// Strongly typed 64-bit identifiers for model objects.
//
// Ids are plain values: 0 is the invalid id, every valid id is unique within a Project
// (one IdGenerator hands out ids for every kind), and ids are never reused, so undo/redo
// can restore objects with their original ids.

#pragma once

#include <compare>
#include <cstdint>
#include <functional>

namespace ve {

template <class Tag> class Id {
  public:
    using ValueType = std::uint64_t;

    constexpr Id() = default;
    constexpr explicit Id(ValueType value) : value_(value) {}

    constexpr ValueType value() const {
        return value_;
    }
    constexpr bool isValid() const {
        return value_ != 0;
    }
    constexpr explicit operator bool() const {
        return isValid();
    }

    friend constexpr bool operator==(const Id &, const Id &) = default;
    friend constexpr auto operator<=>(const Id &, const Id &) = default;

  private:
    ValueType value_ = 0;
};

struct AssetIdTag {};
struct TrackIdTag {};
struct ClipIdTag {};
struct TransitionIdTag {};
struct SequenceIdTag {};

using AssetId = Id<AssetIdTag>;
using TrackId = Id<TrackIdTag>;
using ClipId = Id<ClipIdTag>;
using TransitionId = Id<TransitionIdTag>;
using SequenceId = Id<SequenceIdTag>;

// Monotonic id source shared by all id kinds of one Project. Its state is part of the
// project (serialized, and restored by undo) so re-applied edits recreate identical ids.
class IdGenerator {
  public:
    constexpr IdGenerator() = default;
    constexpr explicit IdGenerator(std::uint64_t nextValue) : next_(nextValue == 0 ? 1 : nextValue) {}

    template <class IdType> IdType make() {
        return IdType{next_++};
    }

    // The value the next make() returns.
    constexpr std::uint64_t nextValue() const {
        return next_;
    }

    // Guarantees future ids are greater than `value` (used after loading or merging).
    constexpr void reserveThrough(std::uint64_t value) {
        if (value >= next_) {
            next_ = value + 1;
        }
    }

    friend constexpr bool operator==(const IdGenerator &, const IdGenerator &) = default;

  private:
    std::uint64_t next_ = 1;
};

} // namespace ve

template <class Tag> struct std::hash<ve::Id<Tag>> {
    std::size_t operator()(const ve::Id<Tag> &id) const noexcept {
        return std::hash<std::uint64_t>{}(id.value());
    }
};
