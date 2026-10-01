#include "EditPlans.h"

#include <set>

namespace ve {

std::vector<ClipPlacement> placementsForAsset(const MediaAsset &asset, TrackId videoTrack, TrackId audioTrack,
                                              CMTime sourceIn, CMTime sourceOut) {
    std::vector<ClipPlacement> placements;
    auto configure = [&](TrackId track) {
        ClipPlacement p = placementForAsset(asset, track);
        if (asset.isStill()) {
            if (CMTIME_IS_NUMERIC(sourceIn) && CMTIME_IS_NUMERIC(sourceOut) && sourceIn < sourceOut) {
                p.sourceIn = kCMTimeZero;
                p.sourceOut = sourceOut - sourceIn;
            }
        } else {
            if (CMTIME_IS_NUMERIC(sourceIn)) {
                p.sourceIn = sourceIn;
            }
            if (CMTIME_IS_NUMERIC(sourceOut)) {
                p.sourceOut = sourceOut;
            }
        }
        placements.push_back(p);
    };
    if (asset.hasVideo() && videoTrack) {
        configure(videoTrack);
    }
    if (asset.hasAudio() && audioTrack) {
        configure(audioTrack);
    }
    return placements;
}

std::vector<ClipId> splitTargets(const Sequence &sequence, const std::vector<ClipId> &candidates, CMTime at,
                                 bool skipLocked) {
    std::set<ClipId> covered;
    std::vector<ClipId> targets;
    for (ClipId id : candidates) {
        const Track *track = sequence.trackOfClip(id);
        const Clip *clip = track ? track->find(id) : nullptr;
        if (clip == nullptr || covered.count(id) || !(clip->timelineStart < at && at < clip->timelineEnd())) {
            continue;
        }
        if (skipLocked && track->locked) {
            continue;
        }
        covered.insert(id);
        if (clip->linkedClipId) {
            covered.insert(*clip->linkedClipId); // SplitClip splits the partner too
        }
        targets.push_back(id);
    }
    return targets;
}

EditResult linkedEditTargets(const Sequence &sequence, const std::vector<ClipId> &ids, const std::string &stillRefusal,
                             std::vector<ClipId> &targets) {
    targets.clear();
    std::set<ClipId> covered;
    for (ClipId id : ids) {
        const Clip *clip = sequence.findClip(id);
        if (clip == nullptr) {
            return EditResult::failure(EditError::ClipNotFound, "A selected clip no longer exists.");
        }
        if (clip->isStill) {
            return EditResult::failure(EditError::InvalidArgument, stillRefusal);
        }
        if (!covered.insert(id).second) {
            continue;
        }
        if (clip->linkedClipId) {
            covered.insert(*clip->linkedClipId); // the edit changes the partner too
        }
        targets.push_back(id);
    }
    return EditResult::success();
}

EditResult planMatchMotion(const Sequence &sequence, ClipId clipId, ClipEdge edge, std::optional<VideoParams> &values) {
    values.reset();
    const Track *track = sequence.trackOfClip(clipId);
    const Clip *clip = track ? track->find(clipId) : nullptr;
    if (clip == nullptr) {
        return EditResult::failure(EditError::ClipNotFound, "The clip no longer exists.");
    }
    if (track->kind != TrackKind::Video) {
        return EditResult::failure(EditError::TrackKindMismatch, "Audio clips have no Motion.");
    }
    const bool previous = edge == ClipEdge::Head;
    const CMTime fd = sequence.frameDuration;
    const Clip *neighbour = touchingClip(*track, *clip, edge);
    if (neighbour == nullptr) {
        return EditResult::failure(EditError::NotAdjacent, previous
                                                               ? "No clip ends where this clip starts on its track."
                                                               : "No clip starts where this clip ends on its track.");
    }
    // The neighbour's frame at the cut, as the monitors and export draw it; this clip's frame there.
    const CMTime neighbourFrame = previous ? neighbour->timelineEnd() - fd : neighbour->timelineStart;
    const CMTime frame = previous ? clip->timelineStart : clip->timelineEnd() - fd;
    const VideoParams target = motionValuesAt(*neighbour, neighbourFrame);
    // What the clip's spans add and multiply there, composed onto neutral static values.
    Clip neutral = *clip;
    neutral.video = VideoParams{};
    const VideoParams spans = motionValuesAt(neutral, frame);
    for (const MotionParameter parameter : kMotionParameters) {
        if (!canDecomposeSpanValue(spanParameterOf(parameter), spans.staticValue(parameter))) {
            return EditResult::failure(EditError::InvalidArgument,
                                       "The clip's spans make its scale or opacity 0 there, so no static value can match.");
        }
    }
    // The static values the spans compose onto to give the neighbour's (decomposeSpanValue).
    VideoParams matched = clip->video;
    for (const MotionParameter parameter : kMotionParameters) {
        matched.setStaticValue(parameter, decomposeSpanValue(spanParameterOf(parameter), spans.staticValue(parameter),
                                                             target.staticValue(parameter)));
    }
    if (!(matched.opacity <= 1.0)) {
        return EditResult::failure(EditError::InvalidArgument, "The clip's spans lower its opacity there, so no "
                                                               "static opacity can reach the neighbour's.");
    }
    bool changesAnything = false;
    for (const MotionParameter parameter : kMotionParameters) {
        changesAnything = changesAnything || !spanValuesMatch(spanParameterOf(parameter), matched.staticValue(parameter),
                                                              clip->video.staticValue(parameter));
    }
    if (changesAnything) {
        values = matched;
    }
    return EditResult::success();
}

} // namespace ve
