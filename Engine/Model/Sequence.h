// A sequence (timeline): video and audio tracks. Transitions are lane-0 spans of the clips that own
// them (Transition.h); placeTransition resolves one in its sequence.

#pragma once

#include "Ids.h"
#include "TimeUtil.h"
#include "Track.h"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace ve {

// Where a clip lives inside a sequence.
struct ClipLocation {
    TrackKind trackKind = TrackKind::Video;
    std::size_t trackIndex = 0; // index into videoTracks or audioTracks
    std::size_t clipIndex = 0;  // index into that track's clips
};

// A sequence's settings: its frame grid, frame size and audio sample rate, and whether they were
// chosen. A new project's sequence starts at the defaults (1920x1080, 30 fps, 48 kHz) and not
// configured: the first video clip placed on it sets its size (the picture's displayed size, after
// the container's rotation) and frame rate (formatAdoptedFrom), and configures it, in the same undo
// step as the placement. Stills and sound never do. The Sequence Settings sheet sets them (and
// configures the sequence) explicitly. Every other sequence, a loaded one included (older files
// have none unconfigured), is configured and never adopts anything.
struct SequenceFormat {
    CMTime frameDuration = CMTimeMake(1, 30);
    std::int32_t width = 1920;
    std::int32_t height = 1080;
    std::int32_t audioSampleRate = 48000;
    bool configured = true;

    friend bool operator==(const SequenceFormat &a, const SequenceFormat &b) {
        return identical(a.frameDuration, b.frameDuration) && a.width == b.width && a.height == b.height &&
               a.audioSampleRate == b.audioSampleRate && a.configured == b.configured;
    }
};

// The frame rates a sequence is offered (the Sequence Settings sheet) and adopts, slowest first:
// 23.976, 24, 25, 29.97, 30, 50, 59.94 and 60 fps, as exact frame durations (1001/24000 ...).
const std::vector<CMTime> &standardFrameDurations();

// The standard frame duration for a source running at `framesPerSecond` (a constant rate's own, or
// a variable-rate source's nominal one: the rate of its shortest frame interval, as the prober
// reports it):
//   - up to 60 fps (60.06, a hair above 59.94's NTSC neighbour): the nearest standard rate on a log
//     scale (so 29.97 stays 29.97 and 30.01 becomes 30), except that a rate below 23.976 by more
//     than 0.5 % takes the slowest standard rate that is a whole multiple of it within 0.05 % (15 and
//     10 -> 30, 14.985 -> 29.97, 12.5 -> 25, 20 -> 60; 30 when none is), so each source frame shows
//     a whole number of times;
//   - above 60 fps (high frame rate: 100, 119.88, 120, 240): the standard rate the source rate is
//     a whole multiple of (within 0.05 %: 100 -> 50, 119.88 -> 59.94, 120 and 240 -> 60), else 60.
//     A sequence never runs faster than 60 fps (the monitors and the export are paced for it);
//     such a source plays on it at its normal speed with frames skipped evenly.
// Nullopt for a rate that is not finite and positive, and for one above kMaxFramesPerSecond: no
// picture rate, but a container's time base read as one (Matroska and WebM tick in milliseconds, so two
// frames a tick apart read as 1000 fps; 1000 is a multiple of 50, which it used to adopt).
inline constexpr double kMaxFramesPerSecond = 240.0;
std::optional<CMTime> standardFrameDurationFor(double framesPerSecond);

// "23.976", "24", "25", "29.97", "30", "50", "59.94", "60" (another rate: to 3 decimals, trailing
// zeros dropped).
std::string frameRateName(CMTime frameDuration);

inline constexpr std::int32_t kMinSequenceSide = 16;
inline constexpr std::int32_t kMaxSequenceSide = 16384;
inline constexpr std::int32_t kMinSequenceSampleRate = 8000;
inline constexpr std::int32_t kMaxSequenceSampleRate = 192000;

// Why `format` cannot be a sequence's settings, or nullopt: a frame rate outside 1 to 240 fps (an
// exact positive frame duration), sides outside kMinSequenceSide to kMaxSequenceSide or odd (video
// encoders need even sides), a sample rate outside 8 to 192 kHz. A sentence for the user.
std::optional<std::string> sequenceFormatProblem(const SequenceFormat &format);

// The configured settings a caller asks for with wider integers (the Sequence Settings sheet's).
// A size or sample rate outside the model's integers is clamped to 0 or INT32_MAX, which
// sequenceFormatProblem refuses, so an out-of-range request is refused rather than wrapped.
SequenceFormat requestedSequenceFormat(std::int64_t width, std::int64_t height, CMTime frameDuration,
                                       std::int64_t audioSampleRate);

struct MediaAsset;

// The settings an unconfigured sequence takes from its first video clip's asset, configured: the
// displayed size (after the rotation; an odd side rounded down to even, so the compositor shows the
// picture pixel exact with its spare column or row cropped) and the standard frame rate
// for the asset's (standardFrameDurationFor; `current`'s when the asset has no frame duration or no usable
// rate),
// with `current`'s audio sample rate. A size sequenceFormatProblem refuses (a side under 16 or over
// 16384 pixels) keeps `current`'s size. Nullopt for stills and sound (and a video without a size).
std::optional<SequenceFormat> formatAdoptedFrom(const MediaAsset &asset, const SequenceFormat &current);

struct Sequence {
    SequenceId id;
    std::string name;
    CMTime frameDuration = CMTimeMake(1, 30); // the timeline frame grid
    std::int32_t width = 1920;
    std::int32_t height = 1080;
    std::int32_t audioSampleRate = 48000;
    // Whether the settings above were chosen (SequenceFormat): false only for a new project's
    // sequence until its first video clip or the Sequence Settings sheet sets them.
    bool configured = true;
    std::vector<Track> videoTracks; // bottom to top (later tracks draw over earlier ones)
    std::vector<Track> audioTracks;

    // End of the last clip on any track.
    CMTime duration() const;

    SequenceFormat format() const;
    void setFormat(const SequenceFormat &format);
    // No clip on any track.
    bool isEmpty() const;

    std::vector<Track> &tracks(TrackKind kind) {
        return kind == TrackKind::Video ? videoTracks : audioTracks;
    }
    const std::vector<Track> &tracks(TrackKind kind) const {
        return kind == TrackKind::Video ? videoTracks : audioTracks;
    }

    const Track *findTrack(TrackId trackId) const;
    Track *findTrack(TrackId trackId);

    std::optional<ClipLocation> locateClip(ClipId clipId) const;
    const Clip *findClip(ClipId clipId) const;
    Clip *findClip(ClipId clipId);
    // The track holding `clipId`, or nullptr.
    const Track *trackOfClip(ClipId clipId) const;
    Track *trackOfClip(ClipId clipId);

    // The effect span with `spanId` on any clip, or nullptr; `owner` / `track` receive where it lives.
    const EffectSpan *findSpan(SpanId spanId, const Clip **owner = nullptr, const Track **track = nullptr) const;
    EffectSpan *findSpan(SpanId spanId, Clip **owner = nullptr, Track **track = nullptr);
    // The transition with `spanId` on any clip, or nullptr; `owner` / `track` receive where it lives.
    const TransitionSpan *findTransition(SpanId spanId, const Clip **owner = nullptr,
                                         const Track **track = nullptr) const;
    TransitionSpan *findTransition(SpanId spanId, Clip **owner = nullptr, Track **track = nullptr);
    // Whether a clip of the sequence has a span (either kind) with `spanId`.
    bool hasSpan(SpanId spanId) const {
        return findSpan(spanId) != nullptr || findTransition(spanId) != nullptr;
    }
};

// Bit-for-bit equality of every field.
bool operator==(const Sequence &a, const Sequence &b);

// The clip of `track` touching `clip` at `edge`: the one ending exactly where it starts (Head) or
// starting exactly where it ends (Tail); nullptr when there is none (a gap, the track's end).
const Clip *touchingClip(const Track &track, const Clip &clip, ClipEdge edge);

// A transition span resolved in its sequence.
struct TransitionPlacement {
    const Track *track = nullptr;
    const Clip *owner = nullptr;
    const TransitionSpan *span = nullptr;
    TransitionRole role = TransitionRole::FadeOut;
    // CrossDissolve: the clip touching the owner's end (nullptr when none touches it: the span is
    // then invalid, see checkTransitionSpan).
    const Clip *partner = nullptr;
    CMTime cut = kCMTimeZero; // the owner's end (tail span) or start (head span)
    TimeRange range;          // the timeline range the span covers
};

// Where the lane-0 span `span` of `owner` (on `track`) acts. Nullopt when the times cannot be
// added (only for invalid spans).
std::optional<TransitionPlacement> placeTransition(const Track &track, const Clip &owner, const TransitionSpan &span);

// The transition acting at timeline time `t` on `track`: the tail span of the clip at `t` or of the
// clip touching its start, or its head span, whose range contains `t`; nullopt when none does.
std::optional<TransitionPlacement> transitionAt(const Track &track, CMTime t);

} // namespace ve
