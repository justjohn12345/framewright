#include "AppleProber.h"

#include "AppleStillImage.h"
#include "AppleSupport.h"

namespace ve::media::apple {

AppleProber::AppleProber(double loadTimeoutSeconds) : timeout_(loadTimeoutSeconds) {}

Result<MediaInfo> AppleProber::probe(const std::string &path) {
    @autoreleasepool {
        VE_MEDIA_TRY(checkReadableFile(path));

        auto still = probeStillImage(path);
        if (!still.ok()) {
            return std::move(still).error();
        }
        if (still.value()) {
            MediaInfo info = std::move(*still.value());
            info.backend = "apple";
            return info;
        }

        auto loaded = loadAsset(path, timeout_);
        if (!loaded.ok()) {
            return std::move(loaded).error();
        }
        MediaInfo info;
        info.path = path;
        info.backend = "apple";
        info.container = sniffContainer(path);
        info.duration = loaded->asset.duration;
        NSArray<AVAssetTrack *> *tracks = loaded->tracks;
        for (NSUInteger i = 0; i < tracks.count; ++i) {
            AVAssetTrack *track = tracks[i];
            if (![track.mediaType isEqualToString:AVMediaTypeVideo] &&
                ![track.mediaType isEqualToString:AVMediaTypeAudio]) {
                continue; // Timecode, text, metadata tracks are not media for the editor.
            }
            if (track.formatDescriptions.count == 0) {
                continue;
            }
            info.tracks.push_back(makeTrackInfo(track, static_cast<int>(i)));
        }
        if (info.tracks.empty()) {
            return makeError(MediaErrorCode::UnsupportedFormat, "no audio or video tracks in " + path);
        }
        if (!CMTIME_IS_NUMERIC(info.duration)) {
            return makeError(MediaErrorCode::CorruptData, "no valid duration in " + path);
        }
        return info;
    }
}

} // namespace ve::media::apple
