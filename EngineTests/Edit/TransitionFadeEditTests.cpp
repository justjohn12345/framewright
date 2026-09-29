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
        applyRefused(fx.project, overlap, EditError::Overlap);
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

TEST_CASE("A fade out never removes the crossfade coming into its clip (review M3)") {
    // A1: A [0,60), B [60,150) (90 frames), a 30-frame crossfade A -> B: 15 frames inside B.
    Fixture fx;
    const ClipId a = fx.addClip(fx.a1, fx.audioOnly, 0, 60, 0);
    const ClipId b = fx.addClip(fx.a1, fx.audioOnly, 60, 90, 300);
    const SpanId crossfade = fx.addTransition(fx.a1, a, b, 30);
    fx.requireValid();
    REQUIRE(fx.span(crossfade)->end == f30(15));
    auto fadeOutOf = [&](ClipId clip, CMTime length) {
        ClipParamsChange change;
        change.clipId = clip;
        change.fadeOut = length;
        return std::vector<ClipParamsChange>{change};
    };
    SUBCASE("an 80-frame fade out is refused with its room; 75 frames fit beside the crossfade") {
        SetClipsParams tooLong(fx.seq, fadeOutOf(b, f30(80)));
        const EditResult r = applyRefused(fx.project, tooLong, EditError::Overlap);
        CHECK(r.message.find("crossfade coming into clip") != std::string::npos);
        CHECK(r.message.find("75/30") != std::string::npos);
        CHECK(fx.span(crossfade) != nullptr);
        SetClipsParams fits(fx.seq, fadeOutOf(b, f30(75)));
        const EditResult ok = applyReversible(fx.project, fits);
        CHECK(ok.droppedTransitionIds.empty());
        CHECK(fadeOut(fx, b) == f30(75));
        CHECK(fx.span(crossfade) != nullptr);
    }
    SUBCASE("a tail trim shortens the fade out to leave the crossfade its frames") {
        SetClipsParams fade(fx.seq, fadeOutOf(b, f30(70)));
        applyReversible(fx.project, fade);
        TrimClipTail trim(fx.seq, b, f30(140)); // B is 80 frames now
        const EditResult r = applyReversible(fx.project, trim);
        CHECK(r.droppedTransitionIds.empty());
        CHECK(fx.span(crossfade) != nullptr);
        CHECK(fadeOut(fx, b) == f30(65));
    }
    SUBCASE("a trim leaving no room removes the fade out (reported), never the crossfade") {
        SetClipsParams fade(fx.seq, fadeOutOf(b, f30(70)));
        applyReversible(fx.project, fade);
        const SpanId out = fx.clip(b).transitionAt(ClipEdge::Tail)->id;
        TrimClipTail trim(fx.seq, b, f30(75)); // B is 15 frames: all under the crossfade
        const EditResult r = applyReversible(fx.project, trim);
        CHECK(fx.span(crossfade) != nullptr);
        CHECK(fadeOut(fx, b) == kCMTimeZero);
        CHECK(r.droppedTransitionIds == std::vector<SpanId>{out});
    }
}

TEST_CASE("SetTransitionKind changes a video transition's kind, undoably, and nothing else") {
    DissolveFixture fx;
    const auto [lv, la] = fx.addLinkedPair(200, 60);
    const auto [rv, ra] = fx.addLinkedPair(260, 60, 300);
    const SpanId videoCut = fx.addTransition(fx.v1, lv, rv, 10);
    const SpanId audioCut = fx.addTransition(fx.a1, la, ra, 10);
    const SpanId fade = fx.addFade(fx.b, ClipEdge::Tail, f30(15));
    fx.requireValid();
    REQUIRE(linkedTransition(fx.sequence(), videoCut) == audioCut);
    for (const TransitionKind kind : kTransitionKinds) {
        CAPTURE(nameOf(kind));
        for (const SpanId id : {fx.t, videoCut, fade}) {
            const EffectSpan before = *fx.span(id);
            const EffectSpan audioBefore = *fx.span(audioCut);
            const TransitionRole roleBefore = findTransition(fx.sequence(), id)->role;
            SetTransitionKind edit(fx.seq, id, kind);
            applyReversible(fx.project, edit);
            const EffectSpan &after = *fx.span(id);
            CHECK(after.transition == kind);
            CHECK(identical(after.start, before.start));
            CHECK(identical(after.end, before.end));
            CHECK(after.edge == before.edge);
            CHECK(*fx.span(audioCut) == audioBefore); // the crossfade has no kind
            CHECK(findTransition(fx.sequence(), id)->role == roleBefore);
        }
    }
    CHECK(fx.span(fx.t)->transition == TransitionKind::Iris);
    CHECK(findTransition(fx.sequence(), fade)->role == TransitionRole::FadeOut);
}

TEST_CASE("SetTransitionKind refuses what is not a video transition") {
    DissolveFixture fx;
    const auto [lv, la] = fx.addLinkedPair(200, 60);
    const auto [rv, ra] = fx.addLinkedPair(260, 60, 300);
    const SpanId audioCut = fx.addTransition(fx.a1, la, ra, 10);
    const SpanId motion = fx.addSpan(fx.a, SpanKind::Motion, 1, f30(30), f30(60));
    fx.requireValid();
    (void)lv;
    (void)rv;
    SUBCASE("an effect span") {
        SetTransitionKind edit(fx.seq, motion, TransitionKind::WipeLeft);
        const EditResult r = applyRefused(fx.project, edit, EditError::TransitionNotFound);
        CHECK(r.message.find(std::to_string(motion.value())) != std::string::npos);
    }
    SUBCASE("an unknown id") {
        SetTransitionKind edit(fx.seq, SpanId{9999}, TransitionKind::WipeLeft);
        applyRefused(fx.project, edit, EditError::TransitionNotFound);
    }
    SUBCASE("an audio crossfade") {
        SetTransitionKind edit(fx.seq, audioCut, TransitionKind::Iris);
        const EditResult r = applyRefused(fx.project, edit, EditError::TrackKindMismatch);
        CHECK(r.message.find("Iris") != std::string::npos);
    }
    SUBCASE("a locked track") {
        fx.track(fx.v1).locked = true;
        SetTransitionKind edit(fx.seq, fx.t, TransitionKind::WipeDown);
        applyRefused(fx.project, edit, EditError::TrackLocked);
    }
    SUBCASE("adding a shaped audio transition is refused too") {
        TransitionSpanRequest request;
        request.clipId = ra;
        request.edge = ClipEdge::Tail;
        request.start = -f30(10);
        request.end = kCMTimeZero;
        request.kind = TransitionKind::WipeLeft;
        AddTransitionSpans add(fx.seq, {request});
        const EditResult r = add.apply(fx.project);
        CHECK_FALSE(r.ok());
        CHECK(r.message.find("not a Wipe Left") != std::string::npos); // the display name (review L9)
        CHECK(r.message.find("wipeLeft") == std::string::npos);
    }
}

TEST_CASE("Refusal wording and codes (review L9)") {
    SUBCASE("Cross Dissolve asked of an audio crossfade: nothing to do, not a refusal") {
        DissolveFixture fx;
        const auto [lv, la] = fx.addLinkedPair(200, 60);
        const auto [rv, ra] = fx.addLinkedPair(260, 60, 300);
        const SpanId audioCut = fx.addTransition(fx.a1, la, ra, 10);
        fx.requireValid();
        (void)lv;
        (void)rv;
        const Project before = fx.project;
        SetTransitionKind edit(fx.seq, audioCut, TransitionKind::CrossDissolve);
        const EditResult r = edit.apply(fx.project);
        CHECK_MESSAGE(r.ok(), doctest::String(r.message.c_str()));
        CHECK(fx.project == before);
        // A shape is still refused, by its display name.
        SetTransitionKind wipe(fx.seq, audioCut, TransitionKind::WipeRight);
        const EditResult refused = applyRefused(fx.project, wipe, EditError::TrackKindMismatch);
        CHECK(refused.message.find("Wipe Right") != std::string::npos);
    }
    SUBCASE("a fade out meeting the dissolve coming into its clip: Overlap, as the facade's limit says") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.a1, fx.audioOnly, 0, 60, 0);
        const ClipId b = fx.addClip(fx.a1, fx.audioOnly, 60, 90, 300);
        fx.addTransition(fx.a1, a, b, 30); // 15 frames inside B
        fx.requireValid();
        ClipParamsChange change;
        change.clipId = b;
        change.fadeOut = f30(80);
        SetClipsParams tooLong(fx.seq, {change});
        applyRefused(fx.project, tooLong, EditError::Overlap);
    }
    SUBCASE("a fade out meeting the fade in: Overlap; one longer than the clip: InvalidTime") {
        Fixture fx;
        const ClipId c = fx.addClip(fx.a1, fx.audioOnly, 0, 100);
        fx.addFade(c, ClipEdge::Head, f30(30));
        fx.requireValid();
        ClipParamsChange meets;
        meets.clipId = c;
        meets.fadeOut = f30(71);
        SetClipsParams overlap(fx.seq, {meets});
        applyRefused(fx.project, overlap, EditError::Overlap);
        ClipParamsChange longer;
        longer.clipId = c;
        longer.fadeOut = f30(101);
        SetClipsParams tooLong(fx.seq, {longer});
        applyRefused(fx.project, tooLong, EditError::InvalidTime);
    }
}
