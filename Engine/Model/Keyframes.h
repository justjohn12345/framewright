// Keyframe tracks: the animation machinery inside effect spans (EffectSpan.h).
//
// Time base: a keyframe's time is relative to the start of the span that holds it (EffectSpan
// times are source times of the clip, so keyframes stay on the pictures they were set on through
// trims and speed changes). A span's tracks start with a keyframe at 0 (the span's start value)
// and one at the span's length (its end value); the model allows more in between.
//
// Values: before a track's first keyframe the value holds the first keyframe's value, after the
// last it holds the last one's, and in between it moves from each keyframe to the next as the
// keyframe's interpolation says. An empty track has its parameter's neutral value.
//
// Interpolation belongs to the segment that starts at the keyframe. The ease names follow Premiere
// Pro and Final Cut Pro (not CSS): Ease Out leaves the keyframe slowly and speeds up, Ease In
// slows down to arrive at the next keyframe, Ease In and Out does both (the Ken Burns default).
// The curves are Core Animation's timing functions (control points 0.42 and 0.58). Bezier is a
// custom timing curve: a split through an eased segment gives each piece the exact part of the
// curve it keeps, so a split never changes a single frame's picture.
//
// Plain C++ (CoreMedia's CMTime only): unit-testable without media.

#pragma once

#include "TimeUtil.h"

#include <cstddef>
#include <optional>
#include <string>
#include <vector>

namespace ve {

enum class KeyframeInterpolation {
    Hold,      // the value stays until the next keyframe, then jumps
    Linear,    // constant rate
    EaseOut,   // leaves the keyframe slowly (Core Animation's ease-in curve)
    EaseIn,    // arrives at the next keyframe slowly (Core Animation's ease-out curve)
    EaseInOut, // both
    Bezier,    // a custom timing curve (Keyframe::curve)
};

// "hold", "linear", "easeOut", "easeIn", "easeInOut", "bezier".
const char *nameOf(KeyframeInterpolation interpolation);

// A cubic Bezier timing curve from (0, 0) to (1, 1) with control points (x1, y1) and (x2, y2):
// x is the fraction of the segment's time, y the fraction of its change in value. With x1 and x2
// within [0, 1] x grows monotonically, so the curve is a function of time.
struct TimingCurve {
    double x1 = 0.0;
    double y1 = 0.0;
    double x2 = 1.0;
    double y2 = 1.0;

    friend bool operator==(const TimingCurve &, const TimingCurve &) = default;

    // x1 and x2 within [0, 1] with x1 <= x2 (up to rounding), y1 and y2 finite. With x1 > x2 the
    // parts splitCurve renormalises can have control points outside [0, 1], which it cannot keep.
    bool isValid() const;
    // y at time fraction `fraction` (clamped to [0, 1]).
    double valueAt(double fraction) const;
};

// The curve of an eased interpolation (EaseOut, EaseIn, EaseInOut); the straight line otherwise.
TimingCurve timingCurveFor(KeyframeInterpolation interpolation);

// The two parts of `curve` either side of time fraction `fraction` (strictly inside (0, 1)), each
// renormalised to run from (0, 0) to (1, 1), and the curve's value where it was cut. A part along
// which the value does not change (the cut at a flat end) comes back as nullopt: any curve fits it.
struct CurveSplit {
    std::optional<TimingCurve> before;
    std::optional<TimingCurve> after;
    double valueAtSplit = 0.0;
};
CurveSplit splitCurve(const TimingCurve &curve, double fraction);

struct Keyframe {
    CMTime time = kCMTimeZero; // relative to the span's start (see the top of this file); an exact model time
    double value = 0.0;        // in the parameter's units (pixels, factor, degrees, dB; SpanParameter)
    KeyframeInterpolation interpolation = KeyframeInterpolation::Linear;
    TimingCurve curve; // used when interpolation is Bezier; the straight line otherwise
};

// Bit-for-bit equality (time identical, values and curve compared exactly).
bool operator==(const Keyframe &a, const Keyframe &b);

// Keyframes of one parameter in strictly increasing time order.
using KeyframeTrack = std::vector<Keyframe>;

// The value of a parameter with keyframes `track` at `time` (on the track's time base), or
// `emptyValue` when the track is empty (see the top of this file). The fraction of a segment is
// computed exactly and converted to a double once.
double evaluateTrack(const KeyframeTrack &track, double emptyValue, const ExactTime &time);

// The value the track approaches as time rises to `time` (the limit from the left): the same as
// evaluateTrack except exactly on a keyframe after a Hold segment, where it is the held value (the
// value just before the jump). The end value of a ramp that ends on a keyframe.
double evaluateTrackFromLeft(const KeyframeTrack &track, double emptyValue, const ExactTime &time);

// Index of the keyframe at exactly `time` (numeric comparison), or nullopt.
std::optional<std::size_t> keyframeIndexAt(const KeyframeTrack &track, CMTime time);

// Index of the first keyframe with a time in [from, to), or nullopt.
std::optional<std::size_t> firstKeyframeIn(const KeyframeTrack &track, const ExactTime &from, const ExactTime &to);

// Inserts or replaces (same time) `keyframe`, keeping the track sorted.
void upsertKeyframe(KeyframeTrack &track, const Keyframe &keyframe);

// Adds a keyframe at `time` that changes no value of the track, and returns its index (a keyframe
// already at `time` is left as it is). Inside a segment the segment is divided as a split divides
// it (splitTrack): the new keyframe gets the value there, a hold stays a hold, a linear segment
// stays linear and an eased or custom segment becomes its two exact Bezier parts (shown as Custom).
// Before the first keyframe, after the last one, or on an empty track (where it takes
// `emptyValue`) the new keyframe holds that value and is Linear, the default for new keyframes.
// Set an explicit value or interpolation on the returned keyframe afterwards. The value can lie
// outside a parameter's range where a custom curve from a project file overshoots it; callers
// validate the track (spanTrackProblem).
std::size_t insertKeyframeKeepingValues(KeyframeTrack &track, double emptyValue, CMTime time);

// A track cut at `at` (on the track's time base) for the two pieces of a split span: the left
// piece keeps the keyframes before `at`, the right piece those from `at` on (times unchanged).
// Where the cut falls between two keyframes both pieces get a keyframe at `at` with the value
// there, and an eased segment's curve is divided exactly (splitCurve), so every frame of both
// pieces shows the value it showed before. A piece with no keyframe on its side has a constant
// value there: it gets no keyframes and that value as `leftStatic` / `rightStatic` (an empty
// track gives `emptyValue` to both).
struct TrackSplit {
    KeyframeTrack left;
    KeyframeTrack right;
    double leftStatic = 0.0;
    double rightStatic = 0.0;
};
TrackSplit splitTrack(const KeyframeTrack &track, double emptyValue, CMTime at);

// Every keyframe time moved by `delta`. Returns false, changing nothing, when a result has no exact
// CMTime form.
[[nodiscard]] bool shiftTrack(KeyframeTrack &track, CMTime delta);

// `track` with every keyframe time multiplied by `numerator / denominator` (both positive
// exact times, e.g. a span's new and old length): the keyframes keep their places relative to
// the span. A time without an exact CMTime form goes to the nearest kPreciseTimescale tick (at
// most 0.7 ns away). Nullopt when the times would no longer increase strictly or on overflow.
std::optional<KeyframeTrack> rescaleTrack(const KeyframeTrack &track, CMTime numerator, CMTime denominator);

// Why the times and curves of `track` are not valid (times exact model times in strictly
// increasing order, valid curves on Bezier keyframes and the default curve on the others), or
// nullopt. `what` names the track in the message ("Scale keyframe"). Values are checked by the
// caller (EffectSpan.h, spanTrackProblem).
std::optional<std::string> keyframeTimesProblem(const KeyframeTrack &track, const std::string &what);

} // namespace ve
