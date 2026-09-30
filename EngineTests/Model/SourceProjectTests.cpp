// SourceProject.h: the source monitor's one-asset project and the asset frame grid (moved out of
// VEEngine.mm; VEEngineTests cover the source monitor end to end).

#include "../../Engine/Model/SourceProject.h"

#include "ModelFixtures.h"

using namespace vetest;

namespace {

constexpr std::uint64_t kFirst = std::uint64_t(1) << 56;
const SourceProjectIds kIds{kFirst, ClipId(kFirst + 10), ClipId(kFirst + 11)};

// 10 s of audio+video at 25 fps whose video ends at 8 s.
MediaAsset screenRecording() {
    MediaAsset asset;
    asset.id = AssetId(7);
    asset.name = "recording.mov";
    asset.kind = AssetKind::AudioVideo;
    asset.duration = CMTimeMake(10, 1);
    asset.videoDuration = CMTimeMake(8, 1);
    asset.width = 2560;
    asset.height = 1440;
    asset.frameDuration = CMTimeMake(1, 25);
    asset.audioSampleRate = 48000;
    asset.audioChannels = 2;
    return asset;
}

} // namespace

TEST_CASE("assetFrameGrid: the video's own frame duration, else the fallback") {
    Fixture fx;
    CHECK(assetFrameGrid(*fx.project.findAsset(fx.av24), f30(1)) == CMTimeMake(1001, 24000));
    CHECK(assetFrameGrid(*fx.project.findAsset(fx.audioOnly), f30(1)) == f30(1));
    CHECK(assetFrameGrid(*fx.project.findAsset(fx.still), CMTimeMake(1, 25)) == CMTimeMake(1, 25));
    MediaAsset variable = *fx.project.findAsset(fx.av30);
    variable.frameDuration = kCMTimeInvalid; // a VFR source without a nominal rate
    CHECK(assetFrameGrid(variable, CMTimeMake(1, 25)) == CMTimeMake(1, 25));
}

TEST_CASE("assetFrameTime snaps down to the frame grid and stays on the media") {
    Fixture fx;
    const MediaAsset &av24 = *fx.project.findAsset(fx.av24); // 20 s at 23.976
    const CMTime fd = CMTimeMake(1001, 24000);
    CHECK(assetFrameTime(av24, CMTimeMake(1, 1), f30(1)) == CMTimeMultiply(fd, 23)); // 1 s is inside frame 23
    CHECK(assetFrameTime(av24, CMTimeMultiply(fd, 5), f30(1)) == CMTimeMultiply(fd, 5));
    // Past the end: the start of the last frame (20 s is not on the grid: frame 479 starts before it).
    CHECK(assetFrameTime(av24, CMTimeMake(60, 1), f30(1)) == CMTimeMultiply(fd, 479));
    // Media ending on the grid: its last frame starts one frame before the end.
    const MediaAsset &av30 = *fx.project.findAsset(fx.av30); // 60 s at 30 fps
    CHECK(assetFrameTime(av30, CMTimeMake(60, 1), f30(1)) == CMTimeSubtract(CMTimeMake(60, 1), CMTimeMake(20, 600)));
    // Sound uses the fallback grid.
    CHECK(assetFrameTime(*fx.project.findAsset(fx.audioOnly), CMTimeMake(1, 20), f30(1)) == f30(1));
    // Stills, negative and non-numeric times give zero.
    CHECK(assetFrameTime(*fx.project.findAsset(fx.still), CMTimeMake(3, 1), f30(1)) == kCMTimeZero);
    CHECK(assetFrameTime(av30, CMTimeMake(-1, 30), f30(1)) == kCMTimeZero);
    CHECK(assetFrameTime(av30, kCMTimeInvalid, f30(1)) == kCMTimeZero);
    CHECK(assetFrameTime(av30, kCMTimePositiveInfinity, f30(1)) == kCMTimeZero);
}

TEST_CASE("makeSourceProject lays an audio+video asset out as one linked pair at its own settings") {
    const MediaAsset asset = screenRecording();
    const auto project = makeSourceProject(asset, f30(1), false, kIds);
    REQUIRE(project);
    CHECK(project->name == "Source");
    CHECK_FALSE(project->sharpenScaledDownSources);
    REQUIRE(project->assets.size() == 1);
    CHECK(project->assets[0].id == asset.id);
    const Sequence &sequence = *project->activeSequence();
    CHECK(sequence.name == "Source");
    CHECK(sequence.frameDuration == CMTimeMake(1, 25));
    CHECK(sequence.width == 2560);
    CHECK(sequence.height == 1440);
    REQUIRE(sequence.videoTracks.size() == 1);
    REQUIRE(sequence.audioTracks.size() == 1);
    REQUIRE(sequence.videoTracks[0].clips.size() == 1);
    REQUIRE(sequence.audioTracks[0].clips.size() == 1);
    const Clip &video = sequence.videoTracks[0].clips[0];
    const Clip &audio = sequence.audioTracks[0].clips[0];
    CHECK(video.id == kIds.videoClip);
    CHECK(audio.id == kIds.audioClip);
    CHECK(video.assetId == asset.id);
    CHECK(video.timelineStart == kCMTimeZero);
    CHECK(video.sourceIn == kCMTimeZero);
    CHECK(video.timelineDuration == CMTimeMake(8, 1)); // the picture ends with the video
    CHECK(audio.timelineDuration == CMTimeMake(10, 1));
    CHECK(video.linkedClipId == audio.id);
    CHECK(audio.linkedClipId == video.id);
    // The project's own ids start far from the model's.
    CHECK(project->ids.nextValue() > kFirst);
    CHECK(sequence.id.value() >= kFirst);
}

TEST_CASE("makeSourceProject: sound alone, video alone, and what it refuses") {
    Fixture fx;
    auto sound = makeSourceProject(*fx.project.findAsset(fx.audioOnly), CMTimeMake(1, 25), true, kIds);
    REQUIRE(sound);
    const Sequence &soundSequence = *sound->activeSequence();
    CHECK(soundSequence.frameDuration == CMTimeMake(1, 25)); // the fallback grid
    CHECK(soundSequence.width == 16);
    CHECK(soundSequence.height == 9);
    CHECK(soundSequence.videoTracks[0].clips.empty());
    REQUIRE(soundSequence.audioTracks[0].clips.size() == 1);
    CHECK_FALSE(soundSequence.audioTracks[0].clips[0].linkedClipId);
    CHECK(sound->sharpenScaledDownSources);

    auto picture = makeSourceProject(*fx.project.findAsset(fx.video60), f30(1), true, kIds);
    REQUIRE(picture);
    const Sequence &pictureSequence = *picture->activeSequence();
    CHECK(pictureSequence.frameDuration == CMTimeMake(1, 60));
    REQUIRE(pictureSequence.videoTracks[0].clips.size() == 1);
    CHECK(pictureSequence.videoTracks[0].clips[0].timelineDuration == CMTimeMake(10, 1));
    CHECK(pictureSequence.audioTracks[0].clips.empty());

    CHECK_FALSE(makeSourceProject(*fx.project.findAsset(fx.still), f30(1), true, kIds));
    MediaAsset empty = *fx.project.findAsset(fx.av30);
    empty.duration = kCMTimeZero;
    CHECK_FALSE(makeSourceProject(empty, f30(1), true, kIds));
    empty.duration = kCMTimeInvalid;
    CHECK_FALSE(makeSourceProject(empty, f30(1), true, kIds));
    MediaAsset blip = *fx.project.findAsset(fx.av30);
    blip.duration = CMTimeMake(1, 600); // shorter than one frame
    CHECK_FALSE(makeSourceProject(blip, f30(1), true, kIds));
}
