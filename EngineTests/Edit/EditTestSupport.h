// Helpers for the edit-op tests.

#pragma once

#include "../Model/ModelFixtures.h"

#include <utility>
#include <vector>

namespace vetest {

// Placement of source frames [inFrame, outFrame) (30 fps units) of `asset` on `track`.
inline ClipPlacement place(TrackId track, AssetId asset, std::int64_t inFrame, std::int64_t outFrame,
                           double speed = 1.0) {
    ClipPlacement p;
    p.trackId = track;
    p.assetId = asset;
    p.sourceIn = f30(inFrame);
    p.sourceOut = f30(outFrame);
    p.speed = speedFromDouble(speed);
    return p;
}

inline std::vector<ClipId> clipIdsOn(const Fixture &fx, TrackId trackId) {
    std::vector<ClipId> ids;
    for (const Clip &clip : fx.sequence().findTrack(trackId)->clips) {
        ids.push_back(clip.id);
    }
    return ids;
}

// [start, end) of a clip in 30 fps frames.
inline std::pair<std::int64_t, std::int64_t> framesOf(const Clip &clip) {
    return {frameIndexAt(clip.timelineStart, f30(1), SnapMode::Round),
            frameIndexAt(clip.timelineEnd(), f30(1), SnapMode::Round)};
}

inline std::pair<std::int64_t, std::int64_t> span(std::int64_t start, std::int64_t end) {
    return {start, end};
}

inline void lockTrack(Fixture &fx, TrackId trackId) {
    fx.track(trackId).locked = true;
}

} // namespace vetest
