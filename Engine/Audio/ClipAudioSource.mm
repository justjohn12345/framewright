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
    thread_ = std::thread([this] { producerMain(); });
}

ClipAudioSource::~ClipAudioSource() {
    stop_.store(true, std::memory_order_release);
    {
        std::lock_guard<std::mutex> lock(waitMutex_);
        wake_ = true;
    }
    waitCv_.notify_all();
    if (thread_.joinable()) {
        thread_.join();
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
        if (request_.compare_exchange_weak(current, desired, std::memory_order_release, std::memory_order_relaxed)) {
            return;
        }
    }
}

void ClipAudioSource::seekTo(int64_t sequenceSample) {
    reposition(sequenceSample);
    {
        std::lock_guard<std::mutex> lock(waitMutex_);
        wake_ = true;
    }
    waitCv_.notify_one();
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
    s.framesProduced = framesProduced_.load(std::memory_order_relaxed);
    s.repositions = repositions_.load(std::memory_order_relaxed);
    const uint64_t w = writeIndex_.load(std::memory_order_acquire);
    const uint64_t r = readIndex_.load(std::memory_order_acquire);
    s.bufferedFrames = static_cast<int64_t>(w >= r ? w - r : 0);
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
        readIndex_.store(consumerIndex_, std::memory_order_release);
        consumerPos_.store(consumerExpected_, std::memory_order_release);
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
            readIndex_.store(consumerIndex_, std::memory_order_release);
            consumerPos_.store(consumerExpected_, std::memory_order_release);
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
    readIndex_.store(consumerIndex_, std::memory_order_release);
    consumerPos_.store(consumerExpected_, std::memory_order_release);
    return n;
}

// MARK: - Producer

void ClipAudioSource::waitForWork(std::chrono::milliseconds timeout) {
    std::unique_lock<std::mutex> lock(waitMutex_);
    waitCv_.wait_for(lock, timeout, [&] { return wake_ || stop_.load(std::memory_order_acquire); });
    wake_ = false;
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

void ClipAudioSource::readSource(int64_t start, int64_t frames, float *out) {
    int64_t done = 0;
    if (start < 0) {
        const int64_t silent = std::min(frames, -start);
        std::fill(out, out + silent * channels_, 0.0f);
        done = silent;
    }
    if (done < frames && decoder_ && !failed_.load(std::memory_order_relaxed)) {
        const int64_t first = start + done;
        if (decoder_->position() != first) {
            auto status = decoder_->seek(sampleTime(first, config_.sampleRate));
            if (!status.ok()) {
                std::lock_guard<std::mutex> lock(statsMutex_);
                error_ = status.error().description();
            }
        }
        while (done < frames) {
            const int want = static_cast<int>(std::min<int64_t>(frames - done, 1 << 16));
            auto got = decoder_->read(out + done * channels_, want);
            if (!got.ok()) {
                std::lock_guard<std::mutex> lock(statsMutex_);
                error_ = got.error().description();
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
}

void ClipAudioSource::ensureSourceWindow(int64_t first, int64_t lastInclusive) {
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
        readSource(sourceWindowStart_ + sourceWindowFrames_, need,
                   sourceWindow_.data() + sourceWindowFrames_ * channels_);
        sourceWindowFrames_ += need;
    }
}

void ClipAudioSource::produce(int64_t pos, int frames, float *out) {
    if (unitSpeed_) {
        readSource(pos + unitOffset_, frames, out);
        return;
    }
    const double num = static_cast<double>(mapping_.speed.num);
    const double den = static_cast<double>(mapping_.speed.den);
    auto sourceAt = [&](int64_t n) { return offsetSamples_ + static_cast<double>(n) * num / den; };
    const double x0 = sourceAt(pos);
    const double xn = sourceAt(pos + frames - 1);
    const int64_t first = static_cast<int64_t>(std::floor(x0));
    const int64_t last = static_cast<int64_t>(std::floor(xn)) + 1;
    ensureSourceWindow(first, last);
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
            waitForWork(config_.idlePoll);
            continue;
        }

        const uint64_t w = writeIndex_.load(std::memory_order_relaxed);
        const uint64_t r = readIndex_.load(std::memory_order_acquire);
        const int64_t used = static_cast<int64_t>(w - std::min(r, w));
        const int64_t free = capacity_ - used;
        const int64_t buffered = static_cast<int64_t>(w - std::max(r, segmentStart));
        if (!refilling && buffered < refill_) {
            refilling = true;
        }
        if (buffered >= lookahead_ || free <= 0) {
            refilling = false;
        }
        if (!refilling) {
            waitForWork(config_.idlePoll);
            continue;
        }
        const int n = static_cast<int>(std::min<int64_t>({chunk, free, lookahead_ - buffered}));
        if (n <= 0) {
            waitForWork(config_.idlePoll);
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
