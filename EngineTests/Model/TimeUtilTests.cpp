#include "ModelFixtures.h"

#include <cmath>

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
