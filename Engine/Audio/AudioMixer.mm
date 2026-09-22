#include "AudioMixer.h"

#include <Accelerate/Accelerate.h>

#include <algorithm>
#include <cmath>
#include <thread>

namespace ve::audio {

namespace {

constexpr float kHalfPi = static_cast<float>(M_PI / 2.0);

} // namespace

AudioMixer::AudioMixer(std::shared_ptr<media::BackendRouter> router, Clock *clock, AudioMixerConfig config)
    : router_(std::move(router)), clock_(clock), config_([&] {
          AudioMixerConfig c = config;
          c.channels = std::clamp(c.channels, 1, 8);
          c.maxChunkFrames = std::max(64, c.maxChunkFrames);
          if (!(c.sampleRate > 0)) {
              c.sampleRate = 48000.0;
          }
          return c;
      }()),
      maxSequenceFrames_(config_.maxChunkFrames * 2) {
    const size_t samples = static_cast<size_t>(maxSequenceFrames_) * static_cast<size_t>(config_.channels);
    mixScratch_.assign(samples, 0.0f);
    readScratch_.assign(samples, 0.0f);
    envelope_.assign(static_cast<size_t>(maxSequenceFrames_), 0.0f);
    ramp_.assign(static_cast<size_t>(maxSequenceFrames_), 0.0f);
    shape_.assign(static_cast<size_t>(maxSequenceFrames_), 0.0f);
}

AudioMixer::~AudioMixer() {
    std::lock_guard<std::mutex> lock(mutex_);
    drainRetired();
    Plan *pending = pending_.exchange(nullptr, std::memory_order_acq_rel);
    if (pending != current_) {
        delete pending;
    }
    delete current_;
    current_ = nullptr;
    latest_ = nullptr;
    sources_.clear();
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

void AudioMixer::drainRetired() {
    Plan *plan = nullptr;
    while (retired_.pop(plan)) {
        delete plan;
    }
}

std::unique_ptr<AudioMixer::Plan> AudioMixer::copyLatest() const {
    if (!latest_) {
        return std::make_unique<Plan>();
    }
    return std::make_unique<Plan>(*latest_);
}

void AudioMixer::publish(std::unique_ptr<Plan> plan) {
    drainRetired();
    Plan *raw = plan.release();
    Plan *unadopted = pending_.exchange(raw, std::memory_order_acq_rel);
    delete unadopted; // the render thread never saw it
    latest_ = raw;
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
        mapping.speed = approximateRatio(segment.speed, kMaxSpeedDenominator);
        if (mapping.speed.num <= 0) {
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

    for (Group &group : groups) {
        std::shared_ptr<ClipAudioSource> source;
        for (const SourceEntry &entry : sources_) {
            if (entry.track == group.track && entry.source->mapping().sameAs(group.mapping)) {
                source = entry.source;
                break;
            }
        }
        if (!source) {
            source = std::make_shared<ClipAudioSource>(router_, group.mapping, sourceConfig);
            source->seekTo(std::max(group.spanStart, playhead));
            ++sourcesCreated_;
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
        nextSources.push_back(SourceEntry{group.track, source});
    }
    // Sources that dropped out of the plan stay alive through the plans that still reference
    // them and are destroyed (joining their producer) when those are retired, on this side.
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
    plan->running = audioRate == 1 || audioRate == 2;
    plan->audioRate = plan->running ? audioRate : 1;
    plan->startSample = sampleFor(at);
    plan->clockEpoch = clockEpoch;
    publish(std::move(plan));
}

void AudioMixer::stop() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::unique_ptr<Plan> plan = copyLatest();
    plan->transportSerial = ++transportSerial_;
    plan->running = false;
    publish(std::move(plan));
}

bool AudioMixer::isRunning() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return latest_ && latest_->running;
}

bool AudioMixer::prime(CMTime at, std::chrono::milliseconds timeout) {
    struct Wait {
        std::shared_ptr<ClipAudioSource> source;
        int64_t from = 0;
        int64_t frames = 0;
    };
    std::vector<Wait> waits;
    const int64_t s = sampleFor(at);
    const int64_t window = std::max<int64_t>(1, static_cast<int64_t>(config_.primeSeconds * config_.sampleRate));
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (latest_) {
            for (size_t i = 0; i < latest_->sources.size(); ++i) {
                const PlanSource &ps = latest_->sources[i];
                if (ps.spanEnd <= s || ps.spanStart >= s + window) {
                    continue;
                }
                const int64_t from = std::max(ps.spanStart, s);
                waits.push_back(Wait{latest_->owners[i], from, std::min(window, ps.spanEnd - from)});
            }
        }
    }
    for (const Wait &w : waits) {
        w.source->seekTo(w.from);
    }
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    for (;;) {
        const bool ready = std::all_of(waits.begin(), waits.end(),
                                       [](const Wait &w) { return w.source->isReady(w.from, w.frames); });
        if (ready) {
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

void AudioMixer::setMasterGain(float gain) {
    masterGain_.store(std::max(0.0f, gain), std::memory_order_relaxed);
}

float AudioMixer::masterGain() const {
    return masterGain_.load(std::memory_order_relaxed);
}

AudioMixer::Stats AudioMixer::stats() const {
    Stats s;
    s.renders = renders_.load(std::memory_order_relaxed);
    s.renderedFrames = renderedFrames_.load(std::memory_order_relaxed);
    s.underruns = underruns_.load(std::memory_order_relaxed);
    s.underrunFrames = underrunFrames_.load(std::memory_order_relaxed);
    s.planSwaps = planSwaps_.load(std::memory_order_relaxed);
    s.retireOverflows = retireOverflows_.load(std::memory_order_relaxed);
    s.position = position_.load(std::memory_order_acquire);
    s.running = rtRunning_.load(std::memory_order_acquire);
    s.audioRate = rtAudioRate_.load(std::memory_order_relaxed);
    std::lock_guard<std::mutex> lock(mutex_);
    s.sourcesCreated = sourcesCreated_;
    for (const SourceEntry &entry : sources_) {
        const ClipAudioSource::Stats st = entry.source->stats();
        s.sources.push_back(SourceInfo{entry.source->mapping().asset, entry.track, st.backend, st.error, st.failed,
                                       st.bufferedFrames, st.repositions});
    }
    return s;
}

// MARK: - Realtime

void AudioMixer::mixChunk(const Plan &plan, int64_t position, int frames, float *mix, uint64_t &missing) noexcept {
    const int ch = config_.channels;
    const int64_t end = position + frames;
    for (const PlanSource &ps : plan.sources) {
        const int64_t a = std::max(position, ps.spanStart);
        const int64_t b = std::min(end, ps.spanEnd);
        if (a >= b) {
            continue;
        }
        const int len = static_cast<int>(b - a);
        const int offset = static_cast<int>(a - position);
        float *tmp = readScratch_.data();
        const int got = ps.source->read(a, tmp, len);
        if (got < len) {
            std::fill(tmp + static_cast<size_t>(got) * ch, tmp + static_cast<size_t>(len) * ch, 0.0f);
            missing += static_cast<uint64_t>(len - got);
        }

        float *env = envelope_.data();
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
            vDSP_vramp(&g0, &gStep, ramp_.data(), 1, k);
            if (seg.crossfade) {
                const float c0 =
                    static_cast<float>(seg.crossfadeStart + (seg.crossfadeEnd - seg.crossfadeStart) * into / length);
                const float cStep = static_cast<float>((seg.crossfadeEnd - seg.crossfadeStart) / length);
                vDSP_vramp(&c0, &cStep, shape_.data(), 1, k);
                vDSP_vsmul(shape_.data(), 1, &kHalfPi, shape_.data(), 1, k);
                const int count = static_cast<int>(k);
                vvsinf(shape_.data(), shape_.data(), &count);
                vDSP_vmul(ramp_.data(), 1, shape_.data(), 1, ramp_.data(), 1, k);
            }
            float *dst = env + (sa - a);
            vDSP_vadd(dst, 1, ramp_.data(), 1, dst, 1, k);
        }
        float *out = mix + static_cast<size_t>(offset) * ch;
        for (int c = 0; c < ch; ++c) {
            vDSP_vma(tmp + c, ch, env, 1, out + c, ch, out + c, ch, static_cast<vDSP_Length>(len));
        }
    }
}

void AudioMixer::render(float *interleaved, int frames, int channels, uint64_t hostNanos) noexcept {
    if (!interleaved || frames <= 0 || channels <= 0) {
        return;
    }
    // Adopt the newest plan; retire the old one to the control side.
    if (Plan *next = pending_.exchange(nullptr, std::memory_order_acq_rel)) {
        if (current_ && !retired_.push(current_)) {
            retireOverflows_.fetch_add(1, std::memory_order_relaxed); // leaked rather than freed here
        }
        current_ = next;
        planSwaps_.fetch_add(1, std::memory_order_relaxed);
    }
    renders_.fetch_add(1, std::memory_order_relaxed);
    const size_t total = static_cast<size_t>(frames) * static_cast<size_t>(channels);
    std::fill(interleaved, interleaved + total, 0.0f);

    const Plan *plan = current_;
    if (!plan || !plan->running || channels != config_.channels) {
        rtRunning_.store(false, std::memory_order_release);
        return;
    }
    if (plan->transportSerial != rtTransportSerial_) {
        rtTransportSerial_ = plan->transportSerial;
        rtPosition_ = plan->startSample;
        rtEpoch_ = plan->clockEpoch;
    }
    rtRunning_.store(true, std::memory_order_release);
    rtAudioRate_.store(plan->audioRate, std::memory_order_relaxed);
    lastRenderStart_.store(rtPosition_, std::memory_order_release);

    const int rate = plan->audioRate;
    const int ch = channels;
    uint64_t missing = 0;
    int done = 0;
    while (done < frames) {
        const int chunk = std::min(frames - done, config_.maxChunkFrames);
        const int sequenceFrames = chunk * rate;
        float *out = interleaved + static_cast<size_t>(done) * ch;
        if (rate == 1) {
            mixChunk(*plan, rtPosition_, sequenceFrames, out, missing);
        } else {
            float *mix = mixScratch_.data();
            std::fill(mix, mix + static_cast<size_t>(sequenceFrames) * ch, 0.0f);
            mixChunk(*plan, rtPosition_, sequenceFrames, mix, missing);
            for (int k = 0; k < chunk; ++k) {
                const float *a = mix + static_cast<size_t>(k) * rate * ch;
                for (int c = 0; c < ch; ++c) {
                    float sum = 0.0f;
                    for (int r = 0; r < rate; ++r) {
                        sum += a[r * ch + c];
                    }
                    out[static_cast<size_t>(k) * ch + c] = sum / static_cast<float>(rate);
                }
            }
        }
        rtPosition_ += sequenceFrames;
        done += chunk;
    }

    const float gain = masterGain_.load(std::memory_order_relaxed);
    if (gain != 1.0f) {
        vDSP_vsmul(interleaved, 1, &gain, interleaved, 1, static_cast<vDSP_Length>(total));
    }
    const float lo = -1.0f;
    const float hi = 1.0f;
    vDSP_vclip(interleaved, 1, &lo, &hi, interleaved, 1, static_cast<vDSP_Length>(total));

    position_.store(rtPosition_, std::memory_order_release);
    renderedFrames_.fetch_add(static_cast<uint64_t>(frames), std::memory_order_relaxed);
    if (missing > 0) {
        underruns_.fetch_add(1, std::memory_order_relaxed);
        underrunFrames_.fetch_add(missing, std::memory_order_relaxed);
    }
    if (clock_) {
        clock_->advanceSamples(frames, hostNanos, rtEpoch_);
    }
}

} // namespace ve::audio
