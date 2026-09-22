// CMTime helpers shared by the model, edit operations and the scheduler.
//
// Conventions:
// - Comparison and arithmetic operators on CMTime (declared in the global namespace, below)
//   are numeric: 1/2 == 2/4. Use identical() for bit-for-bit comparison (value, timescale, flags, epoch).
// - Time ranges are half-open [start, end).
// - Frame grids start at time zero: frame n of a grid with frame duration fd covers
//   [n * fd, (n + 1) * fd).

#pragma once

#include <CoreMedia/CMTime.h>
#include <CoreMedia/CMTimeRange.h>

#include <cstdint>
#include <optional>
#include <string>

// Numeric CMTime operators. They live in the global namespace (CMTime's own namespace) so that
// argument-dependent lookup finds them everywhere, including inside std algorithms and test
// macros. == is numeric equality (like Swift's CMTime ==); see ve::identical for bit equality.
inline CMTime operator+(CMTime a, CMTime b) {
    return CMTimeAdd(a, b);
}
inline CMTime operator-(CMTime a, CMTime b) {
    return CMTimeSubtract(a, b);
}
inline CMTime operator-(CMTime a) {
    return CMTIME_IS_NUMERIC(a) ? CMTimeMake(-a.value, a.timescale) : a;
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

// A timescale divisible by every common video and audio rate (24000, 30000, 60000, 600,
// 44100, 48000, 96000, ...). Used when an exact rational result does not fit a CMTime.
inline constexpr std::int32_t kPreciseTimescale = 705600000;

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

// A positive rational num/den.
struct Ratio {
    std::int64_t num = 1;
    std::int64_t den = 1;

    Ratio inverse() const {
        return Ratio{den, num};
    }
    double toDouble() const {
        return static_cast<double>(num) / static_cast<double>(den);
    }
    friend bool operator==(const Ratio &, const Ratio &) = default;
};

// Best rational approximation of a positive finite `x` with denominator <= maxDenominator
// (continued fractions). Returns {0, 1} for non-positive or non-finite input.
Ratio approximateRatio(double x, std::int64_t maxDenominator);

// t * ratio. Exact whenever the result is representable with a timescale <= kCMTimeMaxTimescale
// (t's own timescale is kept when possible); otherwise rounded to kPreciseTimescale and flagged
// kCMTimeFlags_HasBeenRounded. Non-numeric times are returned unchanged.
CMTime scaleTime(CMTime t, Ratio ratio);

// ----- Frame grid -----

enum class SnapMode {
    Floor, // largest grid time <= t
    Round, // nearest grid time; exact halves go toward +infinity
    Ceil,  // smallest grid time >= t
};

// Index of the grid frame selected by `mode`. `frameDuration` must be positive and `t` numeric
// (otherwise 0 is returned).
std::int64_t frameIndexAt(CMTime t, CMTime frameDuration, SnapMode mode);

// Start time of frame `index`, expressed in frameDuration's timescale.
CMTime timeForFrame(std::int64_t index, CMTime frameDuration);

// `t` moved onto the grid, expressed in frameDuration's timescale. Non-numeric `t` or a
// non-positive frame duration return `t` unchanged.
CMTime snapToFrame(CMTime t, CMTime frameDuration, SnapMode mode);

// True when `t` is exactly a multiple of `frameDuration`.
bool isOnFrameGrid(CMTime t, CMTime frameDuration);

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
double fractionThrough(const TimeRange &range, CMTime t);

} // namespace ve
