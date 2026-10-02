#include "EditOps.h"

#include "../Model/Validation.h"
#include "EditPrimitives.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <initializer_list>
#include <limits>
#include <map>
#include <tuple>
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
        if (const TransitionSpan *span = clip.transitionAt(edge)) {
            if (auto placement = placeTransition(track, clip, *span)) {
                result.push_back(*placement);
            }
        }
    }
    if (const Clip *previous = touchingClip(track, clip, ClipEdge::Head)) {
        if (const TransitionSpan *span = previous->transitionAt(ClipEdge::Tail)) {
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
        std::erase_if(sequence.findClip(owner)->transitions,
                      [spanId](const TransitionSpan &span) { return span.id == spanId; });
    }
    created_.clear();
    divided_.clear();
    SplitList splits;
    for (const ClipId clipId : splitting) {
        Track &track = *sequence.trackOfClip(clipId);
        ClipId right;
        if (EditResult r = splitClipAt(sequence, track, *track.indexOf(clipId), at, ids, right, &divided_); !r) {
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

// A span of a kind from a newer version (SpanKind::Unknown) is kept as the file wrote it, never edited.
EditResult unknownKindRefusal(const EffectSpan &span) {
    return EditResult::failure(EditError::InvalidArgument,
                               spanName(span.id) + " is a \"" + span.foreign.kindName +
                                   "\" span from a newer version of Framewright; this version keeps it as it is "
                                   "and cannot change it");
}

// The effect span `spanId` (lanes 1-3), its clip and track, on an editable track.
EditResult findEffectSpan(Sequence &sequence, SpanId spanId, Track *&track, Clip *&clip, EffectSpan *&span) {
    if (sequence.findTransition(spanId) != nullptr) {
        return EditResult::failure(EditError::InvalidArgument,
                                   spanName(spanId) + " is a transition; change it with the transition edits");
    }
    span = sequence.findSpan(spanId, &clip, &track);
    if (span == nullptr) {
        return spanNotFound(spanId);
    }
    if (span->isUnknownKind()) {
        return unknownKindRefusal(*span);
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
    if (kind == SpanKind::Unknown) {
        return EditResult::failure(EditError::InvalidArgument, "a span of an unknown kind cannot be added");
    }
    if (!spanKindFitsTrack(kind, trackKind)) {
        return EditResult::failure(EditError::TrackKindMismatch, std::string("a ") + nameOf(kind) +
                                                                     " span cannot go on a clip of " +
                                                                     nameOf(trackKind) + " track");
    }
    return EditResult::success();
}

// "0", "1", "0.5": a range bound as the refusals print it.
std::string boundName(double bound) {
    char text[32];
    std::snprintf(text, sizeof text, "%g", bound);
    return text;
}

// What the refusal of an invalid value says about the parameter's range (SpanParameterInfo).
std::string rangeName(SpanParameter parameter) {
    const SpanParameterInfo &info = infoOf(parameter);
    const bool below = std::isfinite(info.minimum);
    const bool above = std::isfinite(info.maximum);
    if (below && above) {
        return "it is within " + boundName(info.minimum) + "..." + boundName(info.maximum);
    }
    if (below) {
        return "it is at least " + boundName(info.minimum);
    }
    if (above) {
        return "it is at most " + boundName(info.maximum);
    }
    return "it must be finite";
}

EditResult checkSpanValue(SpanParameter parameter, double value) {
    if (!isValidSpanValue(parameter, value)) {
        return EditResult::failure(EditError::InvalidArgument, std::string(displayNameOf(parameter)) + " cannot be " +
                                                                   std::to_string(value) + " (" +
                                                                   rangeName(parameter) + ")");
    }
    return EditResult::success();
}

// "scale", "opacity": a parameter named inside a sentence.
std::string lowercaseName(SpanParameter parameter) {
    std::string name = displayNameOf(parameter);
    for (char &c : name) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return name;
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
        if (other.lane != lane || other.id == except) {
            continue;
        }
        if (other.start < end && start < other.end) {
            EditResult refusal = EditResult::failure(
                EditError::Overlap, "lane " + std::to_string(lane) + " of clip " + idString(clip.id.value()) +
                                        " already has " + spanName(other.id) +
                                        (other.isUnknownKind() ? " (a span from a newer version of Framewright)" : "") +
                                        " there");
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

std::optional<TimeRange> spanTimelineRange(const Clip &clip, const TransitionSpan &span, const Track &track) {
    const auto placement = placeTransition(track, clip, span);
    return placement ? std::optional<TimeRange>(placement->range) : std::nullopt;
}

std::optional<TimeRange> spanTimelineRange(const Clip &clip, const EffectSpan &span, const Track &) {
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
        if (span.lane != lane || span.id == except) {
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
        // A trim: the keyframes stretch over the new length, keeping their places in the span. Tracks
        // this version does not know cannot be stretched with them: they go (ForeignSpanContent).
        moved.foreign.dropForeignTracks();
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
        const TransitionSpan *transition = sequence.findTransition(id, &clip, &track);
        const EffectSpan *span = transition == nullptr ? sequence.findSpan(id, &clip, &track) : nullptr;
        if (transition == nullptr && span == nullptr) {
            return spanNotFound(id);
        }
        if (EditResult r = requireEditableTrack(track, track->id); !r) {
            return r;
        }
        if (span != nullptr && span->isUnknownKind()) {
            return unknownKindRefusal(*span);
        }
        allTransitions_ = allTransitions_ && transition != nullptr;
        if (transition != nullptr) {
            std::erase_if(clip->transitions, [id](const TransitionSpan &s) { return s.id == id; });
        } else {
            std::erase_if(clip->spans, [id](const EffectSpan &s) { return s.id == id; });
        }
        markRemovedOnPurpose(id);
    }
    return EditResult::success();
}

// ----- Ken Burns and matching a neighbour -----

EditResult kenBurnsNeedsMotionSpan() {
    return EditResult::failure(EditError::InvalidArgument, "the Ken Burns move needs a Motion span");
}

EditResult planKenBurns(const Clip &clip, const EffectSpan &span, CMTime frameDuration, MotionFraming start,
                        MotionFraming end, std::vector<SpanValueChange> &changes) {
    changes.clear();
    if (span.kind != SpanKind::Motion) {
        return kenBurnsNeedsMotionSpan();
    }
    // The framings are read back the same way (spanEdgeMotion).
    const auto startTime = spanEdgeFrameTime(clip, span, frameDuration, false);
    const auto endTime = spanEdgeFrameTime(clip, span, frameDuration, true);
    if (!startTime || !endTime) {
        return notRepresentable(clip.id, clip.timelineStart);
    }
    const VideoParams before = composeMotion(clip, *startTime, span.id);
    const VideoParams after = composeMotion(clip, *endTime, span.id);
    // A framing sets position and scale; each is what the span must add or multiply onto the rest.
    const std::tuple<SpanParameter, double, double, double, double> framed[] = {
        {SpanParameter::X, before.x, after.x, start.x, end.x},
        {SpanParameter::Y, before.y, after.y, start.y, end.y},
        {SpanParameter::Scale, before.scale, after.scale, start.scale, end.scale},
    };
    for (const auto &[parameter, below, belowEnd, wanted, wantedEnd] : framed) {
        if (!canDecomposeSpanValue(parameter, below) || !canDecomposeSpanValue(parameter, belowEnd)) {
            return EditResult::failure(EditError::InvalidArgument, "the clip's " + lowercaseName(parameter) +
                                                                       " is 0 there without this span, so no "
                                                                       "framing can be shown");
        }
    }
    for (const auto &[parameter, below, belowEnd, wanted, wantedEnd] : framed) {
        const double first = decomposeSpanValue(parameter, below, wanted);
        const double last = decomposeSpanValue(parameter, belowEnd, wantedEnd);
        if (EditResult r = checkSpanValue(parameter, first); !r) {
            return r;
        }
        if (EditResult r = checkSpanValue(parameter, last); !r) {
            return r;
        }
        changes.push_back(SpanValueChange{parameter, first, last});
    }
    return EditResult::success();
}

EditResult planMatchSpanEdge(const Sequence &sequence, SpanId spanId, ClipEdge edge,
                             std::vector<SpanValueChange> &changes) {
    changes.clear();
    const Clip *clip = nullptr;
    const Track *track = nullptr;
    if (sequence.findTransition(spanId) != nullptr) {
        return EditResult::failure(EditError::InvalidArgument, "a transition has no values to match");
    }
    const EffectSpan *span = sequence.findSpan(spanId, &clip, &track);
    if (span == nullptr) {
        return spanNotFound(spanId);
    }
    if (span->isUnknownKind()) {
        return unknownKindRefusal(*span);
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
    // What the neighbour shows there, and what the rest of this clip composes to without the span.
    const VideoParams targetVideo = motionValuesAt(*neighbour, otherFrame);
    const AudioParams targetAudio{gainDbAt(*neighbour, otherFrame)};
    const VideoParams othersVideo = composeMotion(*clip, *time, span->id);
    const AudioParams othersAudio{composeGainDb(*clip, *time, span->id)};
    const std::span<const SpanParameter> parameters = infoOf(span->kind).parameters;
    for (const SpanParameter parameter : parameters) {
        if (!canDecomposeSpanValue(parameter, clipValueOf(othersVideo, othersAudio, parameter))) {
            return EditResult::failure(EditError::InvalidArgument, "the clip's " + lowercaseName(parameter) +
                                                                       " is 0 there without this span, so no value "
                                                                       "can match");
        }
    }
    for (const SpanParameter parameter : parameters) {
        const double value = decomposeSpanValue(parameter, clipValueOf(othersVideo, othersAudio, parameter),
                                                clipValueOf(targetVideo, targetAudio, parameter));
        if (EditResult r = propose(parameter, value); !r) {
            return r;
        }
    }
    return EditResult::success();
}

// ----- Continuing a move on the next clip -----

namespace {

// “name” of the clip's media, for a sentence.
std::string quotedClipName(const Project &project, const Clip &clip) {
    const MediaAsset *asset = project.findAsset(clip.assetId);
    return "“" + (asset != nullptr ? asset->name : "clip " + idString(clip.id.value())) + "”";
}

} // namespace

EditResult planContinueMotion(const Project &project, const Sequence &sequence, SpanId spanId, ContinueMotionPlan &plan) {
    plan = ContinueMotionPlan{};
    const Clip *clip = nullptr;
    const Track *track = nullptr;
    const EffectSpan *span = sequence.findSpan(spanId, &clip, &track);
    if (span == nullptr && sequence.findTransition(spanId) == nullptr) {
        return spanNotFound(spanId);
    }
    if (span == nullptr || span->kind != SpanKind::Motion) { // a transition, or another kind
        return EditResult::failure(EditError::InvalidArgument,
                                   "Continue on Next Clip carries a Motion span's move on to the next clip.");
    }
    const std::string name = quotedClipName(project, *clip);
    for (const EffectSpan &other : clip->spans) {
        if (other.kind == SpanKind::Motion && other.id != span->id && span->end < other.end) {
            return EditResult::failure(EditError::InvalidArgument,
                                       "Another move on " + name +
                                           " ends after this one: continue the clip's last move instead.");
        }
    }
    const Clip *next = touchingClip(*track, *clip, ClipEdge::Tail);
    if (next == nullptr) {
        return EditResult::failure(EditError::NotAdjacent,
                                   "No clip touches the end of " + name + ", so there is nothing to continue the move on.");
    }
    if (EditResult r = requireEditableTrack(track, track->id); !r) {
        return r;
    }
    const std::string nextName = quotedClipName(project, *next);
    const CMTime fd = sequence.frameDuration;
    const auto own = spanTimelineRange(*clip, *span, *track);
    if (!own || !isPositive(fd)) {
        return notRepresentable(clip->id, clip->timelineStart);
    }
    const double ownSeconds = CMTimeGetSeconds(own->duration());
    if (!(ownSeconds > 0.0)) {
        return EditResult::failure(EditError::InvalidArgument, "the move has no length to take a rate from");
    }
    // The lane: the span's own when it is free on N's first frame, else the first free one.
    std::vector<int> lanes{span->lane};
    for (int lane = kFirstEffectLane; lane <= kLastLane; ++lane) {
        if (lane != span->lane) {
            lanes.push_back(lane);
        }
    }
    std::optional<TimeRange> room;
    for (const int lane : lanes) {
        for (const TimeRange &free : freeLaneRanges(*next, lane, fd)) {
            if (free.start == next->timelineStart) {
                room = free;
                plan.lane = lane;
                break;
            }
        }
        if (room) {
            break;
        }
    }
    if (!room) {
        return EditResult::failure(EditError::Overlap, "Every effect lane of " + nextName +
                                                           " has a span on its first frame, so the move has no room "
                                                           "there: remove one or move it to a free lane.");
    }
    const std::int64_t ownFrames = std::max<std::int64_t>(1, frameIndexAt(own->duration(), fd, SnapMode::Round));
    const auto wanted = checkedTimeForFrame(frameIndexAt(next->timelineStart, fd, SnapMode::Round) + ownFrames, fd);
    if (!wanted) {
        return notRepresentable(next->id, next->timelineStart);
    }
    plan.clipId = next->id;
    plan.timelineStart = next->timelineStart;
    plan.timelineEnd = minTime(*wanted, room->end);
    TimeRange frames;
    if (EditResult r = spanSourceRange(sequence, *next, plan.timelineStart, plan.timelineEnd, plan.sourceStart,
                                       plan.sourceEnd, frames);
        !r) {
        return r;
    }
    // The new span's first and last frames on N, and what the rest of N composes to there.
    EffectSpan probe;
    probe.kind = SpanKind::Motion;
    probe.lane = plan.lane;
    probe.start = plan.sourceStart;
    probe.end = plan.sourceEnd;
    const auto firstTime = spanEdgeFrameTime(*next, probe, fd, false);
    const auto lastTime = spanEdgeFrameTime(*next, probe, fd, true);
    if (!firstTime || !lastTime) {
        return notRepresentable(next->id, next->timelineStart);
    }
    const VideoParams before = composeMotion(*next, *firstTime);
    const VideoParams after = composeMotion(*next, *lastTime);
    const AudioParams sound = next->audio; // Motion parameters compose onto the picture only
    const std::span<const SpanParameter> parameters = infoOf(SpanKind::Motion).parameters;
    for (const SpanParameter parameter : parameters) {
        if (!canDecomposeSpanValue(parameter, clipValueOf(before, sound, parameter)) ||
            !canDecomposeSpanValue(parameter, clipValueOf(after, sound, parameter))) {
            return EditResult::failure(EditError::InvalidArgument, nextName + " has " + lowercaseName(parameter) +
                                                                       " 0 where the move would go, so no span value "
                                                                       "can show it.");
        }
    }
    // The rate of the move: its own start and end values over its length.
    for (const SpanParameter parameter : parameters) {
        if (!canDecomposeSpanValue(parameter, spanEdgeValue(*span, parameter, false))) {
            return EditResult::failure(EditError::InvalidArgument, "The move starts at " + lowercaseName(parameter) +
                                                                       " 0, so it has no zoom rate to continue.");
        }
    }
    const double k = CMTimeGetSeconds(plan.timelineEnd - plan.timelineStart) / ownSeconds;
    const VideoParams from = motionValuesAt(*clip, clip->timelineEnd());
    for (const SpanParameter parameter : parameters) {
        const double here = clipValueOf(from, sound, parameter);
        const double there = extrapolateSpanValue(parameter, here, spanEdgeValue(*span, parameter, false),
                                                  spanEdgeValue(*span, parameter, true), k);
        const double first = decomposeSpanValue(parameter, clipValueOf(before, sound, parameter), here);
        const double last = decomposeSpanValue(parameter, clipValueOf(after, sound, parameter), there);
        for (const double value : {first, last}) {
            if (EditResult r = checkSpanValue(parameter, value); !r) {
                return r;
            }
        }
        plan.values.push_back(SpanValueChange{parameter, first, last});
    }
    const KeyframeInterpolation easing = spanInterpolation(*span);
    plan.interpolation = easing == KeyframeInterpolation::Bezier ? KeyframeInterpolation::Linear : easing;
    return EditResult::success();
}

ContinueMotionSpan::ContinueMotionSpan(SequenceId sequenceId, SpanId spanId)
    : SequenceCommand(sequenceId), spanId_(spanId) {}

EditResult ContinueMotionSpan::perform(const Project &project, Sequence &sequence, IdGenerator &ids) {
    ContinueMotionPlan plan;
    if (EditResult r = planContinueMotion(project, sequence, spanId_, plan); !r) {
        return r;
    }
    Track *track = nullptr;
    Clip *next = nullptr;
    if (EditResult r = findEditableClip(sequence, plan.clipId, track, next); !r) {
        return r;
    }
    const TimeRange frames{plan.timelineStart, plan.timelineEnd};
    if (EditResult r = checkLaneFree(sequence, *next, plan.lane, plan.sourceStart, plan.sourceEnd, frames, SpanId{});
        !r) {
        return r;
    }
    const auto length = checkedSubtract(plan.sourceEnd, plan.sourceStart);
    if (!length || !isExactModelTime(*length)) {
        return notRepresentable(next->id, plan.timelineStart);
    }
    EffectSpan span;
    span.id = ids.make<SpanId>();
    span.lane = plan.lane;
    span.kind = SpanKind::Motion;
    span.start = plan.sourceStart;
    span.end = plan.sourceEnd;
    for (const SpanValueChange &change : plan.values) {
        span.tracks.track(change.parameter) = {
            keyframeAt(kCMTimeZero, change.start.value_or(neutralValue(change.parameter)), plan.interpolation),
            keyframeAt(*length, change.end.value_or(neutralValue(change.parameter)), plan.interpolation)};
    }
    if (auto problem = spanTracksProblem(span)) {
        return EditResult::failure(EditError::InvalidArgument, *problem);
    }
    created_ = span.id;
    next->spans.push_back(std::move(span));
    next->sortSpans();
    return EditResult::success();
}

// ----- Audio fades -----

CMTime clipFadeLength(const Clip &clip, ClipEdge edge) {
    const TransitionSpan *span = clip.transitionAt(edge);
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
    TransitionSpan *span = clip.transitionAt(edge);
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
            std::erase_if(clip.transitions, [id](const TransitionSpan &s) { return s.id == id; });
        }
        return EditResult::success();
    }
    if (edge == ClipEdge::Head && span == nullptr && touchingClip(track, clip, ClipEdge::Head) != nullptr) {
        return EditResult::failure(EditError::InvalidArgument,
                                   "another clip touches the start of clip " + idString(clip.id.value()) +
                                       ", so the cut belongs to that clip: use a crossfade there instead of a fade in");
    }
    if (edge == ClipEdge::Tail) {
        // A cross dissolve coming into the clip keeps its part inside it: the fade out has the rest.
        const CMTime incoming = TransitionRules::incomingPartInside(track, clip);
        const auto room = checkedSubtract(clip.timelineDuration, incoming);
        if (kCMTimeZero < incoming && (!room || *room < length)) {
            // Overlap, as the facade's fade limit reports the same condition (review L9).
            return EditResult::failure(
                EditError::Overlap,
                "a fade out of " + describe(length) + " would meet the " +
                    (track.kind == TrackKind::Audio ? "crossfade" : "cross dissolve") + " coming into clip " +
                    idString(clip.id.value()) + ": it has room for " + describe(room ? maxTime(*room, kCMTimeZero)
                                                                                     : kCMTimeZero));
        }
    }
    // What the transition at the other edge takes of the clip.
    const CMTime other = TransitionRules::partInside(clip, edge == ClipEdge::Head ? ClipEdge::Tail : ClipEdge::Head);
    const auto total = ExactTime::from(length) && ExactTime::from(other)
                           ? ExactTime::from(length)->plus(*ExactTime::from(other))
                           : std::nullopt;
    if (!total || total->compare(clip.timelineDuration) > 0) {
        return EditResult::failure(EditError::Overlap, "the fade in and fade out overlap: together they are "
                                                       "longer than the clip (" +
                                                           describe(clip.timelineDuration) + ")");
    }
    const auto start = checkedNegate(length);
    if (!start) {
        return notRepresentable(clip.id, clip.timelineStart);
    }
    if (span == nullptr) {
        TransitionSpan fade;
        fade.id = ids.make<SpanId>();
        fade.edge = edge;
        clip.transitions.push_back(fade);
        span = &clip.transitions.back();
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
    const TransitionSpan *span = sequence.findTransition(spanId, &owner, &track);
    if (span == nullptr) {
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
                                 const Clip &clip, const TransitionSpan &span) {
    if (auto issue = checkTransitionSpan(project, track, clip, span, sequence.frameDuration)) {
        return transitionIssueToResult(*issue);
    }
    // The clip's transition at its other edge must still fit beside it (a tail span checks the fade
    // in at the clip's start; a fade in is checked from the tail span's side).
    if (const TransitionSpan *other = clip.transitionAt(span.edge == ClipEdge::Head ? ClipEdge::Tail : ClipEdge::Head)) {
        if (auto issue = checkTransitionSpan(project, track, clip, *other, sequence.frameDuration)) {
            return transitionIssueToResult(*issue);
        }
    }
    // The clip before it may reach into this clip (a cross dissolve), which this span must not meet.
    if (const Clip *previous = touchingClip(track, clip, ClipEdge::Head)) {
        if (const TransitionSpan *incoming = previous->transitionAt(ClipEdge::Tail)) {
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
        TransitionSpan span;
        span.id = ids.make<SpanId>();
        span.edge = request.edge;
        span.kind = request.kind;
        span.start = request.start;
        span.end = request.end;
        clip->transitions.push_back(span);
        clip->sortSpans();
        if (EditResult r = checkPlacedTransition(project, sequence, *track, *clip, *clip->findTransition(span.id)); !r) {
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
        TransitionSpan *span = sequence.findTransition(change.spanId, &clip, &track);
        if (span == nullptr) {
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

namespace {

// `t` as a CMTime on `timescale` when it is a whole number of its ticks (so a time keeps the timescale
// it had when an edit moves it by a whole number of those ticks), else its exact form on the smallest
// timescale; nullopt when neither exists.
std::optional<CMTime> exactTimeOn(const ExactTime &t, std::int32_t timescale) {
    if (timescale > 0) {
        Int128 scaled = 0;
        if (!__builtin_mul_overflow(t.numerator(), static_cast<Int128>(timescale), &scaled) &&
            scaled % t.denominator() == 0) {
            const Int128 value = scaled / t.denominator();
            if (value >= std::numeric_limits<std::int64_t>::min() && value <= std::numeric_limits<std::int64_t>::max()) {
                return CMTimeMake(static_cast<std::int64_t>(value), timescale);
            }
        }
    }
    return t.toTime();
}

// `t` as a CMTime on the first of `timescales` it is a whole number of ticks of, else its exact form
// on the smallest timescale; nullopt when it has none (its reduced denominator exceeds 2^31 - 1, so
// no CMTime holds it exactly on any timescale).
std::optional<CMTime> exactTimeOnFirstOf(const ExactTime &t, std::initializer_list<std::int32_t> timescales) {
    for (const std::int32_t timescale : timescales) {
        if (timescale <= 0) {
            continue;
        }
        Int128 scaled = 0;
        if (!__builtin_mul_overflow(t.numerator(), static_cast<Int128>(timescale), &scaled) &&
            scaled % t.denominator() == 0) {
            const Int128 value = scaled / t.denominator();
            if (value >= std::numeric_limits<std::int64_t>::min() && value <= std::numeric_limits<std::int64_t>::max()) {
                return CMTimeMake(static_cast<std::int64_t>(value), timescale);
            }
        }
    }
    return t.toTime();
}

// `t` in seconds with as many decimals as it needs, up to nine ("10.123456789", "2.5", "3").
std::string secondsText(CMTime t) {
    char text[64];
    std::snprintf(text, sizeof text, "%.9f", CMTimeGetSeconds(t));
    std::string result = text;
    while (!result.empty() && result.back() == '0') {
        result.pop_back();
    }
    if (!result.empty() && result.back() == '.') {
        result.pop_back();
    }
    return result;
}

// Why `clip` (of `asset`, whose media on its track ends at `mediaEnd`) cannot be reversed when the
// in point on the other side of the mirror, E - source out, has no CMTime form: a media end stated to
// the nanosecond (a Matroska DURATION tag of a file imported before those were put on a grid) and a
// clip ending on a frame whose time does not divide into nanoseconds (a third of a second...). The
// sentence names the smallest trim of the clip's end (up to kMaxReverseTrimHint sequence frames)
// after which the in point exists, when one does.
constexpr std::int64_t kMaxReverseTrimHint = 30;
std::string irreversibleMessage(const Clip &clip, const MediaAsset &asset, CMTime mediaEnd, CMTime frameDuration) {
    std::string message = "\xE2\x80\x9C" + asset.name + "\xE2\x80\x9D cannot be reversed: its media's length as the file "
                          "states it (" + secondsText(mediaEnd) + " s) does not line up exactly with this clip's frames, "
                          "so they cannot be mirrored frame for frame.";
    const auto end = ExactTime::from(mediaEnd);
    const auto in = ExactTime::from(clip.sourceIn);
    const auto length = ExactTime::from(clip.timelineDuration);
    const auto frame = ExactTime::from(frameDuration);
    if (end && in && length && frame) {
        for (std::int64_t k = 1; k <= kMaxReverseTrimHint; ++k) {
            const auto cut = frame->times(Ratio{k, 1});
            const auto kept = cut ? length->minus(*cut) : std::nullopt;
            if (!kept || kept->compare(*frame) < 0) {
                break; // at least a frame must stay
            }
            const auto clipTime = kept->times(clip.speedRatio());
            const auto out = clipTime ? in->plus(*clipTime) : std::nullopt;
            const auto flipped = out ? end->minus(*out) : std::nullopt;
            if (flipped && flipped->toTime()) {
                return message + " Trimming " + std::to_string(k) + (k == 1 ? " frame" : " frames") +
                       " off its end makes it reversible.";
            }
        }
    }
    return message + " Trimming a few frames off its end may make it reversible.";
}

} // namespace

SetClipReversed::SetClipReversed(SequenceId sequenceId, ClipId clipId, bool reversed, bool includeLinked)
    : SequenceCommand(sequenceId), clipId_(clipId), reversed_(reversed), includeLinked_(includeLinked) {}

EditResult SetClipReversed::perform(const Project &project, Sequence &sequence, IdGenerator &) {
    std::vector<ClipId> targets;
    if (EditResult r = clipAndPartner(sequence, clipId_, includeLinked_, targets); !r) {
        return r;
    }
    for (const ClipId clipId : targets) {
        const Track &track = *sequence.trackOfClip(clipId);
        Clip &clip = *sequence.findClip(clipId);
        if (clip.isStill) {
            if (clipId != clipId_) {
                continue; // a still linked to the clip asked for has no direction: the clip goes alone
            }
            return EditResult::failure(EditError::InvalidArgument, "a still image has no motion to reverse");
        }
        if (clip.reversed == reversed_) {
            continue;
        }
        const MediaAsset *asset = project.findAsset(clip.assetId);
        if (!asset) {
            return EditResult::failure(EditError::AssetNotFound, "the clip's asset is missing");
        }
        const CMTime mediaEnd = mediaEndFor(*asset, track.kind);
        if (!isPositive(mediaEnd)) {
            return EditResult::failure(EditError::OutOfSourceRange,
                                       "the length of the clip's media is unknown, so it cannot be reversed");
        }
        // The clip time the other side of the mirror gives the same media range: E - out.
        const auto end = ExactTime::from(mediaEnd);
        const auto out = clip.exactSourceOut();
        const auto in = ExactTime::from(clip.sourceIn);
        const auto flipped = end && out ? end->minus(*out) : std::nullopt;
        const auto shift = flipped && in ? flipped->minus(*in) : std::nullopt;
        // Kept on the in point's timescale when it is whole ticks of it, else on the sequence's frame
        // grid or the media end's own timescale, else on the smallest exact one.
        const auto newIn = flipped ? exactTimeOnFirstOf(*flipped, {clip.sourceIn.timescale,
                                                                   sequence.frameDuration.timescale,
                                                                   mediaEnd.timescale})
                                   : std::nullopt;
        if (flipped && in && !newIn) {
            return EditResult::failure(EditError::NotRepresentable,
                                       irreversibleMessage(clip, *asset, mediaEnd, sequence.frameDuration));
        }
        if (!shift || !newIn || !isExactModelTime(*newIn)) {
            return notRepresentable(clip.id, clip.timelineStart);
        }
        // Effect spans keep their timeline frames: their clip times move with the in point.
        // (Transitions are offsets from the clip's edges: unchanged.)
        for (EffectSpan &span : clip.spans) {
            auto moved = [&](CMTime t) -> std::optional<CMTime> {
                const auto exact = ExactTime::from(t);
                const auto shifted = exact ? exact->plus(*shift) : std::nullopt;
                return shifted ? exactTimeOn(*shifted, t.timescale) : std::nullopt;
            };
            const auto start = moved(span.start);
            const auto spanEnd = moved(span.end);
            if (!start || !spanEnd || !isExactModelTime(*start) || !isExactModelTime(*spanEnd)) {
                return notRepresentable(clip.id, clip.timelineStart);
            }
            span.start = *start;
            span.end = *spanEnd;
        }
        clip.sourceIn = *newIn;
        clip.reversed = reversed_;
    }
    return EditResult::success();
}

SetTransitionKind::SetTransitionKind(SequenceId sequenceId, SpanId spanId, TransitionKind kind)
    : SequenceCommand(sequenceId), spanId_(spanId), kind_(kind) {}

EditResult SetTransitionKind::perform(const Project &project, Sequence &sequence, IdGenerator &) {
    Clip *clip = nullptr;
    Track *track = nullptr;
    TransitionSpan *span = sequence.findTransition(spanId_, &clip, &track);
    if (span == nullptr) {
        return EditResult::failure(EditError::TransitionNotFound,
                                   "transition " + idString(spanId_.value()) + " does not exist");
    }
    if (EditResult r = requireEditableTrack(track, track->id); !r) {
        return r;
    }
    if (!transitionKindFitsTrack(kind_, track->kind)) {
        return EditResult::failure(EditError::TrackKindMismatch,
                                   std::string("An audio transition is a crossfade or a fade; it cannot be a ") +
                                       displayNameOf(kind_) + ".");
    }
    if (track->kind != TrackKind::Video) {
        return EditResult::success(); // what every audio transition is: nothing to change (review L9)
    }
    if (kind_ != span->kind || !span->unknownKindName.empty()) {
        // Another kind keeps the parameters it has; the foreign ones described the kind it replaces.
        span->parameters = parametersKeptBy(kind_, span->parameters);
        span->foreignParameters.clear();
    }
    span->kind = kind_;
    span->unknownKindName.clear(); // a kind chosen replaces one from a newer version's file
    if (EditResult r = checkPlacedTransition(project, sequence, *track, *clip, *span); !r) {
        return r;
    }
    return EditResult::success();
}

namespace {

// linkedTransition for the lane-0 `span` of `owner` on `track`, with `find` looking clips up by id.
template <typename Find>
std::optional<SpanId> linkedTransitionOf(const Track &track, const Clip &owner, const TransitionSpan &span, Find find) {
    const auto transition = placeTransition(track, owner, span);
    if (!transition || !owner.linkedClipId) {
        return std::nullopt;
    }
    const auto [partnerOwner, partnerTrack] = find(*owner.linkedClipId);
    const TransitionSpan *candidate = partnerOwner != nullptr ? partnerOwner->transitionAt(span.edge) : nullptr;
    if (candidate == nullptr || partnerTrack == nullptr) {
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

} // namespace

std::optional<SpanId> linkedTransition(const Sequence &sequence, SpanId spanId) {
    const Clip *owner = nullptr;
    const Track *track = nullptr;
    const TransitionSpan *span = sequence.findTransition(spanId, &owner, &track);
    if (span == nullptr) {
        return std::nullopt;
    }
    return linkedTransitionOf(*track, *owner, *span, [&](ClipId id) {
        const Clip *clip = sequence.findClip(id);
        return std::make_pair(clip, clip != nullptr ? sequence.trackOfClip(id) : nullptr);
    });
}

ClipIndex::ClipIndex(const Sequence &sequence) {
    for (const std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (const Track &track : *list) {
            for (const Clip &clip : track.clips) {
                clips_.emplace(clip.id, std::make_pair(&clip, &track));
            }
        }
    }
}

std::pair<const Clip *, const Track *> ClipIndex::find(ClipId id) const {
    const auto it = clips_.find(id);
    return it != clips_.end() ? it->second : std::make_pair<const Clip *, const Track *>(nullptr, nullptr);
}

std::optional<SpanId> ClipIndex::linkedTransition(const Track &track, const Clip &owner, const TransitionSpan &span) const {
    return linkedTransitionOf(track, owner, span, [this](ClipId id) { return find(id); });
}

bool isThroughEdit(const Sequence &sequence, ClipId fromClipId, ClipId toClipId) {
    const Clip *from = sequence.findClip(fromClipId);
    const Clip *to = sequence.findClip(toClipId);
    if (!from || !to || from->assetId != to->assetId || from->trackId != to->trackId ||
        CMTimeCompare(from->timelineEnd(), to->timelineStart) != 0 || from->isStill != to->isStill ||
        from->reversed != to->reversed ||
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

EditError editErrorOf(RoomLimit limit) {
    switch (limit) {
    case RoomLimit::ClipLength:
        return EditError::InvalidArgument;
    case RoomLimit::OtherEdge:
    case RoomLimit::IncomingDissolve:
        return EditError::Overlap;
    case RoomLimit::Media:
        return EditError::InsufficientHandles;
    }
    return EditError::InvalidArgument;
}

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

} // namespace

std::optional<TransitionSideLimits> transitionSideLimits(const Project &project, SequenceId sequenceId, ClipId ownerId,
                                                         SpanId existing, EditResult &why) {
    const Sequence *sequence = project.findSequence(sequenceId);
    if (!sequence) {
        why = EditResult::failure(EditError::SequenceNotFound, "The sequence no longer exists.");
        return std::nullopt;
    }
    return transitionSideLimits(project, *sequence, ownerId, existing, why);
}

std::optional<TransitionSideLimits> transitionSideLimits(const Project &project, const Sequence &sequenceRef,
                                                         ClipId ownerId, SpanId existing, EditResult &why) {
    const Sequence *sequence = &sequenceRef;
    if (!isPositive(sequence->frameDuration)) {
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
    const TransitionSpan *tail = owner->transitionAt(ClipEdge::Tail);
    if (tail && tail->id != existing) {
        why = EditResult::failure(EditError::AlreadyExists, "This cut already has a transition.");
        return std::nullopt;
    }
    if (existing && !tail) {
        why = EditResult::failure(EditError::TransitionNotFound, "The transition no longer exists.");
        return std::nullopt;
    }
    // TransitionRules::edgeRoom: before the cut the owner's frames not taken by its fade in or by a
    // dissolve into it, and the next clip's media before its in point; after the cut the next clip's
    // frames not taken by its own tail transition, and the owner's media after its out point.
    const EdgeRoom room =
        TransitionRules::edgeRoom(project, *track, *owner, ClipEdge::Tail, TransitionShape::CrossDissolve,
                                  sequence->frameDuration);
    TransitionSideLimits limits;
    limits.maxBeforeFrames = room.inside.frames;
    limits.beforeError = editErrorOf(room.inside.limit);
    limits.beforeReason = room.inside.reason;
    if (room.inside.limit == RoomLimit::Media) {
        limits.beforeLimitingClip = room.inside.limitingClip;
    }
    const SideRoom &after = *room.beyond; // a clip touches the owner's end (checked above)
    limits.maxAfterFrames = after.frames;
    limits.afterError = editErrorOf(after.limit);
    limits.afterReason = after.reason;
    if (after.limit == RoomLimit::Media) {
        limits.afterLimitingClip = after.limitingClip;
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
        for (const TransitionSpan &span : clip.transitions) {
            markRemovedOnPurpose(span.id);
        }
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

// ----- Sequence settings -----

namespace {

// The scale that fits a picture of the asset's displayed size into a width x height frame (the
// compositor's fit, Compositor.h).
double fitScale(const MediaAsset &asset, double width, double height) {
    return std::min(width / double(asset.width), height / double(asset.height));
}

std::string sizeName(std::int32_t width, std::int32_t height) {
    return std::to_string(width) + "×" + std::to_string(height);
}

// "0.5 s", "0.042 s" (at most 3 decimals, trailing zeros dropped).
std::string secondsName(CMTime t) {
    char buffer[48];
    std::snprintf(buffer, sizeof buffer, "%.3f", toSeconds(t));
    std::string text = buffer;
    while (text.size() > 1 && text.back() == '0') {
        text.pop_back();
    }
    if (text.back() == '.') {
        text.pop_back();
    }
    return text + " s";
}

std::string framesName(std::int64_t frames) {
    return std::to_string(frames) + (frames == 1 ? " frame" : " frames");
}

// "1 clip", "3 clips".
std::string countName(std::size_t count, const char *one, const char *many) {
    return std::to_string(count) + " " + (count == 1 ? one : many);
}

// "Motion, Opacity and Gain": the effect span kinds (those with parameters), from the kind table.
std::string effectKindsName() {
    std::vector<std::string> names;
    for (const SpanKind kind : kSpanKinds) {
        if (!infoOf(kind).parameters.empty()) {
            names.push_back(displayNameOf(kind));
        }
    }
    std::string text;
    for (std::size_t i = 0; i < names.size(); ++i) {
        text += (i == 0 ? "" : i + 1 == names.size() ? " and " : ", ") + names[i];
    }
    return text;
}

// "the cross dissolve between “a.mov” and “b.mov”", "the crossfade between ...", "the fade in at the
// start of “a.mov”", "the Wipe Left fade out at the end of “a.mov”".
std::string transitionName(const Project &project, const Track &track, const Clip &owner, const TransitionSpan &span) {
    const auto placement = placeTransition(track, owner, span);
    const bool audio = track.kind == TrackKind::Audio;
    std::string kind;
    if (!audio && span.kind != TransitionKind::CrossDissolve) {
        kind = std::string(displayNameOf(span.kind)) + " ";
    }
    if (placement && placement->role == TransitionRole::CrossDissolve && placement->partner != nullptr) {
        const std::string what = audio ? "crossfade" : (kind.empty() ? "cross dissolve" : kind + "transition");
        return "the " + what + " between " + quotedMediaName(project, owner) + " and " +
               quotedMediaName(project, *placement->partner);
    }
    if (span.edge == ClipEdge::Head) {
        return "the " + kind + "fade in at the start of " + quotedMediaName(project, owner);
    }
    return "the " + kind + "fade out at the end of " + quotedMediaName(project, owner);
}

// Whole frames of `offset` (a transition offset, >= 0) on the grid, rounded to the nearest.
std::int64_t roundedFrames(CMTime offset, CMTime frameDuration) {
    const auto exact = ExactTime::from(offset);
    return exact ? std::max<std::int64_t>(0, exact->frameIndex(frameDuration, SnapMode::Round).value_or(0)) : 0;
}

struct TransitionFrames {
    std::int64_t before = 0; // frames before the cut (a tail span's inside part)
    std::int64_t after = 0;  // frames after the cut, or a fade in's length
};

// Sets the lane-0 span's offsets to `frames` on the grid.
void setTransitionFrames(TransitionSpan &span, TransitionFrames frames, CMTime frameDuration) {
    if (span.edge == ClipEdge::Head) {
        span.start = kCMTimeZero;
        span.end = timeForFrame(frames.after, frameDuration);
    } else {
        span.start = negateTime(timeForFrame(frames.before, frameDuration));
        span.end = timeForFrame(frames.after, frameDuration);
    }
}

// ----- The frame-rate conform of clip edges -----
//
// Every clip edge moves to the new frame grid. Edges that must stay together are conformed together, as
// one "edge group" that gets one new time: a clip's end and the start of the clip touching it on its
// track (a cut), and the same edges of linked clips that were at the same time (a linked pair stays
// aligned). A group takes the nearest grid time if every clip allows it (an end needs media up to it, a
// start media from it, each clip keeps a frame, a start stays at or after the end of the clip before it),
// else the grid time on the other side of the old time. When neither works at a cut (the clip before it
// ends on its media's end and the clip after it starts on its media's start: two whole clips), the cut
// goes to the latest grid time the ends allow and the clips starting there move to it with their media
// (their in point is kept) instead of losing their first picture to a trim; a clip keeps the move of
// the clips it is linked to, so linked picture and sound stay in sync, and a later edge of a moved clip
// is conformed from its moved time. Groups are handled in time order, so a clip's start is decided
// before its end.
struct ConformedClip {
    Clip *clip = nullptr;
    const Track *track = nullptr;
    std::size_t indexOnTrack = 0;
    CMTime mediaEnd = kCMTimeInvalid; // not numeric for a still (no media bounds)
    std::size_t component = 0;        // linked clips share one
    std::optional<std::size_t> partner; // the clip it is linked to, when it is in the sequence
    std::optional<CMTime> newStart;
    std::optional<CMTime> newEnd;
};

class EdgeConform {
  public:
    EdgeConform(const Project &project, Sequence &sequence, CMTime newFrameDuration)
        : project_(project), fd_(newFrameDuration) {
        std::unordered_map<ClipId, std::size_t> indexOf;
        for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
            for (Track &track : *list) {
                for (std::size_t i = 0; i < track.clips.size(); ++i) {
                    Clip &clip = track.clips[i];
                    ConformedClip c;
                    c.clip = &clip;
                    c.track = &track;
                    c.indexOnTrack = i;
                    const MediaAsset *asset = project.findAsset(clip.assetId);
                    if (asset != nullptr && !clip.isStill) {
                        c.mediaEnd = mediaEndFor(*asset, track.kind);
                    }
                    c.component = clips_.size();
                    indexOf[clip.id] = clips_.size();
                    clips_.push_back(c);
                }
            }
        }
        for (ConformedClip &c : clips_) {
            if (c.clip->linkedClipId) {
                if (auto it = indexOf.find(*c.clip->linkedClipId); it != indexOf.end()) {
                    c.partner = it->second;
                    c.component = std::min(c.component, clips_[it->second].component);
                    clips_[it->second].component = c.component;
                }
            }
        }
        shift_.assign(clips_.size(), std::nullopt);
        // Edge groups: edge 2i is clip i's start, 2i + 1 its end.
        parent_.resize(clips_.size() * 2);
        for (std::size_t e = 0; e < parent_.size(); ++e) {
            parent_[e] = e;
        }
        std::size_t first = 0;
        for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
            for (Track &track : *list) {
                for (std::size_t i = 0; i + 1 < track.clips.size(); ++i) {
                    if (track.clips[i].timelineEnd() == track.clips[i + 1].timelineStart) {
                        unite(2 * (first + i) + 1, 2 * (first + i + 1));
                    }
                }
                first += track.clips.size();
            }
        }
        for (std::size_t i = 0; i < clips_.size(); ++i) {
            const Clip &clip = *clips_[i].clip;
            if (!clip.linkedClipId) {
                continue;
            }
            const auto it = indexOf.find(*clip.linkedClipId);
            if (it == indexOf.end()) {
                continue;
            }
            const Clip &partner = *clips_[it->second].clip;
            if (clip.timelineStart == partner.timelineStart) {
                unite(2 * i, 2 * it->second);
            }
            if (clip.timelineEnd() == partner.timelineEnd()) {
                unite(2 * i + 1, 2 * it->second + 1);
            }
        }
    }

    // Decides every edge's new time (and the clips that move with their media), then retimes the clips.
    EditResult run(SequenceConformReport &report) {
        std::map<std::size_t, std::vector<std::size_t>> groups; // root edge -> its edges
        for (std::size_t e = 0; e < parent_.size(); ++e) {
            groups[find(e)].push_back(e);
        }
        std::vector<std::vector<std::size_t>> ordered;
        ordered.reserve(groups.size());
        for (auto &[root, edges] : groups) {
            ordered.push_back(std::move(edges));
        }
        std::sort(ordered.begin(), ordered.end(), [&](const auto &a, const auto &b) {
            const CMTime ta = edgeTime(a.front());
            const CMTime tb = edgeTime(b.front());
            return ta < tb || (ta == tb && a.front() < b.front());
        });
        groups_ = std::move(ordered);
        groupOf_.assign(parent_.size(), 0);
        for (std::size_t g = 0; g < groups_.size(); ++g) {
            for (std::size_t e : groups_[g]) {
                groupOf_[e] = g;
            }
        }
        for (const std::vector<std::size_t> &group : groups_) {
            if (EditResult r = decide(group); !r) {
                return r;
            }
        }
        // The clips whose edges went where they did not round to (a start back with its cut, an end apart
        // from its group), now that every edge is decided: each still plays part of what it played and
        // overlaps the clip it is linked to.
        for (std::size_t i : displaced_) {
            if (auto why = misplacement(i, *clips_[i].newStart, *clips_[i].newEnd)) {
                return EditResult::failure(EditError::OutOfSourceRange,
                                           name(i) + " cannot keep a frame at " + frameRateName(fd_) +
                                               " fps where it plays: it would " + *why +
                                               "; trim or unlink them first.");
            }
        }
        return apply(report);
    }

  private:
    std::size_t find(std::size_t e) {
        while (parent_[e] != e) {
            parent_[e] = parent_[parent_[e]];
            e = parent_[e];
        }
        return e;
    }
    void unite(std::size_t a, std::size_t b) {
        a = find(a);
        b = find(b);
        if (a != b) {
            parent_[std::max(a, b)] = std::min(a, b);
        }
    }
    static bool isHead(std::size_t edge) {
        return edge % 2 == 0;
    }
    CMTime edgeTime(std::size_t edge) const {
        const Clip &clip = *clips_[edge / 2].clip;
        return isHead(edge) ? clip.timelineStart : clip.timelineEnd();
    }
    // The move of clip `i` with its media: decided, or none yet.
    CMTime shiftOf(std::size_t i) const {
        return shift_[clips_[i].component].value_or(kCMTimeZero);
    }
    bool shiftDecided(std::size_t i) const {
        return shift_[clips_[i].component].has_value();
    }
    std::string name(std::size_t i) const {
        return quotedMediaName(project_, *clips_[i].clip);
    }

    // Whether clip `i` (moved by its shift) has media up to `p` for its end, and keeps a frame.
    bool endAllows(std::size_t i, CMTime p) const {
        return endAllowsWith(i, p, shiftOf(i));
    }
    bool endAllowsWith(std::size_t i, CMTime p, CMTime shift) const {
        const ConformedClip &c = clips_[i];
        if (!(*c.newStart < p)) {
            return false;
        }
        if (!isNumeric(c.mediaEnd)) {
            return true;
        }
        const auto source = c.clip->exactSourceTimeAt(p - shift);
        return source && source->compare(c.mediaEnd) <= 0;
    }
    // Whether clip `i` (moved by its shift) has media from `p` for its start.
    bool mediaFrom(std::size_t i, CMTime p) const {
        return mediaFromWith(i, p, shiftOf(i));
    }
    bool mediaFromWith(std::size_t i, CMTime p, CMTime shift) const {
        const ConformedClip &c = clips_[i];
        if (!isNumeric(c.mediaEnd)) {
            return true;
        }
        const auto source = c.clip->exactSourceTimeAt(p - shift);
        return source && source->compare(kCMTimeZero) >= 0;
    }
    // The clip before clip `i` on its track, when its end is not in `group` (it does not touch).
    std::optional<std::size_t> separatePrevious(std::size_t i, const std::vector<std::size_t> &group) const {
        const ConformedClip &c = clips_[i];
        if (c.indexOnTrack == 0) {
            return std::nullopt;
        }
        const std::size_t previous = i - 1; // the same track's clips are consecutive in clips_
        const std::size_t previousEnd = 2 * previous + 1;
        if (std::find(group.begin(), group.end(), previousEnd) != group.end()) {
            return std::nullopt;
        }
        return previous;
    }
    bool startAllows(std::size_t i, CMTime p, const std::vector<std::size_t> &group) const {
        if (!mediaFrom(i, p)) {
            return false;
        }
        const auto previous = separatePrevious(i, group);
        return !previous || *clips_[*previous].newEnd <= p;
    }

    static bool overlaps(CMTime from, CMTime to, CMTime otherFrom, CMTime otherTo) {
        return maxTime(from, otherFrom) < minTime(to, otherTo);
    }
    // What clip `i` would do wrong at [from, to) (its new range, after its move), or nullopt: it must still
    // play part of what it played (its old range, moved with it), and still overlap the clip it is linked to
    // where they overlapped. That clip's new range is its decided start (none: not yet decided, so not
    // limited) to `partnerEnd` when given, else to its decided end (none: not limited). An edge that the
    // conform takes away from where it rounded to keep a frame (a start going back with its cut, an end
    // apart from its group) is held to this, so a linked clip shorter than a frame never ends up beside
    // the clip it is linked to, or playing none of its own sound.
    std::optional<std::string> misplacement(std::size_t i, CMTime from, CMTime to,
                                            std::optional<CMTime> partnerEnd = std::nullopt) const {
        const ConformedClip &c = clips_[i];
        const CMTime shift = shiftOf(i);
        if (!overlaps(from, to, c.clip->timelineStart + shift, c.clip->timelineEnd() + shift)) {
            return std::string("play none of its own ") + (c.track->kind == TrackKind::Audio ? "sound" : "picture");
        }
        if (!c.partner) {
            return std::nullopt;
        }
        const ConformedClip &o = clips_[*c.partner];
        if (!overlaps(c.clip->timelineStart, c.clip->timelineEnd(), o.clip->timelineStart, o.clip->timelineEnd())) {
            return std::nullopt;
        }
        if (!partnerEnd) {
            partnerEnd = o.newEnd;
        }
        if (partnerEnd && !(from < *partnerEnd)) {
            return std::string("start after the clip it is linked to ends");
        }
        if (o.newStart && !(*o.newStart < to)) {
            return std::string("end before the clip it is linked to starts");
        }
        return std::nullopt;
    }

    // Whether the start of clip `i`, decided earlier, may go back to `q` for a one-frame clip [q, q + one
    // frame), with the rest of its edge group: the clip still shows part of what it showed (it ended after
    // its old start), every start of the group allows `q`, and every end of it (a cut the start shares: the
    // clip before it on its track, and clips ending with that one) has media to `q` and keeps a frame
    // before it, still playing part of what it played and overlapping the clip it is linked to. A clip
    // whose start rounded up leaves itself no frame before the cut it ends at (a sound clip shorter than a
    // frame, linked to a picture ending on its media's end) keeps one this way, extending its head into its
    // media and bringing the cut before it back with it, so that it stays under its picture.
    bool startCanGoBack(std::size_t i, CMTime q) const {
        if (q < kCMTimeZero || !(clips_[i].clip->timelineStart + shiftOf(i) < q + fd_)) {
            return false;
        }
        const std::vector<std::size_t> &group = groups_[groupOf_[2 * i]];
        return std::all_of(group.begin(), group.end(), [&](std::size_t e) {
            const std::size_t j = e / 2;
            if (isHead(e)) {
                return startAllows(j, q, group);
            }
            if (isApart(e)) {
                return true; // decided apart from the group: it stays
            }
            return endAllows(j, q) && !misplacement(j, *clips_[j].newStart, q);
        });
    }
    void moveStartBack(std::size_t i, CMTime q) {
        for (std::size_t e : groups_[groupOf_[2 * i]]) {
            ConformedClip &c = clips_[e / 2];
            if (isHead(e)) {
                c.newStart = q;
            } else if (!isApart(e)) {
                c.newEnd = q;
            }
            displaced_.push_back(e / 2);
        }
    }

    // Whether the end of clip `i` may leave `group` for one frame after its start: no clip of its own track
    // starts in the group (it ends here with linked clips only), and it has media for that frame.
    bool canEndApart(std::size_t i, const std::vector<std::size_t> &group) const {
        const ConformedClip &c = clips_[i];
        if (c.indexOnTrack + 1 < c.track->clips.size() &&
            std::find(group.begin(), group.end(), 2 * (i + 1)) != group.end()) {
            return false;
        }
        return endAllows(i, *c.newStart + fd_);
    }
    // The new end of the clip linked to clip `i`, when its end is in `group` (to be decided at `p` or later,
    // unless decided apart), else its decided end (none: not yet decided).
    std::optional<CMTime> partnerEndAt(std::size_t i, const std::vector<std::size_t> &group, CMTime p) const {
        if (!clips_[i].partner) {
            return std::nullopt;
        }
        const std::size_t partner = *clips_[i].partner;
        const std::size_t end = 2 * partner + 1;
        if (!isApart(end) && std::find(group.begin(), group.end(), end) != group.end()) {
            return p;
        }
        return clips_[partner].newEnd;
    }
    bool isApart(std::size_t edge) const {
        return std::find(apart_.begin(), apart_.end(), edge) != apart_.end();
    }

    // Why the end of clip `previous`, decided earlier at a later time, cannot come back to `q` (the start
    // of the next clip on its track), or nullopt when it can: its whole edge group comes back, so each end
    // of it must keep a frame before `q` (a start going back if need be, see startCanGoBack; media to `q`
    // it has, being earlier), and each start of it (a cut on another track) allow `q`. An end that rounded
    // up on its own (a sound clip one picture frame shorter than the picture it is linked to) comes back
    // to the cut this way.
    std::optional<std::string> endCannotComeBack(std::size_t previous, CMTime q) const {
        const std::vector<std::size_t> &group = groups_[groupOf_[2 * previous + 1]];
        for (std::size_t e : group) {
            const std::size_t j = e / 2;
            if (isApart(e) && e != 2 * previous + 1) {
                continue; // decided apart from the group: it stays
            }
            if (isHead(e)) {
                if (!startAllows(j, q, group)) {
                    return name(previous) + " cannot end before the next clip on its track at " + frameRateName(fd_) +
                           " fps: " + name(j) + " starts where it ends and has no media to start earlier; trim one "
                           "of them first.";
                }
                continue;
            }
            const bool keepsAFrame = *clips_[j].newStart < q || startCanGoBack(j, q - fd_);
            if (!keepsAFrame) {
                return name(j) + " is shorter than a frame at " + frameRateName(fd_) +
                       " fps and the next clip leaves no room for one; trim or remove it first.";
            }
        }
        return std::nullopt;
    }
    void bringEndBack(std::size_t previous, CMTime q) {
        for (std::size_t e : groups_[groupOf_[2 * previous + 1]]) {
            if (isApart(e) && e != 2 * previous + 1) {
                continue;
            }
            const std::size_t j = e / 2;
            if (isHead(e)) {
                clips_[j].newStart = q;
                continue;
            }
            if (!(*clips_[j].newStart < q)) {
                moveStartBack(j, q - fd_);
            }
            clips_[j].newEnd = q;
        }
    }

    // Whether the clips linked to clip `i` (its component), all decided not to move, may move by `shift`
    // with it: every edge decided so far keeps its media with the shift (the clips are moved and then
    // trimmed to their decided edges), as do the starts of `starts` (this group's, at `p`). A linked clip
    // that started earlier (dual-system sound rolling before the camera) was decided first; it slips its
    // content by the move, which keeps it in sync with the picture that moves.
    bool componentCanMove(std::size_t i, CMTime shift, const std::vector<std::size_t> &starts, CMTime p) const {
        for (std::size_t j = 0; j < clips_.size(); ++j) {
            if (clips_[j].component != clips_[i].component) {
                continue;
            }
            const ConformedClip &c = clips_[j];
            if (std::find(starts.begin(), starts.end(), j) != starts.end()) {
                if (!mediaFromWith(j, p, shift)) {
                    return false;
                }
                continue;
            }
            if (c.newStart && !mediaFromWith(j, *c.newStart, shift)) {
                return false;
            }
            if (c.newEnd && !endAllowsWith(j, *c.newEnd, shift)) {
                return false;
            }
        }
        return true;
    }

    EditResult decide(const std::vector<std::size_t> &group) {
        std::vector<std::size_t> ends;
        std::vector<std::size_t> starts;
        for (std::size_t e : group) {
            (isHead(e) ? starts : ends).push_back(e / 2);
        }
        const CMTime t = edgeTime(group.front());
        // Where the group's clips are now: moved clips count from their moved time when they all moved alike.
        CMTime reference = t;
        {
            std::optional<CMTime> common;
            bool alike = true;
            for (std::size_t e : group) {
                const CMTime shift = shiftOf(e / 2);
                if (common && !(*common == shift)) {
                    alike = false;
                }
                common = shift;
            }
            if (alike && common) {
                reference = t + *common;
            }
        }
        auto allows = [&](CMTime p) {
            return std::all_of(ends.begin(), ends.end(), [&](std::size_t i) { return endAllows(i, p); }) &&
                   std::all_of(starts.begin(), starts.end(), [&](std::size_t i) { return startAllows(i, p, group); });
        };
        const CMTime nearest = snapToFrame(reference, fd_, SnapMode::Round);
        std::vector<CMTime> candidates{nearest};
        if (!(nearest == reference)) {
            candidates.push_back(snapToFrame(reference, fd_, nearest < reference ? SnapMode::Ceil : SnapMode::Floor));
        }
        for (const CMTime p : candidates) {
            if (allows(p)) {
                settle(group, p, {});
                return EditResult::success();
            }
        }
        if (ends.empty()) {
            // Starts only: later, as far as their media and the clips before them require (a trim).
            CMTime p = snapToFrame(reference, fd_, SnapMode::Ceil);
            for (std::size_t i : starts) {
                const ConformedClip &c = clips_[i];
                if (isNumeric(c.mediaEnd)) {
                    const auto zeroAt = c.clip->exactTimelineTimeAt(kCMTimeZero);
                    const auto shift = ExactTime::from(shiftOf(i));
                    const auto from = zeroAt && shift ? zeroAt->plus(*shift) : std::nullopt;
                    const auto frame = from ? from->frameIndex(fd_, SnapMode::Ceil) : std::nullopt;
                    if (!frame) {
                        return notRepresentable(i);
                    }
                    p = maxTime(p, timeForFrame(*frame, fd_));
                }
                if (const auto previous = separatePrevious(i, group)) {
                    p = maxTime(p, *clips_[*previous].newEnd);
                }
            }
            settle(group, p, {});
            return EditResult::success();
        }
        // The latest grid time at or before the old one that every end's media reaches, unless a clip ending
        // here needs a later one to keep a frame.
        CMTime p = snapToFrame(minTime(reference, t), fd_, SnapMode::Floor);
        for (std::size_t i : ends) {
            const ConformedClip &c = clips_[i];
            if (!isNumeric(c.mediaEnd)) {
                continue;
            }
            const auto endAt = c.clip->exactTimelineTimeAt(c.mediaEnd);
            const auto shift = ExactTime::from(shiftOf(i));
            const auto until = endAt && shift ? endAt->plus(*shift) : std::nullopt;
            const auto frame = until ? until->frameIndex(fd_, SnapMode::Floor) : std::nullopt;
            if (!frame) {
                return notRepresentable(i);
            }
            p = minTime(p, timeForFrame(*frame, fd_));
        }
        // A later p where a clip ending here needs one to keep a frame; when an end has no media there, such a
        // clip whose start may go back (see startCanGoBack) starts a frame before p instead.
        auto latestStart = [&] {
            std::size_t shortest = ends.front();
            for (std::size_t i : ends) {
                if (*clips_[shortest].newStart < *clips_[i].newStart) {
                    shortest = i;
                }
            }
            return shortest;
        };
        std::size_t shortest = latestStart(); // the clip that needs the latest p to keep a frame
        const CMTime raised = maxTime(p, *clips_[shortest].newStart + fd_);
        std::map<std::size_t, std::string> notApart; // why a clip without a frame could not end apart
        if (!std::all_of(ends.begin(), ends.end(), [&](std::size_t i) { return endAllows(i, raised); })) {
            // Such a clip starts a frame before p, bringing the cut at its start back with it when it shares
            // one (see startCanGoBack), so that it stays under the clip it is linked to. Or else, when it ends
            // here only with the clip it is linked to (nothing on its own track starts here) and has media for
            // a frame from its start, it ends there instead, apart from the group, provided that frame still
            // plays part of what it played and overlaps that clip (see misplacement); otherwise it stays, and
            // the change is refused below with the reason. Its start being on the grid at or after p, that
            // frame overlaps the clip it is linked to only when another clip ending here takes the group past
            // p: a clip apart never ends "a fraction of a frame after its picture" (as 7e2335b had it); alone,
            // it would start at or after its picture's end.
            std::vector<std::size_t> kept;
            std::size_t left = ends.size(); // ends still in the group (at least one stays)
            for (std::size_t i : ends) {
                if (!(p < *clips_[i].newStart + fd_)) {
                    kept.push_back(i);
                } else if (startCanGoBack(i, p - fd_)) {
                    moveStartBack(i, p - fd_);
                    kept.push_back(i);
                } else if (left > 1 && canEndApart(i, group)) {
                    const CMTime start = *clips_[i].newStart;
                    if (auto why = misplacement(i, start, start + fd_, partnerEndAt(i, group, p))) {
                        notApart[i] = *why;
                        kept.push_back(i);
                        continue;
                    }
                    clips_[i].newEnd = start + fd_;
                    apart_.push_back(2 * i + 1);
                    displaced_.push_back(i);
                    --left;
                } else {
                    kept.push_back(i);
                }
            }
            ends = std::move(kept);
            shortest = latestStart();
        }
        const CMTime keepsAFrame = *clips_[shortest].newStart + fd_;
        p = maxTime(p, keepsAFrame);
        for (std::size_t i : ends) {
            if (!endAllows(i, p)) {
                const bool alone = i == shortest || !(*clips_[i].newStart + fd_ < keepsAFrame);
                if (const auto why = notApart.find(alone ? i : shortest); why != notApart.end()) {
                    return EditResult::failure(EditError::OutOfSourceRange,
                                               name(why->first) + " is shorter than a frame at " + frameRateName(fd_) +
                                                   " fps and has no room for one: it cannot start earlier, and a "
                                                   "frame from its start would " +
                                                   why->second + "; trim or unlink them first.");
                }
                if (alone) {
                    return EditResult::failure(EditError::OutOfSourceRange,
                                               name(i) + " is shorter than a frame at " + frameRateName(fd_) +
                                                   " fps and has no media to fill one; trim or remove it first.");
                }
                return EditResult::failure(EditError::OutOfSourceRange,
                                           name(shortest) + " is shorter than a frame at " + frameRateName(fd_) +
                                               " fps, and " + name(i) +
                                               ", which ends with it, has no media to make room for one; trim or "
                                               "unlink them first.");
            }
        }
        // The starts that have no media from p move there with their media (with the clips linked to them).
        std::vector<std::pair<std::size_t, CMTime>> moves;
        std::vector<std::size_t> endsBack; // clips before a start whose end comes back to p
        for (std::size_t i : starts) {
            if (const auto previous = separatePrevious(i, group); previous && p < *clips_[*previous].newEnd) {
                if (auto why = endCannotComeBack(*previous, p)) {
                    return EditResult::failure(EditError::Overlap, *why);
                }
                endsBack.push_back(*previous);
            }
            if (mediaFrom(i, p)) {
                continue;
            }
            const CMTime move = p - clips_[i].clip->timelineStart; // its in point then plays at p
            if (shiftDecided(i) && !(shiftOf(i) == kCMTimeZero && componentCanMove(i, move, starts, p))) {
                return EditResult::failure(
                    EditError::OutOfSourceRange,
                    name(i) + " cannot stay against the clip before it at " + frameRateName(fd_) +
                        " fps: it has no media before its in point and moving it would put it out of sync with the "
                        "clip it is linked to; unlink them or trim it first.");
            }
            moves.emplace_back(i, move);
        }
        for (std::size_t previous : endsBack) {
            bringEndBack(previous, p);
        }
        settle(group, p, moves);
        return EditResult::success();
    }

    // Records `p` as the new time of every edge of `group`, the moves of the clips in `moves` (for their
    // linked clips too), and no move for the other clips starting there.
    void settle(const std::vector<std::size_t> &group, CMTime p,
                const std::vector<std::pair<std::size_t, CMTime>> &moves) {
        for (const auto &[i, move] : moves) {
            shift_[clips_[i].component] = move;
        }
        for (std::size_t e : group) {
            ConformedClip &c = clips_[e / 2];
            if (isHead(e)) {
                c.newStart = p;
                if (!shift_[c.component]) {
                    shift_[c.component] = kCMTimeZero;
                }
            } else if (!isApart(e)) {
                c.newEnd = p;
            }
        }
    }

    EditResult notRepresentable(std::size_t i) const {
        return EditResult::failure(EditError::NotRepresentable,
                                   "A media time of " + name(i) + " has no exact form at " + frameRateName(fd_) +
                                       " fps.");
    }

    EditResult apply(SequenceConformReport &report) {
        for (std::size_t i = 0; i < clips_.size(); ++i) {
            ConformedClip &c = clips_[i];
            Clip &clip = *c.clip;
            const CMTime start = clip.timelineStart;
            const CMTime end = clip.timelineEnd();
            const CMTime newStart = *c.newStart;
            const CMTime newEnd = *c.newEnd;
            const CMTime shift = shiftOf(i);
            if (!(shift == kCMTimeZero)) {
                // Moves with its media: the in point, and the spans (source times; a still's are relative to
                // its start), stay as they are.
                clip.timelineStart = start + shift;
                ++report.clipsMoved;
                report.largestMove = maxTime(report.largestMove, shift < kCMTimeZero ? -shift : shift);
            }
            const CMTime movedStart = clip.timelineStart;
            const CMTime movedEnd = clip.timelineEnd();
            if (newStart == start && newEnd == end && shift == kCMTimeZero) {
                continue;
            }
            RetimeResult retimed = RetimeResult::Ok;
            if (newEnd > movedEnd) {
                retimed = clip.setTimelineEnd(newEnd);
                if (retimed == RetimeResult::Ok && !(newStart == movedStart)) {
                    retimed = clip.setTimelineStartKeepingEnd(newStart);
                }
            } else {
                if (!(newStart == movedStart)) {
                    retimed = clip.setTimelineStartKeepingEnd(newStart);
                }
                if (retimed == RetimeResult::Ok && !(newEnd == movedEnd)) {
                    retimed = clip.setTimelineEnd(newEnd);
                }
            }
            if (retimed != RetimeResult::Ok) {
                return retimeRefusal(retimed, clip.id, newStart);
            }
            ++report.clipsRetimed;
            for (const CMTime change : {newStart - start, newEnd - end}) {
                report.largestShift = maxTime(report.largestShift, change < kCMTimeZero ? -change : change);
            }
        }
        return EditResult::success();
    }

    const Project &project_;
    const CMTime fd_;
    std::vector<ConformedClip> clips_;
    std::vector<std::optional<CMTime>> shift_; // by component
    std::vector<std::size_t> parent_;          // edge groups (union-find)
    std::vector<std::vector<std::size_t>> groups_; // the edge groups, in time order (run)
    std::vector<std::size_t> groupOf_;             // by edge: its group's index in groups_
    std::vector<std::size_t> apart_;               // ends decided apart from their group (canEndApart)
    std::vector<std::size_t> displaced_;           // clips with an edge moved back with its cut or apart
};

} // namespace

SetSequenceFormat::SetSequenceFormat(SequenceId sequenceId, SequenceFormat format, std::string name)
    : SequenceCommand(sequenceId), format_(format), name_(std::move(name)) {}

EditResult SetSequenceFormat::perform(const Project &project, Sequence &sequence, IdGenerator &) {
    if (auto problem = sequenceFormatProblem(format_)) {
        return EditResult::failure(EditError::InvalidArgument, *problem);
    }
    report_ = SequenceConformReport{};
    const SequenceFormat old = sequence.format();
    SequenceFormat target = format_;
    target.configured = true;
    report_.before = old;
    report_.after = target;
    std::vector<std::string> &sentences = report_.sentences;

    // Size: positions are sequence pixels.
    if (target.width != old.width || target.height != old.height) {
        const double k = std::min(double(target.width) / double(old.width), double(target.height) / double(old.height));
        report_.placementScale = k;
        for (Track &track : sequence.videoTracks) {
            for (Clip &clip : track.clips) {
                const MediaAsset *asset = project.findAsset(clip.assetId);
                if (asset == nullptr || asset->width <= 0 || asset->height <= 0) {
                    continue;
                }
                double factor = k * fitScale(*asset, old.width, old.height) /
                                fitScale(*asset, target.width, target.height);
                if (std::fabs(factor - 1.0) < 1e-12) {
                    factor = 1.0; // the same aspect ratio: the fitted size scales with the frame
                }
                clip.video.x *= k;
                clip.video.y *= k;
                clip.video.scale *= factor;
                for (EffectSpan &span : clip.spans) {
                    if (span.kind != SpanKind::Motion) {
                        continue;
                    }
                    for (Keyframe &keyframe : span.tracks[SpanParameter::X]) {
                        keyframe.value *= k;
                    }
                    for (Keyframe &keyframe : span.tracks[SpanParameter::Y]) {
                        keyframe.value *= k;
                    }
                }
                ++report_.clipsRescaled;
            }
        }
        const bool sameShape = std::int64_t(old.width) * target.height == std::int64_t(old.height) * target.width;
        char scale[32];
        std::snprintf(scale, sizeof scale, "%.4g", k);
        if (sameShape) {
            sentences.push_back("The frame becomes " + sizeName(target.width, target.height) + " (from " +
                                sizeName(old.width, old.height) + ")" +
                                (report_.clipsRescaled > 0
                                     ? ": positions, sizes and Motion spans are scaled ×" + std::string(scale) +
                                           " with it, so every picture stays the same."
                                     : "."));
        } else {
            sentences.push_back("The frame becomes " + sizeName(target.width, target.height) + " (from " +
                                sizeName(old.width, old.height) + "), another shape: the old frame is fitted inside " +
                                "the new one" +
                                (report_.clipsRescaled > 0
                                     ? " (×" + std::string(scale) + ") and every picture keeps its place and size in "
                                           "it; picture outside the old frame may now show."
                                     : "."));
        }
    }

    // Frame rate: clips, then transitions, on the new grid.
    const CMTime fd = old.frameDuration;
    const CMTime newFd = target.frameDuration;
    const bool rateChanged = !(fd == newFd);
    std::unordered_map<SpanId, TransitionFrames> wanted;
    std::unordered_set<SpanId> dissolves; // cross dissolves (with a partner) before the conform
    bool hasEffectSpans = false;
    if (rateChanged) {
        for (const std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
            for (const Track &track : *list) {
                for (const Clip &clip : track.clips) {
                    hasEffectSpans = hasEffectSpans || clip.hasEffectSpans();
                    for (const TransitionSpan &span : clip.transitions) {
                        TransitionFrames frames;
                        frames.after = roundedFrames(span.end, fd);
                        if (span.edge == ClipEdge::Tail) {
                            frames.before = roundedFrames(negateTime(span.start), fd);
                        }
                        const auto placement = placeTransition(track, clip, span);
                        const bool dissolve = placement && placement->role == TransitionRole::CrossDissolve &&
                                              placement->partner != nullptr;
                        if (frames.before + frames.after == 0) {
                            // A transition shorter than half a frame keeps one: a fade out inside its clip, a
                            // fade in or a cross dissolve after the edge.
                            (span.edge == ClipEdge::Tail && !dissolve ? frames.before : frames.after) = 1;
                        }
                        wanted[span.id] = frames;
                        if (dissolve) {
                            dissolves.insert(span.id);
                        }
                    }
                }
            }
        }
        if (EditResult r = EdgeConform(project, sequence, newFd).run(report_); !r) {
            return r;
        }
    }
    sequence.setFormat(target);

    if (rateChanged) {
        std::optional<std::pair<TransitionFrames, SpanId>> example;
        for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
            for (Track &track : *list) {
                for (Clip &clip : track.clips) {
                    for (TransitionSpan &span : clip.transitions) {
                        setTransitionFrames(span, wanted[span.id], newFd);
                    }
                }
            }
        }
        // One rule (the user's decision on D1 and D2, 2026-10-02): when a fade and a cross dissolve on one
        // clip no longer both fit, the fade gives way and the dissolve keeps its length, as after a trim and
        // in pruning. So the dissolves are fitted first, with every fade set aside, and then the fades in
        // what the dissolves leave (TransitionRules::conformFadeFramesBesideDissolves), each clip's fade in
        // before its fade out. The sentences keep the order of the transitions on their tracks.
        enum class ConformRole { Dissolve, LostPartner, Fade };
        struct ConformedTransition {
            Track *track = nullptr;
            ClipId clip{};
            ClipEdge edge = ClipEdge::Head;
            SpanId span{};
            ConformRole role = ConformRole::Fade;
            std::string name;
            TransitionFrames goal;
            TransitionFrames fitted;
            std::string reason;
            bool skipped = false; // a dissolve the limits do not understand: validation decides
        };
        std::vector<ConformedTransition> conformed;
        for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
            for (Track &track : *list) {
                for (Clip &clip : track.clips) {
                    for (const ClipEdge edge : {ClipEdge::Head, ClipEdge::Tail}) {
                        const TransitionSpan *span = clip.transitionAt(edge);
                        if (span == nullptr) {
                            continue;
                        }
                        ConformedTransition entry;
                        entry.track = &track;
                        entry.clip = clip.id;
                        entry.edge = edge;
                        entry.span = span->id;
                        entry.name = transitionName(project, track, clip, *span);
                        entry.goal = wanted[span->id];
                        entry.fitted = entry.goal;
                        const auto placement = placeTransition(track, clip, *span);
                        const bool dissolve = placement && placement->role == TransitionRole::CrossDissolve &&
                                              placement->partner != nullptr;
                        entry.role = dissolve                          ? ConformRole::Dissolve
                                     : dissolves.contains(span->id) ? ConformRole::LostPartner
                                                                     : ConformRole::Fade;
                        conformed.push_back(std::move(entry));
                    }
                }
            }
        }
        auto eraseTransition = [](Clip &clip, SpanId id) {
            std::erase_if(clip.transitions, [id](const TransitionSpan &s) { return s.id == id; });
        };
        // The fades, set aside while the dissolves are fitted (index into `conformed`, the span).
        std::vector<std::pair<std::size_t, TransitionSpan>> fades;
        for (std::size_t i = 0; i < conformed.size(); ++i) {
            ConformedTransition &entry = conformed[i];
            Clip &clip = *entry.track->find(entry.clip);
            if (entry.role == ConformRole::Fade) {
                fades.emplace_back(i, *clip.transitionAt(entry.edge));
                eraseTransition(clip, entry.span);
            } else if (entry.role == ConformRole::LostPartner) {
                // The conform keeps touching clips touching, so a cross dissolve keeps its partner; should one
                // ever lose it, it is removed and named, never kept as a fade.
                entry.fitted = TransitionFrames{};
                entry.reason = "the clips no longer meet at a cut.";
                eraseTransition(clip, entry.span);
            }
        }
        for (ConformedTransition &entry : conformed) {
            if (entry.role != ConformRole::Dissolve) {
                continue;
            }
            Clip &clip = *entry.track->find(entry.clip);
            TransitionSpan &span = *clip.transitionAt(entry.edge);
            EditResult why = EditResult::success();
            const auto limits = transitionSideLimits(project, sequence, clip.id, span.id, why);
            if (!limits) {
                entry.skipped = true; // not a transition the limits understand: validation decides
                continue;
            }
            TransitionFrames &fitted = entry.fitted;
            fitted.before = std::min(entry.goal.before, limits->maxBeforeFrames);
            fitted.after = std::min(entry.goal.after, limits->maxAfterFrames);
            entry.reason = fitted.after < entry.goal.after ? limits->afterReason : limits->beforeReason;
            if (fitted.after < 1) {
                fitted = TransitionFrames{};
            }
            if (fitted.before + fitted.after > 0) {
                setTransitionFrames(span, fitted, newFd);
                if (auto issue = checkTransitionSpan(project, *entry.track, clip, span, newFd)) {
                    entry.reason = issue->kind == TransitionIssueKind::NotAdjacent ? "the clips no longer meet at a cut."
                                                                                   : "it is no longer a valid transition.";
                    fitted = TransitionFrames{};
                }
            }
            if (fitted.before + fitted.after == 0) {
                eraseTransition(clip, entry.span);
            }
        }
        for (auto &[index, stashed] : fades) {
            ConformedTransition &entry = conformed[index];
            Clip &clip = *entry.track->find(entry.clip);
            // A clip's transitions keep the head's first; after the dissolves a clip holds at most its tail
            // dissolve, which a fade at its tail cannot be beside.
            if (entry.edge == ClipEdge::Head) {
                clip.transitions.insert(clip.transitions.begin(), stashed);
            } else {
                clip.transitions.push_back(stashed);
            }
            TransitionSpan &span = *clip.transitionAt(entry.edge);
            TransitionFrames &fitted = entry.fitted;
            std::int64_t &frames = entry.edge == ClipEdge::Head ? fitted.after : fitted.before;
            const std::int64_t besideFade = TransitionRules::conformFadeFrames(clip, entry.edge, newFd);
            const std::int64_t room =
                TransitionRules::conformFadeFramesBesideDissolves(*entry.track, clip, entry.edge, newFd);
            if (room < besideFade && room < frames) {
                const char *dissolveName = entry.track->kind == TrackKind::Audio ? "crossfade" : "cross dissolve";
                entry.reason = entry.edge == ClipEdge::Head
                                   ? std::string("it gives way to the ") + dissolveName + " at the clip's end."
                                   : std::string("it gives way to the ") + dissolveName + " coming into the clip.";
            } else {
                entry.reason = "the clip is too short for it at this frame rate, with its other transition.";
            }
            frames = std::min(frames, room);
            std::optional<TransitionIssue> issue;
            if (frames > 0) {
                setTransitionFrames(span, fitted, newFd);
                issue = checkTransitionSpan(project, *entry.track, clip, span, newFd);
            }
            if (frames > 0 && issue) {
                entry.reason = issue->kind == TransitionIssueKind::Touching ? "another clip now touches the clip's start."
                                                                            : "it is no longer a valid transition.";
                frames = 0;
            }
            if (fitted.before + fitted.after == 0) {
                fitted = TransitionFrames{};
                eraseTransition(clip, entry.span);
            } else {
                setTransitionFrames(span, fitted, newFd);
            }
        }
        for (const ConformedTransition &entry : conformed) {
            if (entry.skipped) {
                continue;
            }
            const std::int64_t wantedTotal = entry.goal.before + entry.goal.after;
            const std::int64_t fittedTotal = entry.fitted.before + entry.fitted.after;
            if (fittedTotal == 0) {
                report_.transitionsRemoved.push_back(entry.span);
                std::string sentence =
                    entry.name + " is removed: not one frame of it fits at " + frameRateName(newFd) + " fps";
                sentence += entry.reason.empty() ? "." : " (" + entry.reason.substr(0, entry.reason.size() - 1) + ").";
                sentence[0] = 'T';
                sentences.push_back(sentence);
                markRemovedOnPurpose(entry.span);
                continue;
            }
            if (fittedTotal < wantedTotal) {
                report_.transitionsShortened.push_back(entry.span);
                std::string sentence = entry.name + " is shortened from " + framesName(wantedTotal) + " to " +
                                       framesName(fittedTotal) + ": " + entry.reason;
                sentence[0] = 'T';
                sentences.push_back(sentence);
            } else {
                ++report_.transitionsKept;
                if (!example) {
                    example = std::make_pair(entry.goal, entry.span);
                }
            }
        }
        std::string rate = "The frame rate becomes " + frameRateName(newFd) + " fps (from " + frameRateName(fd) + ")";
        if (report_.clipsRetimed > 0) {
            rate += ": " + countName(report_.clipsRetimed, "clip moves its", "clips move their") +
                    " start or end to the nearest frame, by at most " + secondsName(report_.largestShift) + ".";
        } else if (!sequence.isEmpty()) {
            rate += "; every clip already starts and ends on a frame.";
        } else {
            rate += ".";
        }
        if (report_.clipsMoved > 0) {
            rate += " " + countName(report_.clipsMoved, "clip moves", "clips move") + " earlier with " +
                    (report_.clipsMoved == 1 ? "its" : "their") + " media, by at most " +
                    secondsName(report_.largestMove) +
                    ", to keep touching the clip before: neither side of the cut has media to spare.";
        }
        // The frame-grid sentence goes before the transitions'.
        sentences.insert(sentences.begin() + (target.width != old.width || target.height != old.height ? 1 : 0), rate);
        if (report_.transitionsKept > 0 && example) {
            const std::int64_t frames = example->first.before + example->first.after;
            sentences.push_back(countName(report_.transitionsKept, "transition keeps its", "transitions keep their") +
                                " frame count" + (report_.transitionsKept == 1 ? "" : "s") + ", so " +
                                (report_.transitionsKept == 1 ? "its" : "their") + " length in seconds changes (" +
                                framesName(frames) + ": " + secondsName(timeForFrame(frames, fd)) + " before, " +
                                secondsName(timeForFrame(frames, newFd)) + " now).");
        }
        if (hasEffectSpans) {
            sentences.push_back(effectKindsName() + " spans stay on their pictures (their times do not change).");
        }
    }
    if (target.audioSampleRate != old.audioSampleRate) {
        char rate[64];
        std::snprintf(rate, sizeof rate, "Audio is mixed and exported at %g kHz (from %g kHz).",
                      target.audioSampleRate / 1000.0, old.audioSampleRate / 1000.0);
        sentences.push_back(rate);
    }
    return EditResult::success();
}

EditResult SetSharpenScaledDownSources::apply(Project &project) {
    if (!applied_) {
        before_ = project.sharpenScaledDownSources;
        applied_ = true;
    }
    project.sharpenScaledDownSources = sharpen_;
    return EditResult::success();
}

void SetSharpenScaledDownSources::revert(Project &project) const {
    project.sharpenScaledDownSources = before_;
}

bool SetSharpenScaledDownSources::canRevert(const Project &project) const {
    return applied_ && project.sharpenScaledDownSources == sharpen_;
}

bool SetSharpenScaledDownSources::isNoOp() const {
    return applied_ && before_ == sharpen_;
}

} // namespace ve
