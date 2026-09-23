#include "ClipAudioSource.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace ve::audio {

namespace {

int64_t secondsToFrames(double seconds, double rate) {
    return std::max<int64_t>(1, static_cast<int64_t>(std::llround(seconds * rate)));
}

CMTime sampleTime(int64_t sample, double rate) {
    if (rate == std::floor(rate) && rate <= 0x7FFFFFFF) {
        return CMTimeMake(sample, static_cast<int32_t>(rate));
    }
    return CMTimeMakeWithSeconds(static_cast<double>(sample) / rate, kPreciseTimescale);
}

} // namespace

bool AudioSourceMapping::sameAs(const AudioSourceMapping &other) const {
    return asset == other.asset && path == other.path && trackIndex == other.trackIndex && speed == other.speed &&
           CMTimeCompare(sourceAtZero, other.sourceAtZero) == 0;
}

ClipAudioSource::ClipAudioSource(std::shared_ptr<media::BackendRouter> router, AudioSourceMapping mapping,
                                 ClipAudioSourceConfig config)
    : router_(std::move(router)), mapping_(std::move(mapping)), config_(config),
      channels_(std::max(1, config.channels)),
      capacity_(secondsToFrames(std::max(config.capacitySeconds, config.lookaheadSeconds + 0.5), config.sampleRate)),
      lookahead_(secondsToFrames(config.lookaheadSeconds, config.sampleRate)),
      refill_(secondsToFrames(std::min(config.refillSeconds, config.lookaheadSeconds), config.sampleRate)),
      unitSpeed_(mapping_.speed.num == mapping_.speed.den),
      unitOffset_(static_cast<int64_t>(std::llround(CMTimeGetSeconds(mapping_.sourceAtZero) * config.sampleRate))),
      offsetSamples_(CMTimeGetSeconds(mapping_.sourceAtZero) * config.sampleRate),
      step_(mapping_.speed.toDouble()) {
    ring_.assign(static_cast<size_t>(capacity_ * channels_), 0.0f);
    scratch_.assign(static_cast<size_t>(std::max(1, config_.chunkFrames) * channels_), 0.0f);
    if (semaphore_create(mach_task_self(), &wakeSemaphore_, SYNC_POLICY_FIFO, 0) != KERN_SUCCESS) {
        wakeSemaphore_ = MACH_PORT_NULL; // the producer then falls back to short sleeps (see waitForWork)
    }
    thread_ = std::thread([this] { producerMain(); });
}

ClipAudioSource::~ClipAudioSource() {
    stop_.store(true, std::memory_order_release);
    wake();
    if (thread_.joinable()) {
        thread_.join();
    }
    if (wakeSemaphore_ != MACH_PORT_NULL) {
        semaphore_destroy(mach_task_self(), wakeSemaphore_);
    }
}

// MARK: - Requests

void ClipAudioSource::reposition(int64_t sequenceSample) noexcept {
    const uint64_t position = static_cast<uint64_t>(std::max<int64_t>(0, sequenceSample));
    uint64_t current = request_.load(std::memory_order_relaxed);
    for (;;) {
        uint64_t serial = ((current & kSerialMask) + 1) & kSerialMask;
        if (serial == 0) {
            serial = 1;
        }
        const uint64_t desired = (position << 16) | serial;
        if (request_.compare_exchange_weak(current, desired, std::memory_order_seq_cst, std::memory_order_relaxed)) {
            break;
        }
    }
    wake();
}

void ClipAudioSource::wake() noexcept {
    if (wakeSemaphore_ != MACH_PORT_NULL) {
        semaphore_signal(wakeSemaphore_);
    }
}

int64_t ClipAudioSource::requestedPosition() const noexcept {
    const uint64_t request = request_.load(std::memory_order_acquire);
    return (request & kSerialMask) == 0 ? -1 : static_cast<int64_t>(request >> 16);
}

bool ClipAudioSource::isPositionedAt(int64_t sequenceSample) const noexcept {
    const uint64_t request = request_.load(std::memory_order_acquire);
    const uint32_t serial = static_cast<uint32_t>(request & kSerialMask);
    if (serial == 0 || static_cast<int64_t>(request >> 16) != std::max<int64_t>(0, sequenceSample)) {
        return false;
    }
    return consumerAdopted_.load(std::memory_order_acquire) != serial ||
           consumerPos_.load(std::memory_order_acquire) == std::max<int64_t>(0, sequenceSample);
}

bool ClipAudioSource::isReady(int64_t sequenceSample, int64_t frames) const noexcept {
    const uint64_t request = request_.load(std::memory_order_acquire);
    const uint32_t serial = static_cast<uint32_t>(request & kSerialMask);
    const Segment segment = segment_.load();
    if (serial == 0 || segment.serial != serial) {
        return false;
    }
    const int64_t end = producedEnd_.load(std::memory_order_acquire);
    return segment.position <= sequenceSample && end >= sequenceSample + frames;
}

ClipAudioSource::Stats ClipAudioSource::stats() const {
    Stats s;
    {
        std::lock_guard<std::mutex> lock(statsMutex_);
        s.backend = backend_;
        s.error = error_;
    }
    s.opened = opened_.load(std::memory_order_acquire);
    s.failed = failed_.load(std::memory_order_acquire);
    s.readFailedAt = readFailedAt_.load(std::memory_order_acquire);
    s.readFailed = s.readFailedAt >= 0;
    s.framesProduced = framesProduced_.load(std::memory_order_relaxed);
    s.repositions = repositions_.load(std::memory_order_relaxed);
    const uint64_t w = writeIndex_.load(std::memory_order_acquire);
    const uint64_t r = readIndex_.load(std::memory_order_acquire);
    s.bufferedFrames = static_cast<int64_t>(w >= r ? w - r : 0);
    s.wakeups = wakeups_.load(std::memory_order_relaxed);
    return s;
}

// MARK: - Consumer (audio render thread)

int ClipAudioSource::read(int64_t pos, float *dst, int frames) noexcept {
    if (frames <= 0) {
        return 0;
    }
    const int64_t far = lookahead_;

    // Adopt the newest segment the producer published.
    const Segment segment = segment_.load();
    if (segment.serial != 0 && segment.serial != consumerSerial_) {
        consumerSerial_ = segment.serial;
        consumerValid_ = true;
        consumerIndex_ = segment.start;
        consumerExpected_ = segment.position;
        consumerSegmentPos_ = segment.position;
        consumerAdopted_.store(segment.serial, std::memory_order_release);
        publishConsumer();
    }

    // A request the producer has not answered yet: wait for it unless it is useless for `pos`.
    const uint64_t request = request_.load(std::memory_order_acquire);
    const uint32_t requestSerial = static_cast<uint32_t>(request & kSerialMask);
    if (requestSerial == 0 || !consumerValid_) {
        if (requestSerial == 0) {
            reposition(pos);
        }
        return 0;
    }
    if (requestSerial != consumerSerial_) {
        const int64_t requested = static_cast<int64_t>(request >> 16);
        if (pos + far < requested || pos > requested + far) {
            reposition(pos);
        }
        return 0;
    }

    const uint64_t written = writeIndex_.load(std::memory_order_acquire);
    int64_t available = static_cast<int64_t>(written - consumerIndex_);
    if (pos < consumerExpected_) {
        // Either the segment starts ahead of us (a source positioned for an upcoming clip):
        // silence until we get there unless it is far away; or we jumped back behind audio
        // already consumed: start over at `pos`.
        const bool untouched = consumerExpected_ == consumerSegmentPos_;
        if (!untouched || consumerExpected_ - pos > far) {
            reposition(pos);
        }
        return 0;
    }
    const int64_t skip = pos - consumerExpected_;
    if (skip > available) {
        // The producer is behind: drop what it has and let it catch up (decoding is faster than
        // real time), or start over when it is hopelessly behind.
        if (skip - available > far) {
            reposition(pos);
        } else {
            consumerIndex_ = written;
            consumerExpected_ += available;
            publishConsumer();
        }
        return 0;
    }
    consumerIndex_ += static_cast<uint64_t>(skip);
    consumerExpected_ = pos;
    available -= skip;

    const int n = static_cast<int>(std::min<int64_t>(frames, available));
    int copied = 0;
    while (copied < n) {
        const int64_t slot = static_cast<int64_t>((consumerIndex_ + static_cast<uint64_t>(copied)) %
                                                  static_cast<uint64_t>(capacity_));
        const int run = static_cast<int>(std::min<int64_t>(n - copied, capacity_ - slot));
        std::memcpy(dst + static_cast<size_t>(copied) * channels_, ring_.data() + slot * channels_,
                    sizeof(float) * static_cast<size_t>(run) * channels_);
        copied += run;
    }
    consumerIndex_ += static_cast<uint64_t>(n);
    consumerExpected_ += n;
    publishConsumer();
    return n;
}

void ClipAudioSource::publishConsumer() noexcept {
    // seq_cst store/load pair against the producer's flag store/readIndex load (see
    // producerMain): either the producer sees the drained level or this sees its flag.
    readIndex_.store(consumerIndex_, std::memory_order_seq_cst);
    consumerPos_.store(consumerExpected_, std::memory_order_release);
    if (waitingForSpace_.load(std::memory_order_seq_cst)) {
        const uint64_t written = writeIndex_.load(std::memory_order_acquire);
        const int64_t buffered = static_cast<int64_t>(written - std::min(written, consumerIndex_));
        if (buffered < refill_ && waitingForSpace_.exchange(false, std::memory_order_acq_rel)) {
            wake();
        }
    }
}

// MARK: - Producer

void ClipAudioSource::waitForWork() {
    if (wakeSemaphore_ != MACH_PORT_NULL) {
        // Spurious returns (KERN_ABORTED) just re-run the producer loop.
        (void)semaphore_wait(wakeSemaphore_);
    } else {
        std::this_thread::sleep_for(std::chrono::milliseconds(5)); // no semaphore: degrade to polling
    }
    wakeups_.fetch_add(1, std::memory_order_relaxed);
}

bool ClipAudioSource::openDecoder() {
    auto fail = [&](const std::string &message) {
        {
            std::lock_guard<std::mutex> lock(statsMutex_);
            error_ = message;
        }
        failed_.store(true, std::memory_order_release);
        return false;
    };
    if (!router_) {
        return fail("no backend router");
    }
    media::RoutedMediaInfo routed;
    if (mapping_.routed) {
        routed = *mapping_.routed;
    } else {
        auto probed = router_->probe(mapping_.path);
        if (!probed.ok()) {
            return fail(probed.error().description());
        }
        routed = std::move(probed).value();
    }
    media::AudioOptions options;
    options.sampleRate = config_.sampleRate;
    options.channels = channels_;
    auto decoder = router_->makeAudioDecoder(routed, mapping_.trackIndex, options);
    if (!decoder.ok()) {
        return fail(decoder.error().description());
    }
    decoder_ = std::move(decoder->decoder);
    {
        std::lock_guard<std::mutex> lock(statsMutex_);
        backend_ = decoder->backend;
    }
    opened_.store(true, std::memory_order_release);
    return true;
}

void ClipAudioSource::noteReadFailure(int64_t at) noexcept {
    at = std::max<int64_t>(0, at);
    int64_t current = readFailedAt_.load(std::memory_order_relaxed);
    while ((current < 0 || at < current) &&
           !readFailedAt_.compare_exchange_weak(current, at, std::memory_order_release, std::memory_order_relaxed)) {
    }
}

int64_t ClipAudioSource::readSource(int64_t start, int64_t frames, float *out) {
    int64_t failedAt = -1;
    int64_t done = 0;
    if (start < 0) {
        const int64_t silent = std::min(frames, -start);
        std::fill(out, out + silent * channels_, 0.0f);
        done = silent;
    }
    if (done < frames && decoder_ && !failed_.load(std::memory_order_relaxed)) {
        const int64_t first = start + done;
        bool positioned = true;
        if (decoder_->position() != first) {
            auto status = decoder_->seek(sampleTime(first, config_.sampleRate));
            if (!status.ok()) {
                std::lock_guard<std::mutex> lock(statsMutex_);
                error_ = status.error().description();
                positioned = false; // reading on would deliver audio from the wrong place
                failedAt = first;
            }
        }
        while (positioned && done < frames) {
            const int want = static_cast<int>(std::min<int64_t>(frames - done, 1 << 16));
            auto got = decoder_->read(out + done * channels_, want);
            if (!got.ok()) {
                std::lock_guard<std::mutex> lock(statsMutex_);
                error_ = got.error().description();
                failedAt = start + done;
                break;
            }
            if (*got <= 0) {
                break; // end of media
            }
            done += *got;
        }
    }
    if (done < frames) {
        std::fill(out + done * channels_, out + frames * channels_, 0.0f);
    }
    return failedAt;
}

int64_t ClipAudioSource::ensureSourceWindow(int64_t first, int64_t lastInclusive) {
    const int64_t windowEnd = sourceWindowStart_ + sourceWindowFrames_;
    if (sourceWindowFrames_ == 0 || first < sourceWindowStart_ || first > windowEnd) {
        sourceWindowStart_ = first;
        sourceWindowFrames_ = 0;
    } else if (first > sourceWindowStart_) {
        const int64_t drop = first - sourceWindowStart_;
        std::memmove(sourceWindow_.data(), sourceWindow_.data() + drop * channels_,
                     sizeof(float) * static_cast<size_t>((sourceWindowFrames_ - drop) * channels_));
        sourceWindowStart_ = first;
        sourceWindowFrames_ -= drop;
    }
    const int64_t need = lastInclusive + 1 - (sourceWindowStart_ + sourceWindowFrames_);
    if (need > 0) {
        const size_t size = static_cast<size_t>((sourceWindowFrames_ + need) * channels_);
        if (sourceWindow_.size() < size) {
            sourceWindow_.resize(size);
        }
        const int64_t failedAt = readSource(sourceWindowStart_ + sourceWindowFrames_, need,
                                            sourceWindow_.data() + sourceWindowFrames_ * channels_);
        sourceWindowFrames_ += need;
        return failedAt;
    }
    return -1;
}

void ClipAudioSource::produce(int64_t pos, int frames, float *out) {
    if (unitSpeed_) {
        if (const int64_t failedAt = readSource(pos + unitOffset_, frames, out); failedAt >= 0) {
            noteReadFailure(failedAt - unitOffset_);
        }
        return;
    }
    const double num = static_cast<double>(mapping_.speed.num);
    const double den = static_cast<double>(mapping_.speed.den);
    auto sourceAt = [&](int64_t n) { return offsetSamples_ + static_cast<double>(n) * num / den; };
    const double x0 = sourceAt(pos);
    const double xn = sourceAt(pos + frames - 1);
    const int64_t first = static_cast<int64_t>(std::floor(x0));
    const int64_t last = static_cast<int64_t>(std::floor(xn)) + 1;
    if (const int64_t failedAt = ensureSourceWindow(first, last); failedAt >= 0) {
        // The first output sample that interpolates from the failed source sample (from
        // floor(x) and floor(x) + 1): x + 1 >= failedAt.
        const double n = std::ceil((static_cast<double>(failedAt) - 1.0 - offsetSamples_) * den / num);
        noteReadFailure(std::clamp<int64_t>(static_cast<int64_t>(n), pos, pos + frames - 1));
    }
    const float *window = sourceWindow_.data();
    for (int k = 0; k < frames; ++k) {
        const double x = sourceAt(pos + k);
        const double base = std::floor(x);
        const int64_t i = static_cast<int64_t>(base) - sourceWindowStart_;
        const double f = x - base;
        const float *a = window + i * channels_;
        const float *b = a + channels_;
        float *o = out + static_cast<size_t>(k) * channels_;
        for (int c = 0; c < channels_; ++c) {
            o[c] = static_cast<float>(a[c] + f * (b[c] - a[c]));
        }
    }
}

void ClipAudioSource::producerMain() {
    openDecoder();

    uint32_t handled = 0;
    bool haveSegment = false;
    bool refilling = true;
    int64_t position = 0;
    uint64_t segmentStart = 0;
    const int chunk = std::max(1, config_.chunkFrames);

    while (!stop_.load(std::memory_order_acquire)) {
        const uint64_t request = request_.load(std::memory_order_acquire);
        const uint32_t serial = static_cast<uint32_t>(request & kSerialMask);
        if (serial != 0 && serial != handled) {
            handled = serial;
            position = static_cast<int64_t>(request >> 16);
            segmentStart = writeIndex_.load(std::memory_order_relaxed);
            sourceWindowFrames_ = 0;
            producedEnd_.store(position, std::memory_order_release);
            segment_.store(Segment{segmentStart, position, serial});
            repositions_.fetch_add(1, std::memory_order_relaxed);
            haveSegment = true;
            refilling = true;
        }
        if (!haveSegment) {
            waitForWork(); // until the first request
            continue;
        }

        const uint64_t w = writeIndex_.load(std::memory_order_relaxed);
        struct Level {
            int64_t free = 0;
            int64_t buffered = 0;
        };
        // Stale frames of an older segment the consumer has not skipped yet still occupy the
        // ring (`free`) but do not count as buffered audio.
        auto levelAt = [&](uint64_t r) {
            return Level{capacity_ - static_cast<int64_t>(w - std::min(r, w)),
                         static_cast<int64_t>(w - std::min(w, std::max(r, segmentStart)))};
        };
        const Level level = levelAt(readIndex_.load(std::memory_order_acquire));
        if (!refilling && level.buffered < refill_) {
            refilling = true;
        }
        if (level.buffered >= lookahead_) {
            refilling = false;
        }
        const int n = refilling && level.free > 0
                          ? static_cast<int>(std::min<int64_t>({chunk, level.free, lookahead_ - level.buffered}))
                          : 0;
        if (n <= 0) {
            // Nothing to do until the consumer drains below the refill level (or frees stale
            // frames by adopting the segment) or a request arrives. Publish the flag, then
            // re-check: the seq_cst pair with publishConsumer guarantees that either this sees
            // the consumer's progress or the consumer sees the flag and signals.
            waitingForSpace_.store(true, std::memory_order_seq_cst);
            const Level again = levelAt(readIndex_.load(std::memory_order_seq_cst));
            const bool canWork =
                again.free > 0 && (refilling ? again.buffered < lookahead_ : again.buffered < refill_);
            const bool requested = (request_.load(std::memory_order_acquire) & kSerialMask) != handled;
            if (!canWork && !requested) {
                waitForWork();
            }
            waitingForSpace_.store(false, std::memory_order_relaxed);
            continue;
        }
        produce(position, n, scratch_.data());
        // A newer request arrived while decoding: drop this chunk.
        if ((request_.load(std::memory_order_acquire) & kSerialMask) != handled) {
            continue;
        }
        int copied = 0;
        while (copied < n) {
            const int64_t slot =
                static_cast<int64_t>((w + static_cast<uint64_t>(copied)) % static_cast<uint64_t>(capacity_));
            const int run = static_cast<int>(std::min<int64_t>(n - copied, capacity_ - slot));
            std::memcpy(ring_.data() + slot * channels_, scratch_.data() + static_cast<size_t>(copied) * channels_,
                        sizeof(float) * static_cast<size_t>(run) * channels_);
            copied += run;
        }
        writeIndex_.store(w + static_cast<uint64_t>(n), std::memory_order_release);
        position += n;
        producedEnd_.store(position, std::memory_order_release);
        framesProduced_.fetch_add(static_cast<uint64_t>(n), std::memory_order_relaxed);
    }
    decoder_.reset();
}

} // namespace ve::audio
