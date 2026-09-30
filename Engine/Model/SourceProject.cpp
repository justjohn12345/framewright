#include "SourceProject.h"

#include <algorithm>

namespace ve {

CMTime assetFrameGrid(const MediaAsset &asset, CMTime fallbackFrameDuration) {
    return asset.hasVideo() && isPositive(asset.frameDuration) ? asset.frameDuration : fallbackFrameDuration;
}

CMTime assetFrameTime(const MediaAsset &asset, CMTime time, CMTime fallbackFrameDuration) {
    if (!CMTIME_IS_NUMERIC(time) || time < kCMTimeZero || asset.isStill()) {
        return kCMTimeZero;
    }
    const CMTime fd = assetFrameGrid(asset, fallbackFrameDuration);
    CMTime t = snapToFrame(time, fd, SnapMode::Floor);
    if (CMTIME_IS_NUMERIC(asset.duration) && asset.duration > kCMTimeZero) {
        const CMTime last = snapToFrame(asset.duration, fd, SnapMode::Floor);
        const CMTime lastStart = last == asset.duration ? last - fd : last;
        if (t > lastStart) {
            t = std::max(kCMTimeZero, lastStart);
        }
    }
    return t;
}

std::optional<Project> makeSourceProject(const MediaAsset &asset, CMTime fallbackFrameDuration, bool sharpen,
                                         const SourceProjectIds &ids) {
    if (asset.isStill() || !CMTIME_IS_NUMERIC(asset.duration) || asset.duration <= kCMTimeZero) {
        return std::nullopt;
    }
    Project project;
    project.name = "Source";
    project.ids = IdGenerator(ids.first);
    project.sharpenScaledDownSources = sharpen;
    project.assets.push_back(asset);
    const CMTime fd = assetFrameGrid(asset, fallbackFrameDuration);
    const SequenceId sequenceId = project.addSequence("Source", fd, asset.hasVideo() ? std::max(1, asset.width) : 16,
                                                      asset.hasVideo() ? std::max(1, asset.height) : 9, 1, 1);
    Sequence &sequence = *project.findSequence(sequenceId);
    const CMTime length = snapToFrame(asset.duration, fd, SnapMode::Floor);
    if (length <= kCMTimeZero) {
        return std::nullopt;
    }
    Clip video;
    video.id = ids.videoClip;
    video.assetId = asset.id;
    video.trackId = sequence.videoTracks.front().id;
    video.timelineStart = kCMTimeZero;
    video.timelineDuration = length;
    video.sourceIn = kCMTimeZero;
    Clip audio = video;
    audio.id = ids.audioClip;
    audio.trackId = sequence.audioTracks.front().id;
    // The picture ends where the media's video ends (the audio may run on).
    const CMTime videoLength = snapToFrame(asset.videoEnd(), fd, SnapMode::Floor);
    if (videoLength > kCMTimeZero && videoLength < length) {
        video.timelineDuration = videoLength;
    }
    if (asset.hasVideo() && asset.hasAudio()) {
        video.linkedClipId = audio.id;
        audio.linkedClipId = video.id;
    }
    if (asset.hasVideo()) {
        sequence.videoTracks.front().clips.push_back(video);
    }
    if (asset.hasAudio()) {
        sequence.audioTracks.front().clips.push_back(audio);
    }
    return project;
}

} // namespace ve
