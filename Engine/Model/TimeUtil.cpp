#include "TimeUtil.h"

#include <cassert>
#include <cmath>
#include <cstdio>
#include <limits>

namespace ve {

namespace {

using UInt128 = unsigned __int128;

constexpr Int128 kInt64Min = std::numeric_limits<std::int64_t>::min();
constexpr Int128 kInt64Max = std::numeric_limits<std::int64_t>::max();

UInt128 magnitude(Int128 v) {
    return v < 0 ? UInt128(0) - static_cast<UInt128>(v) : static_cast<UInt128>(v);
}

// gcd(|a|, |b|); gcd(0, 0) == 0. Computed on magnitudes so that no negation can overflow.
Int128 gcd128(Int128 a, Int128 b) {
    UInt128 x = magnitude(a);
    UInt128 y = magnitude(b);
    while (y != 0) {
        const UInt128 r = x % y;
        x = y;
        y = r;
    }
    // Every caller passes values below 2^127 in magnitude, so the gcd fits.
    return static_cast<Int128>(x);
}

bool fitsInt64(Int128 v) {
    return v >= kInt64Min && v <= kInt64Max;
}

bool checkedMul(Int128 a, Int128 b, Int128 &out) {
    return !__builtin_mul_overflow(a, b, &out);
}

bool checkedAddInt(Int128 a, Int128 b, Int128 &out) {
    return !__builtin_add_overflow(a, b, &out);
}

// floor(n / d) for d > 0.
Int128 floorDiv(Int128 n, Int128 d) {
    assert(d > 0);
    Int128 q = n / d;
    if ((n % d != 0) && (n < 0)) {
        --q;
    }
    return q;
}

// ceil(n / d) for d > 0.
Int128 ceilDiv(Int128 n, Int128 d) {
    assert(d > 0);
    Int128 q = n / d;
    if ((n % d != 0) && (n > 0)) {
        ++q;
    }
    return q;
}

// Numeric with a usable (positive) timescale.
bool usable(CMTime t) {
    return CMTIME_IS_NUMERIC(t) && t.timescale > 0;
}

CMTime makeRaw(std::int64_t value, std::int32_t timescale, CMTimeFlags flags, CMTimeEpoch epoch) {
    CMTime t;
    t.value = value;
    t.timescale = timescale;
    t.flags = flags;
    t.epoch = epoch;
    return t;
}

// value/timescale as a CMTime: as given when it fits, else reduced, else nullopt.
std::optional<CMTime> fitTime(Int128 value, Int128 timescale, CMTimeFlags flags, CMTimeEpoch epoch) {
    assert(timescale > 0);
    if (timescale <= kCMTimeMaxTimescale && fitsInt64(value)) {
        return makeRaw(static_cast<std::int64_t>(value), static_cast<std::int32_t>(timescale), flags, epoch);
    }
    const Int128 g = gcd128(value, timescale);
    if (g > 1) {
        value /= g;
        timescale /= g;
    }
    if (timescale <= kCMTimeMaxTimescale && fitsInt64(value)) {
        return makeRaw(static_cast<std::int64_t>(value), static_cast<std::int32_t>(timescale), flags, epoch);
    }
    return std::nullopt;
}

CMTimeFlags exactFlags(CMTime a, CMTime b) {
    return kCMTimeFlags_Valid | ((a.flags | b.flags) & kCMTimeFlags_HasBeenRounded);
}

std::optional<CMTime> combine(CMTime a, CMTime b, bool subtract) {
    if (!usable(a) || !usable(b) || a.epoch != b.epoch) {
        return std::nullopt;
    }
    const Int128 ta = a.timescale;
    const Int128 tb = b.timescale;
    const Int128 common = ta / gcd128(ta, tb) * tb; // < 2^62
    // |value| * (common / timescale) < 2^63 * 2^31, so neither product nor the sum can overflow.
    const Int128 left = static_cast<Int128>(a.value) * (common / ta);
    const Int128 right = static_cast<Int128>(b.value) * (common / tb);
    return fitTime(subtract ? left - right : left + right, common, exactFlags(a, b), a.epoch);
}

// value/scale rounded to kPreciseTimescale (half toward +infinity), flagged as rounded;
// +/- infinity when the rounded value does not fit int64. scale > 0.
CMTime roundToPrecise(Int128 value, Int128 scale, CMTimeEpoch epoch) {
    assert(scale > 0);
    const Int128 q = floorDiv(value, scale);
    Int128 r = value - q * scale; // 0 <= r < scale
    // The fractional part is round(r / scale * kPreciseTimescale). Keep 2 * r * kPreciseTimescale
    // below 2^127 by dropping low bits of r and scale together when scale is huge; the relative
    // error (< 2^-94) is far below the 1 / kPreciseTimescale resolution of the result.
    while (scale > (static_cast<Int128>(1) << 94)) {
        r >>= 1;
        scale >>= 1;
    }
    Int128 whole = 0;
    Int128 total = 0;
    const Int128 fractional = floorDiv(2 * r * kPreciseTimescale + scale, 2 * scale);
    if (!checkedMul(q, kPreciseTimescale, whole) || !checkedAddInt(whole, fractional, total) || !fitsInt64(total)) {
        return value < 0 ? kCMTimeNegativeInfinity : kCMTimePositiveInfinity;
    }
    CMTime rounded = makeRaw(static_cast<std::int64_t>(total), kPreciseTimescale,
                             kCMTimeFlags_Valid | kCMTimeFlags_HasBeenRounded, epoch);
    return rounded;
}

// Overflow-free comparison of a/b and c/d for b, d > 0 (continued-fraction expansion: compare
// the integer parts, then the reciprocals of the fractional parts in reverse order).
int compareFractions(Int128 a, Int128 b, Int128 c, Int128 d) {
    assert(b > 0 && d > 0);
    int sign = 1;
    for (;;) {
        const Int128 qa = floorDiv(a, b);
        const Int128 qc = floorDiv(c, d);
        if (qa != qc) {
            return qa < qc ? -sign : sign;
        }
        const Int128 ra = a - qa * b; // 0 <= ra < b
        const Int128 rc = c - qc * d; // 0 <= rc < d
        if (ra == 0 || rc == 0) {
            if (ra == rc) {
                return 0;
            }
            return ra == 0 ? -sign : sign;
        }
        // ra/b < rc/d  <=>  b/ra > d/rc.
        a = b;
        b = ra;
        c = d;
        d = rc;
        sign = -sign;
    }
}

} // namespace

// ----- Exact CMTime arithmetic -----

std::optional<CMTime> checkedAdd(CMTime a, CMTime b) {
    return combine(a, b, false);
}

std::optional<CMTime> checkedSubtract(CMTime a, CMTime b) {
    return combine(a, b, true);
}

std::optional<CMTime> checkedNegate(CMTime a) {
    if (!usable(a)) {
        return std::nullopt;
    }
    return fitTime(-static_cast<Int128>(a.value), a.timescale, a.flags, a.epoch);
}

CMTime addTimes(CMTime a, CMTime b) {
    if (const auto exact = checkedAdd(a, b)) {
        return *exact;
    }
    return CMTimeAdd(a, b);
}

CMTime subtractTimes(CMTime a, CMTime b) {
    if (const auto exact = checkedSubtract(a, b)) {
        return *exact;
    }
    return CMTimeSubtract(a, b);
}

CMTime negateTime(CMTime a) {
    if (const auto exact = checkedNegate(a)) {
        return *exact;
    }
    if (CMTIME_IS_POSITIVE_INFINITY(a)) {
        return kCMTimeNegativeInfinity;
    }
    if (CMTIME_IS_NEGATIVE_INFINITY(a)) {
        return kCMTimePositiveInfinity;
    }
    if (!CMTIME_IS_NUMERIC(a)) {
        return a; // invalid or indefinite
    }
    return CMTimeMultiply(a, -1); // INT64_MIN over an odd timescale: CoreMedia's saturated result
}

std::string describe(CMTime t) {
    if (CMTIME_IS_INVALID(t)) {
        return "invalid";
    }
    if (CMTIME_IS_POSITIVE_INFINITY(t)) {
        return "+infinity";
    }
    if (CMTIME_IS_NEGATIVE_INFINITY(t)) {
        return "-infinity";
    }
    if (CMTIME_IS_INDEFINITE(t)) {
        return "indefinite";
    }
    char buffer[128];
    std::snprintf(buffer, sizeof buffer, "%lld/%d (%.6f s)%s", static_cast<long long>(t.value), t.timescale,
                  CMTimeGetSeconds(t), isRounded(t) ? " rounded" : "");
    return buffer;
}

// ----- Ratio -----

std::optional<Ratio> Ratio::reduced(std::int64_t num, std::int64_t den) {
    if (den == 0) {
        return std::nullopt;
    }
    Int128 n = num;
    Int128 d = den;
    if (d < 0) {
        n = -n;
        d = -d;
    }
    const Int128 g = gcd128(n, d);
    if (g > 1) {
        n /= g;
        d /= g;
    }
    if (!fitsInt64(n) || !fitsInt64(d)) {
        return std::nullopt;
    }
    return Ratio{static_cast<std::int64_t>(n), static_cast<std::int64_t>(d)};
}

bool Ratio::isReduced() const {
    return den > 0 && gcd128(num, den) == 1;
}

bool operator<(const Ratio &a, const Ratio &b) {
    return static_cast<Int128>(a.num) * b.den < static_cast<Int128>(b.num) * a.den;
}

Ratio approximateRatio(double x, std::int64_t maxDenominator) {
    if (!std::isfinite(x) || x <= 0.0 || maxDenominator < 1) {
        return Ratio{0, 1};
    }
    // Convergents p/q of the continued fraction of x, in 128 bits so that no step can overflow.
    Int128 p0 = 0, q0 = 1, p1 = 1, q1 = 0;
    double v = x;
    for (int i = 0; i < 64; ++i) {
        const double a = std::floor(v);
        if (a > 1e15) {
            break;
        }
        const auto ai = static_cast<Int128>(a);
        const Int128 p2 = ai * p1 + p0; // ai < 2^50 and p1 <= 2^63: fits
        const Int128 q2 = ai * q1 + q0;
        if (q2 > maxDenominator || p2 > kInt64Max) {
            if (q1 > 0 && q2 > maxDenominator) {
                // Best semiconvergent within the bound, if it beats the last convergent.
                const Int128 k = (maxDenominator - q0) / q1;
                const Int128 ps = p0 + k * p1;
                const Int128 qs = q0 + k * q1;
                const double errSemi = std::fabs(static_cast<double>(ps) / static_cast<double>(qs) - x);
                const double errConv = std::fabs(static_cast<double>(p1) / static_cast<double>(q1) - x);
                if (k > 0 && errSemi < errConv && ps <= kInt64Max) {
                    p1 = ps;
                    q1 = qs;
                }
            }
            break;
        }
        p0 = p1;
        q0 = q1;
        p1 = p2;
        q1 = q2;
        const double fraction = v - a;
        if (fraction < 1e-12) {
            break;
        }
        v = 1.0 / fraction;
    }
    if (q1 == 0) {
        return Ratio{0, 1}; // x too large to approximate
    }
    if (p1 == 0) {
        // x is smaller than 1 / maxDenominator.
        return Ratio{1, maxDenominator};
    }
    return Ratio{static_cast<std::int64_t>(p1), static_cast<std::int64_t>(q1)};
}

std::optional<CMTime> checkedScale(CMTime t, Ratio ratio) {
    if (!usable(t) || ratio.den <= 0) {
        return std::nullopt;
    }
    if (ratio.num == ratio.den) {
        return t;
    }
    // |value * num| < 2^126 and timescale * den < 2^94: no overflow.
    const Int128 numerator = static_cast<Int128>(t.value) * ratio.num;
    if (numerator % ratio.den == 0) {
        const Int128 value = numerator / ratio.den;
        if (fitsInt64(value)) {
            return makeRaw(static_cast<std::int64_t>(value), t.timescale, t.flags, t.epoch);
        }
    }
    return fitTime(numerator, static_cast<Int128>(t.timescale) * ratio.den, t.flags, t.epoch);
}

CMTime scaleTime(CMTime t, Ratio ratio) {
    if (!usable(t) || ratio.den <= 0) {
        return t;
    }
    if (const auto exact = checkedScale(t, ratio)) {
        return *exact;
    }
    Int128 value = static_cast<Int128>(t.value) * ratio.num;
    Int128 scale = static_cast<Int128>(t.timescale) * ratio.den;
    const Int128 g = gcd128(value, scale);
    if (g > 1) {
        value /= g;
        scale /= g;
    }
    return roundToPrecise(value, scale, t.epoch);
}

// ----- Frame grid -----

std::optional<std::int64_t> checkedFrameIndexAt(CMTime t, CMTime frameDuration, SnapMode mode) {
    if (!usable(t) || !isPositive(frameDuration)) {
        return std::nullopt;
    }
    // frame = t / fd = (t.value * fd.timescale) / (t.timescale * fd.value); both < 2^94.
    const Int128 n = static_cast<Int128>(t.value) * frameDuration.timescale;
    const Int128 d = static_cast<Int128>(t.timescale) * frameDuration.value;
    Int128 index = 0;
    switch (mode) {
    case SnapMode::Floor:
        index = floorDiv(n, d);
        break;
    case SnapMode::Ceil:
        index = ceilDiv(n, d);
        break;
    case SnapMode::Round:
        index = floorDiv(2 * n + d, 2 * d); // < 2^96
        break;
    }
    if (!fitsInt64(index)) {
        return std::nullopt;
    }
    return static_cast<std::int64_t>(index);
}

std::int64_t frameIndexAt(CMTime t, CMTime frameDuration, SnapMode mode) {
    if (!usable(t) || !isPositive(frameDuration)) {
        return 0;
    }
    if (const auto index = checkedFrameIndexAt(t, frameDuration, mode)) {
        return *index;
    }
    return t.value < 0 ? std::numeric_limits<std::int64_t>::min() : std::numeric_limits<std::int64_t>::max();
}

std::optional<CMTime> checkedTimeForFrame(std::int64_t index, CMTime frameDuration) {
    if (!isPositive(frameDuration)) {
        return std::nullopt;
    }
    const Int128 value = static_cast<Int128>(index) * frameDuration.value;
    if (!fitsInt64(value)) {
        return std::nullopt;
    }
    return CMTimeMake(static_cast<std::int64_t>(value), frameDuration.timescale);
}

CMTime timeForFrame(std::int64_t index, CMTime frameDuration) {
    if (!isPositive(frameDuration)) {
        return kCMTimeInvalid;
    }
    if (const auto time = checkedTimeForFrame(index, frameDuration)) {
        return *time;
    }
    return index < 0 ? kCMTimeNegativeInfinity : kCMTimePositiveInfinity;
}

CMTime snapToFrame(CMTime t, CMTime frameDuration, SnapMode mode) {
    if (!usable(t) || !isPositive(frameDuration)) {
        return t;
    }
    const auto index = checkedFrameIndexAt(t, frameDuration, mode);
    if (!index) {
        return t.value < 0 ? kCMTimeNegativeInfinity : kCMTimePositiveInfinity;
    }
    return timeForFrame(*index, frameDuration);
}

bool isOnFrameGrid(CMTime t, CMTime frameDuration) {
    if (!usable(t) || !isPositive(frameDuration)) {
        return false;
    }
    const Int128 n = static_cast<Int128>(t.value) * frameDuration.timescale;
    const Int128 d = static_cast<Int128>(t.timescale) * frameDuration.value;
    return n % d == 0;
}

// ----- ExactTime -----

std::optional<ExactTime> ExactTime::fraction(Int128 num, Int128 den) {
    if (den == 0) {
        return std::nullopt;
    }
    // Magnitudes of 2^127 cannot be negated; callers never produce them, but refuse them anyway.
    constexpr Int128 kLimit = static_cast<Int128>(static_cast<UInt128>(1) << 126);
    if (num >= kLimit || num <= -kLimit || den >= kLimit || den <= -kLimit) {
        return std::nullopt;
    }
    if (den < 0) {
        num = -num;
        den = -den;
    }
    const Int128 g = gcd128(num, den);
    if (g > 1) {
        num /= g;
        den /= g;
    }
    ExactTime e;
    e.num_ = num;
    e.den_ = den;
    return e;
}

std::optional<ExactTime> ExactTime::from(CMTime t) {
    if (!usable(t)) {
        return std::nullopt;
    }
    return fraction(t.value, t.timescale);
}

std::optional<ExactTime> ExactTime::plus(const ExactTime &other) const {
    // a/b + c/d = (a * (d/g) + c * (b/g)) / (b/g * d), g = gcd(b, d).
    const Int128 g = gcd128(den_, other.den_);
    const Int128 bg = den_ / g;
    const Int128 dg = other.den_ / g;
    Int128 left = 0, right = 0, num = 0, den = 0;
    if (!checkedMul(num_, dg, left) || !checkedMul(other.num_, bg, right) || !checkedAddInt(left, right, num) ||
        !checkedMul(bg, other.den_, den)) {
        return std::nullopt;
    }
    return fraction(num, den);
}

std::optional<ExactTime> ExactTime::minus(const ExactTime &other) const {
    return plus(other.negated());
}

ExactTime ExactTime::negated() const {
    ExactTime e;
    e.num_ = -num_;
    e.den_ = den_;
    return e;
}

std::optional<ExactTime> ExactTime::times(Ratio ratio) const {
    if (ratio.den <= 0) {
        return std::nullopt;
    }
    // (a/b) * (p/q): cancel gcd(a, q) and gcd(p, b) first.
    const Int128 g1 = num_ == 0 ? 1 : gcd128(num_, ratio.den);
    const Int128 g2 = ratio.num == 0 ? 1 : gcd128(ratio.num, den_);
    Int128 num = 0, den = 0;
    if (!checkedMul(num_ / g1, ratio.num / g2, num) || !checkedMul(den_ / g2, ratio.den / g1, den)) {
        return std::nullopt;
    }
    return fraction(num, den);
}

std::optional<ExactTime> ExactTime::dividedBy(Ratio ratio) const {
    if (ratio.num == 0 || ratio.den <= 0) {
        return std::nullopt;
    }
    const Ratio inverse = ratio.num > 0 ? Ratio{ratio.den, ratio.num} : Ratio{-ratio.den, -ratio.num};
    if (inverse.den <= 0) {
        return std::nullopt; // -INT64_MIN
    }
    return times(inverse);
}

int ExactTime::compare(const ExactTime &other) const {
    return compareFractions(num_, den_, other.num_, other.den_);
}

int ExactTime::compare(CMTime t) const {
    const auto other = from(t);
    assert(other.has_value());
    return other ? compare(*other) : 0;
}

std::optional<CMTime> ExactTime::toTime() const {
    if (den_ <= kCMTimeMaxTimescale && fitsInt64(num_)) {
        return CMTimeMake(static_cast<std::int64_t>(num_), static_cast<std::int32_t>(den_));
    }
    return std::nullopt;
}

CMTime ExactTime::toTimeRounded() const {
    if (const auto exact = toTime()) {
        return *exact;
    }
    return roundToPrecise(num_, den_, 0);
}

double ExactTime::toDouble() const {
    return static_cast<double>(num_) / static_cast<double>(den_);
}

std::optional<std::int64_t> ExactTime::frameIndex(CMTime frameDuration, SnapMode mode) const {
    if (!isPositive(frameDuration)) {
        return std::nullopt;
    }
    // Frames = this / frameDuration = this * (timescale / value).
    const auto frames = times(Ratio{frameDuration.timescale, frameDuration.value});
    if (!frames) {
        return std::nullopt;
    }
    const Int128 n = frames->num_;
    const Int128 d = frames->den_;
    Int128 index = 0;
    switch (mode) {
    case SnapMode::Floor:
        index = floorDiv(n, d);
        break;
    case SnapMode::Ceil:
        index = ceilDiv(n, d);
        break;
    case SnapMode::Round: {
        Int128 twiceN = 0, twiceD = 0, shifted = 0;
        if (!checkedMul(n, 2, twiceN) || !checkedMul(d, 2, twiceD) || !checkedAddInt(twiceN, d, shifted)) {
            return std::nullopt;
        }
        index = floorDiv(shifted, twiceD);
        break;
    }
    }
    if (!fitsInt64(index)) {
        return std::nullopt;
    }
    return static_cast<std::int64_t>(index);
}

// ----- Ranges -----

std::optional<TimeRange> intersection(const TimeRange &a, const TimeRange &b) {
    TimeRange r{maxTime(a.start, b.start), minTime(a.end, b.end)};
    if (r.isEmpty()) {
        return std::nullopt;
    }
    return r;
}

double fractionThrough(const TimeRange &range, CMTime t) {
    if (range.isEmpty()) {
        return t < range.start ? 0.0 : 1.0;
    }
    if (t <= range.start) {
        return 0.0;
    }
    if (t >= range.end) {
        return 1.0;
    }
    const auto start = ExactTime::from(range.start);
    const auto end = ExactTime::from(range.end);
    const auto at = ExactTime::from(t);
    if (start && end && at) {
        const auto into = at->minus(*start);
        const auto length = end->minus(*start);
        if (into && length && length->numerator() > 0) {
            // (a/b) / (c/d) = (a * d) / (b * c), exact when the products fit.
            Int128 num = 0, den = 0;
            if (checkedMul(into->numerator(), length->denominator(), num) &&
                checkedMul(into->denominator(), length->numerator(), den)) {
                if (const auto q = ExactTime::fraction(num, den)) {
                    return q->toDouble();
                }
            }
        }
    }
    const double f = CMTimeGetSeconds(t - range.start) / CMTimeGetSeconds(range.duration());
    return f < 0.0 ? 0.0 : (f > 1.0 ? 1.0 : f);
}

} // namespace ve
