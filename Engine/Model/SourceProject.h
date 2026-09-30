// The source monitor's view of one asset: a private project that plays the asset on its own, and
// the asset's frame grid.

#pragma once

#include "Project.h"

#include <cstdint>
#include <optional>

namespace ve {

// The frame grid an asset is shown on: its nominal frame duration for video (and audio+video)
// media that has one, `fallbackFrameDuration` otherwise (sound, stills, variable-rate media without
// a nominal rate).
CMTime assetFrameGrid(const MediaAsset &asset, CMTime fallbackFrameDuration);

// `time` snapped down to the asset's frame grid (assetFrameGrid) and clamped to the start of its last
// frame; zero for a still and for a time that is not a numeric time >= 0.
CMTime assetFrameTime(const MediaAsset &asset, CMTime time, CMTime fallbackFrameDuration);

// The ids a source project uses: its IdGenerator starts at `first` (chosen far from any model id)
// and its two clips have fixed ids.
struct SourceProjectIds {
    std::uint64_t first = 0;
    ClipId videoClip;
    ClipId audioClip;
};

// A project named "Source" that shows `asset` (same id as in the real project, so the frame cache
// and routing are shared) as one clip over the whole media, video on V1 and audio on A1 (linked when
// it has both), on a sequence "Source" at the asset's own frame grid (assetFrameGrid) and size (16x9
// for sound), sharpening scaled-down pictures as `sharpen` says. The video clip ends where the
// media's video ends when the audio runs on. Nullopt for stills and media without a positive
// duration (or shorter than one frame).
std::optional<Project> makeSourceProject(const MediaAsset &asset, CMTime fallbackFrameDuration, bool sharpen,
                                         const SourceProjectIds &ids);

} // namespace ve
