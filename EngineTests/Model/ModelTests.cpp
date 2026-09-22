#include "ModelFixtures.h"

using namespace vetest;

TEST_CASE("Model: ids are strongly typed, ordered and hashable") {
    IdGenerator generator;
    const ClipId a = generator.make<ClipId>();
    const TrackId b = generator.make<TrackId>();
    CHECK(a.value() == 1);
    CHECK(b.value() == 2);
    CHECK(a.isValid());
    CHECK_FALSE(ClipId{}.isValid());
    CHECK(ClipId{3} < ClipId{4});
    CHECK(std::hash<ClipId>{}(ClipId{9}) == std::hash<std::uint64_t>{}(9));
    generator.reserveThrough(10);
    CHECK(generator.nextValue() == 11);
    generator.reserveThrough(5);
    CHECK(generator.nextValue() == 11);
    CHECK(IdGenerator(0).nextValue() == 1);
}

TEST_CASE("Model: clip duration derives from source range and speed") {
    Clip clip;
    clip.sourceIn = CMTimeMake(600, 600);
    clip.sourceOut = CMTimeMake(6600, 600); // 10 s of source
    CHECK(clip.duration() == CMTimeMake(10, 1));
    clip.speed = 2.0;
    CHECK(clip.duration() == CMTimeMake(5, 1));
    clip.speed = 0.5;
    CHECK(clip.duration() == CMTimeMake(20, 1));
    clip.speed = 1.0 / 3.0;
    CHECK(clip.duration() == CMTimeMake(30, 1));

    clip.speed = 2.0;
    clip.timelineStart = CMTimeMake(3, 1);
    CHECK(clip.timelineEnd() == CMTimeMake(8, 1));
    CHECK(clip.sourceTimeAt(CMTimeMake(4, 1)) == CMTimeMake(3, 1)); // 1 s in -> 2 s of source past 1 s
    CHECK(clip.timelineTimeAt(CMTimeMake(3, 1)) == CMTimeMake(4, 1));
    CHECK(clip.sourceTimeAt(CMTimeMake(2, 1)) == CMTimeMake(-1, 1)); // handles before the clip

    clip.setTimelineStartKeepingEnd(CMTimeMake(5, 1));
    CHECK(clip.timelineEnd() == CMTimeMake(8, 1));
    CHECK(clip.sourceIn == CMTimeMake(5, 1));
    clip.setTimelineEnd(CMTimeMake(7, 1));
    CHECK(clip.sourceOut == CMTimeMake(9, 1));
    CHECK(clip.duration() == CMTimeMake(2, 1));
}

TEST_CASE("Model: still clips measure their source range in timeline time") {
    Clip still;
    still.isStill = true;
    still.speed = 1.0;
    still.sourceIn = kCMTimeZero;
    still.sourceOut = defaultStillDuration();
    still.timelineStart = CMTimeMake(2, 1);
    CHECK(still.duration() == CMTimeMake(5, 1));
    still.setTimelineStartKeepingEnd(CMTimeMake(1, 1));
    CHECK(still.sourceIn == kCMTimeZero);
    CHECK(still.duration() == CMTimeMake(6, 1));
    CHECK(still.timelineEnd() == CMTimeMake(7, 1));
    still.setTimelineEnd(CMTimeMake(3, 1));
    CHECK(still.duration() == CMTimeMake(2, 1));
}

TEST_CASE("Model: track lookup by time and invariant checks") {
    Fixture fx;
    const ClipId c1 = fx.addClip(fx.v1, fx.av30, 0, 30);
    const ClipId c2 = fx.addClip(fx.v1, fx.av30, 60, 30);
    const ClipId c3 = fx.addClip(fx.v1, fx.av30, 90, 10);
    fx.requireValid();
    const Track &track = fx.track(fx.v1);
    CHECK(track.clipAt(f30(0))->id == c1);
    CHECK(track.clipAt(f30(29))->id == c1);
    CHECK(track.clipAt(f30(30)) == nullptr); // gap
    CHECK(track.clipAt(f30(59)) == nullptr);
    CHECK(track.clipAt(f30(60))->id == c2);
    CHECK(track.clipAt(f30(90))->id == c3); // touching clips: the later one owns the cut
    CHECK(track.clipAt(f30(100)) == nullptr);
    CHECK(track.clipAt(f30(-1)) == nullptr);
    CHECK(track.firstClipStartingAtOrAfter(f30(1)) == 1);
    CHECK(track.end() == f30(100));
    CHECK(fx.sequence().duration() == f30(100));
    CHECK_FALSE(track.checkInvariants().has_value());

    Track broken = track;
    broken.clips[1].timelineStart = f30(20);
    REQUIRE(broken.checkInvariants().has_value());
    CHECK(broken.checkInvariants()->find("overlaps") != std::string::npos);

    Track unsorted = track;
    std::swap(unsorted.clips[0], unsorted.clips[2]);
    CHECK(unsorted.checkInvariants().has_value());

    Track wrongTrack = track;
    wrongTrack.clips[0].trackId = fx.v2;
    CHECK(wrongTrack.checkInvariants().has_value());
}

TEST_CASE("Model: sequence lookups and transition ranges") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    const TransitionId t = fx.addTransition(fx.v1, a, b, 15);
    fx.requireValid();
    const Sequence &s = fx.sequence();
    const auto location = s.locateClip(b);
    REQUIRE(location.has_value());
    CHECK(location->trackKind == TrackKind::Video);
    CHECK(location->trackIndex == 0);
    CHECK(location->clipIndex == 1);
    CHECK(s.trackOfClip(a)->id == fx.v1);
    CHECK(s.findTransition(t)->fromClipId == a);
    CHECK(s.transitionFrom(a)->id == t);
    CHECK(s.transitionTo(b)->id == t);
    CHECK(s.transitionFrom(b) == nullptr);
    // 15 frames: 7 before the cut, 8 after.
    const auto range = s.transitionRange(*s.findTransition(t));
    REQUIRE(range.has_value());
    CHECK(range->start == f30(53));
    CHECK(range->end == f30(68));
    CHECK(s.transitionAt(fx.v1, f30(53))->id == t);
    CHECK(s.transitionAt(fx.v1, f30(68)) == nullptr);
    CHECK(s.transitionAt(fx.v2, f30(60)) == nullptr);
}

TEST_CASE("Model: validateProject catches broken invariants") {
    SUBCASE("valid fixture") {
        Fixture fx;
        fx.addLinkedPair(0, 30);
        fx.requireValid();
    }
    SUBCASE("unreciprocated link") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
        const ClipId b = fx.addClip(fx.a1, fx.av30, 0, 30);
        fx.sequence().findClip(a)->linkedClipId = b;
        CHECK(problemOf(fx.project).find("not reciprocated") != std::string::npos);
    }
    SUBCASE("clip end off the frame grid") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
        fx.sequence().findClip(a)->sourceOut = CMTimeMake(601, 600);
        CHECK(problemOf(fx.project).find("frame grid") != std::string::npos);
    }
    SUBCASE("source past the end of the media") {
        Fixture fx;
        fx.addClip(fx.v1, fx.av30, 0, 30, 60 * 30 - 10);
        CHECK(problemOf(fx.project).find("past the end") != std::string::npos);
    }
    SUBCASE("audio-only asset on a video track") {
        Fixture fx;
        fx.addClip(fx.v1, fx.audioOnly, 0, 30);
        CHECK(problemOf(fx.project).find("audio asset on a video track") != std::string::npos);
    }
    SUBCASE("id generator behind ids in use") {
        Fixture fx;
        fx.project.ids = IdGenerator(3);
        CHECK(problemOf(fx.project).find("id generator") != std::string::npos);
    }
    SUBCASE("duplicate ids across kinds") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
        fx.sequence().findClip(a)->id = ClipId{fx.v2.value()};
        CHECK(problemOf(fx.project).find("used more than once") != std::string::npos);
    }
    SUBCASE("transition without handles") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 60 * 30 - 60); // ends at the media end
        const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
        fx.addTransition(fx.v1, a, b, 10);
        CHECK(problemOf(fx.project).find("lacks media after") != std::string::npos);
    }
    SUBCASE("overlapping transitions on one clip") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30, 100);
        const ClipId b = fx.addClip(fx.v1, fx.av30, 30, 10, 300);
        const ClipId c = fx.addClip(fx.v1, fx.av30, 40, 30, 500);
        fx.addTransition(fx.v1, a, b, 12);
        fx.addTransition(fx.v1, b, c, 12);
        CHECK(problemOf(fx.project).find("overlap") != std::string::npos);
    }
    SUBCASE("missing active sequence") {
        Fixture fx;
        fx.project.activeSequenceId = SequenceId{999};
        CHECK(problemOf(fx.project).find("active sequence") != std::string::npos);
    }
}

TEST_CASE("Model: structural equality is bit-for-bit") {
    Fixture a;
    Fixture b;
    CHECK(a.project == b.project);
    b.project.assets[0].duration = CMTimeMake(60, 1); // same value, different timescale
    CHECK_FALSE(a.project == b.project);
    Fixture c;
    c.sequence().videoTracks[0].muted = true;
    CHECK_FALSE(a.project == c.project);
}
