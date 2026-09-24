// Effect spans in the model (EffectSpan.h, Clip.h): kinds, parameters and their ranges, values at
// exact times, exact splits and cuts, track validation, lane rules, and the composition of lanes
// (position and rotation add, scale and opacity multiply, gain adds in dB), each checked against
// the independent references of SpanReference.h.

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

TEST_CASE("Composition: lanes compose in order onto the static values, against the reference") {
    Fixture fx;
    // A 90-frame clip from source 1 s with static Motion, and spans on three lanes:
    //   lane 1 Motion [1 s, 3 s): x 0 -> 100 linear, scale 1 -> 2 and rotation 0 -> 90 ease in and out;
    //   lane 2 Motion [2 s, 4 s): x 0 -> -50, scale 1 -> 0.5, linear;
    //   lane 3 Opacity [1.5 s, 3.5 s): 1 -> 0.25 easing out.
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
        const double x1 = referenceSpanValue(1, 3, 0, 100, KI::Linear, s).value_or(0);
        const double s1 = referenceSpanValue(1, 3, 1, 2, KI::EaseInOut, s).value_or(1);
        const double r1 = referenceSpanValue(1, 3, 0, 90, KI::EaseInOut, s).value_or(0);
        const double x2 = referenceSpanValue(2, 4, 0, -50, KI::Linear, s).value_or(0);
        const double s2 = referenceSpanValue(2, 4, 1, 0.5, KI::Linear, s).value_or(1);
        const double o3 = referenceSpanValue(1.5, 3.5, 1, 0.25, KI::EaseOut, s).value_or(1);
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
}

TEST_CASE("Composition: gain spans add decibels to the clip's gain") {
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
        const double expected = -6 + referenceSpanValue(0.5, 1.5, 0, -12, KeyframeInterpolation::Linear, s).value_or(0) +
                                referenceSpanValue(1, 2, 0, 6, KeyframeInterpolation::EaseInOut, s).value_or(0);
        CHECK(close(gainDbAt(fx.clip(id), CMTimeMake(k, 240)), expected));
    }
}

TEST_CASE("Composition: a span reaching the clip's out point keeps acting through a tail handle") {
    Fixture fx;
    const ClipId id = fx.addClip(fx.v1, fx.av30, 0, 60, 30); // source [1 s, 3 s)
    const SpanId whole = fx.addSpan(id, SpanKind::Motion, 1, f30(30), f30(90));
    const SpanId early = fx.addSpan(id, SpanKind::Motion, 2, f30(30), f30(60));
    Clip &clip = *fx.sequence().findClip(id);
    clip.findSpan(whole)->tracks.x = rampTrack(0, 60, f30(60));
    clip.findSpan(early)->tracks.scale = rampTrack(1, 2, f30(30));
    fx.requireValid();
    const Clip &c = fx.clip(id);
    // Frames past the clip's end (a transition handle) are evaluated at its out point: the span
    // ending there shows its end value, the earlier one nothing.
    for (int f = 60; f < 70; ++f) {
        const auto time = spanEvaluationTime(c, f30(f));
        REQUIRE(time.has_value());
        CHECK(time->compare(f30(90)) == 0);
        CHECK(spanActiveAt(c, *c.findSpan(whole), *time));
        CHECK_FALSE(spanActiveAt(c, *c.findSpan(early), *time));
        CHECK(motionValuesAt(c, f30(f)).x == 60);
        CHECK(motionValuesAt(c, f30(f)).scale == 1);
    }
    // Before the clip, its in point: both act, at their start values.
    CHECK(motionValuesAt(c, f30(-3)).x == 0);
    CHECK(spanActiveAt(c, *c.findSpan(early), *spanEvaluationTime(c, f30(-3))));
    // The early span's end is exclusive.
    CHECK_FALSE(spanActiveAt(c, *c.findSpan(early), exact(f30(60))));
    CHECK(spanActiveAt(c, *c.findSpan(early), exact(f30(59))));
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
    // Every remaining frame shows what it showed before.
    const Clip &before = fx.clip(id);
    for (int f = 15; f < 75; ++f) {
        CHECK(close(motionValuesAt(clip, f30(f)).x, motionValuesAt(before, f30(f)).x, 1e-12));
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
