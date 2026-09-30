// VEEngine (Edits) and VEClipParamsBatch: placing media, moving, trimming, splitting and removing
// clips, clip parameters, speed and direction, links and tracks.

#import "VEEngine+Internal.h"

#import "VEFacadeCommands+Internal.h"

#include "../Edit/EditPlans.h"
#include "../Render/Scheduler.h"

#include <cmath>
#include <memory>
#include <optional>
#include <vector>

using namespace ve;
using namespace ve::facade;

namespace {

std::vector<ClipId> toClipIds(NSArray<NSNumber *> *numbers) {
    std::vector<ClipId> ids;
    ids.reserve(numbers.count);
    for (NSNumber *n : numbers) {
        const int64_t value = n.longLongValue;
        if (value > 0) {
            ids.push_back(toClipId(value));
        }
    }
    return ids;
}

} // namespace

@interface VEClipParamsBatch ()
/// The batch as engine changes, in the order clips were first added.
@property (nonatomic, readonly) std::vector<ClipParamsChange> changes;
@end

namespace {

/// The engine change for VEAudioParams: the static gain and the lane-0 fade lengths.
void setAudioChange(ClipParamsChange &change, const VEAudioParams &params) {
    change.audio = fromVE(params);
    change.fadeIn = params.fadeInDuration;
    change.fadeOut = params.fadeOutDuration;
}

} // namespace

@implementation VEClipParamsBatch {
    std::vector<ClipParamsChange> _changes;
}

- (ClipParamsChange &)entryForClip:(VEClipID)clipID {
    const ClipId id = toClipId(clipID);
    for (ClipParamsChange &change : _changes) {
        if (change.clipId == id) {
            return change;
        }
    }
    ClipParamsChange change;
    change.clipId = id;
    _changes.push_back(change);
    return _changes.back();
}

- (void)setVideoParams:(VEVideoParams)params forClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    [self entryForClip:clipID].video = fromVE(params);
}

- (void)setAudioParams:(VEAudioParams)params forClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    setAudioChange([self entryForClip:clipID], params);
}

- (NSUInteger)count {
    VE_ASSERT_MAIN();
    return _changes.size();
}

- (std::vector<ClipParamsChange>)changes {
    return _changes;
}

@end

@implementation VEEngine (Edits)

// MARK: - Edits

- (VEEditResult *)placeAsset:(VEAssetID)assetID
                      atTime:(CMTime)time
                  videoTrack:(VETrackID)videoTrackID
                  audioTrack:(VETrackID)audioTrackID
                    sourceIn:(CMTime)sourceIn
                   sourceOut:(CMTime)sourceOut
                   overwrite:(BOOL)overwrite {
    VE_ASSERT_MAIN();
    const MediaAsset *asset = _project.findAsset(toAssetId(assetID));
    if (asset == nullptr) {
        return [VEEditResult failureWithMessage:@"The media is not in the project."];
    }
    std::vector<ClipPlacement> placements =
        placementsForAsset(*asset, toTrackId(videoTrackID), toTrackId(audioTrackID), sourceIn, sourceOut);
    if (placements.empty()) {
        return [VEEditResult failureWithMessage:asset->hasVideo() ? @"Choose a video track for this media."
                                                                  : @"Choose an audio track for this media."];
    }
    const bool link = placements.size() == 2;
    // A video clip cannot use media past the end of the video (EditOps cuts its range there):
    // say so when the request (or the whole media) runs past it.
    NSString *note = nil;
    const CMTime videoEnd = asset->videoEnd();
    const CMTime requestedOut = CMTIME_IS_NUMERIC(sourceOut) ? sourceOut : asset->duration;
    if (!asset->isStill() && asset->hasVideo() && videoTrackID != 0 && CMTIME_IS_NUMERIC(videoEnd) &&
        videoEnd < asset->duration && requestedOut > videoEnd) {
        note = [NSString stringWithFormat:@"The video of “%@” ends at %.3f s, before its audio: the video clip "
                                          @"ends there.",
                                          toNS(asset->name), CMTimeGetSeconds(videoEnd)];
    }
    // The first video clip on a sequence that is not configured sets its settings, in the same undo
    // step (a composite: the settings first, so the placement lands on the new frame grid).
    const Sequence &sequence = [self activeSequence];
    std::optional<SequenceFormat> adopted;
    if (!sequence.configured && videoTrackID != 0) {
        adopted = formatAdoptedFrom(*asset, sequence.format());
    }
    if (adopted) {
        NSString *taken = [NSString stringWithFormat:@"The sequence takes “%@”'s settings: %d×%d at %@ fps.",
                                                     toNS(asset->name), adopted->width, adopted->height,
                                                     toNS(frameRateName(adopted->frameDuration))];
        note = note.length > 0 ? [NSString stringWithFormat:@"%@ %@", taken, note] : taken;
    }
    const SequenceId sequenceId = [self sequenceId];
    auto withAdoption = [adopted, sequenceId](std::unique_ptr<Command> placement, const char *name) {
        if (!adopted) {
            return placement;
        }
        std::vector<std::unique_ptr<Command>> children;
        children.push_back(std::make_unique<SetSequenceFormat>(sequenceId, *adopted, name));
        children.push_back(std::move(placement));
        return std::unique_ptr<Command>(std::make_unique<CompositeCommand>(name, std::move(children)));
    };
    if (overwrite) {
        auto command = std::make_unique<OverwriteClip>(sequenceId, time, std::move(placements), link);
        OverwriteClip *raw = command.get();
        return [self push:withAdoption(std::move(command), "Overwrite")
                  created:^NSArray<NSNumber *> * {
                      return toNumbers(raw->createdClipIds());
                  }
                     note:note];
    }
    __block InsertClip *raw = nullptr;
    return [self pushRipple:^std::unique_ptr<Command>(RippleScope scope) {
        InsertOptions options;
        options.linkPair = link;
        options.ripple = scope;
        auto command = std::make_unique<InsertClip>(sequenceId, time, placements, options);
        raw = command.get();
        return withAdoption(std::move(command), "Insert");
    }
                      scope:_rippleScope
                    created:^NSArray<NSNumber *> * {
                        return raw != nullptr ? toNumbers(raw->createdClipIds()) : @[];
                    }
                       note:note];
}

- (VEEditResult *)insertAsset:(VEAssetID)assetID
                       atTime:(CMTime)time
                   videoTrack:(VETrackID)videoTrackID
                   audioTrack:(VETrackID)audioTrackID
                     sourceIn:(CMTime)sourceIn
                    sourceOut:(CMTime)sourceOut {
    return [self placeAsset:assetID
                     atTime:time
                 videoTrack:videoTrackID
                 audioTrack:audioTrackID
                   sourceIn:sourceIn
                  sourceOut:sourceOut
                  overwrite:NO];
}

- (VEEditResult *)overwriteAsset:(VEAssetID)assetID
                          atTime:(CMTime)time
                      videoTrack:(VETrackID)videoTrackID
                      audioTrack:(VETrackID)audioTrackID
                        sourceIn:(CMTime)sourceIn
                       sourceOut:(CMTime)sourceOut {
    return [self placeAsset:assetID
                     atTime:time
                 videoTrack:videoTrackID
                 audioTrack:audioTrackID
                   sourceIn:sourceIn
                  sourceOut:sourceOut
                  overwrite:YES];
}

- (VEEditResult *)moveClip:(VEClipID)clipID toTrack:(VETrackID)trackID start:(CMTime)start {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<MoveClip>([self sequenceId], toClipId(clipID), toTrackId(trackID), start)
              created:nil];
}

- (VEEditResult *)moveClips:(NSArray<NSNumber *> *)clipIDs byTime:(CMTime)delta trackOffset:(NSInteger)trackOffset {
    VE_ASSERT_MAIN();
    return [self moveClips:clipIDs byTime:delta trackOffset:trackOffset kind:std::nullopt];
}

- (VEEditResult *)moveClips:(NSArray<NSNumber *> *)clipIDs
                     byTime:(CMTime)delta
                trackOffset:(NSInteger)trackOffset
                ofTrackKind:(VETrackKind)kind {
    VE_ASSERT_MAIN();
    return [self moveClips:clipIDs
                    byTime:delta
               trackOffset:trackOffset
                      kind:kind == VETrackKindVideo ? TrackKind::Video : TrackKind::Audio];
}

- (VEEditResult *)moveClips:(NSArray<NSNumber *> *)clipIDs
                     byTime:(CMTime)delta
                trackOffset:(NSInteger)trackOffset
                       kind:(std::optional<TrackKind>)kind {
    if (!CMTIME_IS_NUMERIC(delta)) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidTime message:@"Invalid time."];
    }
    std::vector<ClipId> ids = toClipIds(clipIDs);
    if (ids.empty()) {
        return [VEEditResult failureWithMessage:@"Nothing to move."];
    }
    // Inside a coalescing group the undo stack reverts the group's previous step before this
    // one applies, so the offsets are relative to the positions when the group began.
    return [self push:std::make_unique<MoveClips>([self sequenceId], std::move(ids), delta, trackOffset, kind)
              created:nil];
}

- (VEEditResult *)trimClipHead:(VEClipID)clipID toTime:(CMTime)time clamp:(BOOL)clamp {
    VE_ASSERT_MAIN();
    TrimOptions options;
    options.clampToLimits = clamp;
    return [self push:std::make_unique<TrimClipHead>([self sequenceId], toClipId(clipID), time, options) created:nil];
}

- (VEEditResult *)trimClipTail:(VEClipID)clipID toTime:(CMTime)time clamp:(BOOL)clamp {
    VE_ASSERT_MAIN();
    TrimOptions options;
    options.clampToLimits = clamp;
    return [self push:std::make_unique<TrimClipTail>([self sequenceId], toClipId(clipID), time, options) created:nil];
}

- (VEEditResult *)splitClip:(VEClipID)clipID atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    auto command = std::make_unique<SplitClip>([self sequenceId], toClipId(clipID), time);
    SplitClip *raw = command.get();
    VEEditResult *result = [self push:std::move(command)
                              created:^NSArray<NSNumber *> * {
                                  return toNumbers(raw->createdClipIds());
                              }];
    if (result.ok) {
        setDividedSpans(result, raw->dividedSpans());
    }
    return result;
}

- (VEEditResult *)splitClips:(NSArray<NSNumber *> *)clipIDs atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    return [self splitClips:clipIDs atTime:time breakingTransitions:NO];
}

- (VEEditResult *)splitClips:(NSArray<NSNumber *> *)clipIDs
                      atTime:(CMTime)time
         breakingTransitions:(BOOL)breakingTransitions {
    VE_ASSERT_MAIN();
    SplitOptions options;
    options.allowBreakingTransitions = breakingTransitions;
    const Sequence &sequence = [self activeSequence];
    const CMTime at = snapToFrame(time, sequence.frameDuration, SnapMode::Round);
    // The given clips, or every clip under the playhead on an unlocked track.
    const std::vector<ClipId> candidates = clipIDs.count > 0 ? toClipIds(clipIDs) : Scheduler::clipsAt(sequence, at);
    std::vector<std::unique_ptr<Command>> children;
    std::vector<SplitClip *> splits;
    for (ClipId id : splitTargets(sequence, candidates, at, clipIDs.count == 0)) {
        auto split = std::make_unique<SplitClip>([self sequenceId], id, at, options);
        splits.push_back(split.get());
        children.push_back(std::move(split));
    }
    if (children.empty()) {
        return [VEEditResult failureWithMessage:@"No clip under the playhead to split."];
    }
    auto createdBlock = ^NSArray<NSNumber *> * {
        NSMutableArray<NSNumber *> *all = [NSMutableArray array];
        for (SplitClip *s : splits) {
            [all addObjectsFromArray:toNumbers(s->createdClipIds())];
        }
        return all;
    };
    VEEditResult *result = children.size() == 1
                               ? [self push:std::move(children.front()) created:createdBlock]
                               : [self push:std::make_unique<CompositeCommand>("Split", std::move(children))
                                    created:createdBlock];
    if (result.ok) {
        std::vector<std::pair<SpanId, SpanId>> divided;
        for (SplitClip *s : splits) {
            divided.insert(divided.end(), s->dividedSpans().begin(), s->dividedSpans().end());
        }
        setDividedSpans(result, divided);
    }
    return result;
}

- (VEEditResult *)removeClips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    std::vector<ClipId> ids = toClipIds(clipIDs);
    if (ids.empty()) {
        return [VEEditResult failureWithMessage:@"Nothing selected."];
    }
    return [self push:std::make_unique<RemoveClips>([self sequenceId], std::move(ids)) created:nil];
}

- (VEEditResult *)rippleDeleteClips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    std::vector<ClipId> ids = toClipIds(clipIDs);
    if (ids.empty()) {
        return [VEEditResult failureWithMessage:@"Nothing selected."];
    }
    const SequenceId sequenceId = [self sequenceId];
    return [self pushRipple:^std::unique_ptr<Command>(RippleScope scope) {
        RippleOptions options;
        options.scope = scope;
        return std::make_unique<RippleDelete>(sequenceId, ids, options);
    }
                    created:nil];
}

- (VERippleScope)rippleScope {
    VE_ASSERT_MAIN();
    return _rippleScope;
}

- (void)setRippleScope:(VERippleScope)rippleScope {
    VE_ASSERT_MAIN();
    _rippleScope = rippleScope;
}

- (VEEditResult *)setVideoParams:(VEVideoParams)params forClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<SetVideoParams>([self sequenceId], toClipId(clipID), fromVE(params))
              created:nil];
}

- (VEEditResult *)setAudioParams:(VEAudioParams)params forClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    ClipParamsChange change;
    change.clipId = toClipId(clipID);
    setAudioChange(change, params);
    return [self push:std::make_unique<SetClipsParams>([self sequenceId], std::vector<ClipParamsChange>{change})
              created:nil];
}

- (VEEditResult *)applyClipParams:(VEClipParamsBatch *)batch {
    VE_ASSERT_MAIN();
    if (batch.count == 0) {
        return [VEEditResult failureWithMessage:@"Nothing selected."];
    }
    return [self push:std::make_unique<SetClipsParams>([self sequenceId], batch.changes) created:nil];
}

- (VEEditResult *)setSpeed:(double)speed forClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    if (!std::isfinite(speed) || speed <= 0) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"The speed must be positive."];
    }
    return [self setSpeedRatio:speedFromDouble(speed) forClip:clipID];
}

- (VEEditResult *)setSpeedNumerator:(int64_t)numerator denominator:(int64_t)denominator forClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    const std::optional<Ratio> ratio = Ratio::reduced(numerator, denominator);
    if (!ratio || !isValidSpeed(*ratio)) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                     message:@"The speed must be a fraction between 1/100 and 100 with a "
                                             @"denominator of at most 1000."];
    }
    return [self setSpeedRatio:*ratio forClip:clipID];
}

- (VEEditResult *)setSpeedRatio:(Ratio)speed forClip:(VEClipID)clipID {
    const SequenceId sequenceId = [self sequenceId];
    const ClipId clip = toClipId(clipID);
    return [self pushRipple:^std::unique_ptr<Command>(RippleScope scope) {
        SpeedOptions options;
        options.ripple = true;
        options.scope = scope;
        return std::make_unique<SetClipSpeed>(sequenceId, clip, speed, options);
    }
                    created:nil];
}

- (VEEditResult *)setSpeedNumerator:(int64_t)numerator
                        denominator:(int64_t)denominator
                           forClips:(NSArray<NSNumber *> *)clipIDs
                             ripple:(BOOL)ripple
                              scope:(VERippleScope)scope {
    VE_ASSERT_MAIN();
    const std::optional<Ratio> ratio = Ratio::reduced(numerator, denominator);
    if (!ratio || !isValidSpeed(*ratio)) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                     message:@"The speed must be between 1% and 10000% (a fraction between 1/100 "
                                             @"and 100 with a denominator of at most 1000)."];
    }
    const Sequence &sequence = [self activeSequence];
    std::vector<ClipId> targets;
    if (const EditResult listed = linkedEditTargets(
            sequence, toClipIds(clipIDs),
            "Still images have no playback speed; change their duration by trimming instead.", targets);
        !listed) {
        return toVE(listed);
    }
    if (targets.empty()) {
        return [VEEditResult failureWithMessage:@"Nothing selected."];
    }
    const SequenceId sequenceId = [self sequenceId];
    const Ratio speed = *ratio;
    const bool rippling = ripple;
    auto make = ^std::unique_ptr<Command>(RippleScope rippleScope) {
        std::vector<std::unique_ptr<Command>> children;
        for (ClipId id : targets) {
            SpeedOptions options;
            options.ripple = rippling;
            options.scope = rippleScope;
            children.push_back(std::make_unique<SetClipSpeed>(sequenceId, id, speed, options));
        }
        if (children.size() == 1) {
            return std::move(children.front());
        }
        return std::make_unique<CompositeCommand>("Change Speed", std::move(children));
    };
    if (!ripple) {
        return [self push:make(RippleScope::SyncedTracks) created:nil];
    }
    return [self pushRipple:make scope:scope created:nil];
}

- (VEEditResult *)setReversed:(BOOL)reversed forClips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    std::vector<ClipId> targets;
    if (const EditResult listed =
            linkedEditTargets(sequence, toClipIds(clipIDs), "A still image has no motion to reverse.", targets);
        !listed) {
        return toVE(listed);
    }
    if (targets.empty()) {
        return [VEEditResult failureWithMessage:@"Nothing selected."];
    }
    const SequenceId sequenceId = [self sequenceId];
    const bool on = reversed;
    // A still linked to a clip being turned stays as it is (it has no direction; review L2): say so.
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    for (ClipId id : targets) {
        const Clip *clip = sequence.findClip(id);
        const Clip *partner = clip->linkedClipId ? sequence.findClip(*clip->linkedClipId) : nullptr;
        if (partner == nullptr || !partner->isStill || clip->reversed == on) {
            continue;
        }
        const MediaAsset *clipAsset = _project.findAsset(clip->assetId);
        const MediaAsset *stillAsset = _project.findAsset(partner->assetId);
        NSString *clipName = clipAsset ? toNS(clipAsset->name) : @"the clip";
        NSString *stillName = stillAsset ? toNS(stillAsset->name) : @"its picture";
        [notes addObject:[NSString stringWithFormat:@"“%@” is a still image, which has no direction: its linked "
                                                    @"“%@” was %@ on its own.",
                                                    stillName, clipName, on ? @"reversed" : @"played forward"]];
    }
    NSString *note = notes.count > 0 ? [notes componentsJoinedByString:@" "] : nil;
    std::vector<std::unique_ptr<Command>> children;
    for (ClipId id : targets) {
        children.push_back(std::make_unique<SetClipReversed>(sequenceId, id, on));
    }
    if (children.size() == 1) {
        return [self push:std::move(children.front()) created:nil note:note];
    }
    return [self push:std::make_unique<CompositeCommand>(on ? "Reverse Clips" : "Play Clips Forward", std::move(children))
              created:nil
                 note:note];
}

- (VEEditResult *)linkClip:(VEClipID)clipID withClip:(VEClipID)otherClipID {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<LinkClips>([self sequenceId], toClipId(clipID), toClipId(otherClipID))
              created:nil];
}

- (VEEditResult *)unlinkClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<UnlinkClip>([self sequenceId], toClipId(clipID)) created:nil];
}

- (VEEditResult *)addTrackOfKind:(VETrackKind)kind name:(nullable NSString *)name {
    VE_ASSERT_MAIN();
    auto command = std::make_unique<AddTrack>([self sequenceId],
                                              kind == VETrackKindVideo ? TrackKind::Video : TrackKind::Audio,
                                              name ? toStd(name) : std::string());
    AddTrack *raw = command.get();
    return [self push:std::move(command)
              created:^NSArray<NSNumber *> * {
                  return @[ @(static_cast<int64_t>(raw->createdTrackId().value())) ];
              }];
}

- (VEEditResult *)removeTrack:(VETrackID)trackID {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const Track *track = sequence.findTrack(toTrackId(trackID));
    if (track != nullptr && sequence.tracks(track->kind).size() <= 1) {
        return [VEEditResult failureWithMessage:@"A sequence keeps at least one track of each kind."];
    }
    return [self push:std::make_unique<RemoveTrack>([self sequenceId], toTrackId(trackID)) created:nil];
}

- (VEEditResult *)updateTrack:(VETrackID)trackID with:(const TrackFlagsUpdate &)update {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<SetTrackFlags>([self sequenceId], toTrackId(trackID), update) created:nil];
}

- (VEEditResult *)setTrack:(VETrackID)trackID muted:(BOOL)muted {
    TrackFlagsUpdate update;
    update.muted = muted;
    return [self updateTrack:trackID with:update];
}

- (VEEditResult *)setTrack:(VETrackID)trackID solo:(BOOL)solo {
    TrackFlagsUpdate update;
    update.solo = solo;
    return [self updateTrack:trackID with:update];
}

- (VEEditResult *)setTrack:(VETrackID)trackID locked:(BOOL)locked {
    TrackFlagsUpdate update;
    update.locked = locked;
    return [self updateTrack:trackID with:update];
}

- (VEEditResult *)renameTrack:(VETrackID)trackID to:(NSString *)name {
    TrackFlagsUpdate update;
    update.name = toStd(name);
    return [self updateTrack:trackID with:update];
}

@end
