// Independent references for effect span values: the timing curves solved with Newton's method (the
// engine bisects), and spans evaluated from their two edge values and a frame's source time in
// doubles. Used to check the model, the edit ops, the scheduler and the facade against arithmetic
// that shares no code with them.

#pragma once

#include "ModelFixtures.h"

#include <algorithm>
#include <cmath>

namespace vetest {

// y at time fraction `u` of the cubic Bezier timing curve (0, 0), (x1, y1), (x2, y2), (1, 1).
inline double referenceCurve(double x1, double y1, double x2, double y2, double u) {
    auto bez = [](double p1, double p2, double t) {
        const double v = 1 - t;
        return 3 * v * v * t * p1 + 3 * v * t * t * p2 + t * t * t;
    };
    auto dbez = [](double p1, double p2, double t) {
        const double v = 1 - t;
        return 3 * v * v * p1 + 6 * v * t * (p2 - p1) + 3 * t * t * (1 - p2);
    };
    double t = std::clamp(u, 0.0, 1.0);
    for (int i = 0; i < 100; ++i) {
        const double d = dbez(x1, x2, t);
        if (std::fabs(d) < 1e-14) {
            break;
        }
        t = std::clamp(t - (bez(x1, x2, t) - u) / d, 0.0, 1.0);
    }
    return bez(y1, y2, t);
}

// The fraction of a segment's change reached at time fraction `u` (0 <= u < 1) for `interpolation`:
// Premiere's and Final Cut's names over Core Animation's curves (control points 0.42 and 0.58).
inline double referenceEase(KeyframeInterpolation interpolation, double u) {
    switch (interpolation) {
    case KeyframeInterpolation::Hold:
        return 0.0;
    case KeyframeInterpolation::Linear:
    case KeyframeInterpolation::Bezier:
        return u;
    case KeyframeInterpolation::EaseOut: // leaves slowly: Core Animation's ease-in
        return referenceCurve(0.42, 0.0, 1.0, 1.0, u);
    case KeyframeInterpolation::EaseIn: // arrives slowly: Core Animation's ease-out
        return referenceCurve(0.0, 0.0, 0.58, 1.0, u);
    case KeyframeInterpolation::EaseInOut:
        return referenceCurve(0.42, 0.0, 0.58, 1.0, u);
    }
    return u;
}

// A span moving from `from` to `to` over [start, end) seconds with `interpolation`, evaluated at
// source second `s`: nullopt outside the span (it does nothing there).
inline std::optional<double> referenceSpanValue(double start, double end, double from, double to,
                                                KeyframeInterpolation interpolation, double s) {
    if (s < start || s >= end) {
        return std::nullopt;
    }
    return from + (to - from) * referenceEase(interpolation, (s - start) / (end - start));
}

// A two-keyframe track from `from` (at 0) to `to` (at `length`) with `interpolation`.
inline KeyframeTrack rampTrack(double from, double to, CMTime length,
                               KeyframeInterpolation interpolation = KeyframeInterpolation::Linear) {
    return KeyframeTrack{key(kCMTimeZero, from, interpolation), key(length, to, interpolation)};
}

// Seconds of an exact time, as a double.
inline double seconds(CMTime t) {
    return CMTimeGetSeconds(t);
}

} // namespace vetest
