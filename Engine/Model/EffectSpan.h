// Effect spans: time ranges on a clip's lanes, each with start and end values for what it changes.
//
// Lanes. Every clip has up to kLaneCount lanes (the track draws them under the clip). Lane 0 holds
// the clip's transitions (SpanKind::Transition, see Transition.h), lanes 1-3 its effect spans
// (Motion and Opacity on video tracks, Gain on audio tracks). Spans of one clip on one lane never
// overlap; spans on different lanes may, and their effects compose (Clip.h, motionValuesAt).
//
// Time base. An effect span's [start, end) is in the clip's source-time base, like its pictures:
// the source time Clip::exactSourceTimeAt maps a timeline time to (for a still, the time into the
// clip). A trim therefore leaves a span on its pictures (one that cuts through a span clips it,
// the value at the new edge evaluated exactly; extending the clip again does not restore what was
// cut), a speed change moves it on the timeline with its pictures, and a split divides it exactly
// (splitSpan). A span lies within its clip's used source range. A transition span's start and end
// are sequence-time offsets from the edge it is attached to instead (Transition.h), because a
// transition stays on its cut and on the frame grid whatever the clip's speed.
//
// Values. A span holds keyframe tracks (Keyframes.h) for the parameters of its kind only, with
// times relative to its start: normally a keyframe at 0 (the start value) and one at the span's
// length (the end value); the model allows more. A span's values are relative: position and
// rotation are offsets added to the clip's static values, scale and opacity factors multiplied
// with them, gain decibels added to the clip's gain (Clip.h). The neutral values (0, 1, 0 dB)
// change nothing, which is what a new span starts with.
//
// Activity (hold after). An effect span contributes nothing to the frames before its start,
// animates over [start, end), and from its end on holds its end value until the clip ends: at
// source time t >= start it contributes its value at min(t, end) (spanContributionAt). A later span
// on the same lane does not end the hold but applies on top of it: spans on one lane are
// cumulative, so a span that starts at neutral values continues the held picture without a jump,
// and one that starts elsewhere jumps from it. (Clip.h, composeMotion, defines "on top of".) In
// transition handles (frames of a transition outside the clip) the source time is held at the
// clip's nearest edge: a tail handle keeps the values held at the clip's end, a head handle shows
// the spans that start on the clip's in point at their start values.
//
// Plain C++ (CoreMedia's CMTime only): unit-testable without media.

#pragma once

#include "Ids.h"
#include "Keyframes.h"
#include "TimeUtil.h"
#include "Transition.h"

#include <array>
#include <optional>
#include <string>
#include <vector>

namespace ve {

// An end of a clip on its track.
enum class ClipEdge {
    Head,
    Tail,
};

// "head", "tail".
const char *nameOf(ClipEdge edge);

inline constexpr int kLaneCount = 4;
inline constexpr int kTransitionLane = 0;
inline constexpr int kFirstEffectLane = 1;
inline constexpr int kLastLane = kLaneCount - 1;

enum class SpanKind {
    Transition, // lane 0 only: a cross dissolve / crossfade or a fade (Transition.h)
    Motion,     // video: position X/Y, scale, rotation
    Opacity,    // video: opacity (a video fade)
    Gain,       // audio: level in dB
};

// "transition", "motion", "opacity", "gain" (the project file's names).
const char *nameOf(SpanKind kind);
// "Transition", "Motion", "Opacity", "Gain" (messages).
const char *displayNameOf(SpanKind kind);

// The parameters a span can animate.
enum class SpanParameter {
    X,        // pixels added to the clip's x
    Y,        // pixels added to the clip's y
    Scale,    // factor the clip's scale is multiplied with
    Rotation, // degrees added to the clip's rotation
    Opacity,  // factor the clip's opacity is multiplied with (0...1)
    Gain,     // decibels added to the clip's gain
};

inline constexpr std::array<SpanParameter, 6> kSpanParameters{SpanParameter::X,        SpanParameter::Y,
                                                              SpanParameter::Scale,    SpanParameter::Rotation,
                                                              SpanParameter::Opacity,  SpanParameter::Gain};

// "x", "y", "scale", "rotation", "opacity", "gain" (the project file's keys).
const char *nameOf(SpanParameter parameter);
// "Position X", "Position Y", "Scale", "Rotation", "Opacity", "Gain" (messages).
const char *displayNameOf(SpanParameter parameter);
// The value that changes nothing: 0 for X, Y, Rotation and Gain, 1 for Scale and Opacity.
double neutralValue(SpanParameter parameter);
// Whether `value` is allowed for `parameter`: finite; scale >= 0; opacity within [0, 1].
bool isValidSpanValue(SpanParameter parameter, double value);
// `value` limited to the parameter's range (a custom timing curve may overshoot its keyframes).
double clampSpanValue(SpanParameter parameter, double value);
// The parameters of `kind`, in SpanParameter order (none for a transition).
std::vector<SpanParameter> parametersOf(SpanKind kind);
// Whether spans of `kind` animate `parameter`.
bool kindHasParameter(SpanKind kind, SpanParameter parameter);

// Keyframe tracks of a span, one per parameter (only the span kind's may be non-empty).
struct SpanTracks {
    KeyframeTrack x;
    KeyframeTrack y;
    KeyframeTrack scale;
    KeyframeTrack rotation;
    KeyframeTrack opacity;
    KeyframeTrack gain;

    KeyframeTrack &track(SpanParameter parameter);
    const KeyframeTrack &track(SpanParameter parameter) const;
    // No track has keyframes.
    bool empty() const;

    friend bool operator==(const SpanTracks &, const SpanTracks &) = default;
};

struct EffectSpan {
    SpanId id;
    int lane = kFirstEffectLane;
    SpanKind kind = SpanKind::Motion;
    // Effect spans: [start, end) in the clip's source-time base (exact model times, start < end).
    // Transition spans: offsets in sequence time from the edge: a tail span covers
    // [clip end + start, clip end + end] (start <= 0 <= end), a head span
    // [clip start, clip start + end] (start == 0 < end).
    CMTime start = kCMTimeZero;
    CMTime end = kCMTimeZero;
    ClipEdge edge = ClipEdge::Tail;                     // transition spans only (Tail for effect spans)
    TransitionKind transition = TransitionKind::CrossDissolve; // transition spans only
    SpanTracks tracks;                                  // effect spans only; times relative to `start`

    bool isTransition() const {
        return kind == SpanKind::Transition;
    }
};

// Bit-for-bit equality of every field.
bool operator==(const EffectSpan &a, const EffectSpan &b);

// The value of `parameter` of an effect span at `time` (the clip's source-time base): its track
// evaluated at `time - start` (holding before the first and after the last keyframe), limited to
// the parameter's range; the neutral value when the span has no keyframes for it.
double spanValueAt(const EffectSpan &span, SpanParameter parameter, const ExactTime &time);

// The value spanValueAt approaches as `time` rises to it (evaluateTrackFromLeft): the end value of
// a ramp over a piece of the span that ends at `time`.
double spanValueFromLeft(const EffectSpan &span, SpanParameter parameter, const ExactTime &time);

// The value of `parameter` at the span's start (`atEnd` false) or end (true).
double spanEdgeValue(const EffectSpan &span, SpanParameter parameter, bool atEnd);

// Whether the effect span contributes at `time` (the clip's source-time base): from its start on,
// through its range and after its end (where it holds its end value). Never for a transition span.
bool spanActsAt(const EffectSpan &span, const ExactTime &time);

// The value of `parameter` the effect span contributes at `time`: nothing (the neutral value)
// before its start, spanValueAt over [start, end), and its end value (spanValueAt at `end`) from
// its end on.
double spanContributionAt(const EffectSpan &span, SpanParameter parameter, const ExactTime &time);

// The value spanContributionAt approaches as `time` rises to it: the neutral value up to and at the
// span's start, spanValueFromLeft after it up to its end (the end of a ramp over a piece ending at
// `time`), the end value after it (the hold).
double spanContributionFromLeft(const EffectSpan &span, SpanParameter parameter, const ExactTime &time);

// How the span moves between its keyframes: the interpolation every segment of every track shares
// (Linear when no track has a segment), Bezier (a custom curve, shown as Custom) when the segments
// differ or are custom parts of a split.
KeyframeInterpolation spanInterpolation(const EffectSpan &span);

// Why the tracks of the effect span `span` are invalid (a track of a parameter its kind does not
// have, keyframe times not exact and increasing, a keyframe before 0 or after the span's length,
// values outside the parameter's range, curves), or nullopt. Transition spans must have no tracks.
std::optional<std::string> spanTracksProblem(const EffectSpan &span);

// Why an effect span could not be cut (splitSpan, clipSpan).
enum class SpanCutProblem {
    None,
    NotRepresentable, // a time of a part has no exact CMTime form
    CurveOvershoot,   // a custom timing curve (from a project file) goes outside a parameter's range at the cut
};

// The two parts of an effect span cut at source time `at` (strictly inside it): the left part
// keeps its id and covers [start, at), the right part (id left invalid for the caller to assign)
// covers [at, end) with its tracks re-based to start at 0. Each track is divided exactly
// (splitTrack): a keyframe at the cut with the value there on both sides, an eased segment's curve
// divided into its exact parts; a side left without keyframes gets one at its start holding the
// constant value it had. So the parts show every frame exactly as the span did. Nullopt when `at`
// is not strictly inside, and on a SpanCutProblem (reported through `problem` when given).
struct SpanSplit {
    EffectSpan left;
    EffectSpan right;
};
std::optional<SpanSplit> splitSpan(const EffectSpan &span, CMTime at, SpanCutProblem *problem = nullptr);

// The effect span limited to [from, to] (source times): unchanged when it lies inside; the part
// inside when it crosses an end (divided like splitSpan); nullopt when nothing of it is inside, or
// on a SpanCutProblem (reported through `problem`, None when the span simply lies outside).
std::optional<EffectSpan> clipSpan(const EffectSpan &span, CMTime from, CMTime to, SpanCutProblem *problem = nullptr);

} // namespace ve
