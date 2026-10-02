// VEEngine (EffectSpans): the effect spans of clips' lanes 1-3 (Motion, Opacity, Gain), Ken Burns,
// Continue on Next Clip, and matching a span or a clip's static Motion to its neighbour.

#import "VEEngine+Internal.h"

#include "../Edit/EditPlans.h"

#include <cmath>
#include <memory>
#include <optional>
#include <vector>

using namespace ve;
using namespace ve::facade;

@implementation VEEngine (EffectSpans)

// MARK: - Effect spans

/// The span (either kind) `spanId` as it is now, or nil (also for a span the app is not shown,
/// isShownSpan).
- (nullable VEEffectSpan *)effectSpanInfo:(SpanId)spanId {
    const Sequence &sequence = [self activeSequence];
    const Clip *clip = nullptr;
    const Track *track = nullptr;
    if (const TransitionSpan *transition = sequence.findTransition(spanId, &clip, &track)) {
        return makeEffectSpan(*transition, *clip, *track, sequence);
    }
    const EffectSpan *span = sequence.findSpan(spanId, &clip, &track);
    return span != nullptr && isShownSpan(*span) ? makeEffectSpan(*span, *clip, *track, sequence) : nil;
}

/// Pushes a span edit; on success the result carries the span `spanId()` names (as it is after the
/// edit), and `created` lists it when the edit created it.
- (VEEditResult *)pushSpanCommand:(std::unique_ptr<Command>)command
                           spanId:(SpanId (^)(void))spanId
                          created:(BOOL)created
                             note:(nullable NSString *)note {
    const EditResult result = [self pushCommand:std::move(command)];
    if (!result) {
        return toVE(result);
    }
    const SpanId id = spanId();
    [self notifyModelChanged];
    NSArray<NSNumber *> *ids = created ? @[ @(static_cast<VESpanID>(id.value())) ] : @[];
    return makeEditResult(result, ids, note, [self effectSpanInfo:id]);
}

/// pushSpanCommand: for an edit of the existing span `spanId`.
- (VEEditResult *)pushSpanEdit:(std::unique_ptr<Command>)command span:(SpanId)spanId note:(nullable NSString *)note {
    return [self pushSpanCommand:std::move(command)
                          spanId:^SpanId {
                              return spanId;
                          }
                         created:NO
                            note:note];
}

- (NSArray<VEEffectSpan *> *)spansForClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const ClipId id = toClipId(clipID);
    const Track *track = sequence.trackOfClip(id);
    const Clip *clip = track ? track->find(id) : nullptr;
    NSMutableArray<VEEffectSpan *> *spans = [NSMutableArray array];
    if (clip != nullptr) {
        for (const TransitionSpan &span : clip->transitions) {
            [spans addObject:makeEffectSpan(span, *clip, *track, sequence)];
        }
        for (const EffectSpan &span : clip->spans) {
            if (isShownSpan(span)) {
                [spans addObject:makeEffectSpan(span, *clip, *track, sequence)];
            }
        }
    }
    return spans;
}

- (NSArray<VEEffectSpan *> *)spansForTrack:(VETrackID)trackID {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const Track *track = sequence.findTrack(toTrackId(trackID));
    NSMutableArray<VEEffectSpan *> *spans = [NSMutableArray array];
    if (track != nullptr) {
        const ClipIndex index(sequence);
        for (const Clip &clip : track->clips) {
            for (const TransitionSpan &span : clip.transitions) {
                [spans addObject:makeEffectSpan(span, clip, *track, sequence, &index)];
            }
            for (const EffectSpan &span : clip.spans) {
                if (isShownSpan(span)) {
                    [spans addObject:makeEffectSpan(span, clip, *track, sequence, &index)];
                }
            }
        }
    }
    return spans;
}

- (nullable VEEffectSpan *)spanInfo:(VESpanID)spanID {
    VE_ASSERT_MAIN();
    return [self effectSpanInfo:toSpanId(spanID)];
}

- (NSInteger)laneCountForTrack:(VETrackID)trackID {
    VE_ASSERT_MAIN();
    const Track *track = [self activeSequence].findTrack(toTrackId(trackID));
    return track != nullptr ? laneCount(*track) : 0;
}

- (VEEditResult *)addSpanOfKind:(VESpanKind)kind lane:(NSInteger)lane clip:(VEClipID)clipID range:(CMTimeRange)range {
    VE_ASSERT_MAIN();
    const std::optional<SpanKind> spanKind = fromVE(kind);
    if (!spanKind || *spanKind == SpanKind::Transition) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                     message:@"Add a Motion, Opacity or Gain span (transitions have their own calls)."];
    }
    const auto ends = numericRange(range);
    if (!ends) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidTime message:@"The span's range is not a valid time range."];
    }
    auto command = std::make_unique<AddSpan>([self sequenceId], toClipId(clipID), *spanKind, clampToInt(lane),
                                             ends->start, ends->end);
    AddSpan *raw = command.get();
    return [self pushSpanCommand:std::move(command)
                          spanId:^SpanId {
                              return raw->createdSpanId();
                          }
                         created:YES
                            note:nil];
}

- (VEEditResult *)setRangeOfSpan:(VESpanID)spanID range:(CMTimeRange)range {
    VE_ASSERT_MAIN();
    const auto ends = numericRange(range);
    if (!ends) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidTime message:@"The span's range is not a valid time range."];
    }
    const SpanId id = toSpanId(spanID);
    return [self pushSpanEdit:std::make_unique<SetSpanRange>([self sequenceId], id, ends->start, ends->end)
                         span:id
                         note:nil];
}

- (VEEditResult *)setValuesOfSpan:(VESpanID)spanID start:(VESpanValues)start end:(VESpanValues)end {
    VE_ASSERT_MAIN();
    std::vector<SpanValueChange> changes;
    for (const SpanParameter parameter : kSpanParameters) {
        const double from = spanValueIn(start, parameter);
        const double to = spanValueIn(end, parameter);
        if (std::isnan(from) && std::isnan(to)) {
            continue;
        }
        SpanValueChange change;
        change.parameter = parameter;
        if (!std::isnan(from)) {
            change.start = from;
        }
        if (!std::isnan(to)) {
            change.end = to;
        }
        changes.push_back(change);
    }
    const SpanId id = toSpanId(spanID);
    return [self pushSpanEdit:std::make_unique<SetSpanValues>([self sequenceId], id, std::move(changes))
                         span:id
                         note:nil];
}

- (VEEditResult *)setInterpolationOfSpan:(VESpanID)spanID interpolation:(VEKeyframeInterpolation)interpolation {
    VE_ASSERT_MAIN();
    const std::optional<KeyframeInterpolation> easing = fromVE(interpolation);
    if (!easing) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"Unknown interpolation."];
    }
    const SpanId id = toSpanId(spanID);
    return [self pushSpanEdit:std::make_unique<SetSpanInterpolation>([self sequenceId], id, *easing) span:id note:nil];
}

- (VEEditResult *)moveSpan:(VESpanID)spanID toLane:(NSInteger)lane {
    VE_ASSERT_MAIN();
    const SpanId id = toSpanId(spanID);
    return [self pushSpanEdit:std::make_unique<MoveSpanLane>([self sequenceId], id, clampToInt(lane)) span:id note:nil];
}

- (VEEditResult *)removeSpan:(VESpanID)spanID {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<RemoveSpans>([self sequenceId], std::vector<SpanId> { toSpanId(spanID) })
              created:nil];
}

- (VEEditResult *)matchSpanEdge:(VESpanID)spanID toAdjacentClipAtEdge:(VEClipEdge)edge {
    VE_ASSERT_MAIN();
    const SpanId id = toSpanId(spanID);
    const bool previous = edge == VEClipEdgeStart;
    const Sequence &sequence = [self activeSequence];
    std::vector<SpanValueChange> changes;
    if (EditResult planned = planMatchSpanEdge(sequence, id, previous ? ClipEdge::Head : ClipEdge::Tail, changes);
        !planned) {
        return toVE(planned);
    }
    NSString *what = previous ? @"the previous clip's end" : @"the next clip's start";
    if (changes.empty()) {
        const Track *track = nullptr;
        sequence.findSpan(id, nullptr, &track);
        if (track != nullptr && track->locked) {
            return [VEEditResult failureWithCode:VEEditErrorTrackLocked
                                         message:[NSString stringWithFormat:@"Track %@ is locked.", toNS(track->name)]];
        }
        return makeEditResult(EditResult::success(), @[], [NSString stringWithFormat:@"This span already matches %@.", what],
                              [self effectSpanInfo:id]);
    }
    return [self pushSpanEdit:std::make_unique<SetSpanValues>([self sequenceId], id, std::move(changes),
                                                              previous ? "Match Previous Clip" : "Match Next Clip")
                         span:id
                         note:[NSString stringWithFormat:@"Matched %@.", what]];
}

- (VEEditResult *)continueMotionSpanOnNextClip:(VESpanID)spanID {
    VE_ASSERT_MAIN();
    const SpanId id = toSpanId(spanID);
    auto command = std::make_unique<ContinueMotionSpan>([self sequenceId], id);
    ContinueMotionSpan *raw = command.get();
    return [self pushSpanCommand:std::move(command)
                          spanId:^SpanId {
                              return raw->createdSpanId();
                          }
                         created:YES
                            note:nil];
}

- (nullable NSString *)problemContinuingMotionSpanOnNextClip:(VESpanID)spanID {
    VE_ASSERT_MAIN();
    ContinueMotionPlan plan;
    const EditResult planned = planContinueMotion(_project, [self activeSequence], toSpanId(spanID), plan);
    return planned ? nil : toNS(planned.message);
}

- (VEEditResult *)applyKenBurnsToSpan:(VESpanID)spanID
                                start:(VEMotionFraming)start
                                  end:(VEMotionFraming)end
                        interpolation:(VEKeyframeInterpolation)interpolation {
    VE_ASSERT_MAIN();
    const SpanId id = toSpanId(spanID);
    const Sequence &sequence = [self activeSequence];
    const Clip *clip = nullptr;
    const Track *track = nullptr;
    const bool transition = sequence.findTransition(id) != nullptr;
    const EffectSpan *span = transition ? nullptr : sequence.findSpan(id, &clip, &track);
    if (!transition && span == nullptr) {
        return [VEEditResult failureWithCode:VEEditErrorSpanNotFound message:@"The span no longer exists."];
    }
    const std::optional<KeyframeInterpolation> easing = fromVE(interpolation);
    if (!easing || *easing == KeyframeInterpolation::Bezier) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                     message:@"Choose hold, linear or an ease for the Ken Burns move."];
    }
    if (transition) {
        return toVE(kenBurnsNeedsMotionSpan());
    }
    std::vector<SpanValueChange> changes;
    if (EditResult planned = planKenBurns(*clip, *span, sequence.frameDuration, MotionFraming{start.x, start.y, start.scale},
                                          MotionFraming{end.x, end.y, end.scale}, changes);
        !planned) {
        return toVE(planned);
    }
    return [self
        pushSpanEdit:std::make_unique<SetSpanValues>([self sequenceId], id, std::move(changes), "Ken Burns", *easing)
                span:id
                note:nil];
}

- (VEClipID)adjacentClipOfClip:(VEClipID)clipID atEdge:(VEClipEdge)edge {
    VE_ASSERT_MAIN();
    const Clip *neighbour = adjacentClip([self activeSequence], toClipId(clipID),
                                         edge == VEClipEdgeStart ? ClipEdge::Head : ClipEdge::Tail);
    return neighbour != nullptr ? static_cast<VEClipID>(neighbour->id.value()) : 0;
}

- (VEEditResult *)matchMotionOfClip:(VEClipID)clipID toAdjacentAtEdge:(VEClipEdge)edge {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const ClipId id = toClipId(clipID);
    const bool previous = edge == VEClipEdgeStart;
    std::optional<VideoParams> values;
    if (const EditResult planned = planMatchMotion(sequence, id, previous ? ClipEdge::Head : ClipEdge::Tail, values);
        !planned) {
        return toVE(planned);
    }
    NSString *what = previous ? @"the previous clip's end" : @"the next clip's start";
    if (!values) {
        const Track *track = sequence.trackOfClip(id);
        if (track->locked) {
            return [VEEditResult failureWithCode:VEEditErrorTrackLocked
                                         message:[NSString stringWithFormat:@"Track %@ is locked.", toNS(track->name)]];
        }
        return toVE(EditResult::success(), @[], [NSString stringWithFormat:@"This clip already matches %@.", what]);
    }
    return [self push:std::make_unique<SetVideoParams>([self sequenceId], id, *values,
                                                       previous ? "Match Previous Clip" : "Match Next Clip")
              created:nil
                 note:[NSString stringWithFormat:@"Matched %@: set as this clip's static values.", what]];
}

@end
