// CMTime helpers shared by the model, edit operations and the scheduler.
//
// Conventions:
// - Comparison and arithmetic operators on CMTime (declared in the global namespace, below)
//   are numeric: 1/2 == 2/4. Use identical() for bit-for-bit comparison (value, timescale, flags, epoch).
// - Time ranges are half-open [start, end).
// - Frame grids start at time zero: frame n of a grid with frame duration fd covers
//   [n * fd, (n + 1) * fd).
//
// Exactness: CoreMedia's CMTimeAdd/CMTimeSubtract round to a nanosecond timescale (and set
// kCMTimeFlags_HasBeenRounded) whenever the common timescale of the operands exceeds 2^31 - 1.
// The model never stores a rounded time. checkedAdd/checkedSubtract/checkedNegate/checkedScale
// return the exact result or nullopt when it cannot be represented as a CMTime (value in int64,
// timescale in int32); edit code uses them wherever it stores a computed time and refuses the
// edit explicitly instead of rounding. ExactTime carries intermediate results (for example a
// clip's derived source out point) that need not be representable as a CMTime at all.
// The global + and - operators are exact whenever the exact result is representable and only
// then fall back to CoreMedia's rounded result (flagged kCMTimeFlags_HasBeenRounded).

#pragma once

#include <CoreMedia/CMTime.h>
#include <CoreMedia/CMTimeRange.h>

#include <cstdint>
#include <optional>
#include <string>

namespace ve {

// 128-bit integer for exact intermediate products (clang/gcc builtin).
using Int128 = __int128;

// A timescale divisible by every common video and audio rate (24000, 30000, 60000, 600,
// 44100, 48000, 96000, ...). Used when a result must be rounded (rendering only).
inline constexpr std::int32_t kPreciseTimescale = 705600000;

// ----- Exact CMTime arithmetic -----

// a + b exactly. Both must be numeric with a positive timescale and the same epoch. The result
// uses the least common multiple of the two timescales when that fits (so sums of times on one
// timescale stay on it); otherwise the fully reduced fraction. nullopt when the exact sum is not
// representable (timescale > kCMTimeMaxTimescale or value outside int64) or the inputs are not
// usable. kCMTimeFlags_HasBeenRounded propagates from the inputs; the epoch is kept.
std::optional<CMTime> checkedAdd(CMTime a, CMTime b);
std::optional<CMTime> checkedSubtract(CMTime a, CMTime b);

// -a exactly, keeping flags and epoch. nullopt for non-numeric input or when -a has no exact
// representation (value INT64_MIN with an odd timescale).
std::optional<CMTime> checkedNegate(CMTime a);

// Numeric a + b / a - b / -a: exact when representable, otherwise CoreMedia's result (rounded
// and flagged, or invalid/infinite for non-numeric operands).
CMTime addTimes(CMTime a, CMTime b);
CMTime subtractTimes(CMTime a, CMTime b);
CMTime negateTime(CMTime a);

} // namespace ve

// Numeric CMTime operators. They live in the global namespace (CMTime's own namespace) so that
// argument-dependent lookup finds them everywhere, including inside std algorithms and test
// macros. == is numeric equality (like Swift's CMTime ==); see ve::identical for bit equality.
inline CMTime operator+(CMTime a, CMTime b) {
    return ve::addTimes(a, b);
}
inline CMTime operator-(CMTime a, CMTime b) {
    return ve::subtractTimes(a, b);
}
inline CMTime operator-(CMTime a) {
    return ve::negateTime(a);
}
inline bool operator==(CMTime a, CMTime b) {
    return CMTimeCompare(a, b) == 0;
}
inline bool operator!=(CMTime a, CMTime b) {
    return CMTimeCompare(a, b) != 0;
}
inline bool operator<(CMTime a, CMTime b) {
    return CMTimeCompare(a, b) < 0;
}
inline bool operator<=(CMTime a, CMTime b) {
    return CMTimeCompare(a, b) <= 0;
}
inline bool operator>(CMTime a, CMTime b) {
    return CMTimeCompare(a, b) > 0;
}
inline bool operator>=(CMTime a, CMTime b) {
    return CMTimeCompare(a, b) >= 0;
}

namespace ve {

inline CMTime makeTime(std::int64_t value, std::int32_t timescale) {
    return CMTimeMake(value, timescale);
}

inline bool isNumeric(CMTime t) {
    return CMTIME_IS_NUMERIC(t);
}

// True for a numeric, strictly positive time with a positive timescale (a usable frame duration).
inline bool isPositive(CMTime t) {
    return CMTIME_IS_NUMERIC(t) && t.timescale > 0 && t.value > 0;
}

// True for a numeric time with a positive timescale, epoch 0 and no kCMTimeFlags_HasBeenRounded:
// the only kind of numeric time the model stores.
inline bool isExactModelTime(CMTime t) {
    return CMTIME_IS_NUMERIC(t) && t.timescale > 0 && t.epoch == 0 && (t.flags & kCMTimeFlags_HasBeenRounded) == 0;
}

inline bool isRounded(CMTime t) {
    return (t.flags & kCMTimeFlags_HasBeenRounded) != 0;
}

// Bit-for-bit equality (value, timescale, flags, epoch).
inline bool identical(CMTime a, CMTime b) {
    return a.value == b.value && a.timescale == b.timescale && a.flags == b.flags && a.epoch == b.epoch;
}

inline CMTime minTime(CMTime a, CMTime b) {
    return CMTimeCompare(b, a) < 0 ? b : a;
}
inline CMTime maxTime(CMTime a, CMTime b) {
    return CMTimeCompare(b, a) > 0 ? b : a;
}
inline CMTime clampTime(CMTime t, CMTime lo, CMTime hi) {
    return maxTime(lo, minTime(t, hi));
}

inline double toSeconds(CMTime t) {
    return CMTimeGetSeconds(t);
}

// "value/timescale (seconds s)" for diagnostics.
std::string describe(CMTime t);

// ----- Rational scaling -----

// A rational num/den with den > 0. Speeds and other factors in the model are positive and
// reduced (see isReduced()).
struct Ratio {
    std::int64_t num = 1;
    std::int64_t den = 1;

    // num/den in lowest terms with a positive denominator; nullopt when den == 0 or the reduced
    // value does not fit (only possible for INT64_MIN).
    static std::optional<Ratio> reduced(std::int64_t num, std::int64_t den);

    Ratio inverse() const {
        return Ratio{den, num};
    }
    double toDouble() const {
        return static_cast<double>(num) / static_cast<double>(den);
    }
    bool isPositive() const {
        return num > 0 && den > 0;
    }
    bool isUnity() const {
        return num == den && den != 0;
    }
    // Positive denominator and gcd(num, den) == 1.
    bool isReduced() const;

    friend bool operator==(const Ratio &, const Ratio &) = default;
};

// Numeric ordering of two ratios with positive denominators (exact).
bool operator<(const Ratio &a, const Ratio &b);

// Best rational approximation of a positive finite `x` with denominator <= maxDenominator
// (continued fractions). Returns {0, 1} for non-positive or non-finite input or when the
// approximation's numerator would not fit in 64 bits.
Ratio approximateRatio(double x, std::int64_t maxDenominator);

// t * ratio exactly: t's timescale is kept when the result is an integer there, otherwise the
// reduced fraction. nullopt when not representable, for non-numeric t or a non-positive
// denominator.
std::optional<CMTime> checkedScale(CMTime t, Ratio ratio);

// t * ratio. Exact whenever checkedScale is; otherwise rounded to kPreciseTimescale and flagged
// kCMTimeFlags_HasBeenRounded (saturating to +/- infinity when even that overflows). For
// rendering and display; the model uses checkedScale. Non-numeric times are returned unchanged.
CMTime scaleTime(CMTime t, Ratio ratio);

// ----- Frame grid -----

enum class SnapMode {
    Floor, // largest grid time <= t
    Round, // nearest grid time; exact halves go toward +infinity
    Ceil,  // smallest grid time >= t
};

// Index of the grid frame selected by `mode`, or nullopt when `t` is not numeric, the frame
// duration is not positive, or the index does not fit in int64.
std::optional<std::int64_t> checkedFrameIndexAt(CMTime t, CMTime frameDuration, SnapMode mode);

// As checkedFrameIndexAt, but 0 for unusable input and saturated to the int64 range when the
// index does not fit.
std::int64_t frameIndexAt(CMTime t, CMTime frameDuration, SnapMode mode);

// Start time of frame `index`, expressed in frameDuration's timescale; nullopt when
// index * frameDuration.value overflows int64 or the frame duration is not positive.
std::optional<CMTime> checkedTimeForFrame(std::int64_t index, CMTime frameDuration);

// As checkedTimeForFrame, but +/- infinity on overflow (and invalid for an unusable frame
// duration).
CMTime timeForFrame(std::int64_t index, CMTime frameDuration);

// `t` moved onto the grid, expressed in frameDuration's timescale. Non-numeric `t` or a
// non-positive frame duration return `t` unchanged; a result outside the representable range
// is +/- infinity.
CMTime snapToFrame(CMTime t, CMTime frameDuration, SnapMode mode);

// True when `t` is exactly a multiple of `frameDuration`.
bool isOnFrameGrid(CMTime t, CMTime frameDuration);

// ----- Exact rationals -----

// An exact rational number of seconds, num/den with den > 0, kept in lowest terms. Carries
// intermediate results that must not be rounded and need not be representable as a CMTime
// (e.g. sourceIn + duration * speed). Operations return nullopt instead of overflowing 128 bits.
class ExactTime {
  public:
    ExactTime() = default;

    // Numeric times with a positive timescale only (flags and epoch are ignored).
    static std::optional<ExactTime> from(CMTime t);
    static std::optional<ExactTime> fraction(Int128 num, Int128 den);
    static ExactTime integer(std::int64_t value) {
        ExactTime e;
        e.num_ = value;
        return e;
    }

    Int128 numerator() const {
        return num_;
    }
    Int128 denominator() const {
        return den_;
    }

    std::optional<ExactTime> plus(const ExactTime &other) const;
    std::optional<ExactTime> minus(const ExactTime &other) const;
    std::optional<ExactTime> times(Ratio ratio) const;
    std::optional<ExactTime> dividedBy(Ratio ratio) const;
    ExactTime negated() const;

    // -1, 0 or 1. Exact and overflow-free.
    int compare(const ExactTime &other) const;
    int compare(CMTime t) const; // t must be numeric with a positive timescale

    // The exact CMTime (smallest timescale), or nullopt when not representable.
    std::optional<CMTime> toTime() const;
    // Exact when representable; otherwise rounded to kPreciseTimescale and flagged
    // kCMTimeFlags_HasBeenRounded (+/- infinity if even that overflows).
    CMTime toTimeRounded() const;
    double toDouble() const;

    // Index of the frame of the grid `frameDuration` selected by `mode`; nullopt for a
    // non-positive frame duration or when the index does not fit in int64.
    std::optional<std::int64_t> frameIndex(CMTime frameDuration, SnapMode mode) const;

    friend bool operator==(const ExactTime &a, const ExactTime &b) {
        return a.num_ == b.num_ && a.den_ == b.den_;
    }

  private:
    Int128 num_ = 0;
    Int128 den_ = 1;
};

// ----- Ranges -----

// Half-open time range [start, end).
struct TimeRange {
    CMTime start = kCMTimeZero;
    CMTime end = kCMTimeZero;

    static TimeRange fromDuration(CMTime start, CMTime duration) {
        return TimeRange{start, start + duration};
    }
    static TimeRange fromCMTimeRange(CMTimeRange range) {
        return TimeRange{range.start, range.start + range.duration};
    }
    CMTimeRange toCMTimeRange() const {
        return CMTimeRangeMake(start, end - start);
    }

    CMTime duration() const {
        return end - start;
    }
    bool isEmpty() const {
        return !(start < end);
    }
    bool contains(CMTime t) const {
        return start <= t && t < end;
    }
    bool contains(const TimeRange &other) const {
        return start <= other.start && other.end <= end;
    }
    bool intersects(const TimeRange &other) const {
        return start < other.end && other.start < end && !isEmpty() && !other.isEmpty();
    }
};

// Numeric equality of both ends.
inline bool operator==(const TimeRange &a, const TimeRange &b) {
    return a.start == b.start && a.end == b.end;
}

inline bool identical(const TimeRange &a, const TimeRange &b) {
    return identical(a.start, b.start) && identical(a.end, b.end);
}

// The overlap of two ranges, or nullopt when they do not overlap.
std::optional<TimeRange> intersection(const TimeRange &a, const TimeRange &b);

// Fraction of the way `t` is through `range` (0 at start, 1 at end), clamped to [0, 1].
// Computed exactly and converted to double once.
double fractionThrough(const TimeRange &range, CMTime t);

} // namespace ve
