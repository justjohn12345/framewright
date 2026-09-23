// Phase 6 edit ops: SetClipsParams (multi-clip parameter batches) and transitionLimit (the
// longest transition a cut can take, and why).

#include "EditTestSupport.h"

#include "../../Engine/Edit/UndoStack.h"

#include <memory>

using namespace vetest;

TEST_CASE("SetClipsParams changes several clips in one reversible edit") {
    Fixture fx;
    const auto [v1a, a1a] = fx.addLinkedPair(0, 30);
    const auto [v1b, a1b] = fx.addLinkedPair(30, 30, 60);
    fx.requireValid();

    VideoParams dim;
    dim.opacity = 0.5;
    VideoParams moved;
    moved.x = -12;
    AudioParams quiet;
    quiet.gainDb = -9;
    quiet.fadeInDuration = f30(5);
    SetClipsParams batch(fx.seq, {ClipParamsChange{v1a, dim, std::nullopt}, ClipParamsChange{v1b, moved, std::nullopt},
                                  ClipParamsChange{a1b, std::nullopt, quiet}});
    CHECK(batch.name() == "Change Clip Settings");
    applyReversible(fx.project, batch);
    CHECK(fx.clip(v1a).video.opacity == 0.5);
    CHECK(fx.clip(v1b).video.x == -12);
    CHECK(fx.clip(a1b).audio == quiet);
    CHECK(fx.clip(a1a).audio == AudioParams{});

    SetClipsParams videoOnly(fx.seq, {ClipParamsChange{v1a, moved, std::nullopt}});
    CHECK(videoOnly.name() == "Change Video Settings");
    SetClipsParams audioOnly(fx.seq, {ClipParamsChange{a1a, std::nullopt, quiet}});
    CHECK(audioOnly.name() == "Change Audio Settings");
}

TEST_CASE("SetClipsParams is refused as a whole") {
    Fixture fx;
    const auto [video, audio] = fx.addLinkedPair(0, 30);
    VideoParams params;
    params.scale = 2;
    SUBCASE("video parameters on an audio clip") {
        SetClipsParams batch(fx.seq, {ClipParamsChange{video, params, std::nullopt},
                                      ClipParamsChange{audio, params, std::nullopt}});
        applyRefused(fx.project, batch, EditError::TrackKindMismatch);
    }
    SUBCASE("audio parameters on a video clip") {
        SetClipsParams batch(fx.seq, {ClipParamsChange{video, std::nullopt, AudioParams{}}});
        applyRefused(fx.project, batch, EditError::TrackKindMismatch);
    }
    SUBCASE("fades longer than the clip") {
        AudioParams fades;
        fades.fadeInDuration = f30(20);
        fades.fadeOutDuration = f30(11);
        SetClipsParams batch(fx.seq, {ClipParamsChange{video, params, std::nullopt},
                                      ClipParamsChange{audio, std::nullopt, fades}});
        applyRefused(fx.project, batch, EditError::InvalidTime);
    }
    SUBCASE("a clip listed twice") {
        SetClipsParams batch(fx.seq, {ClipParamsChange{video, params, std::nullopt},
                                      ClipParamsChange{video, params, std::nullopt}});
        applyRefused(fx.project, batch, EditError::InvalidArgument);
    }
    SUBCASE("a locked track") {
        lockTrack(fx, fx.a1);
        SetClipsParams batch(fx.seq, {ClipParamsChange{video, params, std::nullopt},
                                      ClipParamsChange{audio, std::nullopt, AudioParams{}}});
        applyRefused(fx.project, batch, EditError::TrackLocked);
    }
    SUBCASE("empty") {
        SetClipsParams batch(fx.seq, {});
        applyRefused(fx.project, batch, EditError::InvalidArgument);
    }
}

TEST_CASE("SetClipsParams batches merge under Accumulate coalescing") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 30, 30, 60);
    UndoStack stack;
    stack.beginCoalescing("nudge", CoalesceMode::Accumulate);
    for (int i = 0; i < 10; ++i) {
        std::vector<ClipParamsChange> changes;
        for (ClipId id : {a, b}) {
            VideoParams p = fx.clip(id).video;
            p.rotationDegrees += 1;
            changes.push_back(ClipParamsChange{id, p, std::nullopt});
        }
        auto command = std::make_unique<SetClipsParams>(fx.seq, changes);
        command->setCoalescingKey("nudge");
        REQUIRE(stack.push(fx.project, std::move(command)).ok());
    }
    stack.endCoalescing();
    CHECK(stack.undoCount() == 1);
    CHECK(fx.clip(a).video.rotationDegrees == 10);
    REQUIRE(stack.undo(fx.project));
    CHECK(fx.clip(a).video.rotationDegrees == 0);
    CHECK(fx.clip(b).video.rotationDegrees == 0);
}

TEST_CASE("transitionLimit finds the longest transition a cut takes and why") {
    Fixture fx;
    // A: source [30, 90) at [0, 60); B: source [300, 360) at [60, 120).
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    fx.requireValid();

    SUBCASE("limited by the clips' lengths") {
        const TransitionLimit limit = transitionLimit(fx.project, fx.seq, a, b);
        // floor(n/2) <= 60 frames of A and ceil(n/2) <= 60 of B: 120 frames.
        CHECK(limit.maximumFrames == 120);
        CHECK(identical(limit.maximum, f30(120)));
        CHECK(limit.limitError == EditError::InvalidArgument);
        CHECK(limit.reason.find("longer than the clips") != std::string::npos);
        AddTransition fits(fx.seq, a, b, f30(120));
        applyReversible(fx.project, fits);
        AddTransition tooLong(fx.seq, a, b, f30(121));
        fits.revert(fx.project);
        applyRefused(fx.project, tooLong, EditError::InvalidArgument);
    }
    SUBCASE("limited by the incoming clip's media before its in point") {
        const ClipId c = fx.addClip(fx.v1, fx.av30, 120, 60, 7); // 7 frames of handle
        const TransitionLimit limit = transitionLimit(fx.project, fx.seq, b, c);
        CHECK(limit.maximumFrames == 15); // floor(15/2) = 7
        CHECK(limit.limitError == EditError::InsufficientHandles);
        CHECK(limit.limitingClip == c);
        CHECK(limit.reason == "“av30.mov” has no more media before its in point.");
        AddTransition atLimit(fx.seq, b, c, f30(15));
        applyReversible(fx.project, atLimit);
    }
    SUBCASE("limited by the outgoing clip's media after its out point") {
        // A2 ends 6 frames before the end of av30's 1800 frames.
        const ClipId d = fx.addClip(fx.v2, fx.av30, 0, 60, 1734);
        const ClipId e = fx.addClip(fx.v2, fx.av30, 60, 60, 300);
        const TransitionLimit limit = transitionLimit(fx.project, fx.seq, d, e);
        CHECK(limit.maximumFrames == 12); // ceil(12/2) = 6
        CHECK(limit.limitingClip == d);
        CHECK(limit.reason.find("after its out point") != std::string::npos);
    }
    SUBCASE("a one-frame transition needs only the outgoing clip's media") {
        const ClipId c = fx.addClip(fx.v1, fx.av30, 120, 60, 0); // no media before its in point
        CHECK(transitionLimit(fx.project, fx.seq, b, c).maximumFrames == 1);
    }
    SUBCASE("no transition fits") {
        const ClipId d = fx.addClip(fx.v2, fx.av30, 0, 60, 1740); // ends at the end of the media
        const ClipId e = fx.addClip(fx.v2, fx.av30, 60, 60, 0);
        const TransitionLimit none = transitionLimit(fx.project, fx.seq, d, e);
        CHECK(none.maximumFrames == 0);
        CHECK(identical(none.maximum, kCMTimeZero));
        CHECK(none.limitError == EditError::InsufficientHandles);
        CHECK(none.limitingClip == d);
    }
    SUBCASE("structural refusals") {
        CHECK(transitionLimit(fx.project, fx.seq, b, a).limitError == EditError::NotAdjacent);
        CHECK(transitionLimit(fx.project, fx.seq, a, ClipId(999)).limitError == EditError::ClipNotFound);
        const TransitionId t = fx.addTransition(fx.v1, a, b, 10);
        CHECK(transitionLimit(fx.project, fx.seq, a, b).limitError == EditError::AlreadyExists);
        const TransitionLimit resize = transitionLimit(fx.project, fx.seq, a, b, t);
        CHECK(resize.maximumFrames == 120);
        lockTrack(fx, fx.v1);
        const TransitionLimit locked = transitionLimit(fx.project, fx.seq, a, b, t);
        CHECK(locked.maximumFrames == 0);
        CHECK(locked.limitError == EditError::TrackLocked);
    }
    SUBCASE("a neighbouring transition") {
        const ClipId c = fx.addClip(fx.v1, fx.av30, 120, 60, 600);
        fx.addTransition(fx.v1, b, c, 40); // [100, 140)
        const TransitionLimit limit = transitionLimit(fx.project, fx.seq, a, b);
        // ceil(n/2) <= 40 frames of B before 100: n = 80.
        CHECK(limit.maximumFrames == 80);
        CHECK(limit.limitError == EditError::Overlap);
        CHECK(limit.reason.find("neighbouring transition") != std::string::npos);
    }
}
