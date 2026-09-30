// VEEngine (Transitions): adding cross dissolves, crossfades and fades, their kinds, limits,
// durations and ranges, with the user-facing explanation of what limits a cut.

#import "VEEngine+Internal.h"

#include <algorithm>
#include <cstdint>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

using namespace ve;
using namespace ve::facade;

namespace {

/// "12 frames (0.40 s)".
NSString *describeFrames(int64_t frames, CMTime frameDuration) {
    const double seconds = static_cast<double>(frames) * CMTimeGetSeconds(frameDuration);
    return [NSString stringWithFormat:@"%lld %@ (%.2f s)", (long long)frames, frames == 1 ? @"frame" : @"frames", seconds];
}

/// Whether a transition refusal is about length (media, clip length, neighbours) rather than
/// structure (missing clips, no cut, locked track, a transition already there).
bool isLengthLimit(EditError error) {
    return error == EditError::InsufficientHandles || error == EditError::InvalidArgument ||
           error == EditError::Overlap;
}

/// The user-facing refusal of a transition of `frames` on a cut limited by `limit`.
NSString *transitionRefusal(const TransitionLimit &limit, int64_t frames, CMTime frameDuration) {
    NSString *reason = toNS(limit.reason);
    if (limit.maximumFrames == 0) {
        return isLengthLimit(limit.limitError) ? [NSString stringWithFormat:@"No transition fits this cut: %@", reason]
                                               : reason;
    }
    return [NSString stringWithFormat:@"A transition of %@ does not fit this cut: %@ The longest it allows is %@.",
                                      describeFrames(frames, frameDuration), reason,
                                      describeFrames(limit.maximumFrames, frameDuration)];
}

VEEditErrorCode refusalCode(const TransitionLimit &limit) {
    return limit.limitError == EditError::None ? VEEditErrorInvalidArgument : ve::facade::toVE(limit.limitError);
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

/// The kind a transition on `track` gets for the requested `kind`: audio transitions have none.
static TransitionKind transitionKindOn(const Track &track, VETransitionKind kind) {
    return track.kind == TrackKind::Video ? fromVE(kind).value_or(TransitionKind::CrossDissolve)
                                          : TransitionKind::CrossDissolve;
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
        return [VEEditResult failureWithCode:refusalCode(limit)
                                     message:transitionRefusal(limit, frames, frameDuration)];
    }
    // Each transition is fitted to its own cut: the linked partners' cut never shortens the
    // requested one, nor the other way round.
    const int64_t requested = frames;
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    int64_t mainFrames = requested;
    if (mainFrames > limit.maximumFrames) {
        mainFrames = limit.maximumFrames;
        [notes addObject:[NSString stringWithFormat:@"Shortened to %@: %@", describeFrames(mainFrames, frameDuration),
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
        request.kind = ownerTrack != nullptr ? transitionKindOn(*ownerTrack, kind) : TransitionKind::CrossDissolve;
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
                                                            transitionRefusal(linked, requested, frameDuration)]];
            } else {
                int64_t partnerFrames = requested;
                if (partnerFrames > linked.maximumFrames) {
                    partnerFrames = linked.maximumFrames;
                    [notes addObject:[NSString stringWithFormat:@"The linked clips' transition was shortened to %@: %@",
                                                                describeFrames(partnerFrames, frameDuration),
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

/// "black" for a video track, "silence" for an audio track.
static NSString *fadeTarget(const Track &track) {
    return track.kind == TrackKind::Video ? @"black" : @"silence";
}

/// The longest fade (whole frames) `clip` (of `track`) takes at `edge`: its length less its other
/// lane-0 span's part inside it and, for a fade out, less the part inside it of a cross dissolve
/// coming into it; and why not longer.
static int64_t fadeLimitFrames(const Clip &clip, const Track &track, ClipEdge edge, CMTime frameDuration,
                               NSString **reason, EditError *error) {
    CMTime taken = kCMTimeZero;
    CMTime incoming = kCMTimeZero;
    if (edge == ClipEdge::Head) {
        if (const EffectSpan *tail = clip.transitionAt(ClipEdge::Tail)) {
            taken = -tail->start;
        }
    } else {
        taken = clipFadeLength(clip, ClipEdge::Head);
        incoming = incomingTransitionInside(track, clip);
    }
    const CMTime room = clip.timelineDuration - taken - incoming;
    if (kCMTimeZero < incoming) {
        *reason = track.kind == TrackKind::Audio ? @"It would meet the crossfade coming into the clip."
                                                 : @"It would meet the cross dissolve coming into the clip.";
        *error = EditError::Overlap;
    } else {
        *reason = taken == kCMTimeZero ? @"A fade cannot be longer than its clip."
                                       : @"It would overlap the transition at the clip's other end.";
        *error = taken == kCMTimeZero ? EditError::InvalidArgument : EditError::Overlap;
    }
    return std::max<int64_t>(0, frameIndexAt(room, frameDuration, SnapMode::Floor));
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
    // A fade of `length` frames at `side` of `owner`, fitted when allowed; nil on success.
    auto plan = [&](const Clip &owner, const Track &ownerTrack, bool linked) -> NSString * {
        if (owner.transitionAt(side) != nullptr) {
            return side == ClipEdge::Head ? @"The clip already has a transition at its start."
                                          : @"The clip already has a transition at its end.";
        }
        if (side == ClipEdge::Head && touchingClip(ownerTrack, owner, ClipEdge::Head) != nullptr) {
            return @"Another clip touches the clip's start, so the cut belongs to that clip: add a transition at its "
                   @"end instead.";
        }
        NSString *reason = nil;
        EditError error = EditError::None;
        const int64_t limitFrames = fadeLimitFrames(owner, ownerTrack, side, frameDuration, &reason, &error);
        int64_t length = frames;
        if (length > limitFrames) {
            if (!(options & VETransitionOptionFitToCut) || limitFrames == 0) {
                return [NSString stringWithFormat:@"A fade of %@ does not fit: %@ The longest it allows is %@.",
                                                  describeFrames(frames, frameDuration), reason,
                                                  describeFrames(limitFrames, frameDuration)];
            }
            length = limitFrames;
            [notes addObject:[NSString stringWithFormat:@"%@shortened to %@: %@", linked ? @"The linked clip's fade was "
                                                                                          : @"Shortened to ",
                                                        describeFrames(length, frameDuration), reason]];
        }
        TransitionSpanRequest request;
        request.clipId = owner.id;
        request.edge = side;
        request.kind = transitionKindOn(ownerTrack, kind);
        const CMTime fade = timeForFrame(length, frameDuration);
        request.start = side == ClipEdge::Head ? kCMTimeZero : -fade;
        request.end = side == ClipEdge::Head ? fade : kCMTimeZero;
        requests.push_back(request);
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
    const TransitionKind shape = transitionKindOn(*track, kind);
    if (shape == TransitionKind::CrossDissolve) {
        [notes insertObject:[NSString stringWithFormat:side == ClipEdge::Head ? @"Fades in from %@." : @"Fades out to %@.",
                                                       fadeTarget(*track)]
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

/// The offsets a transition of `frames` gets from setDuration: a centred cross dissolve stays
/// centred, an uneven one keeps its share before the cut in proportion (rounded down), a fade keeps
/// its edge.
static std::pair<CMTime, CMTime> resizedOffsets(const TransitionPlacement &transition, int64_t frames, CMTime fd) {
    if (transition.role == TransitionRole::FadeIn) {
        return {kCMTimeZero, timeForFrame(frames, fd)};
    }
    if (transition.role == TransitionRole::FadeOut) {
        return {-timeForFrame(frames, fd), kCMTimeZero};
    }
    const int64_t before = frameIndexAt(transition.cut - transition.range.start, fd, SnapMode::Round);
    const int64_t total = frameIndexAt(transition.range.duration(), fd, SnapMode::Round);
    int64_t newBefore = frames / 2;
    if (total > 0 && before != total / 2) {
        newBefore = static_cast<int64_t>((static_cast<Int128>(frames) * before) / total);
    }
    return {-timeForFrame(newBefore, fd), timeForFrame(frames - newBefore, fd)};
}

/// The longest duration `transition` can be given by setDuration (resizedOffsets), and why not longer.
- (TransitionLimit)durationLimitFor:(const TransitionPlacement &)transition {
    const CMTime fd = [self activeSequence].frameDuration;
    TransitionLimit limit;
    if (transition.role != TransitionRole::CrossDissolve) {
        NSString *reason = nil;
        EditError error = EditError::None;
        const ClipEdge edge = transition.role == TransitionRole::FadeIn ? ClipEdge::Head : ClipEdge::Tail;
        // The fade's own length does not count against it.
        Clip without = *transition.owner;
        std::erase_if(without.spans, [&](const EffectSpan &s) { return s.id == transition.span->id; });
        limit.maximumFrames = fadeLimitFrames(without, *transition.track, edge, fd, &reason, &error);
        limit.maximum = limit.maximumFrames > 0 ? timeForFrame(limit.maximumFrames, fd) : kCMTimeZero;
        limit.limitError = error;
        limit.reason = toStd(reason);
        return limit;
    }
    EditResult why = EditResult::success();
    const auto sides = transitionSideLimits(_project, [self sequenceId], transition.owner->id, transition.span->id, why);
    if (!sides) {
        limit.limitError = why.error;
        limit.reason = why.message;
        return limit;
    }
    auto fits = [&](int64_t frames) {
        const auto [start, end] = resizedOffsets(transition, frames, fd);
        return frameIndexAt(-start, fd, SnapMode::Round) <= sides->maxBeforeFrames &&
               frameIndexAt(end, fd, SnapMode::Round) <= sides->maxAfterFrames;
    };
    int64_t lo = 0;
    int64_t hi = sides->maxBeforeFrames + sides->maxAfterFrames + 1;
    while (hi - lo > 1) {
        const int64_t mid = lo + (hi - lo) / 2;
        (fits(mid) ? lo : hi) = mid;
    }
    limit.maximumFrames = lo;
    limit.maximum = lo > 0 ? timeForFrame(lo, fd) : kCMTimeZero;
    const auto [start, end] = resizedOffsets(transition, lo + 1, fd);
    const bool beforeOverruns = frameIndexAt(-start, fd, SnapMode::Round) > sides->maxBeforeFrames;
    (void)end;
    limit.limitError = beforeOverruns ? sides->beforeError : sides->afterError;
    limit.reason = beforeOverruns ? sides->beforeReason : sides->afterReason;
    limit.limitingClip = beforeOverruns ? sides->beforeLimitingClip : sides->afterLimitingClip;
    return limit;
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
    return makeTransitionLimit([self durationLimitFor:*transition]);
}

- (VEEditResult *)removeTransition:(VETransitionID)transitionID {
    VE_ASSERT_MAIN();
    const SpanId id(static_cast<SpanId::ValueType>(transitionID));
    if (!findTransition([self activeSequence], id)) {
        return [VEEditResult failureWithCode:VEEditErrorTransitionNotFound message:@"The transition no longer exists."];
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
        return [VEEditResult failureWithCode:VEEditErrorTransitionNotFound message:@"The transition no longer exists."];
    }
    int64_t frames = 0;
    if (VEEditResult *refusal = [self refuseTransitionDuration:duration frames:&frames]) {
        return refusal;
    }
    const CMTime fd = sequence.frameDuration;
    const TransitionLimit limit = [self durationLimitFor:*transition];
    if (frames > limit.maximumFrames && isLengthLimit(limit.limitError)) {
        return [VEEditResult failureWithCode:refusalCode(limit) message:transitionRefusal(limit, frames, fd)];
    }
    const auto [start, end] = resizedOffsets(*transition, frames, fd);
    std::vector<TransitionRangeChange> changes{{id, start, end}};
    NSString *note = nil;
    const auto partner = includingLinked ? linkedTransition(sequence, id) : std::nullopt;
    if (const auto linked = partner ? findTransition(sequence, *partner) : std::nullopt) {
        if (linked->track->locked) {
            note = [NSString stringWithFormat:@"The linked transition on %@ was not changed: the track is locked.",
                                              toNS(linked->track->name)];
        } else {
            // The linked transition gets the same length, fitted to its own cut.
            const TransitionLimit linkedLimit = [self durationLimitFor:*linked];
            if (linkedLimit.maximumFrames == 0) {
                note = [NSString stringWithFormat:@"The linked transition was not changed: %@", toNS(linkedLimit.reason)];
            } else {
                int64_t linkedFrames = frames;
                if (linkedFrames > linkedLimit.maximumFrames) {
                    linkedFrames = linkedLimit.maximumFrames;
                    note = [NSString stringWithFormat:@"The linked transition was limited to %@: %@",
                                                      describeFrames(linkedFrames, fd), toNS(linkedLimit.reason)];
                }
                const auto [linkedStart, linkedEnd] = resizedOffsets(*linked, linkedFrames, fd);
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
    const TransitionLimit limit = [self durationLimitFor:*transition];
    const int64_t frames =
        frameIndexAt(snapToFrame(duration, sequence.frameDuration, SnapMode::Round), sequence.frameDuration,
                     SnapMode::Round);
    if (frames <= limit.maximumFrames) {
        return result; // refused for another reason (e.g. shorter than a frame)
    }
    return [VEEditResult failureWithCode:result.errorCode
                                 message:transitionRefusal(limit, frames, sequence.frameDuration)];
}

/// The offsets of `transition` covering the timeline frames `range` (whole frames), fitted to what
/// its clips allow; `notes` says what was fitted or changed role. Nil when nothing fits (`refusal`
/// set).
- (std::optional<std::pair<CMTime, CMTime>>)offsetsFor:(const TransitionPlacement &)transition
                                                 range:(TimeRange)range
                                                linked:(BOOL)linked
                                                 notes:(NSMutableArray<NSString *> *)notes
                                               refusal:(VEEditResult **)refusal {
    const CMTime fd = [self activeSequence].frameDuration;
    NSString *who = linked ? @"The linked transition" : @"The transition";
    const Clip &owner = *transition.owner;
    if (transition.span->edge == ClipEdge::Head) {
        if (range.start != owner.timelineStart) {
            *refusal = [VEEditResult failureWithCode:VEEditErrorInvalidTime
                                             message:@"A fade in starts at its clip's start."];
            return std::nullopt;
        }
        NSString *reason = nil;
        EditError error = EditError::None;
        Clip without = owner;
        std::erase_if(without.spans, [&](const EffectSpan &s) { return s.id == transition.span->id; });
        const int64_t limit = fadeLimitFrames(without, *transition.track, ClipEdge::Head, fd, &reason, &error);
        int64_t length = frameIndexAt(range.duration(), fd, SnapMode::Round);
        if (length > limit) {
            length = limit;
            [notes addObject:[NSString stringWithFormat:@"%@ was shortened to %@: %@", who, describeFrames(length, fd), reason]];
        }
        if (length < 1) {
            *refusal = [VEEditResult failureWithCode:toVE(error) message:reason];
            return std::nullopt;
        }
        return std::make_pair(kCMTimeZero, timeForFrame(length, fd));
    }
    const CMTime cut = owner.timelineEnd();
    if (cut < range.start) {
        *refusal = [VEEditResult failureWithCode:VEEditErrorInvalidTime
                                         message:@"A transition at a clip's end starts inside the clip."];
        return std::nullopt;
    }
    int64_t before = frameIndexAt(cut - range.start, fd, SnapMode::Round);
    int64_t after = std::max<int64_t>(0, frameIndexAt(range.end - cut, fd, SnapMode::Round));
    const Clip *next = touchingClip(*transition.track, owner, ClipEdge::Tail);
    NSString *target = fadeTarget(*transition.track);
    if (after > 0 && next == nullptr) {
        after = 0;
        [notes addObject:[NSString stringWithFormat:@"%@ fades out to %@: nothing follows the clip.", who, target]];
    }
    if (after > 0) {
        EditResult why = EditResult::success();
        const auto sides = transitionSideLimits(_project, [self sequenceId], owner.id, transition.span->id, why);
        if (!sides) {
            *refusal = toVE(why);
            return std::nullopt;
        }
        if (before > sides->maxBeforeFrames) {
            before = sides->maxBeforeFrames;
            [notes addObject:[NSString stringWithFormat:@"%@ was shortened before the cut to %@: %@", who,
                                                        describeFrames(before, fd), toNS(sides->beforeReason)]];
        }
        if (after > sides->maxAfterFrames) {
            after = sides->maxAfterFrames;
            [notes addObject:[NSString stringWithFormat:@"%@ was shortened after the cut to %@: %@", who,
                                                        describeFrames(after, fd), toNS(sides->afterReason)]];
        }
        if (after > 0 && transition.role != TransitionRole::CrossDissolve) {
            [notes addObject:[NSString stringWithFormat:@"%@ now crosses the cut: a %@ into the next clip.", who,
                                                        transition.track->kind == TrackKind::Video ? @"cross dissolve"
                                                                                                    : @"crossfade"]];
        }
    }
    if (after == 0) {
        NSString *reason = nil;
        EditError error = EditError::None;
        Clip without = owner;
        std::erase_if(without.spans, [&](const EffectSpan &s) { return s.id == transition.span->id; });
        const int64_t limit = fadeLimitFrames(without, *transition.track, ClipEdge::Tail, fd, &reason, &error);
        if (before > limit) {
            before = limit;
            [notes addObject:[NSString stringWithFormat:@"%@ was shortened to %@: %@", who, describeFrames(before, fd), reason]];
        }
        if (transition.role == TransitionRole::CrossDissolve && before > 0 && next != nullptr) {
            [notes addObject:[NSString stringWithFormat:@"%@ no longer reaches past the cut, so it now fades out to %@.",
                                                        who, target]];
        }
    }
    if (before + after < 1) {
        *refusal = [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                         message:[NSString stringWithFormat:@"%@ would cover no frame.", who]];
        return std::nullopt;
    }
    return std::make_pair(-timeForFrame(before, fd), timeForFrame(after, fd));
}

- (VEEditResult *)setRangeOfTransition:(VETransitionID)transitionID
                                 range:(CMTimeRange)range
                       includingLinked:(BOOL)includingLinked {
    VE_ASSERT_MAIN();
    const SpanId id(static_cast<SpanId::ValueType>(transitionID));
    const Sequence &sequence = [self activeSequence];
    const auto transition = findTransition(sequence, id);
    if (!transition) {
        return [VEEditResult failureWithCode:VEEditErrorTransitionNotFound message:@"The transition no longer exists."];
    }
    const auto ends = rangeEnds(range);
    if (!ends) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidTime message:@"The range is not a valid time range."];
    }
    const CMTime fd = sequence.frameDuration;
    const TimeRange frames{snapToFrame(ends->first, fd, SnapMode::Round), snapToFrame(ends->second, fd, SnapMode::Round)};
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
