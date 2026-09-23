// MediaAsset::videoDuration (phase 7 review finding 2): the video of an A/V asset may end before
// the container (screen recordings, files trimmed elsewhere). Validation, the edit ops that set
// source ranges (placement, tail trim, speed), transitions, the scheduler and the project file
// all use where the video ends for clips on video tracks, while audio clips keep the whole media.

#include "../../Engine/Render/Scheduler.h"
#include "EditTestSupport.h"

using namespace vetest;

namespace {

// av30 is 60 s long; its video ends at 50 s (frame 1500 at 30 fps).
constexpr std::int64_t kVideoEndFrame = 1500;

void shortenVideo(Fixture &fx) {
    fx.project.findAsset(fx.av30)->videoDuration = f30(kVideoEndFrame);
}

} // namespace

TEST_CASE("videoDuration: validation keeps video clips within the video, audio clips within the media") {
    Fixture fx;
    shortenVideo(fx);
    CHECK(fx.project.findAsset(fx.av30)->videoEnd() == f30(kVideoEndFrame));
    CHECK(fx.project.findAsset(fx.av24)->videoEnd() == fx.project.findAsset(fx.av24)->duration);
    CHECK(mediaEndFor(*fx.project.findAsset(fx.av30), TrackKind::Video) == f30(kVideoEndFrame));
    CHECK(mediaEndFor(*fx.project.findAsset(fx.av30), TrackKind::Audio) == f30(1800));

    const ClipId audio = fx.addClip(fx.a1, fx.av30, 0, 300, 1500); // source 50 s - 60 s
    CHECK(problemOf(fx.project).empty());
    const ClipId video = fx.addClip(fx.v1, fx.av30, 0, 30, 1480); // source 49.33 s - 50.33 s
    CHECK(problemOf(fx.project).find("past the end of the media's video") != std::string::npos);
    fx.track(fx.v1).clips.clear();
    fx.addClip(fx.v1, fx.av30, 0, 20, 1480); // ends exactly at the video's end
    CHECK(problemOf(fx.project).empty());
    (void)audio;
    (void)video;

    MediaAsset &asset = *fx.project.findAsset(fx.av30);
    asset.videoDuration = f30(1801);
    CHECK(problemOf(fx.project).find("video duration") != std::string::npos);
    asset.videoDuration = f30(kVideoEndFrame);
    fx.project.findAsset(fx.audioOnly)->videoDuration = f30(30);
    CHECK(problemOf(fx.project).find("only video has a video duration") != std::string::npos);
}

TEST_CASE("videoDuration: placements on a video track end where the video ends") {
    Fixture fx;
    shortenVideo(fx);
    Project &p = fx.project;

    SUBCASE("the whole media: the video clip is shorter than its linked audio") {
        ClipPlacement v = placementForAsset(*p.findAsset(fx.av30), fx.v1);
        ClipPlacement a = placementForAsset(*p.findAsset(fx.av30), fx.a1);
        InsertClip insert(fx.seq, f30(0), {v, a});
        applyReversible(p, insert);
        const Clip &video = fx.sequence().videoTracks[0].clips.at(0);
        const Clip &sound = fx.sequence().audioTracks[0].clips.at(0);
        CHECK(framesOf(video) == span(0, kVideoEndFrame));
        CHECK(framesOf(sound) == span(0, 1800));
        REQUIRE(video.linkedClipId.has_value());
        CHECK(*video.linkedClipId == sound.id);
    }
    SUBCASE("an out point past the video's end is cut there; the audio keeps it") {
        OverwriteClip overwrite(fx.seq, f30(0), {place(fx.v1, fx.av30, 1400, 1650), place(fx.a1, fx.av30, 1400, 1650)});
        applyReversible(p, overwrite);
        CHECK(framesOf(fx.sequence().videoTracks[0].clips.at(0)) == span(0, 100));
        CHECK(framesOf(fx.sequence().audioTracks[0].clips.at(0)) == span(0, 250));
    }
    SUBCASE("an in point at or after the video's end is refused on the video track only") {
        InsertClip refused(fx.seq, f30(0), {place(fx.v1, fx.av30, 1500, 1600)});
        const EditResult r = applyRefused(p, refused, EditError::OutOfSourceRange);
        CHECK(r.message.find("ends at") != std::string::npos);
        InsertClip audioOnly(fx.seq, f30(0), {place(fx.a1, fx.av30, 1500, 1600)});
        applyReversible(p, audioOnly);
    }
}

TEST_CASE("videoDuration: tail trims and speed changes stop at the video's end") {
    Fixture fx;
    shortenVideo(fx);
    Project &p = fx.project;
    const ClipId video = fx.addClip(fx.v1, fx.av30, 0, 30, 1460); // 10 frames of video left
    const ClipId audio = fx.addClip(fx.a1, fx.av30, 0, 30, 1460);  // 310 frames of audio left
    fx.link(video, audio);
    fx.requireValid();

    SUBCASE("trim tail") {
        TrimClipTail refused(fx.seq, video, f30(60), TrimOptions{false, false});
        const EditResult r = applyRefused(p, refused, EditError::OutOfSourceRange);
        CHECK(r.message.find("the end of the media's video") != std::string::npos);
        TrimClipTail clamped(fx.seq, video, f30(60), TrimOptions{false, true});
        applyReversible(p, clamped);
        CHECK(framesOf(fx.clip(video)) == span(0, 40));
        CHECK(fx.clip(video).sourceOut() == f30(kVideoEndFrame));
        // The linked audio can go on alone.
        TrimClipTail audioTrim(fx.seq, audio, f30(60), TrimOptions{false, false});
        applyReversible(p, audioTrim);
        CHECK(framesOf(fx.clip(audio)) == span(0, 60));
    }
    SUBCASE("trimming the pair together stops at the tighter end") {
        TrimClipTail clamped(fx.seq, video, f30(60), TrimOptions{true, true});
        applyReversible(p, clamped);
        CHECK(framesOf(fx.clip(video)) == span(0, 40));
        CHECK(framesOf(fx.clip(audio)) == span(0, 40));
    }
    SUBCASE("a speed change keeps the source range, so it never passes the video's end") {
        SetClipSpeed slower(fx.seq, video, Ratio{1, 2}, SpeedOptions{});
        applyReversible(p, slower);
        CHECK(fx.clip(video).sourceOut() <= f30(kVideoEndFrame));
    }
}

TEST_CASE("videoDuration: a transition needs video handles, an audio crossfade audio handles") {
    Fixture fx;
    shortenVideo(fx);
    Project &p = fx.project;
    // Outgoing clips end 2 frames before the end of the video; a 10-frame transition needs 5
    // frames of handle after the out point.
    const ClipId v1 = fx.addClip(fx.v1, fx.av30, 0, 30, 1468);
    const ClipId v2 = fx.addClip(fx.v1, fx.av30, 30, 30, 100);
    const ClipId a1 = fx.addClip(fx.a1, fx.av30, 0, 30, 1468);
    const ClipId a2 = fx.addClip(fx.a1, fx.av30, 30, 30, 100);
    fx.requireValid();
    AddTransition video(fx.seq, v1, v2, f30(10));
    applyRefused(p, video, EditError::InsufficientHandles);
    AddTransition sound(fx.seq, a1, a2, f30(10));
    applyReversible(p, sound);
}

TEST_CASE("videoDuration: the scheduler never shows a frame past the video's end") {
    Fixture fx;
    MediaAsset &asset = *fx.project.findAsset(fx.av30);
    Clip clip;
    clip.assetId = fx.av30;
    clip.timelineStart = kCMTimeZero;
    clip.timelineDuration = f30(60);
    clip.sourceIn = f30(1480); // an old project: source up to 51.33 s of a 60 s asset
    // Unknown (a version 2 file migrated to the duration): the mapped frame.
    CHECK(Scheduler::sourceFrameTime(clip, asset, f30(40)) == CMTimeMake(1520 * 20, 600));
    // Known: held on the last frame of the video.
    asset.videoDuration = f30(kVideoEndFrame);
    CHECK(Scheduler::sourceFrameTime(clip, asset, f30(40)) == CMTimeMake((kVideoEndFrame - 1) * 20, 600));
    CHECK(Scheduler::sourceFrameTime(clip, asset, f30(10)) == CMTimeMake(1490 * 20, 600));
}

TEST_CASE("videoDuration: saved, loaded, and migrated from schema 2") {
    Fixture fx;
    shortenVideo(fx);
    const ProjectLoadResult loaded = parseProject(serializeProject(fx.project));
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(*loaded.project == fx.project);
    CHECK(identical(loaded.project->findAsset(fx.av30)->videoDuration, f30(kVideoEndFrame)));
    CHECK(CMTIME_IS_INVALID(loaded.project->findAsset(fx.audioOnly)->videoDuration));

    // A schema 2 document: video and A/V assets get their duration, others nothing.
    nlohmann::json doc = projectToJson(fx.project);
    doc["schemaVersion"] = 2;
    for (auto &asset : doc["assets"]) {
        asset.erase("videoDuration");
    }
    std::vector<std::string> warnings;
    REQUIRE_FALSE(migrateProjectJson(doc, 2, warnings).has_value());
    CHECK(warnings.empty());
    CHECK(doc.at("schemaVersion") == kProjectSchemaVersion);
    const ProjectLoadResult migrated = projectFromJson(doc);
    REQUIRE_MESSAGE(migrated.ok(), doctest::String(migrated.error.c_str()));
    for (const MediaAsset &asset : migrated.project->assets) {
        const bool video = asset.kind == AssetKind::Video || asset.kind == AssetKind::AudioVideo;
        CHECK_MESSAGE(identical(asset.videoDuration, video ? asset.duration : kCMTimeInvalid),
                      doctest::String(asset.name.c_str()));
    }
}
