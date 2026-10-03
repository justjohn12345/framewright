// A piece of source media imported into a project, or one of the project's generator assets.
//
// A generator asset (`generator` not None: one "Title" and one "Colour Matte" asset per project, made by
// the first clip of its kind) has no file: it is a still with an empty URL and a size of 0 x 0, whose clips
// carry what they show (Clip::generated, GeneratedContent.h). It is hidden from the media bin and the source
// monitor, never offered by "remove unused media", not written to a project file when no clip uses it, and
// every place that reads an asset's URL as a file (registration with the decode pools and mixers, thumbnails,
// waveforms, locate, bookmarks, export's media checks, "File not found") asks isFileBacked() first.

#pragma once

#include "GeneratedContent.h"
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

    // What the asset generates (see the top of this file); None for a file.
    GeneratorKind generator = GeneratorKind::None;

    // The asset is a file (not a generator asset): its URL names media to decode.
    bool isFileBacked() const {
        return generator == GeneratorKind::None;
    }
    bool isGenerator() const {
        return generator != GeneratorKind::None;
    }

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

// The generator asset of `kind` (Title or ColourMatte) as a project adds it: a still named after the kind
// (displayNameOf) with an empty URL and no size. Its id is the project's to give (Project::addAsset).
MediaAsset makeGeneratorAsset(GeneratorKind kind);

// A probed time as the model stores it: the prober's measurement is taken as exact (a
// kCMTimeFlags_HasBeenRounded flag from its own arithmetic is dropped and the epoch reset to 0);
// any invalid time becomes the canonical kCMTimeInvalid. Other non-numeric times are unchanged.
CMTime canonicalProbedTime(CMTime t);

// 0, 90, 180 or 270.
bool isValidRotation(std::int32_t degrees);

} // namespace ve
