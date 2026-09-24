// The keyframe machinery inside effect spans (Keyframes.h): evaluation at exact times for every
// interpolation, the limit from the left, timing curves and their exact division, track splits and
// rescaling, validation, and which sequence frame shows a source time (Clip.h).

#include "ModelFixtures.h"

#include <cmath>
#include <vector>

using namespace vetest;

namespace {

ExactTime exact(CMTime t) {
    return *ExactTime::from(t);
}

// Reference for a timing curve: Newton's method on x(t) from the fraction (a different solver
// from the engine's bisection), then y(t).
double referenceCurve(const TimingCurve &c, double u) {
    auto bez = [](double p1, double p2, double t) {
        const double v = 1 - t;
        return 3 * v * v * t * p1 + 3 * v * t * t * p2 + t * t * t;
    };
    auto dbez = [](double p1, double p2, double t) {
        const double v = 1 - t;
        return 3 * v * v * p1 + 6 * v * t * (p2 - p1) + 3 * t * t * (1 - p2);
    };
    double t = u;
    for (int i = 0; i < 100; ++i) {
        const double d = dbez(c.x1, c.x2, t);
        if (std::fabs(d) < 1e-12) {
            break;
        }
        t = std::clamp(t - (bez(c.x1, c.x2, t) - u) / d, 0.0, 1.0);
    }
    return bez(c.y1, c.y2, t);
}

} // namespace

TEST_CASE("Keyframes: an empty track has its neutral value; with keyframes the ends hold") {
    const KeyframeTrack none;
    CHECK(evaluateTrack(none, 7.5, exact(f30(3))) == 7.5);

    const KeyframeTrack track{key(f30(10), 100), key(f30(40), 400)};
    // Premiere Pro's behaviour: before the first keyframe the first value, after the last the last
    // one; the static value (-1) is not used while animated.
    CHECK(evaluateTrack(track, -1, exact(f30(0))) == 100);
    CHECK(evaluateTrack(track, -1, exact(f30(10))) == 100);
    CHECK(evaluateTrack(track, -1, exact(f30(40))) == 400);
    CHECK(evaluateTrack(track, -1, exact(f30(90))) == 400);
}

TEST_CASE("Keyframes: linear interpolation is exact at every frame") {
    const KeyframeTrack track{key(f30(0), 0), key(f30(30), 30)};
    for (int frame = 0; frame <= 30; ++frame) {
        CHECK(evaluateTrack(track, 0, exact(f30(frame))) == doctest::Approx(frame).epsilon(1e-15));
    }
    // The segment fraction is computed exactly: 1/3 of a 29.97 fps segment of 3003 ticks.
    const KeyframeTrack ntsc{key(CMTimeMake(0, 30000), 0), key(CMTimeMake(3003, 30000), 3)};
    CHECK(evaluateTrack(ntsc, 0, exact(CMTimeMake(1001, 30000))) == doctest::Approx(1.0).epsilon(1e-15));
    // A source time between frames (a 2x clip on a 60 fps grid) interpolates too.
    CHECK(evaluateTrack(track, 0, exact(CMTimeMake(1, 60))) == doctest::Approx(0.5).epsilon(1e-15));
}

TEST_CASE("Keyframes: hold keeps the value until the next keyframe, then jumps") {
    const KeyframeTrack track{key(f30(0), 5, KeyframeInterpolation::Hold), key(f30(10), 50, KeyframeInterpolation::Hold),
                              key(f30(20), 80)};
    CHECK(evaluateTrack(track, 0, exact(f30(0))) == 5);
    CHECK(evaluateTrack(track, 0, exact(f30(9))) == 5);
    CHECK(evaluateTrack(track, 0, exact(CMTimeMake(9999, 30000))) == 5); // just before frame 10
    CHECK(evaluateTrack(track, 0, exact(f30(10))) == 50);
    CHECK(evaluateTrack(track, 0, exact(f30(19))) == 50);
    CHECK(evaluateTrack(track, 0, exact(f30(20))) == 80);
    // The limit from the left, where a ramp over [9, 10) ends: the held value, not the jump.
    CHECK(evaluateTrackFromLeft(track, 0, exact(f30(10))) == 5);
    CHECK(evaluateTrackFromLeft(track, 0, exact(f30(20))) == 50);
    CHECK(evaluateTrackFromLeft(track, 0, exact(f30(15))) == 50); // between keyframes: the value
    CHECK(evaluateTrackFromLeft(track, 0, exact(f30(0))) == 5);   // on the first: nothing before it
    CHECK(evaluateTrackFromLeft(track, 0, exact(f30(30))) == 80);
    const KeyframeTrack ramp{key(f30(0), 0), key(f30(10), 10)};
    CHECK(evaluateTrackFromLeft(ramp, 0, exact(f30(10))) == 10); // a ramp arrives at its end value
}

TEST_CASE("Keyframes: the eases follow Premiere and FCP naming with Core Animation's curves") {
    const TimingCurve easeOut = timingCurveFor(KeyframeInterpolation::EaseOut);
    const TimingCurve easeIn = timingCurveFor(KeyframeInterpolation::EaseIn);
    const TimingCurve both = timingCurveFor(KeyframeInterpolation::EaseInOut);
    CHECK(easeOut == TimingCurve{0.42, 0, 1, 1});
    CHECK(easeIn == TimingCurve{0, 0, 0.58, 1});
    CHECK(both == TimingCurve{0.42, 0, 0.58, 1});
    for (int i = 1; i < 30; ++i) {
        const double u = i / 30.0;
        // Ease Out leaves the keyframe slowly (behind linear), Ease In arrives slowly (ahead of it).
        CHECK(easeOut.valueAt(u) < u);
        CHECK(easeIn.valueAt(u) > u);
        for (const TimingCurve &c : {easeOut, easeIn, both}) {
            CHECK(c.valueAt(u) == doctest::Approx(referenceCurve(c, u)).epsilon(1e-9));
        }
    }
    CHECK(both.valueAt(0.5) == doctest::Approx(0.5).epsilon(1e-12)); // symmetric
    // Motion starts and ends at rest: the first and last frames of a 30-frame ease-in-out move
    // barely change.
    const KeyframeTrack track{key(f30(0), 0, KeyframeInterpolation::EaseInOut), key(f30(30), 300)};
    const double first = evaluateTrack(track, 0, exact(f30(1)));
    const double middle = evaluateTrack(track, 0, exact(f30(16))) - evaluateTrack(track, 0, exact(f30(15)));
    const double last = 300 - evaluateTrack(track, 0, exact(f30(29)));
    CHECK(first < 1.5);
    CHECK(last < 1.5);
    CHECK(middle > 15);
    CHECK(evaluateTrack(track, 0, exact(f30(15))) == doctest::Approx(150).epsilon(1e-9));
}

TEST_CASE("Keyframes: a timing curve divided at any point reproduces it exactly") {
    for (const KeyframeInterpolation interpolation :
         {KeyframeInterpolation::EaseOut, KeyframeInterpolation::EaseIn, KeyframeInterpolation::EaseInOut}) {
        const TimingCurve curve = timingCurveFor(interpolation);
        for (const double cut : {0.1, 0.37, 0.5, 0.9}) {
            const CurveSplit parts = splitCurve(curve, cut);
            REQUIRE(parts.before.has_value());
            REQUIRE(parts.after.has_value());
            CHECK(parts.before->isValid());
            CHECK(parts.after->isValid());
            CHECK(parts.valueAtSplit == doctest::Approx(curve.valueAt(cut)).epsilon(1e-12));
            for (int i = 0; i <= 40; ++i) {
                const double u = i / 40.0;
                const double expected = curve.valueAt(u);
                const double actual = u < cut
                                          ? parts.before->valueAt(u / cut) * parts.valueAtSplit
                                          : parts.valueAtSplit +
                                                parts.after->valueAt((u - cut) / (1 - cut)) * (1 - parts.valueAtSplit);
                CHECK(actual == doctest::Approx(expected).epsilon(1e-9));
            }
        }
    }
}

TEST_CASE("Keyframes: a curve part divided again, and cuts near either end, match the reference") {
    // Every part is compared with the independent reference of the undivided curve.
    for (const TimingCurve curve : {timingCurveFor(KeyframeInterpolation::EaseInOut),
                                    timingCurveFor(KeyframeInterpolation::EaseOut), TimingCurve{0.3, 0.1, 0.6, 0.95}}) {
        for (const double first : {1e-3, 0.37, 0.999}) {
            const CurveSplit outer = splitCurve(curve, first);
            REQUIRE(outer.before.has_value());
            REQUIRE(outer.after.has_value());
            CHECK(outer.before->isValid());
            CHECK(outer.after->isValid());
            // The part after the cut, cut again at 0.6 of its own time.
            const CurveSplit inner = splitCurve(*outer.after, 0.6);
            REQUIRE(inner.before.has_value());
            REQUIRE(inner.after.has_value());
            CHECK(inner.before->isValid());
            CHECK(inner.after->isValid());
            const double innerCut = first + (1 - first) * 0.6;
            const double atInner = outer.valueAtSplit + (1 - outer.valueAtSplit) * inner.valueAtSplit;
            for (int i = 0; i <= 50; ++i) {
                const double u = i / 50.0;
                double actual = 0;
                if (u < first) {
                    actual = outer.before->valueAt(u / first) * outer.valueAtSplit;
                } else if (u < innerCut) {
                    actual = outer.valueAtSplit +
                             inner.before->valueAt((u - first) / (innerCut - first)) * (atInner - outer.valueAtSplit);
                } else {
                    actual = atInner + inner.after->valueAt((u - innerCut) / (1 - innerCut)) * (1 - atInner);
                }
                CAPTURE(first);
                CAPTURE(u);
                CHECK(actual == doctest::Approx(referenceCurve(curve, u)).epsilon(1e-9));
            }
        }
    }
}

TEST_CASE("Keyframes: splitting a track keeps every value on both sides") {
    const std::vector<KeyframeInterpolation> kinds{KeyframeInterpolation::Hold, KeyframeInterpolation::Linear,
                                                   KeyframeInterpolation::EaseOut, KeyframeInterpolation::EaseIn,
                                                   KeyframeInterpolation::EaseInOut};
    for (const KeyframeInterpolation kind : kinds) {
        const KeyframeTrack track{key(f30(10), 100, kind), key(f30(40), 400, kind), key(f30(70), -50)};
        for (const std::int64_t cut : {5, 10, 23, 40, 41, 69, 70, 90}) {
            CAPTURE(cut);
            CAPTURE(static_cast<int>(kind));
            const TrackSplit split = splitTrack(track, 9, f30(cut));
            CHECK_FALSE(keyframeTimesProblem(split.left, "X keyframe").has_value());
            CHECK_FALSE(keyframeTimesProblem(split.right, "X keyframe").has_value());
            for (std::int64_t frame = 0; frame < 100; ++frame) {
                const double expected = evaluateTrack(track, 9, exact(f30(frame)));
                const double actual = frame < cut ? evaluateTrack(split.left, split.leftStatic, exact(f30(frame)))
                                                  : evaluateTrack(split.right, split.rightStatic, exact(f30(frame)));
                CHECK(actual == doctest::Approx(expected).epsilon(1e-9));
            }
            // Keyframes stay on their own side; the cut gets one when it falls between keyframes.
            for (const Keyframe &k : split.left) {
                CHECK(k.time <= f30(cut));
            }
            for (const Keyframe &k : split.right) {
                CHECK(k.time >= f30(cut));
            }
        }
    }
    SUBCASE("a piece with no keyframe on its side is static") {
        const KeyframeTrack track{key(f30(10), 100), key(f30(20), 200)};
        const TrackSplit early = splitTrack(track, 9, f30(5));
        CHECK(early.left.empty());
        CHECK(early.leftStatic == 100);
        CHECK(early.right == track);
        const TrackSplit late = splitTrack(track, 9, f30(25));
        CHECK(late.right.empty());
        CHECK(late.rightStatic == 200);
        CHECK(late.left == track);
    }
    SUBCASE("between keyframes both pieces get the cut, eased segments a custom curve") {
        const KeyframeTrack track{key(f30(0), 0, KeyframeInterpolation::EaseInOut), key(f30(30), 300)};
        const TrackSplit split = splitTrack(track, 0, f30(12));
        REQUIRE(split.left.size() == 2);
        REQUIRE(split.right.size() == 2);
        CHECK(split.left.back().time == f30(12));
        CHECK(split.right.front().time == f30(12));
        CHECK(split.left.back().value == split.right.front().value);
        CHECK(split.left.front().interpolation == KeyframeInterpolation::Bezier);
        CHECK(split.right.front().interpolation == KeyframeInterpolation::Bezier);
    }
}

TEST_CASE("Keyframes: validation of times and curves") {
    CHECK_FALSE(keyframeTimesProblem({key(f30(0), 1), key(f30(1), 2)}, "k").has_value());
    CHECK(keyframeTimesProblem({key(f30(1), 1), key(f30(1), 2)}, "k").has_value());
    CHECK(keyframeTimesProblem({key(f30(2), 1), key(f30(1), 2)}, "k").has_value());
    CHECK(keyframeTimesProblem({key(f30(0), NAN)}, "k").has_value());
    CMTime rounded = f30(1);
    rounded.flags |= kCMTimeFlags_HasBeenRounded;
    CHECK(keyframeTimesProblem({key(rounded, 1)}, "k").has_value());
    Keyframe bent = key(f30(0), 1, KeyframeInterpolation::Bezier);
    bent.curve = TimingCurve{1.5, 0, 0.5, 1};
    CHECK(keyframeTimesProblem({bent}, "k").has_value());
    // Control points that run backwards in time (x1 > x2): splitCurve could not keep their parts.
    CHECK_FALSE(TimingCurve({0.9, 0, 0.1, 1}).isValid());
    bent.curve = TimingCurve{0.9, 0, 0.1, 1};
    CHECK(keyframeTimesProblem({bent}, "k").has_value());
    CHECK(TimingCurve({0.5, 0, 0.5, 1}).isValid());
    CHECK(TimingCurve({0.5 + 1e-16, 0, 0.5, 1}).isValid()); // rounding of a split part
    // Only a custom keyframe keeps a curve.
    Keyframe straight = key(f30(0), 1);
    straight.curve = TimingCurve{0.42, 0, 0.58, 1};
    CHECK(keyframeTimesProblem({straight}, "k").has_value());
}

TEST_CASE("Keyframes: rescaling a track keeps each keyframe's place in the span") {
    const KeyframeTrack track{key(f30(0), 1, KeyframeInterpolation::EaseInOut), key(f30(10), 2), key(f30(30), 3)};
    // Stretched from 30 to 45 frames: 0, 15, 45.
    const auto longer = rescaleTrack(track, f30(45), f30(30));
    REQUIRE(longer.has_value());
    CHECK((*longer)[1].time == f30(15));
    CHECK((*longer)[2].time == f30(45));
    CHECK((*longer)[0].interpolation == KeyframeInterpolation::EaseInOut);
    CHECK((*longer)[1].value == 2);
    // A factor whose products have no CMTime form lands on the nearest precise tick.
    const auto odd = rescaleTrack(track, CMTimeMake(1001, 30000), CMTimeMake(1, 44100));
    REQUIRE(odd.has_value());
    CHECK(isExactModelTime((*odd)[1].time));
    CHECK(std::fabs(toSeconds((*odd)[1].time) - (10.0 / 30.0) * (1001.0 / 30000.0) * 44100.0) < 1e-9);
    CHECK_FALSE(rescaleTrack(track, kCMTimeZero, f30(30)).has_value());
    CHECK_FALSE(rescaleTrack(track, f30(30), kCMTimeInvalid).has_value());
}

TEST_CASE("Keyframes: which sequence frame shows a source time; span edges on frames") {
    Fixture fx;
    // A clip at 2x from source frame 30 (1 s), on timeline frames [60, 90).
    const ClipId id = fx.addClip(fx.v1, fx.av30, 60, 30, 30, 2.0);
    const Clip &clip = fx.clip(id);
    const CMTime fd = f30(1);
    // Source frame 30 plays at timeline frame 60; source frame 31 (half a sequence frame later at
    // 2x) is still shown by frame 60; source frame 90 is the out point, owned by the last frame (89).
    CHECK(frameShowingSourceTime(clip, f30(30), fd) == f30(60));
    CHECK(frameShowingSourceTime(clip, f30(31), fd) == f30(60));
    CHECK(frameShowingSourceTime(clip, f30(32), fd) == f30(61));
    CHECK(frameShowingSourceTime(clip, f30(90), fd) == f30(89));
    CHECK_FALSE(frameShowingSourceTime(clip, f30(200), fd).has_value()); // trimmed off
    CHECK_FALSE(frameShowingSourceTime(clip, f30(29), fd).has_value());
    CHECK(spanTimeAt(clip, f30(70)) == f30(50));
    CHECK(spanTimeAt(clip, f30(90)) == f30(90)); // the clip's end: its out point

    // 999/1000 speed at 29.97 fps: the frame's exact source time has no CMTime form, so a span edge
    // there is the first time on kPreciseTimescale at or after it, unflagged, still shown by that
    // frame (the nearest one could fall on the frame before), and the frame is evaluated there.
    Fixture ntsc;
    ntsc.sequence().frameDuration = CMTimeMake(1001, 30000);
    Clip slow;
    slow.id = ntsc.project.ids.make<ClipId>();
    slow.assetId = ntsc.av24;
    slow.trackId = ntsc.v1;
    slow.timelineStart = CMTimeMake(0, 30000);
    slow.timelineDuration = CMTimeMake(1001 * 101, 30000); // its out point has no CMTime form either
    slow.sourceIn = CMTimeMake(44101, 44100);
    slow.speed = Ratio{999, 1000};
    const CMTime frame = CMTimeMake(1001 * 7, 30000);
    REQUIRE_FALSE(slow.exactSourceTimeAt(frame)->toTime().has_value());
    const auto time = spanTimeAt(slow, frame);
    REQUIRE(time.has_value());
    CHECK(isExactModelTime(*time));
    CHECK(time->timescale == kPreciseTimescale);
    CHECK(frameShowingSourceTime(slow, *time, CMTimeMake(1001, 30000)) == frame);
    CHECK(motionTimeAt(slow, frame)->compare(*time) == 0);
    // The clip's out point has no CMTime form either: its bound is the tick before it.
    REQUIRE_FALSE(slow.exactSourceOut()->toTime().has_value());
    const auto bounds = slow.spanBounds();
    REQUIRE(bounds.has_value());
    CHECK(slow.exactSourceOut()->compare(bounds->second) > 0);
    CHECK(spanTimeAt(slow, slow.timelineEnd()) == bounds->second);
}

TEST_CASE("Spans: a still's spans keep their timeline positions when its start moves; a movie's stay put") {
    Fixture fx;
    const ClipId id = fx.addClip(fx.v1, fx.still, 30, 90);
    Clip clip = fx.clip(id);
    SpanTracks tracks;
    tracks.scale = {key(f30(0), 1, KeyframeInterpolation::EaseInOut), key(f30(60), 2)};
    EffectSpan span;
    span.id = SpanId{500};
    span.kind = SpanKind::Motion;
    span.start = f30(20);
    span.end = f30(80);
    span.tracks = tracks;
    clip.spans = {span};
    const VideoParams before = motionValuesAt(clip, f30(70));
    REQUIRE(clip.setTimelineStartKeepingEnd(f30(40)) == RetimeResult::Ok);
    // Moved back by the 10 frames the start moved: still at timeline frames [50, 110).
    CHECK(clip.spans[0].start == f30(10));
    CHECK(clip.spans[0].end == f30(70));
    CHECK(clip.spans[0].tracks == tracks);
    CHECK(motionValuesAt(clip, f30(70)) == before);
    // A trim past the span's start clips it, the value at the new edge evaluated exactly: every
    // remaining frame shows what it showed.
    std::vector<double> remaining;
    for (std::int64_t f = 60; f < 120; ++f) {
        remaining.push_back(motionValuesAt(clip, f30(f)).scale);
    }
    REQUIRE(clip.setTimelineStartKeepingEnd(f30(60)) == RetimeResult::Ok);
    CHECK(clip.spans[0].start == kCMTimeZero);
    CHECK(clip.spans[0].end == f30(50));
    for (std::int64_t f = 60; f < 120; ++f) {
        CAPTURE(f);
        CHECK(motionValuesAt(clip, f30(f)).scale == doctest::Approx(remaining[std::size_t(f - 60)]).epsilon(1e-12));
    }

    // A video clip's spans are source times: the trim does not move them.
    const ClipId movie = fx.addClip(fx.v2, fx.av30, 30, 90, 10);
    Clip video = fx.clip(movie);
    EffectSpan moving = span;
    moving.start = f30(40);
    moving.end = f30(90);
    video.spans = {moving};
    REQUIRE(video.setTimelineStartKeepingEnd(f30(50)) == RetimeResult::Ok);
    CHECK(video.spans[0] == moving);
}
