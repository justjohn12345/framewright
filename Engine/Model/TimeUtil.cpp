#include "TimeUtil.h"

#include <cmath>
#include <cstdio>
#include <limits>

namespace ve {

namespace {

using Int128 = __int128;

Int128 absValue(Int128 v) {
    return v < 0 ? -v : v;
}

Int128 gcd128(Int128 a, Int128 b) {
    a = absValue(a);
    b = absValue(b);
    while (b != 0) {
        const Int128 r = a % b;
        a = b;
        b = r;
    }
    return a;
}

// floor(n / d) for d > 0.
Int128 floorDiv(Int128 n, Int128 d) {
    Int128 q = n / d;
    if ((n % d != 0) && (n < 0)) {
        --q;
    }
    return q;
}

// ceil(n / d) for d > 0.
Int128 ceilDiv(Int128 n, Int128 d) {
    return -floorDiv(-n, d);
}

// n / d rounded half away from zero, d > 0.
Int128 roundDivAwayFromZero(Int128 n, Int128 d) {
    return n >= 0 ? (2 * n + d) / (2 * d) : -((-2 * n + d) / (2 * d));
}

bool fitsInt64(Int128 v) {
    return v >= std::numeric_limits<std::int64_t>::min() && v <= std::numeric_limits<std::int64_t>::max();
}

std::int64_t saturate64(Int128 v) {
    if (v > std::numeric_limits<std::int64_t>::max()) {
        return std::numeric_limits<std::int64_t>::max();
    }
    if (v < std::numeric_limits<std::int64_t>::min()) {
        return std::numeric_limits<std::int64_t>::min();
    }
    return static_cast<std::int64_t>(v);
}

} // namespace

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
    char buffer[96];
    std::snprintf(buffer, sizeof buffer, "%lld/%d (%.6f s)", static_cast<long long>(t.value), t.timescale,
                  CMTimeGetSeconds(t));
    return buffer;
}

Ratio approximateRatio(double x, std::int64_t maxDenominator) {
    if (!std::isfinite(x) || x <= 0.0 || maxDenominator < 1) {
        return Ratio{0, 1};
    }
    // Convergents p/q of the continued fraction of x.
    std::int64_t p0 = 0, q0 = 1, p1 = 1, q1 = 0;
    double v = x;
    for (int i = 0; i < 64; ++i) {
        const double a = std::floor(v);
        if (a > 1e15) {
            break;
        }
        const auto ai = static_cast<std::int64_t>(a);
        const std::int64_t p2 = ai * p1 + p0;
        const std::int64_t q2 = ai * q1 + q0;
        if (q2 > maxDenominator) {
            // Best semiconvergent within the bound, if it beats the last convergent.
            const std::int64_t k = (maxDenominator - q0) / q1;
            const std::int64_t ps = p0 + k * p1;
            const std::int64_t qs = q0 + k * q1;
            const double errSemi = std::fabs(static_cast<double>(ps) / static_cast<double>(qs) - x);
            const double errConv = std::fabs(static_cast<double>(p1) / static_cast<double>(q1) - x);
            if (k > 0 && errSemi < errConv) {
                p1 = ps;
                q1 = qs;
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
    if (p1 == 0) {
        // x is smaller than 1 / maxDenominator.
        return Ratio{1, maxDenominator};
    }
    return Ratio{p1, q1};
}

CMTime scaleTime(CMTime t, Ratio ratio) {
    if (!CMTIME_IS_NUMERIC(t) || t.timescale <= 0 || ratio.den <= 0) {
        return t;
    }
    if (ratio.num == ratio.den) {
        return t;
    }
    const Int128 numerator = static_cast<Int128>(t.value) * ratio.num;
    // Keep t's timescale when the result is an integer there.
    if (numerator % ratio.den == 0) {
        const Int128 value = numerator / ratio.den;
        if (fitsInt64(value)) {
            return CMTimeMake(static_cast<std::int64_t>(value), t.timescale);
        }
    }
    Int128 value = numerator;
    Int128 scale = static_cast<Int128>(t.timescale) * ratio.den;
    const Int128 g = gcd128(value, scale);
    if (g > 1) {
        value /= g;
        scale /= g;
    }
    if (scale <= kCMTimeMaxTimescale && fitsInt64(value)) {
        return CMTimeMake(static_cast<std::int64_t>(value), static_cast<std::int32_t>(scale));
    }
    CMTime rounded = CMTimeMake(saturate64(roundDivAwayFromZero(value * kPreciseTimescale, scale)), kPreciseTimescale);
    rounded.flags |= kCMTimeFlags_HasBeenRounded;
    return rounded;
}

std::int64_t frameIndexAt(CMTime t, CMTime frameDuration, SnapMode mode) {
    if (!CMTIME_IS_NUMERIC(t) || t.timescale <= 0 || !isPositive(frameDuration)) {
        return 0;
    }
    // frame = t / fd = (t.value * fd.timescale) / (t.timescale * fd.value)
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
        index = floorDiv(2 * n + d, 2 * d);
        break;
    }
    return saturate64(index);
}

CMTime timeForFrame(std::int64_t index, CMTime frameDuration) {
    return CMTimeMake(saturate64(static_cast<Int128>(index) * frameDuration.value), frameDuration.timescale);
}

CMTime snapToFrame(CMTime t, CMTime frameDuration, SnapMode mode) {
    if (!CMTIME_IS_NUMERIC(t) || t.timescale <= 0 || !isPositive(frameDuration)) {
        return t;
    }
    return timeForFrame(frameIndexAt(t, frameDuration, mode), frameDuration);
}

bool isOnFrameGrid(CMTime t, CMTime frameDuration) {
    if (!CMTIME_IS_NUMERIC(t) || t.timescale <= 0 || !isPositive(frameDuration)) {
        return false;
    }
    const Int128 n = static_cast<Int128>(t.value) * frameDuration.timescale;
    const Int128 d = static_cast<Int128>(t.timescale) * frameDuration.value;
    return n % d == 0;
}

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
    const double f = CMTimeGetSeconds(t - range.start) / CMTimeGetSeconds(range.duration());
    return f < 0.0 ? 0.0 : (f > 1.0 ? 1.0 : f);
}

} // namespace ve
