// A clip: a range of one asset placed on one track.
//
// Timing model (exact; see TimeUtil.h):
// - `timelineStart` and `timelineDuration` place the clip on the timeline. Both are whole
//   numbers of sequence frames, and the duration is the authoritative length of the clip.
// - `sourceIn` is the first source time used; `speed` is an exact positive ratio (2/1 plays
//   twice as fast). Everything else about the source is derived: source time at timeline time t
//   is sourceIn + (t - timelineStart) * speed, and the source out point (exclusive) is
//   sourceIn + timelineDuration * speed. The derived source times need not be representable as
//   a CMTime (a 44.1 kHz in point at 999/1000 speed on a 29.97 timeline is not), so the model
//   never stores them; exact* accessors return them as ExactTime and the CMTime accessors are
//   for rendering and display (exact when representable, else rounded and flagged).
// - Still-image clips (isStill) have no source timing: sourceIn is zero, speed is 1 and the
//   "source" is the offset into the still's timeline range.
// - Invariants (checked by validateSequence): speed reduced, with a denominator of at most
//   kMaxSpeedDenominator and a value within [kMinSpeed, kMaxSpeed]; sourceIn >= 0 and the
//   derived out point within the asset; start and duration on the sequence frame grid;
//   fadeIn + fadeOut <= duration; every stored time exact (no rounded flag, epoch 0).

#pragma once

#include "Ids.h"
#include "TimeUtil.h"

#include <cstdint>
#include <optional>

namespace ve {

inline constexpr double kMinSpeed = 0.01;
inline constexpr double kMaxSpeed = 100.0;
inline constexpr std::int64_t kMaxSpeedDenominator = 1000;

// True when `speed` is a valid clip speed: reduced, denominator in [1, kMaxSpeedDenominator],
// value within [kMinSpeed, kMaxSpeed] (compared exactly as 1/100 and 100/1).
bool isValidSpeed(Ratio speed);

// The clip speed for a UI value such as 0.999 or 1/3: the best approximation with a
// denominator of at most kMaxSpeedDenominator ({0, 1} for non-positive or non-finite input).
inline Ratio speedFromDouble(double speed) {
    return approximateRatio(speed, kMaxSpeedDenominator);
}

// Duration given to a still-image clip when none is specified.
inline CMTime defaultStillDuration() {
    return CMTimeMake(5, 1);
}

// Placement of a clip's picture in the sequence frame. x/y offset the clip's centre from the
// frame centre in sequence pixels (+y is down); scale 1 draws the source at its fitted size.
struct VideoParams {
    double x = 0.0;
    double y = 0.0;
    double scale = 1.0;
    double rotationDegrees = 0.0;
    double opacity = 1.0; // 0...1

    friend bool operator==(const VideoParams &, const VideoParams &) = default;
};

// Fades are timeline durations. They may not overlap: fadeIn + fadeOut <= the clip's duration,
// so the fade envelope is linear on every piece between its corners. Edits that shorten a clip
// shorten its fades to fit (the fade at the edited edge first).
struct AudioParams {
    double gainDb = 0.0;
    CMTime fadeInDuration = kCMTimeZero;  // linear ramp from silence at the clip start
    CMTime fadeOutDuration = kCMTimeZero; // linear ramp to silence at the clip end
};

bool operator==(const AudioParams &a, const AudioParams &b); // bit-for-bit

enum class ClipEdge {
    Head,
    Tail,
};

struct Clip {
    ClipId id;
    AssetId assetId;
    TrackId trackId;
    CMTime timelineStart = kCMTimeZero;
    CMTime timelineDuration = kCMTimeZero; // authoritative length; whole sequence frames
    CMTime sourceIn = kCMTimeZero;
    Ratio speed{1, 1}; // > 0; 2/1 plays twice as fast
    bool isStill = false;
    std::optional<ClipId> linkedClipId; // symmetric: the partner links back
    VideoParams video;
    AudioParams audio;

    // Speed used for all time mapping ({1, 1} for stills).
    Ratio speedRatio() const {
        return isStill ? Ratio{1, 1} : speed;
    }
    // Speed as a double, for display.
    double speedValue() const {
        return speedRatio().toDouble();
    }

    // Duration on the timeline.
    CMTime duration() const {
        return timelineDuration;
    }
    CMTime timelineEnd() const {
        return timelineStart + timelineDuration;
    }
    TimeRange timelineRange() const {
        return TimeRange{timelineStart, timelineEnd()};
    }

    // Exact source time at timeline time `t` (valid outside the clip too: transition handles).
    // nullopt only if `t` is not numeric or the exact value overflows 128 bits.
    std::optional<ExactTime> exactSourceTimeAt(CMTime t) const;
    // Exact (exclusive) source out point: sourceIn + duration * speed.
    std::optional<ExactTime> exactSourceOut() const;
    // Exact timeline time at which source time `s` plays (inverse of exactSourceTimeAt).
    std::optional<ExactTime> exactTimelineTimeAt(CMTime s) const;

    // CMTime forms of the above for rendering and display: exact when representable, otherwise
    // rounded to kPreciseTimescale and flagged kCMTimeFlags_HasBeenRounded. For stills the source
    // time is the offset into the still's timeline range.
    CMTime sourceTimeAt(CMTime t) const;
    CMTime sourceOut() const;
    CMTime sourceDuration() const; // duration * speed
    CMTime timelineTimeAt(CMTime s) const;

    // Moves the start to `newStart` keeping the end fixed; sourceIn moves by the change times
    // speed. Returns false, leaving the clip unchanged, when the new sourceIn is not exactly
    // representable. Fades are shortened to fit (the fade-in first).
    [[nodiscard]] bool setTimelineStartKeepingEnd(CMTime newStart);

    // Moves the end to `newEnd` keeping the start fixed. Fades are shortened to fit (the
    // fade-out first). Returns false, leaving the clip unchanged, when the new duration is not
    // exactly representable.
    [[nodiscard]] bool setTimelineEnd(CMTime newEnd);

    // Shortens the fades so that each is at most the duration and together they fit; when they
    // overlap, the fade at `editedEdge` gives way first.
    void fitFades(ClipEdge editedEdge);
};

// Bit-for-bit equality of every field.
bool operator==(const Clip &a, const Clip &b);

} // namespace ve
