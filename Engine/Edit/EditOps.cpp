#include "EditOps.h"

#include "../Model/Validation.h"
#include "EditPrimitives.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <unordered_map>
#include <unordered_set>
#include <utility>

namespace ve {

namespace {

std::string idString(std::uint64_t value) {
    return std::to_string(value);
}

EditResult requireNumeric(CMTime t, const char *what) {
    if (!isNumeric(t)) {
        return EditResult::failure(EditError::InvalidTime, std::string(what) + " is not a numeric time");
    }
    return EditResult::success();
}

EditResult checkSpeed(Ratio speed) {
    if (!isValidSpeed(speed)) {
        return EditResult::failure(EditError::InvalidArgument,
                                   "speed " + std::to_string(speed.num) + "/" + std::to_string(speed.den) +
                                       " is not a reduced ratio within [1/100, 100] with a denominator of at most " +
                                       std::to_string(kMaxSpeedDenominator));
    }
    return EditResult::success();
}

// Refusal unless `t` is an exact model time (numeric, not rounded, epoch 0).
EditResult requireExact(CMTime t, const char *what) {
    if (!isExactModelTime(t)) {
        return EditResult::failure(EditError::InvalidTime, std::string(what) + " " + describe(t) +
                                                               " is not an exact time (numeric, unrounded, epoch 0)");
    }
    return EditResult::success();
}

EditResult checkVideoParams(const VideoParams &v) {
    if (!std::isfinite(v.x) || !std::isfinite(v.y) || !std::isfinite(v.scale) || !std::isfinite(v.rotationDegrees) ||
        !std::isfinite(v.opacity)) {
        return EditResult::failure(EditError::InvalidArgument, "video parameters must be finite");
    }
    if (v.scale < 0.0) {
        return EditResult::failure(EditError::InvalidArgument, "scale must be >= 0");
    }
    if (v.opacity < 0.0 || v.opacity > 1.0) {
        return EditResult::failure(EditError::InvalidArgument, "opacity must be within [0, 1]");
    }
    if (auto problem = videoParamsProblem(v)) {
        return EditResult::failure(EditError::InvalidArgument, *problem);
    }
    return EditResult::success();
}

EditResult checkAudioParams(const AudioParams &a) {
    if (!std::isfinite(a.gainDb)) {
        return EditResult::failure(EditError::InvalidArgument, "gain must be finite");
    }
    return EditResult::success();
}

// Builds the clip described by a placement (without id or start).
EditResult buildClip(const Project &project, const Sequence &sequence, const Track &track,
                     const ClipPlacement &placement, Clip &out) {
    const MediaAsset *asset = project.findAsset(placement.assetId);
    if (!asset) {
        return EditResult::failure(EditError::AssetNotFound,
                                   "asset " + idString(placement.assetId.value()) + " does not exist");
    }
    if (!assetFitsTrack(*asset, track.kind)) {
        return EditResult::failure(EditError::TrackKindMismatch, std::string("a ") + nameOf(asset->kind) +
                                                                     " asset cannot go on " + nameOf(track.kind) +
                                                                     " track \"" + track.name + "\"");
    }
    if (EditResult r = checkVideoParams(placement.video); !r) {
        return r;
    }
    const CMTime frame = sequence.frameDuration;
    Clip clip;
    clip.assetId = asset->id;
    clip.trackId = track.id;
    clip.video = placement.video;
    clip.audio = placement.audio;

    if (asset->isStill()) {
        CMTime length = defaultStillDuration();
        if (isNumeric(placement.sourceIn) && isNumeric(placement.sourceOut) &&
            placement.sourceIn < placement.sourceOut) {
            length = placement.sourceOut - placement.sourceIn;
        }
        length = maxTime(snapToSequence(sequence, length), frame);
        if (!isExactModelTime(length)) {
            return EditResult::failure(EditError::InvalidTime, "the still's duration is not a usable time");
        }
        clip.isStill = true;
        clip.speed = Ratio{1, 1};
        clip.sourceIn = kCMTimeZero;
        clip.timelineDuration = length;
    } else {
        if (EditResult r = checkSpeed(placement.speed); !r) {
            return r;
        }
        if (EditResult r = requireExact(placement.sourceIn, "source in point"); !r) {
            return r;
        }
        CMTime sourceOut = isNumeric(placement.sourceOut) ? placement.sourceOut : asset->duration;
        if (EditResult r = requireExact(sourceOut, "source out point"); !r) {
            return r;
        }
        if (placement.sourceIn < kCMTimeZero || sourceOut > asset->duration) {
            return EditResult::failure(EditError::OutOfSourceRange,
                                       "source range " + describe(placement.sourceIn) + " - " + describe(sourceOut) +
                                           " is outside the media (0 - " + describe(asset->duration) + ")");
        }
        // On a video track the media ends where its video ends (the container may run on with
        // audio): the range is cut there (see ClipPlacement), and one starting after it has
        // nothing to show.
        const CMTime mediaEnd = mediaEndFor(*asset, track.kind);
        if (sourceOut > mediaEnd) {
            if (!(placement.sourceIn < mediaEnd)) {
                return EditResult::failure(EditError::OutOfSourceRange,
                                           "the video of \"" + asset->name + "\" ends at " + describe(mediaEnd) +
                                               ", before the source in point " + describe(placement.sourceIn));
            }
            sourceOut = mediaEnd;
        }
        if (!(placement.sourceIn < sourceOut)) {
            return EditResult::failure(EditError::InvalidArgument, "source range is empty");
        }
        // Whole frames of timeline that the source range fills at this speed, rounded down so the
        // derived out point never passes the requested one.
        const auto exactIn = ExactTime::from(placement.sourceIn);
        const auto exactOut = ExactTime::from(sourceOut);
        const auto sourceLength = exactIn && exactOut ? exactOut->minus(*exactIn) : std::nullopt;
        const auto timelineLength = sourceLength ? sourceLength->dividedBy(placement.speed) : std::nullopt;
        const auto frames = timelineLength ? timelineLength->frameIndex(frame, SnapMode::Floor) : std::nullopt;
        const auto length = frames ? checkedTimeForFrame(*frames, frame) : std::nullopt;
        if (!length) {
            return EditResult::failure(EditError::InvalidArgument, "the source range is too long");
        }
        if (*length < frame) {
            return EditResult::failure(EditError::InvalidArgument, "source range is shorter than one frame");
        }
        clip.speed = placement.speed;
        clip.sourceIn = placement.sourceIn;
        clip.timelineDuration = *length;
    }
    if (EditResult r = checkAudioParams(clip.audio); !r) {
        return r;
    }
    out = std::move(clip);
    return EditResult::success();
}

struct PlannedClip {
    Track *track = nullptr;
    Clip clip;
};

// Validates placements shared by InsertClip and OverwriteClip; resolves the start time.
EditResult planPlacements(const Project &project, Sequence &sequence, CMTime requestedAt,
                          const std::vector<ClipPlacement> &placements, CMTime &at, std::vector<PlannedClip> &plan) {
    if (placements.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "nothing to place");
    }
    if (EditResult r = requireNumeric(requestedAt, "placement time"); !r) {
        return r;
    }
    at = snapToSequence(sequence, requestedAt);
    if (at < kCMTimeZero) {
        return EditResult::failure(EditError::InvalidTime, "cannot place clips before time zero");
    }
    std::unordered_set<TrackId> used;
    for (const ClipPlacement &placement : placements) {
        Track *track = sequence.findTrack(placement.trackId);
        if (EditResult r = requireEditableTrack(track, placement.trackId); !r) {
            return r;
        }
        if (!used.insert(track->id).second) {
            return EditResult::failure(EditError::InvalidArgument,
                                       "two placements target track \"" + track->name + "\"");
        }
        PlannedClip planned;
        planned.track = track;
        if (EditResult r = buildClip(project, sequence, *track, placement, planned.clip); !r) {
            return r;
        }
        planned.clip.timelineStart = at;
        plan.push_back(std::move(planned));
    }
    return EditResult::success();
}

void linkPair(Sequence &sequence, ClipId a, ClipId b) {
    sequence.findClip(a)->linkedClipId = b;
    sequence.findClip(b)->linkedClipId = a;
}

// Resolves `clipIds` (plus linked partners when requested) to a de-duplicated list of clips on
// editable tracks.
EditResult collectClips(Sequence &sequence, const std::vector<ClipId> &clipIds, bool includeLinked,
                        std::vector<ClipId> &out) {
    if (clipIds.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "no clips given");
    }
    std::unordered_set<ClipId> seen;
    for (const ClipId clipId : clipIds) {
        Track *track = nullptr;
        Clip *clip = nullptr;
        if (EditResult r = findEditableClip(sequence, clipId, track, clip); !r) {
            return r;
        }
        if (seen.insert(clipId).second) {
            out.push_back(clipId);
        }
        if (includeLinked && clip->linkedClipId && seen.insert(*clip->linkedClipId).second) {
            Track *partnerTrack = nullptr;
            Clip *partner = nullptr;
            if (EditResult r = findEditableClip(sequence, *clip->linkedClipId, partnerTrack, partner); !r) {
                return r;
            }
            out.push_back(partner->id);
        }
    }
    return EditResult::success();
}

// The clip plus its linked partner (when requested), both on editable tracks.
EditResult clipAndPartner(Sequence &sequence, ClipId clipId, bool includeLinked, std::vector<ClipId> &out) {
    Track *track = nullptr;
    Clip *clip = nullptr;
    if (EditResult r = findEditableClip(sequence, clipId, track, clip); !r) {
        return r;
    }
    out.push_back(clipId);
    if (includeLinked && clip->linkedClipId) {
        Track *partnerTrack = nullptr;
        Clip *partner = nullptr;
        if (EditResult r = findEditableClip(sequence, *clip->linkedClipId, partnerTrack, partner); !r) {
            return r;
        }
        out.push_back(partner->id);
    }
    return EditResult::success();
}

// Sorted union of ranges.
std::vector<TimeRange> mergeRanges(std::vector<TimeRange> ranges) {
    std::sort(ranges.begin(), ranges.end(), [](const TimeRange &a, const TimeRange &b) { return a.start < b.start; });
    std::vector<TimeRange> merged;
    for (const TimeRange &range : ranges) {
        if (!merged.empty() && range.start <= merged.back().end) {
            merged.back().end = maxTime(merged.back().end, range.end);
        } else {
            merged.push_back(range);
        }
    }
    return merged;
}

// Allowed trim delta, with the reason each bound exists.
struct DeltaLimits {
    CMTime lo = kCMTimeNegativeInfinity;
    CMTime hi = kCMTimePositiveInfinity;
    EditError loError = EditError::None;
    EditError hiError = EditError::None;
    std::string loReason;
    std::string hiReason;

    void raiseLo(CMTime value, EditError error, std::string reason) {
        if (value > lo) {
            lo = value;
            loError = error;
            loReason = std::move(reason);
        }
    }
    void lowerHi(CMTime value, EditError error, std::string reason) {
        if (value < hi) {
            hi = value;
            hiError = error;
            hiReason = std::move(reason);
        }
    }

    // Resolves the requested delta (clamping or refusing).
    EditResult resolve(CMTime &delta, bool clamp) const {
        if (lo > hi) {
            return EditResult::failure(loError, "cannot trim: limited by " + loReason + " and " + hiReason);
        }
        if (clamp) {
            delta = clampTime(delta, lo, hi);
            return EditResult::success();
        }
        if (delta < lo) {
            return EditResult::failure(loError, "trim would pass " + loReason);
        }
        if (delta > hi) {
            return EditResult::failure(hiError, "trim would pass " + hiReason);
        }
        return EditResult::success();
    }
};

EditResult transitionIssueToResult(const TransitionIssue &issue) {
    switch (issue.kind) {
    case TransitionIssueKind::NotAdjacent:
        return EditResult::failure(EditError::NotAdjacent, issue.message);
    case TransitionIssueKind::InsufficientHandles:
        return EditResult::failure(EditError::InsufficientHandles, issue.message);
    case TransitionIssueKind::Overlap:
        return EditResult::failure(EditError::Overlap, issue.message);
    case TransitionIssueKind::TooLong:
    case TransitionIssueKind::BadDuration:
    case TransitionIssueKind::Structure:
    case TransitionIssueKind::Touching:
        break;
    }
    return EditResult::failure(EditError::InvalidArgument, issue.message);
}

// The lane-0 spans acting on `clip` of `track` (its own, and a cross dissolve into it from the clip
// touching its start), with their timeline ranges.
std::vector<TransitionPlacement> transitionsOn(const Track &track, const Clip &clip) {
    std::vector<TransitionPlacement> result;
    for (const ClipEdge edge : {ClipEdge::Head, ClipEdge::Tail}) {
        if (const EffectSpan *span = clip.transitionAt(edge)) {
            if (auto placement = placeTransition(track, clip, *span)) {
                result.push_back(*placement);
            }
        }
    }
    if (const Clip *previous = touchingClip(track, clip, ClipEdge::Head)) {
        if (const EffectSpan *span = previous->transitionAt(ClipEdge::Tail)) {
            auto placement = placeTransition(track, *previous, *span);
            if (placement && placement->role == TransitionRole::CrossDissolve) {
                result.push_back(*placement);
            }
        }
    }
    return result;
}

} // namespace

ClipPlacement placementForAsset(const MediaAsset &asset, TrackId trackId) {
    ClipPlacement placement;
    placement.trackId = trackId;
    placement.assetId = asset.id;
    if (asset.isStill()) {
        placement.sourceIn = kCMTimeZero;
        placement.sourceOut = defaultStillDuration();
    } else {
        placement.sourceIn = kCMTimeZero;
        placement.sourceOut = asset.duration;
    }
    return placement;
}

// ----- InsertClip -----

InsertClip::InsertClip(SequenceId sequenceId, CMTime at, std::vector<ClipPlacement> placements, bool linkPair)
    : InsertClip(sequenceId, at, std::move(placements), InsertOptions{linkPair, RippleScope::AllUnlockedTracks}) {}

InsertClip::InsertClip(SequenceId sequenceId, CMTime at, std::vector<ClipPlacement> placements, InsertOptions options)
    : SequenceCommand(sequenceId), at_(at), placements_(std::move(placements)), options_(options) {}

EditResult InsertClip::perform(const Project &project, Sequence &sequence, IdGenerator &ids) {
    CMTime at;
    std::vector<PlannedClip> plan;
    if (EditResult r = planPlacements(project, sequence, at_, placements_, at, plan); !r) {
        return r;
    }
    // Every rippled track moves by the longest new clip, so they all stay in sync.
    CMTime length = kCMTimeZero;
    std::vector<TrackId> targets;
    for (const PlannedClip &planned : plan) {
        length = maxTime(length, planned.clip.timelineDuration);
        targets.push_back(planned.track->id);
    }
    std::unordered_set<TrackId> rippled;
    if (EditResult r = rippleTracks(sequence, options_.ripple, targets, at, rippled); !r) {
        return r;
    }
    SplitList splits;
    if (EditResult r = openTime(sequence, rippled, at, length, ids, splits); !r) {
        return r;
    }
    created_.clear();
    for (PlannedClip &planned : plan) {
        planned.clip.id = ids.make<ClipId>();
        created_.push_back(planned.clip.id);
        insertClipSorted(*sequence.findTrack(planned.clip.trackId), planned.clip);
    }
    relinkSplitPieces(sequence, splits);
    if (options_.linkPair && created_.size() == 2) {
        linkPair(sequence, created_[0], created_[1]);
    }
    return EditResult::success();
}

// ----- OverwriteClip -----

OverwriteClip::OverwriteClip(SequenceId sequenceId, CMTime at, std::vector<ClipPlacement> placements, bool linkPair)
    : SequenceCommand(sequenceId), at_(at), placements_(std::move(placements)), linkPair_(linkPair) {}

EditResult OverwriteClip::perform(const Project &project, Sequence &sequence, IdGenerator &ids) {
    CMTime at;
    std::vector<PlannedClip> plan;
    if (EditResult r = planPlacements(project, sequence, at_, placements_, at, plan); !r) {
        return r;
    }
    created_.clear();
    SplitList splits;
    for (PlannedClip &planned : plan) {
        if (EditResult r = clearRange(sequence, *planned.track, planned.clip.timelineRange(), ids, splits); !r) {
            return r;
        }
        planned.clip.id = ids.make<ClipId>();
        created_.push_back(planned.clip.id);
        insertClipSorted(*planned.track, planned.clip);
    }
    relinkSplitPieces(sequence, splits);
    if (linkPair_ && created_.size() == 2) {
        linkPair(sequence, created_[0], created_[1]);
    }
    return EditResult::success();
}

// ----- MoveClip -----

MoveClip::MoveClip(SequenceId sequenceId, ClipId clipId, TrackId destinationTrackId, CMTime newStart,
                   bool includeLinked)
    : SequenceCommand(sequenceId), clipId_(clipId), destinationTrackId_(destinationTrackId), newStart_(newStart),
      includeLinked_(includeLinked) {
    setCoalescingKey("move:" + idString(clipId.value()));
}

EditResult MoveClip::perform(const Project &, Sequence &sequence, IdGenerator &ids) {
    Track *track = nullptr;
    Clip *clip = nullptr;
    if (EditResult r = findEditableClip(sequence, clipId_, track, clip); !r) {
        return r;
    }
    Track *destination = sequence.findTrack(destinationTrackId_);
    if (EditResult r = requireEditableTrack(destination, destinationTrackId_); !r) {
        return r;
    }
    if (destination->kind != track->kind) {
        return EditResult::failure(EditError::TrackKindMismatch, std::string("cannot move a ") + nameOf(track->kind) +
                                                                     " clip to " + nameOf(destination->kind) +
                                                                     " track \"" + destination->name + "\"");
    }
    if (EditResult r = requireNumeric(newStart_, "new start"); !r) {
        return r;
    }
    const CMTime newStart = snapToSequence(sequence, newStart_);
    if (newStart < kCMTimeZero) {
        return EditResult::failure(EditError::InvalidTime, "cannot move a clip before time zero");
    }
    const CMTime delta = newStart - clip->timelineStart;

    struct Move {
        ClipId clipId;
        TrackId from;
        TrackId to;
    };
    std::vector<Move> moves{{clip->id, track->id, destination->id}};
    if (includeLinked_ && clip->linkedClipId) {
        Track *partnerTrack = nullptr;
        Clip *partner = nullptr;
        if (EditResult r = findEditableClip(sequence, *clip->linkedClipId, partnerTrack, partner); !r) {
            return r;
        }
        if (partner->timelineStart + delta < kCMTimeZero) {
            return EditResult::failure(EditError::InvalidTime, "the linked clip would start before time zero");
        }
        moves.push_back({partner->id, partnerTrack->id, partnerTrack->id});
    }
    if (delta == kCMTimeZero && destination->id == track->id) {
        return EditResult::success();
    }

    std::vector<Clip> lifted;
    for (const Move &move : moves) {
        Clip moved = removeClip(*sequence.findTrack(move.from), move.clipId);
        moved.timelineStart = moved.timelineStart + delta;
        moved.trackId = move.to;
        lifted.push_back(std::move(moved));
    }
    if (lifted.size() == 2 && lifted[0].trackId == lifted[1].trackId &&
        lifted[0].timelineRange().intersects(lifted[1].timelineRange())) {
        return EditResult::failure(EditError::Overlap, "the clip and its linked clip would overlap");
    }
    SplitList splits;
    for (Clip &moved : lifted) {
        Track &target = *sequence.findTrack(moved.trackId);
        if (EditResult r = clearRange(sequence, target, moved.timelineRange(), ids, splits); !r) {
            return r;
        }
        insertClipSorted(target, std::move(moved));
    }
    relinkSplitPieces(sequence, splits);
    return EditResult::success();
}

// ----- TrimClipHead / TrimClipTail -----

TrimClipHead::TrimClipHead(SequenceId sequenceId, ClipId clipId, CMTime newStart, TrimOptions options)
    : SequenceCommand(sequenceId), clipId_(clipId), newStart_(newStart), options_(options) {
    setCoalescingKey("trimHead:" + idString(clipId.value()));
}

EditResult TrimClipHead::perform(const Project &, Sequence &sequence, IdGenerator &) {
    std::vector<ClipId> targets;
    if (EditResult r = clipAndPartner(sequence, clipId_, options_.includeLinked, targets); !r) {
        return r;
    }
    if (EditResult r = requireNumeric(newStart_, "new start"); !r) {
        return r;
    }
    const CMTime frame = sequence.frameDuration;
    const Clip &primary = *sequence.findClip(clipId_);
    CMTime delta = snapToSequence(sequence, newStart_) - primary.timelineStart;

    DeltaLimits limits;
    for (const ClipId clipId : targets) {
        const Track &track = *sequence.trackOfClip(clipId);
        const std::size_t index = *track.indexOf(clipId);
        const Clip &clip = track.clips[index];
        const std::string which = clipId == clipId_ ? "" : " of the linked clip";
        limits.raiseLo(-clip.timelineStart, EditError::InvalidTime, "time zero" + which);
        if (index > 0) {
            limits.raiseLo(track.clips[index - 1].timelineEnd() - clip.timelineStart, EditError::Overlap,
                           "the previous clip" + which);
        }
        if (!clip.isStill) {
            // The earliest whole frame at which the source media has started.
            const auto mediaStart = clip.exactTimelineTimeAt(kCMTimeZero);
            const auto frameIndex = mediaStart ? mediaStart->frameIndex(frame, SnapMode::Ceil) : std::nullopt;
            const auto earliest = frameIndex ? checkedTimeForFrame(*frameIndex, frame) : std::nullopt;
            if (!earliest) {
                return notRepresentable(clip.id, kCMTimeZero);
            }
            limits.raiseLo(*earliest - clip.timelineStart, EditError::OutOfSourceRange,
                           "the start of the source media" + which);
        }
        limits.lowerHi(clip.timelineEnd() - frame - clip.timelineStart, EditError::InvalidTime,
                       "the minimum length of one frame" + which);
    }
    if (EditResult r = limits.resolve(delta, options_.clampToLimits); !r) {
        return r;
    }
    if (delta == kCMTimeZero) {
        return EditResult::success();
    }
    for (const ClipId clipId : targets) {
        Clip &clip = *sequence.findClip(clipId);
        const CMTime newStart = clip.timelineStart + delta;
        if (EditResult r = retimeRefusal(clip.setTimelineStartKeepingEnd(newStart), clip.id, newStart); !r) {
            return r;
        }
    }
    return EditResult::success();
}

TrimClipTail::TrimClipTail(SequenceId sequenceId, ClipId clipId, CMTime newEnd, TrimOptions options)
    : SequenceCommand(sequenceId), clipId_(clipId), newEnd_(newEnd), options_(options) {
    setCoalescingKey("trimTail:" + idString(clipId.value()));
}

EditResult TrimClipTail::perform(const Project &project, Sequence &sequence, IdGenerator &) {
    std::vector<ClipId> targets;
    if (EditResult r = clipAndPartner(sequence, clipId_, options_.includeLinked, targets); !r) {
        return r;
    }
    if (EditResult r = requireNumeric(newEnd_, "new end"); !r) {
        return r;
    }
    const CMTime frame = sequence.frameDuration;
    const Clip &primary = *sequence.findClip(clipId_);
    CMTime delta = snapToSequence(sequence, newEnd_) - primary.timelineEnd();

    DeltaLimits limits;
    for (const ClipId clipId : targets) {
        const Track &track = *sequence.trackOfClip(clipId);
        const std::size_t index = *track.indexOf(clipId);
        const Clip &clip = track.clips[index];
        const CMTime end = clip.timelineEnd();
        const std::string which = clipId == clipId_ ? "" : " of the linked clip";
        if (index + 1 < track.clips.size()) {
            limits.lowerHi(track.clips[index + 1].timelineStart - end, EditError::Overlap, "the next clip" + which);
        }
        if (!clip.isStill) {
            const MediaAsset *asset = project.findAsset(clip.assetId);
            if (!asset) {
                return EditResult::failure(EditError::AssetNotFound, "the clip's asset is missing");
            }
            // The last whole frame at which the source media (on a video track: its video) still
            // lasts.
            const CMTime sourceEnd = mediaEndFor(*asset, track.kind);
            const auto mediaEnd = clip.exactTimelineTimeAt(sourceEnd);
            const auto frameIndex = mediaEnd ? mediaEnd->frameIndex(frame, SnapMode::Floor) : std::nullopt;
            const auto latest = frameIndex ? checkedTimeForFrame(*frameIndex, frame) : std::nullopt;
            if (!latest) {
                return notRepresentable(clip.id, sourceEnd);
            }
            limits.lowerHi(*latest - end, EditError::OutOfSourceRange,
                           std::string(track.kind == TrackKind::Video && sourceEnd < asset->duration
                                           ? "the end of the media's video"
                                           : "the end of the source media") +
                               which);
        }
        limits.raiseLo(clip.timelineStart + frame - end, EditError::InvalidTime,
                       "the minimum length of one frame" + which);
    }
    if (EditResult r = limits.resolve(delta, options_.clampToLimits); !r) {
        return r;
    }
    if (delta == kCMTimeZero) {
        return EditResult::success();
    }
    for (const ClipId clipId : targets) {
        Clip &clip = *sequence.findClip(clipId);
        const CMTime newEnd = clip.timelineEnd() + delta;
        if (EditResult r = retimeRefusal(clip.setTimelineEnd(newEnd), clip.id, newEnd); !r) {
            return r;
        }
    }
    return EditResult::success();
}

// ----- SplitClip -----

SplitClip::SplitClip(SequenceId sequenceId, ClipId clipId, CMTime at, bool includeLinked)
    : SplitClip(sequenceId, clipId, at, SplitOptions{includeLinked, false}) {}

SplitClip::SplitClip(SequenceId sequenceId, ClipId clipId, CMTime at, SplitOptions options)
    : SequenceCommand(sequenceId), clipId_(clipId), at_(at), options_(options) {}

EditResult SplitClip::perform(const Project &, Sequence &sequence, IdGenerator &ids) {
    std::vector<ClipId> targets;
    if (EditResult r = clipAndPartner(sequence, clipId_, options_.includeLinked, targets); !r) {
        return r;
    }
    if (EditResult r = requireNumeric(at_, "split time"); !r) {
        return r;
    }
    const CMTime at = snapToSequence(sequence, at_);
    const Clip &primary = *sequence.findClip(clipId_);
    if (!(primary.timelineStart < at && at < primary.timelineEnd())) {
        return EditResult::failure(EditError::InvalidTime,
                                   "split time " + describe(at) + " is not inside clip " + idString(clipId_.value()));
    }
    // Clips that will be split (a linked clip that does not span the split time stays whole).
    std::vector<ClipId> splitting;
    for (const ClipId clipId : targets) {
        const Clip &clip = *sequence.findClip(clipId);
        if (clip.timelineStart < at && at < clip.timelineEnd()) {
            splitting.push_back(clipId);
        }
    }
    // Transitions acting on a clip being split, around the split time: refused, or removed when
    // allowed (reported as dropped).
    std::vector<std::pair<ClipId, SpanId>> broken;
    for (const ClipId clipId : splitting) {
        const Track &track = *sequence.trackOfClip(clipId);
        for (const TransitionPlacement &transition : transitionsOn(track, *track.find(clipId))) {
            if (!(transition.range.start < at && at < transition.range.end)) {
                continue;
            }
            if (!options_.allowBreakingTransitions) {
                return EditResult::failure(EditError::InsideTransition,
                                           "split time " + describe(at) + " is inside transition " +
                                               idString(transition.span->id.value()) + " (" +
                                               describe(transition.range.start) + " - " +
                                               describe(transition.range.end) + "); remove or shorten it first");
            }
            broken.emplace_back(transition.owner->id, transition.span->id);
        }
    }
    for (const auto &[owner, spanId] : broken) {
        std::erase_if(sequence.findClip(owner)->spans, [spanId](const EffectSpan &span) { return span.id == spanId; });
    }
    created_.clear();
    SplitList splits;
    for (const ClipId clipId : splitting) {
        Track &track = *sequence.trackOfClip(clipId);
        ClipId right;
        if (EditResult r = splitClipAt(sequence, track, *track.indexOf(clipId), at, ids, right); !r) {
            return r;
        }
        splits.emplace_back(clipId, right);
        created_.push_back(right);
    }
    relinkSplitPieces(sequence, splits);
    return EditResult::success();
}

// ----- RemoveClips / RippleDelete -----

RemoveClips::RemoveClips(SequenceId sequenceId, std::vector<ClipId> clipIds, bool includeLinked)
    : SequenceCommand(sequenceId), clipIds_(std::move(clipIds)), includeLinked_(includeLinked) {}

EditResult RemoveClips::perform(const Project &, Sequence &sequence, IdGenerator &) {
    std::vector<ClipId> all;
    if (EditResult r = collectClips(sequence, clipIds_, includeLinked_, all); !r) {
        return r;
    }
    for (const ClipId clipId : all) {
        removeClip(*sequence.trackOfClip(clipId), clipId);
    }
    return EditResult::success();
}

RippleDelete::RippleDelete(SequenceId sequenceId, std::vector<ClipId> clipIds, RippleOptions options)
    : SequenceCommand(sequenceId), clipIds_(std::move(clipIds)), options_(options) {}

EditResult RippleDelete::perform(const Project &, Sequence &sequence, IdGenerator &) {
    std::vector<ClipId> all;
    if (EditResult r = collectClips(sequence, clipIds_, options_.includeLinked, all); !r) {
        return r;
    }
    std::vector<TimeRange> removed;
    std::vector<TrackId> seeds;
    for (const ClipId clipId : all) {
        Track &track = *sequence.trackOfClip(clipId);
        const Clip clip = removeClip(track, clipId);
        removed.push_back(clip.timelineRange());
        if (std::find(seeds.begin(), seeds.end(), track.id) == seeds.end()) {
            seeds.push_back(track.id);
        }
    }
    const std::vector<TimeRange> merged = mergeRanges(removed);
    std::unordered_set<TrackId> tracks;
    if (EditResult r = rippleTracks(sequence, options_.scope, seeds, merged.front().start, tracks); !r) {
        return r;
    }
    return closeTime(sequence, tracks, merged);
}

// ----- Clip parameters -----

SetVideoParams::SetVideoParams(SequenceId sequenceId, ClipId clipId, VideoParams params, std::string name)
    : SequenceCommand(sequenceId), clipId_(clipId), params_(params), name_(std::move(name)) {
    setCoalescingKey("videoParams:" + idString(clipId.value()));
}

EditResult SetVideoParams::perform(const Project &, Sequence &sequence, IdGenerator &) {
    Track *track = nullptr;
    Clip *clip = nullptr;
    if (EditResult r = findEditableClip(sequence, clipId_, track, clip); !r) {
        return r;
    }
    if (EditResult r = checkVideoParams(params_); !r) {
        return r;
    }
    clip->video = params_;
    return EditResult::success();
}

SetAudioParams::SetAudioParams(SequenceId sequenceId, ClipId clipId, AudioParams params)
    : SequenceCommand(sequenceId), clipId_(clipId), params_(params) {
    setCoalescingKey("audioParams:" + idString(clipId.value()));
}

EditResult SetAudioParams::perform(const Project &, Sequence &sequence, IdGenerator &) {
    Track *track = nullptr;
    Clip *clip = nullptr;
    if (EditResult r = findEditableClip(sequence, clipId_, track, clip); !r) {
        return r;
    }
    if (EditResult r = checkAudioParams(params_); !r) {
        return r;
    }
    clip->audio = params_;
    return EditResult::success();
}

SetClipsParams::SetClipsParams(SequenceId sequenceId, std::vector<ClipParamsChange> changes)
    : SequenceCommand(sequenceId), changes_(std::move(changes)) {
    std::string key = "clipsParams";
    for (const ClipParamsChange &change : changes_) {
        key += ":" + idString(change.clipId.value());
    }
    setCoalescingKey(std::move(key));
}

std::string SetClipsParams::name() const {
    const bool video = std::any_of(changes_.begin(), changes_.end(), [](const auto &c) { return c.video.has_value(); });
    const bool audio = std::any_of(changes_.begin(), changes_.end(), [](const auto &c) {
        return c.audio.has_value() || c.fadeIn.has_value() || c.fadeOut.has_value();
    });
    if (video && !audio) {
        return "Change Video Settings";
    }
    if (audio && !video) {
        return "Change Audio Settings";
    }
    return "Change Clip Settings";
}

EditResult SetClipsParams::perform(const Project &, Sequence &sequence, IdGenerator &ids) {
    if (changes_.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "no clips to change");
    }
    std::unordered_set<ClipId> seen;
    for (const ClipParamsChange &change : changes_) {
        if (!seen.insert(change.clipId).second) {
            return EditResult::failure(EditError::InvalidArgument,
                                       "clip " + idString(change.clipId.value()) + " is listed twice");
        }
        Track *track = nullptr;
        Clip *clip = nullptr;
        if (EditResult r = findEditableClip(sequence, change.clipId, track, clip); !r) {
            return r;
        }
        if (change.video) {
            if (track->kind != TrackKind::Video) {
                return EditResult::failure(EditError::TrackKindMismatch,
                                           "clip " + idString(change.clipId.value()) + " is not on a video track");
            }
            if (EditResult r = checkVideoParams(*change.video); !r) {
                return r;
            }
            clip->video = *change.video;
        }
        if (change.audio || change.fadeIn || change.fadeOut) {
            if (track->kind != TrackKind::Audio) {
                return EditResult::failure(EditError::TrackKindMismatch,
                                           "clip " + idString(change.clipId.value()) + " is not on an audio track");
            }
        }
        if (change.audio) {
            if (EditResult r = checkAudioParams(*change.audio); !r) {
                return r;
            }
            clip->audio = *change.audio;
        }
        // With both fades changing, the one that shrinks goes first, so the clip never holds two
        // fades that meet on the way to two that fit (each is checked against the other).
        std::vector<std::pair<ClipEdge, CMTime>> fades;
        if (change.fadeIn) {
            fades.emplace_back(ClipEdge::Head, *change.fadeIn);
        }
        if (change.fadeOut) {
            const bool inGrows = change.fadeIn && isNumeric(*change.fadeIn) &&
                                 clipFadeLength(*clip, ClipEdge::Head) < *change.fadeIn;
            fades.insert(inGrows ? fades.begin() : fades.end(), std::make_pair(ClipEdge::Tail, *change.fadeOut));
        }
        for (const auto &[edge, length] : fades) {
            if (EditResult r = setClipFade(*clip, *track, edge, length, ids); !r) {
                return r;
            }
        }
    }
    return EditResult::success();
}

SetClipSpeed::SetClipSpeed(SequenceId sequenceId, ClipId clipId, Ratio speed, SpeedOptions options)
    : SequenceCommand(sequenceId), clipId_(clipId), speed_(speed), options_(options) {
    setCoalescingKey("speed:" + idString(clipId.value()));
}

SetClipSpeed::SetClipSpeed(SequenceId sequenceId, ClipId clipId, double speed, SpeedOptions options)
    : SetClipSpeed(sequenceId, clipId, speedFromDouble(speed), options) {}

EditResult SetClipSpeed::perform(const Project &project, Sequence &sequence, IdGenerator &ids) {
    std::vector<ClipId> targets;
    if (EditResult r = clipAndPartner(sequence, clipId_, options_.includeLinked, targets); !r) {
        return r;
    }
    if (EditResult r = checkSpeed(speed_); !r) {
        return r;
    }
    const CMTime frame = sequence.frameDuration;

    struct Change {
        ClipId clipId;
        CMTime newDuration;
        CMTime oldEnd;
        CMTime newEnd;
    };
    std::vector<Change> changes;
    for (const ClipId clipId : targets) {
        const Track &track = *sequence.trackOfClip(clipId);
        const std::size_t index = *track.indexOf(clipId);
        const Clip &clip = track.clips[index];
        if (clip.isStill) {
            return EditResult::failure(EditError::InvalidArgument, "still images have no speed");
        }
        const MediaAsset *asset = project.findAsset(clip.assetId);
        if (!asset) {
            return EditResult::failure(EditError::AssetNotFound, "the clip's asset is missing");
        }
        // Whole frames the clip's source range fills at the new speed, rounded down (so the out
        // point never moves later), at least one frame, and never past the end of the media.
        const auto in = ExactTime::from(clip.sourceIn);
        const auto sourceOut = clip.exactSourceOut();
        const auto mediaEnd = ExactTime::from(mediaEndFor(*asset, track.kind));
        if (!in || !sourceOut || !mediaEnd) {
            return notRepresentable(clip.id, clip.timelineStart);
        }
        auto framesFor = [&](const ExactTime &sourceEnd) -> std::optional<std::int64_t> {
            const auto length = sourceEnd.minus(*in);
            const auto timeline = length ? length->dividedBy(speed_) : std::nullopt;
            return timeline ? timeline->frameIndex(frame, SnapMode::Floor) : std::nullopt;
        };
        auto frames = framesFor(*sourceOut);
        if (!frames) {
            return notRepresentable(clip.id, clip.timelineStart);
        }
        if (*frames < 1) {
            // One frame, if the media lasts that long at this speed.
            frames = std::min<std::int64_t>(1, framesFor(*mediaEnd).value_or(0));
            if (*frames < 1) {
                return EditResult::failure(EditError::OutOfSourceRange,
                                           "not enough source media for one frame at this speed");
            }
        }
        const auto newDuration = checkedTimeForFrame(*frames, frame);
        if (!newDuration) {
            return notRepresentable(clip.id, clip.timelineStart);
        }
        const CMTime newEnd = clip.timelineStart + *newDuration;
        if (!options_.ripple && index + 1 < track.clips.size() && newEnd > track.clips[index + 1].timelineStart) {
            return EditResult::failure(EditError::Overlap,
                                       "the clip would overlap the next clip; use ripple to push it along");
        }
        changes.push_back({clipId, *newDuration, clip.timelineEnd(), newEnd});
    }

    const CMTime oldEnd = changes.front().oldEnd;
    const CMTime delta = changes.front().newEnd - oldEnd;
    if (options_.ripple) {
        for (const Change &change : changes) {
            if (change.oldEnd != oldEnd || change.newEnd != changes.front().newEnd) {
                return EditResult::failure(EditError::InvalidArgument,
                                           "the clip and its linked clip end at different times, so a ripple would "
                                           "move their tracks by different amounts; unlink them or turn ripple off");
            }
        }
    }
    const bool rippling = options_.ripple && delta != kCMTimeZero;
    std::unordered_set<TrackId> rippled;
    if (rippling) {
        std::vector<TrackId> seeds;
        for (const Change &change : changes) {
            seeds.push_back(sequence.trackOfClip(change.clipId)->id);
        }
        if (EditResult r = rippleTracks(sequence, options_.scope, seeds, oldEnd, rippled); !r) {
            return r;
        }
        if (kCMTimeZero < delta) {
            SplitList splits;
            if (EditResult r = openTime(sequence, rippled, oldEnd, delta, ids, splits); !r) {
                return r;
            }
            relinkSplitPieces(sequence, splits);
        }
    }
    for (const Change &change : changes) {
        Clip &clip = *sequence.findClip(change.clipId);
        clip.speed = speed_;
        clip.timelineDuration = change.newDuration;
        // Spans stay on their pictures: those past the new out point are clipped there.
        if (EditResult r = retimeRefusal(clip.fitSpans(ClipEdge::Tail), clip.id, clip.timelineEnd()); !r) {
            return r;
        }
    }
    if (rippling && delta < kCMTimeZero) {
        return closeTime(sequence, rippled, {TimeRange{changes.front().newEnd, oldEnd}});
    }
    return EditResult::success();
}

// ----- Effect spans -----

namespace {

std::string spanName(SpanId id) {
    return "span " + idString(id.value());
}

EditResult spanNotFound(SpanId id) {
    return EditResult::failure(EditError::SpanNotFound, spanName(id) + " does not exist");
}

// The effect span `spanId` (lanes 1-3), its clip and track, on an editable track.
EditResult findEffectSpan(Sequence &sequence, SpanId spanId, Track *&track, Clip *&clip, EffectSpan *&span) {
    span = sequence.findSpan(spanId, &clip, &track);
    if (span == nullptr) {
        return spanNotFound(spanId);
    }
    if (span->isTransition()) {
        return EditResult::failure(EditError::InvalidArgument,
                                   spanName(spanId) + " is a transition; change it with the transition edits");
    }
    return requireEditableTrack(track, track->id);
}

EditResult checkLane(int lane) {
    if (lane < kFirstEffectLane || lane > kLastLane) {
        return EditResult::failure(EditError::InvalidArgument, "effect spans live on lanes " +
                                                                   std::to_string(kFirstEffectLane) + " to " +
                                                                   std::to_string(kLastLane) + ", not lane " +
                                                                   std::to_string(lane));
    }
    return EditResult::success();
}

EditResult checkSpanKind(SpanKind kind, TrackKind trackKind) {
    if (kind == SpanKind::Transition) {
        return EditResult::failure(EditError::InvalidArgument, "a transition is added with the transition edits");
    }
    const bool video = kind == SpanKind::Motion || kind == SpanKind::Opacity;
    if (video != (trackKind == TrackKind::Video)) {
        return EditResult::failure(EditError::TrackKindMismatch, std::string("a ") + nameOf(kind) +
                                                                     " span cannot go on a clip of " +
                                                                     nameOf(trackKind) + " track");
    }
    return EditResult::success();
}

EditResult checkSpanValue(SpanParameter parameter, double value) {
    if (!isValidSpanValue(parameter, value)) {
        return EditResult::failure(EditError::InvalidArgument,
                                   std::string(displayNameOf(parameter)) + " cannot be " + std::to_string(value) +
                                       (parameter == SpanParameter::Opacity ? " (it is within 0...1)"
                                        : parameter == SpanParameter::Scale ? " (it is at least 0)"
                                                                            : " (it must be finite)"));
    }
    return EditResult::success();
}

EditResult checkInterpolation(KeyframeInterpolation interpolation) {
    if (interpolation == KeyframeInterpolation::Bezier) {
        return EditResult::failure(EditError::InvalidArgument,
                                   "a custom curve comes only from dividing an eased segment (a split); choose hold, "
                                   "linear or an ease");
    }
    return EditResult::success();
}

// The source range of an effect span over the timeline frames [timelineStart, timelineEnd) of
// `clip` (rounded to the frame grid): at least one frame, within the clip. `frames` receives the
// snapped timeline range.
EditResult spanSourceRange(const Sequence &sequence, const Clip &clip, CMTime timelineStart, CMTime timelineEnd,
                           CMTime &start, CMTime &end, TimeRange &frames) {
    if (EditResult r = requireNumeric(timelineStart, "span start"); !r) {
        return r;
    }
    if (EditResult r = requireNumeric(timelineEnd, "span end"); !r) {
        return r;
    }
    frames = TimeRange{snapToSequence(sequence, timelineStart), snapToSequence(sequence, timelineEnd)};
    if (!(frames.start < frames.end)) {
        return EditResult::failure(EditError::InvalidArgument, "a span covers at least one frame");
    }
    if (frames.start < clip.timelineStart || clip.timelineEnd() < frames.end) {
        return EditResult::failure(EditError::InvalidTime, "the span " + describe(frames.start) + " - " +
                                                               describe(frames.end) + " is not within clip " +
                                                               idString(clip.id.value()) + " (" +
                                                               describe(clip.timelineStart) + " - " +
                                                               describe(clip.timelineEnd()) + ")");
    }
    const auto from = spanTimeAt(clip, frames.start);
    const auto to = spanTimeAt(clip, frames.end);
    if (!from || !to) {
        return notRepresentable(clip.id, frames.start);
    }
    if (!(*from < *to)) {
        return EditResult::failure(EditError::InvalidArgument, "the span covers no source time of clip " +
                                                                   idString(clip.id.value()));
    }
    start = *from;
    end = *to;
    return EditResult::success();
}

// Refusal (Overlap, with the nearest free range) when [start, end) meets another span of `lane`.
EditResult checkLaneFree(const Sequence &sequence, const Clip &clip, int lane, CMTime start, CMTime end,
                         const TimeRange &frames, SpanId except) {
    for (const EffectSpan &other : clip.spans) {
        if (other.isTransition() || other.lane != lane || other.id == except) {
            continue;
        }
        if (other.start < end && start < other.end) {
            EditResult refusal = EditResult::failure(
                EditError::Overlap, "lane " + std::to_string(lane) + " of clip " + idString(clip.id.value()) +
                                        " already has " + spanName(other.id) + " there");
            refusal.freeRange = nearestFreeRange(clip, lane, sequence.frameDuration, frames, except);
            if (refusal.freeRange) {
                refusal.message += "; the nearest free range is " + describe(refusal.freeRange->start) + " - " +
                                   describe(refusal.freeRange->end);
            } else {
                refusal.message += "; the lane has no free frame";
            }
            return refusal;
        }
    }
    return EditResult::success();
}

Keyframe keyframeAt(CMTime time, double value, KeyframeInterpolation interpolation) {
    Keyframe keyframe;
    keyframe.time = time;
    keyframe.value = value;
    keyframe.interpolation = interpolation;
    return keyframe;
}

} // namespace

std::optional<TimeRange> spanTimelineRange(const Clip &clip, const EffectSpan &span, const Track &track) {
    if (span.isTransition()) {
        const auto placement = placeTransition(track, clip, span);
        return placement ? std::optional<TimeRange>(placement->range) : std::nullopt;
    }
    const auto start = clip.exactTimelineTimeAt(span.start);
    const auto end = clip.exactTimelineTimeAt(span.end);
    if (!start || !end) {
        return std::nullopt;
    }
    return TimeRange{start->toTimeRounded(), end->toTimeRounded()};
}

std::vector<TimeRange> freeLaneRanges(const Clip &clip, int lane, CMTime frameDuration, SpanId except) {
    std::vector<TimeRange> occupied;
    for (const EffectSpan &span : clip.spans) {
        if (span.isTransition() || span.lane != lane || span.id == except) {
            continue;
        }
        const auto start = clip.exactTimelineTimeAt(span.start);
        const auto end = clip.exactTimelineTimeAt(span.end);
        const auto first = start ? start->frameIndex(frameDuration, SnapMode::Floor) : std::nullopt;
        const auto past = end ? end->frameIndex(frameDuration, SnapMode::Ceil) : std::nullopt;
        if (first && past) {
            occupied.push_back(TimeRange{timeForFrame(*first, frameDuration), timeForFrame(*past, frameDuration)});
        }
    }
    std::sort(occupied.begin(), occupied.end(), [](const TimeRange &a, const TimeRange &b) { return a.start < b.start; });
    std::vector<TimeRange> free;
    CMTime cursor = clip.timelineStart;
    for (const TimeRange &range : occupied) {
        if (cursor < range.start) {
            free.push_back(TimeRange{cursor, minTime(range.start, clip.timelineEnd())});
        }
        cursor = maxTime(cursor, range.end);
    }
    if (cursor < clip.timelineEnd()) {
        free.push_back(TimeRange{cursor, clip.timelineEnd()});
    }
    return free;
}

std::optional<TimeRange> nearestFreeRange(const Clip &clip, int lane, CMTime frameDuration, TimeRange requested,
                                          SpanId except) {
    std::optional<TimeRange> best;
    double bestOverlap = -1.0;
    double bestDistance = 0.0;
    for (const TimeRange &range : freeLaneRanges(clip, lane, frameDuration, except)) {
        const auto overlap = intersection(range, requested);
        const double seconds = overlap ? toSeconds(overlap->duration()) : 0.0;
        const double distance = overlap ? 0.0
                                        : std::min(std::fabs(toSeconds(range.start - requested.end)),
                                                   std::fabs(toSeconds(requested.start - range.end)));
        if (!best || seconds > bestOverlap || (seconds == bestOverlap && distance < bestDistance)) {
            best = range;
            bestOverlap = seconds;
            bestDistance = distance;
        }
    }
    return best;
}

bool spanValuesMatch(SpanParameter, double a, double b) {
    if (!std::isfinite(a) || !std::isfinite(b)) {
        return a == b;
    }
    const double magnitude = std::max({1.0, std::abs(a), std::abs(b)});
    return std::abs(a - b) <= 1e-6 * magnitude;
}

const Clip *adjacentClip(const Sequence &sequence, ClipId clipId, ClipEdge edge) {
    const Track *track = sequence.trackOfClip(clipId);
    const Clip *clip = track != nullptr ? track->find(clipId) : nullptr;
    return clip != nullptr ? touchingClip(*track, *clip, edge) : nullptr;
}

AddSpan::AddSpan(SequenceId sequenceId, ClipId clipId, SpanKind kind, int lane, CMTime timelineStart,
                 CMTime timelineEnd)
    : SequenceCommand(sequenceId), clipId_(clipId), kind_(kind), lane_(lane), start_(timelineStart),
      end_(timelineEnd) {}

std::string AddSpan::name() const {
    return std::string("Add ") + displayNameOf(kind_) + " Span";
}

EditResult AddSpan::perform(const Project &, Sequence &sequence, IdGenerator &ids) {
    Track *track = nullptr;
    Clip *clip = nullptr;
    if (EditResult r = findEditableClip(sequence, clipId_, track, clip); !r) {
        return r;
    }
    if (EditResult r = checkSpanKind(kind_, track->kind); !r) {
        return r;
    }
    if (EditResult r = checkLane(lane_); !r) {
        return r;
    }
    CMTime start = kCMTimeZero;
    CMTime end = kCMTimeZero;
    TimeRange frames;
    if (EditResult r = spanSourceRange(sequence, *clip, start_, end_, start, end, frames); !r) {
        return r;
    }
    if (EditResult r = checkLaneFree(sequence, *clip, lane_, start, end, frames, SpanId{}); !r) {
        return r;
    }
    const auto length = checkedSubtract(end, start);
    if (!length || !isExactModelTime(*length)) {
        return notRepresentable(clip->id, frames.end);
    }
    EffectSpan span;
    span.id = ids.make<SpanId>();
    span.lane = lane_;
    span.kind = kind_;
    span.start = start;
    span.end = end;
    for (const SpanParameter parameter : parametersOf(kind_)) {
        const double neutral = neutralValue(parameter);
        span.tracks.track(parameter) = {keyframeAt(kCMTimeZero, neutral, KeyframeInterpolation::Linear),
                                        keyframeAt(*length, neutral, KeyframeInterpolation::Linear)};
    }
    created_ = span.id;
    clip->spans.push_back(std::move(span));
    clip->sortSpans();
    return EditResult::success();
}

SetSpanRange::SetSpanRange(SequenceId sequenceId, SpanId spanId, CMTime timelineStart, CMTime timelineEnd)
    : SequenceCommand(sequenceId), spanId_(spanId), start_(timelineStart), end_(timelineEnd) {
    setCoalescingKey("spanRange:" + idString(spanId.value()));
}

EditResult SetSpanRange::perform(const Project &, Sequence &sequence, IdGenerator &) {
    Track *track = nullptr;
    Clip *clip = nullptr;
    EffectSpan *span = nullptr;
    if (EditResult r = findEffectSpan(sequence, spanId_, track, clip, span); !r) {
        return r;
    }
    CMTime start = kCMTimeZero;
    CMTime end = kCMTimeZero;
    TimeRange frames;
    if (EditResult r = spanSourceRange(sequence, *clip, start_, end_, start, end, frames); !r) {
        return r;
    }
    if (identical(start, span->start) && identical(end, span->end)) {
        return EditResult::success();
    }
    if (EditResult r = checkLaneFree(sequence, *clip, span->lane, start, end, frames, span->id); !r) {
        return r;
    }
    const auto oldLength = checkedSubtract(span->end, span->start);
    const auto newLength = checkedSubtract(end, start);
    if (!oldLength || !newLength || !isExactModelTime(*newLength)) {
        return notRepresentable(clip->id, frames.start);
    }
    EffectSpan moved = *span;
    moved.start = start;
    moved.end = end;
    if (!(*oldLength == *newLength)) {
        // A trim: the keyframes stretch over the new length, keeping their places in the span.
        for (const SpanParameter parameter : kSpanParameters) {
            KeyframeTrack &keys = moved.tracks.track(parameter);
            if (keys.empty()) {
                continue;
            }
            auto rescaled = rescaleTrack(keys, *newLength, *oldLength);
            if (!rescaled) {
                return notRepresentable(clip->id, frames.start);
            }
            keys = std::move(*rescaled);
            // The end keyframe lands exactly on the new length.
            if (keys.back().time != *newLength && span->tracks.track(parameter).back().time == *oldLength) {
                keys.back().time = *newLength;
            }
        }
    }
    *span = std::move(moved);
    clip->sortSpans();
    return EditResult::success();
}

SetSpanValues::SetSpanValues(SequenceId sequenceId, SpanId spanId, std::vector<SpanValueChange> changes,
                             std::string name, std::optional<KeyframeInterpolation> interpolation)
    : SequenceCommand(sequenceId), spanId_(spanId), changes_(std::move(changes)), name_(std::move(name)),
      interpolation_(interpolation) {
    setCoalescingKey("spanValues:" + idString(spanId.value()));
}

EditResult SetSpanValues::perform(const Project &, Sequence &sequence, IdGenerator &) {
    if (changes_.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "no values to change");
    }
    Track *track = nullptr;
    Clip *clip = nullptr;
    EffectSpan *span = nullptr;
    if (EditResult r = findEffectSpan(sequence, spanId_, track, clip, span); !r) {
        return r;
    }
    const auto length = checkedSubtract(span->end, span->start);
    if (!length) {
        return notRepresentable(clip->id, clip->timelineStart);
    }
    if (interpolation_) {
        if (EditResult r = checkInterpolation(*interpolation_); !r) {
            return r;
        }
    }
    const KeyframeInterpolation easing = spanInterpolation(*span);
    EffectSpan updated = *span;
    std::vector<SpanParameter> seen;
    for (const SpanValueChange &change : changes_) {
        if (!kindHasParameter(span->kind, change.parameter)) {
            return EditResult::failure(EditError::InvalidArgument,
                                       std::string("a ") + nameOf(span->kind) + " span has no " +
                                           displayNameOf(change.parameter));
        }
        if (std::find(seen.begin(), seen.end(), change.parameter) != seen.end()) {
            return EditResult::failure(EditError::InvalidArgument,
                                       std::string(displayNameOf(change.parameter)) + " is listed twice");
        }
        seen.push_back(change.parameter);
        KeyframeTrack &keys = updated.tracks.track(change.parameter);
        const bool wasEmpty = keys.empty();
        const double neutral = neutralValue(change.parameter);
        for (const auto &[time, value] : {std::pair{kCMTimeZero, change.start}, std::pair{*length, change.end}}) {
            if (!value) {
                continue;
            }
            if (EditResult r = checkSpanValue(change.parameter, *value); !r) {
                return r;
            }
            keys[insertKeyframeKeepingValues(keys, neutral, time)].value = *value;
        }
        if (wasEmpty && easing != KeyframeInterpolation::Bezier) {
            // A new track moves like the span's other tracks.
            for (Keyframe &keyframe : keys) {
                keyframe.interpolation = easing;
            }
        }
    }
    if (interpolation_) {
        for (const SpanParameter parameter : kSpanParameters) {
            for (Keyframe &keyframe : updated.tracks.track(parameter)) {
                keyframe.interpolation = *interpolation_;
                keyframe.curve = TimingCurve{};
            }
        }
    }
    if (auto problem = spanTracksProblem(updated)) {
        return EditResult::failure(EditError::InvalidArgument, *problem);
    }
    *span = std::move(updated);
    return EditResult::success();
}

SetSpanInterpolation::SetSpanInterpolation(SequenceId sequenceId, SpanId spanId, KeyframeInterpolation interpolation)
    : SequenceCommand(sequenceId), spanId_(spanId), interpolation_(interpolation) {
    setCoalescingKey("spanInterpolation:" + idString(spanId.value()));
}

EditResult SetSpanInterpolation::perform(const Project &, Sequence &sequence, IdGenerator &) {
    Track *track = nullptr;
    Clip *clip = nullptr;
    EffectSpan *span = nullptr;
    if (EditResult r = findEffectSpan(sequence, spanId_, track, clip, span); !r) {
        return r;
    }
    if (EditResult r = checkInterpolation(interpolation_); !r) {
        return r;
    }
    for (const SpanParameter parameter : kSpanParameters) {
        for (Keyframe &keyframe : span->tracks.track(parameter)) {
            keyframe.interpolation = interpolation_;
            keyframe.curve = TimingCurve{};
        }
    }
    return EditResult::success();
}

MoveSpanLane::MoveSpanLane(SequenceId sequenceId, SpanId spanId, int lane)
    : SequenceCommand(sequenceId), spanId_(spanId), lane_(lane) {
    setCoalescingKey("spanLane:" + idString(spanId.value()));
}

EditResult MoveSpanLane::perform(const Project &, Sequence &sequence, IdGenerator &) {
    Track *track = nullptr;
    Clip *clip = nullptr;
    EffectSpan *span = nullptr;
    if (EditResult r = findEffectSpan(sequence, spanId_, track, clip, span); !r) {
        return r;
    }
    if (EditResult r = checkLane(lane_); !r) {
        return r;
    }
    if (span->lane == lane_) {
        return EditResult::success();
    }
    const TimeRange frames = spanTimelineRange(*clip, *span, *track).value_or(clip->timelineRange());
    if (EditResult r = checkLaneFree(sequence, *clip, lane_, span->start, span->end, frames, span->id); !r) {
        return r;
    }
    span->lane = lane_;
    clip->sortSpans();
    return EditResult::success();
}

RemoveSpans::RemoveSpans(SequenceId sequenceId, std::vector<SpanId> spanIds)
    : SequenceCommand(sequenceId), spanIds_(std::move(spanIds)) {}

std::string RemoveSpans::name() const {
    if (allTransitions_) {
        return spanIds_.size() == 1 ? "Remove Transition" : "Remove Transitions";
    }
    return spanIds_.size() == 1 ? "Remove Span" : "Remove Spans";
}

EditResult RemoveSpans::perform(const Project &, Sequence &sequence, IdGenerator &) {
    if (spanIds_.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "no spans to remove");
    }
    allTransitions_ = true;
    for (const SpanId id : spanIds_) {
        Clip *clip = nullptr;
        Track *track = nullptr;
        const EffectSpan *span = sequence.findSpan(id, &clip, &track);
        if (span == nullptr) {
            return spanNotFound(id);
        }
        if (EditResult r = requireEditableTrack(track, track->id); !r) {
            return r;
        }
        allTransitions_ = allTransitions_ && span->isTransition();
        std::erase_if(clip->spans, [id](const EffectSpan &s) { return s.id == id; });
        markRemovedOnPurpose(id);
    }
    return EditResult::success();
}

// ----- Ken Burns and matching a neighbour -----

EditResult planKenBurns(const Clip &clip, const EffectSpan &span, CMTime frameDuration, MotionFraming start,
                        MotionFraming end, std::vector<SpanValueChange> &changes) {
    changes.clear();
    if (span.kind != SpanKind::Motion) {
        return EditResult::failure(EditError::InvalidArgument, "the Ken Burns move needs a Motion span");
    }
    // The framings are read back the same way (spanEdgeMotion).
    const auto startTime = spanEdgeFrameTime(clip, span, frameDuration, false);
    const auto endTime = spanEdgeFrameTime(clip, span, frameDuration, true);
    if (!startTime || !endTime) {
        return notRepresentable(clip.id, clip.timelineStart);
    }
    const VideoParams before = composeMotion(clip, *startTime, span.id);
    const VideoParams after = composeMotion(clip, *endTime, span.id);
    if (!(before.scale > 0.0) || !(after.scale > 0.0)) {
        return EditResult::failure(EditError::InvalidArgument,
                                   "the clip's scale is 0 there without this span, so no framing can be shown");
    }
    const std::pair<SpanParameter, std::pair<double, double>> values[] = {
        {SpanParameter::X, {start.x - before.x, end.x - after.x}},
        {SpanParameter::Y, {start.y - before.y, end.y - after.y}},
        {SpanParameter::Scale, {start.scale / before.scale, end.scale / after.scale}},
    };
    for (const auto &[parameter, pair] : values) {
        if (EditResult r = checkSpanValue(parameter, pair.first); !r) {
            return r;
        }
        if (EditResult r = checkSpanValue(parameter, pair.second); !r) {
            return r;
        }
        changes.push_back(SpanValueChange{parameter, pair.first, pair.second});
    }
    return EditResult::success();
}

EditResult planMatchSpanEdge(const Sequence &sequence, SpanId spanId, ClipEdge edge,
                             std::vector<SpanValueChange> &changes) {
    changes.clear();
    const Clip *clip = nullptr;
    const Track *track = nullptr;
    const EffectSpan *span = sequence.findSpan(spanId, &clip, &track);
    if (span == nullptr) {
        return spanNotFound(spanId);
    }
    if (span->isTransition()) {
        return EditResult::failure(EditError::InvalidArgument, "a transition has no values to match");
    }
    const Clip *neighbour = touchingClip(*track, *clip, edge);
    if (neighbour == nullptr) {
        return EditResult::failure(EditError::NotAdjacent, std::string("no clip touches the ") +
                                                               (edge == ClipEdge::Head ? "start" : "end") + " of clip " +
                                                               idString(clip->id.value()));
    }
    const CMTime fd = sequence.frameDuration;
    // This clip's frame at that edge, and the neighbour's frame that meets it.
    const CMTime ownFrame = edge == ClipEdge::Head ? clip->timelineStart : clip->timelineEnd() - fd;
    const CMTime otherFrame = edge == ClipEdge::Head ? neighbour->timelineEnd() - fd : neighbour->timelineStart;
    const auto time = spanEvaluationTime(*clip, ownFrame);
    if (!time) {
        return notRepresentable(clip->id, ownFrame);
    }
    if (!spanActsAt(*span, *time)) {
        return EditResult::failure(EditError::InvalidArgument,
                                   spanName(spanId) + " starts after the " +
                                       (edge == ClipEdge::Head ? "first" : "last") + " frame of clip " +
                                       idString(clip->id.value()) + ", so its value cannot match the neighbour there");
    }
    const bool atEnd = edge == ClipEdge::Tail;
    auto propose = [&](SpanParameter parameter, double value) -> EditResult {
        if (EditResult r = checkSpanValue(parameter, value); !r) {
            return r;
        }
        if (!spanValuesMatch(parameter, spanEdgeValue(*span, parameter, atEnd), value)) {
            SpanValueChange change;
            change.parameter = parameter;
            (atEnd ? change.end : change.start) = value;
            changes.push_back(change);
        }
        return EditResult::success();
    };
    if (span->kind == SpanKind::Gain) {
        const double target = gainDbAt(*neighbour, otherFrame);
        return propose(SpanParameter::Gain, target - composeGainDb(*clip, *time, span->id));
    }
    const VideoParams target = motionValuesAt(*neighbour, otherFrame);
    const VideoParams others = composeMotion(*clip, *time, span->id);
    if (span->kind == SpanKind::Opacity) {
        if (!(others.opacity > 0.0)) {
            return EditResult::failure(EditError::InvalidArgument,
                                       "the clip's opacity is 0 there without this span, so no value can match");
        }
        return propose(SpanParameter::Opacity, target.opacity / others.opacity);
    }
    if (!(others.scale > 0.0)) {
        return EditResult::failure(EditError::InvalidArgument,
                                   "the clip's scale is 0 there without this span, so no value can match");
    }
    for (const auto &[parameter, value] :
         {std::pair{SpanParameter::X, target.x - others.x}, std::pair{SpanParameter::Y, target.y - others.y},
          std::pair{SpanParameter::Scale, target.scale / others.scale},
          std::pair{SpanParameter::Rotation, target.rotationDegrees - others.rotationDegrees}}) {
        if (EditResult r = propose(parameter, value); !r) {
            return r;
        }
    }
    return EditResult::success();
}

// ----- Audio fades -----

CMTime clipFadeLength(const Clip &clip, ClipEdge edge) {
    const EffectSpan *span = clip.transitionAt(edge);
    if (span == nullptr) {
        return kCMTimeZero;
    }
    if (edge == ClipEdge::Head) {
        return span->end;
    }
    return span->end == kCMTimeZero ? -span->start : kCMTimeZero;
}

EditResult setClipFade(Clip &clip, const Track &track, ClipEdge edge, CMTime length, IdGenerator &ids) {
    const char *which = edge == ClipEdge::Head ? "fade in" : "fade out";
    if (EditResult r = requireExact(length, which); !r) {
        return r;
    }
    if (length < kCMTimeZero || clip.timelineDuration < length) {
        return EditResult::failure(EditError::InvalidTime, std::string("a ") + which + " of " + describe(length) +
                                                               " does not fit clip " + idString(clip.id.value()) +
                                                               " (" + describe(clip.timelineDuration) + ")");
    }
    EffectSpan *span = clip.transitionAt(edge);
    if (edge == ClipEdge::Tail && span != nullptr && kCMTimeZero < span->end) {
        if (length == kCMTimeZero) {
            return EditResult::success(); // a cross dissolve is not a fade
        }
        return EditResult::failure(EditError::InvalidArgument, "clip " + idString(clip.id.value()) +
                                                                   " ends in a crossfade, which replaces a fade out "
                                                                   "there");
    }
    if (length == kCMTimeZero) {
        if (span != nullptr) {
            const SpanId id = span->id;
            std::erase_if(clip.spans, [id](const EffectSpan &s) { return s.id == id; });
        }
        return EditResult::success();
    }
    if (edge == ClipEdge::Head && span == nullptr && touchingClip(track, clip, ClipEdge::Head) != nullptr) {
        return EditResult::failure(EditError::InvalidArgument,
                                   "another clip touches the start of clip " + idString(clip.id.value()) +
                                       ", so the cut belongs to that clip: use a crossfade there instead of a fade in");
    }
    const CMTime other = edge == ClipEdge::Head ? [&] {
        const EffectSpan *tail = clip.transitionAt(ClipEdge::Tail);
        return tail != nullptr ? -tail->start : kCMTimeZero;
    }()
                                                : clipFadeLength(clip, ClipEdge::Head);
    const auto total = ExactTime::from(length) && ExactTime::from(other)
                           ? ExactTime::from(length)->plus(*ExactTime::from(other))
                           : std::nullopt;
    if (!total || total->compare(clip.timelineDuration) > 0) {
        return EditResult::failure(EditError::InvalidTime, "the fade in and fade out overlap: together they are "
                                                           "longer than the clip (" +
                                                               describe(clip.timelineDuration) + ")");
    }
    const auto start = checkedNegate(length);
    if (!start) {
        return notRepresentable(clip.id, clip.timelineStart);
    }
    if (span == nullptr) {
        EffectSpan fade;
        fade.id = ids.make<SpanId>();
        fade.lane = kTransitionLane;
        fade.kind = SpanKind::Transition;
        fade.edge = edge;
        clip.spans.push_back(fade);
        span = &clip.spans.back();
    }
    if (edge == ClipEdge::Head) {
        span->start = kCMTimeZero;
        span->end = length;
    } else {
        span->start = *start;
        span->end = kCMTimeZero;
    }
    clip.sortSpans();
    return EditResult::success();
}

// ----- Transitions -----

std::optional<TransitionPlacement> findTransition(const Sequence &sequence, SpanId spanId) {
    const Clip *owner = nullptr;
    const Track *track = nullptr;
    const EffectSpan *span = sequence.findSpan(spanId, &owner, &track);
    if (span == nullptr || !span->isTransition()) {
        return std::nullopt;
    }
    return placeTransition(*track, *owner, *span);
}

std::pair<CMTime, CMTime> centredTransitionOffsets(std::int64_t frames, CMTime frameDuration) {
    const CMTime before = timeForFrame(frames / 2, frameDuration);
    const CMTime after = timeForFrame(frames - frames / 2, frameDuration);
    return {-before, after};
}

namespace {

// Validates the transition spans of `clip` after an edit put `span` there.
EditResult checkPlacedTransition(const Project &project, const Sequence &sequence, const Track &track,
                                 const Clip &clip, const EffectSpan &span) {
    if (auto issue = checkTransitionSpan(project, track, clip, span, sequence.frameDuration)) {
        return transitionIssueToResult(*issue);
    }
    // The clip's transition at its other edge must still fit beside it (a tail span checks the fade
    // in at the clip's start; a fade in is checked from the tail span's side).
    if (const EffectSpan *other = clip.transitionAt(span.edge == ClipEdge::Head ? ClipEdge::Tail : ClipEdge::Head)) {
        if (auto issue = checkTransitionSpan(project, track, clip, *other, sequence.frameDuration)) {
            return transitionIssueToResult(*issue);
        }
    }
    // The clip before it may reach into this clip (a cross dissolve), which this span must not meet.
    if (const Clip *previous = touchingClip(track, clip, ClipEdge::Head)) {
        if (const EffectSpan *incoming = previous->transitionAt(ClipEdge::Tail)) {
            if (auto issue = checkTransitionSpan(project, track, *previous, *incoming, sequence.frameDuration)) {
                return transitionIssueToResult(*issue);
            }
        }
    }
    return EditResult::success();
}

} // namespace

AddTransitionSpans::AddTransitionSpans(SequenceId sequenceId, std::vector<TransitionSpanRequest> requests)
    : SequenceCommand(sequenceId), requests_(std::move(requests)) {}

EditResult AddTransitionSpans::perform(const Project &project, Sequence &sequence, IdGenerator &ids) {
    if (requests_.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "no transitions to add");
    }
    created_.clear();
    for (const TransitionSpanRequest &request : requests_) {
        Track *track = nullptr;
        Clip *clip = nullptr;
        if (EditResult r = findEditableClip(sequence, request.clipId, track, clip); !r) {
            return r;
        }
        for (const CMTime t : {request.start, request.end}) {
            if (EditResult r = requireExact(t, "transition offset"); !r) {
                return r;
            }
        }
        if (clip->transitionAt(request.edge) != nullptr) {
            return EditResult::failure(EditError::AlreadyExists,
                                       std::string("clip ") + idString(clip->id.value()) + " already has a transition at its " +
                                           (request.edge == ClipEdge::Head ? "start" : "end"));
        }
        EffectSpan span;
        span.id = ids.make<SpanId>();
        span.lane = kTransitionLane;
        span.kind = SpanKind::Transition;
        span.edge = request.edge;
        span.transition = request.kind;
        span.start = request.start;
        span.end = request.end;
        clip->spans.push_back(span);
        clip->sortSpans();
        if (EditResult r = checkPlacedTransition(project, sequence, *track, *clip, *clip->findSpan(span.id)); !r) {
            return r;
        }
        created_.push_back(span.id);
    }
    return EditResult::success();
}

SetTransitionRanges::SetTransitionRanges(SequenceId sequenceId, std::vector<TransitionRangeChange> changes,
                                         bool durationChange)
    : SequenceCommand(sequenceId), changes_(std::move(changes)), durationChange_(durationChange) {
    std::string key = "transitionRanges:";
    for (const TransitionRangeChange &change : changes_) {
        key += idString(change.spanId.value()) + ",";
    }
    setCoalescingKey(key);
}

std::string SetTransitionRanges::name() const {
    const bool several = changes_.size() != 1;
    if (durationChange_) {
        return several ? "Change Transition Durations" : "Change Transition Duration";
    }
    return several ? "Change Transitions" : "Change Transition";
}

EditResult SetTransitionRanges::perform(const Project &project, Sequence &sequence, IdGenerator &) {
    if (changes_.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "no transitions to change");
    }
    for (const TransitionRangeChange &change : changes_) {
        Clip *clip = nullptr;
        Track *track = nullptr;
        EffectSpan *span = sequence.findSpan(change.spanId, &clip, &track);
        if (span == nullptr || !span->isTransition()) {
            return EditResult::failure(EditError::TransitionNotFound,
                                       "transition " + idString(change.spanId.value()) + " does not exist");
        }
        if (EditResult r = requireEditableTrack(track, track->id); !r) {
            return r;
        }
        for (const CMTime t : {change.start, change.end}) {
            if (EditResult r = requireExact(t, "transition offset"); !r) {
                return r;
            }
        }
        span->start = change.start;
        span->end = change.end;
        if (EditResult r = checkPlacedTransition(project, sequence, *track, *clip, *span); !r) {
            return r;
        }
    }
    return EditResult::success();
}

std::optional<SpanId> linkedTransition(const Sequence &sequence, SpanId spanId) {
    const auto transition = findTransition(sequence, spanId);
    if (!transition || !transition->owner->linkedClipId) {
        return std::nullopt;
    }
    const Clip *partnerOwner = sequence.findClip(*transition->owner->linkedClipId);
    const Track *partnerTrack = partnerOwner != nullptr ? sequence.trackOfClip(partnerOwner->id) : nullptr;
    const EffectSpan *candidate = partnerOwner != nullptr ? partnerOwner->transitionAt(transition->span->edge) : nullptr;
    if (candidate == nullptr) {
        return std::nullopt;
    }
    const auto other = placeTransition(*partnerTrack, *partnerOwner, *candidate);
    if (!other || other->role != transition->role) {
        return std::nullopt;
    }
    if (transition->role == TransitionRole::CrossDissolve) {
        // The partners of the two clips meet at this cut.
        if (transition->partner == nullptr || other->partner == nullptr || !transition->partner->linkedClipId ||
            *transition->partner->linkedClipId != other->partner->id) {
            return std::nullopt;
        }
    }
    return candidate->id;
}

bool isThroughEdit(const Sequence &sequence, ClipId fromClipId, ClipId toClipId) {
    const Clip *from = sequence.findClip(fromClipId);
    const Clip *to = sequence.findClip(toClipId);
    if (!from || !to || from->assetId != to->assetId || from->trackId != to->trackId ||
        CMTimeCompare(from->timelineEnd(), to->timelineStart) != 0 || from->isStill != to->isStill ||
        !(from->speedRatio() == to->speedRatio()) || !(from->video == to->video) ||
        !(from->audio.gainDb == to->audio.gainDb) || from->hasEffectSpans() || to->hasEffectSpans()) {
        return false;
    }
    if (from->isStill) {
        return true;
    }
    const auto out = from->exactSourceOut();
    const auto in = ExactTime::from(to->sourceIn);
    return out && in && *out == *in;
}

// ----- Transition limits -----

namespace {

std::string quotedMediaName(const Project &project, const Clip &clip) {
    const MediaAsset *asset = project.findAsset(clip.assetId);
    const std::string name = asset && !asset->name.empty() ? asset->name : "clip " + idString(clip.id.value());
    return "“" + name + "”";
}

TransitionLimit noTransition(EditError error, std::string reason) {
    TransitionLimit limit;
    limit.limitError = error;
    limit.reason = std::move(reason);
    return limit;
}

// Whole frames of `length` (a timeline time), rounded down; unlimited for nullopt.
std::int64_t wholeFrames(const std::optional<ExactTime> &length, CMTime frameDuration) {
    if (!length) {
        return std::numeric_limits<std::int64_t>::max() / 4;
    }
    if (length->numerator() <= 0) {
        return 0;
    }
    return length->frameIndex(frameDuration, SnapMode::Floor).value_or(0);
}

} // namespace

std::optional<TransitionSideLimits> transitionSideLimits(const Project &project, SequenceId sequenceId, ClipId ownerId,
                                                         SpanId existing, EditResult &why) {
    const Sequence *sequence = project.findSequence(sequenceId);
    if (!sequence || !isPositive(sequence->frameDuration)) {
        why = EditResult::failure(EditError::SequenceNotFound, "The sequence no longer exists.");
        return std::nullopt;
    }
    const Track *track = sequence->trackOfClip(ownerId);
    const Clip *owner = track ? track->find(ownerId) : nullptr;
    if (!owner) {
        why = EditResult::failure(EditError::ClipNotFound, "The clips no longer exist.");
        return std::nullopt;
    }
    const Clip *next = touchingClip(*track, *owner, ClipEdge::Tail);
    if (!next) {
        why = EditResult::failure(EditError::NotAdjacent, "The clips do not meet at a cut on one track.");
        return std::nullopt;
    }
    if (track->locked) {
        why = EditResult::failure(EditError::TrackLocked, "Track “" + track->name + "” is locked.");
        return std::nullopt;
    }
    const EffectSpan *tail = owner->transitionAt(ClipEdge::Tail);
    if (tail && tail->id != existing) {
        why = EditResult::failure(EditError::AlreadyExists, "This cut already has a transition.");
        return std::nullopt;
    }
    if (existing && !tail) {
        why = EditResult::failure(EditError::TransitionNotFound, "The transition no longer exists.");
        return std::nullopt;
    }
    const CMTime fd = sequence->frameDuration;
    TransitionSideLimits limits;

    // Before the cut: the owner's frames not taken by its fade in or by a dissolve into it, and the
    // next clip's media before its in point.
    CMTime taken = kCMTimeZero;
    EditError roomError = EditError::InvalidArgument;
    std::string roomReason = "A transition cannot be longer than the clips it joins.";
    if (const EffectSpan *head = owner->transitionAt(ClipEdge::Head)) {
        taken = head->end;
        roomError = EditError::Overlap;
        roomReason = "It would overlap the fade at the clip's start.";
    } else if (const Clip *previous = touchingClip(*track, *owner, ClipEdge::Head)) {
        if (const EffectSpan *incoming = previous->transitionAt(ClipEdge::Tail); incoming && kCMTimeZero < incoming->end) {
            taken = incoming->end;
            roomError = EditError::Overlap;
            roomReason = "It would overlap the neighbouring transition.";
        }
    }
    const auto ownerLength = ExactTime::from(owner->timelineDuration);
    const auto takenExact = ExactTime::from(taken);
    const std::int64_t roomBefore =
        wholeFrames(ownerLength && takenExact ? ownerLength->minus(*takenExact) : std::nullopt, fd);
    std::int64_t mediaBefore = wholeFrames(std::nullopt, fd);
    if (!next->isStill) {
        const auto in = ExactTime::from(next->sourceIn);
        mediaBefore = wholeFrames(in ? in->dividedBy(next->speedRatio()) : std::nullopt, fd);
    }
    limits.maxBeforeFrames = std::min(roomBefore, mediaBefore);
    if (roomBefore <= mediaBefore) {
        limits.beforeError = roomError;
        limits.beforeReason = roomReason;
    } else {
        limits.beforeError = EditError::InsufficientHandles;
        limits.beforeReason = quotedMediaName(project, *next) + " has no more media before its in point.";
        limits.beforeLimitingClip = next->id;
    }

    // After the cut: the next clip's frames not taken by its own tail transition, and the owner's
    // media after its out point.
    CMTime nextTaken = kCMTimeZero;
    EditError nextError = EditError::InvalidArgument;
    std::string nextReason = "A transition cannot be longer than the clips it joins.";
    if (const EffectSpan *nextTail = next->transitionAt(ClipEdge::Tail)) {
        nextTaken = -nextTail->start;
        nextError = EditError::Overlap;
        nextReason = "It would overlap the neighbouring transition.";
    }
    const auto nextLength = ExactTime::from(next->timelineDuration);
    const auto nextTakenExact = ExactTime::from(nextTaken);
    const std::int64_t roomAfter =
        wholeFrames(nextLength && nextTakenExact ? nextLength->minus(*nextTakenExact) : std::nullopt, fd);
    std::int64_t mediaAfter = wholeFrames(std::nullopt, fd);
    if (!owner->isStill) {
        const MediaAsset *asset = project.findAsset(owner->assetId);
        const auto out = owner->exactSourceOut();
        const auto end = asset ? ExactTime::from(mediaEndFor(*asset, track->kind)) : std::nullopt;
        const auto rest = out && end ? end->minus(*out) : std::nullopt;
        mediaAfter = wholeFrames(rest ? rest->dividedBy(owner->speedRatio()) : std::optional<ExactTime>(ExactTime{}), fd);
    }
    limits.maxAfterFrames = std::min(roomAfter, mediaAfter);
    if (roomAfter <= mediaAfter) {
        limits.afterError = nextError;
        limits.afterReason = nextReason;
    } else {
        limits.afterError = EditError::InsufficientHandles;
        limits.afterReason = quotedMediaName(project, *owner) + " has no more media after its out point.";
        limits.afterLimitingClip = owner->id;
    }
    why = EditResult::success();
    return limits;
}

TransitionLimit transitionLimit(const Project &project, SequenceId sequenceId, ClipId fromClipId, ClipId toClipId,
                                SpanId existing) {
    const Sequence *sequence = project.findSequence(sequenceId);
    if (!sequence || !isPositive(sequence->frameDuration)) {
        return noTransition(EditError::SequenceNotFound, "The sequence no longer exists.");
    }
    const Track *track = sequence->trackOfClip(fromClipId);
    const Clip *from = track ? track->find(fromClipId) : nullptr;
    if (!from || !sequence->findClip(toClipId)) {
        return noTransition(EditError::ClipNotFound, "The clips no longer exist.");
    }
    const Clip *next = touchingClip(*track, *from, ClipEdge::Tail);
    if (!next || next->id != toClipId || fromClipId == toClipId) {
        return noTransition(EditError::NotAdjacent, "The clips do not meet at a cut on one track.");
    }
    EditResult why = EditResult::success();
    const auto sides = transitionSideLimits(project, sequenceId, fromClipId, existing, why);
    if (!sides) {
        return noTransition(why.error, why.message);
    }
    // A centred transition of n frames takes floor(n/2) before the cut and the rest after.
    const std::int64_t before = sides->maxBeforeFrames;
    const std::int64_t after = sides->maxAfterFrames;
    std::int64_t frames = 2 * std::min(before, after);
    if (after >= 1) {
        frames = std::max(frames, 2 * std::min(before, after - 1) + 1);
    }
    TransitionLimit limit;
    limit.maximumFrames = frames;
    limit.maximum = frames > 0 ? timeForFrame(frames, sequence->frameDuration) : kCMTimeZero;
    // Why one frame more is refused: the side it would overrun.
    const std::int64_t longer = frames + 1;
    if (longer / 2 > before) {
        limit.limitError = sides->beforeError;
        limit.reason = sides->beforeReason;
        limit.limitingClip = sides->beforeLimitingClip;
    } else {
        limit.limitError = sides->afterError;
        limit.reason = sides->afterReason;
        limit.limitingClip = sides->afterLimitingClip;
    }
    return limit;
}

// ----- Links -----

LinkClips::LinkClips(SequenceId sequenceId, ClipId first, ClipId second)
    : SequenceCommand(sequenceId), first_(first), second_(second) {}

EditResult LinkClips::perform(const Project &, Sequence &sequence, IdGenerator &) {
    if (first_ == second_) {
        return EditResult::failure(EditError::InvalidArgument, "cannot link a clip to itself");
    }
    Track *firstTrack = nullptr;
    Track *secondTrack = nullptr;
    Clip *first = nullptr;
    Clip *second = nullptr;
    if (EditResult r = findEditableClip(sequence, first_, firstTrack, first); !r) {
        return r;
    }
    if (EditResult r = findEditableClip(sequence, second_, secondTrack, second); !r) {
        return r;
    }
    if (firstTrack == secondTrack) {
        return EditResult::failure(EditError::InvalidArgument, "linked clips must be on different tracks");
    }
    if (first->linkedClipId || second->linkedClipId) {
        return EditResult::failure(EditError::AlreadyLinked, "a clip is already linked; unlink it first");
    }
    first->linkedClipId = second_;
    second->linkedClipId = first_;
    return EditResult::success();
}

UnlinkClip::UnlinkClip(SequenceId sequenceId, ClipId clipId) : SequenceCommand(sequenceId), clipId_(clipId) {}

EditResult UnlinkClip::perform(const Project &, Sequence &sequence, IdGenerator &) {
    Track *track = nullptr;
    Clip *clip = nullptr;
    if (EditResult r = findEditableClip(sequence, clipId_, track, clip); !r) {
        return r;
    }
    if (!clip->linkedClipId) {
        return EditResult::failure(EditError::NotLinked, "clip " + idString(clipId_.value()) + " is not linked");
    }
    Track *partnerTrack = nullptr;
    Clip *partner = nullptr;
    if (EditResult r = findEditableClip(sequence, *clip->linkedClipId, partnerTrack, partner); !r) {
        return r;
    }
    clip->linkedClipId.reset();
    partner->linkedClipId.reset();
    return EditResult::success();
}

// ----- Tracks -----

AddTrack::AddTrack(SequenceId sequenceId, TrackKind kind, std::string trackName, std::optional<std::size_t> index)
    : SequenceCommand(sequenceId), kind_(kind), trackName_(std::move(trackName)), index_(index) {}

EditResult AddTrack::perform(const Project &, Sequence &sequence, IdGenerator &ids) {
    std::vector<Track> &list = sequence.tracks(kind_);
    const std::size_t index = index_.value_or(list.size());
    if (index > list.size()) {
        return EditResult::failure(EditError::InvalidArgument, "track index " + std::to_string(index) +
                                                                   " is past the end (" + std::to_string(list.size()) +
                                                                   " tracks)");
    }
    Track track;
    track.id = ids.make<TrackId>();
    track.kind = kind_;
    track.name = !trackName_.empty()
                     ? trackName_
                     : std::string(kind_ == TrackKind::Video ? "V" : "A") + std::to_string(list.size() + 1);
    created_ = track.id;
    list.insert(list.begin() + static_cast<std::ptrdiff_t>(index), std::move(track));
    return EditResult::success();
}

RemoveTrack::RemoveTrack(SequenceId sequenceId, TrackId trackId) : SequenceCommand(sequenceId), trackId_(trackId) {}

EditResult RemoveTrack::perform(const Project &, Sequence &sequence, IdGenerator &) {
    const Track *track = sequence.findTrack(trackId_);
    if (EditResult r = requireEditableTrack(track, trackId_); !r) {
        return r;
    }
    for (const Clip &clip : track->clips) {
        for (const EffectSpan &span : clip.spans) {
            markRemovedOnPurpose(span.id);
        }
    }
    std::vector<Track> &list = sequence.tracks(track->kind);
    std::erase_if(list, [this](const Track &t) { return t.id == trackId_; });
    return EditResult::success();
}

SetTrackFlags::SetTrackFlags(SequenceId sequenceId, TrackId trackId, TrackFlagsUpdate update)
    : SequenceCommand(sequenceId), trackId_(trackId), update_(std::move(update)) {
    setCoalescingKey("trackFlags:" + idString(trackId.value()));
}

EditResult SetTrackFlags::perform(const Project &, Sequence &sequence, IdGenerator &) {
    Track *track = sequence.findTrack(trackId_);
    if (!track) {
        return EditResult::failure(EditError::TrackNotFound, "track " + idString(trackId_.value()) + " does not exist");
    }
    if (update_.muted) {
        track->muted = *update_.muted;
    }
    if (update_.solo) {
        track->solo = *update_.solo;
    }
    if (update_.locked) {
        track->locked = *update_.locked;
    }
    if (update_.name) {
        track->name = *update_.name;
    }
    return EditResult::success();
}

} // namespace ve
