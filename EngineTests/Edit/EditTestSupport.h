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

// A request for a cross dissolve of `frames` centred on the cut at `owner`'s end (floor(n/2) before).
inline TransitionSpanRequest centredDissolve(ClipId owner, std::int64_t frames) {
    const auto [start, end] = centredTransitionOffsets(frames, f30(1));
    TransitionSpanRequest request;
    request.clipId = owner;
    request.edge = ClipEdge::Tail;
    request.start = start;
    request.end = end;
    return request;
}

// A request for a tail transition with `before` frames inside `owner` and `after` past its end.
inline TransitionSpanRequest tailTransition(ClipId owner, std::int64_t before, std::int64_t after) {
    TransitionSpanRequest request;
    request.clipId = owner;
    request.edge = ClipEdge::Tail;
    request.start = -f30(before);
    request.end = f30(after);
    return request;
}

// A request for a fade in of `frames` at `owner`'s start.
inline TransitionSpanRequest headFade(ClipId owner, std::int64_t frames) {
    TransitionSpanRequest request;
    request.clipId = owner;
    request.edge = ClipEdge::Head;
    request.start = kCMTimeZero;
    request.end = f30(frames);
    return request;
}

// The timeline range of transition `id` in 30 fps frames, or {-1, -1} when it is gone.
inline std::pair<std::int64_t, std::int64_t> transitionFrames(const Fixture &fx, SpanId id) {
    const auto placed = findTransition(fx.sequence(), id);
    if (!placed) {
        return {-1, -1};
    }
    return {frameIndexAt(placed->range.start, f30(1), SnapMode::Round),
            frameIndexAt(placed->range.end, f30(1), SnapMode::Round)};
}

} // namespace vetest
