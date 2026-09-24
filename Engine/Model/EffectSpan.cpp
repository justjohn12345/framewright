#include "EffectSpan.h"

#include "Validation.h"

#include <algorithm>
#include <cmath>

namespace ve {

const char *nameOf(ClipEdge edge) {
    return edge == ClipEdge::Head ? "head" : "tail";
}

const char *nameOf(SpanKind kind) {
    switch (kind) {
    case SpanKind::Transition:
        return "transition";
    case SpanKind::Motion:
        return "motion";
    case SpanKind::Opacity:
        return "opacity";
    case SpanKind::Gain:
        return "gain";
    }
    return "motion";
}

const char *displayNameOf(SpanKind kind) {
    switch (kind) {
    case SpanKind::Transition:
        return "Transition";
    case SpanKind::Motion:
        return "Motion";
    case SpanKind::Opacity:
        return "Opacity";
    case SpanKind::Gain:
        return "Gain";
    }
    return "Motion";
}

const char *nameOf(SpanParameter parameter) {
    switch (parameter) {
    case SpanParameter::X:
        return "x";
    case SpanParameter::Y:
        return "y";
    case SpanParameter::Scale:
        return "scale";
    case SpanParameter::Rotation:
        return "rotation";
    case SpanParameter::Opacity:
        return "opacity";
    case SpanParameter::Gain:
        return "gain";
    }
    return "x";
}

const char *displayNameOf(SpanParameter parameter) {
    switch (parameter) {
    case SpanParameter::X:
        return "Position X";
    case SpanParameter::Y:
        return "Position Y";
    case SpanParameter::Scale:
        return "Scale";
    case SpanParameter::Rotation:
        return "Rotation";
    case SpanParameter::Opacity:
        return "Opacity";
    case SpanParameter::Gain:
        return "Gain";
    }
    return "Position X";
}

double neutralValue(SpanParameter parameter) {
    return parameter == SpanParameter::Scale || parameter == SpanParameter::Opacity ? 1.0 : 0.0;
}

bool isValidSpanValue(SpanParameter parameter, double value) {
    if (!std::isfinite(value)) {
        return false;
    }
    switch (parameter) {
    case SpanParameter::Scale:
        return value >= 0.0;
    case SpanParameter::Opacity:
        return value >= 0.0 && value <= 1.0;
    case SpanParameter::X:
    case SpanParameter::Y:
    case SpanParameter::Rotation:
    case SpanParameter::Gain:
        break;
    }
    return true;
}

double clampSpanValue(SpanParameter parameter, double value) {
    switch (parameter) {
    case SpanParameter::Scale:
        return std::max(0.0, value);
    case SpanParameter::Opacity:
        return std::clamp(value, 0.0, 1.0);
    case SpanParameter::X:
    case SpanParameter::Y:
    case SpanParameter::Rotation:
    case SpanParameter::Gain:
        break;
    }
    return value;
}

std::vector<SpanParameter> parametersOf(SpanKind kind) {
    switch (kind) {
    case SpanKind::Motion:
        return {SpanParameter::X, SpanParameter::Y, SpanParameter::Scale, SpanParameter::Rotation};
    case SpanKind::Opacity:
        return {SpanParameter::Opacity};
    case SpanKind::Gain:
        return {SpanParameter::Gain};
    case SpanKind::Transition:
        break;
    }
    return {};
}

bool kindHasParameter(SpanKind kind, SpanParameter parameter) {
    switch (kind) {
    case SpanKind::Motion:
        return parameter == SpanParameter::X || parameter == SpanParameter::Y || parameter == SpanParameter::Scale ||
               parameter == SpanParameter::Rotation;
    case SpanKind::Opacity:
        return parameter == SpanParameter::Opacity;
    case SpanKind::Gain:
        return parameter == SpanParameter::Gain;
    case SpanKind::Transition:
        break;
    }
    return false;
}

KeyframeTrack &SpanTracks::track(SpanParameter parameter) {
    switch (parameter) {
    case SpanParameter::X:
        return x;
    case SpanParameter::Y:
        return y;
    case SpanParameter::Scale:
        return scale;
    case SpanParameter::Rotation:
        return rotation;
    case SpanParameter::Opacity:
        return opacity;
    case SpanParameter::Gain:
        return gain;
    }
    return x;
}

const KeyframeTrack &SpanTracks::track(SpanParameter parameter) const {
    return const_cast<SpanTracks *>(this)->track(parameter);
}

bool SpanTracks::empty() const {
    return x.empty() && y.empty() && scale.empty() && rotation.empty() && opacity.empty() && gain.empty();
}

bool operator==(const EffectSpan &a, const EffectSpan &b) {
    return a.id == b.id && a.lane == b.lane && a.kind == b.kind && identical(a.start, b.start) &&
           identical(a.end, b.end) && a.edge == b.edge && a.transition == b.transition && a.tracks == b.tracks;
}

namespace {

// time - span.start, exactly.
std::optional<ExactTime> relativeTime(const EffectSpan &span, const ExactTime &time) {
    const auto start = ExactTime::from(span.start);
    return start ? time.minus(*start) : std::nullopt;
}

Keyframe constantKeyframe(double value) {
    Keyframe keyframe;
    keyframe.time = kCMTimeZero;
    keyframe.value = value;
    keyframe.interpolation = KeyframeInterpolation::Linear;
    return keyframe;
}

} // namespace

double spanValueAt(const EffectSpan &span, SpanParameter parameter, const ExactTime &time) {
    const KeyframeTrack &track = span.tracks.track(parameter);
    if (track.empty()) {
        return neutralValue(parameter);
    }
    const auto relative = relativeTime(span, time);
    if (!relative) {
        return clampSpanValue(parameter, track.front().value); // only on 128-bit overflow
    }
    return clampSpanValue(parameter, evaluateTrack(track, neutralValue(parameter), *relative));
}

double spanValueFromLeft(const EffectSpan &span, SpanParameter parameter, const ExactTime &time) {
    const KeyframeTrack &track = span.tracks.track(parameter);
    if (track.empty()) {
        return neutralValue(parameter);
    }
    const auto relative = relativeTime(span, time);
    if (!relative) {
        return clampSpanValue(parameter, track.back().value); // only on 128-bit overflow
    }
    return clampSpanValue(parameter, evaluateTrackFromLeft(track, neutralValue(parameter), *relative));
}

double spanEdgeValue(const EffectSpan &span, SpanParameter parameter, bool atEnd) {
    const auto at = ExactTime::from(atEnd ? span.end : span.start);
    return at ? spanValueAt(span, parameter, *at) : neutralValue(parameter);
}

bool spanActsAt(const EffectSpan &span, const ExactTime &time) {
    return !span.isTransition() && time.compare(span.start) >= 0;
}

double spanContributionAt(const EffectSpan &span, SpanParameter parameter, const ExactTime &time) {
    if (!spanActsAt(span, time)) {
        return neutralValue(parameter);
    }
    if (time.compare(span.end) >= 0) {
        return spanEdgeValue(span, parameter, true);
    }
    return spanValueAt(span, parameter, time);
}

double spanContributionFromLeft(const EffectSpan &span, SpanParameter parameter, const ExactTime &time) {
    if (span.isTransition() || time.compare(span.start) <= 0) {
        return neutralValue(parameter);
    }
    if (time.compare(span.end) > 0) {
        return spanEdgeValue(span, parameter, true);
    }
    return spanValueFromLeft(span, parameter, time);
}

KeyframeInterpolation spanInterpolation(const EffectSpan &span) {
    std::optional<KeyframeInterpolation> shared;
    for (const SpanParameter parameter : kSpanParameters) {
        const KeyframeTrack &track = span.tracks.track(parameter);
        for (std::size_t i = 0; i + 1 < track.size(); ++i) {
            const KeyframeInterpolation interpolation = track[i].interpolation;
            if (interpolation == KeyframeInterpolation::Bezier || (shared && *shared != interpolation)) {
                return KeyframeInterpolation::Bezier;
            }
            shared = interpolation;
        }
    }
    return shared.value_or(KeyframeInterpolation::Linear);
}

std::optional<std::string> spanTracksProblem(const EffectSpan &span) {
    const std::string where = std::string(displayNameOf(span.kind)) + " span " + std::to_string(span.id.value());
    if (span.isTransition()) {
        if (!span.tracks.empty()) {
            return where + ": a transition has no keyframes";
        }
        return std::nullopt;
    }
    const auto start = ExactTime::from(span.start);
    const auto end = ExactTime::from(span.end);
    const auto length = start && end ? end->minus(*start) : std::nullopt;
    if (!length) {
        return where + ": its length cannot be computed";
    }
    for (const SpanParameter parameter : kSpanParameters) {
        const KeyframeTrack &track = span.tracks.track(parameter);
        if (track.empty()) {
            continue;
        }
        if (!kindHasParameter(span.kind, parameter)) {
            return where + ": a " + nameOf(span.kind) + " span has no " + displayNameOf(parameter) + " keyframes";
        }
        const std::string what = where + ": " + displayNameOf(parameter) + " keyframe";
        if (auto problem = keyframeTimesProblem(track, what)) {
            return problem;
        }
        if (track.front().time < kCMTimeZero || length->compare(track.back().time) < 0) {
            return what + " times must lie within the span (0 to " + describe(length->toTimeRounded()) + "), found " +
                   describe(track.front().time < kCMTimeZero ? track.front().time : track.back().time);
        }
        for (const Keyframe &keyframe : track) {
            if (!isValidSpanValue(parameter, keyframe.value)) {
                return what + " at " + describe(keyframe.time) + " has the invalid value " +
                       std::to_string(keyframe.value);
            }
        }
    }
    return std::nullopt;
}

std::optional<SpanSplit> splitSpan(const EffectSpan &span, CMTime at, SpanCutProblem *problem) {
    SpanCutProblem ignored = SpanCutProblem::None;
    SpanCutProblem &why = problem != nullptr ? *problem : ignored;
    why = SpanCutProblem::None;
    if (span.isTransition() || !isNumeric(at) || !(span.start < at) || !(at < span.end)) {
        return std::nullopt;
    }
    const auto relative = checkedSubtract(at, span.start);
    const auto back = relative ? checkedNegate(*relative) : std::nullopt;
    if (!relative || !back || !isExactModelTime(*relative) || !isExactModelTime(at)) {
        why = SpanCutProblem::NotRepresentable;
        return std::nullopt;
    }
    SpanSplit split{span, span};
    split.left.end = at;
    split.right.start = at;
    split.right.id = SpanId{};
    for (const SpanParameter parameter : kSpanParameters) {
        const KeyframeTrack &track = span.tracks.track(parameter);
        if (track.empty()) {
            continue;
        }
        TrackSplit pieces = splitTrack(track, neutralValue(parameter), *relative);
        if (!pieces.right.empty() && !isValidSpanValue(parameter, pieces.right.front().value)) {
            why = SpanCutProblem::CurveOvershoot; // a custom curve goes outside the range at the cut
            return std::nullopt;
        }
        KeyframeTrack left = pieces.left.empty() ? KeyframeTrack{constantKeyframe(pieces.leftStatic)}
                                                 : std::move(pieces.left);
        KeyframeTrack right;
        if (pieces.right.empty()) {
            right = {constantKeyframe(pieces.rightStatic)};
        } else {
            right = std::move(pieces.right);
            if (!shiftTrack(right, *back)) {
                why = SpanCutProblem::NotRepresentable;
                return std::nullopt;
            }
        }
        split.left.tracks.track(parameter) = std::move(left);
        split.right.tracks.track(parameter) = std::move(right);
    }
    return split;
}

std::optional<EffectSpan> clipSpan(const EffectSpan &span, CMTime from, CMTime to, SpanCutProblem *problem) {
    SpanCutProblem ignored = SpanCutProblem::None;
    SpanCutProblem &why = problem != nullptr ? *problem : ignored;
    why = SpanCutProblem::None;
    if (span.isTransition() || !(span.start < to) || !(from < span.end) || !(from < to)) {
        return std::nullopt;
    }
    EffectSpan clipped = span;
    if (clipped.start < from) {
        const auto parts = splitSpan(clipped, from, &why);
        if (!parts) {
            return std::nullopt;
        }
        clipped = parts->right;
        clipped.id = span.id;
    }
    if (to < clipped.end) {
        const auto parts = splitSpan(clipped, to, &why);
        if (!parts) {
            return std::nullopt;
        }
        clipped = parts->left;
    }
    return clipped;
}

} // namespace ve
