// Keyframed Motion: keyframe tracks for a clip's picture placement (VideoParams in Clip.h).
//
// Time base: a keyframe's time is a source time of its clip, the time Clip::exactSourceTimeAt
// maps a timeline time to (for a still, the time into the clip measured from its start). Keyframes
// therefore stay attached to the pictures they were set on: a head or tail trim leaves them where
// they are (keyframes the trim cut off are kept, hidden, and come back when the clip is extended
// again), a speed change moves them on the timeline with their pictures, and a split gives each
// piece the keyframes on its side (see splitTrack). Stills have no source timing, so an edit that
// moves a still's start keeping its end shifts its keyframes to keep them at the same timeline
// positions (Clip::setTimelineStartKeepingEnd).
//
// Values: a parameter without keyframes has its static value. With keyframes the static value is
// not used (as in Premiere Pro): before the first keyframe the parameter holds the first
// keyframe's value, after the last it holds the last one's, and in between it moves from each
// keyframe to the next as the keyframe's interpolation says.
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

#include <array>
#include <cstddef>
#include <optional>
#include <string>
#include <vector>

namespace ve {

// The keyframeable parameters of VideoParams.
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

// "x", "y", "scale", "rotation", "opacity" (the project file's keys).
const char *nameOf(MotionParameter parameter);
// "Position X", "Position Y", "Scale", "Rotation", "Opacity" (messages).
const char *displayNameOf(MotionParameter parameter);

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
    CMTime time = kCMTimeZero; // source time (see the top of this file); an exact model time
    double value = 0.0;        // in VideoParams units (pixels, scale factor, degrees, 0...1)
    KeyframeInterpolation interpolation = KeyframeInterpolation::Linear;
    TimingCurve curve; // used when interpolation is Bezier; the straight line otherwise
};

// Bit-for-bit equality (time identical, values and curve compared exactly).
bool operator==(const Keyframe &a, const Keyframe &b);

// Keyframes of one parameter in strictly increasing time order.
using KeyframeTrack = std::vector<Keyframe>;

struct MotionKeyframes {
    KeyframeTrack x;
    KeyframeTrack y;
    KeyframeTrack scale;
    KeyframeTrack rotation;
    KeyframeTrack opacity;

    KeyframeTrack &track(MotionParameter parameter);
    const KeyframeTrack &track(MotionParameter parameter) const;
    // No parameter has keyframes.
    bool empty() const;
    // Total number of keyframes.
    std::size_t count() const;

    friend bool operator==(const MotionKeyframes &, const MotionKeyframes &) = default;
};

// The value of a parameter with keyframes `track` and static value `staticValue` at source time
// `time` (see the top of this file). The fraction of a segment is computed exactly and converted
// to a double once.
double evaluateTrack(const KeyframeTrack &track, double staticValue, const ExactTime &time);

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
// `staticValue`) the new keyframe holds that value and is Linear, the default for new keyframes.
// Set an explicit value or interpolation on the returned keyframe afterwards. The value can lie
// outside a parameter's range where a custom curve from a project file overshoots it; callers
// validate the track (keyframeTrackProblem).
std::size_t insertKeyframeKeepingValues(KeyframeTrack &track, double staticValue, CMTime time);

// A track cut at source time `at` for the two pieces of a split clip: the left piece keeps the
// keyframes before `at`, the right piece those from `at` on. Where the cut falls between two
// keyframes both pieces get a keyframe at `at` with the value there, and an eased segment's curve
// is divided exactly (splitCurve), so every frame of both pieces shows the value it showed before.
// A piece with no keyframe on its side has a constant value there: it gets no keyframes and that
// value as its static value.
struct TrackSplit {
    KeyframeTrack left;
    KeyframeTrack right;
    double leftStatic = 0.0;
    double rightStatic = 0.0;
};
TrackSplit splitTrack(const KeyframeTrack &track, double staticValue, CMTime at);

// Every keyframe time moved by `delta`. Returns false, changing nothing, when a result has no exact
// CMTime form.
[[nodiscard]] bool shiftTrack(KeyframeTrack &track, CMTime delta);

// Why `track` is not a valid track for `parameter` (times exact model times in strictly
// increasing order, finite values within the parameter's range, valid curves on Bezier keyframes
// and the default curve on the others), or nullopt.
std::optional<std::string> keyframeTrackProblem(const KeyframeTrack &track, MotionParameter parameter);

// Whether `value` is allowed for `parameter` (finite; scale >= 0; opacity within [0, 1]).
bool isValidMotionValue(MotionParameter parameter, double value);

// `value` limited to the parameter's range (scale >= 0, opacity within [0, 1]): a custom timing
// curve may overshoot its keyframes' values.
double clampMotionValue(MotionParameter parameter, double value);

} // namespace ve
