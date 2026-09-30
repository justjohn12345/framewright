// TransitionFitting.h: the transition limits, offsets and messages the facade's transition calls use
// (moved out of VEEngine.mm; the facade tests cover them end to end through VEEngine).

#include "../../Engine/Edit/TransitionFitting.h"

#include "EditTestSupport.h"

#include <cstdio>

using namespace vetest;

namespace {

// V1: A [0,60) and B [60,120) of av30 (60 s of media); B starts `bSourceIn` frames into its media,
// so a cross dissolve out of A can reach at most that many frames before the cut.
struct CutFixture : Fixture {
    ClipId a, b;
    explicit CutFixture(std::int64_t bSourceIn = 300) {
        a = addClip(v1, av30, 0, 60, 30);
        b = addClip(v1, av30, 60, 60, bSourceIn);
    }
    TransitionPlacement placed(SpanId id) const {
        const auto transition = findTransition(sequence(), id);
        REQUIRE(transition.has_value());
        return *transition;
    }
};

std::pair<std::int64_t, std::int64_t> offsetFrames(const std::pair<CMTime, CMTime> &offsets) {
    return {frameIndexAt(offsets.first, f30(1), SnapMode::Round), frameIndexAt(offsets.second, f30(1), SnapMode::Round)};
}

TimeRange frames(std::int64_t start, std::int64_t end) {
    return TimeRange{f30(start), f30(end)};
}

} // namespace

TEST_CASE("describeFrames writes the frame count and the seconds as %.2f does") {
    CHECK(describeFrames(12, f30(1)) == "12 frames (0.40 s)");
    CHECK(describeFrames(1, f30(1)) == "1 frame (0.03 s)");
    CHECK(describeFrames(0, f30(1)) == "0 frames (0.00 s)");
    CHECK(describeFrames(30, CMTimeMake(1001, 30000)) == "30 frames (1.00 s)");
    CHECK(describeFrames(1, CMTimeMake(1, 8)) == "1 frame (0.12 s)"); // an exact tie rounds to even, as printf does
    char expected[64];
    for (const CMTime fd : {f30(1), CMTimeMake(1001, 24000), CMTimeMake(1001, 60000), CMTimeMake(1, 25)}) {
        for (std::int64_t n = 0; n <= 900; ++n) {
            std::snprintf(expected, sizeof expected, "%.2f", static_cast<double>(n) * CMTimeGetSeconds(fd));
            const std::string text = describeFrames(n, fd);
            REQUIRE(text.find(std::string("(") + expected + " s)") != std::string::npos);
        }
    }
}

TEST_CASE("isLengthLimit and refusalError classify transition limits") {
    for (const EditError error : {EditError::InsufficientHandles, EditError::InvalidArgument, EditError::Overlap}) {
        CHECK(isLengthLimit(error));
    }
    for (const EditError error : {EditError::None, EditError::ClipNotFound, EditError::NotAdjacent,
                                  EditError::AlreadyExists, EditError::TrackLocked, EditError::SequenceNotFound}) {
        CHECK_FALSE(isLengthLimit(error));
    }
    TransitionLimit limit;
    CHECK(refusalError(limit) == EditError::InvalidArgument);
    limit.limitError = EditError::Overlap;
    CHECK(refusalError(limit) == EditError::Overlap);
    limit.limitError = EditError::TrackLocked;
    CHECK(refusalError(limit) == EditError::TrackLocked);
}

TEST_CASE("transitionRefusal explains the limit of the cut") {
    TransitionLimit limit;
    limit.reason = "“a.mov” has no more media after its out point.";
    limit.limitError = EditError::InsufficientHandles;
    CHECK(transitionRefusal(limit, 20, f30(1)) == "No transition fits this cut: “a.mov” has no more media after its out point.");
    limit.limitError = EditError::AlreadyExists;
    limit.reason = "The cut already has a transition.";
    CHECK(transitionRefusal(limit, 20, f30(1)) == "The cut already has a transition.");
    limit.limitError = EditError::Overlap;
    limit.reason = "It would meet the next transition.";
    limit.maximumFrames = 10;
    CHECK(transitionRefusal(limit, 20, f30(1)) ==
          "A transition of 20 frames (0.67 s) does not fit this cut: It would meet the next transition. The longest "
          "it allows is 10 frames (0.33 s).");
}

TEST_CASE("transition kinds and fade targets follow the track kind") {
    CHECK(transitionKindOnTrack(TrackKind::Video, TransitionKind::WipeLeft) == TransitionKind::WipeLeft);
    CHECK(transitionKindOnTrack(TrackKind::Video, TransitionKind::Iris) == TransitionKind::Iris);
    for (const TransitionKind kind : kTransitionKinds) {
        CHECK(transitionKindOnTrack(TrackKind::Audio, kind) == TransitionKind::CrossDissolve);
    }
    CHECK(std::string(fadeTargetName(TrackKind::Video)) == "black");
    CHECK(std::string(fadeTargetName(TrackKind::Audio)) == "silence");
}

TEST_CASE("fadeLimit: the clip's length less its other fade and an incoming cross dissolve") {
    CutFixture fx;
    const Clip *a = &fx.clip(fx.a);
    TransitionLimit limit = fadeLimit(*a, fx.track(fx.v1), ClipEdge::Head, f30(1));
    CHECK(limit.maximumFrames == 60);
    CHECK(limit.maximum == f30(60));
    CHECK(limit.limitError == EditError::InvalidArgument);
    CHECK(limit.reason == "A fade cannot be longer than its clip.");

    // A fade in of 15 frames leaves 45 for a fade out, and the other way round.
    const SpanId fadeIn = fx.addFade(fx.a, ClipEdge::Head, f30(15));
    a = &fx.clip(fx.a);
    limit = fadeLimit(*a, fx.track(fx.v1), ClipEdge::Tail, f30(1));
    CHECK(limit.maximumFrames == 45);
    CHECK(limit.limitError == EditError::Overlap);
    CHECK(limit.reason == "It would overlap the transition at the clip's other end.");
    // The fade being resized does not count against itself.
    CHECK(fadeLimit(*a, fx.track(fx.v1), ClipEdge::Head, f30(1), fadeIn).maximumFrames == 60);
    CHECK(fadeLimit(*a, fx.track(fx.v1), ClipEdge::Head, f30(1)).maximumFrames == 60); // a fade in counts only for a fade out

    // A 20-frame dissolve out of A reaches 10 frames into B: B's fade out may use the other 50.
    fx.addTransition(fx.v1, fx.a, fx.b, 20);
    limit = fadeLimit(fx.clip(fx.b), fx.track(fx.v1), ClipEdge::Tail, f30(1));
    CHECK(limit.maximumFrames == 50);
    CHECK(limit.limitError == EditError::Overlap);
    CHECK(limit.reason == "It would meet the cross dissolve coming into the clip.");
    // A's tail dissolve takes 10 frames of A: a fade in could only use the other 50.
    CHECK(fadeLimit(fx.clip(fx.a), fx.track(fx.v1), ClipEdge::Head, f30(1)).maximumFrames == 50);
}

TEST_CASE("fadeLimit on an audio track names the crossfade, and no room is zero") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.a1, fx.audioOnly, 0, 60, 30);
    const ClipId b = fx.addClip(fx.a1, fx.audioOnly, 60, 30, 300);
    fx.addTransition(fx.a1, a, b, 20);
    TransitionLimit limit = fadeLimit(fx.clip(b), fx.track(fx.a1), ClipEdge::Tail, f30(1));
    CHECK(limit.maximumFrames == 20);
    CHECK(limit.reason == "It would meet the crossfade coming into the clip.");
    fx.addFade(b, ClipEdge::Head, f30(30)); // (an invalid model, but the limit only subtracts)
    limit = fadeLimit(fx.clip(b), fx.track(fx.a1), ClipEdge::Tail, f30(1));
    CHECK(limit.maximumFrames == 0);
    CHECK(limit.maximum == kCMTimeZero);
}

TEST_CASE("resizedTransitionOffsets keeps a fade's edge and a dissolve's share before the cut") {
    CutFixture fx;
    const SpanId dissolve = fx.addTailTransition(fx.a, 10, 10);
    CHECK(offsetFrames(resizedTransitionOffsets(fx.placed(dissolve), 15, f30(1))) == span(-7, 8));
    CHECK(offsetFrames(resizedTransitionOffsets(fx.placed(dissolve), 16, f30(1))) == span(-8, 8));

    CutFixture uneven;
    const SpanId share = uneven.addTailTransition(uneven.a, 15, 5); // 3/4 before the cut
    CHECK(offsetFrames(resizedTransitionOffsets(uneven.placed(share), 10, f30(1))) == span(-7, 3));
    CHECK(offsetFrames(resizedTransitionOffsets(uneven.placed(share), 40, f30(1))) == span(-30, 10));

    Fixture fades;
    const ClipId c = fades.addClip(fades.v1, fades.av30, 0, 60);
    const SpanId in = fades.addFade(c, ClipEdge::Head, f30(10));
    const SpanId out = fades.addFade(c, ClipEdge::Tail, f30(10));
    CHECK(offsetFrames(resizedTransitionOffsets(*findTransition(fades.sequence(), in), 25, f30(1))) == span(0, 25));
    CHECK(offsetFrames(resizedTransitionOffsets(*findTransition(fades.sequence(), out), 25, f30(1))) == span(-25, 0));
}

TEST_CASE("transitionDurationLimit of a cross dissolve matches the cut's centred limit") {
    CutFixture fx(5); // B has 5 frames of media before its in point
    const SpanId dissolve = fx.addTailTransition(fx.a, 2, 2);
    const TransitionLimit limit = transitionDurationLimit(fx.project, fx.sequence(), fx.placed(dissolve));
    CHECK(limit.maximumFrames == 11); // 5 before the cut, 6 after
    CHECK(limit.maximum == f30(11));
    CHECK(limit.limitError == EditError::InsufficientHandles);
    CHECK(limit.limitingClip == fx.b);
    const TransitionLimit centred = transitionLimit(fx.project, fx.seq, fx.a, fx.b, dissolve);
    CHECK(centred.maximumFrames == limit.maximumFrames);
    CHECK(centred.reason == limit.reason);

    // An uneven dissolve keeps its share: 1 of 4 frames before the cut limits it to 20 (5 before).
    CutFixture uneven(5);
    const SpanId share = uneven.addTailTransition(uneven.a, 1, 3);
    const TransitionLimit shared = transitionDurationLimit(uneven.project, uneven.sequence(), uneven.placed(share));
    CHECK(shared.maximumFrames == 23); // 23 * 1/4 = 5 frames before, rounded down; 24 would take 6
    CHECK(shared.limitError == EditError::InsufficientHandles);
    CHECK(offsetFrames(resizedTransitionOffsets(uneven.placed(share), 23, f30(1))) == span(-5, 18));
}

TEST_CASE("transitionDurationLimit of a fade and of a cut that refuses transitions") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 60);
    fx.addFade(c, ClipEdge::Head, f30(20));
    const SpanId out = fx.addFade(c, ClipEdge::Tail, f30(10));
    const TransitionLimit fade = transitionDurationLimit(fx.project, fx.sequence(), *findTransition(fx.sequence(), out));
    CHECK(fade.maximumFrames == 40); // its own 10 frames do not count
    CHECK(fade.limitError == EditError::Overlap);
    CHECK(fade.reason == "It would overlap the transition at the clip's other end.");

    CutFixture locked;
    const SpanId dissolve = locked.addTailTransition(locked.a, 5, 5);
    const TransitionPlacement placed = locked.placed(dissolve);
    lockTrack(locked, locked.v1);
    const TransitionLimit none = transitionDurationLimit(locked.project, locked.sequence(), placed);
    CHECK(none.maximumFrames == 0);
    CHECK(none.maximum == kCMTimeZero);
    CHECK(none.limitError == EditError::TrackLocked);
    CHECK_FALSE(none.reason.empty());
}

TEST_CASE("fitTransitionRange fits a fade in to its clip") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 60);
    const SpanId in = fx.addFade(c, ClipEdge::Head, f30(10));
    const TransitionPlacement placed = *findTransition(fx.sequence(), in);
    TransitionRangeFit fit = fitTransitionRange(fx.project, fx.sequence(), placed, frames(0, 90), false);
    REQUIRE(fit.offsets);
    CHECK(offsetFrames(*fit.offsets) == span(0, 60));
    REQUIRE(fit.notes.size() == 1);
    CHECK(fit.notes[0] == "The transition was shortened to 60 frames (2.00 s): A fade cannot be longer than its clip.");

    fit = fitTransitionRange(fx.project, fx.sequence(), placed, frames(0, 20), true);
    REQUIRE(fit.offsets);
    CHECK(offsetFrames(*fit.offsets) == span(0, 20));
    CHECK(fit.notes.empty());

    fit = fitTransitionRange(fx.project, fx.sequence(), placed, frames(5, 20), false);
    CHECK_FALSE(fit.offsets);
    CHECK(fit.refusal.error == EditError::InvalidTime);
    CHECK(fit.refusal.message == "A fade in starts at its clip's start.");

    // No room at all: the fade out takes the whole clip.
    Fixture full;
    const ClipId d = full.addClip(full.v1, full.av30, 0, 60);
    const SpanId fullIn = full.addFade(d, ClipEdge::Head, f30(10));
    full.addFade(d, ClipEdge::Tail, f30(60));
    fit = fitTransitionRange(full.project, full.sequence(), *findTransition(full.sequence(), fullIn), frames(0, 10), true);
    CHECK_FALSE(fit.offsets);
    CHECK(fit.refusal.error == EditError::Overlap);
    CHECK(fit.refusal.message == "It would overlap the transition at the clip's other end.");
    REQUIRE(fit.notes.size() == 1);
    CHECK(fit.notes[0] ==
          "The linked transition was shortened to 0 frames (0.00 s): It would overlap the transition at the clip's "
          "other end.");
}

TEST_CASE("fitTransitionRange fits a tail transition to both sides of its cut") {
    CutFixture fx(5);
    const SpanId dissolve = fx.addTailTransition(fx.a, 2, 2);
    const TransitionPlacement placed = fx.placed(dissolve);

    TransitionRangeFit fit = fitTransitionRange(fx.project, fx.sequence(), placed, frames(40, 80), false);
    REQUIRE(fit.offsets);
    CHECK(offsetFrames(*fit.offsets) == span(-5, 20));
    REQUIRE(fit.notes.size() == 1);
    CHECK(fit.notes[0].rfind("The transition was shortened before the cut to 5 frames (0.17 s): ", 0) == 0);

    // Ending on the cut: the dissolve becomes a fade out to black.
    fit = fitTransitionRange(fx.project, fx.sequence(), placed, frames(55, 60), true);
    REQUIRE(fit.offsets);
    CHECK(offsetFrames(*fit.offsets) == span(-5, 0));
    REQUIRE(fit.notes.size() == 1);
    CHECK(fit.notes[0] == "The linked transition no longer reaches past the cut, so it now fades out to black.");

    fit = fitTransitionRange(fx.project, fx.sequence(), placed, frames(61, 70), false);
    CHECK_FALSE(fit.offsets);
    CHECK(fit.refusal.error == EditError::InvalidTime);
    CHECK(fit.refusal.message == "A transition at a clip's end starts inside the clip.");

    fit = fitTransitionRange(fx.project, fx.sequence(), placed, frames(60, 60), false);
    CHECK_FALSE(fit.offsets);
    CHECK(fit.refusal.error == EditError::InvalidArgument);
    CHECK(fit.refusal.message == "The transition would cover no frame.");

    lockTrack(fx, fx.v1);
    fit = fitTransitionRange(fx.project, fx.sequence(), placed, frames(55, 65), false);
    CHECK_FALSE(fit.offsets);
    CHECK(fit.refusal.error == EditError::TrackLocked);
}

TEST_CASE("fitTransitionRange turns fades into dissolves and back as the range crosses the cut") {
    CutFixture fx;
    const SpanId out = fx.addFade(fx.a, ClipEdge::Tail, f30(10));
    TransitionRangeFit fit = fitTransitionRange(fx.project, fx.sequence(), fx.placed(out), frames(50, 65), false);
    REQUIRE(fit.offsets);
    CHECK(offsetFrames(*fit.offsets) == span(-10, 5));
    REQUIRE(fit.notes.size() == 1);
    CHECK(fit.notes[0] == "The transition now crosses the cut: a cross dissolve into the next clip.");

    // Nothing after the clip: the part past the cut is dropped.
    Fixture alone;
    const ClipId c = alone.addClip(alone.a1, alone.audioOnly, 0, 60);
    const SpanId fade = alone.addFade(c, ClipEdge::Tail, f30(10));
    fit = fitTransitionRange(alone.project, alone.sequence(), *findTransition(alone.sequence(), fade), frames(40, 70),
                             false);
    REQUIRE(fit.offsets);
    CHECK(offsetFrames(*fit.offsets) == span(-20, 0));
    REQUIRE(fit.notes.size() == 1);
    CHECK(fit.notes[0] == "The transition fades out to silence: nothing follows the clip.");
}

TEST_CASE("planFade fits a fade to its clip or explains why it cannot") {
    CutFixture fx;
    // At A's start: nothing touches it, so a fade in fits (a wipe on video).
    FadePlan plan = planFade(fx.clip(fx.a), fx.track(fx.v1), ClipEdge::Head, 20, f30(1), false,
                             TransitionKind::WipeLeft, false);
    REQUIRE(plan.request);
    CHECK(plan.request->clipId == fx.a);
    CHECK(plan.request->edge == ClipEdge::Head);
    CHECK(plan.request->kind == TransitionKind::WipeLeft);
    CHECK(offsetFrames({plan.request->start, plan.request->end}) == span(0, 20));
    CHECK_FALSE(plan.note);

    // At B's start A touches it: the cut is A's.
    plan = planFade(fx.clip(fx.b), fx.track(fx.v1), ClipEdge::Head, 20, f30(1), true, TransitionKind::CrossDissolve,
                    false);
    CHECK_FALSE(plan.request);
    CHECK(plan.refusal == "Another clip touches the clip's start, so the cut belongs to that clip: add a transition at "
                          "its end instead.");

    // Longer than B: refused, or fitted with a note.
    plan = planFade(fx.clip(fx.b), fx.track(fx.v1), ClipEdge::Tail, 90, f30(1), false, TransitionKind::CrossDissolve,
                    false);
    CHECK_FALSE(plan.request);
    CHECK(plan.refusal == "A fade of 90 frames (3.00 s) does not fit: A fade cannot be longer than its clip. The "
                          "longest it allows is 60 frames (2.00 s).");
    plan = planFade(fx.clip(fx.b), fx.track(fx.v1), ClipEdge::Tail, 90, f30(1), true, TransitionKind::CrossDissolve,
                    true);
    REQUIRE(plan.request);
    CHECK(offsetFrames({plan.request->start, plan.request->end}) == span(-60, 0));
    REQUIRE(plan.note);
    CHECK(*plan.note == "The linked clip's fade was shortened to 60 frames (2.00 s): A fade cannot be longer than its clip.");
    plan = planFade(fx.clip(fx.b), fx.track(fx.v1), ClipEdge::Tail, 90, f30(1), true, TransitionKind::CrossDissolve,
                    false);
    REQUIRE(plan.note);
    // (sic: the facade has always written the clip's own note this way; kept by the refactor)
    CHECK(*plan.note == "Shortened to shortened to 60 frames (2.00 s): A fade cannot be longer than its clip.");

    // An existing transition at that edge; and an audio fade is never a wipe.
    fx.addFade(fx.b, ClipEdge::Tail, f30(5));
    plan = planFade(fx.clip(fx.b), fx.track(fx.v1), ClipEdge::Tail, 10, f30(1), true, TransitionKind::Iris, false);
    CHECK_FALSE(plan.request);
    CHECK(plan.refusal == "The clip already has a transition at its end.");
    const ClipId sound = fx.addClip(fx.a1, fx.audioOnly, 0, 60);
    plan = planFade(fx.clip(sound), fx.track(fx.a1), ClipEdge::Tail, 10, f30(1), false, TransitionKind::Iris, false);
    REQUIRE(plan.request);
    CHECK(plan.request->kind == TransitionKind::CrossDissolve);
}

TEST_CASE("planFade refuses a fade no frame of which fits, even when fitting") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 60);
    fx.addFade(c, ClipEdge::Head, f30(60));
    const FadePlan plan = planFade(fx.clip(c), fx.track(fx.v1), ClipEdge::Tail, 10, f30(1), true,
                                   TransitionKind::CrossDissolve, false);
    CHECK_FALSE(plan.request);
    CHECK(plan.refusal == "A fade of 10 frames (0.33 s) does not fit: It would overlap the transition at the clip's "
                          "other end. The longest it allows is 0 frames (0.00 s).");
}
