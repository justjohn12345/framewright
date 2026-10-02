#include "TransitionValueJSON.h"

#include <string>

namespace ve::serialize {

using nlohmann::json;

json transitionValueToJson(const TransitionParameterInfo &info, const TransitionValue &value) {
    switch (info.type) {
    case TransitionParameterType::Scalar:
    case TransitionParameterType::Angle:
        return value.components[0];
    case TransitionParameterType::Point:
        return json::array({value.components[0], value.components[1]});
    case TransitionParameterType::Colour:
        return json::array({value.components[0], value.components[1], value.components[2], value.components[3]});
    case TransitionParameterType::Enum: {
        const double index = value.components[0];
        if (index >= 0.0 && index < static_cast<double>(info.choices.size()) &&
            static_cast<double>(static_cast<std::size_t>(index)) == index) {
            return info.choices[static_cast<std::size_t>(index)];
        }
        return index;
    }
    }
    return value.components[0];
}

std::optional<TransitionValue> transitionValueFromJson(const TransitionParameterInfo &info, const Node &node) {
    switch (info.type) {
    case TransitionParameterType::Scalar:
    case TransitionParameterType::Angle:
        return TransitionValue::scalar(node.asDouble());
    case TransitionParameterType::Point:
    case TransitionParameterType::Colour: {
        const std::size_t count = componentCountOf(info.type);
        if (node.arraySize() != count) {
            node.fail("expected an array of " + std::to_string(count) + " numbers, found " +
                      std::to_string(node.arraySize()));
        }
        TransitionValue value;
        for (std::size_t i = 0; i < count; ++i) {
            value.components[i] = node.element(i).asDouble();
        }
        return value;
    }
    case TransitionParameterType::Enum: {
        const std::string name = node.asString();
        for (std::size_t i = 0; i < info.choices.size(); ++i) {
            if (name == info.choices[i]) {
                return TransitionValue::choice(i);
            }
        }
        return std::nullopt;
    }
    }
    node.fail("a parameter of an unknown type");
}

} // namespace ve::serialize
