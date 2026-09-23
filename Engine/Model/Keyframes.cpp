#include "Keyframes.h"

#include "Validation.h"

#include <algorithm>
#include <cmath>

namespace ve {

namespace {

struct Point {
    double x = 0.0;
    double y = 0.0;
};

Point lerp(Point a, Point b, double t) {
    return Point{a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t};
}

double cubic(double p1, double p2, double t) {
    const double u = 1.0 - t;
    return 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t;
}

// The curve parameter at which x reaches `fraction` (x is monotonic for x1, x2 in [0, 1]).
double parameterForX(const TimingCurve &curve, double fraction) {
    double lo = 0.0;
    double hi = 1.0;
    for (int i = 0; i < 64 && hi - lo > 1e-15; ++i) {
        const double mid = 0.5 * (lo + hi);
        if (cubic(curve.x1, curve.x2, mid) < fraction) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    return 0.5 * (lo + hi);
}

// into / length as a double, from their exact values (both positive for a segment).
double ratio(const ExactTime &into, const ExactTime &length) {
    Int128 numerator = 0;
    Int128 denominator = 0;
    if (!__builtin_mul_overflow(into.numerator(), length.denominator(), &numerator) &&
        !__builtin_mul_overflow(into.denominator(), length.numerator(), &denominator) && denominator != 0) {
        return static_cast<double>(numerator) / static_cast<double>(denominator);
    }
    const double total = length.toDouble();
    return total != 0.0 ? into.toDouble() / total : 0.0;
}

// Value between keyframes `from` and `to` at segment fraction `fraction` in [0, 1).
double segmentValue(const Keyframe &from, const Keyframe &to, double fraction) {
    switch (from.interpolation) {
    case KeyframeInterpolation::Hold:
        return from.value;
    case KeyframeInterpolation::Linear:
        return from.value + (to.value - from.value) * fraction;
    case KeyframeInterpolation::EaseOut:
    case KeyframeInterpolation::EaseIn:
    case KeyframeInterpolation::EaseInOut:
        return from.value + (to.value - from.value) * timingCurveFor(from.interpolation).valueAt(fraction);
    case KeyframeInterpolation::Bezier:
        return from.value + (to.value - from.value) * from.curve.valueAt(fraction);
    }
    return from.value;
}

} // namespace

const char *nameOf(MotionParameter parameter) {
    switch (parameter) {
    case MotionParameter::X:
        return "x";
    case MotionParameter::Y:
        return "y";
    case MotionParameter::Scale:
        return "scale";
    case MotionParameter::Rotation:
        return "rotation";
    case MotionParameter::Opacity:
        return "opacity";
    }
    return "x";
}

const char *displayNameOf(MotionParameter parameter) {
    switch (parameter) {
    case MotionParameter::X:
        return "Position X";
    case MotionParameter::Y:
        return "Position Y";
    case MotionParameter::Scale:
        return "Scale";
    case MotionParameter::Rotation:
        return "Rotation";
    case MotionParameter::Opacity:
        return "Opacity";
    }
    return "Position X";
}

const char *nameOf(KeyframeInterpolation interpolation) {
    switch (interpolation) {
    case KeyframeInterpolation::Hold:
        return "hold";
    case KeyframeInterpolation::Linear:
        return "linear";
    case KeyframeInterpolation::EaseOut:
        return "easeOut";
    case KeyframeInterpolation::EaseIn:
        return "easeIn";
    case KeyframeInterpolation::EaseInOut:
        return "easeInOut";
    case KeyframeInterpolation::Bezier:
        return "bezier";
    }
    return "linear";
}

bool TimingCurve::isValid() const {
    return std::isfinite(x1) && std::isfinite(x2) && std::isfinite(y1) && std::isfinite(y2) && x1 >= 0.0 &&
           x1 <= 1.0 && x2 >= 0.0 && x2 <= 1.0;
}

double TimingCurve::valueAt(double fraction) const {
    if (!(fraction > 0.0)) {
        return 0.0;
    }
    if (fraction >= 1.0) {
        return 1.0;
    }
    return cubic(y1, y2, parameterForX(*this, fraction));
}

TimingCurve timingCurveFor(KeyframeInterpolation interpolation) {
    switch (interpolation) {
    case KeyframeInterpolation::EaseOut:
        return TimingCurve{0.42, 0.0, 1.0, 1.0};
    case KeyframeInterpolation::EaseIn:
        return TimingCurve{0.0, 0.0, 0.58, 1.0};
    case KeyframeInterpolation::EaseInOut:
        return TimingCurve{0.42, 0.0, 0.58, 1.0};
    case KeyframeInterpolation::Hold:
    case KeyframeInterpolation::Linear:
    case KeyframeInterpolation::Bezier:
        break;
    }
    return TimingCurve{};
}

CurveSplit splitCurve(const TimingCurve &curve, double fraction) {
    const double t = parameterForX(curve, std::clamp(fraction, 0.0, 1.0));
    const Point p0{0.0, 0.0};
    const Point p1{curve.x1, curve.y1};
    const Point p2{curve.x2, curve.y2};
    const Point p3{1.0, 1.0};
    // De Casteljau.
    const Point a = lerp(p0, p1, t);
    const Point b = lerp(p1, p2, t);
    const Point c = lerp(p2, p3, t);
    const Point d = lerp(a, b, t);
    const Point e = lerp(b, c, t);
    const Point m = lerp(d, e, t);
    CurveSplit split;
    split.valueAtSplit = m.y;
    constexpr double kFlat = 1e-12;
    if (m.x > kFlat && std::fabs(m.y) > kFlat) {
        split.before = TimingCurve{std::clamp(a.x / m.x, 0.0, 1.0), a.y / m.y, std::clamp(d.x / m.x, 0.0, 1.0),
                                   d.y / m.y};
    }
    const double restX = 1.0 - m.x;
    const double restY = 1.0 - m.y;
    if (restX > kFlat && std::fabs(restY) > kFlat) {
        split.after = TimingCurve{std::clamp((e.x - m.x) / restX, 0.0, 1.0), (e.y - m.y) / restY,
                                  std::clamp((c.x - m.x) / restX, 0.0, 1.0), (c.y - m.y) / restY};
    }
    return split;
}

bool operator==(const Keyframe &a, const Keyframe &b) {
    return identical(a.time, b.time) && a.value == b.value && a.interpolation == b.interpolation && a.curve == b.curve;
}

KeyframeTrack &MotionKeyframes::track(MotionParameter parameter) {
    switch (parameter) {
    case MotionParameter::X:
        return x;
    case MotionParameter::Y:
        return y;
    case MotionParameter::Scale:
        return scale;
    case MotionParameter::Rotation:
        return rotation;
    case MotionParameter::Opacity:
        return opacity;
    }
    return x;
}

const KeyframeTrack &MotionKeyframes::track(MotionParameter parameter) const {
    return const_cast<MotionKeyframes *>(this)->track(parameter);
}

bool MotionKeyframes::empty() const {
    return x.empty() && y.empty() && scale.empty() && rotation.empty() && opacity.empty();
}

std::size_t MotionKeyframes::count() const {
    return x.size() + y.size() + scale.size() + rotation.size() + opacity.size();
}

double evaluateTrack(const KeyframeTrack &track, double staticValue, const ExactTime &time) {
    if (track.empty()) {
        return staticValue;
    }
    if (time.compare(track.front().time) <= 0) {
        return track.front().value;
    }
    if (time.compare(track.back().time) >= 0) {
        return track.back().value;
    }
    // The segment [k, k + 1) containing `time`: the last keyframe at or before it.
    const auto after = std::upper_bound(track.begin(), track.end(), time,
                                        [](const ExactTime &t, const Keyframe &k) { return t.compare(k.time) < 0; });
    const Keyframe &to = *after;
    const Keyframe &from = *(after - 1);
    const auto start = ExactTime::from(from.time);
    const auto end = ExactTime::from(to.time);
    const auto into = start ? time.minus(*start) : std::nullopt;
    const auto length = start && end ? end->minus(*start) : std::nullopt;
    if (!into || !length) {
        return from.value; // only on 128-bit overflow of the exact arithmetic
    }
    return segmentValue(from, to, std::clamp(ratio(*into, *length), 0.0, 1.0));
}

std::optional<std::size_t> keyframeIndexAt(const KeyframeTrack &track, CMTime time) {
    const auto it = std::lower_bound(track.begin(), track.end(), time,
                                     [](const Keyframe &k, CMTime t) { return k.time < t; });
    if (it != track.end() && it->time == time) {
        return static_cast<std::size_t>(it - track.begin());
    }
    return std::nullopt;
}

std::optional<std::size_t> firstKeyframeIn(const KeyframeTrack &track, const ExactTime &from, const ExactTime &to) {
    const auto it = std::lower_bound(track.begin(), track.end(), from,
                                     [](const Keyframe &k, const ExactTime &t) { return t.compare(k.time) > 0; });
    if (it != track.end() && to.compare(it->time) > 0) {
        return static_cast<std::size_t>(it - track.begin());
    }
    return std::nullopt;
}

void upsertKeyframe(KeyframeTrack &track, const Keyframe &keyframe) {
    const auto it = std::lower_bound(track.begin(), track.end(), keyframe.time,
                                     [](const Keyframe &k, CMTime t) { return k.time < t; });
    if (it != track.end() && it->time == keyframe.time) {
        *it = keyframe;
    } else {
        track.insert(it, keyframe);
    }
}

TrackSplit splitTrack(const KeyframeTrack &track, double staticValue, CMTime at) {
    TrackSplit split;
    split.leftStatic = staticValue;
    split.rightStatic = staticValue;
    if (track.empty()) {
        return split;
    }
    const auto firstRight = std::lower_bound(track.begin(), track.end(), at,
                                             [](const Keyframe &k, CMTime t) { return k.time < t; });
    split.left.assign(track.begin(), firstRight);
    split.right.assign(firstRight, track.end());
    if (split.left.empty()) {
        // Every keyframe is at or after the cut: the left piece holds the first value.
        split.leftStatic = track.front().value;
        return split;
    }
    if (split.right.empty()) {
        // Every keyframe is before the cut: the right piece holds the last value.
        split.rightStatic = track.back().value;
        return split;
    }
    Keyframe &before = split.left.back();
    if (split.right.front().time == at) {
        // A keyframe on the cut: the left piece ends on a copy of it.
        split.left.push_back(split.right.front());
        return split;
    }
    // The cut falls inside the segment [before, next): both pieces get a keyframe at the cut with
    // the value there, and the segment's curve is divided between them.
    const Keyframe &next = split.right.front();
    const auto start = ExactTime::from(before.time);
    const auto end = ExactTime::from(next.time);
    const auto cut = ExactTime::from(at);
    const auto into = start && cut ? cut->minus(*start) : std::nullopt;
    const auto length = start && end ? end->minus(*start) : std::nullopt;
    const double fraction = into && length ? std::clamp(ratio(*into, *length), 0.0, 1.0) : 0.0;
    Keyframe boundary;
    boundary.time = at;
    boundary.interpolation = before.interpolation;
    boundary.curve = before.curve;
    switch (before.interpolation) {
    case KeyframeInterpolation::Hold:
        boundary.value = before.value;
        break;
    case KeyframeInterpolation::Linear:
        boundary.value = before.value + (next.value - before.value) * fraction;
        break;
    case KeyframeInterpolation::EaseOut:
    case KeyframeInterpolation::EaseIn:
    case KeyframeInterpolation::EaseInOut:
    case KeyframeInterpolation::Bezier: {
        const TimingCurve curve =
            before.interpolation == KeyframeInterpolation::Bezier ? before.curve : timingCurveFor(before.interpolation);
        const CurveSplit parts = splitCurve(curve, fraction);
        boundary.value = before.value + (next.value - before.value) * parts.valueAtSplit;
        // A part along which the value does not change is straight (any curve gives the same values).
        before.interpolation = parts.before ? KeyframeInterpolation::Bezier : KeyframeInterpolation::Linear;
        before.curve = parts.before.value_or(TimingCurve{});
        boundary.interpolation = parts.after ? KeyframeInterpolation::Bezier : KeyframeInterpolation::Linear;
        boundary.curve = parts.after.value_or(TimingCurve{});
        break;
    }
    }
    split.left.push_back(boundary);
    split.right.insert(split.right.begin(), boundary);
    return split;
}

bool shiftTrack(KeyframeTrack &track, CMTime delta) {
    KeyframeTrack shifted = track;
    for (Keyframe &keyframe : shifted) {
        const auto moved = checkedAdd(keyframe.time, delta);
        if (!moved || !isExactModelTime(*moved)) {
            return false;
        }
        keyframe.time = *moved;
    }
    track = std::move(shifted);
    return true;
}

bool isValidMotionValue(MotionParameter parameter, double value) {
    if (!std::isfinite(value)) {
        return false;
    }
    switch (parameter) {
    case MotionParameter::Scale:
        return value >= 0.0;
    case MotionParameter::Opacity:
        return value >= 0.0 && value <= 1.0;
    case MotionParameter::X:
    case MotionParameter::Y:
    case MotionParameter::Rotation:
        break;
    }
    return true;
}

std::optional<std::string> keyframeTrackProblem(const KeyframeTrack &track, MotionParameter parameter) {
    const std::string what = std::string(displayNameOf(parameter)) + " keyframe";
    for (std::size_t i = 0; i < track.size(); ++i) {
        const Keyframe &keyframe = track[i];
        if (auto problem = modelTimeProblem(keyframe.time, what + " time")) {
            return problem;
        }
        if (i > 0 && !(track[i - 1].time < keyframe.time)) {
            return what + " times must increase strictly (" + describe(track[i - 1].time) + " then " +
                   describe(keyframe.time) + ")";
        }
        if (!isValidMotionValue(parameter, keyframe.value)) {
            return what + " at " + describe(keyframe.time) + " has the invalid value " + std::to_string(keyframe.value);
        }
        if (keyframe.interpolation == KeyframeInterpolation::Bezier && !keyframe.curve.isValid()) {
            return what + " at " + describe(keyframe.time) + " has an invalid timing curve";
        }
    }
    return std::nullopt;
}

double clampMotionValue(MotionParameter parameter, double value) {
    switch (parameter) {
    case MotionParameter::Scale:
        return std::max(0.0, value);
    case MotionParameter::Opacity:
        return std::clamp(value, 0.0, 1.0);
    case MotionParameter::X:
    case MotionParameter::Y:
    case MotionParameter::Rotation:
        break;
    }
    return value;
}

} // namespace ve
