#include "ModelFixtures.h"

#include <cmath>

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

TEST_CASE("Model: the timeline duration is authoritative; source times derive from it and speed") {
    Clip clip;
    clip.sourceIn = CMTimeMake(600, 600);
    clip.timelineDuration = CMTimeMake(10, 1);
    CHECK(clip.duration() == CMTimeMake(10, 1));
    CHECK(clip.sourceOut() == CMTimeMake(11, 1));
    clip.speed = Ratio{2, 1};
    CHECK(clip.sourceDuration() == CMTimeMake(20, 1));
    CHECK(clip.sourceOut() == CMTimeMake(21, 1));
    clip.speed = Ratio{1, 3};
    CHECK(clip.sourceOut() == CMTimeMake(1 * 3 + 10, 3)); // 1 s + 10/3 s

    clip.speed = Ratio{2, 1};
    clip.timelineStart = CMTimeMake(3, 1);
    clip.timelineDuration = CMTimeMake(5, 1);
    CHECK(clip.timelineEnd() == CMTimeMake(8, 1));
    CHECK(clip.sourceTimeAt(CMTimeMake(4, 1)) == CMTimeMake(3, 1)); // 1 s in -> 2 s of source past 1 s
    CHECK(clip.timelineTimeAt(CMTimeMake(3, 1)) == CMTimeMake(4, 1));
    CHECK(clip.sourceTimeAt(CMTimeMake(2, 1)) == CMTimeMake(-1, 1)); // handles before the clip

    REQUIRE(clip.setTimelineStartKeepingEnd(CMTimeMake(5, 1)));
    CHECK(clip.timelineEnd() == CMTimeMake(8, 1));
    CHECK(clip.sourceIn == CMTimeMake(5, 1));
    REQUIRE(clip.setTimelineEnd(CMTimeMake(7, 1)));
    CHECK(clip.sourceOut() == CMTimeMake(9, 1));
    CHECK(clip.duration() == CMTimeMake(2, 1));
}

TEST_CASE("Model: derived source times are exact even when no CMTime can hold them") {
    // A 44.1 kHz in point at 999/1000 speed on a 29.97 timeline: the exact out point needs a
    // timescale of 4.41e9 > 2^31 - 1. The model stores only representable times and derives the
    // rest exactly.
    Clip clip;
    clip.timelineStart = CMTimeMake(1001 * 7, 30000);
    clip.timelineDuration = CMTimeMake(1001 * 13, 30000);
    clip.sourceIn = CMTimeMake(44101, 44100);
    clip.speed = Ratio{999, 1000};
    const auto out = clip.exactSourceOut();
    REQUIRE(out.has_value());
    // 44101/44100 + 13 * 1001/30000 * 999/1000, reduced.
    const auto expected = ExactTime::fraction(static_cast<Int128>(44101) * 10000000 + static_cast<Int128>(13) * 333333 * 44100,
                                              static_cast<Int128>(44100) * 10000000);
    REQUIRE(expected.has_value());
    CHECK(*out == *expected);
    CHECK_FALSE(out->toTime().has_value());
    const CMTime display = clip.sourceOut();
    CHECK(isRounded(display));
    CHECK(std::fabs(CMTimeGetSeconds(display) - out->toDouble()) < 2e-9);
    // Mapping back lands exactly on the clip's end.
    const auto end = clip.exactTimelineTimeAt(display);
    REQUIRE(end.has_value());
    CHECK(clip.exactSourceTimeAt(clip.timelineEnd()) == out);

    // A trim whose new in point would need that timescale is refused rather than rounded.
    Clip trimmed = clip;
    CHECK_FALSE(trimmed.setTimelineStartKeepingEnd(CMTimeMake(1001 * 8, 30000)));
    CHECK(trimmed == clip);
}

TEST_CASE("Model: fades shrink to fit when a clip gets shorter") {
    Clip clip;
    clip.timelineDuration = CMTimeMake(30, 30);
    clip.audio.fadeInDuration = CMTimeMake(20, 30);
    clip.audio.fadeOutDuration = CMTimeMake(10, 30);
    REQUIRE(clip.setTimelineEnd(CMTimeMake(25, 30)));
    CHECK(clip.audio.fadeInDuration == CMTimeMake(20, 30));
    CHECK(clip.audio.fadeOutDuration == CMTimeMake(5, 30)); // the edited edge gives way
    REQUIRE(clip.setTimelineStartKeepingEnd(CMTimeMake(10, 30)));
    CHECK(clip.duration() == CMTimeMake(15, 30));
    CHECK(clip.audio.fadeOutDuration == CMTimeMake(5, 30));
    CHECK(clip.audio.fadeInDuration == CMTimeMake(10, 30));
    REQUIRE(clip.setTimelineEnd(CMTimeMake(13, 30)));
    CHECK(clip.audio.fadeInDuration == CMTimeMake(3, 30)); // each fade at most the duration
    CHECK(clip.audio.fadeOutDuration == kCMTimeZero);
}

TEST_CASE("Model: still clips measure their source range in timeline time") {
    Clip still;
    still.isStill = true;
    still.sourceIn = kCMTimeZero;
    still.timelineDuration = defaultStillDuration();
    still.timelineStart = CMTimeMake(2, 1);
    CHECK(still.duration() == CMTimeMake(5, 1));
    CHECK(still.sourceOut() == CMTimeMake(5, 1));
    REQUIRE(still.setTimelineStartKeepingEnd(CMTimeMake(1, 1)));
    CHECK(still.sourceIn == kCMTimeZero);
    CHECK(still.duration() == CMTimeMake(6, 1));
    CHECK(still.timelineEnd() == CMTimeMake(7, 1));
    REQUIRE(still.setTimelineEnd(CMTimeMake(3, 1)));
    CHECK(still.duration() == CMTimeMake(2, 1));
    CHECK(still.speedRatio() == Ratio{1, 1});
}

TEST_CASE("Model: speeds are exact reduced ratios within [1/100, 100]") {
    CHECK(isValidSpeed(Ratio{1, 1}));
    CHECK(isValidSpeed(Ratio{999, 1000}));
    CHECK(isValidSpeed(Ratio{1, 100}));
    CHECK(isValidSpeed(Ratio{100, 1}));
    CHECK_FALSE(isValidSpeed(Ratio{1, 101}));
    CHECK_FALSE(isValidSpeed(Ratio{101, 1}));
    CHECK_FALSE(isValidSpeed(Ratio{2, 2}));      // not reduced
    CHECK_FALSE(isValidSpeed(Ratio{1, 1001}));   // denominator too large
    CHECK_FALSE(isValidSpeed(Ratio{0, 1}));
    CHECK_FALSE(isValidSpeed(Ratio{-1, 2}));
    CHECK(speedFromDouble(0.999) == Ratio{999, 1000});
    CHECK(speedFromDouble(1.0 / 3.0) == Ratio{1, 3});
    CHECK(speedFromDouble(0.3337) == Ratio{303, 908});
    CHECK_FALSE(isValidSpeed(speedFromDouble(NAN)));
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
    auto expectProblem = [](const Fixture &fx, const std::string &needle) {
        const std::string problem = problemOf(fx.project);
        CHECK_MESSAGE(problem.find(needle) != std::string::npos,
                      doctest::String(("expected \"" + needle + "\", got \"" + problem + "\"").c_str()));
    };
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
        expectProblem(fx, "not reciprocated");
    }
    SUBCASE("link to itself, to a missing clip, on the same track") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
        fx.sequence().findClip(a)->linkedClipId = a;
        expectProblem(fx, "linked to itself");
        fx.sequence().findClip(a)->linkedClipId = ClipId{999};
        expectProblem(fx, "linked to missing");
        const ClipId b = fx.addClip(fx.v1, fx.av30, 30, 30);
        fx.link(a, b);
        expectProblem(fx, "on the same track");
    }
    SUBCASE("clip duration off the frame grid") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
        fx.sequence().findClip(a)->timelineDuration = CMTimeMake(601, 600);
        expectProblem(fx, "not a whole number of frames");
    }
    SUBCASE("clip start off the frame grid") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
        fx.sequence().findClip(a)->timelineStart = CMTimeMake(1, 600);
        expectProblem(fx, "not on the sequence frame grid");
    }
    SUBCASE("negative start or source in point") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
        fx.sequence().findClip(a)->timelineStart = f30(-1);
        expectProblem(fx, "starts before zero");
        fx.sequence().findClip(a)->timelineStart = f30(0);
        fx.sequence().findClip(a)->sourceIn = f30(-1);
        expectProblem(fx, "before the start of the media");
    }
    SUBCASE("zero or negative duration") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
        fx.sequence().findClip(a)->timelineDuration = kCMTimeZero;
        expectProblem(fx, "is not positive");
    }
    SUBCASE("source past the end of the media") {
        Fixture fx;
        fx.addClip(fx.v1, fx.av30, 0, 30, 60 * 30 - 10);
        expectProblem(fx, "past the end");
    }
    SUBCASE("source past the end at a speed, compared exactly") {
        Fixture fx;
        // Source 1790 + 10 * 999/1000 frames ends 0.01 frames before the media end.
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 10, 1790, 0.999);
        fx.requireValid();
        fx.sequence().findClip(a)->speed = Ratio{1001, 1000};
        expectProblem(fx, "past the end");
    }
    SUBCASE("speeds") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
        for (const Ratio bad : {Ratio{0, 1}, Ratio{2, 2}, Ratio{1, 1001}, Ratio{1, 101}, Ratio{101, 1}}) {
            fx.sequence().findClip(a)->speed = bad;
            expectProblem(fx, "speed");
        }
    }
    SUBCASE("still with a speed or an in point") {
        Fixture fx;
        const ClipId s = fx.addClip(fx.v1, fx.still, 0, 30);
        fx.sequence().findClip(s)->speed = Ratio{2, 1};
        expectProblem(fx, "still clips must have speed 1");
        fx.sequence().findClip(s)->speed = Ratio{1, 1};
        fx.sequence().findClip(s)->sourceIn = f30(1);
        expectProblem(fx, "still clips must have sourceIn 0");
        fx.sequence().findClip(s)->sourceIn = kCMTimeZero;
        fx.sequence().findClip(s)->isStill = false;
        expectProblem(fx, "still asset but clip is not marked still");
    }
    SUBCASE("non-finite or out-of-range video parameters, non-finite gain, bad fades") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.a1, fx.av30, 0, 30);
        Clip &clip = *fx.sequence().findClip(a);
        clip.video.opacity = NAN;
        expectProblem(fx, "non-finite video parameter");
        clip.video.opacity = 1.5;
        expectProblem(fx, "opacity");
        clip.video.opacity = 1;
        clip.video.scale = -1;
        expectProblem(fx, "scale");
        clip.video.scale = 1;
        clip.audio.gainDb = INFINITY;
        expectProblem(fx, "non-finite gain");
        clip.audio.gainDb = 0;
        clip.audio.fadeInDuration = f30(-1);
        expectProblem(fx, "negative");
        clip.audio.fadeInDuration = f30(31);
        expectProblem(fx, "longer than the clip");
        clip.audio.fadeInDuration = f30(20);
        clip.audio.fadeOutDuration = f30(11);
        expectProblem(fx, "overlap");
        clip.audio.fadeOutDuration = f30(10);
        fx.requireValid(); // fades may meet exactly
        clip.audio.fadeOutDuration = kCMTimeInvalid;
        expectProblem(fx, "not a numeric time");
    }
    SUBCASE("rounded times and epochs are rejected everywhere") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.a1, fx.av30, 0, 30);
        const ClipId b = fx.addClip(fx.a1, fx.av30, 30, 30, 300);
        fx.addTransition(fx.a1, a, b, 4);
        fx.requireValid();
        auto withRound = [](CMTime t) {
            t.flags |= kCMTimeFlags_HasBeenRounded;
            return t;
        };
        auto withEpoch = [](CMTime t) {
            t.epoch = 1;
            return t;
        };
        for (auto modify : {+withRound, +withEpoch}) {
            for (int field = 0; field < 9; ++field) {
                Fixture copy = fx;
                Clip &clip = *copy.sequence().findClip(a);
                switch (field) {
                case 0: clip.timelineStart = modify(clip.timelineStart); break;
                case 1: clip.timelineDuration = modify(clip.timelineDuration); break;
                case 2: clip.sourceIn = modify(clip.sourceIn); break;
                case 3: clip.audio.fadeInDuration = modify(clip.audio.fadeInDuration); break;
                case 4: clip.audio.fadeOutDuration = modify(clip.audio.fadeOutDuration); break;
                case 5: copy.sequence().transitions[0].duration = modify(copy.sequence().transitions[0].duration); break;
                case 6: copy.sequence().frameDuration = modify(copy.sequence().frameDuration); break;
                case 7: copy.project.findAsset(copy.av30)->duration = modify(copy.project.findAsset(copy.av30)->duration); break;
                default:
                    copy.project.findAsset(copy.av30)->frameDuration =
                        modify(copy.project.findAsset(copy.av30)->frameDuration);
                    break;
                }
                CAPTURE(field);
                CHECK_FALSE(problemOf(copy.project).empty());
            }
        }
        // An overlapping clip with a different epoch does not hide behind CMTimeCompare's
        // epoch-first ordering.
        Fixture overlap;
        overlap.addClip(overlap.v1, overlap.av30, 0, 30);
        const ClipId late = overlap.addClip(overlap.v1, overlap.av30, 10, 30);
        overlap.sequence().findClip(late)->timelineStart.epoch = 1;
        CHECK_FALSE(problemOf(overlap.project).empty());
    }
    SUBCASE("audio-only asset on a video track") {
        Fixture fx;
        fx.addClip(fx.v1, fx.audioOnly, 0, 30);
        expectProblem(fx, "audio asset on a video track");
    }
    SUBCASE("asset checks") {
        Fixture fx;
        MediaAsset &av = *fx.project.findAsset(fx.av30);
        av.duration = kCMTimeZero;
        expectProblem(fx, "duration");
        av.duration = CMTimeMake(60, 1);
        av.frameDuration = kCMTimeInvalid;
        expectProblem(fx, "frame duration");
        av.isVFR = true;
        fx.requireValid(); // VFR video may leave the nominal frame duration out
        av.isVFR = false;
        av.frameDuration = CMTimeMake(0, 600);
        expectProblem(fx, "frame duration");
        av.frameDuration = CMTimeMake(20, 600);
        av.width = 0;
        expectProblem(fx, "frame size");
        av.width = 1920;
        av.audioSampleRate = 0;
        expectProblem(fx, "sample rate");
        av.audioSampleRate = 48000;
        av.audioChannels = 0;
        expectProblem(fx, "channel");
        av.audioChannels = 2;
        av.url.clear();
        expectProblem(fx, "empty URL");
        av.url = "/a.mov";
        av.rotationDegrees = 45;
        expectProblem(fx, "rotation");
        av.rotationDegrees = 270;
        fx.requireValid();
        MediaAsset &still = *fx.project.findAsset(fx.still);
        still.duration = CMTimeMake(5, 1);
        expectProblem(fx, "a still has no duration");
        still.duration = kCMTimeInvalid;
        still.height = -1;
        expectProblem(fx, "frame size");
        still.height = 1080;
        CMTime nonCanonical = kCMTimeInvalid;
        nonCanonical.value = 7;
        still.duration = nonCanonical;
        expectProblem(fx, "non-zero fields");
        still.duration = kCMTimeInvalid;
        MediaAsset &audio = *fx.project.findAsset(fx.audioOnly);
        audio.audioChannels = -2;
        expectProblem(fx, "channel");
    }
    SUBCASE("sequence checks") {
        Fixture fx;
        fx.sequence().frameDuration = kCMTimeZero;
        expectProblem(fx, "frame duration");
        fx.sequence().frameDuration = CMTimeMake(1, 30);
        fx.sequence().width = 0;
        expectProblem(fx, "frame size");
        fx.sequence().width = 1920;
        fx.sequence().audioSampleRate = 0;
        expectProblem(fx, "sample rate");
    }
    SUBCASE("track in the wrong list, duplicate ids") {
        Fixture fx;
        fx.sequence().videoTracks[0].kind = TrackKind::Audio;
        expectProblem(fx, "wrong track list");
        Fixture dup;
        const ClipId a = dup.addClip(dup.v1, dup.av30, 0, 30);
        const ClipId b = dup.addClip(dup.v1, dup.av30, 30, 30);
        dup.sequence().findTrack(dup.v1)->clips[1].id = a;
        (void)b;
        expectProblem(dup, "used more than once");
    }
    SUBCASE("id generator behind ids in use") {
        Fixture fx;
        fx.project.ids = IdGenerator(3);
        expectProblem(fx, "id generator");
    }
    SUBCASE("duplicate ids across kinds") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30);
        fx.sequence().findClip(a)->id = ClipId{fx.v2.value()};
        expectProblem(fx, "used more than once");
    }
    SUBCASE("transition without handles") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 60 * 30 - 60); // ends at the media end
        const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
        fx.addTransition(fx.v1, a, b, 10);
        expectProblem(fx, "lacks media after");
    }
    SUBCASE("transition not adjacent, too long, bad duration, duplicated on a cut, unknown track") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
        const ClipId b = fx.addClip(fx.v1, fx.av30, 61, 60, 300);
        fx.addTransition(fx.v1, a, b, 10);
        expectProblem(fx, "are not adjacent");
        fx.sequence().findClip(b)->timelineStart = f30(60);
        fx.requireValid();
        fx.sequence().transitions[0].duration = f30(130);
        expectProblem(fx, "longer than the clips");
        fx.sequence().transitions[0].duration = CMTimeMake(1, 60);
        expectProblem(fx, "whole number of frames");
        fx.sequence().transitions[0].duration = kCMTimeZero;
        expectProblem(fx, "whole number of frames");
        fx.sequence().transitions[0].duration = f30(10);
        fx.addTransition(fx.v1, a, b, 4);
        expectProblem(fx, "more than one transition");
        fx.sequence().transitions.pop_back();
        fx.sequence().transitions[0].trackId = TrackId{999};
        expectProblem(fx, "unknown track");
        fx.sequence().transitions[0].trackId = fx.v1;
        fx.sequence().transitions[0].toClipId = a;
        expectProblem(fx, "joins a clip to itself");
    }
    SUBCASE("overlapping transitions on one clip") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30, 100);
        const ClipId b = fx.addClip(fx.v1, fx.av30, 30, 10, 300);
        const ClipId c = fx.addClip(fx.v1, fx.av30, 40, 30, 500);
        fx.addTransition(fx.v1, a, b, 12);
        fx.addTransition(fx.v1, b, c, 12);
        expectProblem(fx, "overlap");
    }
    SUBCASE("missing active sequence") {
        Fixture fx;
        fx.project.activeSequenceId = SequenceId{999};
        expectProblem(fx, "active sequence");
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
