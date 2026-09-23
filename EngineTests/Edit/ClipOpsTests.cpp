#include "EditTestSupport.h"

using namespace vetest;

// ---------------------------------------------------------------------------------------------
// InsertClip

TEST_CASE("InsertClip refuses invalid requests without changing the project") {
    Fixture fx;
    fx.addClip(fx.v1, fx.av30, 0, 30);
    Project &p = fx.project;
    auto insert = [&](CMTime at, std::vector<ClipPlacement> placements) {
        return InsertClip(fx.seq, at, std::move(placements));
    };
    {
        InsertClip c = insert(f30(0), {place(TrackId{999}, fx.av30, 0, 30)});
        applyRefused(p, c, EditError::TrackNotFound);
    }
    {
        InsertClip c = insert(f30(0), {place(fx.v1, fx.audioOnly, 0, 30)});
        applyRefused(p, c, EditError::TrackKindMismatch);
    }
    {
        InsertClip c = insert(f30(0), {place(fx.v1, AssetId{999}, 0, 30)});
        applyRefused(p, c, EditError::AssetNotFound);
    }
    {
        InsertClip c = insert(f30(-5), {place(fx.v1, fx.av30, 0, 30)});
        applyRefused(p, c, EditError::InvalidTime);
    }
    {
        InsertClip c = insert(kCMTimeInvalid, {place(fx.v1, fx.av30, 0, 30)});
        applyRefused(p, c, EditError::InvalidTime);
    }
    {
        InsertClip c = insert(f30(0), {place(fx.v1, fx.av30, 1790, 1810)});
        applyRefused(p, c, EditError::OutOfSourceRange);
    }
    {
        InsertClip c = insert(f30(0), {place(fx.v1, fx.av30, -1, 10)});
        applyRefused(p, c, EditError::OutOfSourceRange);
    }
    {
        InsertClip c = insert(f30(0), {place(fx.v1, fx.av30, 10, 10)});
        applyRefused(p, c, EditError::InvalidArgument);
    }
    {
        InsertClip c = insert(f30(0), {place(fx.v1, fx.av30, 0, 30, 0.0)});
        applyRefused(p, c, EditError::InvalidArgument);
    }
    {
        InsertClip c = insert(f30(0), {});
        applyRefused(p, c, EditError::InvalidArgument);
    }
    {
        InsertClip c = insert(f30(0), {place(fx.v1, fx.av30, 0, 30), place(fx.v1, fx.av30, 0, 30)});
        applyRefused(p, c, EditError::InvalidArgument);
    }
    {
        InsertClip c(SequenceId{999}, f30(0), {place(fx.v1, fx.av30, 0, 30)});
        applyRefused(p, c, EditError::SequenceNotFound);
    }
    {
        lockTrack(fx, fx.v1);
        InsertClip c = insert(f30(0), {place(fx.v1, fx.av30, 0, 30)});
        applyRefused(p, c, EditError::TrackLocked);
    }
}

TEST_CASE("InsertClip on synced tracks ripples later clips and splits a clip spanning the insert point") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 30, 30, 100);
    const ClipId other = fx.addClip(fx.v2, fx.av30, 0, 60);
    fx.requireValid();

    InsertClip insert(fx.seq, f30(10), {place(fx.v1, fx.av30, 500, 515)}, InsertOptions{true, RippleScope::SyncedTracks});
    applyReversible(fx.project, insert);

    REQUIRE(insert.createdClipIds().size() == 1);
    const ClipId inserted = insert.createdClipIds()[0];
    const std::vector<ClipId> ids = clipIdsOn(fx, fx.v1);
    REQUIRE(ids.size() == 4);
    CHECK(ids[0] == a);
    CHECK(ids[1] == inserted);
    const ClipId aRight = ids[2];
    CHECK(ids[3] == b);
    CHECK(framesOf(fx.clip(a)) == span(0, 10));
    CHECK(framesOf(fx.clip(inserted)) == span(10, 25));
    CHECK(framesOf(fx.clip(aRight)) == span(25, 45));
    CHECK(fx.clip(aRight).sourceIn == f30(10));
    CHECK(fx.clip(aRight).sourceOut() == f30(30));
    CHECK(framesOf(fx.clip(b)) == span(45, 75));
    CHECK(fx.clip(b).sourceIn == f30(100));
    CHECK(fx.clip(inserted).sourceIn == f30(500));
    CHECK(framesOf(fx.clip(other)) == span(0, 60)); // unlinked material on other tracks does not ripple
}

TEST_CASE("InsertClip ripples every unlocked track by default, splitting clips that span the insert point") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
    const ClipId other = fx.addClip(fx.v2, fx.av30, 0, 60, 100);
    const ClipId music = fx.addClip(fx.a2, fx.audioOnly, 20, 100);
    const ClipId locked = fx.addClip(fx.a1, fx.audioOnly, 0, 90, 300);
    lockTrack(fx, fx.a1);
    fx.requireValid();

    InsertClip insert(fx.seq, f30(10), {place(fx.v1, fx.av30, 500, 515)});
    applyReversible(fx.project, insert);
    const std::vector<ClipId> upper = clipIdsOn(fx, fx.v2);
    REQUIRE(upper.size() == 2);
    CHECK(framesOf(fx.clip(other)) == span(0, 10));
    CHECK(framesOf(fx.clip(upper[1])) == span(25, 75));
    CHECK(fx.clip(upper[1]).sourceIn == f30(110));
    CHECK(framesOf(fx.clip(music)) == span(35, 135)); // starts after the insert point: moves whole
    CHECK(framesOf(fx.clip(locked)) == span(0, 90));  // locked tracks stay put
    CHECK(framesOf(fx.clip(a)) == span(0, 10));
}

TEST_CASE("InsertClip keeps downstream linked pairs in sync (review finding 4)") {
    Fixture fx;
    fx.addLinkedPair(0, 60);
    const auto [v, a] = fx.addLinkedPair(60, 60, 300);
    SUBCASE("default: all unlocked tracks") {
        InsertClip insert(fx.seq, f30(10), {place(fx.v1, fx.video60, 0, 20)});
        applyReversible(fx.project, insert);
        CHECK(framesOf(fx.clip(v)) == span(80, 140));
        CHECK(framesOf(fx.clip(a)) == span(80, 140));
        // The split halves of the first pair are paired too.
        const std::vector<ClipId> video = clipIdsOn(fx, fx.v1);
        const std::vector<ClipId> audio = clipIdsOn(fx, fx.a1);
        REQUIRE(video.size() == 4);
        REQUIRE(audio.size() == 3);
        CHECK(fx.clip(video[2]).linkedClipId == audio[1]);
        CHECK(framesOf(fx.clip(audio[1])) == span(30, 80));
    }
    SUBCASE("synced tracks: the partners' track ripples with the target track") {
        InsertClip insert(fx.seq, f30(10), {place(fx.v1, fx.video60, 0, 20)},
                          InsertOptions{true, RippleScope::SyncedTracks});
        applyReversible(fx.project, insert);
        CHECK(framesOf(fx.clip(v)) == span(80, 140));
        CHECK(framesOf(fx.clip(a)) == span(80, 140));
    }
    SUBCASE("a partner on a locked track refuses the insert rather than drift") {
        lockTrack(fx, fx.a1);
        InsertClip insert(fx.seq, f30(10), {place(fx.v1, fx.video60, 0, 20)});
        const EditResult r = applyRefused(fx.project, insert, EditError::TrackLocked);
        CHECK(r.message.find("linked") != std::string::npos);
        InsertClip synced(fx.seq, f30(10), {place(fx.v1, fx.video60, 0, 20)},
                          InsertOptions{true, RippleScope::SyncedTracks});
        applyRefused(fx.project, synced, EditError::TrackLocked);
        // Inserting after the pairs touches nothing linked.
        InsertClip after(fx.seq, f30(120), {place(fx.v1, fx.video60, 0, 20)});
        applyReversible(fx.project, after);
    }
    SUBCASE("a partner wholly after the insert point takes the link to the moving right piece") {
        Fixture offset;
        const ClipId video = offset.addClip(offset.v1, offset.av30, 0, 100);
        const ClipId audio = offset.addClip(offset.a1, offset.av30, 50, 50, 50);
        offset.link(video, audio);
        InsertClip insert(offset.seq, f30(20), {place(offset.v1, offset.av30, 0, 10)});
        applyReversible(offset.project, insert);
        const ClipId right = clipIdsOn(offset, offset.v1)[2];
        CHECK(framesOf(offset.clip(right)) == span(30, 110));
        CHECK(framesOf(offset.clip(audio)) == span(60, 110));
        CHECK(offset.clip(audio).linkedClipId == right);
        CHECK_FALSE(offset.clip(video).linkedClipId.has_value());
    }
}

TEST_CASE("InsertClip of placements of different lengths moves every rippled track by the longest") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(30, 30);
    InsertClip insert(fx.seq, f30(0), {place(fx.v1, fx.av30, 0, 20), place(fx.a1, fx.av30, 0, 10)}, false);
    applyReversible(fx.project, insert);
    CHECK(framesOf(fx.clip(insert.createdClipIds()[0])) == span(0, 20));
    CHECK(framesOf(fx.clip(insert.createdClipIds()[1])) == span(0, 10)); // a 10-frame gap follows
    CHECK(framesOf(fx.clip(v)) == span(50, 80));
    CHECK(framesOf(fx.clip(a)) == span(50, 80));
}

TEST_CASE("InsertClip at a cut ripples without splitting") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 30, 30);
    InsertClip insert(fx.seq, f30(30), {place(fx.v1, fx.av30, 0, 20)});
    applyReversible(fx.project, insert);
    CHECK(clipIdsOn(fx, fx.v1).size() == 3);
    CHECK(framesOf(fx.clip(a)) == span(0, 30));
    CHECK(framesOf(fx.clip(b)) == span(50, 80));
}

TEST_CASE("InsertClip of an A/V pair links the new clips and keeps split pairs linked") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 60);
    InsertClip insert(fx.seq, f30(20), {place(fx.v1, fx.av30, 0, 30), place(fx.a1, fx.av30, 0, 30)});
    applyReversible(fx.project, insert);

    const auto &created = insert.createdClipIds();
    REQUIRE(created.size() == 2);
    CHECK(fx.clip(created[0]).linkedClipId == created[1]);
    CHECK(fx.clip(created[1]).linkedClipId == created[0]);
    CHECK(fx.clip(v).linkedClipId == a);
    CHECK(fx.clip(a).linkedClipId == v);

    const std::vector<ClipId> video = clipIdsOn(fx, fx.v1);
    const std::vector<ClipId> audio = clipIdsOn(fx, fx.a1);
    REQUIRE(video.size() == 3);
    REQUIRE(audio.size() == 3);
    CHECK(fx.clip(video[2]).linkedClipId == audio[2]); // right-hand halves linked to each other
    CHECK(fx.clip(audio[2]).linkedClipId == video[2]);
    CHECK(framesOf(fx.clip(video[2])) == span(50, 90));
    CHECK(framesOf(fx.clip(audio[2])) == span(50, 90));

    InsertClip unlinked(fx.seq, f30(0), {place(fx.v1, fx.av30, 0, 10), place(fx.a1, fx.av30, 0, 10)}, false);
    applyReversible(fx.project, unlinked);
    CHECK_FALSE(fx.clip(unlinked.createdClipIds()[0]).linkedClipId.has_value());
}

TEST_CASE("InsertClip handles stills, speed, foreign frame rates and off-grid times") {
    Fixture fx;
    SUBCASE("still with the default duration") {
        ClipPlacement p;
        p.trackId = fx.v1;
        p.assetId = fx.still;
        InsertClip insert(fx.seq, f30(0), {p});
        applyReversible(fx.project, insert);
        const Clip &clip = fx.clip(insert.createdClipIds()[0]);
        CHECK(clip.isStill);
        CHECK(clip.duration() == CMTimeMake(5, 1));
        CHECK(clip.sourceIn == kCMTimeZero);
    }
    SUBCASE("still with an explicit duration") {
        InsertClip insert(fx.seq, f30(0), {place(fx.v1, fx.still, 0, 60)});
        applyReversible(fx.project, insert);
        CHECK(framesOf(fx.clip(insert.createdClipIds()[0])) == span(0, 60));
    }
    SUBCASE("a still cannot go on an audio track") {
        InsertClip insert(fx.seq, f30(0), {place(fx.a1, fx.still, 0, 60)});
        applyRefused(fx.project, insert, EditError::TrackKindMismatch);
    }
    SUBCASE("speed 2 halves the timeline duration") {
        InsertClip insert(fx.seq, f30(0), {place(fx.v1, fx.av30, 0, 300, 2.0)});
        applyReversible(fx.project, insert);
        const Clip &clip = fx.clip(insert.createdClipIds()[0]);
        CHECK(framesOf(clip) == span(0, 150));
        CHECK(clip.sourceOut() == f30(300));
    }
    SUBCASE("23.976 source on a 30 fps timeline rounds down to whole frames") {
        ClipPlacement p;
        p.trackId = fx.v1;
        p.assetId = fx.av24;
        p.sourceIn = kCMTimeZero;
        p.sourceOut = CMTimeMake(25 * 1001, 24000); // 25 source frames = 1.0427 s
        InsertClip insert(fx.seq, f30(0), {p});
        applyReversible(fx.project, insert);
        const Clip &clip = fx.clip(insert.createdClipIds()[0]);
        CHECK(framesOf(clip) == span(0, 31));
        CHECK(clip.sourceOut() == f30(31));
        CHECK(clip.sourceOut() <= p.sourceOut);
    }
    SUBCASE("the insert time snaps to the nearest frame") {
        InsertClip insert(fx.seq, CMTimeMake(101, 300), {place(fx.v1, fx.av30, 0, 30)}); // 10.1 frames
        applyReversible(fx.project, insert);
        CHECK(framesOf(fx.clip(insert.createdClipIds()[0])) == span(10, 40));
    }
    SUBCASE("a source range shorter than a frame is refused") {
        ClipPlacement p = place(fx.v1, fx.av30, 0, 1);
        p.sourceOut = CMTimeMake(1, 600);
        InsertClip insert(fx.seq, f30(0), {p});
        applyRefused(fx.project, insert, EditError::InvalidArgument);
    }
}

// ---------------------------------------------------------------------------------------------
// OverwriteClip

TEST_CASE("OverwriteClip splits a clip it lands inside") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.a1, fx.av30, 0, 90);
    fx.sequence().findClip(a)->audio.fadeInDuration = f30(5);
    fx.sequence().findClip(a)->audio.fadeOutDuration = f30(6);
    fx.requireValid();

    OverwriteClip overwrite(fx.seq, f30(30), {place(fx.a1, fx.av30, 300, 315)});
    applyReversible(fx.project, overwrite);

    const std::vector<ClipId> ids = clipIdsOn(fx, fx.a1);
    REQUIRE(ids.size() == 3);
    CHECK(ids[0] == a);
    CHECK(ids[1] == overwrite.createdClipIds()[0]);
    const ClipId right = ids[2];
    CHECK(right != a);
    CHECK(framesOf(fx.clip(a)) == span(0, 30));
    CHECK(fx.clip(a).sourceOut() == f30(30));
    CHECK(framesOf(fx.clip(ids[1])) == span(30, 45));
    CHECK(framesOf(fx.clip(right)) == span(45, 90));
    CHECK(fx.clip(right).sourceIn == f30(45));
    CHECK(fx.clip(right).sourceOut() == f30(90));
    // The fade-in stays with the left piece, the fade-out goes with the right piece.
    CHECK(fx.clip(a).audio.fadeInDuration == f30(5));
    CHECK(fx.clip(a).audio.fadeOutDuration == kCMTimeZero);
    CHECK(fx.clip(right).audio.fadeInDuration == kCMTimeZero);
    CHECK(fx.clip(right).audio.fadeOutDuration == f30(6));
}

TEST_CASE("OverwriteClip trims clips it overlaps and removes clips it covers") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 30, 10);
    const ClipId c = fx.addClip(fx.v1, fx.av30, 40, 40, 200);
    OverwriteClip overwrite(fx.seq, f30(20), {place(fx.v1, fx.av30, 600, 630)});
    applyReversible(fx.project, overwrite);
    CHECK(framesOf(fx.clip(a)) == span(0, 20));
    CHECK_FALSE(fx.hasClip(b));
    CHECK(framesOf(fx.clip(c)) == span(50, 80));
    CHECK(fx.clip(c).sourceIn == f30(210));
    CHECK(framesOf(fx.clip(overwrite.createdClipIds()[0])) == span(20, 50));
    CHECK(clipIdsOn(fx, fx.v1).size() == 3);
}

TEST_CASE("OverwriteClip on one track of a linked pair leaves the other track alone") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 90);
    OverwriteClip overwrite(fx.seq, f30(30), {place(fx.v1, fx.video60, 0, 30)});
    applyReversible(fx.project, overwrite);
    const std::vector<ClipId> video = clipIdsOn(fx, fx.v1);
    REQUIRE(video.size() == 3);
    CHECK(fx.clip(v).linkedClipId == a);
    CHECK_FALSE(fx.clip(video[2]).linkedClipId.has_value());
    CHECK(framesOf(fx.clip(a)) == span(0, 90));
}

TEST_CASE("OverwriteClip of an A/V pair inside a linked pair keeps both halves linked") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 90);
    OverwriteClip overwrite(fx.seq, f30(30), {place(fx.v1, fx.av30, 0, 15), place(fx.a1, fx.av30, 0, 15)});
    applyReversible(fx.project, overwrite);
    const std::vector<ClipId> video = clipIdsOn(fx, fx.v1);
    const std::vector<ClipId> audio = clipIdsOn(fx, fx.a1);
    REQUIRE(video.size() == 3);
    REQUIRE(audio.size() == 3);
    CHECK(fx.clip(v).linkedClipId == a);
    CHECK(fx.clip(video[1]).linkedClipId == audio[1]);
    CHECK(fx.clip(video[2]).linkedClipId == audio[2]);
}

TEST_CASE("OverwriteClip refuses locked tracks") {
    Fixture fx;
    fx.addClip(fx.v1, fx.av30, 0, 90);
    lockTrack(fx, fx.v1);
    OverwriteClip overwrite(fx.seq, f30(30), {place(fx.v1, fx.av30, 0, 15)});
    applyRefused(fx.project, overwrite, EditError::TrackLocked);
}

// ---------------------------------------------------------------------------------------------
// MoveClip

TEST_CASE("MoveClip moves within a track and onto another track with overwrite semantics") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 30);
    const ClipId c = fx.addClip(fx.v2, fx.av30, 0, 120);

    SUBCASE("later on the same track") {
        MoveClip move(fx.seq, a, fx.v1, f30(30));
        applyReversible(fx.project, move);
        CHECK(framesOf(fx.clip(a)) == span(30, 60));
        CHECK(fx.clip(a).sourceIn == f30(0));
    }
    SUBCASE("overlapping its own old position") {
        MoveClip move(fx.seq, a, fx.v1, f30(15));
        applyReversible(fx.project, move);
        CHECK(framesOf(fx.clip(a)) == span(15, 45));
    }
    SUBCASE("onto another track, splitting the clip it lands in") {
        MoveClip move(fx.seq, b, fx.v2, f30(30));
        applyReversible(fx.project, move);
        const std::vector<ClipId> upper = clipIdsOn(fx, fx.v2);
        REQUIRE(upper.size() == 3);
        CHECK(upper[0] == c);
        CHECK(upper[1] == b);
        CHECK(framesOf(fx.clip(c)) == span(0, 30));
        CHECK(framesOf(fx.clip(b)) == span(30, 60));
        CHECK(framesOf(fx.clip(upper[2])) == span(60, 120));
        CHECK(fx.clip(upper[2]).sourceIn == f30(60));
        CHECK(fx.clip(b).trackId == fx.v2);
        CHECK(clipIdsOn(fx, fx.v1) == std::vector<ClipId>{a});
    }
    SUBCASE("over a neighbour, trimming it") {
        MoveClip move(fx.seq, a, fx.v1, f30(45));
        applyReversible(fx.project, move);
        CHECK(framesOf(fx.clip(a)) == span(45, 75));
        CHECK(framesOf(fx.clip(b)) == span(75, 90));
        CHECK(fx.clip(b).sourceIn == f30(15));
    }
    SUBCASE("to where it already is is a no-op") {
        const Project before = fx.project;
        MoveClip move(fx.seq, a, fx.v1, f30(0));
        applyReversible(fx.project, move);
        CHECK(fx.project == before);
    }
}

TEST_CASE("MoveClip carries the linked clip unless told not to") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 30);
    SUBCASE("linked") {
        MoveClip move(fx.seq, v, fx.v2, f30(60));
        applyReversible(fx.project, move);
        CHECK(framesOf(fx.clip(v)) == span(60, 90));
        CHECK(fx.clip(v).trackId == fx.v2);
        CHECK(framesOf(fx.clip(a)) == span(60, 90));
        CHECK(fx.clip(a).trackId == fx.a1); // the partner keeps its track
        CHECK(fx.clip(v).linkedClipId == a);
    }
    SUBCASE("moving the audio side moves the video") {
        MoveClip move(fx.seq, a, fx.a1, f30(10));
        applyReversible(fx.project, move);
        CHECK(framesOf(fx.clip(v)) == span(10, 40));
    }
    SUBCASE("alone") {
        MoveClip move(fx.seq, v, fx.v1, f30(60), false);
        applyReversible(fx.project, move);
        CHECK(framesOf(fx.clip(v)) == span(60, 90));
        CHECK(framesOf(fx.clip(a)) == span(0, 30));
        CHECK(fx.clip(v).linkedClipId == a); // still linked, now out of sync
    }
}

TEST_CASE("MoveClip refusals") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(30, 30);
    const ClipId loose = fx.addClip(fx.v1, fx.av30, 100, 30);
    // A partner that starts earlier than its video.
    const ClipId offsetVideo = fx.addClip(fx.v2, fx.av30, 30, 30);
    const ClipId offsetAudio = fx.addClip(fx.a2, fx.av30, 0, 30);
    fx.link(offsetVideo, offsetAudio);
    fx.requireValid();
    Project &p = fx.project;
    {
        MoveClip move(fx.seq, loose, fx.a1, f30(0));
        applyRefused(p, move, EditError::TrackKindMismatch);
    }
    {
        MoveClip move(fx.seq, loose, fx.v1, f30(-1));
        applyRefused(p, move, EditError::InvalidTime);
    }
    {
        MoveClip move(fx.seq, offsetVideo, fx.v2, f30(10)); // partner would start at -20
        applyRefused(p, move, EditError::InvalidTime);
    }
    {
        MoveClip move(fx.seq, ClipId{999}, fx.v1, f30(0));
        applyRefused(p, move, EditError::ClipNotFound);
    }
    {
        MoveClip move(fx.seq, loose, TrackId{999}, f30(0));
        applyRefused(p, move, EditError::TrackNotFound);
    }
    {
        lockTrack(fx, fx.a1); // partner's track
        MoveClip move(fx.seq, v, fx.v1, f30(200));
        applyRefused(p, move, EditError::TrackLocked);
        MoveClip alone(fx.seq, v, fx.v1, f30(200), false);
        applyReversible(p, alone);
        fx.track(fx.a1).locked = false;
    }
    {
        lockTrack(fx, fx.v2); // destination
        MoveClip move(fx.seq, loose, fx.v2, f30(200));
        applyRefused(p, move, EditError::TrackLocked);
        fx.track(fx.v2).locked = false;
    }
    {
        lockTrack(fx, fx.v1); // source
        MoveClip move(fx.seq, loose, fx.v2, f30(200));
        applyRefused(p, move, EditError::TrackLocked);
    }
}

TEST_CASE("MoveClip drops a transition whose cut it breaks; undo restores it") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    fx.addTransition(fx.v1, a, b, 10);
    fx.requireValid();
    MoveClip move(fx.seq, b, fx.v1, f30(200));
    applyReversible(fx.project, move);
    CHECK(fx.sequence().transitions.empty());
    move.revert(fx.project);
    CHECK(fx.sequence().transitions.size() == 1);
}

// ---------------------------------------------------------------------------------------------
// Trims

TEST_CASE("TrimClipHead is bounded by neighbours, source media and one frame") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 40, 30, 60);
    const ClipId c = fx.addClip(fx.v2, fx.av30, 100, 30, 5);
    Project &p = fx.project;

    SUBCASE("extend into the gap") {
        TrimClipHead trim(fx.seq, b, f30(35));
        applyReversible(p, trim);
        CHECK(framesOf(fx.clip(b)) == span(35, 70));
        CHECK(fx.clip(b).sourceIn == f30(55));
    }
    SUBCASE("shorten") {
        TrimClipHead trim(fx.seq, b, f30(50));
        applyReversible(p, trim);
        CHECK(framesOf(fx.clip(b)) == span(50, 70));
        CHECK(fx.clip(b).sourceIn == f30(70));
    }
    SUBCASE("previous clip") {
        TrimClipHead trim(fx.seq, b, f30(20));
        applyRefused(p, trim, EditError::Overlap);
        TrimClipHead clamped(fx.seq, b, f30(20), TrimOptions{true, true});
        applyReversible(p, clamped);
        CHECK(framesOf(fx.clip(b)) == span(30, 70));
    }
    SUBCASE("time zero") {
        TrimClipHead trim(fx.seq, a, f30(-10));
        applyRefused(p, trim, EditError::InvalidTime);
    }
    SUBCASE("start of the media") {
        TrimClipHead trim(fx.seq, c, f30(90));
        applyRefused(p, trim, EditError::OutOfSourceRange);
        TrimClipHead clamped(fx.seq, c, f30(90), TrimOptions{true, true});
        applyReversible(p, clamped);
        CHECK(framesOf(fx.clip(c)) == span(95, 130));
        CHECK(fx.clip(c).sourceIn == kCMTimeZero);
    }
    SUBCASE("minimum length") {
        TrimClipHead toEnd(fx.seq, a, f30(30));
        applyRefused(p, toEnd, EditError::InvalidTime);
        TrimClipHead oneFrame(fx.seq, a, f30(29));
        applyReversible(p, oneFrame);
        CHECK(framesOf(fx.clip(a)) == span(29, 30));
    }
    SUBCASE("locked") {
        lockTrack(fx, fx.v1);
        TrimClipHead trim(fx.seq, b, f30(45));
        applyRefused(p, trim, EditError::TrackLocked);
    }
    SUBCASE("non-numeric time") {
        TrimClipHead trim(fx.seq, b, kCMTimeIndefinite);
        applyRefused(p, trim, EditError::InvalidTime);
    }
}

TEST_CASE("TrimClipTail is bounded by the next clip, source media and one frame") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30, 1760); // 10 frames of media left
    const ClipId b = fx.addClip(fx.v1, fx.av30, 35, 30);
    const ClipId c = fx.addClip(fx.v2, fx.av30, 0, 30, 1760);
    Project &p = fx.project;

    SUBCASE("next clip limits first") {
        TrimClipTail trim(fx.seq, a, f30(50));
        applyRefused(p, trim, EditError::Overlap);
        TrimClipTail clamped(fx.seq, a, f30(50), TrimOptions{true, true});
        applyReversible(p, clamped);
        CHECK(framesOf(fx.clip(a)) == span(0, 35));
    }
    SUBCASE("end of the media") {
        TrimClipTail trim(fx.seq, c, f30(50));
        applyRefused(p, trim, EditError::OutOfSourceRange);
        TrimClipTail clamped(fx.seq, c, f30(50), TrimOptions{true, true});
        applyReversible(p, clamped);
        CHECK(framesOf(fx.clip(c)) == span(0, 40));
        CHECK(fx.clip(c).sourceOut() == f30(1800));
    }
    SUBCASE("shorten") {
        TrimClipTail trim(fx.seq, b, f30(40));
        applyReversible(p, trim);
        CHECK(framesOf(fx.clip(b)) == span(35, 40));
        CHECK(fx.clip(b).sourceOut() == f30(5));
    }
    SUBCASE("minimum length") {
        TrimClipTail trim(fx.seq, b, f30(35));
        applyRefused(p, trim, EditError::InvalidTime);
    }
}

TEST_CASE("Trimming a still is bounded only by neighbours") {
    Fixture fx;
    const ClipId s = fx.addClip(fx.v1, fx.still, 300, 150);
    const ClipId next = fx.addClip(fx.v1, fx.av30, 1000, 30);
    TrimClipHead head(fx.seq, s, f30(0));
    applyReversible(fx.project, head);
    CHECK(framesOf(fx.clip(s)) == span(0, 450));
    CHECK(fx.clip(s).sourceIn == kCMTimeZero);
    TrimClipTail tail(fx.seq, s, f30(990));
    applyReversible(fx.project, tail);
    CHECK(framesOf(fx.clip(s)) == span(0, 990));
    TrimClipTail tooFar(fx.seq, s, f30(1010));
    applyRefused(fx.project, tooFar, EditError::Overlap);
    CHECK(framesOf(fx.clip(next)) == span(1000, 1030));
}

TEST_CASE("Trims carry the linked clip and honour its limits") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(30, 30, 30);
    SUBCASE("both edges move") {
        TrimClipHead head(fx.seq, v, f30(20));
        applyReversible(fx.project, head);
        CHECK(framesOf(fx.clip(v)) == span(20, 60));
        CHECK(framesOf(fx.clip(a)) == span(20, 60));
        CHECK(fx.clip(a).sourceIn == f30(20));
        TrimClipTail tail(fx.seq, a, f30(50));
        applyReversible(fx.project, tail);
        CHECK(framesOf(fx.clip(v)) == span(20, 50));
        CHECK(framesOf(fx.clip(a)) == span(20, 50));
    }
    SUBCASE("the partner's neighbour blocks the trim") {
        fx.addClip(fx.a1, fx.audioOnly, 0, 25);
        TrimClipHead head(fx.seq, v, f30(20));
        const EditResult r = applyRefused(fx.project, head, EditError::Overlap);
        CHECK(r.message.find("linked clip") != std::string::npos);
        TrimClipHead alone(fx.seq, v, f30(20), TrimOptions{false, false});
        applyReversible(fx.project, alone);
        CHECK(framesOf(fx.clip(v)) == span(20, 60));
        CHECK(framesOf(fx.clip(a)) == span(30, 60));
    }
    SUBCASE("the partner's track is locked") {
        lockTrack(fx, fx.a1);
        TrimClipTail tail(fx.seq, v, f30(50));
        applyRefused(fx.project, tail, EditError::TrackLocked);
    }
}

TEST_CASE("Trimming a speed-changed clip moves the source by speed x the timeline change") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 30, 30, 60, 2.0); // source 60..120
    TrimClipHead head(fx.seq, c, f30(20));
    applyReversible(fx.project, head);
    CHECK(fx.clip(c).sourceIn == f30(40));
    CHECK(fx.clip(c).sourceOut() == f30(120));
    TrimClipTail tail(fx.seq, c, f30(40));
    applyReversible(fx.project, tail);
    CHECK(fx.clip(c).sourceOut() == f30(80));
    CHECK(framesOf(fx.clip(c)) == span(20, 40));
}

// ---------------------------------------------------------------------------------------------
// SplitClip

TEST_CASE("SplitClip splits at a frame inside the clip") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.a1, fx.audioOnly, 10, 60, 100);
    fx.sequence().findClip(c)->audio = AudioParams{-3.0, f30(3), f30(4)};
    SplitClip split(fx.seq, c, f30(30));
    applyReversible(fx.project, split);
    REQUIRE(split.createdClipIds().size() == 1);
    const ClipId right = split.createdClipIds()[0];
    CHECK(framesOf(fx.clip(c)) == span(10, 30));
    CHECK(fx.clip(c).sourceIn == f30(100));
    CHECK(fx.clip(c).sourceOut() == f30(120));
    CHECK(framesOf(fx.clip(right)) == span(30, 70));
    CHECK(fx.clip(right).sourceIn == f30(120));
    CHECK(fx.clip(right).sourceOut() == f30(160));
    CHECK(fx.clip(c).audio.gainDb == -3.0);
    CHECK(fx.clip(right).audio.gainDb == -3.0);
    CHECK(fx.clip(c).audio.fadeInDuration == f30(3));
    CHECK(fx.clip(c).audio.fadeOutDuration == kCMTimeZero);
    CHECK(fx.clip(right).audio.fadeInDuration == kCMTimeZero);
    CHECK(fx.clip(right).audio.fadeOutDuration == f30(4));
}

TEST_CASE("SplitClip splits the linked clip too and links the halves pairwise") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 60);
    SUBCASE("linked") {
        SplitClip split(fx.seq, v, f30(20));
        applyReversible(fx.project, split);
        REQUIRE(split.createdClipIds().size() == 2);
        const ClipId vRight = split.createdClipIds()[0];
        const ClipId aRight = split.createdClipIds()[1];
        CHECK(fx.clip(v).linkedClipId == a);
        CHECK(fx.clip(a).linkedClipId == v);
        CHECK(fx.clip(vRight).linkedClipId == aRight);
        CHECK(fx.clip(aRight).linkedClipId == vRight);
        CHECK(fx.clip(vRight).trackId == fx.v1);
        CHECK(fx.clip(aRight).trackId == fx.a1);
        CHECK(framesOf(fx.clip(aRight)) == span(20, 60));
    }
    SUBCASE("unlinked split leaves the partner whole") {
        SplitClip split(fx.seq, v, f30(20), false);
        applyReversible(fx.project, split);
        REQUIRE(split.createdClipIds().size() == 1);
        CHECK_FALSE(fx.clip(split.createdClipIds()[0]).linkedClipId.has_value());
        CHECK(framesOf(fx.clip(a)) == span(0, 60));
        CHECK(fx.clip(v).linkedClipId == a);
    }
    SUBCASE("a partner that does not span the split time stays whole") {
        TrimClipTail shorten(fx.seq, a, f30(10), TrimOptions{false, false});
        REQUIRE(shorten.apply(fx.project).ok());
        SplitClip split(fx.seq, v, f30(20));
        applyReversible(fx.project, split);
        REQUIRE(split.createdClipIds().size() == 1);
        CHECK_FALSE(fx.clip(split.createdClipIds()[0]).linkedClipId.has_value());
        CHECK(fx.clip(v).linkedClipId == a);
    }
    SUBCASE("refused when the partner's track is locked") {
        lockTrack(fx, fx.a1);
        SplitClip split(fx.seq, v, f30(20));
        applyRefused(fx.project, split, EditError::TrackLocked);
    }
}

TEST_CASE("SplitClip refuses times not strictly inside the clip") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 10, 30);
    for (const CMTime t : {f30(10), f30(40), f30(5), f30(100), kCMTimeInvalid}) {
        SplitClip split(fx.seq, c, t);
        applyRefused(fx.project, split, EditError::InvalidTime);
    }
    SplitClip missing(fx.seq, ClipId{999}, f30(20));
    applyRefused(fx.project, missing, EditError::ClipNotFound);
}

TEST_CASE("SplitClip moves a transition at the clip's end to the right piece") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    const TransitionId t = fx.addTransition(fx.v1, a, b, 10);
    fx.requireValid();

    SplitClip split(fx.seq, a, f30(20));
    applyReversible(fx.project, split);
    const ClipId right = split.createdClipIds()[0];
    REQUIRE(fx.sequence().findTransition(t) != nullptr);
    CHECK(fx.sequence().findTransition(t)->fromClipId == right);
    CHECK(fx.sequence().findTransition(t)->toClipId == b);
}

TEST_CASE("SplitClip on a speed-changed clip splits the source proportionally") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30, 0, 2.0);
    SplitClip split(fx.seq, c, f30(10));
    applyReversible(fx.project, split);
    const ClipId right = split.createdClipIds()[0];
    CHECK(fx.clip(c).sourceOut() == f30(20));
    CHECK(fx.clip(right).sourceIn == f30(20));
    CHECK(fx.clip(right).sourceOut() == f30(60));
    CHECK(fx.clip(right).speed == Ratio{2, 1});
    CHECK(framesOf(fx.clip(right)) == span(10, 30));
}

// ---------------------------------------------------------------------------------------------
// RemoveClips / RippleDelete

TEST_CASE("RemoveClips leaves a gap and removes linked partners") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 30);
    const ClipId later = fx.addClip(fx.v1, fx.av30, 60, 30);
    SUBCASE("with partner") {
        RemoveClips remove(fx.seq, {v});
        applyReversible(fx.project, remove);
        CHECK_FALSE(fx.hasClip(v));
        CHECK_FALSE(fx.hasClip(a));
        CHECK(framesOf(fx.clip(later)) == span(60, 90));
    }
    SUBCASE("without partner, which becomes unlinked") {
        RemoveClips remove(fx.seq, {v}, false);
        applyReversible(fx.project, remove);
        CHECK_FALSE(fx.hasClip(v));
        CHECK_FALSE(fx.clip(a).linkedClipId.has_value());
    }
    SUBCASE("duplicates and partners listed explicitly are fine") {
        RemoveClips remove(fx.seq, {v, a, v, later});
        applyReversible(fx.project, remove);
        CHECK(fx.sequence().duration() == kCMTimeZero);
    }
    SUBCASE("refusals") {
        RemoveClips none(fx.seq, {});
        applyRefused(fx.project, none, EditError::InvalidArgument);
        RemoveClips missing(fx.seq, {later, ClipId{999}});
        applyRefused(fx.project, missing, EditError::ClipNotFound);
        lockTrack(fx, fx.a1);
        RemoveClips locked(fx.seq, {v});
        applyRefused(fx.project, locked, EditError::TrackLocked);
    }
}

TEST_CASE("RippleDelete closes the gap on every unlocked track by default") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 30, 30);
    const ClipId c = fx.addClip(fx.v1, fx.av30, 70, 30);
    const ClipId other = fx.addClip(fx.v2, fx.av30, 80, 30);
    SUBCASE("one clip") {
        RippleDelete ripple(fx.seq, {b});
        applyReversible(fx.project, ripple);
        CHECK(framesOf(fx.clip(a)) == span(0, 30));
        CHECK(framesOf(fx.clip(c)) == span(40, 70));
        CHECK(framesOf(fx.clip(other)) == span(50, 80));
    }
    SUBCASE("synced tracks only") {
        RippleDelete ripple(fx.seq, {b}, RippleOptions{true, RippleScope::SyncedTracks});
        applyReversible(fx.project, ripple);
        CHECK(framesOf(fx.clip(c)) == span(40, 70));
        CHECK(framesOf(fx.clip(other)) == span(80, 110));
    }
    SUBCASE("several clips") {
        RippleDelete ripple(fx.seq, {a, c}, RippleOptions{true, RippleScope::SyncedTracks});
        applyReversible(fx.project, ripple);
        CHECK(framesOf(fx.clip(b)) == span(0, 30));
        CHECK(clipIdsOn(fx, fx.v1) == std::vector<ClipId>{b});
    }
    SUBCASE("several clips on every track is refused when another track has a clip in the removed time") {
        RippleDelete ripple(fx.seq, {a, c});
        applyRefused(fx.project, ripple, EditError::Overlap);
    }
    SUBCASE("locked tracks stay put") {
        lockTrack(fx, fx.v2);
        RippleDelete ripple(fx.seq, {b});
        applyReversible(fx.project, ripple);
        CHECK(framesOf(fx.clip(other)) == span(80, 110));
    }
    SUBCASE("refused when another track has a clip in the removed time") {
        fx.addClip(fx.a1, fx.audioOnly, 40, 5);
        RippleDelete ripple(fx.seq, {b});
        const EditResult r = applyRefused(fx.project, ripple, EditError::Overlap);
        CHECK(r.message.find("ripple fewer tracks") != std::string::npos);
    }
}

TEST_CASE("RippleDelete keeps linked pairs in sync on synced tracks and refuses to strand a locked partner") {
    Fixture fx;
    const ClipId gone = fx.addClip(fx.v1, fx.av30, 0, 30);
    const auto [v, a] = fx.addLinkedPair(30, 30, 300);
    SUBCASE("synced: the partner's track closes the same time") {
        RippleDelete ripple(fx.seq, {gone}, RippleOptions{true, RippleScope::SyncedTracks});
        applyReversible(fx.project, ripple);
        CHECK(framesOf(fx.clip(v)) == span(0, 30));
        CHECK(framesOf(fx.clip(a)) == span(0, 30));
    }
    SUBCASE("a partner on a locked track refuses the delete") {
        lockTrack(fx, fx.a1);
        RippleDelete all(fx.seq, {gone});
        applyRefused(fx.project, all, EditError::TrackLocked);
        RippleDelete synced(fx.seq, {gone}, RippleOptions{true, RippleScope::SyncedTracks});
        applyRefused(fx.project, synced, EditError::TrackLocked);
    }
}

TEST_CASE("RippleDelete of a linked clip ripples both tracks") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 30);
    const ClipId q = fx.addClip(fx.v1, fx.av30, 30, 30);
    const ClipId r = fx.addClip(fx.a1, fx.audioOnly, 40, 30);
    RippleDelete ripple(fx.seq, {v});
    applyReversible(fx.project, ripple);
    CHECK_FALSE(fx.hasClip(a));
    CHECK(framesOf(fx.clip(q)) == span(0, 30));
    CHECK(framesOf(fx.clip(r)) == span(10, 40));
}

// ---------------------------------------------------------------------------------------------
// Clip parameters and speed

TEST_CASE("SetVideoParams and SetAudioParams validate and apply") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 30);
    VideoParams video{100.0, -50.0, 0.5, 45.0, 0.75};
    SetVideoParams setVideo(fx.seq, v, video);
    applyReversible(fx.project, setVideo);
    CHECK(fx.clip(v).video == video);
    CHECK(setVideo.coalescingKey() == "videoParams:" + std::to_string(v.value()));

    AudioParams audio{-6.0, f30(10), f30(20)};
    SetAudioParams setAudio(fx.seq, a, audio);
    applyReversible(fx.project, setAudio);
    CHECK(fx.clip(a).audio == audio);

    for (const VideoParams bad : {VideoParams{0, 0, 1, 0, 1.5}, VideoParams{NAN, 0, 1, 0, 1},
                                  VideoParams{0, 0, -1, 0, 1}, VideoParams{0, 0, 1, INFINITY, 1}}) {
        SetVideoParams c(fx.seq, v, bad);
        applyRefused(fx.project, c, EditError::InvalidArgument);
    }
    {
        SetAudioParams c(fx.seq, a, AudioParams{NAN, kCMTimeZero, kCMTimeZero});
        applyRefused(fx.project, c, EditError::InvalidArgument);
    }
    {
        SetAudioParams c(fx.seq, a, AudioParams{0, f30(31), kCMTimeZero});
        applyRefused(fx.project, c, EditError::InvalidTime);
    }
    {
        SetAudioParams c(fx.seq, a, AudioParams{0, kCMTimeZero, f30(-1)});
        applyRefused(fx.project, c, EditError::InvalidTime);
    }
    {
        lockTrack(fx, fx.v1);
        SetVideoParams c(fx.seq, v, VideoParams{});
        applyRefused(fx.project, c, EditError::TrackLocked);
    }
}

TEST_CASE("SetClipSpeed changes duration, respects neighbours and can ripple") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 60);
    const ClipId next = fx.addClip(fx.v1, fx.av30, 90, 30);
    SUBCASE("faster") {
        SetClipSpeed speed(fx.seq, c, 2.0);
        applyReversible(fx.project, speed);
        CHECK(framesOf(fx.clip(c)) == span(0, 30));
        CHECK(fx.clip(c).sourceOut() == f30(60));
        CHECK(framesOf(fx.clip(next)) == span(90, 120));
    }
    SUBCASE("slower overlaps the next clip") {
        SetClipSpeed speed(fx.seq, c, 0.5);
        applyRefused(fx.project, speed, EditError::Overlap);
    }
    SUBCASE("slower with ripple pushes the next clip") {
        SetClipSpeed speed(fx.seq, c, 0.5, SpeedOptions{true, true});
        applyReversible(fx.project, speed);
        CHECK(framesOf(fx.clip(c)) == span(0, 120));
        CHECK(framesOf(fx.clip(next)) == span(150, 180));
    }
    SUBCASE("faster with ripple pulls the next clip") {
        SetClipSpeed speed(fx.seq, c, 2.0, SpeedOptions{true, true});
        applyReversible(fx.project, speed);
        CHECK(framesOf(fx.clip(next)) == span(60, 90));
    }
    SUBCASE("a third speed") {
        SetClipSpeed speed(fx.seq, c, 1.0 / 3.0, SpeedOptions{true, true});
        applyReversible(fx.project, speed);
        CHECK(framesOf(fx.clip(c)) == span(0, 180));
        CHECK(fx.clip(c).sourceOut() == f30(60));
    }
    SUBCASE("invalid speeds") {
        for (const double bad : {0.0, -1.0, double(NAN), double(INFINITY), 1000.0, 0.001}) {
            SetClipSpeed speed(fx.seq, c, bad);
            applyRefused(fx.project, speed, EditError::InvalidArgument);
        }
    }
}

TEST_CASE("SetClipSpeed near the end of the media shortens rather than overrun it") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 61, 1739); // source 1739..1800
    SetClipSpeed speed(fx.seq, c, 1.5);
    applyReversible(fx.project, speed);
    CHECK(framesOf(fx.clip(c)) == span(0, 40)); // 61 / 1.5 = 40.67 would need media past the end
    CHECK(fx.clip(c).sourceOut() == f30(1799));
}

TEST_CASE("SetClipSpeed applies to the linked clip and refuses stills") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 60);
    SetClipSpeed speed(fx.seq, v, 2.0);
    applyReversible(fx.project, speed);
    CHECK(framesOf(fx.clip(a)) == span(0, 30));
    CHECK(fx.clip(a).speed == Ratio{2, 1});

    const ClipId s = fx.addClip(fx.v2, fx.still, 0, 60);
    SetClipSpeed still(fx.seq, s, 2.0);
    applyRefused(fx.project, still, EditError::InvalidArgument);
}
