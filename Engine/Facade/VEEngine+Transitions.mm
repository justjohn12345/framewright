// VEEngine (Transitions): adding cross dissolves, crossfades and fades, their kinds, limits,
// durations and ranges, with the user-facing explanation of what limits a cut.

#import "VEEngine+Internal.h"

#include "../Edit/TransitionFitting.h"

#include <cstdint>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

using namespace ve;
using namespace ve::facade;

namespace {

/// describeFrames (TransitionFitting.h) for the notes: "12 frames (0.40 s)".
NSString *framesText(int64_t frames, CMTime frameDuration) {
    return toNS(describeFrames(frames, frameDuration));
}

/// The refusal of a transition of `frames` on a cut limited by `limit` (transitionRefusal).
VEEditResult *refuseTransition(const TransitionLimit &limit, int64_t frames, CMTime frameDuration) {
    return [VEEditResult failureWithCode:toVE(refusalError(limit))
                                 message:toNS(transitionRefusal(limit, frames, frameDuration))];
}

/// The refusal of an edit of a transition that no longer exists.
VEEditResult *transitionNotFound() {
    return [VEEditResult failureWithCode:VEEditErrorTransitionNotFound message:@"The transition no longer exists."];
}

/// The engine kind of a VETransitionKind that refuseTransitionKind accepted.
TransitionKind requestedKind(VETransitionKind kind) {
    return fromVE(kind).value_or(TransitionKind::CrossDissolve);
}

} // namespace

@implementation VEEngine (Transitions)

- (VEEditResult *)addTransitionFromClip:(VEClipID)fromClipID toClip:(VEClipID)toClipID duration:(CMTime)duration {
    VE_ASSERT_MAIN();
    return [self addTransitionFromClip:fromClipID toClip:toClipID duration:duration options:VETransitionOptionNone];
}

/// Whole frames of a requested transition duration, or a refusal.
- (nullable VEEditResult *)refuseTransitionDuration:(CMTime)duration frames:(int64_t *)frames {
    const CMTime frameDuration = [self activeSequence].frameDuration;
    if (!CMTIME_IS_NUMERIC(duration)) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidTime message:@"The transition duration is not a valid time."];
    }
    *frames = frameIndexAt(snapToFrame(duration, frameDuration, SnapMode::Round), frameDuration, SnapMode::Round);
    if (*frames < 1) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                     message:@"A transition must be at least one frame long."];
    }
    return nil;
}

- (VEEditResult *)addTransitionFromClip:(VEClipID)fromClipID
                                 toClip:(VEClipID)toClipID
                               duration:(CMTime)duration
                                options:(VETransitionOptions)options {
    VE_ASSERT_MAIN();
    return [self addTransitionFromClip:fromClipID
                                toClip:toClipID
                              duration:duration
                               options:options
                                  kind:VETransitionKindCrossDissolve];
}

/// The refusal of a VETransitionKind value outside the enum (from Swift), or nil.
static VEEditResult *_Nullable refuseTransitionKind(VETransitionKind kind) {
    if (fromVE(kind)) {
        return nil;
    }
    return [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                 message:[NSString stringWithFormat:@"%ld is not a transition kind.", long(kind)]];
}

- (VEEditResult *)addTransitionFromClip:(VEClipID)fromClipID
                                 toClip:(VEClipID)toClipID
                               duration:(CMTime)duration
                                options:(VETransitionOptions)options
                                   kind:(VETransitionKind)kind {
    VE_ASSERT_MAIN();
    if (VEEditResult *refusal = refuseTransitionKind(kind)) {
        return refusal;
    }
    const Sequence &sequence = [self activeSequence];
    const CMTime frameDuration = sequence.frameDuration;
    int64_t frames = 0;
    if (VEEditResult *refusal = [self refuseTransitionDuration:duration frames:&frames]) {
        return refusal;
    }
    const SequenceId sequenceId = [self sequenceId];
    const ClipId from(static_cast<ClipId::ValueType>(fromClipID));
    const ClipId to(static_cast<ClipId::ValueType>(toClipID));
    const TransitionLimit limit = transitionLimit(_project, sequenceId, from, to);
    if (limit.maximumFrames == 0 || (frames > limit.maximumFrames && !(options & VETransitionOptionFitToCut))) {
        return refuseTransition(limit, frames, frameDuration);
    }
    // Each transition is fitted to its own cut: the linked partners' cut never shortens the
    // requested one, nor the other way round.
    const int64_t requested = frames;
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    int64_t mainFrames = requested;
    if (mainFrames > limit.maximumFrames) {
        mainFrames = limit.maximumFrames;
        [notes addObject:[NSString stringWithFormat:@"Shortened to %@: %@", framesText(mainFrames, frameDuration),
                                                    toNS(limit.reason)]];
    }
    std::vector<TransitionSpanRequest> requests;
    auto centred = [&](ClipId owner, int64_t length) {
        const auto [start, end] = centredTransitionOffsets(length, frameDuration);
        TransitionSpanRequest request;
        request.clipId = owner;
        request.edge = ClipEdge::Tail;
        request.start = start;
        request.end = end;
        const Track *ownerTrack = sequence.trackOfClip(owner);
        request.kind = ownerTrack != nullptr ? transitionKindOnTrack(ownerTrack->kind, requestedKind(kind))
                                             : TransitionKind::CrossDissolve;
        return request;
    };
    requests.push_back(centred(from, mainFrames));

    // The linked partners' cut (the audio under a video dissolve).
    if (options & VETransitionOptionIncludeLinked) {
        const Clip *fromClip = sequence.findClip(from);
        const Clip *toClip = sequence.findClip(to);
        if (fromClip && toClip && fromClip->linkedClipId && toClip->linkedClipId) {
            const TransitionLimit linked =
                transitionLimit(_project, sequenceId, *fromClip->linkedClipId, *toClip->linkedClipId);
            if (linked.maximumFrames == 0 ||
                (requested > linked.maximumFrames && !(options & VETransitionOptionFitToCut))) {
                [notes addObject:[NSString stringWithFormat:@"The linked clips got no transition: %@",
                                                            toNS(transitionRefusal(linked, requested, frameDuration))]];
            } else {
                int64_t partnerFrames = requested;
                if (partnerFrames > linked.maximumFrames) {
                    partnerFrames = linked.maximumFrames;
                    [notes addObject:[NSString stringWithFormat:@"The linked clips' transition was shortened to %@: %@",
                                                                framesText(partnerFrames, frameDuration),
                                                                toNS(linked.reason)]];
                }
                requests.push_back(centred(*fromClip->linkedClipId, partnerFrames));
            }
        } else if (fromClip && toClip && (fromClip->linkedClipId || toClip->linkedClipId)) {
            [notes addObject:@"The linked clips do not meet at a cut, so they got no transition."];
        }
    }
    if (isThroughEdit(sequence, from, to)) {
        // A plain split: both sides are the same media, so the transition changes nothing.
        const Track *track = sequence.trackOfClip(from);
        [notes addObject:track != nullptr && track->kind == TrackKind::Audio
                             ? @"Both sides play the same audio here; trim or move one side to hear the crossfade."
                             : kind == VETransitionKindCrossDissolve
                                   ? @"Both sides show the same frames here; trim or move one side to see the dissolve."
                                   : @"Both sides show the same frames here; trim or move one side to see the transition."];
    }
    NSString *note = notes.count > 0 ? [notes componentsJoinedByString:@" "] : nil;
    auto command = std::make_unique<AddTransitionSpans>(sequenceId, std::move(requests));
    AddTransitionSpans *raw = command.get();
    return [self push:std::move(command)
              created:^NSArray<NSNumber *> * {
                  return toNumbers(raw->createdSpanIds());
              }
                 note:note];
}

- (VEEditResult *)addTransitionAtEdge:(VEClipEdge)edge
                               ofClip:(VEClipID)clipID
                             duration:(CMTime)duration
                              options:(VETransitionOptions)options {
    VE_ASSERT_MAIN();
    return [self addTransitionAtEdge:edge
                              ofClip:clipID
                            duration:duration
                             options:options
                                kind:VETransitionKindCrossDissolve];
}

- (VEEditResult *)addTransitionAtEdge:(VEClipEdge)edge
                               ofClip:(VEClipID)clipID
                             duration:(CMTime)duration
                              options:(VETransitionOptions)options
                                 kind:(VETransitionKind)kind {
    VE_ASSERT_MAIN();
    if (VEEditResult *refusal = refuseTransitionKind(kind)) {
        return refusal;
    }
    const Sequence &sequence = [self activeSequence];
    const CMTime frameDuration = sequence.frameDuration;
    const ClipId id(static_cast<ClipId::ValueType>(clipID));
    const Track *track = sequence.trackOfClip(id);
    const Clip *clip = track ? track->find(id) : nullptr;
    if (clip == nullptr) {
        return [VEEditResult failureWithCode:VEEditErrorClipNotFound message:@"The clip no longer exists."];
    }
    const ClipEdge side = edge == VEClipEdgeStart ? ClipEdge::Head : ClipEdge::Tail;
    if (side == ClipEdge::Tail) {
        if (const Clip *next = touchingClip(*track, *clip, ClipEdge::Tail)) {
            return [self addTransitionFromClip:clipID
                                        toClip:static_cast<VEClipID>(next->id.value())
                                      duration:duration
                                       options:options
                                          kind:kind];
        }
    }
    int64_t frames = 0;
    if (VEEditResult *refusal = [self refuseTransitionDuration:duration frames:&frames]) {
        return refusal;
    }
    if (track->locked) {
        return [VEEditResult failureWithCode:VEEditErrorTrackLocked
                                     message:[NSString stringWithFormat:@"Track “%@” is locked.", toNS(track->name)]];
    }
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    std::vector<TransitionSpanRequest> requests;
    // A fade at `side` of `owner` (planFade); nil on success, else why not.
    auto plan = [&](const Clip &owner, const Track &ownerTrack, bool linked) -> NSString * {
        const FadePlan fade = planFade(owner, ownerTrack, side, frames, frameDuration,
                                       (options & VETransitionOptionFitToCut) != 0, requestedKind(kind), linked);
        if (!fade.request) {
            return toNS(fade.refusal);
        }
        if (fade.note) {
            [notes addObject:toNS(*fade.note)];
        }
        requests.push_back(*fade.request);
        return nil;
    };
    if (NSString *refusal = plan(*clip, *track, false)) {
        const bool exists = clip->transitionAt(side) != nullptr;
        return [VEEditResult failureWithCode:exists ? VEEditErrorAlreadyExists : VEEditErrorInvalidArgument message:refusal];
    }
    if ((options & VETransitionOptionIncludeLinked) && clip->linkedClipId) {
        const Track *partnerTrack = sequence.trackOfClip(*clip->linkedClipId);
        const Clip *partner = partnerTrack ? partnerTrack->find(*clip->linkedClipId) : nullptr;
        if (partner != nullptr && partnerTrack->locked) {
            [notes addObject:[NSString stringWithFormat:@"The linked clip got no fade: track “%@” is locked.",
                                                        toNS(partnerTrack->name)]];
        } else if (partner != nullptr && side == ClipEdge::Tail && touchingClip(*partnerTrack, *partner, ClipEdge::Tail)) {
            [notes addObject:@"The linked clip got no fade: another clip touches its end."];
        } else if (partner != nullptr) {
            if (NSString *why = plan(*partner, *partnerTrack, true)) {
                [notes addObject:[NSString stringWithFormat:@"The linked clip got no fade: %@", why]];
            }
        }
    }
    const TransitionKind shape = transitionKindOnTrack(track->kind, requestedKind(kind));
    if (shape == TransitionKind::CrossDissolve) {
        [notes
            insertObject:[NSString stringWithFormat:side == ClipEdge::Head ? @"Fades in from %@." : @"Fades out to %@.",
                                                    @(fadeTargetName(track->kind))]
                 atIndex:0];
    } else {
        [notes insertObject:[NSString stringWithFormat:side == ClipEdge::Head ? @"%@ from black." : @"%@ to black.",
                                                       toNS(displayNameOf(shape))]
                    atIndex:0];
    }
    auto command = std::make_unique<AddTransitionSpans>([self sequenceId], std::move(requests));
    AddTransitionSpans *raw = command.get();
    return [self push:std::move(command)
              created:^NSArray<NSNumber *> * {
                  return toNumbers(raw->createdSpanIds());
              }
                 note:[notes componentsJoinedByString:@" "]];
}

- (VEEditResult *)setKind:(VETransitionKind)kind forTransition:(VETransitionID)transitionID {
    VE_ASSERT_MAIN();
    const std::optional<TransitionKind> engineKind = fromVE(kind);
    if (!engineKind) {
        return refuseTransitionKind(kind);
    }
    return [self push:std::make_unique<SetTransitionKind>([self sequenceId],
                                                          SpanId(static_cast<SpanId::ValueType>(transitionID)), *engineKind)
              created:nil];
}

- (VETransitionLimit *)transitionLimitFromClip:(VEClipID)fromClipID toClip:(VEClipID)toClipID {
    VE_ASSERT_MAIN();
    return makeTransitionLimit(transitionLimit(_project, [self sequenceId],
                                               ClipId(static_cast<ClipId::ValueType>(fromClipID)),
                                               ClipId(static_cast<ClipId::ValueType>(toClipID))));
}

- (VETransitionLimit *)transitionLimitForTransition:(VETransitionID)transitionID {
    VE_ASSERT_MAIN();
    const auto transition = findTransition([self activeSequence], SpanId(static_cast<SpanId::ValueType>(transitionID)));
    if (!transition) {
        TransitionLimit none;
        none.limitError = EditError::TransitionNotFound;
        none.reason = "The transition no longer exists.";
        return makeTransitionLimit(none);
    }
    return makeTransitionLimit(transitionDurationLimit(_project, [self activeSequence], *transition));
}

- (VEEditResult *)removeTransition:(VETransitionID)transitionID {
    VE_ASSERT_MAIN();
    const SpanId id(static_cast<SpanId::ValueType>(transitionID));
    if (!findTransition([self activeSequence], id)) {
        return transitionNotFound();
    }
    return [self push:std::make_unique<RemoveSpans>([self sequenceId], std::vector<SpanId>{id}) created:nil];
}

- (VETransitionID)linkedTransitionForTransition:(VETransitionID)transitionID {
    VE_ASSERT_MAIN();
    const auto partner = linkedTransition([self activeSequence], SpanId(static_cast<SpanId::ValueType>(transitionID)));
    return partner ? static_cast<VETransitionID>(partner->value()) : 0;
}

- (VEEditResult *)removeTransition:(VETransitionID)transitionID includingLinked:(BOOL)includingLinked {
    VE_ASSERT_MAIN();
    const SpanId id(static_cast<SpanId::ValueType>(transitionID));
    const Sequence &sequence = [self activeSequence];
    const auto partner = includingLinked ? linkedTransition(sequence, id) : std::nullopt;
    if (!partner || !findTransition(sequence, id)) {
        return [self removeTransition:transitionID];
    }
    const auto linked = findTransition(sequence, *partner);
    if (linked && linked->track->locked) {
        // The pair's other half is protected: remove the requested one and say why the other stays.
        return [self push:std::make_unique<RemoveSpans>([self sequenceId], std::vector<SpanId>{id})
                  created:nil
                     note:[NSString stringWithFormat:@"The linked transition on %@ was kept: the track is locked.",
                                                     toNS(linked->track->name)]];
    }
    return [self push:std::make_unique<RemoveSpans>([self sequenceId], std::vector<SpanId>{id, *partner}) created:nil];
}

- (VEEditResult *)setDuration:(CMTime)duration
                forTransition:(VETransitionID)transitionID
              includingLinked:(BOOL)includingLinked {
    VE_ASSERT_MAIN();
    const SpanId id(static_cast<SpanId::ValueType>(transitionID));
    const Sequence &sequence = [self activeSequence];
    const auto transition = findTransition(sequence, id);
    if (!transition) {
        return transitionNotFound();
    }
    int64_t frames = 0;
    if (VEEditResult *refusal = [self refuseTransitionDuration:duration frames:&frames]) {
        return refusal;
    }
    const CMTime fd = sequence.frameDuration;
    const TransitionLimit limit = transitionDurationLimit(_project, sequence, *transition);
    if (frames > limit.maximumFrames && isLengthLimit(limit.limitError)) {
        return refuseTransition(limit, frames, fd);
    }
    const auto [start, end] = resizedTransitionOffsets(*transition, frames, fd);
    std::vector<TransitionRangeChange> changes{{id, start, end}};
    NSString *note = nil;
    const auto partner = includingLinked ? linkedTransition(sequence, id) : std::nullopt;
    if (const auto linked = partner ? findTransition(sequence, *partner) : std::nullopt) {
        if (linked->track->locked) {
            note = [NSString stringWithFormat:@"The linked transition on %@ was not changed: the track is locked.",
                                              toNS(linked->track->name)];
        } else {
            // The linked transition gets the same length, fitted to its own cut.
            const TransitionLimit linkedLimit = transitionDurationLimit(_project, sequence, *linked);
            if (linkedLimit.maximumFrames == 0) {
                note = [NSString stringWithFormat:@"The linked transition was not changed: %@", toNS(linkedLimit.reason)];
            } else {
                int64_t linkedFrames = frames;
                if (linkedFrames > linkedLimit.maximumFrames) {
                    linkedFrames = linkedLimit.maximumFrames;
                    note = [NSString stringWithFormat:@"The linked transition was limited to %@: %@",
                                                      framesText(linkedFrames, fd), toNS(linkedLimit.reason)];
                }
                const auto [linkedStart, linkedEnd] = resizedTransitionOffsets(*linked, linkedFrames, fd);
                changes.push_back({*partner, linkedStart, linkedEnd});
            }
        }
    }
    VEEditResult *result = [self push:std::make_unique<SetTransitionRanges>([self sequenceId], std::move(changes), true)
                              created:nil
                                 note:note];
    return [self explainDurationRefusal:result transition:id duration:duration];
}

- (VEEditResult *)setDuration:(CMTime)duration forTransition:(VETransitionID)transitionID {
    VE_ASSERT_MAIN();
    return [self setDuration:duration forTransition:transitionID includingLinked:NO];
}

/// A refused duration change of `id` that is about length gets the user-facing explanation of
/// the cut's limit (as adding one does); anything else is returned as is.
- (VEEditResult *)explainDurationRefusal:(VEEditResult *)result transition:(SpanId)id duration:(CMTime)duration {
    const Sequence &sequence = [self activeSequence];
    const auto transition = findTransition(sequence, id);
    if (result.ok || !transition || !CMTIME_IS_NUMERIC(duration) ||
        !(result.errorCode == VEEditErrorInsufficientHandles || result.errorCode == VEEditErrorInvalidArgument ||
          result.errorCode == VEEditErrorOverlap)) {
        return result;
    }
    const TransitionLimit limit = transitionDurationLimit(_project, sequence, *transition);
    const int64_t frames =
        frameIndexAt(snapToFrame(duration, sequence.frameDuration, SnapMode::Round), sequence.frameDuration,
                     SnapMode::Round);
    if (frames <= limit.maximumFrames) {
        return result; // refused for another reason (e.g. shorter than a frame)
    }
    return [VEEditResult failureWithCode:result.errorCode
                                 message:toNS(transitionRefusal(limit, frames, sequence.frameDuration))];
}

/// The offsets of `transition` covering the timeline frames `range` (fitTransitionRange), its notes
/// added to `notes`. Nil when nothing fits (`refusal` set).
- (std::optional<std::pair<CMTime, CMTime>>)offsetsFor:(const TransitionPlacement &)transition
                                                 range:(TimeRange)range
                                                linked:(BOOL)linked
                                                 notes:(NSMutableArray<NSString *> *)notes
                                               refusal:(VEEditResult **)refusal {
    const TransitionRangeFit fit = fitTransitionRange(_project, [self activeSequence], transition, range, linked);
    for (const std::string &note : fit.notes) {
        [notes addObject:toNS(note)];
    }
    if (!fit.offsets) {
        *refusal = toVE(fit.refusal);
    }
    return fit.offsets;
}

- (VEEditResult *)setRangeOfTransition:(VETransitionID)transitionID
                                 range:(CMTimeRange)range
                       includingLinked:(BOOL)includingLinked {
    VE_ASSERT_MAIN();
    const SpanId id(static_cast<SpanId::ValueType>(transitionID));
    const Sequence &sequence = [self activeSequence];
    const auto transition = findTransition(sequence, id);
    if (!transition) {
        return transitionNotFound();
    }
    const auto ends = numericRange(range);
    if (!ends) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidTime message:@"The range is not a valid time range."];
    }
    const CMTime fd = sequence.frameDuration;
    const TimeRange frames{snapToFrame(ends->start, fd, SnapMode::Round), snapToFrame(ends->end, fd, SnapMode::Round)};
    if (!(frames.start < frames.end)) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidTime message:@"A transition covers at least one frame."];
    }
    if (transition->track->locked) {
        return [VEEditResult failureWithCode:VEEditErrorTrackLocked
                                     message:[NSString stringWithFormat:@"Track “%@” is locked.",
                                                                        toNS(transition->track->name)]];
    }
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    VEEditResult *refusal = nil;
    const auto offsets = [self offsetsFor:*transition range:frames linked:NO notes:notes refusal:&refusal];
    if (!offsets) {
        return refusal;
    }
    std::vector<TransitionRangeChange> changes{{id, offsets->first, offsets->second}};
    const auto partner = includingLinked ? linkedTransition(sequence, id) : std::nullopt;
    if (const auto linked = partner ? findTransition(sequence, *partner) : std::nullopt) {
        if (linked->track->locked) {
            [notes addObject:[NSString stringWithFormat:@"The linked transition on %@ was not changed: the track is locked.",
                                                        toNS(linked->track->name)]];
        } else {
            // The same range relative to its own cut.
            const CMTime shift = linked->cut - transition->cut;
            const TimeRange moved{frames.start + shift, frames.end + shift};
            VEEditResult *linkedRefusal = nil;
            if (const auto linkedOffsets = [self offsetsFor:*linked range:moved linked:YES notes:notes refusal:&linkedRefusal]) {
                changes.push_back({*partner, linkedOffsets->first, linkedOffsets->second});
            } else {
                [notes addObject:[NSString stringWithFormat:@"The linked transition was not changed: %@", linkedRefusal.message]];
            }
        }
    }
    NSString *note = notes.count > 0 ? [notes componentsJoinedByString:@" "] : nil;
    return [self push:std::make_unique<SetTransitionRanges>([self sequenceId], std::move(changes)) created:nil note:note];
}

@end
