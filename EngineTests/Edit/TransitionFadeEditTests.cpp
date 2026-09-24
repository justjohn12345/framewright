// Edits keep transitions and fades consistent (model review finding 7, carried into effect lanes):
// a split inside a transition span's range (a cross dissolve or a fade) is refused unless explicitly
// allowed, transitions an edit breaks are reported in EditResult::droppedTransitionIds, and lane-0
// fades always fit their clip.

#include "EditTestSupport.h"

using namespace vetest;

namespace {

// V1: A [0,60) source 30.., B [60,120) source 300.., a 20-frame dissolve [50,70) owned by A.
struct DissolveFixture : Fixture {
    ClipId a, b;
    SpanId t;
    DissolveFixture() {
        a = addClip(v1, av30, 0, 60, 30);
        b = addClip(v1, av30, 60, 60, 300);
        t = addTransition(v1, a, b, 20);
        requireValid();
    }
};

CMTime fadeIn(const Fixture &fx, ClipId clip) {
    return clipFadeLength(fx.clip(clip), ClipEdge::Head);
}

CMTime fadeOut(const Fixture &fx, ClipId clip) {
    return clipFadeLength(fx.clip(clip), ClipEdge::Tail);
}

} // namespace

TEST_CASE("SplitClip inside a transition range is refused unless allowed") {
    DissolveFixture fx;
    for (const std::int64_t at : {51, 55, 59}) { // inside the part before the cut
        SplitClip split(fx.seq, fx.a, f30(at));
        const EditResult r = applyRefused(fx.project, split, EditError::InsideTransition);
        CHECK(r.message.find("transition") != std::string::npos);
    }
    for (const std::int64_t at : {61, 69}) { // inside the part over B (owned by A)
        SplitClip split(fx.seq, fx.b, f30(at));
        applyRefused(fx.project, split, EditError::InsideTransition);
    }
    SUBCASE("at the range's edges the transition survives") {
        SplitClip left(fx.seq, fx.a, f30(50));
        applyReversible(fx.project, left);
        // The tail span moved to the right piece, which now owns the cut.
        const Clip *owner = nullptr;
        REQUIRE(fx.sequence().findSpan(fx.t, &owner) != nullptr);
        CHECK(owner->id == left.createdClipIds()[0]);
        SplitClip right(fx.seq, fx.b, f30(70));
        const EditResult r = applyReversible(fx.project, right);
        CHECK(r.droppedTransitionIds.empty());
        CHECK(fx.span(fx.t) != nullptr);
    }
    SUBCASE("allowed: the transition is dropped and reported") {
        SplitClip split(fx.seq, fx.a, f30(55), SplitOptions{true, true});
        const EditResult r = applyReversible(fx.project, split);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{fx.t});
        CHECK(fx.span(fx.t) == nullptr);
        split.revert(fx.project);
        CHECK(fx.span(fx.t) != nullptr);
    }
    SUBCASE("allowed on the incoming clip: the dissolve over it goes too") {
        SplitClip split(fx.seq, fx.b, f30(65), SplitOptions{true, true});
        const EditResult r = applyReversible(fx.project, split);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{fx.t});
    }
}

TEST_CASE("Edits that break a transition report it") {
    DissolveFixture fx;
    SUBCASE("overwrite inside the outgoing clip's tail") {
        OverwriteClip overwrite(fx.seq, f30(52), {place(fx.v1, fx.av30, 900, 905)});
        const EditResult r = applyReversible(fx.project, overwrite);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{fx.t});
    }
    SUBCASE("insert inside the outgoing clip's tail") {
        InsertClip insert(fx.seq, f30(52), {place(fx.v1, fx.av30, 900, 905)});
        const EditResult r = applyReversible(fx.project, insert);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{fx.t});
    }
    SUBCASE("insert at the cut separates the clips") {
        InsertClip insert(fx.seq, f30(60), {place(fx.v1, fx.av30, 900, 905)});
        const EditResult r = applyReversible(fx.project, insert);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{fx.t});
    }
    SUBCASE("insert elsewhere keeps it") {
        InsertClip insert(fx.seq, f30(0), {place(fx.v1, fx.av30, 900, 905)});
        const EditResult r = applyReversible(fx.project, insert);
        CHECK(r.droppedTransitionIds.empty());
        const auto placed = findTransition(fx.sequence(), fx.t);
        REQUIRE(placed.has_value());
        CHECK(placed->range.start == f30(55));
        CHECK(placed->range.end == f30(75));
    }
    SUBCASE("a trim that leaves too little clip for it") {
        TrimClipHead trim(fx.seq, fx.b, f30(65));
        const EditResult r = applyReversible(fx.project, trim);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{fx.t});
    }
    SUBCASE("deleting the incoming clip") {
        RemoveClips remove(fx.seq, {fx.b});
        const EditResult r = applyReversible(fx.project, remove);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{fx.t});
    }
    SUBCASE("deleting the outgoing clip (its owner)") {
        RemoveClips remove(fx.seq, {fx.a});
        const EditResult r = applyReversible(fx.project, remove);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{fx.t});
    }
    SUBCASE("removing it on purpose is not a side effect") {
        RemoveSpans remove(fx.seq, {fx.t});
        const EditResult r = applyReversible(fx.project, remove);
        CHECK(r.droppedTransitionIds.empty());
        CHECK(remove.name() == "Remove Transition");
    }
    SUBCASE("removing its track is not a side effect either") {
        RemoveTrack track(fx.seq, fx.v1);
        CHECK(applyReversible(fx.project, track).droppedTransitionIds.empty());
    }
}

TEST_CASE("Fades always fit the clip after edits that shorten it") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.a1, fx.audioOnly, 0, 300);
    fx.sequence().findClip(c)->audio.gainDb = -2;
    const SpanId in = fx.addFade(c, ClipEdge::Head, f30(90));
    const SpanId out = fx.addFade(c, ClipEdge::Tail, f30(60));
    fx.requireValid();
    SUBCASE("a split inside a fade is refused; between the fades each piece keeps its outer fade") {
        SplitClip inside(fx.seq, c, f30(30));
        applyRefused(fx.project, inside, EditError::InsideTransition);
        SplitClip between(fx.seq, c, f30(150));
        applyReversible(fx.project, between);
        const ClipId right = between.createdClipIds()[0];
        CHECK(fadeIn(fx, c) == f30(90));
        CHECK(fadeOut(fx, c) == kCMTimeZero);
        CHECK(fadeIn(fx, right) == kCMTimeZero);
        CHECK(fadeOut(fx, right) == f30(60));
        CHECK(fx.clip(c).findSpan(in) != nullptr);
        CHECK(fx.clip(right).findSpan(out) != nullptr);
    }
    SUBCASE("an insert inside a fade splits the clip: the piece's fade is shortened to fit it") {
        InsertClip insert(fx.seq, f30(30), {place(fx.a1, fx.audioOnly, 600, 630)});
        applyReversible(fx.project, insert);
        CHECK(fadeIn(fx, c) == f30(30));
    }
    SUBCASE("trim tail: the fade-out gives way first") {
        TrimClipTail trim(fx.seq, c, f30(120));
        applyReversible(fx.project, trim);
        CHECK(fadeIn(fx, c) == f30(90));
        CHECK(fadeOut(fx, c) == f30(30));
    }
    SUBCASE("trim head: the fade-in gives way first") {
        TrimClipHead trim(fx.seq, c, f30(200));
        applyReversible(fx.project, trim);
        CHECK(fadeIn(fx, c) == f30(40));
        CHECK(fadeOut(fx, c) == f30(60));
    }
    SUBCASE("a trim to nothing but one frame removes the fade that no longer fits, and reports it") {
        TrimClipTail trim(fx.seq, c, f30(90));
        const EditResult r = applyReversible(fx.project, trim);
        CHECK(fadeIn(fx, c) == f30(90));
        CHECK(fadeOut(fx, c) == kCMTimeZero);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{out});
    }
    SUBCASE("overwrite over the tail") {
        OverwriteClip overwrite(fx.seq, f30(100), {place(fx.a1, fx.audioOnly, 0, 400)});
        applyReversible(fx.project, overwrite);
        CHECK(fadeIn(fx, c) == f30(90));
        CHECK(fadeOut(fx, c) == f30(10));
    }
    SUBCASE("speed up") {
        SetClipSpeed speed(fx.seq, c, 3.0);
        applyReversible(fx.project, speed);
        CHECK(fx.clip(c).duration() == f30(100));
        CHECK(fadeIn(fx, c) == f30(90));
        CHECK(fadeOut(fx, c) == f30(10));
    }
    SUBCASE("SetClipsParams sets both fades in one step and refuses fades that overlap") {
        auto change = [&](CMTime fadeInLength, CMTime fadeOutLength) {
            ClipParamsChange fades;
            fades.clipId = c;
            fades.fadeIn = fadeInLength;
            fades.fadeOut = fadeOutLength;
            return std::vector<ClipParamsChange>{fades};
        };
        SetClipsParams overlap(fx.seq, change(f30(200), f30(101)));
        applyRefused(fx.project, overlap, EditError::InvalidTime);
        SetClipsParams meet(fx.seq, change(f30(200), f30(100)));
        applyReversible(fx.project, meet);
        CHECK(fadeIn(fx, c) == f30(200));
        CHECK(fadeOut(fx, c) == f30(100));
        // The spans keep their ids: the fades were changed, not replaced.
        CHECK(fx.clip(c).findSpan(in) != nullptr);
        CHECK(fx.clip(c).findSpan(out) != nullptr);
        SetClipsParams swap(fx.seq, change(f30(100), f30(200)));
        applyReversible(fx.project, swap);
        CHECK(fadeIn(fx, c) == f30(100));
        CHECK(fadeOut(fx, c) == f30(200));
        CMTime rounded = f30(10);
        rounded.flags |= kCMTimeFlags_HasBeenRounded;
        SetClipsParams inexact(fx.seq, change(rounded, kCMTimeZero));
        applyRefused(fx.project, inexact, EditError::InvalidTime);
        SetClipsParams removeBoth(fx.seq, change(kCMTimeZero, kCMTimeZero));
        applyReversible(fx.project, removeBoth);
        CHECK(fx.clip(c).spans.empty());
    }
}
