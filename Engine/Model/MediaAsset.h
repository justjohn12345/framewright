// A piece of source media imported into a project.

#pragma once

#include "Ids.h"
#include "TimeUtil.h"

#include <cstdint>
#include <string>

namespace ve {

enum class AssetKind {
    Video,      // video only
    Audio,      // audio only
    Still,      // single image; has no intrinsic duration
    AudioVideo, // video with at least one audio track
};

const char *nameOf(AssetKind kind);

struct MediaAsset {
    AssetId id;
    std::string name;
    std::string url; // file URL or path, as given by the importer
    AssetKind kind = AssetKind::AudioVideo;

    // Media runs from time zero to `duration`: positive for every kind except Still, where it
    // is not numeric (kCMTimeInvalid).
    CMTime duration = kCMTimeInvalid;

    // Video (Video, AudioVideo, Still).
    std::int32_t width = 0;
    std::int32_t height = 0;
    // Nominal frame duration: positive for Video/AudioVideo (VFR sources may leave it invalid);
    // ignored for stills and audio.
    CMTime frameDuration = kCMTimeInvalid;
    bool isVFR = false;
    // Video (Video, AudioVideo): where the video track ends (the end of its last frame, as the
    // prober reports it), at most `duration`; shorter when the container runs on with audio
    // (screen recordings, files trimmed elsewhere). kCMTimeInvalid when not recorded (stills,
    // audio-only assets); the video then lasts `duration`. Projects saved before schema 3 get
    // `duration` (the best they know). Clips on video tracks use media up to videoEnd() only
    // (Validation, EditOps); the decode pool holds the last frame should the pictures still end
    // earlier (DecodePool.h).
    CMTime videoDuration = kCMTimeInvalid;
    // Display rotation from the container (MP4 preferredTransform, MKV display matrix), in
    // degrees clockwise: 0, 90, 180 or 270. `width`/`height` are the DISPLAYED size after this
    // rotation; decoders return frames in storage orientation, so the renderer must apply it.
    std::int32_t rotationDegrees = 0;

    // Audio (Audio, AudioVideo): both positive.
    std::int32_t audioSampleRate = 0;
    std::int32_t audioChannels = 0;

    std::string backendHint; // decoder backend chosen by the router ("apple", "ffmpeg", ...)
    bool hardwareDecode = false;

    bool hasVideo() const {
        return kind != AssetKind::Audio;
    }
    bool hasAudio() const {
        return kind == AssetKind::Audio || kind == AssetKind::AudioVideo;
    }
    bool isStill() const {
        return kind == AssetKind::Still;
    }
    // End of the media a clip on a video track may use: videoDuration when recorded, else
    // duration.
    CMTime videoEnd() const {
        return isNumeric(videoDuration) ? videoDuration : duration;
    }
};

// Bit-for-bit equality of every field.
bool operator==(const MediaAsset &a, const MediaAsset &b);

// A probed time as the model stores it: the prober's measurement is taken as exact (a
// kCMTimeFlags_HasBeenRounded flag from its own arithmetic is dropped and the epoch reset to 0);
// any invalid time becomes the canonical kCMTimeInvalid. Other non-numeric times are unchanged.
CMTime canonicalProbedTime(CMTime t);

// 0, 90, 180 or 270.
bool isValidRotation(std::int32_t degrees);

} // namespace ve
