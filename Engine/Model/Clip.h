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
#include "Keyframes.h"
#include "TimeUtil.h"

#include <cstddef>
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

// Placement of a clip's picture in the sequence frame (its Motion). x/y offset the clip's centre
// from the frame centre in sequence pixels (+y is down); scale 1 draws the source at its fitted
// size. The five values are the static values; a parameter with keyframes is animated instead
// (Keyframes.h: keyframe times are source times of the clip, and the static value of an animated
// parameter is not used).
struct VideoParams {
    VideoParams() = default;
    // Static values, no keyframes.
    VideoParams(double x_, double y_, double scale_, double rotationDegrees_, double opacity_)
        : x(x_), y(y_), scale(scale_), rotationDegrees(rotationDegrees_), opacity(opacity_) {}

    double x = 0.0;
    double y = 0.0;
    double scale = 1.0;
    double rotationDegrees = 0.0;
    double opacity = 1.0; // 0...1
    MotionKeyframes keyframes;

    friend bool operator==(const VideoParams &, const VideoParams &) = default;

    double staticValue(MotionParameter parameter) const;
    void setStaticValue(MotionParameter parameter, double value);
    bool isAnimated() const {
        return !keyframes.empty();
    }
    bool isAnimated(MotionParameter parameter) const {
        return !keyframes.track(parameter).empty();
    }
    // The value of `parameter` at source time `time`.
    double valueAt(MotionParameter parameter, const ExactTime &time) const;
    // The five values at source time `time`, without keyframes (what a render graph layer shows).
    VideoParams valuesAt(const ExactTime &time) const;
    // The static values without keyframes.
    VideoParams staticValues() const;
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
    // speed. A still's keyframes move by the opposite of the change so they keep their timeline
    // positions (a still's source time is measured from its start; see Keyframes.h). Returns false,
    // leaving the clip unchanged, when the new sourceIn (or a moved keyframe time) is not exactly
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

// ----- Keyframes and sequence frames -----
// The sequence frame starting at timeline time F (frameDuration long) shows the clip's source span
// [sourceTimeAt(F), sourceTimeAt(F + frameDuration)). A keyframe belongs to the frame whose span
// contains its time; the clip's last frame also owns a keyframe exactly on the clip's out point
// (where a split leaves the left piece's last keyframe).

// The start of the clip's frame that shows source time `sourceTime`, or nullopt when no frame of
// the clip does (a keyframe a trim cut off).
std::optional<CMTime> frameShowingSourceTime(const Clip &clip, CMTime sourceTime, CMTime frameDuration);

// Index of the keyframe of `parameter` that the frame starting at `frameStart` shows, or nullopt
// (also when the frame is not one of the clip's).
std::optional<std::size_t> keyframeIndexForFrame(const Clip &clip, MotionParameter parameter, CMTime frameStart,
                                                 CMTime frameDuration);

// The time a keyframe set on the frame starting at `frameStart` gets: the exact source time the
// frame starts on, or, when that has no CMTime form, the first kPreciseTimescale tick after it
// (under 1.5 ns later, well inside the frame's span). Nullopt only on overflow. This is also the
// time the frame's Motion is evaluated at (motionTimeAt), so the frame shows the keyframe's value.
std::optional<CMTime> keyframeTimeForFrame(const Clip &clip, CMTime frameStart);

// The source time at which the clip's Motion at timeline time `t` is evaluated: the exact source
// time when it has a CMTime form, else the first kPreciseTimescale tick after it, the time
// keyframeTimeForFrame gives a keyframe set there. Evaluating at the exact time instead would show
// the previous value on the keyframe's own frame after a Hold (the keyframe lies up to 1.5 ns
// later). Nullopt only for a non-numeric time or on overflow.
std::optional<ExactTime> motionTimeAt(const Clip &clip, CMTime t);

// The five Motion values the clip shows at timeline time `t`, without keyframes (its static values
// when it is not animated, or when `t` has no source time). Scheduler::motionAt and the facade's
// VEClipInfo motion(at:) both return this.
VideoParams motionValuesAt(const Clip &clip, CMTime t);

} // namespace ve
