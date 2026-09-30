#include "AssetImport.h"

#include "../Model/Sequence.h"

#include <algorithm>
#include <cmath>

namespace ve::media {

void displaySize(const TrackInfo &track, int &width, int &height) {
    const int r = ((track.rotationDegrees % 360) + 360) % 360;
    const bool swap = r == 90 || r == 270;
    width = swap ? track.height : track.width;
    height = swap ? track.width : track.height;
}

namespace {

std::string lastPathComponent(const std::string &path) {
    std::string p = path;
    while (p.size() > 1 && p.back() == '/') {
        p.pop_back();
    }
    const size_t slash = p.find_last_of('/');
    return slash == std::string::npos ? p : p.substr(slash + 1);
}

bool routable(const RoutedMediaInfo &routed, const TrackInfo &t) {
    const TrackRoute *r = routed.route(t.index);
    return r != nullptr && !r->backend.empty();
}

const TrackInfo *firstRoutable(const RoutedMediaInfo &routed, TrackKind kind) {
    for (const TrackInfo &t : routed.info.tracks) {
        if (t.kind == kind && routable(routed, t)) {
            return &t;
        }
    }
    return nullptr;
}

} // namespace

Result<MediaAsset> makeMediaAsset(const RoutedMediaInfo &routed, AssetId id, const std::string &name) {
    if (!id.isValid()) {
        return makeError(MediaErrorCode::InvalidArgument, "makeMediaAsset: invalid asset id");
    }
    const MediaInfo &info = routed.info;
    const TrackInfo *video = firstRoutable(routed, TrackKind::Video);
    const TrackInfo *still = video ? nullptr : firstRoutable(routed, TrackKind::Still);
    const TrackInfo *audio = firstRoutable(routed, TrackKind::Audio);
    const TrackInfo *visual = video ? video : still;
    if (visual == nullptr && audio == nullptr) {
        return makeError(MediaErrorCode::NoSuchTrack, "no decodable track in " + info.path);
    }

    MediaAsset asset;
    asset.id = id;
    asset.name = name.empty() ? lastPathComponent(info.path) : name;
    asset.url = info.path;

    if (still != nullptr) {
        asset.kind = AssetKind::Still;
    } else if (video != nullptr) {
        asset.kind = audio ? AssetKind::AudioVideo : AssetKind::Video;
    } else {
        asset.kind = AssetKind::Audio;
    }

    if (visual != nullptr) {
        int w = 0;
        int h = 0;
        displaySize(*visual, w, h);
        if (w <= 0 || h <= 0) {
            return makeError(MediaErrorCode::InvalidArgument, "track " + std::to_string(visual->index) +
                                                                  " of " + info.path + " has no frame size");
        }
        asset.width = w;
        asset.height = h;
        // Stills come out of the decoders already oriented (EXIF applied): no rotation left.
        asset.rotationDegrees = still != nullptr ? 0 : ((visual->rotationDegrees % 360) + 360) % 360;
    }
    if (video != nullptr) {
        if (!isPositive(video->frameDuration)) {
            return makeError(MediaErrorCode::InvalidArgument,
                             "video track " + std::to_string(video->index) + " of " + info.path +
                                 " has no frame duration");
        }
        asset.frameDuration = video->frameDuration;
        // A shortest frame interval faster than kMaxFramesPerSecond is the container's time base, not the
        // picture's rate (Matroska and WebM tick in milliseconds: two frames a tick apart read as 1000 fps).
        // The track's nominal (average) rate stands in for it, when that is a picture rate; 120000 is a
        // multiple of every standard rate's frame duration (1001/24000 ... 1/60), so those stay exact.
        const double fastest = 1.0 / CMTimeGetSeconds(video->frameDuration);
        if (fastest > kMaxFramesPerSecond * 1.0005 && video->nominalFps > 0 &&
            video->nominalFps <= kMaxFramesPerSecond * 1.0005) {
            asset.frameDuration = CMTimeMake(std::max<int64_t>(1, std::llround(120000.0 / video->nominalFps)), 120000);
        }
        asset.isVFR = video->isVFR;
    }
    if (audio != nullptr) {
        asset.audioSampleRate = static_cast<int32_t>(std::lround(audio->sampleRate));
        asset.audioChannels = audio->channels;
    }

    if (asset.kind == AssetKind::Still) {
        asset.duration = kCMTimeInvalid;
    } else {
        CMTime duration = info.duration;
        if (!isNumeric(duration)) {
            duration = kCMTimeZero;
            for (const TrackInfo &t : info.tracks) {
                if (t.kind != TrackKind::Still && isNumeric(t.duration) && isNumeric(t.startTime)) {
                    duration = maxTime(duration, t.startTime + t.duration);
                }
            }
        }
        if (!isPositive(duration)) {
            return makeError(MediaErrorCode::InvalidArgument, info.path + " has no duration");
        }
        asset.duration = duration;
        // Where the pictures end: the video track's end on the container timeline, which comes
        // before the container's duration when the audio runs longer. Clips on video tracks are
        // kept within it (MediaAsset::videoDuration).
        if (video != nullptr && isNumeric(video->duration) && isPositive(video->duration)) {
            const CMTime start = isNumeric(video->startTime) ? maxTime(video->startTime, kCMTimeZero) : kCMTimeZero;
            asset.videoDuration = canonicalProbedTime(minTime(start + video->duration, duration));
        }
    }

    const TrackRoute *route = visual ? routed.route(visual->index) : routed.route(audio->index);
    asset.backendHint = route->backend;
    asset.hardwareDecode = route->hardwareDecode;
    return asset;
}

} // namespace ve::media
