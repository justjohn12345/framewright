#include "Transition.h"

#include "Track.h"

#include <algorithm>
#include <cmath>
#include <iterator>

namespace ve {

namespace {

constexpr TransitionParameterInfo kParameterTable[] = {
    // Up to 1000 sequence pixels: a soft edge wider than a 4K frame's half height is no longer an edge.
    {TransitionParameter::Softness, "softness", "Edge Softness", TransitionParameterType::Scalar,
     TransitionValue::scalar(kDefaultTransitionSoftness), 0.0, 1000.0, {}},
};

constexpr TransitionParameter kShapedParameters[] = {TransitionParameter::Softness};

constexpr TransitionKindInfo kKindTable[] = {
    {TransitionKind::CrossDissolve, "crossDissolve", "Cross Dissolve", std::nullopt, TransitionMask::None, {}},
    {TransitionKind::WipeLeft, "wipeLeft", "Wipe Left", TrackKind::Video, TransitionMask::Linear, kShapedParameters},
    {TransitionKind::WipeRight, "wipeRight", "Wipe Right", TrackKind::Video, TransitionMask::Linear, kShapedParameters},
    {TransitionKind::WipeUp, "wipeUp", "Wipe Up", TrackKind::Video, TransitionMask::Linear, kShapedParameters},
    {TransitionKind::WipeDown, "wipeDown", "Wipe Down", TrackKind::Video, TransitionMask::Linear, kShapedParameters},
    {TransitionKind::Iris, "iris", "Iris", TrackKind::Video, TransitionMask::Radial, kShapedParameters},
};

// Whether `value` is valid for `info`, usable in constant expressions (the table's defaults).
constexpr bool validValue(const TransitionParameterInfo &info, const TransitionValue &value) {
    const std::size_t used = componentCountOf(info.type);
    for (std::size_t i = 0; i < value.components.size(); ++i) {
        const double c = value.components[i];
        if (i >= used) {
            if (c != 0.0) {
                return false;
            }
            continue;
        }
        // Finite: NaN fails both comparisons, infinities the range (whose bounds are finite).
        if (info.type == TransitionParameterType::Enum) {
            // Within the choices first (so the conversion below is defined), then integral.
            if (!(c >= 0.0 && c < static_cast<double>(info.choices.size())) ||
                static_cast<double>(static_cast<std::size_t>(c)) != c) {
                return false;
            }
        } else if (!(c >= info.minimum && c <= info.maximum)) {
            return false;
        }
    }
    return true;
}

// Each table is indexed by its enum: row i describes enumerator i.
constexpr bool parameterTableInOrder() {
    std::size_t i = 0;
    for (const TransitionParameterInfo &row : kParameterTable) {
        if (static_cast<std::size_t>(row.parameter) != i || kTransitionParameters[i] != row.parameter) {
            return false;
        }
        const bool bounded = row.minimum <= row.maximum && row.minimum > -1.0e300 && row.maximum < 1.0e300;
        const bool choices = (row.type == TransitionParameterType::Enum) == !row.choices.empty();
        if (!bounded || !choices || !validValue(row, row.defaultValue)) {
            return false;
        }
        ++i;
    }
    return i == kTransitionParameterCount;
}
static_assert(parameterTableInOrder(),
              "kParameterTable must describe TransitionParameter in order, each default valid within finite bounds");
static_assert(std::size(kParameterTable) == kTransitionParameterCount);

constexpr bool kindTableInOrder() {
    std::size_t i = 0;
    for (const TransitionKindInfo &row : kKindTable) {
        if (static_cast<std::size_t>(row.kind) != i || kTransitionKinds[i] != row.kind ||
            !std::is_sorted(row.parameters.begin(), row.parameters.end())) {
            return false;
        }
        // A kind without a mask is the uniform mix, the one kind audio has: it fits either track.
        if ((row.mask == TransitionMask::None) != !row.trackKind.has_value()) {
            return false;
        }
        ++i;
    }
    return i == kTransitionKinds.size();
}
static_assert(kindTableInOrder(), "kKindTable must describe TransitionKind in order, parameters in "
                                  "TransitionParameter order, only the unmasked kind on either track");

} // namespace

const TransitionKindInfo &infoOf(TransitionKind kind) {
    const auto index = static_cast<std::size_t>(kind);
    return index < std::size(kKindTable) ? kKindTable[index] : kKindTable[0];
}

const TransitionParameterInfo &infoOf(TransitionParameter parameter) {
    const auto index = static_cast<std::size_t>(parameter);
    return index < std::size(kParameterTable) ? kParameterTable[index] : kParameterTable[0];
}

// A value outside the enum (never made by the engine) is named "unknown" / "Unknown", as before the
// table; infoOf reads the cross dissolve's row for it.
const char *nameOf(TransitionKind kind) {
    return static_cast<std::size_t>(kind) < std::size(kKindTable) ? infoOf(kind).name : "unknown";
}

const char *displayNameOf(TransitionKind kind) {
    return static_cast<std::size_t>(kind) < std::size(kKindTable) ? infoOf(kind).displayName : "Unknown";
}

std::optional<TransitionKind> transitionKindNamed(std::string_view name) {
    for (const TransitionKindInfo &row : kKindTable) {
        if (name == row.name) {
            return row.kind;
        }
    }
    return std::nullopt;
}

bool transitionKindFitsTrack(TransitionKind kind, TrackKind track) {
    const std::optional<TrackKind> wanted = infoOf(kind).trackKind;
    return !wanted || *wanted == track;
}

bool isShapedTransition(TransitionKind kind) {
    return infoOf(kind).mask != TransitionMask::None;
}

const char *nameOf(TransitionParameter parameter) {
    return infoOf(parameter).name;
}

const char *displayNameOf(TransitionParameter parameter) {
    return infoOf(parameter).displayName;
}

std::optional<TransitionParameter> transitionParameterNamed(std::string_view name) {
    for (const TransitionParameterInfo &row : kParameterTable) {
        if (name == row.name) {
            return row.parameter;
        }
    }
    return std::nullopt;
}

bool transitionKindHasParameter(TransitionKind kind, TransitionParameter parameter) {
    const std::span<const TransitionParameter> parameters = infoOf(kind).parameters;
    return std::find(parameters.begin(), parameters.end(), parameter) != parameters.end();
}

bool isValidTransitionValue(const TransitionParameterInfo &info, const TransitionValue &value) {
    return validValue(info, value);
}

bool isValidTransitionValue(TransitionParameter parameter, const TransitionValue &value) {
    return validValue(infoOf(parameter), value);
}

TransitionValue TransitionParameters::valueOf(TransitionParameter parameter) const {
    const std::optional<TransitionValue> &set = (*this)[parameter];
    return set ? *set : infoOf(parameter).defaultValue;
}

bool TransitionParameters::empty() const {
    return std::none_of(byParameter.begin(), byParameter.end(),
                        [](const std::optional<TransitionValue> &value) { return value.has_value(); });
}

std::optional<std::string> transitionParametersProblem(TransitionKind kind, const TransitionParameters &parameters) {
    for (const TransitionParameter parameter : kTransitionParameters) {
        const std::optional<TransitionValue> &value = parameters[parameter];
        if (!value) {
            continue;
        }
        if (!transitionKindHasParameter(kind, parameter)) {
            return std::string("a ") + displayNameOf(kind) + " has no " + displayNameOf(parameter);
        }
        if (!isValidTransitionValue(parameter, *value)) {
            const TransitionParameterInfo &info = infoOf(parameter);
            std::string components;
            for (std::size_t i = 0; i < componentCountOf(info.type); ++i) {
                components += (i == 0 ? "" : ", ") + std::to_string(value->components[i]);
            }
            return std::string("its ") + displayNameOf(parameter) + " has the invalid value " + components;
        }
    }
    return std::nullopt;
}

TransitionParameters parametersKeptBy(TransitionKind kind, const TransitionParameters &parameters) {
    TransitionParameters kept;
    for (const TransitionParameter parameter : infoOf(kind).parameters) {
        kept[parameter] = parameters[parameter];
    }
    return kept;
}

const char *nameOf(TransitionRole role) {
    switch (role) {
    case TransitionRole::CrossDissolve:
        return "crossDissolve";
    case TransitionRole::FadeOut:
        return "fadeOut";
    case TransitionRole::FadeIn:
        return "fadeIn";
    }
    return "unknown";
}

} // namespace ve
