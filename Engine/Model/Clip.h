// A clip: a range of one asset placed on one track, with its effect spans.
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
// - Effect spans (EffectSpan.h) live in `spans`: lane-0 transitions (Transition.h) and lanes 1-3
//   effects, which compose onto the static values (motionValuesAt, gainDbAt), each holding its end
//   value from its end to the clip's end.
// - Invariants (checked by validateSequence): speed reduced, with a denominator of at most
//   kMaxSpeedDenominator and a value within [kMinSpeed, kMaxSpeed]; sourceIn >= 0 and the
//   derived out point within the asset; start and duration on the sequence frame grid; every
//   stored time exact (no rounded flag, epoch 0); the spans' own invariants (Validation.h).

#pragma once

#include "EffectSpan.h"
#include "Ids.h"
#include "TimeUtil.h"

#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

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

// The Motion parameters of a clip's static placement (VideoParams).
enum class MotionParameter {
    X,
    Y,
    Scale,
    Rotation,
    Opacity,
};

inline constexpr std::array<MotionParameter, 5> kMotionParameters{
    MotionParameter::X, MotionParameter::Y, MotionParameter::Scale, MotionParameter::Rotation,
    MotionParameter::Opacity};

// "x", "y", "scale", "rotation", "opacity".
const char *nameOf(MotionParameter parameter);
// "Position X", "Position Y", "Scale", "Rotation", "Opacity" (messages).
const char *displayNameOf(MotionParameter parameter);
// The span parameter that animates `parameter` (same name).
SpanParameter spanParameterOf(MotionParameter parameter);

// Placement of a clip's picture in the sequence frame (its Motion). x/y offset the clip's centre
// from the frame centre in sequence pixels (+y is down); scale 1 draws the source at its fitted
// size. These are the clip's static values; its Motion and Opacity spans compose onto them
// (motionValuesAt).
struct VideoParams {
    VideoParams() = default;
    VideoParams(double x_, double y_, double scale_, double rotationDegrees_, double opacity_)
        : x(x_), y(y_), scale(scale_), rotationDegrees(rotationDegrees_), opacity(opacity_) {}

    double x = 0.0;
    double y = 0.0;
    double scale = 1.0;
    double rotationDegrees = 0.0;
    double opacity = 1.0; // 0...1

    friend bool operator==(const VideoParams &, const VideoParams &) = default;

    double staticValue(MotionParameter parameter) const;
    void setStaticValue(MotionParameter parameter, double value);
};

// A clip's static audio level; its Gain spans add to it (gainDbAt) and its lane-0 spans fade or
// crossfade it (Transition.h).
struct AudioParams {
    double gainDb = 0.0;

    friend bool operator==(const AudioParams &, const AudioParams &) = default;
};

// What a change of a clip's timing did to its spans (Clip::setTimelineStartKeepingEnd and friends).
enum class RetimeResult {
    Ok,
    // A new time (sourceIn, a span edge or keyframe) has no exact CMTime form; nothing changed.
    NotRepresentable,
    // A span's custom timing curve (from a project file) overshoots its parameter's range where the
    // new edge cuts it, so the span cannot be clipped there without changing the picture; nothing
    // changed.
    SpanCurveOvershoot,
    // The values spans left before the new start hold would not be finite once folded into the
    // static values (fitSpans), so they cannot be kept; nothing changed.
    HeldValuesOverflow,
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
    // Lane 0 (transitions, at most one per edge) then lanes 1-3, each by start (sortSpans).
    std::vector<EffectSpan> spans;

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

    // The source range effect spans must lie in: [sourceIn, source out] (a still's [0, duration]).
    // When the out point has no CMTime form the bound is the kPreciseTimescale tick before it (under
    // 1.5 ns inside; no frame starts in between). Nullopt only on overflow.
    std::optional<std::pair<CMTime, CMTime>> spanBounds() const;

    // Moves the start to `newStart` keeping the end fixed; sourceIn moves by the change times
    // speed. A still's effect spans move by the opposite of the change so they keep their timeline
    // positions (a still's source time is measured from its start). Then fitSpans(Head).
    // On a failure nothing changes.
    [[nodiscard]] RetimeResult setTimelineStartKeepingEnd(CMTime newStart);

    // Moves the end to `newEnd` keeping the start fixed, then fitSpans(Tail). On a failure nothing
    // changes.
    [[nodiscard]] RetimeResult setTimelineEnd(CMTime newEnd);

    // Brings the spans back within the clip after its range changed: effect spans are clipped to
    // spanBounds() (clipSpan: the value at a new edge evaluated exactly; a span left with nothing
    // inside is removed), and lane-0 fades are shortened to fit the clip (when a head fade and the
    // tail span together no longer fit, the fade at `editedEdge` gives way first; a cross dissolve
    // at the tail is never shortened here: SequenceCommand drops one that no longer fits). A fade
    // shortened to nothing is removed. An effect span left wholly before the new start (its end at
    // or before the in bound) still held its end value over every remaining frame, so that value is
    // folded into the static values before it goes (composed onto them as composeMotion and
    // composeGainDb do, in lane and start order): no remaining frame changes. On a failure nothing
    // changes.
    [[nodiscard]] RetimeResult fitSpans(ClipEdge editedEdge);

    // Orders the spans: lane 0 (head, then tail), then lanes 1-3, each by start.
    void sortSpans();

    // The span with `id`, or nullptr.
    const EffectSpan *findSpan(SpanId spanId) const;
    EffectSpan *findSpan(SpanId spanId);
    // The lane-0 transition span at `edge`, or nullptr.
    const EffectSpan *transitionAt(ClipEdge edge) const;
    EffectSpan *transitionAt(ClipEdge edge);
    // Whether the clip has any span on lanes 1-3.
    bool hasEffectSpans() const;
};

// Bit-for-bit equality of every field.
bool operator==(const Clip &a, const Clip &b);

// ----- Frames and source times -----
// The sequence frame starting at timeline time F (frameDuration long) shows the clip's source span
// [sourceTimeAt(F), sourceTimeAt(F + frameDuration)); its picture is evaluated at the frame's start
// (motionTimeAt).

// The start of the clip's frame that shows source time `sourceTime` (the clip's last frame also
// for its out point), or nullopt when no frame of the clip does.
std::optional<CMTime> frameShowingSourceTime(const Clip &clip, CMTime sourceTime, CMTime frameDuration);

// The source time at which the clip's picture at timeline time `t` is evaluated: the exact source
// time when it has a CMTime form, else the first kPreciseTimescale tick after it. Nullopt only for
// a non-numeric time or on overflow.
std::optional<ExactTime> motionTimeAt(const Clip &clip, CMTime t);

// The source time a span edge set at timeline time `t` (a frame boundary of the clip) gets: the
// exact source time, or the first kPreciseTimescale tick after it when that has no CMTime form
// (the time motionTimeAt evaluates the frame starting there at, so a span starting there covers
// that frame), limited to spanBounds() (so an edge on the clip's end is its out bound). Nullopt
// for a non-numeric time or on overflow.
std::optional<CMTime> spanTimeAt(const Clip &clip, CMTime t);

// The source time the clip's spans are evaluated at for timeline time `t`: motionTimeAt held
// within spanBounds(), so a frame of a transition handle (outside the clip) is evaluated at the
// clip's nearest edge (a tail handle at the out bound, where every span holds its end value).
// Nullopt only for a non-numeric time or on overflow.
std::optional<ExactTime> spanEvaluationTime(const Clip &clip, CMTime t);

// ----- Composition -----
// At source time `time` (a spanEvaluationTime) every effect span that has started (spanActsAt:
// start <= time) contributes its value at min(time, end) (spanContributionAt): the moving value
// inside its range, its end value held after it. Spans that have not started contribute nothing.
// The contributions are applied to the clip's static values one after another, lane 1, 2, 3 and,
// within a lane, in start order ("on top of" one another):
//   - Position X, Position Y and Rotation: offsets, added;
//   - Scale and Opacity: factors, multiplied;
//   - Gain (audio): decibels, added to the static gain.
// So on one lane a span that follows another applies its relative values on top of the value the
// earlier one holds (a span starting neutral continues it without a jump), and spans on different
// lanes combine the same way (a zoom on one lane with a pan on another). `except` leaves one span
// out (what the rest of the composition contributes: the Ken Burns plan and matching use it).

VideoParams composeMotion(const Clip &clip, const ExactTime &time, std::optional<SpanId> except = std::nullopt);
double composeGainDb(const Clip &clip, const ExactTime &time, std::optional<SpanId> except = std::nullopt);

// The Motion the clip shows at timeline time `t` (its static values when `t` has no source time).
// Scheduler::motionAt and the facade's VEClipInfo motion(at:) both return this.
VideoParams motionValuesAt(const Clip &clip, CMTime t);

// The clip's audio level in dB at timeline time `t`.
double gainDbAt(const Clip &clip, CMTime t);

// ----- A span's edges as the Ken Burns move reads and writes them -----
// The time the rest of the clip is composed at for an edge of `span`: its start (`atEnd` false),
// or the spanEvaluationTime of its last frame (the sequence frame, `frameDuration` long, starting
// before the timeline time of its end; not before the clip's first frame). The rest includes what
// earlier spans hold there, on its own lane as on the others (so the start edge of a span that
// follows another on its lane reads that span's held end value). Nullopt when a time has no exact
// form.
std::optional<ExactTime> spanEdgeFrameTime(const Clip &clip, const EffectSpan &span, CMTime frameDuration, bool atEnd);

// The Motion an edge of the Motion span `span` shows: the clip's other spans composed at
// spanEdgeFrameTime (with what they hold there) and `span` at its start or end values
// (spanEdgeValue) applied on top. The Ken Burns move (planKenBurns) sets the span's values from the
// same composition, so reading them back gives the framings exactly. The start framing is what the
// span's first frame shows; the end framing is reached at its end and, from there on, held on the
// frames where nothing else changes (on those frames motionValuesAt equals it). Nullopt for a span
// of another kind or a time with no exact form.
std::optional<VideoParams> spanEdgeMotion(const Clip &clip, const EffectSpan &span, CMTime frameDuration, bool atEnd);

} // namespace ve
