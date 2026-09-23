// AssetImport: turns a routed probe result into the model's MediaAsset.
//
// Pure function over value types (no I/O, no globals), thread-safe.
#pragma once

#include "../Model/MediaAsset.h"
#include "BackendRouter.h"

#include <string>

namespace ve::media {

/// Builds the MediaAsset for `routed`:
/// - kind: Still if the visual track is a still image; AudioVideo / Video / Audio from the
///   routable tracks present (tracks no backend can decode are ignored).
/// - duration: routed.info.duration (kCMTimeInvalid for stills); if the container reports no
///   numeric duration, the longest track end.
/// - width/height: display size of the first video (or still) track: the storage size with
///   90/270 degree rotation applied (width and height swapped).
/// - rotationDegrees: that video track's clockwise display rotation (0/90/180/270, from the
///   prober: MP4 preferredTransform, Matroska display matrix); decoders return storage
///   orientation, so the renderer applies it. 0 for stills (decoded already oriented).
/// - frameDuration / isVFR from that track (invalid / false for stills).
/// - audioSampleRate (rounded to Hz) / audioChannels from the first routable audio track.
/// - backendHint / hardwareDecode from the visual track's route, else the audio route.
/// - name: `name` if non-empty, else the last path component of routed.info.path.
/// - url: routed.info.path.
/// Errors: NoSuchTrack if no track is routable; InvalidArgument for an invalid id, a video
/// track without a positive frame duration or size, or a timed asset without a duration.
Result<MediaAsset> makeMediaAsset(const RoutedMediaInfo &routed, AssetId id, const std::string &name = {});

/// Display size of a video/still track: storage size with 90/270 degree rotation applied.
void displaySize(const TrackInfo &track, int &width, int &height);

} // namespace ve::media
