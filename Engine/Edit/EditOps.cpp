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

EditResult checkAudioParams(const AudioParams &a, CMTime clipDuration) {
    if (!std::isfinite(a.gainDb)) {
        return EditResult::failure(EditError::InvalidArgument, "gain must be finite");
    }
    for (const CMTime fade : {a.fadeInDuration, a.fadeOutDuration}) {
        if (EditResult r = requireExact(fade, "fade duration"); !r) {
            return r;
        }
        if (fade < kCMTimeZero) {
            return EditResult::failure(EditError::InvalidTime, "fade durations must be >= 0");
        }
        if (fade > clipDuration) {
            return EditResult::failure(EditError::InvalidTime, "fade " + describe(fade) + " is longer than the clip (" +
                                                                   describe(clipDuration) + ")");
        }
    }
    const auto fadeIn = ExactTime::from(a.fadeInDuration);
    const auto fadeOut = ExactTime::from(a.fadeOutDuration);
    const auto total = fadeIn && fadeOut ? fadeIn->plus(*fadeOut) : std::nullopt;
    if (!total || total->compare(clipDuration) > 0) {
        return EditResult::failure(EditError::InvalidTime, "the fade-in and fade-out overlap: together they are longer "
                                                           "than the clip (" +
                                                               describe(clipDuration) + ")");
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
    if (EditResult r = checkAudioParams(clip.audio, clip.duration()); !r) {
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
    case TransitionIssueKind::TooLong:
    case TransitionIssueKind::BadDuration:
    case TransitionIssueKind::Structure:
        break;
    }
    return EditResult::failure(EditError::InvalidArgument, issue.message);
}

// Full placement check for a new or resized transition (ignoring `ignore` when looking for
// neighbouring transitions).
EditResult checkTransitionPlacement(const Sequence &sequence, const Project &project, const Transition &transition,
                                    TransitionId ignore) {
    if (auto issue = checkTransition(sequence, project, transition)) {
        return transitionIssueToResult(*issue);
    }
    const TimeRange range = *sequence.transitionRange(transition);
    for (const Transition &other : sequence.transitions) {
        if (other.id == ignore || other.id == transition.id) {
            continue;
        }
        const auto otherRange = sequence.transitionRange(other);
        if (!otherRange) {
            continue;
        }
        if (other.toClipId == transition.fromClipId && otherRange->end > range.start) {
            return EditResult::failure(EditError::Overlap, "overlaps the transition at the start of clip " +
                                                               idString(transition.fromClipId.value()));
        }
        if (other.fromClipId == transition.toClipId && range.end > otherRange->start) {
            return EditResult::failure(EditError::Overlap, "overlaps the transition at the end of clip " +
                                                               idString(transition.toClipId.value()));
        }
    }
    return EditResult::success();
}

EditResult snapDuration(const Sequence &sequence, CMTime requested, CMTime &out) {
    if (EditResult r = requireNumeric(requested, "duration"); !r) {
        return r;
    }
    out = snapToSequence(sequence, requested);
    if (out < sequence.frameDuration) {
        return EditResult::failure(EditError::InvalidArgument, "duration must be at least one frame");
    }
    return EditResult::success();
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
        if (!clip.setTimelineStartKeepingEnd(newStart)) {
            return notRepresentable(clip.id, newStart);
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
        if (!clip.setTimelineEnd(newEnd)) {
            return notRepresentable(clip.id, newEnd);
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
    if (!options_.allowBreakingTransitions) {
        for (const Transition &transition : sequence.transitions) {
            const bool onSplitClip =
                std::find(splitting.begin(), splitting.end(), transition.fromClipId) != splitting.end() ||
                std::find(splitting.begin(), splitting.end(), transition.toClipId) != splitting.end();
            const auto range = sequence.transitionRange(transition);
            if (onSplitClip && range && range->start < at && at < range->end) {
                return EditResult::failure(EditError::InsideTransition,
                                           "split time " + describe(at) + " is inside transition " +
                                               idString(transition.id.value()) + " (" + describe(range->start) +
                                               " - " + describe(range->end) + "); remove or shorten it first");
            }
        }
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

SetVideoParams::SetVideoParams(SequenceId sequenceId, ClipId clipId, VideoParams params)
    : SequenceCommand(sequenceId), clipId_(clipId), params_(params) {
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
    if (EditResult r = checkAudioParams(params_, clip->duration()); !r) {
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
    const bool audio = std::any_of(changes_.begin(), changes_.end(), [](const auto &c) { return c.audio.has_value(); });
    if (video && !audio) {
        return "Change Video Settings";
    }
    if (audio && !video) {
        return "Change Audio Settings";
    }
    return "Change Clip Settings";
}

EditResult SetClipsParams::perform(const Project &, Sequence &sequence, IdGenerator &) {
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
        if (change.audio) {
            if (track->kind != TrackKind::Audio) {
                return EditResult::failure(EditError::TrackKindMismatch,
                                           "clip " + idString(change.clipId.value()) + " is not on an audio track");
            }
            if (EditResult r = checkAudioParams(*change.audio, clip->duration()); !r) {
                return r;
            }
            clip->audio = *change.audio;
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
        clip.fitFades(ClipEdge::Tail);
    }
    if (rippling && delta < kCMTimeZero) {
        return closeTime(sequence, rippled, {TimeRange{changes.front().newEnd, oldEnd}});
    }
    return EditResult::success();
}

// ----- Keyframed Motion -----

namespace {

std::string motionKey(const char *op, ClipId clipId, MotionParameter parameter) {
    return std::string(op) + ":" + idString(clipId.value()) + ":" + nameOf(parameter);
}

// The clip, on an editable video track.
EditResult findMotionClip(Sequence &sequence, ClipId clipId, Clip *&clip) {
    Track *track = nullptr;
    if (EditResult r = findEditableClip(sequence, clipId, track, clip); !r) {
        return r;
    }
    if (track->kind != TrackKind::Video) {
        return EditResult::failure(EditError::TrackKindMismatch,
                                   "clip " + idString(clipId.value()) + " is on an audio track, which has no Motion");
    }
    return EditResult::success();
}

EditResult checkMotionValue(MotionParameter parameter, double value) {
    if (!isValidMotionValue(parameter, value)) {
        return EditResult::failure(EditError::InvalidArgument,
                                   std::string(displayNameOf(parameter)) + " cannot be " + std::to_string(value) +
                                       (parameter == MotionParameter::Opacity ? " (it is within 0...1)"
                                        : parameter == MotionParameter::Scale ? " (it is at least 0)"
                                                                              : " (it must be finite)"));
    }
    return EditResult::success();
}

// Refusal unless `time` lies within the clip's used source range [in, out] (inclusive: a split
// leaves a keyframe on a piece's out point).
EditResult requireInsideClip(const Clip &clip, CMTime time) {
    if (EditResult r = requireExact(time, "keyframe time"); !r) {
        return r;
    }
    const auto in = ExactTime::from(clip.isStill ? kCMTimeZero : clip.sourceIn);
    const auto out = clip.exactSourceOut();
    if (!in || !out) {
        return notRepresentable(clip.id, clip.timelineStart);
    }
    if (in->compare(time) > 0 || out->compare(time) < 0) {
        return EditResult::failure(EditError::InvalidTime, "keyframe time " + describe(time) +
                                                               " is outside the clip's source range (" +
                                                               describe(in->toTimeRounded()) + " - " +
                                                               describe(out->toTimeRounded()) + ")");
    }
    return EditResult::success();
}

EditResult keyframeNotFound(ClipId clipId, MotionParameter parameter, CMTime time) {
    return EditResult::failure(EditError::KeyframeNotFound, std::string(displayNameOf(parameter)) +
                                                                " of clip " + idString(clipId.value()) +
                                                                " has no keyframe at " + describe(time));
}

EditResult checkInterpolation(KeyframeInterpolation interpolation) {
    if (interpolation == KeyframeInterpolation::Bezier) {
        return EditResult::failure(EditError::InvalidArgument,
                                   "a custom curve comes only from dividing an eased segment (a split, or a keyframe "
                                   "added inside it); choose hold, linear or an ease");
    }
    return EditResult::success();
}

// Refusal when the keyframe `insertKeyframeKeepingValues` added at `time` has a value outside the
// parameter's range: a custom curve from a project file overshoots there, and a keyframe with the
// limited value would change the frames around it.
EditResult checkInsertedValue(MotionParameter parameter, const Keyframe &keyframe) {
    if (isValidMotionValue(parameter, keyframe.value)) {
        return EditResult::success();
    }
    return EditResult::failure(EditError::InvalidArgument,
                               std::string(displayNameOf(parameter)) + "'s custom timing curve goes outside its range at " +
                                   describe(keyframe.time) +
                                   ", so a keyframe there would change the picture; set a value there instead");
}

// Sets `value` on the frame starting at `frame` of `parameter` (an animated parameter of `clip`):
// the keyframe goes on the frame's start `time` (keyframeTimeForFrame), where the frame's picture is
// evaluated, so the frame shows exactly `value`. It is added without reshaping the segment it lands
// in (insertKeyframeKeepingValues: a hold stays a hold, an eased segment is divided exactly) and
// then given the value. Other keyframes the frame shows (keyframeIndexForFrame's rule: one on the
// out point, or inside a frame of a sped-up clip) give way to it, and it takes the interpolation and
// curve of the last of them, whose segment is the one leaving the frame.
KeyframeTrack trackWithValueOnFrame(const Clip &clip, CMTime frameDuration, CMTime frame, CMTime time,
                                    MotionParameter parameter, double value) {
    KeyframeTrack track = clip.video.keyframes.track(parameter);
    insertKeyframeKeepingValues(track, clip.video.staticValue(parameter), time);
    std::optional<Keyframe> lender;
    KeyframeTrack kept;
    kept.reserve(track.size());
    for (const Keyframe &keyframe : track) {
        if (!(keyframe.time == time)) {
            const std::optional<CMTime> shownBy = frameShowingSourceTime(clip, keyframe.time, frameDuration);
            if (shownBy && *shownBy == frame) {
                lender = keyframe; // in time order: the last one wins
                continue;
            }
        }
        kept.push_back(keyframe);
    }
    Keyframe &target = kept[*keyframeIndexAt(kept, time)];
    target.value = value;
    if (lender) {
        target.interpolation = lender->interpolation;
        target.curve = lender->curve;
    }
    return kept;
}

} // namespace

AddKeyframe::AddKeyframe(SequenceId sequenceId, ClipId clipId, MotionParameter parameter, CMTime time,
                         std::optional<double> value, std::optional<KeyframeInterpolation> interpolation)
    : SequenceCommand(sequenceId), clipId_(clipId), parameter_(parameter), time_(time), value_(value),
      interpolation_(interpolation) {
    setCoalescingKey(motionKey("addKeyframe", clipId, parameter));
}

EditResult AddKeyframe::perform(const Project &, Sequence &sequence, IdGenerator &) {
    Clip *clip = nullptr;
    if (EditResult r = findMotionClip(sequence, clipId_, clip); !r) {
        return r;
    }
    if (EditResult r = requireInsideClip(*clip, time_); !r) {
        return r;
    }
    if (interpolation_) {
        if (EditResult r = checkInterpolation(*interpolation_); !r) {
            return r;
        }
    }
    KeyframeTrack &track = clip->video.keyframes.track(parameter_);
    if (keyframeIndexAt(track, time_)) {
        return EditResult::failure(EditError::AlreadyExists, std::string(displayNameOf(parameter_)) +
                                                                 " already has a keyframe at " + describe(time_));
    }
    if (value_) {
        if (EditResult r = checkMotionValue(parameter_, *value_); !r) {
            return r;
        }
    }
    // Added without reshaping the segment it lands in, then given what was asked for.
    KeyframeTrack updated = track;
    Keyframe &keyframe = updated[insertKeyframeKeepingValues(updated, clip->video.staticValue(parameter_), time_)];
    if (value_) {
        keyframe.value = *value_;
    } else if (EditResult r = checkInsertedValue(parameter_, keyframe); !r) {
        return r;
    }
    if (interpolation_) {
        keyframe.interpolation = *interpolation_;
        keyframe.curve = TimingCurve{};
    }
    track = std::move(updated);
    return EditResult::success();
}

SetMotionValue::SetMotionValue(SequenceId sequenceId, ClipId clipId, MotionParameter parameter,
                               std::optional<CMTime> keyframeTime, double value,
                               std::optional<KeyframeInterpolation> interpolation)
    : SequenceCommand(sequenceId), clipId_(clipId), parameter_(parameter), keyframeTime_(keyframeTime), value_(value),
      interpolation_(interpolation) {
    setCoalescingKey(motionKey("motionValue", clipId, parameter));
}

std::string SetMotionValue::name() const {
    if (!keyframeTime_) {
        return "Change Video Settings";
    }
    return added_ ? "Add Keyframe" : "Change Keyframe";
}

EditResult SetMotionValue::perform(const Project &, Sequence &sequence, IdGenerator &) {
    Clip *clip = nullptr;
    if (EditResult r = findMotionClip(sequence, clipId_, clip); !r) {
        return r;
    }
    if (EditResult r = checkMotionValue(parameter_, value_); !r) {
        return r;
    }
    if (!keyframeTime_) {
        clip->video.setStaticValue(parameter_, value_);
        return EditResult::success();
    }
    if (interpolation_) {
        if (EditResult r = checkInterpolation(*interpolation_); !r) {
            return r;
        }
    }
    KeyframeTrack &track = clip->video.keyframes.track(parameter_);
    if (const auto index = keyframeIndexAt(track, *keyframeTime_)) {
        Keyframe &keyframe = track[*index];
        keyframe.value = value_;
        if (interpolation_) {
            keyframe.interpolation = *interpolation_;
            keyframe.curve = TimingCurve{};
        }
        added_ = false;
        return EditResult::success();
    }
    if (EditResult r = requireInsideClip(*clip, *keyframeTime_); !r) {
        return r;
    }
    // Added without reshaping the segment it lands in (a hold stays a hold, an eased segment is
    // divided exactly), then given the value and, when asked for, the interpolation.
    Keyframe &keyframe = track[insertKeyframeKeepingValues(track, clip->video.staticValue(parameter_), *keyframeTime_)];
    keyframe.value = value_;
    if (interpolation_) {
        keyframe.interpolation = *interpolation_;
        keyframe.curve = TimingCurve{};
    }
    added_ = true;
    return EditResult::success();
}

RemoveKeyframe::RemoveKeyframe(SequenceId sequenceId, ClipId clipId, MotionParameter parameter, CMTime time)
    : SequenceCommand(sequenceId), clipId_(clipId), parameter_(parameter), time_(time) {
    setCoalescingKey(motionKey("removeKeyframe", clipId, parameter));
}

EditResult RemoveKeyframe::perform(const Project &, Sequence &sequence, IdGenerator &) {
    Clip *clip = nullptr;
    if (EditResult r = findMotionClip(sequence, clipId_, clip); !r) {
        return r;
    }
    KeyframeTrack &track = clip->video.keyframes.track(parameter_);
    const auto index = isNumeric(time_) ? keyframeIndexAt(track, time_) : std::nullopt;
    if (!index) {
        return keyframeNotFound(clipId_, parameter_, time_);
    }
    if (track.size() == 1) {
        clip->video.setStaticValue(parameter_, track.front().value);
    }
    track.erase(track.begin() + static_cast<std::ptrdiff_t>(*index));
    return EditResult::success();
}

MoveKeyframe::MoveKeyframe(SequenceId sequenceId, ClipId clipId, MotionParameter parameter, CMTime from, CMTime to)
    : SequenceCommand(sequenceId), clipId_(clipId), parameter_(parameter), from_(from), to_(to) {
    setCoalescingKey(motionKey("moveKeyframe", clipId, parameter));
}

EditResult MoveKeyframe::perform(const Project &, Sequence &sequence, IdGenerator &) {
    Clip *clip = nullptr;
    if (EditResult r = findMotionClip(sequence, clipId_, clip); !r) {
        return r;
    }
    KeyframeTrack &track = clip->video.keyframes.track(parameter_);
    const auto index = isNumeric(from_) ? keyframeIndexAt(track, from_) : std::nullopt;
    if (!index) {
        return keyframeNotFound(clipId_, parameter_, from_);
    }
    if (EditResult r = requireInsideClip(*clip, to_); !r) {
        return r;
    }
    if (to_ == from_) {
        return EditResult::success();
    }
    if (keyframeIndexAt(track, to_)) {
        return EditResult::failure(EditError::AlreadyExists, std::string(displayNameOf(parameter_)) +
                                                                 " already has a keyframe at " + describe(to_));
    }
    Keyframe moved = track[*index];
    moved.time = to_;
    track.erase(track.begin() + static_cast<std::ptrdiff_t>(*index));
    upsertKeyframe(track, moved);
    return EditResult::success();
}

MoveKeyframeGroup::MoveKeyframeGroup(SequenceId sequenceId, ClipId clipId, CMTime fromFrame, CMTime toFrame)
    : SequenceCommand(sequenceId), clipId_(clipId), fromFrame_(fromFrame), toFrame_(toFrame) {
    setCoalescingKey("moveKeyframeGroup:" + idString(clipId.value()));
}

EditResult MoveKeyframeGroup::perform(const Project &, Sequence &sequence, IdGenerator &) {
    Clip *clip = nullptr;
    if (EditResult r = findMotionClip(sequence, clipId_, clip); !r) {
        return r;
    }
    MotionKeyframeGroup group;
    if (EditResult r = motionKeyframeGroupAt(*clip, sequence.frameDuration, fromFrame_, group); !r) {
        return r;
    }
    parameterCount_ = group.keyframes.size();
    std::vector<MotionTrackChange> changes;
    if (EditResult r = planMotionKeyframeGroupMove(*clip, sequence.frameDuration, fromFrame_, toFrame_, changes); !r) {
        return r;
    }
    for (MotionTrackChange &change : changes) {
        clip->video.keyframes.track(change.parameter) = std::move(change.keyframes);
    }
    return EditResult::success();
}

SetKeyframeInterpolation::SetKeyframeInterpolation(SequenceId sequenceId, ClipId clipId, MotionParameter parameter,
                                                   CMTime time, KeyframeInterpolation interpolation)
    : SequenceCommand(sequenceId), clipId_(clipId), parameter_(parameter), time_(time),
      interpolation_(interpolation) {
    setCoalescingKey(motionKey("keyframeInterpolation", clipId, parameter));
}

EditResult SetKeyframeInterpolation::perform(const Project &, Sequence &sequence, IdGenerator &) {
    Clip *clip = nullptr;
    if (EditResult r = findMotionClip(sequence, clipId_, clip); !r) {
        return r;
    }
    if (EditResult r = checkInterpolation(interpolation_); !r) {
        return r;
    }
    KeyframeTrack &track = clip->video.keyframes.track(parameter_);
    const auto index = isNumeric(time_) ? keyframeIndexAt(track, time_) : std::nullopt;
    if (!index) {
        return keyframeNotFound(clipId_, parameter_, time_);
    }
    track[*index].interpolation = interpolation_;
    track[*index].curve = TimingCurve{};
    return EditResult::success();
}

SetMotionTracks::SetMotionTracks(SequenceId sequenceId, ClipId clipId, std::vector<MotionTrackChange> changes,
                                 std::string name)
    : SequenceCommand(sequenceId), clipId_(clipId), changes_(std::move(changes)), name_(std::move(name)) {
    setCoalescingKey("motionTracks:" + idString(clipId.value()));
}

EditResult SetMotionTracks::perform(const Project &, Sequence &sequence, IdGenerator &) {
    if (changes_.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "no parameters to change");
    }
    Clip *clip = nullptr;
    if (EditResult r = findMotionClip(sequence, clipId_, clip); !r) {
        return r;
    }
    std::unordered_set<int> seen;
    for (const MotionTrackChange &change : changes_) {
        if (!seen.insert(static_cast<int>(change.parameter)).second) {
            return EditResult::failure(EditError::InvalidArgument,
                                       std::string(displayNameOf(change.parameter)) + " is listed twice");
        }
        if (EditResult r = checkMotionValue(change.parameter, change.staticValue); !r) {
            return r;
        }
        if (auto problem = keyframeTrackProblem(change.keyframes, change.parameter)) {
            return EditResult::failure(EditError::InvalidArgument, *problem);
        }
        const KeyframeTrack &current = clip->video.keyframes.track(change.parameter);
        for (const Keyframe &keyframe : change.keyframes) {
            if (EditResult r = requireInsideClip(*clip, keyframe.time); !r) {
                // A keyframe a trim hid may stay where it is (a partial Ken Burns move keeps it).
                if (std::find(current.begin(), current.end(), keyframe) == current.end()) {
                    return r;
                }
            }
        }
        clip->video.keyframes.track(change.parameter) = change.keyframes;
        clip->video.setStaticValue(change.parameter, change.staticValue);
    }
    return EditResult::success();
}

// ----- Ken Burns moves and matching a neighbour's framing -----

bool motionValuesMatch(MotionParameter, double a, double b) {
    if (!std::isfinite(a) || !std::isfinite(b)) {
        return a == b;
    }
    const double magnitude = std::max({1.0, std::abs(a), std::abs(b)});
    return std::abs(a - b) <= 1e-6 * magnitude;
}

namespace {

// Refusal unless `frame` is the start of one of the clip's sequence frames.
EditResult requireClipFrame(const Clip &clip, CMTime frameDuration, CMTime frame, const char *what) {
    if (!isPositive(frameDuration) || !isNumeric(frame) || !isOnFrameGrid(frame, frameDuration)) {
        return EditResult::failure(EditError::InvalidTime, std::string(what) + " " + describe(frame) +
                                                               " is not the start of a sequence frame");
    }
    if (frame < clip.timelineStart || frame >= clip.timelineEnd()) {
        return EditResult::failure(EditError::InvalidTime, std::string(what) + " " + describe(frame) +
                                                               " is not a frame of clip " +
                                                               idString(clip.id.value()));
    }
    return EditResult::success();
}

// Whether `time` (a keyframe's source time) plays before the clip's start on the timeline.
bool isBeforeClip(const Clip &clip, CMTime time) {
    const auto at = clip.exactTimelineTimeAt(time);
    const auto start = ExactTime::from(clip.timelineStart);
    return at && start && at->compare(*start) < 0;
}

void noteDrift(MotionMoveDrift &drift, MotionParameter parameter, CMTime time, bool earliest) {
    drift.parameters.push_back(parameter);
    if (!isNumeric(drift.keyframeTime) || (earliest ? time < drift.keyframeTime : time > drift.keyframeTime)) {
        drift.keyframeTime = time;
    }
}

} // namespace

EditResult planMotionMove(const Clip &clip, CMTime frameDuration, const MotionMoveRequest &request,
                          MotionMovePlan &plan) {
    plan = MotionMovePlan{};
    if (EditResult r = requireClipFrame(clip, frameDuration, request.firstFrame, "the move's first frame"); !r) {
        return r;
    }
    if (EditResult r = requireClipFrame(clip, frameDuration, request.lastFrame, "the move's last frame"); !r) {
        return r;
    }
    if (!(request.firstFrame < request.lastFrame)) {
        return EditResult::failure(EditError::InvalidTime, "a Ken Burns move needs at least two frames");
    }
    if (EditResult r = checkInterpolation(request.interpolation); !r) {
        return r;
    }
    const std::optional<CMTime> startTime = keyframeTimeForFrame(clip, request.firstFrame);
    const std::optional<CMTime> endTime = keyframeTimeForFrame(clip, request.lastFrame);
    if (!startTime || !endTime) {
        return notRepresentable(clip.id, clip.timelineStart);
    }
    const std::optional<CMTime> clipLastFrame = checkedSubtract(clip.timelineEnd(), frameDuration);
    const bool fromClipStart = request.firstFrame == clip.timelineStart;
    const bool toClipEnd = clipLastFrame && request.lastFrame == *clipLastFrame;

    const std::pair<MotionParameter, std::pair<double, double>> values[] = {
        {MotionParameter::X, {request.start.x, request.end.x}},
        {MotionParameter::Y, {request.start.y, request.end.y}},
        {MotionParameter::Scale, {request.start.scale, request.end.scale}},
    };
    for (const auto &[parameter, pair] : values) {
        if (EditResult r = checkMotionValue(parameter, pair.first); !r) {
            return r;
        }
        if (EditResult r = checkMotionValue(parameter, pair.second); !r) {
            return r;
        }
        MotionTrackChange change;
        change.parameter = parameter;
        change.staticValue = pair.first;
        std::optional<Keyframe> keptBefore; // the kept keyframe nearest before the move
        std::optional<Keyframe> keptAfter;  // the kept keyframe nearest after it
        for (const Keyframe &keyframe : clip.video.keyframes.track(parameter)) {
            const std::optional<CMTime> frame = frameShowingSourceTime(clip, keyframe.time, frameDuration);
            bool before = false;
            if (frame) {
                if (*frame >= request.firstFrame && *frame <= request.lastFrame) {
                    continue; // shown by the move's frames: replaced
                }
                before = *frame < request.firstFrame;
            } else {
                // Hidden by a trim: replaced when the move reaches that end of the clip.
                before = isBeforeClip(clip, keyframe.time);
                if (before ? fromClipStart : toClipEnd) {
                    continue;
                }
            }
            change.keyframes.push_back(keyframe);
            if (before) {
                keptBefore = keyframe; // the track is in time order: the last one is the nearest
            } else if (!keptAfter) {
                keptAfter = keyframe;
            }
        }
        Keyframe from;
        from.time = *startTime;
        from.value = pair.first;
        from.interpolation = request.interpolation;
        Keyframe to;
        to.time = *endTime;
        to.value = pair.second;
        to.interpolation = KeyframeInterpolation::Linear;
        upsertKeyframe(change.keyframes, from);
        upsertKeyframe(change.keyframes, to);
        if (auto problem = keyframeTrackProblem(change.keyframes, parameter)) {
            return EditResult::failure(EditError::InvariantViolation, "the Ken Burns move's " +
                                                                          std::string(displayNameOf(parameter)) +
                                                                          " keyframes are invalid: " + *problem);
        }
        if (keptBefore && !motionValuesMatch(parameter, keptBefore->value, pair.first)) {
            noteDrift(plan.before, parameter, keptBefore->time, true);
        }
        if (keptAfter && !motionValuesMatch(parameter, keptAfter->value, pair.second)) {
            noteDrift(plan.after, parameter, keptAfter->time, false);
        }
        plan.changes.push_back(std::move(change));
    }
    return EditResult::success();
}

EditResult planMotionAtFrame(const Clip &clip, CMTime frameDuration, CMTime frame, const VideoParams &values,
                             std::vector<MotionTrackChange> &changes) {
    changes.clear();
    if (EditResult r = requireClipFrame(clip, frameDuration, frame, "the frame"); !r) {
        return r;
    }
    const std::optional<CMTime> time = keyframeTimeForFrame(clip, frame);
    if (!time) {
        return notRepresentable(clip.id, frame);
    }
    for (MotionParameter parameter : kMotionParameters) {
        const double value = values.staticValue(parameter);
        if (EditResult r = checkMotionValue(parameter, value); !r) {
            return r;
        }
        MotionTrackChange change;
        change.parameter = parameter;
        if (!clip.video.isAnimated(parameter)) {
            change.staticValue = value;
            changes.push_back(std::move(change));
            continue;
        }
        change.staticValue = clip.video.staticValue(parameter);
        change.keyframes = trackWithValueOnFrame(clip, frameDuration, frame, *time, parameter, value);
        changes.push_back(std::move(change));
    }
    return EditResult::success();
}

EditResult planMotionValueAtFrame(const Clip &clip, CMTime frameDuration, CMTime frame, MotionParameter parameter,
                                  double value, MotionTrackChange &change) {
    change = MotionTrackChange{};
    change.parameter = parameter;
    if (EditResult r = requireClipFrame(clip, frameDuration, frame, "the frame"); !r) {
        return r;
    }
    if (EditResult r = checkMotionValue(parameter, value); !r) {
        return r;
    }
    if (!clip.video.isAnimated(parameter)) {
        return EditResult::failure(EditError::InvalidArgument,
                                   std::string(displayNameOf(parameter)) + " of clip " + idString(clip.id.value()) +
                                       " is not animated");
    }
    const std::optional<CMTime> time = keyframeTimeForFrame(clip, frame);
    if (!time) {
        return notRepresentable(clip.id, frame);
    }
    change.staticValue = clip.video.staticValue(parameter);
    change.keyframes = trackWithValueOnFrame(clip, frameDuration, frame, *time, parameter, value);
    return EditResult::success();
}

EditResult planMotionKeyframeToggle(const Clip &clip, CMTime frameDuration, CMTime frame, MotionKeyframeToggle &plan) {
    plan = MotionKeyframeToggle{};
    if (EditResult r = requireClipFrame(clip, frameDuration, frame, "the frame"); !r) {
        return r;
    }
    const std::optional<CMTime> time = keyframeTimeForFrame(clip, frame);
    const std::optional<ExactTime> shown = motionTimeAt(clip, frame);
    if (!time || !shown) {
        return notRepresentable(clip.id, frame);
    }
    bool all = true;
    for (MotionParameter parameter : kMotionParameters) {
        if (!keyframeIndexForFrame(clip, parameter, frame, frameDuration)) {
            all = false;
            break;
        }
    }
    plan.removing = all;
    for (MotionParameter parameter : kMotionParameters) {
        const KeyframeTrack &track = clip.video.keyframes.track(parameter);
        MotionTrackChange change;
        change.parameter = parameter;
        change.staticValue = clip.video.staticValue(parameter);
        if (all) {
            // Every keyframe this frame shows goes (a sped-up frame can show several).
            for (const Keyframe &keyframe : track) {
                const std::optional<CMTime> shownBy = frameShowingSourceTime(clip, keyframe.time, frameDuration);
                if (!shownBy || *shownBy != frame) {
                    change.keyframes.push_back(keyframe);
                }
            }
            if (change.keyframes.empty()) {
                change.staticValue = clampMotionValue(parameter, clip.video.valueAt(parameter, *shown));
            }
        } else {
            if (keyframeIndexForFrame(clip, parameter, frame, frameDuration)) {
                continue; // already has one on this frame
            }
            // Added without reshaping the segment it lands in (like AddKeyframe).
            change.keyframes = track;
            const std::size_t index = insertKeyframeKeepingValues(change.keyframes, change.staticValue, *time);
            if (EditResult r = checkInsertedValue(parameter, change.keyframes[index]); !r) {
                return r;
            }
        }
        plan.changes.push_back(std::move(change));
    }
    return EditResult::success();
}

EditResult motionKeyframeGroupAt(const Clip &clip, CMTime frameDuration, CMTime frame, MotionKeyframeGroup &group) {
    group = MotionKeyframeGroup{};
    if (EditResult r = requireClipFrame(clip, frameDuration, frame, "the keyframe's frame"); !r) {
        return r;
    }
    const std::optional<CMTime> lastFrame = checkedSubtract(clip.timelineEnd(), frameDuration);
    if (!lastFrame) {
        return notRepresentable(clip.id, frame);
    }
    CMTime earliest = clip.timelineStart;
    CMTime latest = *lastFrame;
    for (MotionParameter parameter : kMotionParameters) {
        const auto index = keyframeIndexForFrame(clip, parameter, frame, frameDuration);
        if (!index) {
            continue;
        }
        const KeyframeTrack &track = clip.video.keyframes.track(parameter);
        if (*index + 1 < track.size()) {
            const std::optional<CMTime> next = frameShowingSourceTime(clip, track[*index + 1].time, frameDuration);
            if (next && *next == frame) {
                group.crowdedParameter = parameter;
                return EditResult::failure(EditError::InvalidArgument,
                                           std::string(displayNameOf(parameter)) +
                                               " has several keyframes on the frame at " + describe(frame) +
                                               " (the clip plays faster than the sequence): moved to one frame they "
                                               "would meet");
            }
            if (next) {
                const std::optional<CMTime> limit = checkedSubtract(*next, frameDuration);
                if (!limit) {
                    return notRepresentable(clip.id, *next);
                }
                latest = minTime(latest, *limit);
            }
        }
        if (*index > 0) {
            if (const std::optional<CMTime> previous =
                    frameShowingSourceTime(clip, track[*index - 1].time, frameDuration)) {
                const std::optional<CMTime> limit = checkedAdd(*previous, frameDuration);
                if (!limit) {
                    return notRepresentable(clip.id, *previous);
                }
                earliest = maxTime(earliest, *limit);
            }
        }
        group.keyframes.emplace_back(parameter, *index);
    }
    if (group.keyframes.empty()) {
        return EditResult::failure(EditError::KeyframeNotFound, "clip " + idString(clip.id.value()) +
                                                                    " has no keyframe on the frame at " +
                                                                    describe(frame));
    }
    group.earliestFrame = earliest;
    group.latestFrame = latest;
    return EditResult::success();
}

EditResult planMotionKeyframeGroupMove(const Clip &clip, CMTime frameDuration, CMTime fromFrame, CMTime toFrame,
                                       std::vector<MotionTrackChange> &changes) {
    changes.clear();
    MotionKeyframeGroup group;
    if (EditResult r = motionKeyframeGroupAt(clip, frameDuration, fromFrame, group); !r) {
        return r;
    }
    if (!isNumeric(toFrame) || !isOnFrameGrid(toFrame, frameDuration) || toFrame < group.earliestFrame ||
        toFrame > group.latestFrame) {
        return EditResult::failure(EditError::InvalidTime, "the keyframes on the frame at " + describe(fromFrame) +
                                                               " can move to the frames from " +
                                                               describe(group.earliestFrame) + " to " +
                                                               describe(group.latestFrame) + ", not " +
                                                               describe(toFrame));
    }
    if (toFrame == fromFrame) {
        return EditResult::success();
    }
    const std::optional<CMTime> destination = keyframeTimeForFrame(clip, toFrame);
    if (!destination) {
        return notRepresentable(clip.id, toFrame);
    }
    for (const auto &[parameter, index] : group.keyframes) {
        MotionTrackChange change;
        change.parameter = parameter;
        change.staticValue = clip.video.staticValue(parameter);
        change.keyframes = clip.video.keyframes.track(parameter);
        Keyframe moved = change.keyframes[index];
        moved.time = *destination;
        change.keyframes.erase(change.keyframes.begin() + static_cast<std::ptrdiff_t>(index));
        upsertKeyframe(change.keyframes, moved);
        if (auto problem = keyframeTrackProblem(change.keyframes, parameter)) {
            return EditResult::failure(EditError::InvariantViolation,
                                       "moving the " + std::string(displayNameOf(parameter)) +
                                           " keyframe would break its track: " + *problem);
        }
        changes.push_back(std::move(change));
    }
    return EditResult::success();
}

const Clip *adjacentClip(const Sequence &sequence, ClipId clipId, ClipEdge edge) {
    const Track *track = sequence.trackOfClip(clipId);
    const Clip *clip = track != nullptr ? track->find(clipId) : nullptr;
    if (clip == nullptr) {
        return nullptr;
    }
    for (const Clip &other : track->clips) {
        if (other.id == clipId) {
            continue;
        }
        if (edge == ClipEdge::Head ? other.timelineEnd() == clip->timelineStart
                                   : other.timelineStart == clip->timelineEnd()) {
            return &other;
        }
    }
    return nullptr;
}

// ----- Transitions -----

AddTransition::AddTransition(SequenceId sequenceId, ClipId fromClipId, ClipId toClipId, CMTime duration,
                             TransitionKind kind)
    : SequenceCommand(sequenceId), fromClipId_(fromClipId), toClipId_(toClipId), duration_(duration), kind_(kind) {}

EditResult AddTransition::perform(const Project &project, Sequence &sequence, IdGenerator &ids) {
    Track *track = nullptr;
    Clip *from = nullptr;
    if (EditResult r = findEditableClip(sequence, fromClipId_, track, from); !r) {
        return r;
    }
    const Clip *to = track->find(toClipId_);
    if (!to) {
        if (!sequence.findClip(toClipId_)) {
            return EditResult::failure(EditError::ClipNotFound,
                                       "clip " + idString(toClipId_.value()) + " does not exist");
        }
        return EditResult::failure(EditError::InvalidArgument, "transition clips must be on the same track");
    }
    CMTime duration;
    if (EditResult r = snapDuration(sequence, duration_, duration); !r) {
        return r;
    }
    if (from->timelineEnd() != to->timelineStart) {
        return EditResult::failure(EditError::NotAdjacent, "clip " + idString(fromClipId_.value()) +
                                                               " does not end where clip " +
                                                               idString(toClipId_.value()) + " starts");
    }
    if (sequence.transitionFrom(fromClipId_) || sequence.transitionTo(toClipId_)) {
        return EditResult::failure(EditError::AlreadyExists, "there is already a transition on this cut");
    }
    Transition transition;
    transition.id = ids.make<TransitionId>();
    transition.trackId = track->id;
    transition.kind = kind_;
    transition.fromClipId = fromClipId_;
    transition.toClipId = toClipId_;
    transition.duration = duration;
    if (EditResult r = checkTransitionPlacement(sequence, project, transition, TransitionId{}); !r) {
        return r;
    }
    sequence.transitions.push_back(transition);
    created_ = transition.id;
    return EditResult::success();
}

RemoveTransition::RemoveTransition(SequenceId sequenceId, TransitionId transitionId)
    : SequenceCommand(sequenceId), transitionId_(transitionId) {}

EditResult RemoveTransition::perform(const Project &, Sequence &sequence, IdGenerator &) {
    const Transition *transition = sequence.findTransition(transitionId_);
    if (!transition) {
        return EditResult::failure(EditError::TransitionNotFound,
                                   "transition " + idString(transitionId_.value()) + " does not exist");
    }
    if (EditResult r = requireEditableTrack(sequence.findTrack(transition->trackId), transition->trackId); !r) {
        return r;
    }
    std::erase_if(sequence.transitions, [this](const Transition &t) { return t.id == transitionId_; });
    return EditResult::success();
}

SetTransitionDuration::SetTransitionDuration(SequenceId sequenceId, TransitionId transitionId, CMTime duration)
    : SequenceCommand(sequenceId), transitionId_(transitionId), duration_(duration) {
    setCoalescingKey("transitionDuration:" + idString(transitionId.value()));
}

EditResult SetTransitionDuration::perform(const Project &project, Sequence &sequence, IdGenerator &) {
    const Transition *existing = sequence.findTransition(transitionId_);
    if (!existing) {
        return EditResult::failure(EditError::TransitionNotFound,
                                   "transition " + idString(transitionId_.value()) + " does not exist");
    }
    if (EditResult r = requireEditableTrack(sequence.findTrack(existing->trackId), existing->trackId); !r) {
        return r;
    }
    Transition updated = *existing;
    if (EditResult r = snapDuration(sequence, duration_, updated.duration); !r) {
        return r;
    }
    if (EditResult r = checkTransitionPlacement(sequence, project, updated, transitionId_); !r) {
        return r;
    }
    for (Transition &transition : sequence.transitions) {
        if (transition.id == transitionId_) {
            transition = updated;
        }
    }
    return EditResult::success();
}

RemoveTransitions::RemoveTransitions(SequenceId sequenceId, std::vector<TransitionId> transitionIds)
    : SequenceCommand(sequenceId), transitionIds_(std::move(transitionIds)) {}

EditResult RemoveTransitions::perform(const Project &, Sequence &sequence, IdGenerator &) {
    if (transitionIds_.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "no transitions to remove");
    }
    for (const TransitionId id : transitionIds_) {
        const Transition *transition = sequence.findTransition(id);
        if (!transition) {
            return EditResult::failure(EditError::TransitionNotFound,
                                       "transition " + idString(id.value()) + " does not exist");
        }
        if (EditResult r = requireEditableTrack(sequence.findTrack(transition->trackId), transition->trackId); !r) {
            return r;
        }
    }
    std::erase_if(sequence.transitions, [this](const Transition &t) {
        return std::find(transitionIds_.begin(), transitionIds_.end(), t.id) != transitionIds_.end();
    });
    return EditResult::success();
}

SetTransitionDurations::SetTransitionDurations(SequenceId sequenceId, std::vector<Change> changes)
    : SequenceCommand(sequenceId), changes_(std::move(changes)) {
    std::string key = "transitionDurations:";
    for (const Change &change : changes_) {
        key += idString(change.transitionId.value()) + ",";
    }
    setCoalescingKey(key);
}

EditResult SetTransitionDurations::perform(const Project &project, Sequence &sequence, IdGenerator &) {
    if (changes_.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "no transitions to change");
    }
    for (const Change &change : changes_) {
        const Transition *existing = sequence.findTransition(change.transitionId);
        if (!existing) {
            return EditResult::failure(EditError::TransitionNotFound,
                                       "transition " + idString(change.transitionId.value()) + " does not exist");
        }
        if (EditResult r = requireEditableTrack(sequence.findTrack(existing->trackId), existing->trackId); !r) {
            return r;
        }
        Transition updated = *existing;
        if (EditResult r = snapDuration(sequence, change.duration, updated.duration); !r) {
            return r;
        }
        if (EditResult r = checkTransitionPlacement(sequence, project, updated, change.transitionId); !r) {
            return r;
        }
        for (Transition &transition : sequence.transitions) {
            if (transition.id == change.transitionId) {
                transition = updated;
            }
        }
    }
    return EditResult::success();
}

std::optional<TransitionId> linkedTransition(const Sequence &sequence, TransitionId transitionId) {
    const Transition *transition = sequence.findTransition(transitionId);
    if (!transition) {
        return std::nullopt;
    }
    const Clip *from = sequence.findClip(transition->fromClipId);
    const Clip *to = sequence.findClip(transition->toClipId);
    if (!from || !to || !from->linkedClipId || !to->linkedClipId) {
        return std::nullopt;
    }
    const ClipId partnerFrom = *from->linkedClipId;
    const ClipId partnerTo = *to->linkedClipId;
    for (const Transition &candidate : sequence.transitions) {
        if (candidate.id != transitionId && candidate.fromClipId == partnerFrom && candidate.toClipId == partnerTo) {
            return candidate.id;
        }
    }
    return std::nullopt;
}

bool isThroughEdit(const Sequence &sequence, ClipId fromClipId, ClipId toClipId) {
    const Clip *from = sequence.findClip(fromClipId);
    const Clip *to = sequence.findClip(toClipId);
    if (!from || !to || from->assetId != to->assetId || from->trackId != to->trackId ||
        CMTimeCompare(from->timelineEnd(), to->timelineStart) != 0 || from->isStill != to->isStill ||
        !(from->speedRatio() == to->speedRatio()) || !(from->video == to->video) || !(from->audio.gainDb == to->audio.gainDb)) {
        return false;
    }
    if (from->isStill) {
        return true; // a still shows the same picture on both sides
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
    return "\u201C" + name + "\u201D";
}

TransitionLimit noTransition(EditError error, std::string reason) {
    TransitionLimit limit;
    limit.limitError = error;
    limit.reason = std::move(reason);
    return limit;
}

} // namespace

TransitionLimit transitionLimit(const Project &project, SequenceId sequenceId, ClipId fromClipId, ClipId toClipId,
                                TransitionId existing) {
    const Sequence *sequence = project.findSequence(sequenceId);
    if (!sequence || !isPositive(sequence->frameDuration)) {
        return noTransition(EditError::SequenceNotFound, "The sequence no longer exists.");
    }
    const Track *track = sequence->trackOfClip(fromClipId);
    const Clip *from = track ? track->find(fromClipId) : nullptr;
    const Clip *to = track ? track->find(toClipId) : nullptr;
    if (!from || !sequence->findClip(toClipId)) {
        return noTransition(EditError::ClipNotFound, "The clips no longer exist.");
    }
    if (!to || from->timelineEnd() != to->timelineStart || fromClipId == toClipId) {
        return noTransition(EditError::NotAdjacent, "The clips do not meet at a cut on one track.");
    }
    if (track->locked) {
        return noTransition(EditError::TrackLocked, "Track \u201C" + track->name + "\u201D is locked.");
    }
    const Transition *onCut = sequence->transitionFrom(fromClipId);
    if (!onCut) {
        onCut = sequence->transitionTo(toClipId);
    }
    if (onCut && onCut->id != existing) {
        return noTransition(EditError::AlreadyExists, "This cut already has a transition.");
    }
    if (existing && !onCut) {
        return noTransition(EditError::TransitionNotFound, "The transition no longer exists.");
    }

    Transition probe;
    probe.id = existing ? existing : TransitionId(std::numeric_limits<TransitionId::ValueType>::max());
    probe.trackId = track->id;
    probe.fromClipId = fromClipId;
    probe.toClipId = toClipId;
    auto check = [&](std::int64_t frames) {
        probe.duration = timeForFrame(frames, sequence->frameDuration);
        return checkTransitionPlacement(*sequence, project, probe, existing);
    };
    // A centred transition of n frames needs floor(n/2) frames of the outgoing clip and ceil(n/2)
    // of the incoming one, so it can never exceed their combined length.
    const std::int64_t upper = frameIndexAt(from->duration(), sequence->frameDuration, SnapMode::Floor) +
                               frameIndexAt(to->duration(), sequence->frameDuration, SnapMode::Floor);
    std::int64_t lo = 0;         // fits (0: none)
    std::int64_t hi = upper + 1; // refused
    while (hi - lo > 1) {
        const std::int64_t mid = lo + (hi - lo) / 2;
        if (check(mid)) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    TransitionLimit limit;
    limit.maximumFrames = lo;
    limit.maximum = lo > 0 ? timeForFrame(lo, sequence->frameDuration) : kCMTimeZero;
    // Why one frame more is refused.
    probe.duration = timeForFrame(lo + 1, sequence->frameDuration);
    if (auto issue = checkTransition(*sequence, project, probe)) {
        switch (issue->kind) {
        case TransitionIssueKind::InsufficientHandles: {
            limit.limitError = EditError::InsufficientHandles;
            limit.limitingClip = issue->clip;
            const bool outgoing = issue->clip == fromClipId;
            limit.reason = quotedMediaName(project, outgoing ? *from : *to) +
                           (outgoing ? " has no more media after its out point." : " has no more media before its in point.");
            break;
        }
        case TransitionIssueKind::TooLong:
            limit.limitError = EditError::InvalidArgument;
            limit.reason = "A transition cannot be longer than the clips it joins.";
            break;
        case TransitionIssueKind::NotAdjacent:
        case TransitionIssueKind::BadDuration:
        case TransitionIssueKind::Structure:
            limit.limitError = EditError::InvalidArgument;
            limit.reason = "The cut cannot take a longer transition.";
            break;
        }
    } else {
        const EditResult refusal = check(lo + 1);
        limit.limitError = refusal ? EditError::InvalidArgument : refusal.error;
        limit.reason = refusal.error == EditError::Overlap ? "It would overlap the neighbouring transition."
                                                           : "The cut cannot take a longer transition.";
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
    std::vector<Track> &list = sequence.tracks(track->kind);
    std::erase_if(list, [this](const Track &t) { return t.id == trackId_; });
    std::erase_if(sequence.transitions, [this](const Transition &t) { return t.trackId == trackId_; });
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
