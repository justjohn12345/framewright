#include "EffectSpan.h"

#include "Track.h"
#include "Validation.h"

#include <algorithm>
#include <cmath>
#include <iterator>
#include <limits>

namespace ve {

const char *nameOf(ClipEdge edge) {
    return edge == ClipEdge::Head ? "head" : "tail";
}

namespace {

constexpr double kUnbounded = std::numeric_limits<double>::infinity();

constexpr SpanParameterInfo kParameterTable[] = {
    {SpanParameter::X, "x", "Position X", 0.0, -kUnbounded, kUnbounded, SpanComposition::Additive},
    {SpanParameter::Y, "y", "Position Y", 0.0, -kUnbounded, kUnbounded, SpanComposition::Additive},
    {SpanParameter::Scale, "scale", "Scale", 1.0, 0.0, kUnbounded, SpanComposition::Multiplicative},
    {SpanParameter::Rotation, "rotation", "Rotation", 0.0, -kUnbounded, kUnbounded, SpanComposition::Additive},
    {SpanParameter::Opacity, "opacity", "Opacity", 1.0, 0.0, 1.0, SpanComposition::Multiplicative},
    {SpanParameter::Gain, "gain", "Gain", 0.0, -kUnbounded, kUnbounded, SpanComposition::Additive},
};

constexpr SpanParameter kMotionParametersOfSpans[] = {SpanParameter::X, SpanParameter::Y, SpanParameter::Scale,
                                                      SpanParameter::Rotation};
constexpr SpanParameter kOpacityParameters[] = {SpanParameter::Opacity};
constexpr SpanParameter kGainParameters[] = {SpanParameter::Gain};

constexpr SpanKindInfo kKindTable[] = {
    {SpanKind::Transition, "transition", "Transition", std::nullopt, {}},
    {SpanKind::Motion, "motion", "Motion", TrackKind::Video, kMotionParametersOfSpans},
    {SpanKind::Opacity, "opacity", "Opacity", TrackKind::Video, kOpacityParameters},
    {SpanKind::Gain, "gain", "Gain", TrackKind::Audio, kGainParameters},
    {SpanKind::Unknown, "unknown", "Unknown", std::nullopt, {}},
};

// Each table is indexed by its enum: row i describes enumerator i.
constexpr bool parameterTableInOrder() {
    std::size_t i = 0;
    for (const SpanParameterInfo &row : kParameterTable) {
        if (static_cast<std::size_t>(row.parameter) != i || kSpanParameters[i] != row.parameter) {
            return false;
        }
        if (!(row.minimum <= row.neutral && row.neutral <= row.maximum)) {
            return false;
        }
        if (row.neutral != (row.composition == SpanComposition::Additive ? 0.0 : 1.0)) {
            return false;
        }
        ++i;
    }
    return i == kSpanParameterCount;
}
static_assert(parameterTableInOrder(), "kParameterTable must describe SpanParameter in order, neutral within range");
static_assert(std::size(kParameterTable) == kSpanParameterCount);
static_assert(static_cast<std::size_t>(SpanKind::Unknown) + 1 == std::size(kKindTable));
static_assert(static_cast<std::size_t>(kSpanKinds.back()) + 1 == kSpanKinds.size(),
              "kSpanKinds lists every SpanKind before Unknown, in order");

constexpr bool kindTableInOrder() {
    for (std::size_t i = 0; i < std::size(kKindTable); ++i) {
        if (static_cast<std::size_t>(kKindTable[i].kind) != i ||
            !std::is_sorted(kKindTable[i].parameters.begin(), kKindTable[i].parameters.end())) {
            return false;
        }
    }
    return true;
}
static_assert(kindTableInOrder(), "kKindTable must describe SpanKind in order, parameters in SpanParameter order");

} // namespace

const SpanKindInfo &infoOf(SpanKind kind) {
    const auto index = static_cast<std::size_t>(kind);
    return index < std::size(kKindTable) ? kKindTable[index] : kKindTable[static_cast<std::size_t>(SpanKind::Unknown)];
}

const SpanParameterInfo &infoOf(SpanParameter parameter) {
    const auto index = static_cast<std::size_t>(parameter);
    return index < std::size(kParameterTable) ? kParameterTable[index] : kParameterTable[0];
}

const char *nameOf(SpanKind kind) {
    return infoOf(kind).name;
}

const char *displayNameOf(SpanKind kind) {
    return infoOf(kind).displayName;
}

std::optional<SpanKind> spanKindNamed(std::string_view name) {
    for (const SpanKind kind : kSpanKinds) {
        if (name == nameOf(kind)) {
            return kind;
        }
    }
    return std::nullopt;
}

bool spanKindFitsTrack(SpanKind kind, TrackKind track) {
    const std::optional<TrackKind> wanted = infoOf(kind).trackKind;
    return !wanted || *wanted == track;
}

const char *nameOf(SpanParameter parameter) {
    return infoOf(parameter).name;
}

const char *displayNameOf(SpanParameter parameter) {
    return infoOf(parameter).displayName;
}

std::optional<SpanParameter> spanParameterNamed(std::string_view name) {
    for (const SpanParameterInfo &row : kParameterTable) {
        if (name == row.name) {
            return row.parameter;
        }
    }
    return std::nullopt;
}

double neutralValue(SpanParameter parameter) {
    return infoOf(parameter).neutral;
}

bool isValidSpanValue(SpanParameter parameter, double value) {
    const SpanParameterInfo &info = infoOf(parameter);
    return std::isfinite(value) && value >= info.minimum && value <= info.maximum;
}

double clampSpanValue(SpanParameter parameter, double value) {
    const SpanParameterInfo &info = infoOf(parameter);
    const bool below = std::isfinite(info.minimum);
    const bool above = std::isfinite(info.maximum);
    if (below && above) {
        return std::clamp(value, info.minimum, info.maximum);
    }
    if (below) {
        return std::max(info.minimum, value);
    }
    if (above) {
        return std::min(info.maximum, value);
    }
    return value;
}

std::vector<SpanParameter> parametersOf(SpanKind kind) {
    const std::span<const SpanParameter> parameters = infoOf(kind).parameters;
    return std::vector<SpanParameter>(parameters.begin(), parameters.end());
}

bool kindHasParameter(SpanKind kind, SpanParameter parameter) {
    const std::span<const SpanParameter> parameters = infoOf(kind).parameters;
    return std::find(parameters.begin(), parameters.end(), parameter) != parameters.end();
}

double composeSpanValue(SpanParameter parameter, double below, double contribution) {
    return infoOf(parameter).composition == SpanComposition::Additive ? below + contribution : below * contribution;
}

bool canDecomposeSpanValue(SpanParameter parameter, double below) {
    return infoOf(parameter).composition == SpanComposition::Additive || below > 0.0;
}

double decomposeSpanValue(SpanParameter parameter, double below, double wanted) {
    return infoOf(parameter).composition == SpanComposition::Additive ? wanted - below : wanted / below;
}

double extrapolateSpanValue(SpanParameter parameter, double from, double first, double last, double times) {
    return infoOf(parameter).composition == SpanComposition::Additive ? from + (last - first) * times
                                                                      : from * std::pow(last / first, times);
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

bool operator==(const ForeignSpanContent &a, const ForeignSpanContent &b) {
    return a.kindName == b.kindName && a.fields == b.fields && a.tracks == b.tracks &&
           identical(a.tracksLength, b.tracksLength);
}

bool operator==(const EffectSpan &a, const EffectSpan &b) {
    return a.id == b.id && a.lane == b.lane && a.kind == b.kind && identical(a.start, b.start) &&
           identical(a.end, b.end) && a.edge == b.edge && a.transition == b.transition && a.tracks == b.tracks &&
           a.unknownTransitionName == b.unknownTransitionName && a.foreign == b.foreign;
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
    if (span.isTransition() || span.isUnknownKind() || !isNumeric(at) || !(span.start < at) || !(at < span.end)) {
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
    split.left.foreign.dropForeignTracks();
    split.right.foreign.dropForeignTracks();
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
    if (span.isUnknownKind() && (span.start < from || to < span.end)) {
        return std::nullopt; // its content cannot be divided: it goes
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
