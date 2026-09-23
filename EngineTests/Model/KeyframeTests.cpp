// Keyframed Motion model (Keyframes.h, VideoParams, the frame/keyframe mapping in Clip.h):
// evaluation at exact source times for every interpolation, timing curves and their exact
// division, track splits, validation, and which sequence frame shows a keyframe.

#include "ModelFixtures.h"

#include <cmath>
#include <vector>

using namespace vetest;

namespace {

ExactTime exact(CMTime t) {
    return *ExactTime::from(t);
}

Keyframe key(CMTime time, double value, KeyframeInterpolation interpolation = KeyframeInterpolation::Linear) {
    Keyframe k;
    k.time = time;
    k.value = value;
    k.interpolation = interpolation;
    return k;
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

TEST_CASE("Keyframes: a parameter without keyframes has its static value; with keyframes the ends hold") {
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
            CHECK_FALSE(keyframeTrackProblem(split.left, MotionParameter::X).has_value());
            CHECK_FALSE(keyframeTrackProblem(split.right, MotionParameter::X).has_value());
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

TEST_CASE("Keyframes: validation") {
    CHECK_FALSE(keyframeTrackProblem({key(f30(0), 1), key(f30(1), 2)}, MotionParameter::Scale).has_value());
    CHECK(keyframeTrackProblem({key(f30(1), 1), key(f30(1), 2)}, MotionParameter::X).has_value());
    CHECK(keyframeTrackProblem({key(f30(2), 1), key(f30(1), 2)}, MotionParameter::X).has_value());
    CHECK(keyframeTrackProblem({key(f30(0), -0.5)}, MotionParameter::Scale).has_value());
    CHECK(keyframeTrackProblem({key(f30(0), 1.5)}, MotionParameter::Opacity).has_value());
    CHECK(keyframeTrackProblem({key(f30(0), NAN)}, MotionParameter::Rotation).has_value());
    CMTime rounded = f30(1);
    rounded.flags |= kCMTimeFlags_HasBeenRounded;
    CHECK(keyframeTrackProblem({key(rounded, 1)}, MotionParameter::X).has_value());
    Keyframe bent = key(f30(0), 1, KeyframeInterpolation::Bezier);
    bent.curve = TimingCurve{1.5, 0, 0.5, 1};
    CHECK(keyframeTrackProblem({bent}, MotionParameter::X).has_value());

    // A clip's keyframes are part of the model's invariants; audio clips have none.
    Fixture fx;
    const auto [video, audio] = fx.addLinkedPair(0, 60);
    fx.sequence().findClip(video)->video.keyframes.opacity = {key(f30(0), 0.2), key(f30(10), 1.2)};
    CHECK(problemOf(fx.project).find("Opacity keyframe") != std::string::npos);
    fx.sequence().findClip(video)->video.keyframes.opacity = {key(f30(0), 0.2)};
    fx.requireValid();
    fx.sequence().findClip(audio)->video.keyframes.x = {key(f30(0), 1)};
    CHECK(problemOf(fx.project).find("only clips on video tracks") != std::string::npos);
}

TEST_CASE("Keyframes: VideoParams evaluates animated parameters and keeps the others static") {
    VideoParams params{10, 20, 0.5, 45, 0.75};
    params.keyframes.scale = {key(f30(0), 1), key(f30(30), 2)};
    params.keyframes.opacity = {key(f30(0), 0.5, KeyframeInterpolation::Bezier), key(f30(30), 1)};
    // A custom curve that overshoots: the value is limited to the parameter's range.
    params.keyframes.opacity[0].curve = TimingCurve{0.2, 3.0, 0.8, 3.0};
    const VideoParams values = params.valuesAt(exact(f30(15)));
    CHECK(values.x == 10);
    CHECK(values.y == 20);
    CHECK(values.rotationDegrees == 45);
    CHECK(values.scale == doctest::Approx(1.5));
    CHECK(values.opacity == 1.0);
    CHECK(values.keyframes.empty());
    CHECK(params.staticValues() == VideoParams{10, 20, 0.5, 45, 0.75});
    CHECK(params.isAnimated(MotionParameter::Scale));
    CHECK_FALSE(params.isAnimated(MotionParameter::X));
}

TEST_CASE("Keyframes: which sequence frame shows a keyframe, through speed changes") {
    Fixture fx;
    // A clip at 2x from source frame 30 (1 s), on timeline frames [60, 90).
    const ClipId id = fx.addClip(fx.v1, fx.av30, 60, 30, 30, 2.0);
    Clip &clip = *fx.sequence().findClip(id);
    clip.video.keyframes.x = {key(f30(30), 0), key(f30(31), 1), key(f30(90), 2), key(f30(200), 3)};
    fx.requireValid();
    const CMTime fd = f30(1);
    // Source frame 30 plays at timeline frame 60; source frame 31 (half a sequence frame later at
    // 2x) is still shown by frame 60; source frame 90 is the out point, owned by the last frame (89).
    CHECK(frameShowingSourceTime(clip, f30(30), fd) == f30(60));
    CHECK(frameShowingSourceTime(clip, f30(31), fd) == f30(60));
    CHECK(frameShowingSourceTime(clip, f30(32), fd) == f30(61));
    CHECK(frameShowingSourceTime(clip, f30(90), fd) == f30(89));
    CHECK_FALSE(frameShowingSourceTime(clip, f30(200), fd).has_value()); // trimmed off
    CHECK_FALSE(frameShowingSourceTime(clip, f30(29), fd).has_value());
    CHECK(keyframeIndexForFrame(clip, MotionParameter::X, f30(60), fd) == std::optional<std::size_t>(0));
    CHECK(keyframeIndexForFrame(clip, MotionParameter::X, f30(89), fd) == std::optional<std::size_t>(2));
    CHECK_FALSE(keyframeIndexForFrame(clip, MotionParameter::X, f30(70), fd).has_value());
    CHECK_FALSE(keyframeIndexForFrame(clip, MotionParameter::X, f30(90), fd).has_value()); // after the clip
    CHECK(keyframeTimeForFrame(clip, f30(70)) == f30(50));

    // 999/1000 speed at 29.97 fps: the frame's exact source time has no CMTime form, so the
    // keyframe time is the first time on kPreciseTimescale at or after it, unflagged, and still
    // shown by that frame (the nearest one could fall on the frame before).
    Fixture ntsc;
    ntsc.sequence().frameDuration = CMTimeMake(1001, 30000);
    Clip slow;
    slow.id = ntsc.project.ids.make<ClipId>();
    slow.assetId = ntsc.av24;
    slow.trackId = ntsc.v1;
    slow.timelineStart = CMTimeMake(0, 30000);
    slow.timelineDuration = CMTimeMake(1001 * 100, 30000);
    slow.sourceIn = CMTimeMake(44101, 44100);
    slow.speed = Ratio{999, 1000};
    const CMTime frame = CMTimeMake(1001 * 7, 30000);
    REQUIRE_FALSE(slow.exactSourceTimeAt(frame)->toTime().has_value());
    const auto time = keyframeTimeForFrame(slow, frame);
    REQUIRE(time.has_value());
    CHECK(isExactModelTime(*time));
    CHECK(time->timescale == kPreciseTimescale);
    CHECK(frameShowingSourceTime(slow, *time, CMTimeMake(1001, 30000)) == frame);
}

TEST_CASE("Keyframes: a still's keyframes keep their timeline positions when its start moves") {
    Fixture fx;
    const ClipId id = fx.addClip(fx.v1, fx.still, 30, 90);
    Clip clip = fx.clip(id);
    clip.video.keyframes.scale = {key(f30(0), 1, KeyframeInterpolation::EaseInOut), key(f30(89), 2)};
    const VideoParams before = clip.video.valuesAt(*clip.exactSourceTimeAt(f30(70)));
    REQUIRE(clip.setTimelineStartKeepingEnd(f30(50)));
    CHECK(clip.video.keyframes.scale[0].time == f30(-20)); // now before the clip: hidden
    CHECK(clip.video.keyframes.scale[1].time == f30(69));
    CHECK(clip.video.valuesAt(*clip.exactSourceTimeAt(f30(70))) == before);
    // A video clip's keyframes are source times: the trim does not touch them.
    const ClipId movie = fx.addClip(fx.v2, fx.av30, 30, 90, 10);
    Clip video = fx.clip(movie);
    video.video.keyframes.x = {key(f30(10), 1), key(f30(40), 2)};
    const KeyframeTrack kept = video.video.keyframes.x;
    REQUIRE(video.setTimelineStartKeepingEnd(f30(50)));
    CHECK(video.video.keyframes.x == kept);
}
