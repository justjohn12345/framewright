#include "EditTestSupport.h"

using namespace vetest;

namespace {

// V1: A [0,60) source 30.., B [60,120) source 300.. — both with plenty of handles.
struct CutFixture : Fixture {
    ClipId a, b;
    CutFixture() {
        a = addClip(v1, av30, 0, 60, 30);
        b = addClip(v1, av30, 60, 60, 300);
        requireValid();
    }
};

} // namespace

TEST_CASE("AddTransition centres a transition on the cut") {
    CutFixture fx;
    AddTransition add(fx.seq, fx.a, fx.b, f30(10));
    applyReversible(fx.project, add);
    const Transition *t = fx.sequence().findTransition(add.createdTransitionId());
    REQUIRE(t != nullptr);
    CHECK(t->trackId == fx.v1);
    CHECK(t->fromClipId == fx.a);
    CHECK(t->toClipId == fx.b);
    CHECK(t->duration == f30(10));
    const auto range = fx.sequence().transitionRange(*t);
    CHECK(range->start == f30(55));
    CHECK(range->end == f30(65));
}

TEST_CASE("AddTransition refusals") {
    CutFixture fx;
    Project &p = fx.project;
    SUBCASE("not adjacent") {
        const ClipId c = fx.addClip(fx.v1, fx.av30, 121, 30, 600);
        AddTransition add(fx.seq, fx.b, c, f30(10));
        applyRefused(p, add, EditError::NotAdjacent);
    }
    SUBCASE("wrong order") {
        AddTransition add(fx.seq, fx.b, fx.a, f30(10));
        applyRefused(p, add, EditError::NotAdjacent);
    }
    SUBCASE("different tracks") {
        const ClipId c = fx.addClip(fx.v2, fx.av30, 60, 30, 600);
        AddTransition add(fx.seq, fx.a, c, f30(10));
        applyRefused(p, add, EditError::InvalidArgument);
    }
    SUBCASE("outgoing clip has no media after its out point") {
        const ClipId c = fx.addClip(fx.v2, fx.av30, 0, 60, 1740);
        const ClipId d = fx.addClip(fx.v2, fx.av30, 60, 60, 300);
        AddTransition add(fx.seq, c, d, f30(10));
        const EditResult r = applyRefused(p, add, EditError::InsufficientHandles);
        CHECK(r.message.find("after its out point") != std::string::npos);
    }
    SUBCASE("incoming clip has no media before its in point") {
        const ClipId c = fx.addClip(fx.v2, fx.av30, 0, 60, 300);
        const ClipId d = fx.addClip(fx.v2, fx.av30, 60, 60, 0);
        AddTransition add(fx.seq, c, d, f30(10));
        const EditResult r = applyRefused(p, add, EditError::InsufficientHandles);
        CHECK(r.message.find("before its in point") != std::string::npos);
    }
    SUBCASE("handles too short for the requested length") {
        const ClipId c = fx.addClip(fx.v2, fx.av30, 0, 60, 300);
        const ClipId d = fx.addClip(fx.v2, fx.av30, 60, 60, 4); // 4 frames of handle
        AddTransition tooLong(fx.seq, c, d, f30(10));           // needs 5 before the cut
        applyRefused(p, tooLong, EditError::InsufficientHandles);
        AddTransition fits(fx.seq, c, d, f30(9)); // needs 4
        applyReversible(p, fits);
    }
    SUBCASE("longer than the clips") {
        AddTransition add(fx.seq, fx.a, fx.b, f30(200));
        applyRefused(p, add, EditError::InvalidArgument);
    }
    SUBCASE("zero or non-numeric duration") {
        AddTransition zero(fx.seq, fx.a, fx.b, kCMTimeZero);
        applyRefused(p, zero, EditError::InvalidArgument);
        AddTransition invalid(fx.seq, fx.a, fx.b, kCMTimeInvalid);
        applyRefused(p, invalid, EditError::InvalidTime);
    }
    SUBCASE("already exists") {
        fx.addTransition(fx.v1, fx.a, fx.b, 10);
        AddTransition add(fx.seq, fx.a, fx.b, f30(20));
        applyRefused(p, add, EditError::AlreadyExists);
    }
    SUBCASE("overlaps the neighbouring transition") {
        const ClipId c = fx.addClip(fx.v1, fx.av30, 120, 60, 600);
        fx.addTransition(fx.v1, fx.a, fx.b, 40);     // [40, 80)
        AddTransition add(fx.seq, fx.b, c, f30(90)); // [75, 165)
        applyRefused(p, add, EditError::Overlap);
        AddTransition fits(fx.seq, fx.b, c, f30(80)); // [80, 160)
        applyReversible(p, fits);
    }
    SUBCASE("locked or missing") {
        AddTransition missing(fx.seq, fx.a, ClipId{999}, f30(10));
        applyRefused(p, missing, EditError::ClipNotFound);
        lockTrack(fx, fx.v1);
        AddTransition locked(fx.seq, fx.a, fx.b, f30(10));
        applyRefused(p, locked, EditError::TrackLocked);
    }
}

TEST_CASE("Transitions between stills need no handles; audio tracks crossfade") {
    Fixture fx;
    const ClipId s1 = fx.addClip(fx.v1, fx.still, 0, 60);
    const ClipId s2 = fx.addClip(fx.v1, fx.still, 60, 60);
    AddTransition dissolve(fx.seq, s1, s2, f30(30));
    applyReversible(fx.project, dissolve);

    const ClipId m1 = fx.addClip(fx.a1, fx.audioOnly, 0, 60, 30);
    const ClipId m2 = fx.addClip(fx.a1, fx.audioOnly, 60, 60, 300);
    AddTransition crossfade(fx.seq, m1, m2, f30(20));
    applyReversible(fx.project, crossfade);
    CHECK(fx.sequence().transitions.size() == 2);
}

TEST_CASE("SetTransitionDuration and RemoveTransition") {
    CutFixture fx;
    const TransitionId t = fx.addTransition(fx.v1, fx.a, fx.b, 10);
    fx.requireValid();
    SetTransitionDuration longer(fx.seq, t, f30(40));
    applyReversible(fx.project, longer);
    CHECK(fx.sequence().findTransition(t)->duration == f30(40));

    SetTransitionDuration tooLong(fx.seq, t, f30(122)); // 61 frames before the cut, but A is 60 long
    applyRefused(fx.project, tooLong, EditError::InvalidArgument);

    SetTransitionDuration missing(fx.seq, TransitionId{999}, f30(10));
    applyRefused(fx.project, missing, EditError::TransitionNotFound);

    RemoveTransition remove(fx.seq, t);
    applyReversible(fx.project, remove);
    CHECK(fx.sequence().transitions.empty());
    RemoveTransition again(fx.seq, t);
    applyRefused(fx.project, again, EditError::TransitionNotFound);
}

TEST_CASE("SetTransitionDuration refuses a length the handles cannot cover") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 1730); // 10 frames after its out point
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    const TransitionId t = fx.addTransition(fx.v1, a, b, 20); // needs 10 after the cut
    fx.requireValid();
    SetTransitionDuration longer(fx.seq, t, f30(22));
    applyRefused(fx.project, longer, EditError::InsufficientHandles);
    lockTrack(fx, fx.v1);
    SetTransitionDuration locked(fx.seq, t, f30(10));
    applyRefused(fx.project, locked, EditError::TrackLocked);
}

TEST_CASE("Edits that break a cut remove its transition; undo restores it") {
    CutFixture fx;
    const TransitionId t = fx.addTransition(fx.v1, fx.a, fx.b, 10);
    fx.requireValid();
    SUBCASE("trimming the outgoing clip away from the cut") {
        TrimClipTail trim(fx.seq, fx.a, f30(50));
        applyReversible(fx.project, trim);
        CHECK(fx.sequence().findTransition(t) == nullptr);
    }
    SUBCASE("removing a clip") {
        RemoveClips remove(fx.seq, {fx.b});
        applyReversible(fx.project, remove);
        CHECK(fx.sequence().transitions.empty());
    }
    SUBCASE("ripple delete keeps transitions whose clips stay adjacent") {
        const ClipId c = fx.addClip(fx.v1, fx.av30, 150, 30, 900);
        RippleDelete ripple(fx.seq, {c});
        applyReversible(fx.project, ripple);
        CHECK(fx.sequence().findTransition(t) != nullptr);
    }
    SUBCASE("trimming the incoming clip's head shortens its handle below the transition") {
        TrimClipHead trim(fx.seq, fx.b, f30(70));
        applyReversible(fx.project, trim);
        CHECK(fx.sequence().transitions.empty());
    }
    SUBCASE("unrelated edits keep it") {
        SetVideoParams params(fx.seq, fx.a, VideoParams{1, 2, 1, 0, 0.5});
        applyReversible(fx.project, params);
        CHECK(fx.sequence().findTransition(t) != nullptr);
    }
}

// ---------------------------------------------------------------------------------------------
// Links

TEST_CASE("LinkClips and UnlinkClip") {
    Fixture fx;
    const ClipId v = fx.addClip(fx.v1, fx.av30, 0, 30);
    const ClipId a = fx.addClip(fx.a1, fx.av30, 0, 30);
    const ClipId other = fx.addClip(fx.v1, fx.av30, 30, 30);
    const ClipId audio2 = fx.addClip(fx.a2, fx.audioOnly, 0, 30);

    LinkClips link(fx.seq, v, a);
    applyReversible(fx.project, link);
    CHECK(fx.clip(v).linkedClipId == a);
    CHECK(fx.clip(a).linkedClipId == v);

    {
        LinkClips self(fx.seq, v, v);
        applyRefused(fx.project, self, EditError::InvalidArgument);
        LinkClips sameTrack(fx.seq, other, v);
        applyRefused(fx.project, sameTrack, EditError::InvalidArgument);
        LinkClips already(fx.seq, v, audio2);
        applyRefused(fx.project, already, EditError::AlreadyLinked);
        LinkClips missing(fx.seq, other, ClipId{999});
        applyRefused(fx.project, missing, EditError::ClipNotFound);
    }

    UnlinkClip unlink(fx.seq, a);
    applyReversible(fx.project, unlink);
    CHECK_FALSE(fx.clip(v).linkedClipId.has_value());
    CHECK_FALSE(fx.clip(a).linkedClipId.has_value());

    UnlinkClip again(fx.seq, a);
    applyRefused(fx.project, again, EditError::NotLinked);

    lockTrack(fx, fx.a2);
    LinkClips locked(fx.seq, other, audio2);
    applyRefused(fx.project, locked, EditError::TrackLocked);
}

// ---------------------------------------------------------------------------------------------
// Tracks

TEST_CASE("AddTrack inserts named tracks at an index") {
    Fixture fx;
    AddTrack top(fx.seq, TrackKind::Video);
    applyReversible(fx.project, top);
    REQUIRE(fx.sequence().videoTracks.size() == 3);
    CHECK(fx.sequence().videoTracks[2].id == top.createdTrackId());
    CHECK(fx.sequence().videoTracks[2].name == "V3");

    AddTrack bottom(fx.seq, TrackKind::Audio, "Music", 0);
    applyReversible(fx.project, bottom);
    CHECK(fx.sequence().audioTracks[0].id == bottom.createdTrackId());
    CHECK(fx.sequence().audioTracks[0].name == "Music");
    CHECK(fx.sequence().audioTracks[0].kind == TrackKind::Audio);

    AddTrack outOfRange(fx.seq, TrackKind::Video, "", 7);
    applyRefused(fx.project, outOfRange, EditError::InvalidArgument);
}

TEST_CASE("RemoveTrack removes clips and transitions and unlinks partners") {
    CutFixture fx;
    const ClipId audio = fx.addClip(fx.a1, fx.av30, 0, 60, 30);
    fx.link(fx.a, audio);
    fx.addTransition(fx.v1, fx.a, fx.b, 10);
    fx.requireValid();

    RemoveTrack remove(fx.seq, fx.v1);
    applyReversible(fx.project, remove);
    CHECK(fx.sequence().videoTracks.size() == 1);
    CHECK(fx.sequence().videoTracks[0].id == fx.v2);
    CHECK(fx.sequence().transitions.empty());
    CHECK_FALSE(fx.clip(audio).linkedClipId.has_value());

    RemoveTrack missing(fx.seq, TrackId{999});
    applyRefused(fx.project, missing, EditError::TrackNotFound);
    lockTrack(fx, fx.a1);
    RemoveTrack locked(fx.seq, fx.a1);
    applyRefused(fx.project, locked, EditError::TrackLocked);
}

TEST_CASE("SetTrackFlags works on locked tracks and unlocking re-enables edits") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 0, 30);
    SetTrackFlags lock(fx.seq, fx.v1, TrackFlagsUpdate{true, std::nullopt, true, std::string("Main")});
    applyReversible(fx.project, lock);
    CHECK(fx.track(fx.v1).muted);
    CHECK_FALSE(fx.track(fx.v1).solo);
    CHECK(fx.track(fx.v1).locked);
    CHECK(fx.track(fx.v1).name == "Main");

    MoveClip blocked(fx.seq, c, fx.v1, f30(10));
    applyRefused(fx.project, blocked, EditError::TrackLocked);

    SetTrackFlags unlock(fx.seq, fx.v1, TrackFlagsUpdate{std::nullopt, true, false, std::nullopt});
    applyReversible(fx.project, unlock);
    CHECK(fx.track(fx.v1).muted); // untouched
    CHECK(fx.track(fx.v1).solo);
    CHECK_FALSE(fx.track(fx.v1).locked);

    MoveClip allowed(fx.seq, c, fx.v1, f30(10));
    applyReversible(fx.project, allowed);

    SetTrackFlags missing(fx.seq, TrackId{999}, TrackFlagsUpdate{});
    applyRefused(fx.project, missing, EditError::TrackNotFound);
}

namespace {

// V1: A [0,60) source 30.., B [60,120) source 300..; A1: their linked audio (same times and
// sources); a 10-frame dissolve on V1 and a 16-frame crossfade on A1.
struct LinkedPairFixture : Fixture {
    ClipId a, b, aa, ba;
    TransitionId dissolve, crossfade;
    LinkedPairFixture() {
        a = addClip(v1, av30, 0, 60, 30);
        b = addClip(v1, av30, 60, 60, 300);
        aa = addClip(a1, av30, 0, 60, 30);
        ba = addClip(a1, av30, 60, 60, 300);
        link(a, aa);
        link(b, ba);
        dissolve = addTransition(v1, a, b, 10);
        crossfade = addTransition(a1, aa, ba, 16);
        requireValid();
    }
};

} // namespace

TEST_CASE("linkedTransition finds the transition on the linked partners' cut, either way round") {
    LinkedPairFixture fx;
    CHECK(linkedTransition(fx.sequence(), fx.dissolve) == fx.crossfade);
    CHECK(linkedTransition(fx.sequence(), fx.crossfade) == fx.dissolve);
    CHECK_FALSE(linkedTransition(fx.sequence(), TransitionId{999}).has_value());
    SUBCASE("no transition on the partners' cut") {
        std::erase_if(fx.sequence().transitions, [&](const Transition &t) { return t.id == fx.crossfade; });
        CHECK_FALSE(linkedTransition(fx.sequence(), fx.dissolve).has_value());
    }
    SUBCASE("an unlinked clip") {
        fx.sequence().findClip(fx.b)->linkedClipId.reset();
        fx.sequence().findClip(fx.ba)->linkedClipId.reset();
        CHECK_FALSE(linkedTransition(fx.sequence(), fx.dissolve).has_value());
        CHECK_FALSE(linkedTransition(fx.sequence(), fx.crossfade).has_value());
    }
}

TEST_CASE("RemoveTransitions removes a linked pair as one reversible step") {
    LinkedPairFixture fx;
    RemoveTransitions both(fx.seq, {fx.dissolve, fx.crossfade});
    CHECK(both.name() == "Remove Transitions");
    applyReversible(fx.project, both);
    CHECK(fx.sequence().transitions.empty());
    SUBCASE("refused as a whole") {
        LinkedPairFixture other;
        RemoveTransitions missing(other.seq, {other.dissolve, TransitionId{999}});
        applyRefused(other.project, missing, EditError::TransitionNotFound);
        lockTrack(other, other.a1);
        RemoveTransitions locked(other.seq, {other.dissolve, other.crossfade});
        applyRefused(other.project, locked, EditError::TrackLocked);
        RemoveTransitions none(other.seq, {});
        applyRefused(other.project, none, EditError::InvalidArgument);
    }
}

TEST_CASE("SetTransitionDurations resizes a linked pair as one step and refuses it as a whole") {
    LinkedPairFixture fx;
    SetTransitionDurations both(fx.seq, {{fx.dissolve, f30(20)}, {fx.crossfade, f30(24)}});
    CHECK(both.name() == "Change Transition Durations");
    applyReversible(fx.project, both);
    CHECK(fx.sequence().findTransition(fx.dissolve)->duration == f30(20));
    CHECK(fx.sequence().findTransition(fx.crossfade)->duration == f30(24));

    // One of them too long for its clips: nothing changes.
    SetTransitionDurations tooLong(fx.seq, {{fx.dissolve, f30(30)}, {fx.crossfade, f30(122)}});
    applyRefused(fx.project, tooLong, EditError::InvalidArgument);
    CHECK(fx.sequence().findTransition(fx.dissolve)->duration == f30(20));

    SUBCASE("successive steps merge (an Accumulate group of nudges)") {
        SetTransitionDurations first(fx.seq, {{fx.dissolve, f30(22)}, {fx.crossfade, f30(22)}});
        SetTransitionDurations second(fx.seq, {{fx.dissolve, f30(24)}, {fx.crossfade, f30(24)}});
        REQUIRE(first.apply(fx.project));
        REQUIRE(second.apply(fx.project));
        CHECK(first.mergeWith(second));
        first.revert(fx.project);
        CHECK(fx.sequence().findTransition(fx.dissolve)->duration == f30(20));
        CHECK(fx.sequence().findTransition(fx.crossfade)->duration == f30(24));
    }
}

TEST_CASE("isThroughEdit: a plain split versus cuts between different media") {
    Fixture fx;
    // A [0,60) source 30.., B [60,120) source 90..: B continues where A stops.
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 90);
    fx.requireValid();
    CHECK(isThroughEdit(fx.sequence(), a, b));
    CHECK_FALSE(isThroughEdit(fx.sequence(), b, a));
    SUBCASE("a slipped side") {
        fx.sequence().findClip(b)->sourceIn = f30(91);
        CHECK_FALSE(isThroughEdit(fx.sequence(), a, b));
    }
    SUBCASE("different media") {
        fx.sequence().findClip(b)->assetId = fx.av24;
        CHECK_FALSE(isThroughEdit(fx.sequence(), a, b));
    }
    SUBCASE("a different speed") {
        fx.sequence().findClip(b)->speed = Ratio{2, 1};
        CHECK_FALSE(isThroughEdit(fx.sequence(), a, b));
    }
    SUBCASE("different picture parameters show through the dissolve") {
        fx.sequence().findClip(b)->video.scale = 1.5;
        CHECK_FALSE(isThroughEdit(fx.sequence(), a, b));
    }
    SUBCASE("two copies of one still") {
        const ClipId s1 = fx.addClip(fx.v2, fx.still, 0, 60);
        const ClipId s2 = fx.addClip(fx.v2, fx.still, 60, 60);
        CHECK(isThroughEdit(fx.sequence(), s1, s2));
    }
}
