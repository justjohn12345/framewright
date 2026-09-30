// VEEngine (Snapshots): immutable snapshots (VETypes.h) of the active sequence, its clips, tracks
// and transitions, and of the project's assets.

#import "VEEngine+Internal.h"

#import "VEFacadeCommands+Internal.h"
#import "VEMediaLibrary+Internal.h"

#include "../Render/Scheduler.h"

#include <optional>

using namespace ve;
using namespace ve::facade;

@implementation VEEngine (Snapshots)

// MARK: - Snapshots

- (VESequenceInfo *)sequence {
    VE_ASSERT_MAIN();
    return makeSequenceInfo([self activeSequence]);
}

- (nullable VEClipInfo *)clipInfo:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const ClipId id = toClipId(clipID);
    const Track *track = sequence.trackOfClip(id);
    const Clip *clip = track ? track->find(id) : nullptr;
    return clip ? makeClipInfo(*clip, *track, _project, sequence) : nil;
}

- (nullable VETrackInfo *)trackInfo:(VETrackID)trackID {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    for (const auto *tracks : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (size_t i = 0; i < tracks->size(); ++i) {
            if ((*tracks)[i].id == toTrackId(trackID)) {
                return makeTrackInfo((*tracks)[i], NSInteger(i));
            }
        }
    }
    return nil;
}

- (nullable VEAssetInfo *)assetInfo:(VEAssetID)assetID {
    VE_ASSERT_MAIN();
    const MediaAsset *asset = _project.findAsset(toAssetId(assetID));
    return asset ? [self makeInfoForAsset:*asset] : nil;
}

- (VEAssetInfo *)makeInfoForAsset:(const MediaAsset &)asset {
    const std::optional<AssetDetails> details = [_media detailsForAsset:asset.id];
    return makeAssetInfo(asset, details ? &*details : nullptr, [_media isAssetMissing:asset.id],
                         NSInteger(countAssetUses(_project, asset.id)));
}

- (nullable VETransitionInfo *)transitionInfo:(VETransitionID)transitionID {
    VE_ASSERT_MAIN();
    const auto transition = findTransition([self activeSequence], toSpanId(transitionID));
    return transition ? makeTransitionInfo(*transition) : nil;
}

- (NSArray<VEAssetInfo *> *)allAssets {
    VE_ASSERT_MAIN();
    NSMutableArray<VEAssetInfo *> *assets = [NSMutableArray arrayWithCapacity:_project.assets.size()];
    for (const MediaAsset &asset : _project.assets) {
        [assets addObject:[self makeInfoForAsset:asset]];
    }
    return assets;
}

- (NSArray<VETrackInfo *> *)allTracks {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    NSMutableArray<VETrackInfo *> *tracks = [NSMutableArray array];
    for (const auto *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (size_t i = 0; i < list->size(); ++i) {
            [tracks addObject:makeTrackInfo((*list)[i], NSInteger(i))];
        }
    }
    return tracks;
}

- (NSArray<VEClipInfo *> *)clipsOnTrack:(VETrackID)trackID {
    VE_ASSERT_MAIN();
    const Track *track = [self activeSequence].findTrack(toTrackId(trackID));
    NSMutableArray<VEClipInfo *> *clips = [NSMutableArray array];
    if (track != nullptr) {
        const Sequence &sequence = [self activeSequence];
        const ClipIndex index(sequence);
        for (const Clip &clip : track->clips) {
            [clips addObject:makeClipInfo(clip, *track, _project, sequence, &index)];
        }
    }
    return clips;
}

- (NSArray<VEClipInfo *> *)allClips {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    // One lookup table for every span's linked transition (not a scan of the sequence per span).
    const ClipIndex index(sequence);
    NSMutableArray<VEClipInfo *> *clips = [NSMutableArray array];
    for (const auto *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (const Track &track : *list) {
            for (const Clip &clip : track.clips) {
                [clips addObject:makeClipInfo(clip, track, _project, sequence, &index)];
            }
        }
    }
    return clips;
}

- (NSArray<NSNumber *> *)clipIDsAtTime:(CMTime)time {
    VE_ASSERT_MAIN();
    return toNumbers(Scheduler::clipsAt([self activeSequence], time));
}

@end

@implementation VEEngine (SnapshotsInternal)

// MARK: - Private (VEEngine+Internal.h declares what other files call)

- (const Sequence &)activeSequence {
    const Sequence *sequence = _project.activeSequence();
    NSAssert(sequence != nullptr, @"the project always has an active sequence");
    return *sequence;
}

- (SequenceId)sequenceId {
    return _project.activeSequenceId;
}

@end
