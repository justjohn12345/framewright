#include "AudioOutput.h"

#import <AVFAudio/AVFAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

#include <pthread/qos.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <utility>

namespace ve::audio {

using media::makeError;
using media::MediaErrorCode;
using media::okStatus;
using media::Status;

// MARK: - AudioOutput (AVAudioEngine)

namespace {

/// Everything the render block touches. Plain C++; the block captures a raw pointer.
struct RenderContext {
    AudioMixer *mixer = nullptr;
    int channels = 2;
    double sampleRate = 48000.0;
    int capacityFrames = 4096;
    std::vector<float> interleaved;
    std::atomic<bool> muted{false};
    /// Estimate of (IO time - callback entry) when a timestamp has no valid host time.
    std::atomic<uint64_t> fallbackIoOffsetNanos{0};
    std::atomic<uint64_t> hostTimeFallbacks{0};
    // Timeline capture: the render thread appends up to timeline.size() entries.
    std::vector<AudioOutput::TimelineEntry> timeline;
    std::atomic<size_t> timelineWritten{0};
    std::atomic<bool> capturing{false};
};

void renderInto(RenderContext *ctx, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount,
                AudioBufferList *abl) noexcept {
    const int ch = ctx->channels;
    const bool muted = ctx->muted.load(std::memory_order_relaxed);
    const uint64_t entry = HostClock::machToNanos(mach_absolute_time());
    const bool valid =
        timestamp && (timestamp->mFlags & kAudioTimeStampHostTimeValid) != 0 && timestamp->mHostTime != 0;
    const uint64_t io = valid ? HostClock::machToNanos(timestamp->mHostTime)
                              : entry + ctx->fallbackIoOffsetNanos.load(std::memory_order_relaxed);
    if (!valid) {
        ctx->hostTimeFallbacks.fetch_add(1, std::memory_order_relaxed);
    }
    int done = 0;
    const int total = static_cast<int>(frameCount);
    while (done < total) {
        const int n = std::min(total - done, ctx->capacityFrames);
        float *src = ctx->interleaved.data();
        const uint64_t host = io + static_cast<uint64_t>(static_cast<double>(done) * 1e9 / ctx->sampleRate);
        ctx->mixer->render(src, n, ch, host);
        if (ctx->capturing.load(std::memory_order_relaxed)) {
            const size_t slot = ctx->timelineWritten.load(std::memory_order_relaxed);
            if (slot < ctx->timeline.size()) {
                AudioOutput::TimelineEntry &e = ctx->timeline[slot];
                e.ioHostNanos = host;
                e.entryHostNanos = entry;
                e.transportSample = ctx->mixer->lastRenderWasRunning() ? ctx->mixer->lastRenderStartSample() : -1;
                e.frames = n;
                e.hostTimeValid = valid;
                ctx->timelineWritten.store(slot + 1, std::memory_order_release);
            }
        }
        if (muted) {
            std::fill(src, src + static_cast<size_t>(n) * ch, 0.0f);
        }
        if (abl->mNumberBuffers == 1 && static_cast<int>(abl->mBuffers[0].mNumberChannels) == ch) {
            float *dst = static_cast<float *>(abl->mBuffers[0].mData) + static_cast<size_t>(done) * ch;
            std::memcpy(dst, src, sizeof(float) * static_cast<size_t>(n) * ch);
        } else {
            for (UInt32 b = 0; b < abl->mNumberBuffers; ++b) {
                float *dst = static_cast<float *>(abl->mBuffers[b].mData);
                if (!dst) {
                    continue;
                }
                const int c = std::min(static_cast<int>(b), ch - 1);
                for (int k = 0; k < n; ++k) {
                    dst[done + k] = src[static_cast<size_t>(k) * ch + c];
                }
            }
        }
        done += n;
    }
}

/// A device property through the output unit (AUHAL forwards the device's properties).
uint32_t outputUnitProperty(AudioUnit unit, AudioUnitPropertyID property) {
    UInt32 value = 0;
    UInt32 size = sizeof(value);
    if (!unit || AudioUnitGetProperty(unit, property, kAudioUnitScope_Global, 0, &value, &size) != noErr) {
        return 0;
    }
    return value;
}

std::string describe(NSException *e) {
    return e.reason ? std::string(e.reason.UTF8String) : std::string("exception");
}

/// AutomaticAudioOutput's default engine: AudioOutput::create.
media::Result<std::unique_ptr<IAudioOutput>> createEngine(AudioMixer &mixer) {
    auto created = AudioOutput::create(mixer);
    if (!created.ok()) {
        return std::move(created).error();
    }
    return std::unique_ptr<IAudioOutput>(std::move(created).value());
}

} // namespace

struct AudioOutput::Impl {
    AudioMixer *mixer = nullptr;
    std::unique_ptr<RenderContext> context;
    AVAudioEngine *engine = nil;
    AVAudioSourceNode *node = nil;
    AVAudioFormat *format = nil;
    id observer = nil;
    dispatch_queue_t queue = nil; // configuration changes are handled here, one at a time

    std::mutex mutex; // engine operations, closed, breakdown
    bool closed = false;
    LatencyBreakdown breakdown;
    std::atomic<bool> running{false};
    std::atomic<double> latency{0.0};
    std::atomic<uint64_t> configurationChanges{0};

    std::mutex handlerMutex; // held while the handler runs, so clearing it waits for a call in flight
    AudioOutputEventHandler handler;

    void emit(const AudioOutputEvent &event) {
        std::lock_guard<std::mutex> lock(handlerMutex);
        if (handler) {
            handler(event);
        }
    }

    void stopLocked() {
        if (!engine) {
            return;
        }
        @try {
            [engine stop];
        } @catch (NSException *) {
        }
        running.store(false, std::memory_order_release);
    }

    Status connectLocked() {
        @try {
            [engine disconnectNodeOutput:node];
            [engine connect:node to:engine.mainMixerNode format:format];
            [engine prepare];
        } @catch (NSException *e) {
            return makeError(MediaErrorCode::Internal, "AVAudioEngine connect: " + describe(e));
        }
        return okStatus();
    }

    void refreshLatencyLocked() {
        LatencyBreakdown b;
        b.mixerSampleRate = mixer->sampleRate();
        @try {
            b.deviceSampleRate = [engine.outputNode outputFormatForBus:0].sampleRate;
            b.presentationLatency = engine.outputNode.presentationLatency;
            b.pipelineLatency = node.outputPresentationLatency;
            AudioUnit unit = engine.outputNode.audioUnit;
            b.bufferFrames = outputUnitProperty(unit, kAudioDevicePropertyBufferFrameSize);
            b.safetyOffsetFrames = outputUnitProperty(unit, kAudioDevicePropertySafetyOffset);
            b.deviceLatencyFrames = outputUnitProperty(unit, kAudioDevicePropertyLatency);
            b.streamLatencyFrames = static_cast<int64_t>(std::llround(b.presentationLatency * b.deviceSampleRate)) -
                                    static_cast<int64_t>(b.deviceLatencyFrames);
        } @catch (NSException *) {
        }
        if (!(b.pipelineLatency >= b.presentationLatency)) {
            b.pipelineLatency = b.presentationLatency;
        }
        if (b.deviceSampleRate > 0 && b.deviceSampleRate != b.mixerSampleRate) {
            b.converterDelay =
                AudioOutput::measureConverterDelay(b.mixerSampleRate, b.deviceSampleRate, mixer->channels());
        }
        // The engine's own mixer latency is already in the pipeline figure; add only the part of
        // the measured converter delay it does not report.
        const double reportedMixer = b.pipelineLatency - b.presentationLatency;
        b.total = b.pipelineLatency + std::max(0.0, b.converterDelay - reportedMixer);
        breakdown = b;
        latency.store(b.total, std::memory_order_release);
        const double ioOffset = b.deviceSampleRate > 0
                                    ? static_cast<double>(b.bufferFrames + b.safetyOffsetFrames) / b.deviceSampleRate
                                    : 0.0;
        context->fallbackIoOffsetNanos.store(static_cast<uint64_t>(ioOffset * 1e9), std::memory_order_relaxed);
    }

    Status startLocked() {
        NSError *error = nil;
        BOOL ok = NO;
        @try {
            ok = [engine startAndReturnError:&error];
        } @catch (NSException *e) {
            return makeError(MediaErrorCode::Internal, "AVAudioEngine start: " + describe(e));
        }
        if (!ok) {
            return makeError(MediaErrorCode::Internal,
                             std::string("AVAudioEngine start: ") +
                                 (error ? error.localizedDescription.UTF8String : "unknown error"),
                             error ? std::string(error.domain.UTF8String) : std::string(), error ? error.code : 0);
        }
        running.store(true, std::memory_order_release);
        refreshLatencyLocked();
        return okStatus();
    }

    void handleConfigurationChange() {
        AudioOutputEvent event;
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (closed) {
                return; // the output is being destroyed
            }
            configurationChanges.fetch_add(1, std::memory_order_relaxed);
            const bool wasRunning = running.load(std::memory_order_acquire);
            stopLocked();
            // The device format may have changed: reconnect (the main mixer converts from the
            // mixer format to the new device format) and resume where the samples left off.
            Status status = connectLocked();
            if (status.ok() && wasRunning) {
                status = startLocked();
            }
            if (status.ok()) {
                event.kind = AudioOutputEvent::Kind::ConfigurationChanged;
            } else {
                event.kind = AudioOutputEvent::Kind::RestartFailed;
                event.message = status.error().description();
            }
            event.running = running.load(std::memory_order_acquire);
            event.latency = latency.load(std::memory_order_acquire);
        }
        emit(event);
    }
};

media::Result<std::unique_ptr<AudioOutput>> AudioOutput::create(AudioMixer &mixer) {
    (void)HostClock::machToNanos(mach_absolute_time()); // timebase static: never first touched on the render thread
    auto impl = std::make_shared<Impl>();
    impl->mixer = &mixer;
    impl->context = std::make_unique<RenderContext>();
    impl->context->mixer = &mixer;
    impl->context->channels = mixer.channels();
    impl->context->sampleRate = mixer.sampleRate();
    impl->context->interleaved.assign(static_cast<size_t>(impl->context->capacityFrames * mixer.channels()), 0.0f);
    impl->queue = dispatch_queue_create(
        "ve.audio.output.configuration",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
    RenderContext *ctx = impl->context.get();
    @try {
        impl->format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:mixer.sampleRate()
                                                                      channels:static_cast<AVAudioChannelCount>(
                                                                                   mixer.channels())];
        if (!impl->format) {
            return makeError(MediaErrorCode::UnsupportedFormat, "AVAudioFormat for the mixer format");
        }
        impl->engine = [[AVAudioEngine alloc] init];
        impl->node = [[AVAudioSourceNode alloc]
            initWithFormat:impl->format
               renderBlock:^OSStatus(BOOL *, const AudioTimeStamp *timestamp, AVAudioFrameCount frameCount,
                                     AudioBufferList *outputData) {
                 renderInto(ctx, timestamp, frameCount, outputData);
                 return noErr;
               }];
        [impl->engine attachNode:impl->node];
    } @catch (NSException *e) {
        return makeError(MediaErrorCode::Internal, "AVAudioEngine setup: " + describe(e));
    }
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        auto status = impl->connectLocked();
        if (!status.ok()) {
            return std::move(status).error();
        }
    }
    // Configuration changes: the notification is posted on an AVAudioEngine thread; hop to the
    // output's serial queue and do nothing once the output is gone.
    std::weak_ptr<Impl> weak = impl;
    dispatch_queue_t queue = impl->queue;
    impl->observer = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVAudioEngineConfigurationChangeNotification
                    object:impl->engine
                     queue:nil
                usingBlock:^(NSNotification *) {
                  dispatch_async(queue, ^{
                    if (std::shared_ptr<Impl> strong = weak.lock()) {
                        strong->handleConfigurationChange();
                    }
                  });
                }];
    return std::unique_ptr<AudioOutput>(new AudioOutput(std::move(impl)));
}

AudioOutput::AudioOutput(std::shared_ptr<Impl> impl) : impl_(std::move(impl)) {}

AudioOutput::~AudioOutput() {
    if (impl_->observer) {
        [[NSNotificationCenter defaultCenter] removeObserver:impl_->observer];
        impl_->observer = nil;
    }
    {
        // A handler already queued sees `closed` and returns; one running holds the mutex.
        std::lock_guard<std::mutex> lock(impl_->mutex);
        impl_->closed = true;
        impl_->stopLocked();
        @try {
            if (impl_->engine && impl_->node) {
                [impl_->engine detachNode:impl_->node];
            }
        } @catch (NSException *) {
        }
    }
    {
        std::lock_guard<std::mutex> lock(impl_->handlerMutex);
        impl_->handler = nullptr;
    }
}

Status AudioOutput::start() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->running.load(std::memory_order_acquire)) {
        return okStatus();
    }
    return impl_->startLocked();
}

void AudioOutput::stop() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->stopLocked();
}

bool AudioOutput::isRunning() const {
    return impl_->running.load(std::memory_order_acquire);
}

void AudioOutput::setMuted(bool muted) {
    impl_->context->muted.store(muted, std::memory_order_relaxed);
}

bool AudioOutput::isMuted() const {
    return impl_->context->muted.load(std::memory_order_relaxed);
}

double AudioOutput::outputLatency() const {
    return impl_->latency.load(std::memory_order_acquire);
}

void AudioOutput::setEventHandler(AudioOutputEventHandler handler) {
    std::lock_guard<std::mutex> lock(impl_->handlerMutex);
    impl_->handler = std::move(handler);
}

double AudioOutput::deviceSampleRate() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    @try {
        return [impl_->engine.outputNode outputFormatForBus:0].sampleRate;
    } @catch (NSException *) {
        return 0.0;
    }
}

AudioOutput::LatencyBreakdown AudioOutput::latencyBreakdown() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->breakdown;
}

uint64_t AudioOutput::configurationChanges() const {
    return impl_->configurationChanges.load(std::memory_order_relaxed);
}

uint64_t AudioOutput::hostTimeFallbacks() const {
    return impl_->context->hostTimeFallbacks.load(std::memory_order_relaxed);
}

void AudioOutput::handleConfigurationChange() {
    impl_->handleConfigurationChange();
}

void AudioOutput::postConfigurationChangeNotification() {
    AVAudioEngine *engine = nil;
    {
        std::lock_guard<std::mutex> lock(impl_->mutex);
        engine = impl_->engine;
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioEngineConfigurationChangeNotification
                                                        object:engine];
}

void AudioOutput::captureTimeline(size_t capacity) {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    RenderContext &ctx = *impl_->context;
    ctx.capturing.store(false, std::memory_order_release);
    if (impl_->running.load(std::memory_order_acquire)) {
        return; // the render thread may be writing: only while stopped
    }
    ctx.timeline.assign(capacity, TimelineEntry{});
    ctx.timelineWritten.store(0, std::memory_order_release);
    ctx.capturing.store(capacity > 0, std::memory_order_release);
}

std::vector<AudioOutput::TimelineEntry> AudioOutput::drainTimeline() {
    const RenderContext &ctx = *impl_->context;
    const size_t written = ctx.timelineWritten.load(std::memory_order_acquire);
    return std::vector<TimelineEntry>(ctx.timeline.begin(), ctx.timeline.begin() + static_cast<long>(written));
}

double AudioOutput::measureConverterDelay(double fromRate, double toRate, int channels) {
    if (!(fromRate > 0) || !(toRate > 0) || fromRate == toRate) {
        return 0.0;
    }
    static std::mutex cacheMutex;
    static std::map<std::pair<long, long>, double> cache;
    const std::pair<long, long> key{std::lround(fromRate), std::lround(toRate)};
    {
        std::lock_guard<std::mutex> lock(cacheMutex);
        if (auto it = cache.find(key); it != cache.end()) {
            return it->second;
        }
    }
    // A Hann-windowed 1 kHz burst rendered offline through source node -> main mixer -> output
    // at `toRate`, cross-correlated with the ideal (analytically resampled) burst.
    constexpr double kBurstStart = 0.1;
    constexpr double kBurstLength = 0.01;
    constexpr double kFrequency = 1000.0;
    auto burst = [](double t) {
        const double u = t - kBurstStart;
        if (u < 0 || u >= kBurstLength) {
            return 0.0;
        }
        const double window = 0.5 - 0.5 * std::cos(2.0 * M_PI * u / kBurstLength);
        return 0.5 * window * std::sin(2.0 * M_PI * kFrequency * u);
    };
    double delay = 0.0;
    @autoreleasepool {
        @try {
            AVAudioEngine *engine = [[AVAudioEngine alloc] init];
            const auto channelCount = static_cast<AVAudioChannelCount>(channels);
            AVAudioFormat *in = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:fromRate channels:channelCount];
            AVAudioFormat *out = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:toRate channels:channelCount];
            __block int64_t position = 0;
            AVAudioSourceNode *source = [[AVAudioSourceNode alloc]
                initWithFormat:in
                   renderBlock:^OSStatus(BOOL *, const AudioTimeStamp *, AVAudioFrameCount frames,
                                         AudioBufferList *abl) {
                     for (UInt32 b = 0; b < abl->mNumberBuffers; ++b) {
                         auto *d = static_cast<float *>(abl->mBuffers[b].mData);
                         for (AVAudioFrameCount k = 0; k < frames; ++k) {
                             d[k] = static_cast<float>(burst(static_cast<double>(position + k) / fromRate));
                         }
                     }
                     position += frames;
                     return noErr;
                   }];
            [engine attachNode:source];
            [engine connect:source to:engine.mainMixerNode format:in];
            NSError *error = nil;
            if (![engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline
                                            format:out
                                 maximumFrameCount:4096
                                             error:&error] ||
                ![engine startAndReturnError:&error]) {
                return 0.0;
            }
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:engine.manualRenderingFormat
                                                                     frameCapacity:4096];
            const auto total = static_cast<AVAudioFramePosition>(std::ceil(0.3 * toRate));
            std::vector<double> rendered;
            rendered.reserve(static_cast<size_t>(total));
            while (static_cast<AVAudioFramePosition>(rendered.size()) < total) {
                const auto left = total - static_cast<AVAudioFramePosition>(rendered.size());
                const auto want = static_cast<AVAudioFrameCount>(std::min<AVAudioFramePosition>(4096, left));
                const AVAudioEngineManualRenderingStatus status =
                    [engine renderOffline:want toBuffer:buffer error:&error];
                if (status != AVAudioEngineManualRenderingStatusSuccess) {
                    break;
                }
                const float *d = buffer.floatChannelData[0];
                for (AVAudioFrameCount k = 0; k < buffer.frameLength; ++k) {
                    rendered.push_back(d[k]);
                }
            }
            [engine stop];
            // Correlation over lags of +-5 ms, refined by a parabola through the peak.
            const int maxLag = static_cast<int>(std::ceil(0.005 * toRate));
            std::vector<double> r(static_cast<size_t>(2 * maxLag + 1), 0.0);
            const auto first = static_cast<int64_t>(std::floor((kBurstStart - 0.006) * toRate));
            const auto last = static_cast<int64_t>(std::ceil((kBurstStart + kBurstLength + 0.006) * toRate));
            for (int lag = -maxLag; lag <= maxLag; ++lag) {
                double sum = 0.0;
                const int64_t end = std::min<int64_t>(last, static_cast<int64_t>(rendered.size()));
                for (int64_t n = std::max<int64_t>(0, first); n < end; ++n) {
                    sum += rendered[static_cast<size_t>(n)] * burst(static_cast<double>(n - lag) / toRate);
                }
                r[static_cast<size_t>(lag + maxLag)] = sum;
            }
            const auto peak = static_cast<int>(std::max_element(r.begin(), r.end()) - r.begin());
            double refined = peak;
            if (peak > 0 && peak < static_cast<int>(r.size()) - 1) {
                const double a = r[static_cast<size_t>(peak - 1)];
                const double b = r[static_cast<size_t>(peak)];
                const double c = r[static_cast<size_t>(peak + 1)];
                const double denominator = a - 2 * b + c;
                if (denominator != 0) {
                    refined += 0.5 * (a - c) / denominator;
                }
            }
            delay = std::max(0.0, (refined - maxLag) / toRate);
        } @catch (NSException *) {
            return 0.0;
        }
    }
    std::lock_guard<std::mutex> lock(cacheMutex);
    cache[key] = delay;
    return delay;
}

// MARK: - NullAudioOutput

NullAudioOutput::NullAudioOutput(AudioMixer &mixer, NullAudioOutputConfig config)
    : mixer_(mixer), config_([&] {
          NullAudioOutputConfig c = std::move(config);
          c.blockFrames = std::clamp(c.blockFrames, 16, 8192);
          return c;
      }()) {
    buffer_.assign(static_cast<size_t>(config_.blockFrames * mixer_.channels()), 0.0f);
    resetCapture();
}

NullAudioOutput::~NullAudioOutput() {
    stop();
}

Status NullAudioOutput::start() {
    std::lock_guard<std::mutex> lock(controlMutex_);
    if (running_.load(std::memory_order_acquire)) {
        return okStatus();
    }
    if (config_.mode == NullAudioOutputConfig::Mode::Manual) {
        if (!config_.virtualClock || !config_.virtualClock->isVirtual()) {
            return makeError(MediaErrorCode::InvalidArgument, "NullAudioOutput manual mode needs a virtual HostClock");
        }
        running_.store(true, std::memory_order_release);
        return okStatus();
    }
    stopRequested_.store(false, std::memory_order_release);
    running_.store(true, std::memory_order_release);
    thread_ = std::thread([this] { threadMain(); });
    return okStatus();
}

void NullAudioOutput::stop() {
    std::lock_guard<std::mutex> lock(controlMutex_);
    stopRequested_.store(true, std::memory_order_release);
    if (thread_.joinable()) {
        thread_.join();
    }
    running_.store(false, std::memory_order_release);
}

void NullAudioOutput::renderOne() {
    const int ch = mixer_.channels();
    const int n = config_.blockFrames;
    const uint64_t host = config_.mode == NullAudioOutputConfig::Mode::Manual ? config_.virtualClock->nowNanos()
                                                                               : HostClock::system()->nowNanos();
    mixer_.render(buffer_.data(), n, ch, host);
    if (muted_.load(std::memory_order_relaxed)) {
        std::fill(buffer_.begin(), buffer_.end(), 0.0f);
    }
    if (config_.captureFrames > 0 && mixer_.lastRenderWasRunning()) {
        std::lock_guard<std::mutex> lock(captureMutex_);
        const size_t capacity = config_.captureFrames * static_cast<size_t>(ch);
        if (capture_.samples.size() < capacity) {
            if (capture_.firstSequenceSample < 0) {
                capture_.firstSequenceSample = mixer_.lastRenderStartSample();
            }
            const size_t take = std::min(buffer_.size(), capacity - capture_.samples.size());
            capture_.samples.insert(capture_.samples.end(), buffer_.begin(), buffer_.begin() + static_cast<long>(take));
        }
    }
    framesRendered_.fetch_add(n, std::memory_order_acq_rel);
}

int64_t NullAudioOutput::renderBlocks(int count) {
    if (config_.mode != NullAudioOutputConfig::Mode::Manual || !running_.load(std::memory_order_acquire)) {
        return 0;
    }
    const double blockNanos = 1e9 * config_.blockFrames / mixer_.sampleRate();
    int64_t frames = 0;
    for (int i = 0; i < count; ++i) {
        renderOne();
        frames += config_.blockFrames;
        // Advance by the exact block duration (accumulated in integer nanoseconds without drift:
        // the remainder is carried by computing each step from the total).
        const int64_t total = framesRendered_.load(std::memory_order_acquire);
        const uint64_t before = static_cast<uint64_t>(
            static_cast<double>(total - config_.blockFrames) * 1e9 / mixer_.sampleRate() + 0.5);
        const uint64_t after = static_cast<uint64_t>(static_cast<double>(total) * 1e9 / mixer_.sampleRate() + 0.5);
        config_.virtualClock->advance(after > before ? after - before : static_cast<uint64_t>(blockNanos));
    }
    return frames;
}

void NullAudioOutput::threadMain() {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    const double rate = mixer_.sampleRate();
    uint64_t origin = HostClock::system()->nowNanos();
    int64_t blocks = 0;
    while (!stopRequested_.load(std::memory_order_acquire)) {
        renderOne();
        ++blocks;
        const uint64_t due = origin + static_cast<uint64_t>(static_cast<double>(blocks) * config_.blockFrames * 1e9 / rate);
        const uint64_t now = HostClock::system()->nowNanos();
        if (now > due + 100'000'000ull) {
            // Stalled (debugger, heavy load): re-anchor instead of bursting to catch up.
            origin = now;
            blocks = 0;
            continue;
        }
        if (due > now) {
            mach_wait_until(mach_absolute_time() + HostClock::nanosToMach(due - now));
        }
    }
}

void NullAudioOutput::resetCapture() {
    std::lock_guard<std::mutex> lock(captureMutex_);
    capture_ = Capture{};
    capture_.channels = mixer_.channels();
    capture_.samples.reserve(config_.captureFrames * static_cast<size_t>(mixer_.channels()));
}

NullAudioOutput::Capture NullAudioOutput::capture() const {
    std::lock_guard<std::mutex> lock(captureMutex_);
    return capture_;
}

// MARK: - AutomaticAudioOutput

AutomaticAudioOutput::AutomaticAudioOutput(AudioMixer &mixer, EngineFactory engineFactory,
                                           std::chrono::milliseconds retryInterval)
    : mixer_(mixer), engineFactory_(engineFactory ? std::move(engineFactory) : EngineFactory(&createEngine)),
      retryInterval_(retryInterval) {}

AutomaticAudioOutput::~AutomaticAudioOutput() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (engine_) {
        engine_->setEventHandler({}); // waits for an event in flight
        engine_->stop();
        engine_.reset();
    }
    if (null_) {
        null_->stop();
        null_.reset();
    }
}

bool AutomaticAudioOutput::wantsRestart() const {
    if (activeKind_.load(std::memory_order_acquire) == static_cast<int>(Active::Engine) &&
        !engineFailed_.load(std::memory_order_acquire)) {
        return false;
    }
    const int64_t now = std::chrono::duration_cast<std::chrono::nanoseconds>(
                            std::chrono::steady_clock::now().time_since_epoch())
                            .count();
    return engineFailed_.load(std::memory_order_acquire) || now >= nextAttemptNanos_.load(std::memory_order_acquire);
}

void AutomaticAudioOutput::emit(const AudioOutputEvent &event) {
    std::lock_guard<std::mutex> lock(handlerMutex_);
    if (handler_) {
        handler_(event);
    }
}

void AutomaticAudioOutput::applyMutedLocked() {
    muteDirty_.store(false, std::memory_order_release);
    const bool muted = muted_.load(std::memory_order_acquire);
    if (engine_) {
        engine_->setMuted(muted);
    }
    if (null_) {
        null_->setMuted(muted);
    }
}

void AutomaticAudioOutput::publishStateLocked() {
    activeKind_.store(static_cast<int>(active_), std::memory_order_release);
    IAudioOutput *active = active_ == Active::Engine ? engine_.get() : active_ == Active::Null ? null_.get() : nullptr;
    running_.store(active && active->isRunning(), std::memory_order_release);
    latency_.store(active ? active->outputLatency() : 0.0, std::memory_order_release);
}

Status AutomaticAudioOutput::start() {
    Status result = okStatus();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        std::string reason;
        bool done = false;
        if (active_ == Active::Engine && engine_ && !engineFailed_.load(std::memory_order_acquire)) {
            auto status = engine_->start();
            if (status.ok()) {
                done = true;
            } else {
                reason = status.error().description();
                engine_->setEventHandler({});
                engine_.reset();
                active_ = Active::None;
            }
        }
        const auto now = std::chrono::steady_clock::now();
        const bool retryDue =
            !attempted_ || engineFailed_.load(std::memory_order_acquire) || now - lastAttempt_ >= retryInterval_;
        if (!done && retryDue) {
            attempted_ = true;
            lastAttempt_ = now;
            nextAttemptNanos_.store(
                std::chrono::duration_cast<std::chrono::nanoseconds>((now + retryInterval_).time_since_epoch()).count(),
                std::memory_order_release);
            engineAttempts_.fetch_add(1, std::memory_order_relaxed);
            if (engine_) {
                engine_->setEventHandler({});
                engine_->stop();
                engine_.reset();
            }
            engineFailed_.store(false, std::memory_order_release);
            auto created = engineFactory_(mixer_);
            if (created.ok()) {
                std::unique_ptr<IAudioOutput> engine = std::move(created).value();
                engine->setMuted(muted_.load(std::memory_order_acquire));
                engine->setEventHandler([this](const AudioOutputEvent &event) {
                    // The engine is destroyed (clearing this handler) before this output. No lock
                    // here: start() may hold mutex_ while it clears this handler.
                    if (event.kind == AudioOutputEvent::Kind::RestartFailed) {
                        running_.store(false, std::memory_order_release);
                        engineFailed_.store(true, std::memory_order_release);
                    } else {
                        running_.store(event.running, std::memory_order_release);
                        latency_.store(event.latency, std::memory_order_release);
                    }
                    emit(event);
                });
                auto status = engine->start();
                if (status.ok()) {
                    if (null_) {
                        null_->stop();
                    }
                    engine_ = std::move(engine);
                    active_ = Active::Engine;
                    done = true;
                } else {
                    engine->setEventHandler({});
                    reason = status.error().description();
                }
            } else {
                reason = created.error().description();
            }
        }
        if (done) {
            std::lock_guard<std::mutex> info(infoMutex_);
            fallbackReason_.clear();
        } else {
            if (!reason.empty()) {
                std::lock_guard<std::mutex> info(infoMutex_);
                fallbackReason_ = reason;
            }
            if (!null_) {
                null_ = std::make_unique<NullAudioOutput>(mixer_);
            }
            null_->setMuted(muted_.load(std::memory_order_acquire));
            active_ = Active::Null;
            result = null_->start();
        }
        publishStateLocked();
    }
    if (muteDirty_.load(std::memory_order_acquire)) {
        std::lock_guard<std::mutex> lock(mutex_);
        applyMutedLocked();
    }
    if (!result.ok()) {
        return makeError(MediaErrorCode::InvalidState, "no audio output: " + result.error().description());
    }
    return result;
}

void AutomaticAudioOutput::stop() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (engine_) {
            engine_->stop();
        }
        if (null_) {
            null_->stop();
        }
        publishStateLocked();
    }
    if (muteDirty_.load(std::memory_order_acquire)) {
        std::lock_guard<std::mutex> lock(mutex_);
        applyMutedLocked();
    }
}

bool AutomaticAudioOutput::isRunning() const {
    return running_.load(std::memory_order_acquire);
}

void AutomaticAudioOutput::setMuted(bool muted) {
    muted_.store(muted, std::memory_order_release);
    muteDirty_.store(true, std::memory_order_release);
    std::unique_lock<std::mutex> lock(mutex_, std::try_to_lock);
    if (lock.owns_lock()) {
        applyMutedLocked();
    }
    // Otherwise start()/stop() holds the lock and applies the value when it releases it.
}

bool AutomaticAudioOutput::isMuted() const {
    return muted_.load(std::memory_order_acquire);
}

std::string AutomaticAudioOutput::kind() const {
    switch (static_cast<Active>(activeKind_.load(std::memory_order_acquire))) {
    case Active::Engine:
        return "avaudioengine";
    case Active::Null:
        return "null";
    case Active::None:
        break;
    }
    return "none";
}

double AutomaticAudioOutput::outputLatency() const {
    return latency_.load(std::memory_order_acquire);
}

void AutomaticAudioOutput::setEventHandler(AudioOutputEventHandler handler) {
    std::lock_guard<std::mutex> lock(handlerMutex_);
    handler_ = std::move(handler);
}

std::string AutomaticAudioOutput::fallbackReason() const {
    std::lock_guard<std::mutex> lock(infoMutex_);
    return fallbackReason_;
}

} // namespace ve::audio
