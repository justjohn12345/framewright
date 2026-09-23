#include "AudioMixer.h"

#include <Accelerate/Accelerate.h>
#include <dispatch/dispatch.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <thread>
#include <unordered_set>

namespace ve::audio {

namespace {

constexpr float kHalfPi = static_cast<float>(M_PI / 2.0);
constexpr int kDecimatorTaps = 63;

/// Half-band low-pass (cutoff at a quarter of the input rate) for 2:1 decimation: a
/// Blackman-windowed sinc normalised to unity gain at DC. Symmetric, so correlation (what
/// vDSP_desamp computes) equals convolution.
std::vector<float> designHalfBand(int taps) {
    const int mid = (taps - 1) / 2;
    std::vector<double> h(static_cast<size_t>(taps));
    double sum = 0.0;
    for (int n = 0; n < taps; ++n) {
        const int m = n - mid;
        const double sinc = m == 0 ? 0.5 : std::sin(M_PI * m / 2.0) / (M_PI * m);
        const double x = 2.0 * M_PI * n / (taps - 1);
        const double window = 0.42 - 0.5 * std::cos(x) + 0.08 * std::cos(2.0 * x);
        h[static_cast<size_t>(n)] = sinc * window;
        sum += sinc * window;
    }
    std::vector<float> out(static_cast<size_t>(taps));
    for (int n = 0; n < taps; ++n) {
        out[static_cast<size_t>(n)] = static_cast<float>(h[static_cast<size_t>(n)] / sum);
    }
    return out;
}

} // namespace

struct AudioMixer::Reaper {
    dispatch_queue_t queue = nil;
};

AudioMixer::Garbage::~Garbage() {
    for (Plan *plan : plans) {
        delete plan;
    }
}

AudioMixer::AudioMixer(std::shared_ptr<media::BackendRouter> router, Clock *clock, AudioMixerConfig config)
    : router_(std::move(router)), clock_(clock), config_([&] {
          AudioMixerConfig c = config;
          c.channels = std::clamp(c.channels, 1, 8);
          c.maxChunkFrames = std::max(64, c.maxChunkFrames);
          if (!(c.sampleRate > 0)) {
              c.sampleRate = 48000.0;
          }
          if (!(c.rampSeconds >= 0) || !std::isfinite(c.rampSeconds)) {
              c.rampSeconds = 0.005;
          }
          return c;
      }()),
      maxSequenceFrames_(config_.maxChunkFrames * 2),
      rampFrames_(std::max(1, static_cast<int>(std::llround(config_.rampSeconds * config_.sampleRate)))) {
    const size_t samples = static_cast<size_t>(maxSequenceFrames_) * static_cast<size_t>(config_.channels);
    mixScratch_.assign(samples, 0.0f);
    readScratch_.assign(samples, 0.0f);
    envelope_.assign(static_cast<size_t>(maxSequenceFrames_), 0.0f);
    oldEnvelope_.assign(static_cast<size_t>(maxSequenceFrames_), 0.0f);
    ramp_.assign(static_cast<size_t>(maxSequenceFrames_), 0.0f);
    shape_.assign(static_cast<size_t>(maxSequenceFrames_), 0.0f);
    decimatorTaps_ = designHalfBand(kDecimatorTaps);
    history_.assign(static_cast<size_t>(kDecimatorTaps - 1) * static_cast<size_t>(config_.channels), 0.0f);
    filterIn_.assign(static_cast<size_t>(kDecimatorTaps - 1 + maxSequenceFrames_), 0.0f);
    filterOut_.assign(static_cast<size_t>(config_.maxChunkFrames), 0.0f);
    reaper_ = std::make_unique<Reaper>();
    reaper_->queue = dispatch_queue_create(
        "ve.audio.mixer.reaper", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
}

AudioMixer::~AudioMixer() {
    Garbage all;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        reclaimRetired();
        std::unordered_set<Plan *> plans(garbage_.plans.begin(), garbage_.plans.end());
        garbage_.plans.clear();
        Plan *const pending = pending_.exchange(nullptr, std::memory_order_acq_rel);
        for (Plan *plan : {pending, current_, fadePlan_, blendPlan_, latest_}) {
            if (plan) {
                plans.insert(plan);
            }
        }
        current_ = fadePlan_ = blendPlan_ = latest_ = nullptr;
        all.plans.assign(plans.begin(), plans.end());
        all.sources = std::move(garbage_.sources);
        for (SourceEntry &entry : sources_) {
            all.sources.push_back(std::move(entry.source));
        }
        sources_.clear();
    }
    // Batches already handed to the reaper finish first; `all` is destroyed on return.
    dispatch_sync(reaper_->queue, ^{
                  });
}

// MARK: - Control

void AudioMixer::registerAsset(AssetId asset, std::string path, std::optional<media::RoutedMediaInfo> routed) {
    std::lock_guard<std::mutex> lock(mutex_);
    assets_[asset] = AssetEntry{std::move(path), std::move(routed)};
}

int64_t AudioMixer::sampleFor(CMTime t) const {
    if (!CMTIME_IS_NUMERIC(t)) {
        return 0;
    }
    // Exact rational rounding: value * rate / timescale.
    const double rate = config_.sampleRate;
    if (rate == std::floor(rate)) {
        const __int128 num = static_cast<__int128>(t.value) * static_cast<__int128>(rate);
        const __int128 den = t.timescale;
        const __int128 q = num >= 0 ? (2 * num + den) / (2 * den) : -((-2 * num + den) / (2 * den));
        return static_cast<int64_t>(q);
    }
    return static_cast<int64_t>(std::llround(CMTimeGetSeconds(t) * rate));
}

void AudioMixer::reclaimRetired() {
    Plan *plan = nullptr;
    while (retired_.pop(plan)) {
        garbage_.plans.push_back(plan);
    }
}

std::unique_ptr<AudioMixer::Plan> AudioMixer::copyLatest() const {
    if (!latest_) {
        return std::make_unique<Plan>();
    }
    return std::make_unique<Plan>(*latest_);
}

void AudioMixer::publish(std::unique_ptr<Plan> plan) {
    reclaimRetired();
    Plan *raw = plan.release();
    if (Plan *unadopted = pending_.exchange(raw, std::memory_order_acq_rel)) {
        garbage_.plans.push_back(unadopted); // the render thread never saw it
    }
    latest_ = raw;
}

void AudioMixer::collectGarbage() {
    Garbage batch;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        reclaimRetired();
        if (garbage_.empty()) {
            return;
        }
        batch = std::move(garbage_);
        garbage_ = Garbage{};
        ++garbageBatches_;
    }
    auto *heap = new Garbage(std::move(batch));
    dispatch_async(reaper_->queue, ^{
      delete heap;
    });
}

void AudioMixer::setGraph(const AudioGraph &graph, CMTime sequenceTime) {
    std::lock_guard<std::mutex> lock(mutex_);
    const int64_t playhead = sampleFor(sequenceTime);

    struct Group {
        TrackId track;
        AudioSourceMapping mapping;
        std::vector<PlanSegment> segments;
        int64_t spanStart = 0;
        int64_t spanEnd = 0;
    };
    std::vector<Group> groups;
    for (const AudioSegment &segment : graph.segments) {
        const auto asset = assets_.find(segment.assetId);
        if (asset == assets_.end() || asset->second.path.empty()) {
            continue;
        }
        const int64_t start = sampleFor(segment.timelineRange.start);
        const int64_t end = sampleFor(segment.timelineRange.end);
        if (end <= start) {
            continue;
        }
        AudioSourceMapping mapping;
        mapping.asset = segment.assetId;
        mapping.path = asset->second.path;
        mapping.routed = asset->second.routed;
        mapping.speed = segment.speedRatio; // exact (the clip's own ratio)
        if (mapping.speed.num <= 0 || mapping.speed.den <= 0) {
            mapping.speed = Ratio{1, 1};
        }
        mapping.sourceAtZero = segment.sourceRange.start - scaleTime(segment.timelineRange.start, mapping.speed);

        PlanSegment ps;
        ps.start = start;
        ps.end = end;
        ps.gainStart = segment.gain * segment.fade.start;
        ps.gainEnd = segment.gain * segment.fade.end;
        if (segment.transitionId) {
            ps.crossfade = true;
            ps.crossfadeStart = segment.crossfade.start;
            ps.crossfadeEnd = segment.crossfade.end;
        } else if (!segment.crossfade.isUnity()) {
            ps.gainStart *= segment.crossfade.start;
            ps.gainEnd *= segment.crossfade.end;
        }

        auto group = std::find_if(groups.begin(), groups.end(), [&](const Group &g) {
            return g.track == segment.trackId && g.mapping.sameAs(mapping);
        });
        if (group == groups.end()) {
            groups.push_back(Group{segment.trackId, std::move(mapping), {}, start, end});
            group = groups.end() - 1;
        }
        group->segments.push_back(ps);
        group->spanStart = std::min(group->spanStart, start);
        group->spanEnd = std::max(group->spanEnd, end);
    }

    // Match groups to existing sources: same track first, then the same media on another track
    // (a clip moved between tracks keeps its decoded audio).
    std::vector<bool> claimed(sources_.size(), false);
    std::vector<std::shared_ptr<ClipAudioSource>> chosen(groups.size());
    for (size_t g = 0; g < groups.size(); ++g) {
        for (size_t i = 0; i < sources_.size(); ++i) {
            if (!claimed[i] && sources_[i].track == groups[g].track &&
                sources_[i].source->mapping().sameAs(groups[g].mapping)) {
                chosen[g] = sources_[i].source;
                claimed[i] = true;
                break;
            }
        }
    }
    for (size_t g = 0; g < groups.size(); ++g) {
        for (size_t i = 0; i < sources_.size() && !chosen[g]; ++i) {
            if (!claimed[i] && sources_[i].source->mapping().sameAs(groups[g].mapping)) {
                chosen[g] = sources_[i].source;
                claimed[i] = true;
            }
        }
    }

    const bool stopped = !(latest_ && latest_->running);
    const int64_t renderPosition = position_.load(std::memory_order_acquire);
    std::unique_ptr<Plan> plan = copyLatest();
    plan->sources.clear();
    plan->segments.clear();
    plan->owners.clear();
    std::vector<SourceEntry> nextSources;
    ClipAudioSourceConfig sourceConfig;
    sourceConfig.sampleRate = config_.sampleRate;
    sourceConfig.channels = config_.channels;
    sourceConfig.lookaheadSeconds = config_.lookaheadSeconds;
    sourceConfig.refillSeconds = config_.refillSeconds;
    sourceConfig.capacitySeconds = config_.lookaheadSeconds + 1.0;

    for (size_t g = 0; g < groups.size(); ++g) {
        Group &group = groups[g];
        std::shared_ptr<ClipAudioSource> source = chosen[g];
        if (!source) {
            source = std::make_shared<ClipAudioSource>(router_, group.mapping, sourceConfig);
            const int64_t from = stopped ? playhead : std::max(playhead, renderPosition);
            source->seekTo(std::max(group.spanStart, from));
            ++sourcesCreated_;
        } else {
            ++sourcesReused_;
            if (stopped) {
                // An earlier run may have consumed this source past its head (or anywhere else):
                // put it where playback from `playhead` will first need it.
                const int64_t target = std::max(group.spanStart, playhead);
                if (!source->isPositionedAt(target)) {
                    source->seekTo(target);
                    ++repositionsWhileStopped_;
                }
            }
        }
        PlanSource ps;
        ps.source = source.get();
        ps.spanStart = group.spanStart;
        ps.spanEnd = group.spanEnd;
        ps.firstSegment = static_cast<uint32_t>(plan->segments.size());
        ps.segmentCount = static_cast<uint32_t>(group.segments.size());
        plan->segments.insert(plan->segments.end(), group.segments.begin(), group.segments.end());
        plan->sources.push_back(ps);
        plan->owners.push_back(source);
        nextSources.push_back(SourceEntry{group.track, std::move(source)});
    }
    // Sources that dropped out stay alive through the plans that still reference them; the
    // last reference is released on the reaper queue (collectGarbage), never here.
    for (size_t i = 0; i < sources_.size(); ++i) {
        if (!claimed[i]) {
            garbage_.sources.push_back(std::move(sources_[i].source));
        }
    }
    sources_ = std::move(nextSources);
    publish(std::move(plan));
}

void AudioMixer::clearGraph() {
    setGraph(AudioGraph{}, kCMTimeZero);
}

void AudioMixer::start(CMTime at, int audioRate, uint32_t clockEpoch) {
    std::lock_guard<std::mutex> lock(mutex_);
    std::unique_ptr<Plan> plan = copyLatest();
    plan->transportSerial = ++transportSerial_;
    plan->baseSerial = plan->transportSerial;
    plan->running = audioRate == 1 || audioRate == 2;
    plan->audioRate = plan->running ? audioRate : 1;
    plan->startSample = sampleFor(at);
    plan->clockEpoch = clockEpoch;
    publish(std::move(plan));
}

bool AudioMixer::changeRate(int audioRate, uint32_t clockEpoch) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!latest_ || !latest_->running || (audioRate != 1 && audioRate != 2)) {
        return false;
    }
    std::unique_ptr<Plan> plan = copyLatest();
    plan->transportSerial = ++transportSerial_; // same baseSerial: the render thread continues
    plan->audioRate = audioRate;
    plan->clockEpoch = clockEpoch;
    publish(std::move(plan));
    return true;
}

uint64_t AudioMixer::stop() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::unique_ptr<Plan> plan = copyLatest();
    plan->transportSerial = ++transportSerial_;
    plan->baseSerial = plan->transportSerial;
    plan->running = false;
    const uint64_t serial = plan->transportSerial;
    publish(std::move(plan));
    return serial;
}

bool AudioMixer::stopCompleted(uint64_t serial) const noexcept {
    return rtStoppedSerial_.load(std::memory_order_acquire) >= serial;
}

bool AudioMixer::isRunning() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return latest_ && latest_->running;
}

std::vector<AudioMixer::Window> AudioMixer::primeWindows(int64_t s) const {
    std::vector<Window> windows;
    const int64_t window = std::max<int64_t>(1, static_cast<int64_t>(config_.primeSeconds * config_.sampleRate));
    if (!latest_) {
        return windows;
    }
    for (const PlanSource &ps : latest_->sources) {
        if (ps.spanEnd <= s || ps.spanStart >= s + window) {
            continue;
        }
        const int64_t from = std::max(ps.spanStart, s);
        windows.push_back(Window{ps.source, from, std::min(window, ps.spanEnd - from)});
    }
    return windows;
}

void AudioMixer::prepare(CMTime at) {
    std::lock_guard<std::mutex> lock(mutex_);
    for (const Window &w : primeWindows(sampleFor(at))) {
        if (!w.source->isPositionedAt(w.from)) {
            w.source->seekTo(w.from);
        }
    }
}

bool AudioMixer::isPrimed(CMTime at) const {
    std::lock_guard<std::mutex> lock(mutex_);
    const std::vector<Window> windows = primeWindows(sampleFor(at));
    return std::all_of(windows.begin(), windows.end(),
                       [](const Window &w) { return w.source->isReady(w.from, w.frames); });
}

bool AudioMixer::prime(CMTime at, std::chrono::milliseconds timeout) {
    prepare(at);
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    for (;;) {
        if (isPrimed(at)) {
            return true;
        }
        if (std::chrono::steady_clock::now() >= deadline) {
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

bool AudioMixer::waitForBuffered(std::chrono::milliseconds timeout) {
    const int64_t window = std::max<int64_t>(1, static_cast<int64_t>(config_.primeSeconds * config_.sampleRate));
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    for (;;) {
        bool ready = true;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            const int64_t p = position_.load(std::memory_order_acquire);
            const int64_t reach = p + window * (latest_ ? latest_->audioRate : 1);
            if (latest_) {
                for (const PlanSource &ps : latest_->sources) {
                    if (ps.spanEnd <= p || ps.spanStart >= reach) {
                        continue;
                    }
                    const int64_t from = std::max(ps.spanStart, p);
                    if (!ps.source->isReady(from, std::min(reach, ps.spanEnd) - from)) {
                        ready = false;
                        break;
                    }
                }
            }
        }
        if (ready) {
            return true;
        }
        if (std::chrono::steady_clock::now() >= deadline) {
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

bool AudioMixer::isRangeReady(int64_t from, int64_t frames) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!latest_ || frames <= 0) {
        return true;
    }
    const int64_t to = from + frames;
    for (const PlanSource &ps : latest_->sources) {
        if (ps.spanEnd <= from || ps.spanStart >= to) {
            continue;
        }
        const int64_t a = std::max(ps.spanStart, from);
        if (!ps.source->isReady(a, std::min(to, ps.spanEnd) - a)) {
            return false;
        }
    }
    return true;
}

std::optional<AudioMixer::SourceInfo> AudioMixer::failedSourceIn(int64_t from, int64_t frames) const {
    std::lock_guard<std::mutex> lock(mutex_);
    if (!latest_) {
        return std::nullopt;
    }
    const int64_t to = from + frames;
    for (const PlanSource &ps : latest_->sources) {
        if (ps.spanEnd <= from || ps.spanStart >= to) {
            continue;
        }
        const ClipAudioSource::Stats st = ps.source->stats();
        // A read failure matters from its sample on (the source played audio before it).
        const bool readFailedHere = st.readFailed && st.readFailedAt < std::min(to, ps.spanEnd);
        if (st.failed || readFailedHere) {
            TrackId track;
            for (const SourceEntry &entry : sources_) {
                if (entry.source.get() == ps.source) {
                    track = entry.track;
                }
            }
            SourceInfo info{ps.source->mapping().asset, track, st.backend, st.error, true,
                            st.bufferedFrames, st.repositions, st.wakeups};
            info.failedAt = st.failed ? std::max(from, ps.spanStart) : std::max(st.readFailedAt, ps.spanStart);
            return info;
        }
    }
    return std::nullopt;
}

void AudioMixer::setMasterGain(float gain) {
    masterGain_.store(std::isfinite(gain) ? std::max(0.0f, gain) : 1.0f, std::memory_order_relaxed);
}

float AudioMixer::masterGain() const {
    return masterGain_.load(std::memory_order_relaxed);
}

void AudioMixer::setMuted(bool muted) {
    muted_.store(muted, std::memory_order_relaxed);
}

bool AudioMixer::isMuted() const {
    return muted_.load(std::memory_order_relaxed);
}

double AudioMixer::processingLatency(int audioRate) const {
    // A linear-phase FIR delays by (taps - 1) / 2 input (sequence) samples; at 2:1 that is half
    // as many output samples.
    return audioRate == 2 ? (kDecimatorTaps - 1) / 2.0 / 2.0 / config_.sampleRate : 0.0;
}

AudioMixer::Stats AudioMixer::stats() const {
    Stats s;
    s.renders = renders_.load(std::memory_order_relaxed);
    s.renderedFrames = renderedFrames_.load(std::memory_order_relaxed);
    s.underruns = underruns_.load(std::memory_order_relaxed);
    s.underrunFrames = underrunFrames_.load(std::memory_order_relaxed);
    s.planSwaps = planSwaps_.load(std::memory_order_relaxed);
    s.retireOverflows = retireOverflows_.load(std::memory_order_relaxed);
    s.stopFades = stopFades_.load(std::memory_order_relaxed);
    s.planBlends = planBlends_.load(std::memory_order_relaxed);
    s.position = position_.load(std::memory_order_acquire);
    s.running = rtRunning_.load(std::memory_order_acquire);
    s.audioRate = rtAudioRate_.load(std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(mutex_);
    s.sourcesCreated = sourcesCreated_;
    s.sourcesReused = sourcesReused_;
    s.repositionsWhileStopped = repositionsWhileStopped_;
    s.garbageBatches = garbageBatches_;
    for (const SourceEntry &entry : sources_) {
        const ClipAudioSource::Stats st = entry.source->stats();
        SourceInfo info{entry.source->mapping().asset, entry.track, st.backend, st.error, st.failed,
                        st.bufferedFrames, st.repositions, st.wakeups};
        info.failedAt = st.readFailed ? st.readFailedAt : -1;
        s.sources.push_back(std::move(info));
    }
    return s;
}

// MARK: - Realtime

void AudioMixer::retire(Plan *plan) noexcept {
    if (plan && !retired_.push(plan)) {
        retireOverflows_.fetch_add(1, std::memory_order_relaxed); // leaked rather than freed here
    }
}

void AudioMixer::adopt(Plan *next) noexcept {
    Plan *prev = current_;
    current_ = next;
    planSwaps_.fetch_add(1, std::memory_order_relaxed);
    if (!prev) {
        return;
    }
    const bool prevLive = rtLive_ && prev->running && prev->baseSerial == rtBaseSerial_;
    if (!prevLive) {
        retire(prev);
        return;
    }
    if (next->running && next->baseSerial == rtBaseSerial_) {
        // The live transport goes on: a re-plan (new envelopes) and/or a rate change
        // (changeRate: new audio rate and clock epoch, same render position). Crossfade the
        // envelopes from the older plan still being blended (if any) or from prev.
        rtEpoch_ = next->clockEpoch;
        if (blendPlan_) {
            retire(prev);
        } else {
            blendPlan_ = prev;
        }
        blendDone_ = 0;
        planBlends_.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    // The live transport ends (stop, or a jump to another start): fade it out.
    if (blendPlan_) {
        retire(blendPlan_);
        blendPlan_ = nullptr;
    }
    fadePlan_ = prev;
    fadeDone_ = 0;
    rtLive_ = false;
    stopFades_.fetch_add(1, std::memory_order_relaxed);
}

void AudioMixer::envelope(const Plan &plan, const PlanSource &ps, int64_t a, int64_t b, float *env, float *ramp,
                          float *shape) noexcept {
    const int len = static_cast<int>(b - a);
    std::fill(env, env + len, 0.0f);
    for (uint32_t i = 0; i < ps.segmentCount; ++i) {
        const PlanSegment &seg = plan.segments[ps.firstSegment + i];
        const int64_t sa = std::max(a, seg.start);
        const int64_t sb = std::min(b, seg.end);
        if (sa >= sb) {
            continue;
        }
        const vDSP_Length k = static_cast<vDSP_Length>(sb - sa);
        const double length = static_cast<double>(seg.end - seg.start);
        const double into = static_cast<double>(sa - seg.start);
        const float g0 = static_cast<float>(seg.gainStart + (seg.gainEnd - seg.gainStart) * into / length);
        const float gStep = static_cast<float>((seg.gainEnd - seg.gainStart) / length);
        vDSP_vramp(&g0, &gStep, ramp, 1, k);
        if (seg.crossfade) {
            const float c0 =
                static_cast<float>(seg.crossfadeStart + (seg.crossfadeEnd - seg.crossfadeStart) * into / length);
            const float cStep = static_cast<float>((seg.crossfadeEnd - seg.crossfadeStart) / length);
            vDSP_vramp(&c0, &cStep, shape, 1, k);
            vDSP_vsmul(shape, 1, &kHalfPi, shape, 1, k);
            const int count = static_cast<int>(k);
            vvsinf(shape, shape, &count);
            vDSP_vmul(ramp, 1, shape, 1, ramp, 1, k);
        }
        float *dst = env + (sa - a);
        vDSP_vadd(dst, 1, ramp, 1, dst, 1, k);
    }
}

void AudioMixer::mixChunk(const Plan &plan, int64_t position, int frames, float *mix, uint64_t &missing,
                          bool blend) noexcept {
    const int ch = config_.channels;
    const int64_t end = position + frames;
    const Plan *old = blend ? blendPlan_ : nullptr;
    // Plan crossfade window [blendStart, blendEnd) in sequence samples; weight of the new plan
    // at sample n is (n - blendStart + 1) / rampFrames_.
    const int64_t blendStart = position - blendDone_;
    const int64_t blendEnd = old ? blendStart + rampFrames_ : position;
    auto weight = [&](int64_t n) {
        return std::min(1.0f, static_cast<float>(n - blendStart + 1) / static_cast<float>(rampFrames_));
    };
    auto findIn = [](const Plan &p, const ClipAudioSource *source) -> const PlanSource * {
        for (const PlanSource &candidate : p.sources) {
            if (candidate.source == source) {
                return &candidate;
            }
        }
        return nullptr;
    };
    auto accumulate = [&](ClipAudioSource *source, int64_t a, int64_t b, const float *env) {
        const int len = static_cast<int>(b - a);
        float *tmp = readScratch_.data();
        const int got = source->read(a, tmp, len);
        if (got < len) {
            std::fill(tmp + static_cast<size_t>(got) * ch, tmp + static_cast<size_t>(len) * ch, 0.0f);
            missing += static_cast<uint64_t>(len - got);
        }
        float *out = mix + static_cast<size_t>(a - position) * ch;
        for (int c = 0; c < ch; ++c) {
            vDSP_vma(tmp + c, ch, env, 1, out + c, ch, out + c, ch, static_cast<vDSP_Length>(len));
        }
    };

    for (const PlanSource &ps : plan.sources) {
        const PlanSource *ops = old ? findIn(*old, ps.source) : nullptr;
        int64_t lo = ps.spanStart;
        int64_t hi = ps.spanEnd;
        if (ops && ops->spanStart < blendEnd) {
            // During the crossfade the old envelope still counts where the new one may not.
            lo = std::min(lo, ops->spanStart);
            hi = std::max(hi, std::min(ops->spanEnd, blendEnd));
        }
        const int64_t a = std::max(position, lo);
        const int64_t b = std::min(end, hi);
        if (a >= b) {
            continue;
        }
        float *env = envelope_.data();
        envelope(plan, ps, a, b, env, ramp_.data(), shape_.data());
        const int64_t windowEnd = std::min(b, blendEnd);
        if (old && windowEnd > a) {
            float *oldEnv = oldEnvelope_.data();
            if (ops) {
                envelope(*old, *ops, a, windowEnd, oldEnv, ramp_.data(), shape_.data());
            } else {
                std::fill(oldEnv, oldEnv + (windowEnd - a), 0.0f); // new under the playhead: fade in
            }
            for (int64_t n = a; n < windowEnd; ++n) {
                const size_t k = static_cast<size_t>(n - a);
                env[k] = oldEnv[k] + (env[k] - oldEnv[k]) * weight(n);
            }
        }
        accumulate(ps.source, a, b, env);
    }
    if (old && blendEnd > position) {
        // Sources the new plan dropped fade out over the crossfade.
        for (const PlanSource &ops : old->sources) {
            if (findIn(plan, ops.source)) {
                continue;
            }
            const int64_t a = std::max(position, ops.spanStart);
            const int64_t b = std::min({end, blendEnd, ops.spanEnd});
            if (a >= b) {
                continue;
            }
            float *env = oldEnvelope_.data();
            envelope(*old, ops, a, b, env, ramp_.data(), shape_.data());
            for (int64_t n = a; n < b; ++n) {
                env[n - a] *= 1.0f - weight(n);
            }
            accumulate(ops.source, a, b, env);
        }
    }
}

void AudioMixer::updateHistory(const float *mix, int sequenceFrames) noexcept {
    const int ch = config_.channels;
    const int keep = kDecimatorTaps - 1;
    for (int c = 0; c < ch; ++c) {
        float *h = history_.data() + static_cast<size_t>(c) * keep;
        if (sequenceFrames >= keep) {
            for (int i = 0; i < keep; ++i) {
                h[i] = mix[static_cast<size_t>(sequenceFrames - keep + i) * ch + c];
            }
        } else {
            std::memmove(h, h + sequenceFrames, sizeof(float) * static_cast<size_t>(keep - sequenceFrames));
            for (int i = 0; i < sequenceFrames; ++i) {
                h[keep - sequenceFrames + i] = mix[static_cast<size_t>(i) * ch + c];
            }
        }
    }
}

void AudioMixer::decimate(const float *mix, int outFrames, float *out) noexcept {
    const int ch = config_.channels;
    const int keep = kDecimatorTaps - 1;
    const int sequenceFrames = outFrames * 2;
    for (int c = 0; c < ch; ++c) {
        float *h = history_.data() + static_cast<size_t>(c) * keep;
        float *in = filterIn_.data();
        std::memcpy(in, h, sizeof(float) * static_cast<size_t>(keep));
        for (int i = 0; i < sequenceFrames; ++i) {
            in[keep + i] = mix[static_cast<size_t>(i) * ch + c];
        }
        vDSP_desamp(in, 2, decimatorTaps_.data(), filterOut_.data(), static_cast<vDSP_Length>(outFrames),
                    static_cast<vDSP_Length>(kDecimatorTaps));
        for (int k = 0; k < outFrames; ++k) {
            out[static_cast<size_t>(k) * ch + c] = filterOut_[static_cast<size_t>(k)];
        }
        std::memcpy(h, in + sequenceFrames, sizeof(float) * static_cast<size_t>(keep));
    }
}

void AudioMixer::renderTransport(const Plan &plan, float *out, int frames, uint64_t &missing, bool blend) noexcept {
    const int ch = config_.channels;
    const int rate = plan.audioRate == 2 ? 2 : 1;
    int done = 0;
    while (done < frames) {
        const int chunk = std::min(frames - done, config_.maxChunkFrames);
        const int sequenceFrames = chunk * rate;
        float *mix = mixScratch_.data();
        std::fill(mix, mix + static_cast<size_t>(sequenceFrames) * ch, 0.0f);
        mixChunk(plan, rtPosition_, sequenceFrames, mix, missing, blend && blendPlan_ != nullptr);
        float *o = out + static_cast<size_t>(done) * ch;
        if (rate == 1) {
            std::memcpy(o, mix, sizeof(float) * static_cast<size_t>(sequenceFrames) * ch);
            updateHistory(mix, sequenceFrames); // a later switch to 2x filters across the seam
        } else {
            decimate(mix, chunk, o);
        }
        rtPosition_ += sequenceFrames;
        done += chunk;
        if (blend && blendPlan_) {
            blendDone_ += sequenceFrames;
            if (blendDone_ >= rampFrames_) {
                retire(blendPlan_);
                blendPlan_ = nullptr;
            }
        }
    }
}

void AudioMixer::render(float *interleaved, int frames, int channels, uint64_t hostNanos) noexcept {
    if (!interleaved || frames <= 0 || channels <= 0) {
        return;
    }
    // Adopt the newest plan; retire the old one to the control side.
    if (Plan *next = pending_.exchange(nullptr, std::memory_order_acq_rel)) {
        adopt(next);
    }
    renders_.fetch_add(1, std::memory_order_relaxed);
    const size_t total = static_cast<size_t>(frames) * static_cast<size_t>(channels);
    std::fill(interleaved, interleaved + total, 0.0f);

    const int ch = channels;
    uint64_t missing = 0;
    bool renderedTransport = false;
    int64_t firstTransportSample = -1;
    int64_t liveStart = -1;
    int liveOffset = 0;
    int audioRate = 1;
    if (channels == config_.channels) {
        int offset = 0;
        if (fadePlan_) {
            // The transport that just ended plays on for the rest of its fade-out.
            const int n = std::min(frames, rampFrames_ - fadeDone_);
            firstTransportSample = rtPosition_;
            renderTransport(*fadePlan_, interleaved, n, missing, false);
            for (int k = 0; k < n; ++k) {
                const float g = 1.0f - static_cast<float>(fadeDone_ + k + 1) / static_cast<float>(rampFrames_);
                float *frame = interleaved + static_cast<size_t>(k) * ch;
                for (int c = 0; c < ch; ++c) {
                    frame[c] *= g;
                }
            }
            fadeDone_ += n;
            offset = n;
            renderedTransport = true;
            audioRate = fadePlan_->audioRate;
            if (fadeDone_ >= rampFrames_) {
                retire(fadePlan_);
                fadePlan_ = nullptr;
            }
        }
        const Plan *plan = current_;
        if (!fadePlan_ && plan && plan->running && offset < frames) {
            if (!rtLive_ || plan->baseSerial != rtBaseSerial_) {
                rtLive_ = true;
                rtBaseSerial_ = plan->baseSerial;
                rtPosition_ = plan->startSample;
                rtEpoch_ = plan->clockEpoch;
                std::fill(history_.begin(), history_.end(), 0.0f);
            }
            liveStart = rtPosition_;
            liveOffset = offset;
            if (firstTransportSample < 0) {
                firstTransportSample = rtPosition_;
            }
            renderTransport(*plan, interleaved + static_cast<size_t>(offset) * ch, frames - offset, missing, true);
            renderedTransport = true;
            audioRate = plan->audioRate;
        } else if (!(plan && plan->running)) {
            rtLive_ = false;
        }
    }

    // Output gain (master gain and mute), ramped.
    const float target = muted_.load(std::memory_order_relaxed) ? 0.0f : masterGain_.load(std::memory_order_relaxed);
    if (target != gainTarget_) {
        gainTarget_ = target;
        gainRampLeft_ = rampFrames_;
        gainStep_ = (target - outGain_) / static_cast<float>(rampFrames_);
    }
    int k = 0;
    for (; k < frames && gainRampLeft_ > 0; ++k) {
        outGain_ = --gainRampLeft_ == 0 ? gainTarget_ : outGain_ + gainStep_;
        float *frame = interleaved + static_cast<size_t>(k) * ch;
        for (int c = 0; c < ch; ++c) {
            frame[c] *= outGain_;
        }
    }
    if (k < frames && outGain_ != 1.0f) {
        float *rest = interleaved + static_cast<size_t>(k) * ch;
        vDSP_vsmul(rest, 1, &outGain_, rest, 1, static_cast<vDSP_Length>(static_cast<size_t>(frames - k) * ch));
    }
    const float lo = -1.0f;
    const float hi = 1.0f;
    vDSP_vclip(interleaved, 1, &lo, &hi, interleaved, 1, static_cast<vDSP_Length>(total));

    position_.store(rtPosition_, std::memory_order_release);
    if (firstTransportSample >= 0) {
        lastRenderStart_.store(firstTransportSample, std::memory_order_release);
    }
    rtRunning_.store(renderedTransport, std::memory_order_release);
    rtAudioRate_.store(audioRate, std::memory_order_relaxed);
    renderedFrames_.fetch_add(static_cast<uint64_t>(frames), std::memory_order_relaxed);
    if (missing > 0) {
        underruns_.fetch_add(1, std::memory_order_relaxed);
        underrunFrames_.fetch_add(missing, std::memory_order_relaxed);
    }
    if (!fadePlan_ && current_ && !current_->running) {
        rtStoppedSerial_.store(current_->transportSerial, std::memory_order_release);
    }
    if (clock_ && liveStart >= 0) {
        const uint64_t offsetNanos =
            liveOffset > 0 ? static_cast<uint64_t>(static_cast<double>(liveOffset) * 1e9 / config_.sampleRate) : 0;
        clock_->advanceSamples(frames - liveOffset, hostNanos ? hostNanos + offsetNanos : 0, rtEpoch_, liveStart);
    }
}

} // namespace ve::audio
