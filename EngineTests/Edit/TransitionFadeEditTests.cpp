// Edits keep transitions and fades consistent (model review finding 7): a split inside a
// transition's range is refused unless explicitly allowed, transitions an edit breaks are
// reported in EditResult::droppedTransitionIds, and fades always fit their clip.

#include "EditTestSupport.h"

using namespace vetest;

namespace {

// V1: A [0,60) source 30.., B [60,120) source 300.., a 20-frame transition [50,70) on the cut.
struct DissolveFixture : Fixture {
    ClipId a, b;
    TransitionId t;
    DissolveFixture() {
        a = addClip(v1, av30, 0, 60, 30);
        b = addClip(v1, av30, 60, 60, 300);
        t = addTransition(v1, a, b, 20);
        requireValid();
    }
};

} // namespace

TEST_CASE("SplitClip inside a transition range is refused unless allowed") {
    DissolveFixture fx;
    for (const std::int64_t at : {51, 55, 59}) { // inside the tail half of A
        SplitClip split(fx.seq, fx.a, f30(at));
        const EditResult r = applyRefused(fx.project, split, EditError::InsideTransition);
        CHECK(r.message.find("transition") != std::string::npos);
    }
    for (const std::int64_t at : {61, 69}) { // inside the head half of B
        SplitClip split(fx.seq, fx.b, f30(at));
        applyRefused(fx.project, split, EditError::InsideTransition);
    }
    SUBCASE("at the range's edges the transition survives") {
        SplitClip left(fx.seq, fx.a, f30(50));
        applyReversible(fx.project, left);
        CHECK(fx.sequence().findTransition(fx.t) != nullptr);
        SplitClip right(fx.seq, fx.b, f30(70));
        const EditResult r = applyReversible(fx.project, right);
        CHECK(r.droppedTransitionIds.empty());
        CHECK(fx.sequence().findTransition(fx.t) != nullptr);
    }
    SUBCASE("allowed: the transition is dropped and reported") {
        SplitClip split(fx.seq, fx.a, f30(55), SplitOptions{true, true});
        const EditResult r = applyReversible(fx.project, split);
        CHECK(r.droppedTransitionIds == std::vector<TransitionId>{fx.t});
        CHECK(fx.sequence().transitions.empty());
        split.revert(fx.project);
        CHECK(fx.sequence().findTransition(fx.t) != nullptr);
    }
}

TEST_CASE("Edits that break a transition report it") {
    DissolveFixture fx;
    SUBCASE("overwrite inside the outgoing clip's tail") {
        OverwriteClip overwrite(fx.seq, f30(52), {place(fx.v1, fx.av30, 900, 905)});
        const EditResult r = applyReversible(fx.project, overwrite);
        CHECK(r.droppedTransitionIds == std::vector<TransitionId>{fx.t});
    }
    SUBCASE("insert inside the outgoing clip's tail") {
        InsertClip insert(fx.seq, f30(52), {place(fx.v1, fx.av30, 900, 905)});
        const EditResult r = applyReversible(fx.project, insert);
        CHECK(r.droppedTransitionIds == std::vector<TransitionId>{fx.t});
    }
    SUBCASE("insert at the cut separates the clips") {
        InsertClip insert(fx.seq, f30(60), {place(fx.v1, fx.av30, 900, 905)});
        const EditResult r = applyReversible(fx.project, insert);
        CHECK(r.droppedTransitionIds == std::vector<TransitionId>{fx.t});
    }
    SUBCASE("insert elsewhere keeps it") {
        InsertClip insert(fx.seq, f30(0), {place(fx.v1, fx.av30, 900, 905)});
        const EditResult r = applyReversible(fx.project, insert);
        CHECK(r.droppedTransitionIds.empty());
        REQUIRE(fx.sequence().findTransition(fx.t) != nullptr);
        CHECK(fx.sequence().transitionRange(*fx.sequence().findTransition(fx.t))->start == f30(55));
    }
    SUBCASE("a trim that leaves too little clip for it") {
        TrimClipHead trim(fx.seq, fx.b, f30(65));
        const EditResult r = applyReversible(fx.project, trim);
        CHECK(r.droppedTransitionIds == std::vector<TransitionId>{fx.t});
    }
    SUBCASE("deleting one of its clips") {
        RemoveClips remove(fx.seq, {fx.b});
        const EditResult r = applyReversible(fx.project, remove);
        CHECK(r.droppedTransitionIds == std::vector<TransitionId>{fx.t});
    }
    SUBCASE("removing it on purpose is not a side effect") {
        RemoveTransition remove(fx.seq, fx.t);
        CHECK(applyReversible(fx.project, remove).droppedTransitionIds.empty());
    }
    SUBCASE("removing its track is not a side effect either") {
        RemoveTrack track(fx.seq, fx.v1);
        CHECK(applyReversible(fx.project, track).droppedTransitionIds.empty());
    }
}

TEST_CASE("Fades always fit the clip after edits that shorten it") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.a1, fx.audioOnly, 0, 300);
    fx.sequence().findClip(c)->audio = AudioParams{-2, f30(90), f30(60)};
    fx.requireValid();
    SUBCASE("split: each piece keeps its outer fade, shortened to fit") {
        SplitClip split(fx.seq, c, f30(30));
        applyReversible(fx.project, split);
        const Clip &right = fx.clip(split.createdClipIds()[0]);
        CHECK(fx.clip(c).audio.fadeInDuration == f30(30));
        CHECK(fx.clip(c).audio.fadeOutDuration == kCMTimeZero);
        CHECK(right.audio.fadeInDuration == kCMTimeZero);
        CHECK(right.audio.fadeOutDuration == f30(60));
    }
    SUBCASE("trim tail: the fade-out gives way first") {
        TrimClipTail trim(fx.seq, c, f30(120));
        applyReversible(fx.project, trim);
        CHECK(fx.clip(c).audio.fadeInDuration == f30(90));
        CHECK(fx.clip(c).audio.fadeOutDuration == f30(30));
    }
    SUBCASE("trim head: the fade-in gives way first") {
        TrimClipHead trim(fx.seq, c, f30(200));
        applyReversible(fx.project, trim);
        CHECK(fx.clip(c).audio.fadeInDuration == f30(40));
        CHECK(fx.clip(c).audio.fadeOutDuration == f30(60));
    }
    SUBCASE("overwrite over the tail") {
        OverwriteClip overwrite(fx.seq, f30(100), {place(fx.a1, fx.audioOnly, 0, 400)});
        applyReversible(fx.project, overwrite);
        CHECK(fx.clip(c).audio.fadeInDuration == f30(90));
        CHECK(fx.clip(c).audio.fadeOutDuration == f30(10));
    }
    SUBCASE("speed up") {
        SetClipSpeed speed(fx.seq, c, 3.0);
        applyReversible(fx.project, speed);
        CHECK(fx.clip(c).duration() == f30(100));
        CHECK(fx.clip(c).audio.fadeInDuration == f30(90));
        CHECK(fx.clip(c).audio.fadeOutDuration == f30(10));
    }
    SUBCASE("SetAudioParams refuses fades that overlap") {
        SetAudioParams overlap(fx.seq, c, AudioParams{0, f30(200), f30(101)});
        applyRefused(fx.project, overlap, EditError::InvalidTime);
        SetAudioParams meet(fx.seq, c, AudioParams{0, f30(200), f30(100)});
        applyReversible(fx.project, meet);
        CMTime rounded = f30(10);
        rounded.flags |= kCMTimeFlags_HasBeenRounded;
        SetAudioParams inexact(fx.seq, c, AudioParams{0, rounded, kCMTimeZero});
        applyRefused(fx.project, inexact, EditError::InvalidTime);
    }
}
