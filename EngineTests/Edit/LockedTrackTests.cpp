// The locked-track contract (model review finding 5): no edit other than SetTrackFlags may change
// a locked track in any way, including side effects such as clearing a link to a clip the edit
// removed. Such edits are refused with TrackLocked and change nothing.

#include "EditTestSupport.h"

using namespace vetest;

TEST_CASE("Locked tracks: an overwrite that removes a clip whose partner is on a locked track is refused") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(30, 30);
    lockTrack(fx, fx.a1);
    fx.requireValid();
    OverwriteClip covering(fx.seq, f30(20), {place(fx.v1, fx.video60, 0, 60)});
    const EditResult r = applyRefused(fx.project, covering, EditError::TrackLocked);
    CHECK(r.message.find("A1") != std::string::npos);
    CHECK(fx.clip(a).linkedClipId == v);

    // Trimming the video keeps the link, so the locked audio is untouched and that is allowed.
    OverwriteClip trimming(fx.seq, f30(20), {place(fx.v1, fx.video60, 0, 20)});
    applyReversible(fx.project, trimming);
    CHECK(fx.clip(a).linkedClipId == v);
    CHECK(framesOf(fx.clip(v)) == span(40, 60));
    CHECK(framesOf(fx.clip(a)) == span(30, 60));
}

TEST_CASE("Locked tracks: removing one side of a pair whose other side is locked is refused") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 30);
    lockTrack(fx, fx.a1);
    RemoveClips remove(fx.seq, {v}, false);
    applyRefused(fx.project, remove, EditError::TrackLocked);
    RippleDelete ripple(fx.seq, {v}, RippleOptions{false, RippleScope::SyncedTracks});
    applyRefused(fx.project, ripple, EditError::TrackLocked);
    MoveClip moveAway(fx.seq, v, fx.v2, f30(100), false); // moving keeps the link: allowed
    applyReversible(fx.project, moveAway);
    CHECK(fx.clip(a).linkedClipId == v);
}

TEST_CASE("Locked tracks: removing a track linked into a locked track is refused") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 30);
    (void)v;
    lockTrack(fx, fx.a1);
    RemoveTrack remove(fx.seq, fx.v1);
    applyRefused(fx.project, remove, EditError::TrackLocked);
    CHECK(fx.clip(a).linkedClipId.has_value());
    RemoveTrack locked(fx.seq, fx.a1);
    applyRefused(fx.project, locked, EditError::TrackLocked);

    // Once unlocked, both work and undo restores the links.
    SetTrackFlags unlock(fx.seq, fx.a1, TrackFlagsUpdate{std::nullopt, std::nullopt, false, std::nullopt});
    applyReversible(fx.project, unlock);
    RemoveTrack allowed(fx.seq, fx.v1);
    applyReversible(fx.project, allowed);
    CHECK_FALSE(fx.clip(a).linkedClipId.has_value());
}

TEST_CASE("Locked tracks: transitions on a locked track cannot change as a side effect") {
    Fixture fx;
    const ClipId x = fx.addClip(fx.a1, fx.av30, 0, 60, 30);
    const ClipId y = fx.addClip(fx.a1, fx.av30, 60, 60, 300);
    const ClipId vx = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    fx.link(y, vx);
    fx.addTransition(fx.a1, x, y, 10);
    lockTrack(fx, fx.a1);
    fx.requireValid();
    // Deleting the video alone would unlink the locked audio clip.
    RemoveClips remove(fx.seq, {vx}, false);
    applyRefused(fx.project, remove, EditError::TrackLocked);
    // Locking and unlocking are always possible.
    SetTrackFlags rename(fx.seq, fx.a1, TrackFlagsUpdate{true, true, true, std::string("Locked")});
    applyReversible(fx.project, rename);
    CHECK(fx.sequence().transitions.size() == 1);
}

TEST_CASE("Locked tracks: every command that edits clips checks the lock") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 60);
    const ClipId next = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    const ClipId nextAudio = fx.addClip(fx.a1, fx.av30, 60, 60, 300);
    lockTrack(fx, fx.v1);
    Project &p = fx.project;
    {
        SetClipSpeed c(fx.seq, a, 2.0);
        applyRefused(p, c, EditError::TrackLocked); // carries the locked partner
    }
    {
        SetAudioParams c(fx.seq, v, AudioParams{});
        applyRefused(p, c, EditError::TrackLocked);
    }
    {
        AddTransition c(fx.seq, v, next, f30(10));
        applyRefused(p, c, EditError::TrackLocked);
    }
    {
        LinkClips c(fx.seq, next, nextAudio);
        applyRefused(p, c, EditError::TrackLocked);
    }
    {
        InsertClip c(fx.seq, f30(0), {place(fx.a1, fx.audioOnly, 0, 10)});
        applyRefused(p, c, EditError::TrackLocked); // the linked video would have to move
    }
    {
        InsertClip c(fx.seq, f30(0), {place(fx.a2, fx.audioOnly, 0, 10)}, InsertOptions{true, RippleScope::SyncedTracks});
        applyReversible(p, c); // nothing linked moves
    }
}
