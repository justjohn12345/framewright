// Edit operations on NTSC (29.97) and 23.976 timelines with sources whose timescales do not
// divide the frame grid (review finding 1 and its test gap 1): every result is exact and on the
// grid; when an exact result has no CMTime form the edit is refused as NotRepresentable, never
// rounded and never reported as an invariant violation.

#include "EditTestSupport.h"

using namespace vetest;

namespace {

struct GridFixture {
    Project project;
    SequenceId seq;
    TrackId v1, a1, a2;
    AssetId music44; // 44.1 kHz audio, 60 s
    AssetId clip2997; // 29.97 A/V, 60 s
    AssetId clip23976; // 23.976 A/V, 60 s
    CMTime frame;

    explicit GridFixture(CMTime frameDuration) : frame(frameDuration) {
        MediaAsset m;
        m.name = "music.wav";
        m.url = "/media/music.wav";
        m.kind = AssetKind::Audio;
        m.duration = CMTimeMake(60 * 44100, 44100);
        m.audioSampleRate = 44100;
        m.audioChannels = 2;
        music44 = project.addAsset(m);
        MediaAsset n;
        n.name = "ntsc.mov";
        n.url = "/media/ntsc.mov";
        n.kind = AssetKind::AudioVideo;
        n.duration = CMTimeMake(1001 * 1798, 30000);
        n.frameDuration = CMTimeMake(1001, 30000);
        n.width = 1920;
        n.height = 1080;
        n.audioSampleRate = 48000;
        n.audioChannels = 2;
        clip2997 = project.addAsset(n);
        MediaAsset f = n;
        f.name = "film.mov";
        f.url = "/media/film.mov";
        f.duration = CMTimeMake(1001 * 1438, 24000);
        f.frameDuration = CMTimeMake(1001, 24000);
        clip23976 = project.addAsset(f);
        seq = project.addSequence("S", frameDuration, 1920, 1080, 1, 2);
        v1 = project.findSequence(seq)->videoTracks[0].id;
        a1 = project.findSequence(seq)->audioTracks[0].id;
        a2 = project.findSequence(seq)->audioTracks[1].id;
    }

    CMTime frames(std::int64_t n) const {
        return timeForFrame(n, frame);
    }
    const Clip &clip(ClipId id) const {
        return *project.findSequence(seq)->findClip(id);
    }
    ClipPlacement placement(TrackId track, AssetId asset, CMTime in, CMTime out, Ratio speed) const {
        ClipPlacement p;
        p.trackId = track;
        p.assetId = asset;
        p.sourceIn = in;
        p.sourceOut = out;
        p.speed = speed;
        return p;
    }
};

void checkOnGrid(const GridFixture &fx, const Clip &clip) {
    CHECK(isOnFrameGrid(clip.timelineStart, fx.frame));
    CHECK(isOnFrameGrid(clip.timelineDuration, fx.frame));
    CHECK(isExactModelTime(clip.sourceIn));
    CHECK(isExactModelTime(clip.timelineDuration));
}

} // namespace

TEST_CASE("Frame grids: the reviewer's NTSC + 44.1 kHz + 0.999x insert is exact") {
    GridFixture fx(CMTimeMake(1001, 30000));
    const CMTime in = CMTimeMake(44101, 44100);
    const CMTime out = CMTimeMake(44101 + 219177, 44100); // 4.97 s of source
    InsertClip insert(fx.seq, fx.frames(7), {fx.placement(fx.a1, fx.music44, in, out, Ratio{999, 1000})});
    applyReversible(fx.project, insert);
    const Clip &clip = fx.clip(insert.createdClipIds()[0]);
    checkOnGrid(fx, clip);
    CHECK(identical(clip.sourceIn, in));
    // 4.97 s of source at 0.999x = 4.975 s of timeline = 149.1 frames of 1001/30000 -> 149.
    CHECK(identical(clip.timelineDuration, fx.frames(149)));
    // The derived out point is exact, has no CMTime form (its timescale would be 4.41e9), and
    // never passes the requested one.
    const auto exactOut = clip.exactSourceOut();
    REQUIRE(exactOut.has_value());
    CHECK_FALSE(exactOut->toTime().has_value());
    CHECK(exactOut->compare(out) <= 0);
    const auto oneMore = ExactTime::from(fx.frames(150))->times(Ratio{999, 1000})->plus(*ExactTime::from(in));
    CHECK(oneMore->compare(out) > 0); // and one more frame would
}

TEST_CASE("Frame grids: splits and trims at every frame of an NTSC clip with a 44.1 kHz in point") {
    GridFixture fx(CMTimeMake(1001, 30000));
    const CMTime in = CMTimeMake(44101, 44100);
    InsertClip insert(fx.seq, fx.frames(0),
                      {fx.placement(fx.a1, fx.music44, in, CMTimeMake(44101 + 4 * 44100, 44100), Ratio{1, 1})});
    REQUIRE(insert.apply(fx.project).ok());
    const ClipId clip = insert.createdClipIds()[0];
    const std::int64_t length = frameIndexAt(fx.clip(clip).timelineDuration, fx.frame, SnapMode::Round);
    REQUIRE(length == 119);
    // At speed 1 every split point is exact (the review saw 24 of 72 refused as invariant
    // violations here).
    for (std::int64_t at = 1; at < length; ++at) {
        CAPTURE(at);
        Project copy = fx.project;
        SplitClip split(fx.seq, clip, fx.frames(at));
        const EditResult r = split.apply(copy);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.message.c_str()));
        const Sequence &s = *copy.findSequence(fx.seq);
        const Clip &left = *s.findClip(clip);
        const Clip &right = *s.findClip(split.createdClipIds()[0]);
        CHECK(*right.exactSourceTimeAt(right.timelineStart) == *left.exactSourceOut()); // contiguous source
        CHECK(identical(left.timelineStart + left.timelineDuration, right.timelineStart));
        CHECK_FALSE(hasInexactTime(copy));
        TrimClipHead head(fx.seq, clip, fx.frames(at));
        REQUIRE(head.apply(copy).ok() == false); // the left piece ends there now: minimum length
    }
    for (std::int64_t at = 1; at < length; at += 7) {
        Project copy = fx.project;
        TrimClipHead head(fx.seq, clip, fx.frames(at));
        REQUIRE(head.apply(copy).ok());
        CHECK_FALSE(hasInexactTime(copy));
        CHECK(validateProject(copy) == std::nullopt);
    }
}

TEST_CASE("Frame grids: an edit whose exact source time has no CMTime form is refused, not rounded") {
    GridFixture fx(CMTimeMake(1001, 30000));
    const CMTime in = CMTimeMake(44101, 44100);
    InsertClip insert(fx.seq, fx.frames(0), {fx.placement(fx.a1, fx.music44, in, CMTimeMake(44101 + 4 * 44100, 44100),
                                                          Ratio{999, 1000})});
    REQUIRE(insert.apply(fx.project).ok());
    const ClipId clip = insert.createdClipIds()[0];
    // 44101/44100 + k * 1001/30000 * 999/1000 needs a timescale of 4.41e9 for most k.
    int refused = 0;
    for (std::int64_t at = 1; at < 100; ++at) {
        Project copy = fx.project;
        SplitClip split(fx.seq, clip, fx.frames(at));
        const EditResult r = split.apply(copy);
        if (!r) {
            CHECK(r.error == EditError::NotRepresentable);
            CHECK(copy == fx.project);
            ++refused;
        } else {
            CHECK_FALSE(hasInexactTime(copy));
            CHECK(validateProject(copy) == std::nullopt);
        }
    }
    CHECK(refused > 0);
    // Edits that do not move the in point are unaffected.
    TrimClipTail tail(fx.seq, clip, fx.frames(50));
    applyReversible(fx.project, tail);
    SetClipSpeed speed(fx.seq, clip, Ratio{1, 2});
    applyReversible(fx.project, speed);
}

TEST_CASE("Frame grids: 23.976 timeline edits stay on the grid") {
    GridFixture fx(CMTimeMake(1001, 24000));
    InsertClip insert(fx.seq, fx.frames(10),
                      {fx.placement(fx.v1, fx.clip2997, CMTimeMake(1001 * 3, 30000), CMTimeMake(1001 * 300, 30000),
                                    Ratio{1, 1}),
                       fx.placement(fx.a1, fx.clip2997, CMTimeMake(1001 * 3, 30000), CMTimeMake(1001 * 300, 30000),
                                    Ratio{1, 1})});
    applyReversible(fx.project, insert);
    const ClipId video = insert.createdClipIds()[0];
    const ClipId audio = insert.createdClipIds()[1];
    // 297 NTSC frames = 237.6 film frames -> 237.
    CHECK(identical(fx.clip(video).timelineDuration, fx.frames(237)));
    checkOnGrid(fx, fx.clip(video));

    SplitClip split(fx.seq, video, fx.frames(100));
    applyReversible(fx.project, split);
    checkOnGrid(fx, fx.clip(video));
    checkOnGrid(fx, fx.clip(split.createdClipIds()[0]));
    CHECK(fx.clip(audio).linkedClipId == video);

    TrimClipTail tail(fx.seq, split.createdClipIds()[0], fx.frames(10000), TrimOptions{true, true});
    applyReversible(fx.project, tail);
    const Clip &right = fx.clip(split.createdClipIds()[0]);
    checkOnGrid(fx, right);
    // Clamped at the last whole film frame the NTSC media covers.
    const auto out = right.exactSourceOut();
    CHECK(out->compare(fx.project.findAsset(fx.clip2997)->duration) <= 0);
    const auto next = ExactTime::from(right.timelineDuration + fx.frame)->times(Ratio{1, 1})->plus(
        *ExactTime::from(right.sourceIn));
    CHECK(next->compare(fx.project.findAsset(fx.clip2997)->duration) > 0);

    SetClipSpeed speed(fx.seq, video, Ratio{37, 100}, SpeedOptions{true, true});
    applyReversible(fx.project, speed);
    checkOnGrid(fx, fx.clip(video));
    CHECK(fx.clip(video).speed == Ratio{37, 100});

    AddTransition dissolve(fx.seq, video, split.createdClipIds()[0], fx.frames(5));
    const EditResult added = dissolve.apply(fx.project);
    CHECK((added.ok() || added.error == EditError::NotAdjacent || added.error == EditError::InsufficientHandles));
}
