// Effect spans in the model (EffectSpan.h, Clip.h): kinds, parameters and their ranges, values at
// exact times, exact splits and cuts, track validation, lane rules, and the composition of lanes
// (position and rotation add, scale and opacity multiply, gain adds in dB) under the hold-after
// rule (nothing before a span's start, its end value held after its end, later spans on a lane on
// top of what earlier ones hold), each checked against the independent references of
// SpanReference.h.

#include "SpanReference.h"

#include <cmath>
#include <vector>

using namespace vetest;

namespace {

ExactTime exact(CMTime t) {
    return *ExactTime::from(t);
}

// A Motion span over source [start, end) with `tracks`.
EffectSpan motionSpan(CMTime start, CMTime end, SpanTracks tracks, int lane = 1, SpanId id = SpanId{7}) {
    EffectSpan span;
    span.id = id;
    span.lane = lane;
    span.kind = SpanKind::Motion;
    span.start = start;
    span.end = end;
    span.tracks = std::move(tracks);
    return span;
}

bool close(double a, double b, double tolerance = 1e-9) {
    return std::fabs(a - b) <= tolerance * std::max(1.0, std::fabs(b));
}

} // namespace

TEST_CASE("EffectSpan: kinds, parameters, neutral values and their ranges") {
    CHECK(parametersOf(SpanKind::Motion) ==
          std::vector<SpanParameter>{SpanParameter::X, SpanParameter::Y, SpanParameter::Scale, SpanParameter::Rotation});
    CHECK(parametersOf(SpanKind::Opacity) == std::vector<SpanParameter>{SpanParameter::Opacity});
    CHECK(parametersOf(SpanKind::Gain) == std::vector<SpanParameter>{SpanParameter::Gain});
    CHECK(parametersOf(SpanKind::Transition).empty());
    CHECK(kindHasParameter(SpanKind::Motion, SpanParameter::Rotation));
    CHECK_FALSE(kindHasParameter(SpanKind::Motion, SpanParameter::Opacity));
    CHECK_FALSE(kindHasParameter(SpanKind::Gain, SpanParameter::X));
    for (const SpanParameter p : {SpanParameter::X, SpanParameter::Y, SpanParameter::Rotation, SpanParameter::Gain}) {
        CHECK(neutralValue(p) == 0.0);
    }
    CHECK(neutralValue(SpanParameter::Scale) == 1.0);
    CHECK(neutralValue(SpanParameter::Opacity) == 1.0);
    CHECK(isValidSpanValue(SpanParameter::X, -5000));
    CHECK_FALSE(isValidSpanValue(SpanParameter::X, INFINITY));
    CHECK_FALSE(isValidSpanValue(SpanParameter::Gain, NAN));
    CHECK(isValidSpanValue(SpanParameter::Scale, 0));
    CHECK_FALSE(isValidSpanValue(SpanParameter::Scale, -0.1));
    CHECK_FALSE(isValidSpanValue(SpanParameter::Opacity, 1.01));
    CHECK(clampSpanValue(SpanParameter::Scale, -3) == 0);
    CHECK(clampSpanValue(SpanParameter::Opacity, 1.5) == 1);
    CHECK(clampSpanValue(SpanParameter::Opacity, -0.5) == 0);
    CHECK(clampSpanValue(SpanParameter::Rotation, 720) == 720);
    CHECK(std::string(nameOf(SpanKind::Gain)) == "gain");
    CHECK(std::string(displayNameOf(SpanParameter::X)) == "Position X");
    CHECK(std::string(nameOf(ClipEdge::Head)) == "head");
}

TEST_CASE("EffectSpan: values at exact times follow the reference for every interpolation") {
    for (const KeyframeInterpolation interpolation :
         {KeyframeInterpolation::Linear, KeyframeInterpolation::EaseIn, KeyframeInterpolation::EaseOut,
          KeyframeInterpolation::EaseInOut, KeyframeInterpolation::Hold}) {
        CAPTURE(nameOf(interpolation));
        // Source [2 s, 4 s): x from -100 to 300.
        SpanTracks tracks;
        tracks.x = rampTrack(-100, 300, CMTimeMake(2, 1), interpolation);
        const EffectSpan span = motionSpan(CMTimeMake(2, 1), CMTimeMake(4, 1), tracks);
        for (int k = 60; k < 120; ++k) {
            const double reference = *referenceSpanValue(2, 4, -100, 300, interpolation, k / 30.0);
            CHECK(close(spanValueAt(span, SpanParameter::X, exact(f30(k))), reference));
        }
        // The ends hold (the span's owner decides whether it acts there).
        CHECK(spanValueAt(span, SpanParameter::X, exact(f30(0))) == -100);
        CHECK(spanValueAt(span, SpanParameter::X, exact(f30(200))) == 300);
        CHECK(spanEdgeValue(span, SpanParameter::X, false) == -100);
        CHECK(spanEdgeValue(span, SpanParameter::X, true) == 300);
        // Parameters without keyframes are neutral.
        CHECK(spanValueAt(span, SpanParameter::Scale, exact(f30(70))) == 1);
        CHECK(spanValueAt(span, SpanParameter::Y, exact(f30(70))) == 0);
        CHECK(spanInterpolation(span) == interpolation);
    }
}

TEST_CASE("EffectSpan: the limit from the left, the interpolation shown and values kept in range") {
    SpanTracks tracks;
    tracks.scale = {key(kCMTimeZero, 1, KeyframeInterpolation::Hold), key(f30(10), 2, KeyframeInterpolation::Hold),
                    key(f30(20), 3)};
    const EffectSpan span = motionSpan(f30(30), f30(60), tracks);
    // At the hold's jump the value is the new one; the value just before (from the left) the old.
    CHECK(spanValueAt(span, SpanParameter::Scale, exact(f30(40))) == 2);
    CHECK(spanValueFromLeft(span, SpanParameter::Scale, exact(f30(40))) == 1);
    CHECK(spanValueFromLeft(span, SpanParameter::Scale, exact(f30(35))) == 1);
    CHECK(spanInterpolation(span) == KeyframeInterpolation::Hold);

    // Tracks moving differently are shown as Custom.
    SpanTracks mixed;
    mixed.x = rampTrack(0, 10, f30(30), KeyframeInterpolation::EaseIn);
    mixed.y = rampTrack(0, 10, f30(30), KeyframeInterpolation::Linear);
    CHECK(spanInterpolation(motionSpan(f30(0), f30(30), mixed)) == KeyframeInterpolation::Bezier);
    // No segment at all: Linear.
    SpanTracks single;
    single.x = {key(kCMTimeZero, 5)};
    CHECK(spanInterpolation(motionSpan(f30(0), f30(30), single)) == KeyframeInterpolation::Linear);

    // A custom curve from a project file overshooting opacity's range is limited when evaluated.
    EffectSpan fade;
    fade.id = SpanId{3};
    fade.kind = SpanKind::Opacity;
    fade.start = f30(0);
    fade.end = f30(60);
    Keyframe up = key(kCMTimeZero, 0.5, KeyframeInterpolation::Bezier);
    up.curve = TimingCurve{0.2, 3.0, 0.8, 3.0};
    fade.tracks.opacity = {up, key(f30(60), 1)};
    CHECK(spanValueAt(fade, SpanParameter::Opacity, exact(f30(30))) == 1.0);
    CHECK(spanValueAt(fade, SpanParameter::Opacity, exact(f30(1))) <= 1.0);
}

TEST_CASE("EffectSpan: a split divides the span exactly; every frame shows what it did") {
    // Source [1 s, 3 s): x eases in and out -120 -> 240 with a hold in scale and a linear turn.
    SpanTracks tracks;
    tracks.x = rampTrack(-120, 240, CMTimeMake(2, 1), KeyframeInterpolation::EaseInOut);
    tracks.scale = {key(kCMTimeZero, 1, KeyframeInterpolation::Hold), key(f30(45), 1.5, KeyframeInterpolation::EaseOut),
                    key(CMTimeMake(2, 1), 2)};
    tracks.rotation = {key(f30(10), 0), key(f30(50), 90)};
    const EffectSpan span = motionSpan(CMTimeMake(1, 1), CMTimeMake(3, 1), tracks, 2, SpanId{41});
    const std::vector<CMTime> cuts{f30(31), f30(47), f30(75), f30(89), CMTimeMake(1001 * 50, 30000),
                                   CMTimeMake(44101, 44100)};
    for (const CMTime at : cuts) {
        CAPTURE(describe(at));
        SpanCutProblem problem = SpanCutProblem::NotRepresentable;
        const auto split = splitSpan(span, at, &problem);
        REQUIRE(split.has_value());
        CHECK(problem == SpanCutProblem::None);
        CHECK(split->left.id == span.id);
        CHECK_FALSE(split->right.id);
        CHECK(split->left.lane == 2);
        CHECK(split->right.lane == 2);
        CHECK(split->left.start == span.start);
        CHECK(split->left.end == at);
        CHECK(split->right.start == at);
        CHECK(split->right.end == span.end);
        CHECK_FALSE(spanTracksProblem(split->left).has_value());
        CHECK_FALSE(spanTracksProblem(split->right).has_value());
        // Every 30 fps and 29.97 fps frame time, and the cut itself, from the part that holds it.
        std::vector<CMTime> times;
        for (int k = 30; k < 90; ++k) {
            times.push_back(f30(k));
        }
        for (int k = 30; k < 89; ++k) {
            times.push_back(CMTimeMake(1001 * k, 30000));
        }
        times.push_back(at);
        for (const CMTime t : times) {
            const EffectSpan &part = t < at ? split->left : split->right;
            for (const SpanParameter p : parametersOf(SpanKind::Motion)) {
                CHECK(close(spanValueAt(part, p, exact(t)), spanValueAt(span, p, exact(t)), 1e-12));
            }
        }
        for (const SpanParameter p : parametersOf(SpanKind::Motion)) {
            // Approaching the cut the left part does what the span did; the right part starts there.
            CHECK(close(spanValueFromLeft(split->left, p, exact(at)), spanValueFromLeft(span, p, exact(at)), 1e-12));
            CHECK(close(spanEdgeValue(split->right, p, false), spanValueAt(span, p, exact(at)), 1e-12));
        }
    }
    // Only strictly inside.
    CHECK_FALSE(splitSpan(span, span.start).has_value());
    CHECK_FALSE(splitSpan(span, span.end).has_value());
    CHECK_FALSE(splitSpan(span, f30(200)).has_value());
}

TEST_CASE("EffectSpan: a side left without keyframes holds the value it had; an overshooting curve is refused") {
    // x moves only in the second half: [1 s, 2 s) of a [0, 2 s) span.
    SpanTracks tracks;
    tracks.x = {key(CMTimeMake(1, 1), 0), key(CMTimeMake(2, 1), 100)};
    const EffectSpan span = motionSpan(kCMTimeZero, CMTimeMake(2, 1), tracks);
    const auto split = splitSpan(span, f30(15));
    REQUIRE(split.has_value());
    REQUIRE(split->left.tracks.x.size() == 1);
    CHECK(split->left.tracks.x[0].time == kCMTimeZero);
    CHECK(split->left.tracks.x[0].value == 0);
    CHECK(split->right.tracks.x.front().value == 0);

    EffectSpan fade;
    fade.id = SpanId{3};
    fade.kind = SpanKind::Opacity;
    fade.start = f30(0);
    fade.end = f30(60);
    Keyframe up = key(kCMTimeZero, 0.5, KeyframeInterpolation::Bezier);
    up.curve = TimingCurve{0.2, 3.0, 0.8, 3.0};
    fade.tracks.opacity = {up, key(f30(60), 1)};
    SpanCutProblem problem = SpanCutProblem::None;
    CHECK_FALSE(splitSpan(fade, f30(30), &problem).has_value());
    CHECK(problem == SpanCutProblem::CurveOvershoot);
    CHECK_FALSE(clipSpan(fade, f30(0), f30(30), &problem).has_value());
    CHECK(problem == SpanCutProblem::CurveOvershoot);
}

TEST_CASE("EffectSpan: clipSpan keeps the part inside, evaluated exactly at a new edge") {
    SpanTracks tracks;
    tracks.x = rampTrack(0, 300, f30(60), KeyframeInterpolation::EaseOut);
    const EffectSpan span = motionSpan(f30(30), f30(90), tracks);
    SpanCutProblem problem = SpanCutProblem::CurveOvershoot;
    CHECK(clipSpan(span, f30(0), f30(120), &problem) == span);
    CHECK(problem == SpanCutProblem::None);
    CHECK(clipSpan(span, f30(30), f30(90)) == span);
    const auto head = clipSpan(span, f30(45), f30(120));
    REQUIRE(head.has_value());
    CHECK(head->start == f30(45));
    CHECK(head->end == f30(90));
    CHECK(head->id == span.id);
    CHECK(close(spanEdgeValue(*head, SpanParameter::X, false),
                *referenceSpanValue(1, 3, 0, 300, KeyframeInterpolation::EaseOut, 1.5)));
    const auto tail = clipSpan(span, f30(0), f30(60));
    REQUIRE(tail.has_value());
    CHECK(tail->end == f30(60));
    CHECK(close(spanEdgeValue(*tail, SpanParameter::X, true),
                *referenceSpanValue(1, 3, 0, 300, KeyframeInterpolation::EaseOut, 2.0)));
    for (int k = 45; k < 60; ++k) { // both cuts at once
        const auto middle = clipSpan(span, f30(45), f30(60));
        REQUIRE(middle.has_value());
        CHECK(close(spanValueAt(*middle, SpanParameter::X, exact(f30(k))),
                    *referenceSpanValue(1, 3, 0, 300, KeyframeInterpolation::EaseOut, k / 30.0)));
    }
    CHECK_FALSE(clipSpan(span, f30(90), f30(120), &problem).has_value());
    CHECK(problem == SpanCutProblem::None);
    CHECK_FALSE(clipSpan(span, f30(0), f30(30)).has_value());
}

TEST_CASE("EffectSpan: track validation") {
    SpanTracks tracks;
    tracks.x = rampTrack(0, 10, f30(30));
    EffectSpan span = motionSpan(f30(0), f30(30), tracks);
    CHECK_FALSE(spanTracksProblem(span).has_value());
    SUBCASE("a parameter of another kind") {
        span.tracks.gain = rampTrack(0, -6, f30(30));
        CHECK(spanTracksProblem(span).value_or("").find("a motion span has no Gain keyframes") != std::string::npos);
    }
    SUBCASE("a keyframe past the span's length") {
        span.tracks.x.back().time = f30(31);
        CHECK(spanTracksProblem(span).value_or("").find("must lie within the span") != std::string::npos);
    }
    SUBCASE("a keyframe before its start") {
        span.tracks.x.front().time = f30(-1);
        CHECK(spanTracksProblem(span).value_or("").find("must lie within the span") != std::string::npos);
    }
    SUBCASE("times out of order") {
        std::swap(span.tracks.x[0], span.tracks.x[1]);
        CHECK(spanTracksProblem(span).has_value());
    }
    SUBCASE("a value out of range") {
        span.tracks.scale = {key(kCMTimeZero, -1)};
        CHECK(spanTracksProblem(span).value_or("").find("invalid value") != std::string::npos);
    }
    SUBCASE("a transition with keyframes") {
        EffectSpan transition;
        transition.id = SpanId{2};
        transition.lane = kTransitionLane;
        transition.kind = SpanKind::Transition;
        transition.start = -f30(5);
        transition.end = f30(5);
        CHECK_FALSE(spanTracksProblem(transition).has_value());
        transition.tracks.x = {key(kCMTimeZero, 1)};
        CHECK(spanTracksProblem(transition).value_or("").find("a transition has no keyframes") != std::string::npos);
    }
}

TEST_CASE("EffectSpan: lane rules and placement are validated per clip") {
    Fixture fx;
    const ClipId v = fx.addClip(fx.v1, fx.av30, 0, 90, 30);
    const ClipId a = fx.addClip(fx.a1, fx.audioOnly, 0, 90);
    fx.addSpan(v, SpanKind::Motion, 1, f30(30), f30(60));
    fx.requireValid();
    auto problem = [&] { return problemOf(fx.project); };
    SUBCASE("spans of one lane may touch but not overlap") {
        fx.addSpan(v, SpanKind::Opacity, 1, f30(60), f30(90));
        fx.requireValid();
        fx.addSpan(v, SpanKind::Opacity, 1, f30(59), f30(60));
        CHECK(problem().find("overlap on lane 1") != std::string::npos);
    }
    SUBCASE("different lanes may overlap") {
        fx.addSpan(v, SpanKind::Motion, 2, f30(40), f30(100));
        fx.addSpan(v, SpanKind::Opacity, 3, f30(30), f30(120));
        fx.requireValid();
    }
    SUBCASE("lane 0 holds transitions only; transitions lie on lane 0 only; lanes end at 3") {
        fx.sequence().findClip(v)->spans[0].lane = 0;
        CHECK(problem().find("lane 0 holds transitions only") != std::string::npos);
        fx.sequence().findClip(v)->spans[0].lane = 4;
        CHECK(problem().find("is not an effect lane") != std::string::npos);
        fx.sequence().findClip(v)->spans[0].lane = 1;
        const SpanId fade = fx.addFade(v, ClipEdge::Head, f30(10));
        fx.requireValid();
        fx.sequence().findClip(v)->findSpan(fade)->lane = 2;
        CHECK(problem().find("a transition lies on lane 0 only") != std::string::npos);
    }
    SUBCASE("kinds belong to their track's kind") {
        fx.addSpan(a, SpanKind::Motion, 1, f30(0), f30(30));
        CHECK(problem().find("a motion span on audio track") != std::string::npos);
    }
    SUBCASE("a span lies within its clip's source range") {
        fx.addSpan(v, SpanKind::Opacity, 2, f30(100), f30(121)); // the clip's source ends at frame 120
        CHECK(problem().find("outside its clip's source range") != std::string::npos);
    }
    SUBCASE("an empty span") {
        fx.addSpan(v, SpanKind::Opacity, 2, f30(40), f30(40));
        CHECK(problem().find("is empty") != std::string::npos);
    }
    SUBCASE("order: lane, then start") {
        fx.addSpan(v, SpanKind::Opacity, 1, f30(90), f30(100));
        std::swap(fx.sequence().findClip(v)->spans[0], fx.sequence().findClip(v)->spans[1]);
        CHECK(problem().find("not in lane and time order") != std::string::npos);
    }
    SUBCASE("one transition per edge") {
        fx.addFade(a, ClipEdge::Tail, f30(10));
        fx.addFade(a, ClipEdge::Tail, f30(5));
        CHECK(problem().find("more than one transition at its tail") != std::string::npos);
    }
    SUBCASE("span ids are unique in the project") {
        const SpanId id = fx.sequence().findClip(v)->spans[0].id;
        fx.addSpan(v, SpanKind::Opacity, 2, f30(30), f30(40));
        fx.sequence().findClip(v)->spans[1].id = id;
        CHECK_FALSE(problem().empty());
    }
}

TEST_CASE("Composition: lanes compose in order onto the static values and hold, against the reference") {
    Fixture fx;
    // A 90-frame clip from source 1 s with static Motion, and spans on three lanes:
    //   lane 1 Motion [1 s, 3 s): x 0 -> 100 linear, scale 1 -> 2 and rotation 0 -> 90 ease in and out;
    //   lane 2 Motion [2 s, 4 s): x 0 -> -50, scale 1 -> 0.5, linear;
    //   lane 3 Opacity [1.5 s, 3.5 s): 1 -> 0.25 easing out.
    // Each holds its end value after its end (the clip's source runs to 4 s).
    const ClipId id = fx.addClip(fx.v1, fx.av30, 0, 90, 30);
    Clip &clip = *fx.sequence().findClip(id);
    clip.video = VideoParams{10, -5, 1.5, 5, 0.8};
    SpanTracks one;
    one.x = rampTrack(0, 100, CMTimeMake(2, 1));
    one.scale = rampTrack(1, 2, CMTimeMake(2, 1), KeyframeInterpolation::EaseInOut);
    one.rotation = rampTrack(0, 90, CMTimeMake(2, 1), KeyframeInterpolation::EaseInOut);
    fx.addSpan(id, SpanKind::Motion, 1, CMTimeMake(1, 1), CMTimeMake(3, 1), one);
    SpanTracks two;
    two.x = rampTrack(0, -50, CMTimeMake(2, 1));
    two.scale = rampTrack(1, 0.5, CMTimeMake(2, 1));
    fx.addSpan(id, SpanKind::Motion, 2, CMTimeMake(2, 1), CMTimeMake(4, 1), two);
    SpanTracks three;
    three.opacity = rampTrack(1, 0.25, CMTimeMake(2, 1), KeyframeInterpolation::EaseOut);
    fx.addSpan(id, SpanKind::Opacity, 3, CMTimeMake(3, 2), CMTimeMake(7, 2), three);
    fx.requireValid();
    const Clip &c = fx.clip(id);
    using KI = KeyframeInterpolation;
    for (int f = 0; f < 90; ++f) {
        CAPTURE(f);
        const double s = 1.0 + f / 30.0;
        const double x1 = referenceHeldSpanValue(1, 3, 0, 100, KI::Linear, s).value_or(0);
        const double s1 = referenceHeldSpanValue(1, 3, 1, 2, KI::EaseInOut, s).value_or(1);
        const double r1 = referenceHeldSpanValue(1, 3, 0, 90, KI::EaseInOut, s).value_or(0);
        const double x2 = referenceHeldSpanValue(2, 4, 0, -50, KI::Linear, s).value_or(0);
        const double s2 = referenceHeldSpanValue(2, 4, 1, 0.5, KI::Linear, s).value_or(1);
        const double o3 = referenceHeldSpanValue(1.5, 3.5, 1, 0.25, KI::EaseOut, s).value_or(1);
        const VideoParams shown = motionValuesAt(c, f30(f));
        CHECK(close(shown.x, 10 + x1 + x2));
        CHECK(close(shown.y, -5));
        CHECK(close(shown.scale, 1.5 * s1 * s2));
        CHECK(close(shown.rotationDegrees, 5 + r1));
        CHECK(close(shown.opacity, 0.8 * o3));
    }
    // Without a span (`except`): the other lanes alone.
    const VideoParams without = composeMotion(c, exact(CMTimeMake(5, 2)), c.spans[1].id);
    CHECK(close(without.scale, 1.5 * *referenceSpanValue(1, 3, 1, 2, KI::EaseInOut, 2.5)));
    // After lane 1's end its end values hold exactly (the frames from source 3 s on).
    const VideoParams held = composeMotion(c, exact(CMTimeMake(7, 2)), c.spans[1].id);
    CHECK(held.x == 10 + 100);
    CHECK(held.scale == 1.5 * 2);
    CHECK(held.rotationDegrees == 5 + 90);
}

TEST_CASE("Composition: gain spans add decibels to the clip's gain and hold their end level") {
    Fixture fx;
    const ClipId id = fx.addClip(fx.a1, fx.audioOnly, 0, 90);
    fx.sequence().findClip(id)->audio.gainDb = -6;
    SpanTracks duck;
    duck.gain = rampTrack(0, -12, CMTimeMake(1, 1));
    fx.addSpan(id, SpanKind::Gain, 1, CMTimeMake(1, 2), CMTimeMake(3, 2), duck);
    SpanTracks swell;
    swell.gain = rampTrack(0, 6, CMTimeMake(1, 1), KeyframeInterpolation::EaseInOut);
    fx.addSpan(id, SpanKind::Gain, 2, CMTimeMake(1, 1), CMTimeMake(2, 1), swell);
    fx.requireValid();
    for (int k = 0; k < 720; ++k) {
        CAPTURE(k);
        const double s = k / 240.0;
        const double expected =
            -6 + referenceHeldSpanValue(0.5, 1.5, 0, -12, KeyframeInterpolation::Linear, s).value_or(0) +
            referenceHeldSpanValue(1, 2, 0, 6, KeyframeInterpolation::EaseInOut, s).value_or(0);
        CHECK(close(gainDbAt(fx.clip(id), CMTimeMake(k, 240)), expected));
    }
    // Past both ends: both end levels, exactly.
    CHECK(gainDbAt(fx.clip(id), CMTimeMake(5, 2)) == -6 - 12 + 6);
}

TEST_CASE("Composition: every span holds through a tail handle; a head handle shows the spans starting there") {
    Fixture fx;
    const ClipId id = fx.addClip(fx.v1, fx.av30, 0, 60, 30); // source [1 s, 3 s)
    const SpanId whole = fx.addSpan(id, SpanKind::Motion, 1, f30(30), f30(90));
    const SpanId early = fx.addSpan(id, SpanKind::Motion, 2, f30(30), f30(60));
    const SpanId late = fx.addSpan(id, SpanKind::Opacity, 3, f30(45), f30(75));
    Clip &clip = *fx.sequence().findClip(id);
    clip.findSpan(whole)->tracks.x = rampTrack(0, 60, f30(60));
    clip.findSpan(early)->tracks.scale = rampTrack(1, 2, f30(30));
    clip.findSpan(late)->tracks.opacity = rampTrack(0.9, 0.4, f30(30));
    fx.requireValid();
    const Clip &c = fx.clip(id);
    // Frames past the clip's end (a transition handle) are evaluated at its out point: the span
    // ending there shows its end value, and the spans that ended earlier keep holding theirs.
    for (int f = 60; f < 70; ++f) {
        const auto time = spanEvaluationTime(c, f30(f));
        REQUIRE(time.has_value());
        CHECK(time->compare(f30(90)) == 0);
        CHECK(spanActsAt(*c.findSpan(whole), *time));
        CHECK(spanActsAt(*c.findSpan(early), *time));
        const VideoParams shown = motionValuesAt(c, f30(f));
        CHECK(shown.x == 60);
        CHECK(shown.scale == 2);
        CHECK(shown.opacity == 0.4);
        CHECK(motionValuesAt(c, f30(59)).x < 60);               // the last frame is a frame short of it
        CHECK(shown.scale == motionValuesAt(c, f30(59)).scale); // lane 2 held there already
    }
    // Before the clip, its in point: the spans starting there act at their start values; the one
    // starting later contributes nothing yet.
    const auto head = spanEvaluationTime(c, f30(-3));
    REQUIRE(head.has_value());
    CHECK(spanActsAt(*c.findSpan(early), *head));
    CHECK_FALSE(spanActsAt(*c.findSpan(late), *head));
    CHECK(motionValuesAt(c, f30(-3)) == VideoParams{});
    // A span acts from its start on, and after its end holds its end value.
    CHECK_FALSE(spanActsAt(*c.findSpan(late), exact(f30(44))));
    CHECK(spanActsAt(*c.findSpan(late), exact(f30(45))));
    CHECK(spanContributionAt(*c.findSpan(late), SpanParameter::Opacity, exact(f30(44))) == 1);
    CHECK(spanContributionAt(*c.findSpan(late), SpanParameter::Opacity, exact(f30(45))) == 0.9);
    CHECK(spanContributionAt(*c.findSpan(early), SpanParameter::Scale, exact(f30(59))) < 2);
    CHECK(spanContributionAt(*c.findSpan(early), SpanParameter::Scale, exact(f30(60))) == 2);
    CHECK(spanContributionAt(*c.findSpan(early), SpanParameter::Scale, exact(f30(89))) == 2);
    // From the left: neutral up to the start, the ramp up to the end, then the hold.
    CHECK(spanContributionFromLeft(*c.findSpan(early), SpanParameter::Scale, exact(f30(30))) == 1);
    CHECK(close(spanContributionFromLeft(*c.findSpan(early), SpanParameter::Scale, exact(f30(45))), 1.5));
    CHECK(spanContributionFromLeft(*c.findSpan(early), SpanParameter::Scale, exact(f30(60))) == 2);
    CHECK(spanContributionFromLeft(*c.findSpan(early), SpanParameter::Scale, exact(f30(61))) == 2);
    // A transition span never contributes.
    const SpanId fade = fx.addFade(id, ClipEdge::Tail, f30(10));
    CHECK_FALSE(spanActsAt(*fx.clip(id).findSpan(fade), exact(f30(80))));
}

TEST_CASE("Hold after: a 5 s move from 5 s on a 30 s clip shows the framing before, moves, then holds its end") {
    // The reference case: a 30 s clip (source [0, 30 s)) with a Ken Burns move over [5 s, 10 s).
    Fixture fx;
    const ClipId id = fx.addClip(fx.v1, fx.av30, 0, 900, 0);
    SpanTracks move;
    move.x = rampTrack(0, -200, CMTimeMake(5, 1), KeyframeInterpolation::EaseInOut);
    move.y = rampTrack(0, 90, CMTimeMake(5, 1), KeyframeInterpolation::EaseInOut);
    move.scale = rampTrack(1, 1.6, CMTimeMake(5, 1), KeyframeInterpolation::EaseInOut);
    const SpanId span = fx.addSpan(id, SpanKind::Motion, 1, CMTimeMake(5, 1), CMTimeMake(10, 1), move);
    fx.requireValid();
    const Clip &c = fx.clip(id);
    const auto end = spanEdgeMotion(c, *c.findSpan(span), f30(1), true);
    REQUIRE(end.has_value());
    CHECK(*end == VideoParams{-200, 90, 1.6, 0, 1});
    for (int f = 0; f < 900; ++f) {
        CAPTURE(f);
        const VideoParams shown = motionValuesAt(c, f30(f));
        if (f < 150) {
            CHECK(shown == VideoParams{}); // the clip's own framing, exactly
        } else if (f < 300) {
            const double s = f / 30.0;
            CHECK(close(shown.x, *referenceSpanValue(5, 10, 0, -200, KeyframeInterpolation::EaseInOut, s)));
            CHECK(close(shown.y, *referenceSpanValue(5, 10, 0, 90, KeyframeInterpolation::EaseInOut, s)));
            CHECK(close(shown.scale, *referenceSpanValue(5, 10, 1, 1.6, KeyframeInterpolation::EaseInOut, s)));
        } else {
            CHECK(shown == *end); // the end framing, held exactly to the clip's end
        }
    }
    CHECK(motionValuesAt(c, f30(299)).scale < 1.6); // the move's last frame is a frame short of its end
    CHECK(motionValuesAt(c, f30(920)) == *end);     // and it holds in a tail handle
}

TEST_CASE("Hold after: chained spans on one lane compose cumulatively") {
    Fixture fx;
    // A 120-frame clip from source 0 with static Motion; lane 1: A [0.5 s, 1.5 s) x 0 -> 100 and
    // scale 1 -> 2 (linear), then B [2 s, 3 s) x 0 -> 50 and scale 1 -> 1.5 (ease in and out).
    const ClipId id = fx.addClip(fx.v1, fx.av30, 0, 120, 0);
    fx.sequence().findClip(id)->video = VideoParams{12, -4, 1.25, 3, 0.9};
    SpanTracks a;
    a.x = rampTrack(0, 100, CMTimeMake(1, 1));
    a.scale = rampTrack(1, 2, CMTimeMake(1, 1));
    fx.addSpan(id, SpanKind::Motion, 1, CMTimeMake(1, 2), CMTimeMake(3, 2), a);
    SpanTracks b;
    b.x = rampTrack(0, 50, CMTimeMake(1, 1), KeyframeInterpolation::EaseInOut);
    b.scale = rampTrack(1, 1.5, CMTimeMake(1, 1), KeyframeInterpolation::EaseInOut);
    const SpanId second = fx.addSpan(id, SpanKind::Motion, 1, CMTimeMake(2, 1), CMTimeMake(3, 1), b);
    fx.requireValid();
    using KI = KeyframeInterpolation;
    SUBCASE("the second starts neutral: it continues the held picture without a jump") {
        const Clip &c = fx.clip(id);
        for (int f = 0; f < 120; ++f) {
            CAPTURE(f);
            const double s = f / 30.0;
            const double xa = referenceHeldSpanValue(0.5, 1.5, 0, 100, KI::Linear, s).value_or(0);
            const double sa = referenceHeldSpanValue(0.5, 1.5, 1, 2, KI::Linear, s).value_or(1);
            const double xb = referenceHeldSpanValue(2, 3, 0, 50, KI::EaseInOut, s).value_or(0);
            const double sb = referenceHeldSpanValue(2, 3, 1, 1.5, KI::EaseInOut, s).value_or(1);
            const VideoParams shown = motionValuesAt(c, f30(f));
            CHECK(close(shown.x, 12 + xa + xb));
            CHECK(close(shown.scale, 1.25 * sa * sb));
            CHECK(shown.y == -4);
            CHECK(shown.rotationDegrees == 3);
            CHECK(shown.opacity == 0.9);
        }
        // Between the spans A's end values hold exactly; B's first frame shows the same picture.
        for (int f = 45; f <= 60; ++f) {
            CHECK(motionValuesAt(c, f30(f)) == VideoParams{12 + 100, -4, 1.25 * 2, 3, 0.9});
        }
        // Past B the two end values hold, one on top of the other.
        CHECK(motionValuesAt(c, f30(119)) == VideoParams{12 + 100 + 50, -4, 1.25 * 2 * 1.5, 3, 0.9});
        // B's start framing, read as a Ken Burns move reads it, is A's held end framing.
        const auto start = spanEdgeMotion(c, *c.findSpan(second), f30(1), false);
        REQUIRE(start.has_value());
        CHECK(*start == motionValuesAt(c, f30(59)));
    }
    SUBCASE("the second starts elsewhere: it jumps from the held picture by its start values") {
        Clip &clip = *fx.sequence().findClip(id);
        clip.findSpan(second)->tracks.x = rampTrack(30, 50, CMTimeMake(1, 1), KI::EaseInOut);
        clip.findSpan(second)->tracks.scale = rampTrack(0.5, 1.5, CMTimeMake(1, 1), KI::EaseInOut);
        fx.requireValid();
        const Clip &c = fx.clip(id);
        CHECK(motionValuesAt(c, f30(59)) == VideoParams{112, -4, 2.5, 3, 0.9});
        CHECK(motionValuesAt(c, f30(60)) == VideoParams{112 + 30, -4, 2.5 * 0.5, 3, 0.9});
        CHECK(motionValuesAt(c, f30(95)) == VideoParams{112 + 50, -4, 2.5 * 1.5, 3, 0.9});
    }
}

TEST_CASE("Hold after: Opacity and Gain spans hold their end values; chained Gain spans add up") {
    Fixture fx;
    const ClipId v = fx.addClip(fx.v1, fx.av30, 0, 90, 30); // source [1 s, 4 s)
    SpanTracks dim;
    dim.opacity = rampTrack(1, 0.4, f30(15));
    fx.addSpan(v, SpanKind::Opacity, 2, f30(40), f30(55), dim);
    fx.requireValid();
    for (int f = 0; f < 90; ++f) {
        CAPTURE(f);
        const double want = referenceHeldSpanValue(40, 55, 1, 0.4, KeyframeInterpolation::Linear, 30 + f).value_or(1);
        CHECK(close(motionValuesAt(fx.clip(v), f30(f)).opacity, want));
    }
    CHECK(motionValuesAt(fx.clip(v), f30(89)).opacity == 0.4);

    const ClipId a = fx.addClip(fx.a1, fx.audioOnly, 0, 120, 0);
    fx.sequence().findClip(a)->audio.gainDb = -3;
    SpanTracks duck;
    duck.gain = rampTrack(0, -12, CMTimeMake(1, 2));
    fx.addSpan(a, SpanKind::Gain, 1, CMTimeMake(1, 2), CMTimeMake(1, 1), duck);
    SpanTracks swell; // starts neutral: the level goes on from -15 dB
    swell.gain = rampTrack(0, 9, CMTimeMake(1, 2), KeyframeInterpolation::EaseOut);
    fx.addSpan(a, SpanKind::Gain, 1, CMTimeMake(2, 1), CMTimeMake(5, 2), swell);
    fx.requireValid();
    for (int k = 0; k < 960; ++k) {
        CAPTURE(k);
        const double s = k / 240.0;
        const double want = -3 +
                            referenceHeldSpanValue(0.5, 1, 0, -12, KeyframeInterpolation::Linear, s).value_or(0) +
                            referenceHeldSpanValue(2, 2.5, 0, 9, KeyframeInterpolation::EaseOut, s).value_or(0);
        CHECK(close(gainDbAt(fx.clip(a), CMTimeMake(k, 240)), want));
    }
    CHECK(gainDbAt(fx.clip(a), CMTimeMake(3, 2)) == -15);
    CHECK(gainDbAt(fx.clip(a), CMTimeMake(2, 1)) == -15); // the second span's first instant: no jump
    CHECK(gainDbAt(fx.clip(a), CMTimeMake(3, 1)) == -6);
}

TEST_CASE("Hold after: on a still and at speeds other than 1 the end value holds from the span's end") {
    Fixture fx;
    // A still over timeline frames [30, 120): a span over its frames [10, 40) holds 1.5 after.
    const ClipId still = fx.addClip(fx.v1, fx.still, 30, 90);
    SpanTracks grow;
    grow.scale = rampTrack(0.5, 1.5, f30(30), KeyframeInterpolation::EaseIn);
    fx.addSpan(still, SpanKind::Motion, 1, f30(10), f30(40), grow);
    // At 3/2 over timeline [0, 60) from source 1 s: a span over source [1.5 s, 2.5 s) (timeline
    // frames [10, 30)) holds x = 80 after; at 1/3 over [0, 90) from source 0: a span over source
    // [0.2 s, 0.6 s) (frames [18, 54)) holds rotation 30.
    const ClipId fast = fx.addClip(fx.v2, fx.av30, 0, 60, 30, 1.5);
    SpanTracks pan;
    pan.x = rampTrack(0, 80, CMTimeMake(1, 1));
    fx.addSpan(fast, SpanKind::Motion, 2, CMTimeMake(3, 2), CMTimeMake(5, 2), pan);
    const ClipId slow = fx.addClip(fx.v2, fx.av30, 60, 90, 0, 1.0 / 3);
    SpanTracks turn;
    turn.rotation = rampTrack(0, 30, CMTimeMake(2, 5));
    fx.addSpan(slow, SpanKind::Motion, 3, CMTimeMake(1, 5), CMTimeMake(3, 5), turn);
    fx.requireValid();
    for (int f = 30; f < 120; ++f) {
        CAPTURE(f);
        const double want =
            referenceHeldSpanValue(10, 40, 0.5, 1.5, KeyframeInterpolation::EaseIn, f - 30.0).value_or(1);
        CHECK(close(motionValuesAt(fx.clip(still), f30(f)).scale, want));
    }
    CHECK(motionValuesAt(fx.clip(still), f30(119)).scale == 1.5);
    for (int f = 0; f < 60; ++f) {
        CAPTURE(f);
        const double want =
            referenceHeldSpanValue(1.5, 2.5, 0, 80, KeyframeInterpolation::Linear, 1 + f / 20.0).value_or(0);
        CHECK(close(motionValuesAt(fx.clip(fast), f30(f)).x, want));
    }
    CHECK(motionValuesAt(fx.clip(fast), f30(30)).x == 80);
    for (int f = 60; f < 150; ++f) {
        CAPTURE(f);
        const double s = (f - 60) / 90.0;
        const double want = referenceHeldSpanValue(0.2, 0.6, 0, 30, KeyframeInterpolation::Linear, s).value_or(0);
        CHECK(close(motionValuesAt(fx.clip(slow), f30(f)).rotationDegrees, want));
    }
    CHECK(motionValuesAt(fx.clip(slow), f30(60 + 54)).rotationDegrees == 30);
}

TEST_CASE("Hold after: a span ending exactly at a cut holds from there, into a split's right piece too") {
    Fixture fx;
    // A 60-frame clip from source 1 s (source [1 s, 3 s)): lane 1 moves x 0 -> 90 over its last
    // 30 frames, ending on its out point; lane 2 scales 1 -> 2 over [1 s, 2 s), ending at the middle.
    const ClipId id = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
    fx.sequence().findClip(id)->video = VideoParams{5, 0, 1.2, 0, 1};
    SpanTracks tail;
    tail.x = rampTrack(0, 90, f30(30));
    fx.addSpan(id, SpanKind::Motion, 1, f30(60), f30(90), tail);
    SpanTracks middle;
    middle.scale = rampTrack(1, 2, f30(30), KeyframeInterpolation::EaseOut);
    const SpanId half = fx.addSpan(id, SpanKind::Motion, 2, f30(30), f30(60), middle);
    fx.requireValid();
    const Clip &c = fx.clip(id);
    CHECK(close(motionValuesAt(c, f30(59)).x, 5 + 87)); // a frame short of the end value
    CHECK(motionValuesAt(c, f30(60)).x == 95);          // the out point (a tail handle): the end value
    // A cut exactly at the lane-2 span's end: the right piece starts where the span ends, so the
    // span stays on the left and its held scale becomes the right piece's own.
    Clip right = c;
    REQUIRE(right.setTimelineStartKeepingEnd(f30(30)) == RetimeResult::Ok);
    CHECK(right.findSpan(half) == nullptr);
    CHECK(right.video == VideoParams{5, 0, 1.2 * 2, 0, 1});
    Clip left = c;
    REQUIRE(left.setTimelineEnd(f30(30)) == RetimeResult::Ok);
    REQUIRE(left.findSpan(half) != nullptr);
    CHECK(left.video == c.video);
    for (int f = 0; f < 60; ++f) {
        CAPTURE(f);
        const Clip &piece = f < 30 ? left : right;
        CHECK(motionValuesAt(piece, f30(f)) == motionValuesAt(c, f30(f)));
    }
    // The left piece's tail handle holds the lane-2 end value (the cut is its out point).
    CHECK(motionValuesAt(left, f30(33)).scale == 1.2 * 2);
}

TEST_CASE("Hold after: a trim or split past a span keeps its held value as the clip's own") {
    Fixture fx;
    // A 120-frame clip from source 0 with static Motion: lane 1 A [0.5 s, 1.5 s) and B [2 s, 3 s);
    // lane 2 an Opacity span [0.2 s, 0.8 s); the linked audio clip ducks -9 dB over [0.3 s, 0.6 s).
    const auto [v, a] = fx.addLinkedPair(0, 120, 0);
    fx.sequence().findClip(v)->video = VideoParams{12, -4, 1.25, 3, 0.9};
    fx.sequence().findClip(a)->audio.gainDb = -2;
    SpanTracks first;
    first.x = rampTrack(0, 100, CMTimeMake(1, 1));
    first.scale = rampTrack(1, 2, CMTimeMake(1, 1), KeyframeInterpolation::EaseInOut);
    const SpanId spanA = fx.addSpan(v, SpanKind::Motion, 1, CMTimeMake(1, 2), CMTimeMake(3, 2), first);
    SpanTracks second;
    second.x = rampTrack(0, 50, CMTimeMake(1, 1));
    const SpanId spanB = fx.addSpan(v, SpanKind::Motion, 1, CMTimeMake(2, 1), CMTimeMake(3, 1), second);
    SpanTracks fade;
    fade.opacity = rampTrack(1, 0.5, f30(18));
    const SpanId spanO = fx.addSpan(v, SpanKind::Opacity, 2, f30(6), f30(24), fade);
    SpanTracks duck;
    duck.gain = rampTrack(0, -9, f30(9));
    const SpanId spanG = fx.addSpan(a, SpanKind::Gain, 1, f30(9), f30(18), duck);
    fx.requireValid();
    const Clip video = fx.clip(v);
    const Clip audio = fx.clip(a);

    // A head trim to frame 50 (source 5/3 s): A and the Opacity span lie wholly before it.
    Clip trimmed = video;
    REQUIRE(trimmed.setTimelineStartKeepingEnd(f30(50)) == RetimeResult::Ok);
    CHECK(trimmed.findSpan(spanA) == nullptr);
    CHECK(trimmed.findSpan(spanO) == nullptr);
    REQUIRE(trimmed.findSpan(spanB) != nullptr);
    CHECK(trimmed.video == VideoParams{12 + 100, -4, 1.25 * 2, 3, 0.9 * 0.5});
    // The held values were composed in the composition's order (lane 1 before lane 2, A before B),
    // so the remaining frames are the same to the bit.
    for (int f = 50; f < 125; ++f) {
        CAPTURE(f);
        CHECK(motionValuesAt(trimmed, f30(f)) == motionValuesAt(video, f30(f)));
    }
    Clip ducked = audio;
    REQUIRE(ducked.setTimelineStartKeepingEnd(f30(50)) == RetimeResult::Ok);
    CHECK(ducked.findSpan(spanG) == nullptr);
    CHECK(ducked.audio.gainDb == -11);
    for (int k = 200; k < 480; ++k) {
        CHECK(gainDbAt(ducked, CMTimeMake(k, 120)) == gainDbAt(audio, CMTimeMake(k, 120)));
    }

    // A trim that only cuts into a span clips it; nothing is held before it.
    Clip into = video;
    REQUIRE(into.setTimelineStartKeepingEnd(f30(20)) == RetimeResult::Ok);
    CHECK(into.findSpan(spanA) != nullptr);
    CHECK(into.findSpan(spanO) != nullptr);
    CHECK(into.video == video.video);
    for (int f = 20; f < 120; ++f) {
        CHECK(close(motionValuesAt(into, f30(f)).x, motionValuesAt(video, f30(f)).x, 1e-12));
        CHECK(close(motionValuesAt(into, f30(f)).scale, motionValuesAt(video, f30(f)).scale, 1e-12));
    }

    // A still: its spans move back with a head trim and those left before its start fold in.
    const ClipId still = fx.addClip(fx.v2, fx.still, 0, 90);
    SpanTracks grow;
    grow.scale = rampTrack(1, 1.5, f30(20));
    fx.addSpan(still, SpanKind::Motion, 1, f30(10), f30(30), grow);
    fx.requireValid();
    Clip stillTrimmed = fx.clip(still);
    REQUIRE(stillTrimmed.setTimelineStartKeepingEnd(f30(40)) == RetimeResult::Ok);
    CHECK(stillTrimmed.spans.empty());
    CHECK(stillTrimmed.video.scale == 1.5);
    for (int f = 40; f < 90; ++f) {
        CHECK(motionValuesAt(stillTrimmed, f30(f)) == motionValuesAt(fx.clip(still), f30(f)));
    }

    // Values too large to keep refuse the change and leave the clip as it was.
    Clip huge = video;
    huge.video.x = 1.5e308;
    huge.findSpan(spanA)->tracks.x = rampTrack(0, 1.5e308, CMTimeMake(1, 1));
    const Clip hugeBefore = huge;
    CHECK(huge.setTimelineStartKeepingEnd(f30(50)) == RetimeResult::HeldValuesOverflow);
    CHECK(huge == hugeBefore);
}

TEST_CASE("Clip spans follow trims: effect spans are clipped exactly, fades shrink, the edited edge gives way") {
    Fixture fx;
    const ClipId id = fx.addClip(fx.v1, fx.av30, 0, 90, 30); // source [1 s, 4 s)
    SpanTracks move;
    move.x = rampTrack(0, 90, CMTimeMake(3, 1), KeyframeInterpolation::EaseIn);
    const SpanId span = fx.addSpan(id, SpanKind::Motion, 1, f30(30), f30(120), move);
    const SpanId before45 = fx.addSpan(id, SpanKind::Opacity, 2, f30(35), f30(44));
    const SpanId across = fx.addSpan(id, SpanKind::Opacity, 3, f30(40), f30(50));
    fx.requireValid();
    Clip clip = fx.clip(id);
    REQUIRE(clip.setTimelineStartKeepingEnd(f30(15)) == RetimeResult::Ok); // source now from 1.5 s
    REQUIRE(clip.setTimelineEnd(f30(75)) == RetimeResult::Ok);             // to 3.5 s
    const EffectSpan *cut = clip.findSpan(span);
    REQUIRE(cut != nullptr);
    CHECK(cut->start == f30(45));
    CHECK(cut->end == f30(105));
    CHECK(close(spanEdgeValue(*cut, SpanParameter::X, false),
                *referenceSpanValue(1, 4, 0, 90, KeyframeInterpolation::EaseIn, 1.5)));
    CHECK(close(spanEdgeValue(*cut, SpanParameter::X, true),
                *referenceSpanValue(1, 4, 0, 90, KeyframeInterpolation::EaseIn, 3.5)));
    CHECK(clip.findSpan(before45) == nullptr); // it lay before the new in point (source frame 45): removed
    REQUIRE(clip.findSpan(across) != nullptr);  // it crossed it: clipped
    CHECK(clip.findSpan(across)->start == f30(45));
    CHECK(clip.findSpan(across)->end == f30(50));
    // Every remaining frame shows what it showed before (the removed Opacity span was neutral, so
    // nothing of it is held).
    const Clip &before = fx.clip(id);
    CHECK(clip.video == before.video);
    for (int f = 15; f < 75; ++f) {
        CHECK(close(motionValuesAt(clip, f30(f)).x, motionValuesAt(before, f30(f)).x, 1e-12));
        CHECK(motionValuesAt(clip, f30(f)).opacity == motionValuesAt(before, f30(f)).opacity);
    }

    // Fades: an audio clip with a 30-frame fade in and a 40-frame fade out, cut to 50 frames from
    // the tail: the fade out gives way first; from the head, the fade in.
    const ClipId music = fx.addClip(fx.a1, fx.audioOnly, 0, 100);
    fx.addFade(music, ClipEdge::Head, f30(30));
    fx.addFade(music, ClipEdge::Tail, f30(40));
    fx.requireValid();
    Clip tail = fx.clip(music);
    REQUIRE(tail.setTimelineEnd(f30(50)) == RetimeResult::Ok);
    CHECK(clipFadeLength(tail, ClipEdge::Head) == f30(30));
    CHECK(clipFadeLength(tail, ClipEdge::Tail) == f30(20));
    Clip head = fx.clip(music);
    REQUIRE(head.setTimelineStartKeepingEnd(f30(50)) == RetimeResult::Ok);
    CHECK(clipFadeLength(head, ClipEdge::Head) == f30(10));
    CHECK(clipFadeLength(head, ClipEdge::Tail) == f30(40));
    Clip gone = fx.clip(music);
    REQUIRE(gone.setTimelineEnd(f30(30)) == RetimeResult::Ok);
    CHECK(clipFadeLength(gone, ClipEdge::Head) == f30(30));
    CHECK(gone.transitionAt(ClipEdge::Tail) == nullptr); // shortened to nothing: removed
}
