// What the facade's clip edits (VEEngine+Edits.mm, VEEngine+EffectSpans.mm) work out before they build
// their commands (EditOps.h): the placements of an asset, the clips an edit applies to, and the static
// Motion that matches a neighbour. The commands check the result again when they apply.

#pragma once

#include "EditOps.h"

#include <optional>
#include <string>
#include <vector>

namespace ve {

// The placements (placementForAsset) of `asset` on `videoTrack` and `audioTrack` (an invalid id skips
// that part; a part the asset does not have is skipped too), video first, using the source range
// [`sourceIn`, `sourceOut`) where those are numeric: for a still, the length of that range (when it
// is a non-empty numeric range) from source time zero.
std::vector<ClipPlacement> placementsForAsset(const MediaAsset &asset, TrackId videoTrack, TrackId audioTrack,
                                              CMTime sourceIn, CMTime sourceOut);

// The clips of `candidates` that a split at `at` divides: each that `at` falls strictly inside, and
// only one clip of a linked pair (SplitClip splits the partner too), in order. With `skipLocked`,
// clips on locked tracks are left out (a split of whatever is under the playhead).
std::vector<ClipId> splitTargets(const Sequence &sequence, const std::vector<ClipId> &candidates, CMTime at,
                                 bool skipLocked);

// `ids` in order without repeats and without the linked partner of a clip listed before it (a speed
// change or a reverse changes the partner too). Refused (with `targets` unspecified): ClipNotFound for
// a clip that no longer exists, InvalidArgument with `stillRefusal` for a still.
EditResult linkedEditTargets(const Sequence &sequence, const std::vector<ClipId> &ids, const std::string &stillRefusal,
                             std::vector<ClipId> &targets);

// The static Motion that makes the frame of `clipId` at `edge` (Head: its first frame, Tail: its last)
// show what its touching neighbour on that side shows at the cut (the previous clip's last frame, the
// next clip's first; motionValuesAt), the clip's spans acting on that frame taken into account (they
// compose onto the static values: position and rotation add, scale and opacity multiply). `values`
// receives the clip's static values with those changed, or nullopt when every one already matches
// (spanValuesMatch). Refused: ClipNotFound, TrackKindMismatch (an audio clip), NotAdjacent,
// InvalidArgument (the spans make scale or opacity 0 there, or lower the opacity so that no static
// opacity up to 1 reaches the neighbour's).
EditResult planMatchMotion(const Sequence &sequence, ClipId clipId, ClipEdge edge, std::optional<VideoParams> &values);

} // namespace ve
