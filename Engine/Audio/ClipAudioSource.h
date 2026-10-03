// ClipAudioSource: the audio of one clip mapping, decoded ahead of the playhead into a lock-free
// ring buffer, addressed by SEQUENCE sample position.
//
// Mapping. A source renders sequence sample n (at the mixer's sample rate sr) from source media
// time sourceAtZero + (n / sr) * speed, i.e. the clip's own timeline->source mapping
// (Clip::sourceTimeAt) extended to the whole timeline. Two clips with the same asset, speed and
// sourceAtZero on one track (for example the halves of a split) are the same continuous media
// and share one source; the mixer applies each clip's gain envelope on top.
//
// Reverse (AudioSourceMapping::reversed; Clip.h "Reverse"). A reversed clip's sequence sample n reads
// media at mirror - clip time of sample n + 1 (the mirror rule per sample: the mirror of the sample's
// end), i.e. source position mirror * sr - (sourceAtZero * sr + (n + 1) * speed): the forward mapping of
// sequence sample N - 1 - n for the clip's forward form, so the output is the forward output
// sample-reversed. The producer reads the block of source samples that ends at the mirrored position
// (a forward decode) and delivers it back to front; the resampler below runs on the mirrored
// positions, so pitch follows speed as it does forward. Blocks of at least kReverseBlockSeconds are
// decoded at a time (one seek each), since each block lies before the previous one in the file.
//
// Resampling (speed != 1). Constant-speed "tape" resampling by linear interpolation between the
// two nearest decoded source samples, computed in double precision on the producer thread.
// Chosen over AVAudioConverter because it is exactly sample-aligned (source position of every
// output sample is known in closed form, so seeks, envelopes and A/V sync stay sample-accurate),
// has no filter delay or priming to compensate, works for every speed in [0.01, 100] without
// reconfiguration, and is cheap. Trade-off: no anti-aliasing low-pass when speeding up, so
// content above sr / (2 * speed) aliases; acceptable for preview. Pitch follows speed. At speed 1
// the source position is rounded to a whole sample and samples are copied bit-exactly.
//
// Ring buffer protocol (single producer = this source's thread, single consumer = the audio
// render thread):
// - The producer writes frames at writeIndex; the consumer reads at readIndex. Both indices
//   only grow; frame i lives at ring slot i % capacity.
// - Repositioning: anyone may post a request (sequence sample, serial) with reposition(): one
//   lock-free CAS on a packed 64-bit word. The producer answers the newest request by seeking its
//   decoder and publishing a "segment": ring index segmentStart holds sequence sample
//   segmentPosition, and later frames follow contiguously. The consumer adopts the newest
//   segment on its next read (jumping its read index to segmentStart, discarding stale frames),
//   or, while the mixer renders no transport, on its next render callback (adoptNewestSegment):
//   stale frames keep their ring slots until the consumer has skipped them, so a source
//   repositioned twice while stopped (the playhead put down at one place, then another) would
//   otherwise find the ring full of the first place's audio and never get ready for the second.
// - read(pos) is sample-accurate: frames before pos are skipped; when pos is not covered yet the
//   consumer outputs nothing (the caller mixes silence and counts an underrun) and, when pos is
//   out of reach, posts a reposition itself. It never waits.
// - The producer keeps up to `lookahead` seconds decoded past the consumer. Once full it blocks
//   (no timeout, no polling) until the consumer has drained the buffer below `refill` seconds
//   (the consumer signals once when it crosses that level while the producer waits) or a new
//   reposition request arrives. Without a request it blocks until one arrives. So a paused
//   source, or one parked ahead of the playhead, costs no CPU wake-ups at all.
// - Wake-ups use a Mach semaphore: semaphore_signal is a bounded Mach trap that neither
//   allocates nor takes a lock, so the audio render thread may signal it (it does so only when
//   it posts a reposition or crosses the refill level, not per callback).
//
// Threading contract
// - Constructor/destructor: a non-realtime thread. The destructor stops and joins the producer
//   (the decoder is destroyed on the producer thread); it waits for a decoder call in progress,
//   so owners destroy sources off latency-sensitive threads (AudioMixer uses a reaper queue).
// - read(): the audio render thread only (one consumer). Realtime-safe: no locks, no
//   allocation, no Objective-C; its only system call is the occasional semaphore_signal.
// - reposition(), seekTo(): any thread (reposition() is realtime-safe as above; seekTo() is the
//   same call, kept for readability on the control side).
// - isReady(), isPositionedAt(), requestedPosition(), consumerPosition(), producedEnd(),
//   stats(): any non-realtime thread.

#pragma once

#include "../Media/BackendRouter.h"
#include "../Model/Ids.h"
#include "../Model/TimeUtil.h"
#include "Realtime.h"

#include <mach/mach.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace ve::audio {

/// Which media a source plays and how sequence time maps onto it.
struct AudioSourceMapping {
    AssetId asset;
    std::string path; ///< Absolute POSIX path.
    /// Routing from import (saves a probe); probed on the producer thread when absent.
    std::optional<media::RoutedMediaInfo> routed;
    int trackIndex = -1; ///< Audio track of the routed info; -1 = first.
    Ratio speed{1, 1};
    /// Clip time played at sequence time zero (Clip::sourceTimeAt(0)); may be negative. The media
    /// time itself for a forward clip.
    CMTime sourceAtZero = kCMTimeZero;
    /// Plays the media backwards: clip time u reads media time `mirror` - u, by the mirror rule
    /// (see the header comment). `mirror` is the media's end (mediaEndFor) and only used when
    /// reversed.
    bool reversed = false;
    CMTime mirror = kCMTimeInvalid;

    /// Same media, track, speed, offset and direction (numeric comparison).
    bool sameAs(const AudioSourceMapping &other) const;
};

struct ClipAudioSourceConfig {
    double sampleRate = 48000.0;
    int channels = 2;
    double lookaheadSeconds = 2.0; ///< Decode this far ahead of the consumer.
    double refillSeconds = 1.5;    ///< Resume decoding when the buffered audio drops below this.
    double capacitySeconds = 3.0;  ///< Ring size (> lookahead, leaves room after a reposition).
    int chunkFrames = 1024;        ///< Frames produced per decode step.
};

class ClipAudioSource {
  public:
    struct Stats {
        std::string backend; ///< Backend that opened the decoder ("" until opened).
        std::string error;   ///< Open/decode error, if any (the source then plays silence).
        bool opened = false;
        bool failed = false; ///< The decoder could not be opened: the source only plays silence.
        /// A read or seek failed after the decoder opened: the audio from `readFailedAt` (the
        /// earliest sequence sample produced as silence because of it) was not decoded. Playback
        /// keeps playing (silence there, and retries at later positions); an export must fail
        /// (AudioMixer::failedSourceIn).
        bool readFailed = false;
        int64_t readFailedAt = -1;
        uint64_t framesProduced = 0;
        uint64_t repositions = 0;   ///< Segments started by the producer.
        int64_t bufferedFrames = 0; ///< Decoded and not yet consumed.
        uint64_t wakeups = 0;       ///< Times the producer returned from a blocking wait.
    };

    ClipAudioSource(std::shared_ptr<media::BackendRouter> router, AudioSourceMapping mapping,
                    ClipAudioSourceConfig config = {});
    ~ClipAudioSource();
    ClipAudioSource(const ClipAudioSource &) = delete;
    ClipAudioSource &operator=(const ClipAudioSource &) = delete;

    const AudioSourceMapping &mapping() const { return mapping_; }
    const ClipAudioSourceConfig &config() const { return config_; }

    /// Asks the producer to continue from `sequenceSample` (>= 0) and wakes it. Any thread,
    /// realtime-safe.
    void reposition(int64_t sequenceSample) noexcept;
    /// Same as reposition() (control-side spelling).
    void seekTo(int64_t sequenceSample) { reposition(sequenceSample); }

    /// The producer has answered the newest reposition request and has decoded
    /// [sequenceSample, sequenceSample + frames) (or reached a state where it only produces
    /// silence: end of media, open failure).
    bool isReady(int64_t sequenceSample, int64_t frames) const noexcept;
    /// The newest request asks for `sequenceSample` and the consumer has not moved away from it
    /// (it has not adopted that segment yet, or adopted it without consuming). Repositioning
    /// such a source again would only throw decoded audio away.
    bool isPositionedAt(int64_t sequenceSample) const noexcept;
    /// Sequence sample of the newest request (-1 if none).
    int64_t requestedPosition() const noexcept;
    /// Next sequence sample the consumer expects (-1 before its first adopted segment).
    int64_t consumerPosition() const noexcept { return consumerPos_.load(std::memory_order_acquire); }
    /// Sequence sample after the last frame the producer wrote in its current segment.
    int64_t producedEnd() const noexcept { return producedEnd_.load(std::memory_order_acquire); }

    Stats stats() const;

    /// Consumer: copies up to `frames` frames of sequence samples [sequenceSample, ...) into
    /// `dst` (interleaved, config().channels). Returns the number of leading frames written;
    /// the rest of `dst` is left untouched. Audio render thread only.
    int read(int64_t sequenceSample, float *dst, int frames) noexcept;

    /// Consumer, while it reads nothing (the mixer renders no transport): adopts the newest segment
    /// the producer has published, as read() does first, so the frames of older segments free their
    /// ring slots for the producer. Audio render thread only; realtime-safe.
    void adoptNewestSegment() noexcept;

    /// Shortest run of source audio a reversed source decodes at once (see the header comment).
    static constexpr double kReverseBlockSeconds = 0.5;

  private:
    static constexpr uint64_t kSerialMask = 0xFFFF;

    void producerMain();
    bool openDecoder();
    /// Fills `frames` frames of sequence audio starting at `pos` (producer thread).
    void produce(int64_t pos, int frames, float *out);
    /// Source samples [start, start + frames) at the output rate, silence outside the media.
    /// Returns the first source sample that could not be decoded (a failed read or seek; then
    /// silence from there on), or -1.
    int64_t readSource(int64_t start, int64_t frames, float *out);
    /// Like readSource() into the resampler's window; returns its failed source sample or -1.
    int64_t ensureSourceWindow(int64_t first, int64_t lastInclusive);
    /// A reversed source's window: holds [first, lastInclusive], read as one block of at least
    /// kReverseBlockSeconds ending at lastInclusive when it does not; returns a failed source sample or -1.
    int64_t ensureReverseWindow(int64_t first, int64_t lastInclusive);
    /// produce() for a reversed mapping.
    void produceReversed(int64_t pos, int frames, float *out);
    /// Records that sequence sample `at` was produced as silence because the decoder failed.
    void noteReadFailure(int64_t at) noexcept;
    /// Blocks until signalled (producer thread).
    void waitForWork();
    void wake() noexcept;
    /// Publishes the consumer's position and wakes a producer waiting for space once the
    /// buffered level falls below `refill` (render thread).
    void publishConsumer() noexcept;

    const std::shared_ptr<media::BackendRouter> router_;
    const AudioSourceMapping mapping_;
    const ClipAudioSourceConfig config_;
    const int channels_;
    const int64_t capacity_;  // frames
    const int64_t lookahead_; // frames
    const int64_t refill_;    // frames
    // Speed mapping.
    const bool unitSpeed_;
    const int64_t unitOffset_; // source sample = sequence sample + unitOffset_ (speed 1)
    const double offsetSamples_;
    const double step_;
    // Reverse mapping: source position of sequence sample n = mirrorSamples_ - (n + 1) * speed, and at
    // speed 1 source sample unitMirror_ - 1 - n.
    const double mirrorSamples_;
    const int64_t unitMirror_;

    // capacity_ * channels_ floats. Slots are handed over through writeIndex_/readIndex_
    // (release/acquire), so producer writes and consumer reads never touch the same slot.
    std::vector<float> ring_;

    std::atomic<uint64_t> request_{0}; // (sequence sample << 16) | serial; serial 0 = none
    std::atomic<uint64_t> writeIndex_{0};
    std::atomic<uint64_t> readIndex_{0};
    struct Segment {
        uint64_t start = 0;    // ring index of the segment's first frame
        int64_t position = 0;  // its sequence sample
        uint32_t serial = 0;   // the request it answers (0: none yet)
    };
    SeqLock<Segment> segment_; // written by the producer, read by anyone
    std::atomic<int64_t> producedEnd_{-1};
    std::atomic<int64_t> consumerPos_{-1};
    std::atomic<uint32_t> consumerAdopted_{0}; // serial of the segment the consumer adopted
    std::atomic<bool> waitingForSpace_{false};
    std::atomic<uint64_t> wakeups_{0};
    std::atomic<uint64_t> framesProduced_{0};
    std::atomic<uint64_t> repositions_{0};
    std::atomic<bool> opened_{false};
    std::atomic<bool> failed_{false};
    std::atomic<int64_t> readFailedAt_{-1}; // earliest sequence sample of a read failure (-1: none)

    // Consumer-only state (audio render thread).
    uint32_t consumerSerial_ = 0;
    bool consumerValid_ = false;
    uint64_t consumerIndex_ = 0;
    int64_t consumerExpected_ = 0;
    int64_t consumerSegmentPos_ = 0;

    // Producer-only state.
    std::unique_ptr<media::IAudioDecoder> decoder_;
    std::vector<float> scratch_;
    std::vector<float> sourceWindow_; // interleaved source samples for the resampler
    int64_t sourceWindowStart_ = 0;
    int64_t sourceWindowFrames_ = 0;

    mutable std::mutex statsMutex_; // backend_, error_
    std::string backend_;
    std::string error_;

    semaphore_t wakeSemaphore_ = MACH_PORT_NULL;
    std::atomic<bool> stop_{false};
    std::thread thread_;
};

} // namespace ve::audio
