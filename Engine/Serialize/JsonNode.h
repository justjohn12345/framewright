// The JSON reader shared by the project parser (ProjectJSON.cpp) and the frozen migration steps
// (ProjectMigrations.cpp): a value plus its path, whose accessors fail with a ParseError naming
// that path. Private to Engine/Serialize.
//
// One error policy for both: a value of the wrong type, or a required field that is missing,
// fails with "<path>: <what was expected>"; an optional field that is absent or null reads as
// absent (`has`). The time form it reads, {"value", "timescale"} plus "flags" and "epoch" when
// stored, and null for an invalid time, is the form of every schema version from 1 on: the
// migrations depend on it, so a later version that changes the stored form must keep this reader
// for the older ones (the golden migration fixtures fail if it changes).

#pragma once

#include "../Model/TimeUtil.h"

#include <json.hpp>

#include <cstdint>
#include <limits>
#include <string>
#include <utility>

namespace ve::serialize {

struct ParseError {
    std::string message;
};

class Node {
  public:
    Node(const nlohmann::json &value, std::string path) : value_(value), path_(std::move(path)) {}

    const nlohmann::json &value() const {
        return value_;
    }
    const std::string &path() const {
        return path_;
    }

    [[noreturn]] void fail(const std::string &message) const {
        throw ParseError{(path_.empty() ? std::string("(root)") : path_) + ": " + message};
    }

    void requireObject() const {
        if (!value_.is_object()) {
            fail(std::string("expected an object, found ") + value_.type_name());
        }
    }

    bool has(const char *key) const {
        return value_.is_object() && value_.contains(key) && !value_.at(key).is_null();
    }

    Node field(const char *key) const {
        requireObject();
        const auto it = value_.find(key);
        const std::string childPath = path_.empty() ? std::string(key) : path_ + "." + key;
        if (it == value_.end()) {
            throw ParseError{childPath + ": missing required field"};
        }
        return Node(*it, childPath);
    }

    Node element(std::size_t index) const {
        return Node(value_.at(index), path_ + "[" + std::to_string(index) + "]");
    }

    std::size_t arraySize() const {
        if (!value_.is_array()) {
            fail(std::string("expected an array, found ") + value_.type_name());
        }
        return value_.size();
    }

    std::string asString() const {
        if (!value_.is_string()) {
            fail(std::string("expected a string, found ") + value_.type_name());
        }
        return value_.get<std::string>();
    }

    bool asBool() const {
        if (!value_.is_boolean()) {
            fail(std::string("expected a boolean, found ") + value_.type_name());
        }
        return value_.get<bool>();
    }

    double asDouble() const {
        if (!value_.is_number()) {
            fail(std::string("expected a number, found ") + value_.type_name());
        }
        return value_.get<double>();
    }

    std::int64_t asInt64() const {
        if (value_.is_number_unsigned()) {
            const auto v = value_.get<std::uint64_t>();
            if (v > static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max())) {
                fail("integer out of range");
            }
            return static_cast<std::int64_t>(v);
        }
        if (!value_.is_number_integer()) {
            fail(std::string("expected an integer, found ") + value_.type_name());
        }
        return value_.get<std::int64_t>();
    }

    std::int32_t asInt32() const {
        const std::int64_t v = asInt64();
        if (v < std::numeric_limits<std::int32_t>::min() || v > std::numeric_limits<std::int32_t>::max()) {
            fail("integer out of 32-bit range");
        }
        return static_cast<std::int32_t>(v);
    }

    std::uint64_t asUInt64() const {
        if (value_.is_number_unsigned()) {
            return value_.get<std::uint64_t>();
        }
        if (value_.is_number_integer() && value_.get<std::int64_t>() >= 0) {
            return static_cast<std::uint64_t>(value_.get<std::int64_t>());
        }
        fail(std::string("expected a non-negative integer, found ") + value_.dump());
    }

    template <class IdType> IdType asId() const {
        return IdType{asUInt64()};
    }

    CMTime asTime() const {
        if (value_.is_null()) {
            return kCMTimeInvalid;
        }
        if (!value_.is_object()) {
            fail(std::string("expected a time {value, timescale} or null, found ") + value_.type_name());
        }
        CMTime time;
        time.value = field("value").asInt64();
        time.timescale = field("timescale").asInt32();
        time.flags = kCMTimeFlags_Valid;
        time.epoch = 0;
        if (has("flags")) {
            const std::int64_t flags = field("flags").asInt64();
            if (flags < 0 || flags > 0xFF || (flags & kCMTimeFlags_Valid) == 0) {
                fail("invalid time flags " + std::to_string(flags));
            }
            time.flags = static_cast<CMTimeFlags>(flags);
        }
        if (has("epoch")) {
            time.epoch = field("epoch").asInt64();
        }
        if (CMTIME_IS_NUMERIC(time) && time.timescale <= 0) {
            fail("timescale must be positive");
        }
        return time;
    }

    // Optional-field helpers: absent or null -> fallback.
    std::string stringOr(const char *key, std::string fallback) const {
        return has(key) ? field(key).asString() : std::move(fallback);
    }
    bool boolOr(const char *key, bool fallback) const {
        return has(key) ? field(key).asBool() : fallback;
    }
    double doubleOr(const char *key, double fallback) const {
        return has(key) ? field(key).asDouble() : fallback;
    }
    std::int32_t int32Or(const char *key, std::int32_t fallback) const {
        return has(key) ? field(key).asInt32() : fallback;
    }
    CMTime timeOr(const char *key, CMTime fallback) const {
        if (!value_.is_object() || !value_.contains(key)) {
            return fallback;
        }
        return field(key).asTime();
    }

  private:
    const nlohmann::json &value_;
    std::string path_;
};

} // namespace ve::serialize
