// The span kind and parameter descriptor tables (EffectSpan.h, review core #2) and what is derived from
// them: the rows themselves, the functions that read them checked against copies of the switch
// statements they replaced (at 18bb9fd) over every enumerator and a grid of values, the compose /
// decompose / extrapolate helpers against the arithmetic of the six sites they replaced, and the
// refusal sentences derived from the tables, word for word as before.

#include "../Edit/EditTestSupport.h"

#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

using namespace vetest;

namespace {

constexpr double kInf = std::numeric_limits<double>::infinity();
const double kNaN = std::numeric_limits<double>::quiet_NaN();

// ----- The code the tables replaced, as it was (EffectSpan.cpp at 18bb9fd) -----

const char *oldName(SpanKind kind) {
    switch (kind) {
    case SpanKind::Transition:
        return "transition";
    case SpanKind::Motion:
        return "motion";
    case SpanKind::Opacity:
        return "opacity";
    case SpanKind::Gain:
        return "gain";
    case SpanKind::Unknown:
        return "unknown"; // added by the round's item 1
    }
    return "motion";
}

const char *oldDisplayName(SpanKind kind) {
    switch (kind) {
    case SpanKind::Transition:
        return "Transition";
    case SpanKind::Motion:
        return "Motion";
    case SpanKind::Opacity:
        return "Opacity";
    case SpanKind::Gain:
        return "Gain";
    case SpanKind::Unknown:
        return "Unknown";
    }
    return "Motion";
}

const char *oldName(SpanParameter parameter) {
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

const char *oldDisplayName(SpanParameter parameter) {
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

double oldNeutral(SpanParameter parameter) {
    return parameter == SpanParameter::Scale || parameter == SpanParameter::Opacity ? 1.0 : 0.0;
}

bool oldIsValid(SpanParameter parameter, double value) {
    if (!std::isfinite(value)) {
        return false;
    }
    switch (parameter) {
    case SpanParameter::Scale:
        return value >= 0.0;
    case SpanParameter::Opacity:
        return value >= 0.0 && value <= 1.0;
    default:
        break;
    }
    return true;
}

double oldClamp(SpanParameter parameter, double value) {
    switch (parameter) {
    case SpanParameter::Scale:
        return std::max(0.0, value);
    case SpanParameter::Opacity:
        return std::clamp(value, 0.0, 1.0);
    default:
        break;
    }
    return value;
}

std::vector<SpanParameter> oldParameters(SpanKind kind) {
    switch (kind) {
    case SpanKind::Motion:
        return {SpanParameter::X, SpanParameter::Y, SpanParameter::Scale, SpanParameter::Rotation};
    case SpanKind::Opacity:
        return {SpanParameter::Opacity};
    case SpanKind::Gain:
        return {SpanParameter::Gain};
    default:
        break;
    }
    return {};
}

// The track rule as EditOps, Validation and Clip.cpp open-coded it (Unknown: either, item 1).
bool oldFitsTrack(SpanKind kind, TrackKind track) {
    if (kind == SpanKind::Transition || kind == SpanKind::Unknown) {
        return true;
    }
    const bool video = kind == SpanKind::Motion || kind == SpanKind::Opacity;
    return video == (track == TrackKind::Video);
}

// composeSpanOnto, spanEdgeMotion, composeGainDb: offsets added, factors multiplied.
bool oldMultiplies(SpanParameter parameter) {
    return parameter == SpanParameter::Scale || parameter == SpanParameter::Opacity;
}

double oldCompose(SpanParameter parameter, double below, double contribution) {
    double value = below;
    if (oldMultiplies(parameter)) {
        value *= contribution;
    } else {
        value += contribution;
    }
    return value;
}

// planKenBurns, planMatchSpanEdge, planContinueMotion, planMatchMotion: wanted - below, wanted / below,
// refused unless below > 0 for a factor.
double oldDecompose(SpanParameter parameter, double below, double wanted) {
    return oldMultiplies(parameter) ? wanted / below : wanted - below;
}

bool oldCanDecompose(SpanParameter parameter, double below) {
    return !oldMultiplies(parameter) || below > 0.0;
}

// planContinueMotion's rate: to += (end - start) * k, to *= pow(end / start, k).
double oldExtrapolate(SpanParameter parameter, double from, double first, double last, double k) {
    double to = from;
    if (oldMultiplies(parameter)) {
        to *= std::pow(last / first, k);
    } else {
        to += (last - first) * k;
    }
    return to;
}

// Equal bit for bit (so NaN equals NaN and 0 is not -0).
bool same(double a, double b) {
    return std::memcmp(&a, &b, sizeof a) == 0 || (std::isnan(a) && std::isnan(b));
}

const std::vector<double> &grid() {
    static const std::vector<double> values{-kInf,  -1e9, -360.0, -12.5, -1.0, -0.5, -1e-12, -0.0, 0.0,
                                            1e-300, 1e-9, 0.25,   0.5,   1.0,  1.01, 2.0,    45.0, 1920.0,
                                            1e12,   kInf, kNaN};
    return values;
}

constexpr SpanKind kEveryKind[] = {SpanKind::Transition, SpanKind::Motion, SpanKind::Opacity, SpanKind::Gain,
                                   SpanKind::Unknown};

} // namespace

TEST_CASE("Span descriptors: the kind table") {
    CHECK(kSpanKinds == std::array{SpanKind::Transition, SpanKind::Motion, SpanKind::Opacity, SpanKind::Gain});
    for (const SpanKind kind : kEveryKind) {
        CAPTURE(nameOf(kind));
        const SpanKindInfo &info = infoOf(kind);
        CHECK(info.kind == kind);
        CHECK(std::string(nameOf(kind)) == info.name);
        CHECK(std::string(displayNameOf(kind)) == info.displayName);
        CHECK(std::is_sorted(info.parameters.begin(), info.parameters.end()));
    }
    CHECK(infoOf(SpanKind::Motion).trackKind == TrackKind::Video);
    CHECK(infoOf(SpanKind::Opacity).trackKind == TrackKind::Video);
    CHECK(infoOf(SpanKind::Gain).trackKind == TrackKind::Audio);
    CHECK_FALSE(infoOf(SpanKind::Transition).trackKind.has_value());
    CHECK_FALSE(infoOf(SpanKind::Unknown).trackKind.has_value());
    CHECK(infoOf(SpanKind::Transition).parameters.empty());
    CHECK(infoOf(SpanKind::Unknown).parameters.empty());
    // Names: every listed kind is found by its name; Unknown never is (it is written under its own).
    for (const SpanKind kind : kSpanKinds) {
        CHECK(spanKindNamed(nameOf(kind)) == kind);
    }
    CHECK_FALSE(spanKindNamed("unknown").has_value());
    CHECK_FALSE(spanKindNamed("colour").has_value());
    CHECK_FALSE(spanKindNamed("").has_value());
    CHECK_FALSE(spanKindNamed("Motion").has_value()); // names are case-sensitive
}

TEST_CASE("Span descriptors: the parameter table") {
    REQUIRE(kSpanParameters.size() == kSpanParameterCount);
    for (std::size_t i = 0; i < kSpanParameters.size(); ++i) {
        const SpanParameter parameter = kSpanParameters[i];
        CAPTURE(nameOf(parameter));
        const SpanParameterInfo &info = infoOf(parameter);
        CHECK(static_cast<std::size_t>(parameter) == i);
        CHECK(info.parameter == parameter);
        CHECK(spanParameterNamed(info.name) == parameter);
        CHECK(info.neutral == (info.composition == SpanComposition::Additive ? 0.0 : 1.0));
        CHECK(isValidSpanValue(parameter, info.neutral));
    }
    const auto row = [](SpanParameter p) { return infoOf(p); };
    CHECK(row(SpanParameter::Scale).minimum == 0.0);
    CHECK(row(SpanParameter::Scale).maximum == kInf);
    CHECK(row(SpanParameter::Opacity).minimum == 0.0);
    CHECK(row(SpanParameter::Opacity).maximum == 1.0);
    for (const SpanParameter p : {SpanParameter::X, SpanParameter::Y, SpanParameter::Rotation, SpanParameter::Gain}) {
        CHECK(row(p).minimum == -kInf);
        CHECK(row(p).maximum == kInf);
        CHECK(row(p).composition == SpanComposition::Additive);
    }
    CHECK(row(SpanParameter::Scale).composition == SpanComposition::Multiplicative);
    CHECK(row(SpanParameter::Opacity).composition == SpanComposition::Multiplicative);
    CHECK_FALSE(spanParameterNamed("skew").has_value());
    CHECK_FALSE(spanParameterNamed("X").has_value());
}

TEST_CASE("Span descriptors: the derived functions equal the switches they replaced") {
    for (const SpanKind kind : kEveryKind) {
        CAPTURE(oldName(kind));
        CHECK(std::string(nameOf(kind)) == oldName(kind));
        CHECK(std::string(displayNameOf(kind)) == oldDisplayName(kind));
        CHECK(parametersOf(kind) == oldParameters(kind));
        for (const SpanParameter parameter : kSpanParameters) {
            const std::vector<SpanParameter> old = oldParameters(kind);
            CHECK(kindHasParameter(kind, parameter) == (std::find(old.begin(), old.end(), parameter) != old.end()));
        }
        for (const TrackKind track : {TrackKind::Video, TrackKind::Audio}) {
            CHECK(spanKindFitsTrack(kind, track) == oldFitsTrack(kind, track));
        }
    }
    for (const SpanParameter parameter : kSpanParameters) {
        CAPTURE(oldName(parameter));
        CHECK(std::string(nameOf(parameter)) == oldName(parameter));
        CHECK(std::string(displayNameOf(parameter)) == oldDisplayName(parameter));
        CHECK(neutralValue(parameter) == oldNeutral(parameter));
        for (const double value : grid()) {
            CAPTURE(value);
            CHECK(isValidSpanValue(parameter, value) == oldIsValid(parameter, value));
            CHECK(same(clampSpanValue(parameter, value), oldClamp(parameter, value)));
        }
    }
}

TEST_CASE("Span descriptors: compose, decompose and extrapolate equal the six sites' arithmetic") {
    for (const SpanParameter parameter : kSpanParameters) {
        CAPTURE(oldName(parameter));
        for (const double below : grid()) {
            CAPTURE(below);
            CHECK(canDecomposeSpanValue(parameter, below) == oldCanDecompose(parameter, below));
            for (const double other : grid()) {
                CAPTURE(other);
                CHECK(same(composeSpanValue(parameter, below, other), oldCompose(parameter, below, other)));
                CHECK(same(decomposeSpanValue(parameter, below, other), oldDecompose(parameter, below, other)));
            }
        }
        for (const double from : {-200.0, 0.0, 0.5, 1.0, 37.25}) {
            for (const double first : {0.25, 1.0, 2.0, -3.0}) {
                for (const double last : {0.5, 1.0, 1.5, 10.0, -7.0}) {
                    for (const double k : {0.0, 0.25, 1.0, 1.7, 3.0}) {
                        CHECK(same(extrapolateSpanValue(parameter, from, first, last, k),
                                   oldExtrapolate(parameter, from, first, last, k)));
                    }
                }
            }
        }
        // Decomposing undoes composing wherever it can (finite values, below > 0 for a factor).
        for (const double below : {-3.0, 0.5, 1.0, 4.0}) {
            if (!canDecomposeSpanValue(parameter, below)) {
                continue;
            }
            for (const double contribution : {0.0, 0.5, 1.0, 2.5}) {
                const double composed = composeSpanValue(parameter, below, contribution);
                CHECK(decomposeSpanValue(parameter, below, composed) == doctest::Approx(contribution));
            }
        }
    }
}

TEST_CASE("Span descriptors: refusals derived from the tables read as before") {
    Fixture fx;
    const ClipId first = fx.addClip(fx.v1, fx.av30, 0, 30, 0);
    const ClipId second = fx.addClip(fx.v1, fx.av30, 30, 30, 30);
    const ClipId sound = fx.addClip(fx.a1, fx.audioOnly, 0, 30);
    const SpanId motion = fx.addSpan(second, SpanKind::Motion, 1, f30(30), f30(60));
    const SpanId opacity = fx.addSpan(second, SpanKind::Opacity, 2, f30(30), f30(60));
    const SpanId gain = fx.addSpan(sound, SpanKind::Gain, 1, f30(0), f30(30));
    fx.requireValid();
    (void)first;

    SUBCASE("a value outside a parameter's range names the range") {
        const auto refusal = [&](SpanId span, SpanParameter parameter, double value) {
            SetSpanValues command(fx.seq, span, {SpanValueChange{parameter, value, std::nullopt}});
            return applyRefused(fx.project, command, EditError::InvalidArgument).message;
        };
        CHECK(refusal(opacity, SpanParameter::Opacity, 1.5) == "Opacity cannot be 1.500000 (it is within 0...1)");
        CHECK(refusal(motion, SpanParameter::Scale, -1) == "Scale cannot be -1.000000 (it is at least 0)");
        CHECK(refusal(motion, SpanParameter::X, kInf) == "Position X cannot be inf (it must be finite)");
        CHECK(refusal(gain, SpanParameter::Gain, kNaN) == "Gain cannot be nan (it must be finite)");
    }
    SUBCASE("a factor below a span that is 0 cannot be matched or framed") {
        Clip &clip = *fx.sequence().findClip(second);
        std::vector<SpanValueChange> changes;
        clip.video.scale = 0;
        CHECK(planMatchSpanEdge(fx.sequence(), motion, ClipEdge::Head, changes).message ==
              "the clip's scale is 0 there without this span, so no value can match");
        CHECK(planKenBurns(clip, *fx.span(motion), fx.sequence().frameDuration, MotionFraming{0, 0, 1},
                           MotionFraming{0, 0, 1}, changes)
                  .message == "the clip's scale is 0 there without this span, so no framing can be shown");
        clip.video.scale = 1;
        clip.video.opacity = 0;
        CHECK(planMatchSpanEdge(fx.sequence(), opacity, ClipEdge::Head, changes).message ==
              "the clip's opacity is 0 there without this span, so no value can match");
    }
}

