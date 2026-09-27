// Continue on Next Clip (EditOps.h planContinueMotion, ContinueMotionSpan): a Motion span's move carried
// on to the clip touching its clip's end. The new span starts on the next clip's first frame with the
// placement the clip has at the cut, continues the move at its rate (per-second changes of position and
// rotation, the per-second zoom ratio) for as long as the span lasted (shortened to the next clip and to
// a free lane), composed onto the next clip's own values as relative values, with the same easing; one
// undo step; the refusals say why in a sentence.

#include "EditTestSupport.h"

#include "../../Engine/Edit/UndoStack.h"

#include <cmath>
#include <string>

using namespace vetest;

namespace {

// C: V1 [0, 60) and N: V1 [60, 180), both av30, touching.
struct ContinueFixture : Fixture {
    ClipId c, n;
    ContinueFixture() {
        c = addClip(v1, av30, 0, 60, 30);
        n = addClip(v1, av30, 60, 120, 600);
        requireValid();
    }

    SpanId add(ClipId clip, int lane, std::int64_t from, std::int64_t to, std::vector<SpanValueChange> values = {},
               KeyframeInterpolation easing = KeyframeInterpolation::Linear) {
        AddSpan command(seq, clip, SpanKind::Motion, lane, f30(from), f30(to));
        applyReversible(project, command);
        if (!values.empty()) {
            SetSpanValues set(seq, command.createdSpanId(), std::move(values), "Change Span Values", easing);
            applyReversible(project, set);
        }
        return command.createdSpanId();
    }

    // Continues `span` (checked reversible) and returns the new span.
    SpanId continueOn(SpanId span) {
        ContinueMotionSpan command(seq, span);
        applyReversible(project, command);
        CHECK(command.name() == "Continue on Next Clip");
        return command.createdSpanId();
    }

    EditResult refusal(SpanId span) {
        ContinueMotionPlan plan;
        const EditResult planned = planContinueMotion(project, sequence(), span, plan);
        ContinueMotionSpan command(seq, span);
        const std::string before = toJsonString(project);
        const EditResult applied = command.apply(project);
        CHECK_FALSE(applied.ok());
        CHECK(applied.error == planned.error);
        CHECK(applied.message == planned.message);
        CHECK(toJsonString(project) == before);
        return applied;
    }

    const EffectSpan &span(SpanId id) const {
        const EffectSpan *found = sequence().findSpan(id);
        REQUIRE(found != nullptr);
        return *found;
    }

    VideoParams edge(ClipId clip, SpanId id, bool atEnd) const {
        const auto motion = spanEdgeMotion(this->clip(clip), span(id), sequence().frameDuration, atEnd);
        REQUIRE(motion.has_value());
        return *motion;
    }
};

void checkMotion(const VideoParams &actual, double x, double y, double scale, double rotation) {
    CHECK(actual.x == doctest::Approx(x).epsilon(1e-9));
    CHECK(actual.y == doctest::Approx(y).epsilon(1e-9));
    CHECK(actual.scale == doctest::Approx(scale).epsilon(1e-12));
    CHECK(actual.rotationDegrees == doctest::Approx(rotation).epsilon(1e-9));
}

} // namespace

TEST_CASE("Continue on Next Clip: the next clip starts where the move is at the cut and goes on at its rate") {
    ContinueFixture fx;
    // A 2 s move on the whole of C: scale 1 -> 1.5, x 0 -> 300, y 0 -> -40, rotation 0 -> 10, eased.
    const SpanId move =
        fx.add(fx.c, 1, 0, 60,
               {SpanValueChange{SpanParameter::Scale, 1.0, 1.5}, SpanValueChange{SpanParameter::X, 0.0, 300.0},
                SpanValueChange{SpanParameter::Y, 0.0, -40.0}, SpanValueChange{SpanParameter::Rotation, 0.0, 10.0}},
               KeyframeInterpolation::EaseInOut);
    SUBCASE("over the same length on a clip with its own placement") {
        // N sits at half size, 100 px left: the new span's values are relative to that.
        Clip &next = *fx.sequence().findClip(fx.n);
        next.video = VideoParams{-100.0, 0.0, 0.5, 0.0, 1.0};
        fx.requireValid();
        const SpanId continued = fx.continueOn(move);
        const EffectSpan &span = fx.span(continued);
        CHECK(span.kind == SpanKind::Motion);
        CHECK(span.lane == 1);
        CHECK(fx.sequence().trackOfClip(fx.n)->find(fx.n)->findSpan(continued) != nullptr);
        const auto range = spanTimelineRange(fx.clip(fx.n), span, *fx.sequence().trackOfClip(fx.n));
        REQUIRE(range.has_value());
        CHECK(range->start == f30(60));
        CHECK(range->end == f30(120));
        CHECK(spanInterpolation(span) == KeyframeInterpolation::EaseInOut);
        // Start: what C shows at the cut (the move's end placement) is what N's first frame shows.
        const VideoParams atCut = motionValuesAt(fx.clip(fx.c), f30(60));
        checkMotion(atCut, 300.0, -40.0, 1.5, 10.0);
        checkMotion(fx.edge(fx.c, move, true), 300.0, -40.0, 1.5, 10.0);
        checkMotion(motionValuesAt(fx.clip(fx.n), f30(60)), 300.0, -40.0, 1.5, 10.0);
        checkMotion(fx.edge(fx.n, continued, false), 300.0, -40.0, 1.5, 10.0);
        // End: the same rate for another 2 s: x +300, y -40, rotation +10, scale x1.5 again.
        checkMotion(fx.edge(fx.n, continued, true), 600.0, -80.0, 2.25, 20.0);
        // Relative to N's own placement.
        CHECK(spanEdgeValue(span, SpanParameter::Scale, false) == doctest::Approx(3.0).epsilon(1e-12));
        CHECK(spanEdgeValue(span, SpanParameter::Scale, true) == doctest::Approx(4.5).epsilon(1e-12));
        CHECK(spanEdgeValue(span, SpanParameter::X, false) == doctest::Approx(400.0).epsilon(1e-12));
        // The move goes on without a repeated framing: C's last frame is a frame short of the cut's
        // placement, N's first frame is the placement at the cut.
        CHECK(motionValuesAt(fx.clip(fx.c), f30(59)).scale < 1.5);
    }
    SUBCASE("shortened to a shorter next clip, at the same rate") {
        SplitClip split(fx.seq, fx.n, f30(90));
        applyReversible(fx.project, split);
        const SpanId continued = fx.continueOn(move);
        const auto range =
            spanTimelineRange(fx.clip(fx.n), fx.span(continued), *fx.sequence().trackOfClip(fx.n));
        REQUIRE(range.has_value());
        CHECK(range->end == f30(90));
        // 1 s of a 2 s move: x +150, y -20, rotation +5, scale x sqrt(1.5).
        checkMotion(fx.edge(fx.n, continued, true), 450.0, -60.0, 1.5 * std::sqrt(1.5), 15.0);
    }
    SUBCASE("on another lane when the move's lane is taken on the next clip's first frame") {
        fx.add(fx.n, 1, 60, 70);
        const SpanId continued = fx.continueOn(move);
        CHECK(fx.span(continued).lane == 2);
        checkMotion(motionValuesAt(fx.clip(fx.n), f30(60)), 300.0, -40.0, 1.5, 10.0);
    }
    SUBCASE("shortened to the free part of the lane") {
        fx.add(fx.n, 1, 100, 110);
        fx.add(fx.n, 2, 60, 61);
        fx.add(fx.n, 3, 60, 61);
        const SpanId continued = fx.continueOn(move);
        const EffectSpan &span = fx.span(continued);
        CHECK(span.lane == 1);
        const auto range = spanTimelineRange(fx.clip(fx.n), span, *fx.sequence().trackOfClip(fx.n));
        REQUIRE(range.has_value());
        CHECK(range->end == f30(100));
    }
    SUBCASE("undo removes the continued span in one step") {
        UndoStack stack;
        auto command = std::make_unique<ContinueMotionSpan>(fx.seq, move);
        ContinueMotionSpan *raw = command.get();
        const std::string before = toJsonString(fx.project);
        REQUIRE(stack.push(fx.project, std::move(command)).ok());
        const SpanId continued = raw->createdSpanId();
        CHECK(fx.sequence().findSpan(continued) != nullptr);
        CHECK(stack.undoName() == "Continue on Next Clip");
        REQUIRE(stack.undo(fx.project));
        CHECK(fx.sequence().findSpan(continued) == nullptr);
        CHECK(toJsonString(fx.project) == before);
    }
}

TEST_CASE("Continue on Next Clip: a move that ended before the cut continues from what the clip holds") {
    ContinueFixture fx;
    // A zoom on lane 1 over [0, 30) and a later pan on lane 2 over [20, 45): the pan is the last move.
    const SpanId zoom = fx.add(fx.c, 1, 0, 30, {SpanValueChange{SpanParameter::Scale, 1.0, 2.0}});
    const SpanId pan = fx.add(fx.c, 2, 20, 45, {SpanValueChange{SpanParameter::X, 0.0, 100.0}});
    // The zoom is not the last move.
    const EditResult notLast = fx.refusal(zoom);
    CHECK(notLast.error == EditError::InvalidArgument);
    CHECK(notLast.message == "Another move on “av30.mov” ends after this one: continue the clip's last move instead.");
    const SpanId continued = fx.continueOn(pan);
    // From the cut: zoom held at 2, pan held at 100.
    checkMotion(fx.edge(fx.n, continued, false), 100.0, 0.0, 2.0, 0.0);
    // 25 frames of pan (100 px) continued over 25 frames on the next clip, no zoom in it.
    checkMotion(fx.edge(fx.n, continued, true), 200.0, 0.0, 2.0, 0.0);
    CHECK(fx.span(continued).lane == 2);
}

TEST_CASE("Continue on Next Clip: refusals say why, a still takes the span") {
    ContinueFixture fx;
    const SpanId move = fx.add(fx.c, 1, 0, 60, {SpanValueChange{SpanParameter::Scale, 1.0, 1.25}});
    SUBCASE("no clip touches the end") {
        RemoveClips remove(fx.seq, {fx.n});
        applyReversible(fx.project, remove);
        const EditResult r = fx.refusal(move);
        CHECK(r.error == EditError::NotAdjacent);
        CHECK(r.message == "No clip touches the end of “av30.mov”, so there is nothing to continue the move on.");
    }
    SUBCASE("every lane of the next clip is taken on its first frame") {
        for (int lane = 1; lane <= 3; ++lane) {
            fx.add(fx.n, lane, 60, 62);
        }
        const EditResult r = fx.refusal(move);
        CHECK(r.error == EditError::Overlap);
        CHECK(r.message == "Every effect lane of “av30.mov” has a span on its first frame, so the move has no "
                           "room there: remove one or move it to a free lane.");
    }
    SUBCASE("not a Motion span") {
        AddSpan fade(fx.seq, fx.c, SpanKind::Opacity, 2, f30(0), f30(30));
        applyReversible(fx.project, fade);
        const EditResult r = fx.refusal(fade.createdSpanId());
        CHECK(r.error == EditError::InvalidArgument);
        CHECK(r.message == "Continue on Next Clip carries a Motion span's move on to the next clip.");
    }
    SUBCASE("a move from scale 0 has no zoom rate") {
        SetSpanValues zero(fx.seq, move, {SpanValueChange{SpanParameter::Scale, 0.0, 1.0}});
        applyReversible(fx.project, zero);
        CHECK(fx.refusal(move).message == "The move starts at scale 0, so it has no zoom rate to continue.");
    }
    SUBCASE("the next clip at scale 0") {
        fx.sequence().findClip(fx.n)->video.scale = 0.0;
        fx.requireValid();
        CHECK(fx.refusal(move).message ==
              "“av30.mov” has scale 0 where the move would go, so no span value can show it.");
    }
    SUBCASE("a locked track") {
        fx.track(fx.v1).locked = true;
        CHECK(fx.refusal(move).error == EditError::TrackLocked);
    }
    SUBCASE("a still is continued on like any clip") {
        RemoveClips remove(fx.seq, {fx.n});
        applyReversible(fx.project, remove);
        const ClipId still = fx.addClip(fx.v1, fx.still, 60, 90);
        fx.requireValid();
        const SpanId continued = fx.continueOn(move);
        checkMotion(motionValuesAt(fx.clip(still), f30(60)), 0.0, 0.0, 1.25, 0.0);
        checkMotion(fx.edge(still, continued, true), 0.0, 0.0, 1.25 * 1.25, 0.0);
    }
}

TEST_CASE("Continue on Next Clip: across forward and reversed clips (A | reversed A | A)") {
    Fixture fx;
    const ClipId first = fx.addClip(fx.v1, fx.av30, 0, 60, 300);
    const ClipId middle = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    const ClipId last = fx.addClip(fx.v1, fx.av30, 120, 60, 300);
    fx.requireValid();
    SetClipReversed reverse(fx.seq, middle, true);
    applyReversible(fx.project, reverse);
    AddSpan add(fx.seq, first, SpanKind::Motion, 1, f30(0), f30(60));
    applyReversible(fx.project, add);
    SetSpanValues values(fx.seq, add.createdSpanId(),
                         {SpanValueChange{SpanParameter::Scale, 1.0, 1.5}, SpanValueChange{SpanParameter::X, 0.0, 60.0}});
    applyReversible(fx.project, values);
    ContinueMotionSpan onReversed(fx.seq, add.createdSpanId());
    applyReversible(fx.project, onReversed);
    ContinueMotionSpan onLast(fx.seq, onReversed.createdSpanId());
    applyReversible(fx.project, onLast);
    const CMTime fd = fx.sequence().frameDuration;
    // One zoom through three clips: 1.5 at the first cut, 2.25 at the second, 3.375 at the end.
    const auto reversedEnd = spanEdgeMotion(fx.clip(middle), *fx.sequence().findSpan(onReversed.createdSpanId()), fd, true);
    const auto lastEnd = spanEdgeMotion(fx.clip(last), *fx.sequence().findSpan(onLast.createdSpanId()), fd, true);
    REQUIRE(reversedEnd.has_value());
    REQUIRE(lastEnd.has_value());
    checkMotion(motionValuesAt(fx.clip(middle), f30(60)), 60.0, 0.0, 1.5, 0.0);
    checkMotion(*reversedEnd, 120.0, 0.0, 2.25, 0.0);
    checkMotion(motionValuesAt(fx.clip(last), f30(120)), 120.0, 0.0, 2.25, 0.0);
    checkMotion(*lastEnd, 180.0, 0.0, 3.375, 0.0);
    // Frame by frame the zoom never goes back or repeats across the cuts (a linear move: the scale grows
    // every frame).
    double previous = 0.0;
    for (std::int64_t f = 0; f < 180; ++f) {
        const Clip &clip = fx.clip(f < 60 ? first : f < 120 ? middle : last);
        const double scale = motionValuesAt(clip, f30(f)).scale;
        CHECK_MESSAGE(scale > previous, "frame " << f);
        previous = scale;
    }
}
