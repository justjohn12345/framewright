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

    // Media runs from time zero to `duration`. Numeric for every kind except Still, where it is
    // ignored (usually kCMTimeInvalid).
    CMTime duration = kCMTimeInvalid;

    // Video (Video, AudioVideo, Still).
    std::int32_t width = 0;
    std::int32_t height = 0;
    CMTime frameDuration = kCMTimeInvalid; // nominal; invalid for stills
    bool isVFR = false;
    // Display rotation from the container (MP4 preferredTransform, MKV display matrix), in
    // degrees clockwise: 0, 90, 180 or 270. `width`/`height` are the DISPLAYED size after this
    // rotation; decoders return frames in storage orientation, so the renderer must apply it.
    std::int32_t rotationDegrees = 0;

    // Audio (Audio, AudioVideo).
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
};

// Bit-for-bit equality of every field.
bool operator==(const MediaAsset &a, const MediaAsset &b);

} // namespace ve
