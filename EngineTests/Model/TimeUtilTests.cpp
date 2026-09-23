#include "ModelFixtures.h"

#include <cmath>
#include <limits>

using namespace ve;

namespace {

const CMTime k23976 = CMTimeMake(1001, 24000);
const CMTime k2997 = CMTimeMake(1001, 30000);
const CMTime k30 = CMTimeMake(1, 30);
const CMTime k60 = CMTimeMake(1, 60);

std::int64_t floorF(CMTime t, CMTime fd) {
    return frameIndexAt(t, fd, SnapMode::Floor);
}
std::int64_t roundF(CMTime t, CMTime fd) {
    return frameIndexAt(t, fd, SnapMode::Round);
}
std::int64_t ceilF(CMTime t, CMTime fd) {
    return frameIndexAt(t, fd, SnapMode::Ceil);
}

} // namespace

TEST_CASE("TimeUtil: numeric operators compare values across timescales; identical() compares bits") {
    const CMTime half = CMTimeMake(1, 2);
    const CMTime half600 = CMTimeMake(300, 600);
    CHECK(half == half600);
    CHECK_FALSE(identical(half, half600));
    CHECK(identical(half, CMTimeMake(1, 2)));
    CHECK(CMTimeMake(1, 3) < half);
    CHECK(half + half == CMTimeMake(1, 1));
    CHECK(half - CMTimeMake(1, 1) == CMTimeMake(-1, 2));
    CHECK(-half == CMTimeMake(-1, 2));
    CHECK(identical(-kCMTimePositiveInfinity, kCMTimeNegativeInfinity));
    CHECK(identical(-kCMTimeInvalid, kCMTimeInvalid));
    CHECK(minTime(half, CMTimeMake(1, 3)) == CMTimeMake(1, 3));
    CHECK(maxTime(half, CMTimeMake(1, 3)) == half);
    CHECK(clampTime(CMTimeMake(5, 1), kCMTimeZero, half) == half);
    CHECK(clampTime(CMTimeMake(-5, 1), kCMTimeZero, half) == kCMTimeZero);
    CHECK(kCMTimePositiveInfinity > CMTimeMake(1000000, 1));
    CHECK(kCMTimeNegativeInfinity < CMTimeMake(-1000000, 1));
}

TEST_CASE("TimeUtil: 23.976 fps snapping (1001/24000)") {
    // Frame n starts at n * 1001 / 24000 s. 1 s lies between frames 23 (0.959 s) and 24 (1.001 s).
    const CMTime oneSecond = CMTimeMake(1, 1);
    CHECK(floorF(oneSecond, k23976) == 23);
    CHECK(ceilF(oneSecond, k23976) == 24);
    CHECK(roundF(oneSecond, k23976) == 24); // 23.976 frames rounds up
    CHECK(identical(snapToFrame(oneSecond, k23976, SnapMode::Floor), CMTimeMake(23 * 1001, 24000)));
    CHECK(identical(snapToFrame(oneSecond, k23976, SnapMode::Ceil), CMTimeMake(24 * 1001, 24000)));
    CHECK_FALSE(isOnFrameGrid(oneSecond, k23976));

    // Exactly on the grid, expressed in another timescale (frame 1000 = 1001/24 s).
    const CMTime frame1000 = CMTimeMake(5005, 120);
    CHECK(isOnFrameGrid(frame1000, k23976));
    CHECK(floorF(frame1000, k23976) == 1000);
    CHECK(roundF(frame1000, k23976) == 1000);
    CHECK(ceilF(frame1000, k23976) == 1000);
    CHECK(identical(snapToFrame(frame1000, k23976, SnapMode::Round), CMTimeMake(1001000, 24000)));

    // Just past frame 10: floor stays, ceil moves on, round stays.
    const CMTime justAfter10 = CMTimeMake(10 * 1001 + 1, 24000);
    CHECK(floorF(justAfter10, k23976) == 10);
    CHECK(ceilF(justAfter10, k23976) == 11);
    CHECK(roundF(justAfter10, k23976) == 10);

    // Negative times.
    const CMTime minusOne = CMTimeMake(-1, 1);
    CHECK(floorF(minusOne, k23976) == -24);
    CHECK(ceilF(minusOne, k23976) == -23);
    CHECK(roundF(minusOne, k23976) == -24);
    CHECK(identical(snapToFrame(minusOne, k23976, SnapMode::Ceil), CMTimeMake(-23 * 1001, 24000)));
}

TEST_CASE("TimeUtil: 29.97 fps snapping (1001/30000)") {
    const CMTime tenSeconds = CMTimeMake(10, 1); // 299.7 frames
    CHECK(floorF(tenSeconds, k2997) == 299);
    CHECK(roundF(tenSeconds, k2997) == 300);
    CHECK(ceilF(tenSeconds, k2997) == 300);
    CHECK(timeForFrame(300, k2997) == CMTimeMake(300300, 30000));
    CHECK(identical(timeForFrame(-2, k2997), CMTimeMake(-2002, 30000)));

    // One hour at 29.97 is 107892.107... frames.
    const CMTime hour = CMTimeMake(3600, 1);
    CHECK(floorF(hour, k2997) == 107892);
    CHECK(ceilF(hour, k2997) == 107893);

    const CMTime negative = CMTimeMake(-5, 1); // -149.85 frames
    CHECK(floorF(negative, k2997) == -150);
    CHECK(roundF(negative, k2997) == -150);
    CHECK(ceilF(negative, k2997) == -149);
}

TEST_CASE("TimeUtil: 30 fps snapping, halves and negatives") {
    const CMTime halfFrame = CMTimeMake(1, 60);
    CHECK(floorF(halfFrame, k30) == 0);
    CHECK(roundF(halfFrame, k30) == 1); // exact halves go toward +infinity
    CHECK(ceilF(halfFrame, k30) == 1);

    const CMTime minusHalf = CMTimeMake(-1, 60);
    CHECK(floorF(minusHalf, k30) == -1);
    CHECK(roundF(minusHalf, k30) == 0);
    CHECK(ceilF(minusHalf, k30) == 0);

    const CMTime minusOneAndHalf = CMTimeMake(-3, 60);
    CHECK(roundF(minusOneAndHalf, k30) == -1);
    CHECK(floorF(minusOneAndHalf, k30) == -2);

    // A timescale unrelated to the frame rate (90 kHz MPEG clock).
    const CMTime pts = CMTimeMake(93003, 90000); // 1.0333667 s = 31.001 frames
    CHECK(floorF(pts, k30) == 31);
    CHECK(roundF(pts, k30) == 31);
    CHECK(ceilF(pts, k30) == 32);
    CHECK(identical(snapToFrame(pts, k30, SnapMode::Floor), CMTimeMake(31, 30)));

    CHECK(isOnFrameGrid(CMTimeMake(20, 600), k30));
    CHECK_FALSE(isOnFrameGrid(CMTimeMake(21, 600), k30));
    CHECK(isOnFrameGrid(kCMTimeZero, k30));
}

TEST_CASE("TimeUtil: 60 fps snapping") {
    CHECK(floorF(CMTimeMake(45000, 90000), k60) == 30);
    CHECK(roundF(CMTimeMake(1, 30), k60) == 2);
    CHECK(roundF(CMTimeMake(1, 120), k60) == 1);  // half a frame -> up
    CHECK(roundF(CMTimeMake(-1, 120), k60) == 0); // -half -> toward +infinity
    CHECK(floorF(CMTimeMake(-1, 120), k60) == -1);
    CHECK(ceilF(CMTimeMake(119, 7200), k60) == 1);
    CHECK(identical(snapToFrame(CMTimeMake(1, 7), k60, SnapMode::Round), CMTimeMake(9, 60))); // 8.57 frames
}

TEST_CASE("TimeUtil: snapping never overflows at large values and passes through invalid input") {
    const CMTime tenHours = CMTimeMake(36000LL * kPreciseTimescale, kPreciseTimescale);
    CHECK(floorF(tenHours, k2997) == 1078921);
    CHECK(floorF(tenHours, k30) == 1080000);
    CHECK(identical(snapToFrame(kCMTimeInvalid, k30, SnapMode::Round), kCMTimeInvalid));
    CHECK(identical(snapToFrame(CMTimeMake(1, 3), kCMTimeInvalid, SnapMode::Round), CMTimeMake(1, 3)));
    CHECK(identical(snapToFrame(CMTimeMake(1, 3), kCMTimeZero, SnapMode::Round), CMTimeMake(1, 3)));
    CHECK_FALSE(isOnFrameGrid(kCMTimeInvalid, k30));
    CHECK(frameIndexAt(kCMTimePositiveInfinity, k30, SnapMode::Floor) == 0);
}

TEST_CASE("TimeUtil: approximateRatio finds small exact fractions") {
    CHECK(approximateRatio(2.0, 1000) == Ratio{2, 1});
    CHECK(approximateRatio(0.5, 1000) == Ratio{1, 2});
    CHECK(approximateRatio(1.5, 1000) == Ratio{3, 2});
    CHECK(approximateRatio(1.0 / 3.0, 1000) == Ratio{1, 3});
    CHECK(approximateRatio(0.333, 1000) == Ratio{333, 1000});
    CHECK(approximateRatio(M_PI, 1000) == Ratio{355, 113});
    CHECK(approximateRatio(0.0001, 1000) == Ratio{1, 1000});
    CHECK(approximateRatio(-1.0, 1000) == Ratio{0, 1});
    CHECK(approximateRatio(NAN, 1000) == Ratio{0, 1});
}

TEST_CASE("TimeUtil: scaleTime is exact and reversible for rational factors") {
    const CMTime tenSeconds = CMTimeMake(6000, 600);
    CHECK(identical(scaleTime(tenSeconds, Ratio{1, 2}), CMTimeMake(3000, 600))); // keeps timescale
    CHECK(identical(scaleTime(tenSeconds, Ratio{2, 1}), CMTimeMake(12000, 600)));
    const CMTime third = scaleTime(CMTimeMake(1, 30), Ratio{1, 3});
    CHECK(third == CMTimeMake(1, 90));
    CHECK((third.flags & kCMTimeFlags_HasBeenRounded) == 0);
    CHECK(scaleTime(third, Ratio{3, 1}) == CMTimeMake(1, 30));

    // Arbitrary ratio round trip.
    const Ratio r = approximateRatio(1.7, 1000);
    const CMTime d = CMTimeMake(37, 30);
    CHECK(scaleTime(scaleTime(d, r), r.inverse()) == d);

    // Negative values.
    CHECK(scaleTime(CMTimeMake(-3, 30), Ratio{2, 3}) == CMTimeMake(-2, 30));

    // When the exact timescale would exceed kCMTimeMaxTimescale the result is rounded and flagged.
    const CMTime awkward = CMTimeMake(1, 999999937); // prime timescale
    const CMTime rounded = scaleTime(awkward, Ratio{1, 7});
    CHECK((rounded.flags & kCMTimeFlags_HasBeenRounded) != 0);
    CHECK(rounded.timescale == kPreciseTimescale);
    CHECK(std::fabs(CMTimeGetSeconds(rounded) - 1.0 / 999999937.0 / 7.0) < 1e-9);
    CHECK(identical(scaleTime(kCMTimeInvalid, Ratio{2, 1}), kCMTimeInvalid));
}

TEST_CASE("TimeUtil: TimeRange intersection and containment are half-open") {
    const TimeRange a{CMTimeMake(0, 30), CMTimeMake(30, 30)};
    const TimeRange b{CMTimeMake(30, 30), CMTimeMake(60, 30)};
    const TimeRange c{CMTimeMake(15, 30), CMTimeMake(45, 30)};
    CHECK_FALSE(a.intersects(b)); // touching ranges do not overlap
    CHECK_FALSE(intersection(a, b).has_value());
    CHECK(a.intersects(c));
    const auto ac = intersection(a, c);
    REQUIRE(ac.has_value());
    CHECK(*ac == TimeRange{CMTimeMake(15, 30), CMTimeMake(30, 30)});
    CHECK(a.contains(CMTimeMake(0, 30)));
    CHECK_FALSE(a.contains(CMTimeMake(30, 30)));
    CHECK(a.contains(TimeRange{CMTimeMake(1, 30), CMTimeMake(30, 30)}));
    CHECK(a.duration() == CMTimeMake(1, 1));
    CHECK(TimeRange{}.isEmpty());
    CHECK_FALSE(TimeRange{}.intersects(a));
    CHECK(TimeRange::fromDuration(CMTimeMake(1, 1), CMTimeMake(2, 1)).end == CMTimeMake(3, 1));
    const TimeRange roundTrip = TimeRange::fromCMTimeRange(c.toCMTimeRange());
    CHECK(roundTrip == c);
    CHECK(fractionThrough(a, CMTimeMake(15, 30)) == doctest::Approx(0.5));
    CHECK(fractionThrough(a, CMTimeMake(-15, 30)) == 0.0);
    CHECK(fractionThrough(a, CMTimeMake(99, 30)) == 1.0);
}

TEST_CASE("TimeUtil: describe") {
    CHECK(describe(kCMTimeInvalid) == "invalid");
    CHECK(describe(kCMTimePositiveInfinity) == "+infinity");
    CHECK(describe(CMTimeMake(1, 2)) == "1/2 (0.500000 s)");
}

TEST_CASE("TimeUtil: exact addition keeps a shared timescale and never rounds") {
    // Same timescale: stays on it.
    CHECK(identical(*checkedAdd(CMTimeMake(1001, 30000), CMTimeMake(2002, 30000)), CMTimeMake(3003, 30000)));
    // Different timescales: their least common multiple.
    CHECK(identical(*checkedAdd(CMTimeMake(1, 30), CMTimeMake(1, 600)), CMTimeMake(21, 600)));
    CHECK(identical(*checkedSubtract(CMTimeMake(1, 30), CMTimeMake(1, 600)), CMTimeMake(19, 600)));
    // 44.1 kHz + 29.97 fps * 999/1000: the common timescale 4.41e9 does not fit an int32, but the
    // reduced sum may. 44100/44100 + 30000000/30000000 reduces to 2/1.
    CHECK(identical(*checkedAdd(CMTimeMake(44100, 44100), CMTimeMake(30000000, 30000000)), CMTimeMake(2, 1)));
    // ... and when even the reduced sum does not fit, the result is refused, not rounded.
    const CMTime in44 = CMTimeMake(44101, 44100);
    const CMTime scaled = *checkedScale(CMTimeMake(1001, 30000), Ratio{999, 1000}); // 999999/30000000
    CHECK_FALSE(checkedAdd(in44, scaled).has_value());
    CHECK_FALSE(checkedSubtract(in44, scaled).has_value());
    // The operators fall back to CoreMedia's rounded (and flagged) result only then.
    const CMTime rounded = in44 + scaled;
    CHECK(isRounded(rounded));
    CHECK(std::fabs(CMTimeGetSeconds(rounded) - (44101.0 / 44100.0 + 999999.0 / 30000000.0)) < 1e-9);
    CHECK_FALSE(isRounded(CMTimeMake(1, 30) + CMTimeMake(1, 44100)));

    // Flags and epochs.
    CMTime flagged = CMTimeMake(1, 30);
    flagged.flags |= kCMTimeFlags_HasBeenRounded;
    CHECK(isRounded(*checkedAdd(flagged, CMTimeMake(1, 30))));
    CMTime otherEpoch = CMTimeMake(1, 30);
    otherEpoch.epoch = 2;
    CHECK_FALSE(checkedAdd(otherEpoch, CMTimeMake(1, 30)).has_value());
    CHECK(checkedAdd(otherEpoch, otherEpoch)->epoch == 2);
    CHECK_FALSE(checkedAdd(kCMTimeInvalid, CMTimeMake(1, 30)).has_value());
    CHECK_FALSE(checkedAdd(kCMTimePositiveInfinity, CMTimeMake(1, 30)).has_value());
    CHECK(CMTIME_IS_POSITIVE_INFINITY(kCMTimePositiveInfinity + CMTimeMake(1, 30)));

    // Range edges: INT64_MAX values and the largest timescale.
    const std::int64_t big = std::numeric_limits<std::int64_t>::max();
    CHECK_FALSE(checkedAdd(CMTimeMake(big, 1), CMTimeMake(1, 1)).has_value());
    CHECK(identical(*checkedAdd(CMTimeMake(big - 1, 1), CMTimeMake(1, 1)), CMTimeMake(big, 1)));
    CHECK(identical(*checkedAdd(CMTimeMake(big, 2), CMTimeMake(-big, 2)), CMTimeMake(0, 2)));
    const CMTime tick = CMTimeMake(1, kCMTimeMaxTimescale);
    CHECK(identical(*checkedAdd(tick, tick), CMTimeMake(2, kCMTimeMaxTimescale)));
    CHECK_FALSE(checkedAdd(tick, CMTimeMake(1, kCMTimeMaxTimescale - 1)).has_value());
}

TEST_CASE("TimeUtil: unary minus keeps flags and epoch and is defined at INT64_MIN") {
    CMTime t = CMTimeMake(5, 30);
    t.flags |= kCMTimeFlags_HasBeenRounded;
    t.epoch = 3;
    const CMTime negated = -t;
    CHECK(negated.value == -5);
    CHECK(negated.timescale == 30);
    CHECK(negated.flags == t.flags);
    CHECK(negated.epoch == 3);

    const std::int64_t min = std::numeric_limits<std::int64_t>::min();
    // -(INT64_MIN / 2) = 2^62 / 1 exactly.
    const auto even = checkedNegate(CMTimeMake(min, 2));
    REQUIRE(even.has_value());
    CHECK(identical(*even, CMTimeMake(std::int64_t(1) << 62, 1)));
    // Over an odd timescale there is no exact negation.
    CHECK_FALSE(checkedNegate(CMTimeMake(min, 3)).has_value());
    CHECK(-CMTimeMake(min, 3) > kCMTimeZero); // CoreMedia's saturated result, still positive
}

TEST_CASE("TimeUtil: scaling and frame math at the extremes") {
    const std::int64_t max = std::numeric_limits<std::int64_t>::max();
    // Exact scaling refuses what does not fit; the rendering variant rounds or saturates.
    CHECK_FALSE(checkedScale(CMTimeMake(max, 1), Ratio{2, 1}).has_value());
    CHECK(CMTIME_IS_POSITIVE_INFINITY(scaleTime(CMTimeMake(max, 1), Ratio{2, 1})));
    CHECK(CMTIME_IS_NEGATIVE_INFINITY(scaleTime(CMTimeMake(-max, 1), Ratio{3, 1})));
    CHECK(identical(*checkedScale(CMTimeMake(max, 1), Ratio{1, 1}), CMTimeMake(max, 1)));
    CHECK(identical(*checkedScale(CMTimeMake(max - 1, 2), Ratio{1, 1}), CMTimeMake(max - 1, 2)));
    const CMTime tiny = scaleTime(CMTimeMake(1, kCMTimeMaxTimescale), Ratio{1, 1000});
    CHECK(isRounded(tiny));
    CHECK(tiny.value == 0); // below the precise timescale's resolution
    CHECK_FALSE(checkedScale(kCMTimeInvalid, Ratio{1, 2}).has_value());
    CHECK_FALSE(checkedScale(CMTimeMake(1, 2), Ratio{1, 0}).has_value());

    // Frame indices that do not fit int64 are refused (checked) or saturate (documented).
    CHECK_FALSE(checkedFrameIndexAt(CMTimeMake(max, 1), CMTimeMake(1, kCMTimeMaxTimescale), SnapMode::Floor)
                    .has_value());
    CHECK(frameIndexAt(CMTimeMake(max, 1), CMTimeMake(1, kCMTimeMaxTimescale), SnapMode::Floor) == max);
    CHECK(frameIndexAt(CMTimeMake(-max, 1), CMTimeMake(1, kCMTimeMaxTimescale), SnapMode::Ceil) ==
          std::numeric_limits<std::int64_t>::min());
    CHECK(*checkedFrameIndexAt(CMTimeMake(max, 1), CMTimeMake(1, 1), SnapMode::Round) == max);
    CHECK_FALSE(checkedTimeForFrame(max, CMTimeMake(2, 30)).has_value());
    CHECK(CMTIME_IS_POSITIVE_INFINITY(timeForFrame(max, CMTimeMake(2, 30))));
    CHECK(CMTIME_IS_NEGATIVE_INFINITY(timeForFrame(-max, CMTimeMake(2, 30))));
    CHECK(CMTIME_IS_POSITIVE_INFINITY(snapToFrame(CMTimeMake(max, 1), CMTimeMake(1, 30), SnapMode::Floor)));
    CHECK(CMTIME_IS_INVALID(timeForFrame(3, kCMTimeZero)));

    // approximateRatio never overflows or returns a zero denominator.
    CHECK(approximateRatio(1e300, 1000) == Ratio{0, 1});
    CHECK(approximateRatio(9.0e18, 1000) == Ratio{0, 1});
    CHECK(approximateRatio(123456789.5, 1000) == Ratio{246913579, 2});
    CHECK(approximateRatio(1e-300, 1000) == Ratio{1, 1000});
}

TEST_CASE("TimeUtil: ExactTime arithmetic, comparison and snapping") {
    const ExactTime third = *ExactTime::fraction(1, 3);
    const ExactTime sixth = *ExactTime::fraction(-2, -12);
    CHECK(sixth == *ExactTime::fraction(1, 6));
    CHECK(*third.plus(sixth) == *ExactTime::fraction(1, 2));
    CHECK(*third.minus(sixth) == sixth);
    CHECK(*third.times(Ratio{3, 5}) == *ExactTime::fraction(1, 5));
    CHECK(*third.dividedBy(Ratio{2, 3}) == *ExactTime::fraction(1, 2));
    CHECK_FALSE(third.dividedBy(Ratio{0, 1}).has_value());
    CHECK(third.negated().compare(ExactTime()) < 0);
    CHECK(third.compare(sixth) > 0);
    CHECK(third.compare(CMTimeMake(1, 3)) == 0);
    CHECK(third.compare(CMTimeMake(333333, 1000000)) > 0);
    CHECK_FALSE(ExactTime::fraction(1, 0).has_value());
    CHECK(identical(*ExactTime::fraction(10, 20)->toTime(), CMTimeMake(1, 2)));
    CHECK_FALSE(ExactTime::fraction(1, static_cast<Int128>(kCMTimeMaxTimescale) + 2)->toTime().has_value());

    // Comparison is exact where cross products would overflow 128 bits.
    const Int128 huge = static_cast<Int128>(1) << 100;
    const ExactTime a = *ExactTime::fraction(huge + 1, huge);
    const ExactTime b = *ExactTime::fraction(huge + 2, huge + 1);
    CHECK(a.compare(b) > 0); // 1 + 1/huge > 1 + 1/(huge + 1)
    CHECK(b.compare(a) < 0);
    CHECK(a.compare(a) == 0);
    CHECK(a.negated().compare(b.negated()) < 0);
    // Products that overflow are refused, not wrapped.
    CHECK_FALSE(a.times(Ratio{std::numeric_limits<std::int64_t>::max(), 1}).has_value());

    // Snapping an exact value to a frame grid.
    const ExactTime t = *ExactTime::from(CMTimeMake(1, 1)); // 23.976 frames at 1001/24000
    CHECK(*t.frameIndex(k23976, SnapMode::Floor) == 23);
    CHECK(*t.frameIndex(k23976, SnapMode::Ceil) == 24);
    CHECK(*t.frameIndex(k23976, SnapMode::Round) == 24);
    CHECK(*t.negated().frameIndex(k23976, SnapMode::Floor) == -24);
    CHECK(*ExactTime::fraction(1, 60)->frameIndex(k30, SnapMode::Round) == 1); // halves go up
    CHECK_FALSE(t.frameIndex(kCMTimeZero, SnapMode::Floor).has_value());

    // Rounded CMTime form.
    const CMTime r = ExactTime::fraction(1, static_cast<Int128>(3) * kCMTimeMaxTimescale)->toTimeRounded();
    CHECK(isRounded(r));
    CHECK(r.timescale == kPreciseTimescale);
}

TEST_CASE("TimeUtil: fractionThrough is exact at frame boundaries") {
    const TimeRange range{CMTimeMake(1001 * 50, 30000), CMTimeMake(1001 * 70, 30000)};
    for (int k = 0; k <= 20; ++k) {
        CHECK(fractionThrough(range, CMTimeMake(1001 * (50 + k), 30000)) == static_cast<double>(k) / 20.0);
    }
    CHECK(fractionThrough(range, CMTimeMake(0, 1)) == 0.0);
    CHECK(fractionThrough(range, CMTimeMake(1000, 1)) == 1.0);
}

TEST_CASE("TimeUtil: Ratio helpers") {
    CHECK(*Ratio::reduced(6, -4) == Ratio{-3, 2});
    CHECK_FALSE(Ratio::reduced(1, 0).has_value());
    CHECK(Ratio{2, 4}.isReduced() == false);
    CHECK(Ratio{1, 2} < Ratio{2, 3});
    CHECK_FALSE(Ratio{2, 4} < Ratio{1, 2});
    CHECK(Ratio{3, 3}.isUnity());
}
