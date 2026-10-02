// A transition parameter's static value in the project file (Transition.h, TransitionParameterType),
// read and written by ProjectJSON.cpp under a transition span's "parameters". Private to
// Engine/Serialize (and its tests).
//
// The forms: a Scalar or an Angle is a number; a Point is [x, y]; a Colour is [r, g, b, a]; an Enum is
// the name of one of the parameter's choices. The reader checks the shape only (a number where a
// number goes, an array of the right length); the range is validation's (validateProject refuses a
// value outside it, as it refuses an effect span's keyframe value outside its parameter's).

#pragma once

#include "../Model/Transition.h"
#include "JsonNode.h"

#include <json.hpp>

#include <optional>

namespace ve::serialize {

// `value` in the file's form for `info`'s type. Never throws: an Enum index outside the choices (never
// valid, so never in a project that passed validation) is written as its number.
nlohmann::json transitionValueToJson(const TransitionParameterInfo &info, const TransitionValue &value);

// The value `node` holds for `info`'s type; nullopt for an Enum choice this version does not know (a
// newer version's), which the parser keeps as foreign content. A value of the wrong shape fails with
// a ParseError naming its path.
std::optional<TransitionValue> transitionValueFromJson(const TransitionParameterInfo &info, const Node &node);

} // namespace ve::serialize
