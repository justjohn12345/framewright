#include "AudioOutput.h"

#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

#include <pthread/qos.h>

#include <algorithm>
#include <cstring>

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
    int capacityFrames = 4096;
    std::vector<float> interleaved;
    std::atomic<bool> muted{false};
};

void renderInto(RenderContext *ctx, AVAudioFrameCount frameCount, AudioBufferList *abl) noexcept {
    const int ch = ctx->channels;
    const bool muted = ctx->muted.load(std::memory_order_relaxed);
    const uint64_t host = HostClock::machToNanos(mach_absolute_time());
    int done = 0;
    const int total = static_cast<int>(frameCount);
    while (done < total) {
        const int n = std::min(total - done, ctx->capacityFrames);
        float *src = ctx->interleaved.data();
        ctx->mixer->render(src, n, ch, host);
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

} // namespace

struct AudioOutput::Impl {
    AudioMixer *mixer = nullptr;
    Clock *latencyClock = nullptr;
    std::unique_ptr<RenderContext> context;
    AVAudioEngine *engine = nil;
    AVAudioSourceNode *node = nil;
    AVAudioFormat *format = nil;
    id observer = nil;
    mutable std::mutex mutex;
    bool running = false;
    uint64_t configurationChanges = 0;
    double latency = 0.0;

    ~Impl() {
        if (observer) {
            [[NSNotificationCenter defaultCenter] removeObserver:observer];
            observer = nil;
        }
        std::lock_guard<std::mutex> lock(mutex);
        stopLocked();
        @try {
            if (engine && node) {
                [engine detachNode:node];
            }
        } @catch (NSException *) {
        }
        node = nil;
        engine = nil;
    }

    void stopLocked() {
        if (!engine) {
            return;
        }
        @try {
            [engine stop];
        } @catch (NSException *) {
        }
        running = false;
    }

    Status connectLocked() {
        @try {
            [engine disconnectNodeOutput:node];
            [engine connect:node to:engine.mainMixerNode format:format];
            [engine prepare];
        } @catch (NSException *e) {
            return makeError(MediaErrorCode::Internal,
                             std::string("AVAudioEngine connect: ") + (e.reason ? e.reason.UTF8String : "exception"));
        }
        return okStatus();
    }

    Status startLocked() {
        NSError *error = nil;
        BOOL ok = NO;
        @try {
            ok = [engine startAndReturnError:&error];
        } @catch (NSException *e) {
            return makeError(MediaErrorCode::Internal,
                             std::string("AVAudioEngine start: ") + (e.reason ? e.reason.UTF8String : "exception"));
        }
        if (!ok) {
            return makeError(MediaErrorCode::Internal,
                             std::string("AVAudioEngine start: ") +
                                 (error ? error.localizedDescription.UTF8String : "unknown error"),
                             error ? std::string(error.domain.UTF8String) : std::string(), error ? error.code : 0);
        }
        running = true;
        @try {
            latency = engine.outputNode.presentationLatency;
        } @catch (NSException *) {
            latency = 0.0;
        }
        if (latencyClock) {
            latencyClock->setOutputLatency(latency);
        }
        return okStatus();
    }
};

media::Result<std::unique_ptr<AudioOutput>> AudioOutput::create(AudioMixer &mixer, Clock *latencyClock) {
    auto impl = std::make_unique<Impl>();
    impl->mixer = &mixer;
    impl->latencyClock = latencyClock;
    impl->context = std::make_unique<RenderContext>();
    impl->context->mixer = &mixer;
    impl->context->channels = mixer.channels();
    impl->context->interleaved.assign(static_cast<size_t>(impl->context->capacityFrames * mixer.channels()), 0.0f);
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
               renderBlock:^OSStatus(BOOL *, const AudioTimeStamp *, AVAudioFrameCount frameCount,
                                     AudioBufferList *outputData) {
                   renderInto(ctx, frameCount, outputData);
                   return noErr;
               }];
        [impl->engine attachNode:impl->node];
    } @catch (NSException *e) {
        return makeError(MediaErrorCode::Internal,
                         std::string("AVAudioEngine setup: ") + (e.reason ? e.reason.UTF8String : "exception"));
    }
    {
        std::lock_guard<std::mutex> lock(impl->mutex);
        auto status = impl->connectLocked();
        if (!status.ok()) {
            return std::move(status).error();
        }
    }
    Impl *raw = impl.get();
    std::unique_ptr<AudioOutput> output(new AudioOutput(std::move(impl)));
    AudioOutput *self = output.get();
    raw->observer = [[NSNotificationCenter defaultCenter] addObserverForName:AVAudioEngineConfigurationChangeNotification
                                                                      object:raw->engine
                                                                       queue:nil
                                                                  usingBlock:^(NSNotification *) {
                                                                      self->handleConfigurationChange();
                                                                  }];
    return output;
}

AudioOutput::AudioOutput(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}

AudioOutput::~AudioOutput() = default;

Status AudioOutput::start() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    if (impl_->running) {
        return okStatus();
    }
    return impl_->startLocked();
}

void AudioOutput::stop() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    impl_->stopLocked();
}

bool AudioOutput::isRunning() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->running;
}

void AudioOutput::setMuted(bool muted) {
    impl_->context->muted.store(muted, std::memory_order_relaxed);
}

bool AudioOutput::isMuted() const {
    return impl_->context->muted.load(std::memory_order_relaxed);
}

double AudioOutput::outputLatency() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->latency;
}

double AudioOutput::deviceSampleRate() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    @try {
        return [impl_->engine.outputNode outputFormatForBus:0].sampleRate;
    } @catch (NSException *) {
        return 0.0;
    }
}

uint64_t AudioOutput::configurationChanges() const {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->configurationChanges;
}

void AudioOutput::handleConfigurationChange() {
    std::lock_guard<std::mutex> lock(impl_->mutex);
    ++impl_->configurationChanges;
    const bool wasRunning = impl_->running;
    impl_->stopLocked();
    // The device format may have changed: reconnect (the main mixer converts from the mixer
    // format to the new device format) and resume where the samples left off.
    if (!impl_->connectLocked().ok()) {
        return;
    }
    if (wasRunning) {
        (void)impl_->startLocked();
    }
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
    if (config_.captureFrames > 0) {
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

AutomaticAudioOutput::AutomaticAudioOutput(AudioMixer &mixer, Clock *latencyClock)
    : mixer_(mixer), latencyClock_(latencyClock) {}

AutomaticAudioOutput::~AutomaticAudioOutput() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (active_) {
        active_->stop();
        active_.reset();
    }
}

Status AutomaticAudioOutput::start() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!triedEngine_) {
        triedEngine_ = true;
        auto engine = AudioOutput::create(mixer_, latencyClock_);
        if (engine.ok()) {
            active_ = std::move(engine).value();
            active_->setMuted(muted_);
            auto status = active_->start();
            if (status.ok()) {
                return status;
            }
            fallbackReason_ = status.error().description();
            active_.reset();
        } else {
            fallbackReason_ = engine.error().description();
        }
        active_ = std::make_unique<NullAudioOutput>(mixer_);
        active_->setMuted(muted_);
        if (latencyClock_) {
            latencyClock_->setOutputLatency(0.0);
        }
    }
    if (!active_) {
        return makeError(MediaErrorCode::InvalidState, "no audio output");
    }
    return active_->start();
}

void AutomaticAudioOutput::stop() {
    std::lock_guard<std::mutex> lock(mutex_);
    if (active_) {
        active_->stop();
    }
}

bool AutomaticAudioOutput::isRunning() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return active_ && active_->isRunning();
}

void AutomaticAudioOutput::setMuted(bool muted) {
    std::lock_guard<std::mutex> lock(mutex_);
    muted_ = muted;
    if (active_) {
        active_->setMuted(muted);
    }
}

bool AutomaticAudioOutput::isMuted() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return muted_;
}

std::string AutomaticAudioOutput::kind() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return active_ ? active_->kind() : "none";
}

double AutomaticAudioOutput::outputLatency() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return active_ ? active_->outputLatency() : 0.0;
}

std::string AutomaticAudioOutput::fallbackReason() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return fallbackReason_;
}

} // namespace ve::audio
