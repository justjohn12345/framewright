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

    REQUIRE(clip.setTimelineStartKeepingEnd(CMTimeMake(5, 1)) == RetimeResult::Ok);
    CHECK(clip.timelineEnd() == CMTimeMake(8, 1));
    CHECK(clip.sourceIn == CMTimeMake(5, 1));
    REQUIRE(clip.setTimelineEnd(CMTimeMake(7, 1)) == RetimeResult::Ok);
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
    CHECK(trimmed.setTimelineStartKeepingEnd(CMTimeMake(1001 * 8, 30000)) == RetimeResult::NotRepresentable);
    CHECK(trimmed == clip);
}

TEST_CASE("Model: lane-0 fades shrink to fit when a clip gets shorter") {
    Clip clip;
    clip.timelineDuration = CMTimeMake(30, 30);
    EffectSpan in;
    in.id = SpanId{1};
    in.lane = kTransitionLane;
    in.kind = SpanKind::Transition;
    in.edge = ClipEdge::Head;
    in.end = CMTimeMake(20, 30);
    EffectSpan out = in;
    out.id = SpanId{2};
    out.edge = ClipEdge::Tail;
    out.start = CMTimeMake(-10, 30);
    out.end = kCMTimeZero;
    clip.spans = {in, out};
    REQUIRE(clip.setTimelineEnd(CMTimeMake(25, 30)) == RetimeResult::Ok);
    CHECK(clipFadeLength(clip, ClipEdge::Head) == CMTimeMake(20, 30));
    CHECK(clipFadeLength(clip, ClipEdge::Tail) == CMTimeMake(5, 30)); // the edited edge gives way
    REQUIRE(clip.setTimelineStartKeepingEnd(CMTimeMake(10, 30)) == RetimeResult::Ok);
    CHECK(clip.duration() == CMTimeMake(15, 30));
    CHECK(clipFadeLength(clip, ClipEdge::Tail) == CMTimeMake(5, 30));
    CHECK(clipFadeLength(clip, ClipEdge::Head) == CMTimeMake(10, 30));
    REQUIRE(clip.setTimelineEnd(CMTimeMake(13, 30)) == RetimeResult::Ok);
    CHECK(clipFadeLength(clip, ClipEdge::Head) == CMTimeMake(3, 30)); // each fade at most the duration
    CHECK(clipFadeLength(clip, ClipEdge::Tail) == kCMTimeZero);
    CHECK(clip.spans.size() == 1); // a fade shortened to nothing is removed
    SUBCASE("a fade gives way to a cross dissolve at the other end, whichever edge was edited") {
        Clip both;
        both.timelineDuration = CMTimeMake(30, 30);
        EffectSpan dissolve = out;
        dissolve.start = CMTimeMake(-12, 30);
        dissolve.end = CMTimeMake(12, 30);
        both.spans = {in, dissolve};
        REQUIRE(both.setTimelineEnd(CMTimeMake(28, 30)) == RetimeResult::Ok);
        CHECK(clipFadeLength(both, ClipEdge::Head) == CMTimeMake(16, 30));
        CHECK(both.transitionAt(ClipEdge::Tail)->start == CMTimeMake(-12, 30)); // never shortened here
    }
}

TEST_CASE("Model: still clips measure their source range in timeline time") {
    Clip still;
    still.isStill = true;
    still.sourceIn = kCMTimeZero;
    still.timelineDuration = defaultStillDuration();
    still.timelineStart = CMTimeMake(2, 1);
    CHECK(still.duration() == CMTimeMake(5, 1));
    CHECK(still.sourceOut() == CMTimeMake(5, 1));
    REQUIRE(still.setTimelineStartKeepingEnd(CMTimeMake(1, 1)) == RetimeResult::Ok);
    CHECK(still.sourceIn == kCMTimeZero);
    CHECK(still.duration() == CMTimeMake(6, 1));
    CHECK(still.timelineEnd() == CMTimeMake(7, 1));
    REQUIRE(still.setTimelineEnd(CMTimeMake(3, 1)) == RetimeResult::Ok);
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

TEST_CASE("Model: sequence lookups and transition placement") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    const SpanId t = fx.addTransition(fx.v1, a, b, 15);
    fx.requireValid();
    const Sequence &s = fx.sequence();
    const auto location = s.locateClip(b);
    REQUIRE(location.has_value());
    CHECK(location->trackKind == TrackKind::Video);
    CHECK(location->trackIndex == 0);
    CHECK(location->clipIndex == 1);
    CHECK(s.trackOfClip(a)->id == fx.v1);
    const Clip *owner = nullptr;
    const Track *track = nullptr;
    const EffectSpan *span = s.findSpan(t, &owner, &track);
    REQUIRE(span != nullptr);
    CHECK(owner->id == a);
    CHECK(track->id == fx.v1);
    CHECK(s.findSpan(SpanId{999}) == nullptr);
    CHECK(touchingClip(*track, fx.clip(a), ClipEdge::Tail)->id == b);
    CHECK(touchingClip(*track, fx.clip(b), ClipEdge::Head)->id == a);
    CHECK(touchingClip(*track, fx.clip(a), ClipEdge::Head) == nullptr);
    // 15 frames: 7 before the cut, 8 after.
    const auto placed = placeTransition(*track, *owner, *span);
    REQUIRE(placed.has_value());
    CHECK(placed->role == TransitionRole::CrossDissolve);
    CHECK(placed->partner->id == b);
    CHECK(placed->cut == f30(60));
    CHECK(placed->range.start == f30(53));
    CHECK(placed->range.end == f30(68));
    CHECK(transitionAt(*track, f30(53))->span->id == t);
    CHECK(transitionAt(*track, f30(59))->span->id == t);
    CHECK(transitionAt(*track, f30(60))->span->id == t); // the part over B, found from B
    CHECK(transitionAt(*track, f30(67))->span->id == t);
    CHECK_FALSE(transitionAt(*track, f30(68)).has_value());
    CHECK_FALSE(transitionAt(*track, f30(52)).has_value());
    CHECK_FALSE(transitionAt(*s.findTrack(fx.v2), f30(60)).has_value());
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
        auto fade = [](ClipEdge edge, CMTime start, CMTime end) {
            EffectSpan span;
            span.id = SpanId{edge == ClipEdge::Head ? 900u : 901u};
            span.lane = kTransitionLane;
            span.kind = SpanKind::Transition;
            span.edge = edge;
            span.start = start;
            span.end = end;
            return span;
        };
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
        fx.project.ids.reserveThrough(1000);
        clip.spans = {fade(ClipEdge::Head, kCMTimeZero, f30(-1))};
        expectProblem(fx, "is empty");
        clip.spans = {fade(ClipEdge::Head, kCMTimeZero, f30(31))};
        expectProblem(fx, "longer than its clip");
        clip.spans = {fade(ClipEdge::Head, kCMTimeZero, f30(20)), fade(ClipEdge::Tail, -f30(11), kCMTimeZero)};
        expectProblem(fx, "meets the fade in");
        clip.spans = {fade(ClipEdge::Head, kCMTimeZero, f30(20)), fade(ClipEdge::Tail, -f30(10), kCMTimeZero)};
        fx.requireValid(); // fades may meet exactly
        clip.spans = {fade(ClipEdge::Head, kCMTimeZero, f30(20)), fade(ClipEdge::Tail, kCMTimeInvalid, kCMTimeZero)};
        expectProblem(fx, "not a numeric time");
        clip.spans = {fade(ClipEdge::Tail, -f30(10), kCMTimeZero), fade(ClipEdge::Head, kCMTimeZero, f30(20))};
        expectProblem(fx, "lane and time order");
    }
    SUBCASE("rounded times and epochs are rejected everywhere") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.a1, fx.av30, 0, 30);
        const ClipId b = fx.addClip(fx.a1, fx.av30, 30, 30, 300);
        fx.addTransition(fx.a1, a, b, 4);
        SpanTracks gain;
        gain.gain = {key(kCMTimeZero, 0), key(f30(10), -6)};
        fx.addSpan(a, SpanKind::Gain, 1, f30(0), f30(10), gain);
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
            for (int field = 0; field < 10; ++field) {
                Fixture copy = fx;
                Clip &clip = *copy.sequence().findClip(a);
                EffectSpan &dissolve = *clip.transitionAt(ClipEdge::Tail);
                switch (field) {
                case 0: clip.timelineStart = modify(clip.timelineStart); break;
                case 1: clip.timelineDuration = modify(clip.timelineDuration); break;
                case 2: clip.sourceIn = modify(clip.sourceIn); break;
                case 3: dissolve.start = modify(dissolve.start); break;
                case 4: dissolve.end = modify(dissolve.end); break;
                case 5: copy.sequence().findClip(a)->spans[1].tracks.gain[1].time = modify(copy.sequence().findClip(a)->spans[1].tracks.gain[1].time); break;
                case 9: copy.sequence().findClip(a)->spans[1].end = modify(copy.sequence().findClip(a)->spans[1].end); break;
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
        fx.sequence().findClip(a)->sourceIn = f30(30);
        fx.sequence().findClip(b)->sourceIn = f30(4);
        expectProblem(fx, "lacks media before");
    }
    SUBCASE("transition not adjacent, too long, off the grid, duplicated on an edge, on the wrong lane") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
        const ClipId b = fx.addClip(fx.v1, fx.av30, 61, 60, 300);
        fx.addTailTransition(a, 5, 5);
        expectProblem(fx, "no clip touches that end");
        fx.sequence().findClip(b)->timelineStart = f30(60);
        fx.requireValid();
        EffectSpan &t = *fx.sequence().findClip(a)->transitionAt(ClipEdge::Tail);
        t.end = f30(61);
        expectProblem(fx, "longer than clip");
        t.end = f30(5);
        t.start = -f30(61);
        expectProblem(fx, "longer than its clip");
        t.start = -f30(5);
        t.end = CMTimeMake(1, 60);
        expectProblem(fx, "whole sequence frames");
        t.end = f30(5);
        t.start = kCMTimeZero;
        t.end = kCMTimeZero;
        expectProblem(fx, "is empty");
        t.start = f30(2);
        t.end = f30(5);
        expectProblem(fx, "starts at or before its clip's end");
        t.start = -f30(5);
        fx.requireValid();
        fx.addTailTransition(a, 2, 0);
        expectProblem(fx, "more than one transition at its tail");
        fx.sequence().findClip(a)->spans.pop_back();
        fx.sequence().findClip(a)->spans[0].lane = 1;
        expectProblem(fx, "lane 0 only");
        fx.sequence().findClip(a)->spans[0].lane = 0;
        fx.requireValid();
        fx.addSpan(a, SpanKind::Motion, 0, f30(30), f30(40));
        expectProblem(fx, "lane 0 holds transitions only");
    }
    SUBCASE("a fade in on a clip whose start another clip touches") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.a1, fx.av30, 0, 60, 30);
        const ClipId b = fx.addClip(fx.a1, fx.av30, 60, 60, 300);
        fx.addFade(b, ClipEdge::Head, f30(10));
        expectProblem(fx, "the cut belongs to that clip");
        fx.sequence().findClip(a)->timelineDuration = f30(59);
        fx.requireValid(); // a one-frame gap: nothing touches B any more
    }
    SUBCASE("overlapping transitions on one clip") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30, 100);
        const ClipId b = fx.addClip(fx.v1, fx.av30, 30, 10, 300);
        fx.addClip(fx.v1, fx.av30, 40, 30, 500);
        fx.addTransition(fx.v1, a, b, 12); // 6 frames into B
        fx.addTailTransition(b, 6, 6);     // 6 frames before B's end: they meet in B
        expectProblem(fx, "meets the transition at the end of clip");
    }
    SUBCASE("effect spans: lanes, kinds, ranges, tracks and overlap") {
        Fixture fx;
        const ClipId v = fx.addClip(fx.v1, fx.av30, 0, 60, 30); // source frames [30, 90)
        const ClipId a = fx.addClip(fx.a1, fx.av30, 0, 60, 30);
        SpanTracks motion;
        motion.x = {key(kCMTimeZero, 0), key(f30(30), 100)};
        const SpanId s = fx.addSpan(v, SpanKind::Motion, 1, f30(30), f30(60), motion);
        fx.requireValid();
        EffectSpan &span = *fx.sequence().findSpan(s);
        span.lane = 4;
        expectProblem(fx, "not an effect lane");
        span.lane = 1;
        span.start = f30(20);
        expectProblem(fx, "outside its clip's source range");
        span.start = f30(30);
        span.end = f30(91);
        expectProblem(fx, "outside its clip's source range");
        span.end = f30(60);
        span.tracks.x.push_back(key(f30(31), 1));
        expectProblem(fx, "within the span");
        span.tracks.x.pop_back();
        span.tracks.gain = {key(kCMTimeZero, 1)};
        expectProblem(fx, "has no Gain keyframes");
        span.tracks.gain.clear();
        span.tracks.scale = {key(kCMTimeZero, -1)};
        expectProblem(fx, "invalid value");
        span.tracks.scale.clear();
        fx.requireValid();
        fx.addSpan(v, SpanKind::Opacity, 1, f30(50), f30(70));
        expectProblem(fx, "overlap on lane 1");
        fx.sequence().findClip(v)->spans.back().lane = 2;
        fx.requireValid(); // spans on different lanes may overlap
        fx.addSpan(a, SpanKind::Motion, 1, f30(30), f30(40));
        expectProblem(fx, "motion span on audio track");
        fx.sequence().findClip(a)->spans.back().kind = SpanKind::Gain;
        fx.requireValid();
        fx.addSpan(v, SpanKind::Gain, 3, f30(30), f30(40));
        expectProblem(fx, "gain span on video track");
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
