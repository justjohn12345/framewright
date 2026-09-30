// Private interface of VEEngine, shared by its implementation files: VEEngine.mm (lifetime,
// versions, observers, notifications) and one VEEngine+<Area>.mm per category of VEEngine.h. It
// holds the engine's instance variables, the helpers several files use and the private methods
// one file calls on another, grouped by the file that implements them.
// Private to the facade implementation: excluded from the framework's headers (project.yml).

#pragma once

#import "VEEngine.h"

#import "VEProgramFrameProvider+Internal.h"
#import "VETypes+Internal.h"

#include "../Edit/Command.h"
#include "../Edit/EditOps.h"
#include "../Edit/UndoStack.h"
#include "../Media/BackendRouter.h"
#include "../Media/DecodePool.h"
#include "../Media/FrameCache.h"
#include "../Model/Project.h"
#include "../Playback/PlaybackController.h"
#include "../Thumbs/ThumbnailService.h"
#include "../Thumbs/WaveformService.h"

#include <os/log.h>

#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <utility>
#include <vector>

NS_ASSUME_NONNULL_BEGIN
/// Raises NSInternalInconsistencyException: a VEEngine method was called off the main thread.
[[noreturn]] void veMainThreadViolation(const char *function);
NS_ASSUME_NONNULL_END

/// Engine model calls are confined to the main thread. Active in every build configuration: a
/// call from another thread would race the model, so it fails loudly instead.
#define VE_ASSERT_MAIN()                                                                                               \
    do {                                                                                                               \
        if (__builtin_expect(!NSThread.isMainThread, 0)) {                                                             \
            veMainThreadViolation(__PRETTY_FUNCTION__);                                                                \
        }                                                                                                              \
    } while (0)

namespace ve::facade {

/// Shares of the frame cache budget the two decode pools may fill with lookahead windows. They
/// add up to the single pool's former 0.75, leaving the rest for scrubbed and pinned frames;
/// the program monitor gets the larger share (it plays multi-layer sequences).
constexpr double kProgramPoolBudgetShare = 0.5;
constexpr double kSourcePoolBudgetShare = 0.25;
/// An export's decode pool (the program and source shares plus this add up to 1).
constexpr double kExportPoolBudgetShare = 0.25;

/// Lanes of DecodePool::requestFrame: the program controller's layers use kProgramLaneBase + i,
/// the source monitor's scrub provider and controller their own ranges (on the source pool).
constexpr uint64_t kProgramLaneBase = 0;
constexpr uint64_t kSourceScrubLaneBase = uint64_t(1) << 40;
constexpr uint64_t kSourcePlaybackLaneBase = uint64_t(2) << 40;

NS_ASSUME_NONNULL_BEGIN

NSError *makeError(VEEngineErrorCode code, NSString *message);
VEEditResult *toVE(const EditResult &result, NSArray<NSNumber *> *created = @[], NSString *_Nullable note = nil);
template <class IdType> NSArray<NSNumber *> *toNumbers(const std::vector<IdType> &ids) {
    NSMutableArray<NSNumber *> *numbers = [NSMutableArray arrayWithCapacity:ids.size()];
    for (const IdType &id : ids) {
        [numbers addObject:@(static_cast<int64_t>(id.value()))];
    }
    return numbers;
}
/// Security-scoped bookmark for a file, falling back to a plain bookmark (outside the sandbox
/// security scope may be unavailable). Nil if the file cannot be bookmarked.
NSData *_Nullable makeBookmark(NSString *path);
bool isRunning(playback::PlaybackState state);
/// A timeline range as its two ends, or a refusal for an unusable range.
std::optional<std::pair<CMTime, CMTime>> rangeEnds(CMTimeRange range);

NS_ASSUME_NONNULL_END

} // namespace ve::facade

@interface VEEngine () {
    std::shared_ptr<ve::media::BackendRouter> _router;
    std::shared_ptr<ve::media::FrameCache> _frameCache;
    ve::media::FrameCache::Epoch _mediaEpoch; // advanced on every New/Open (ids restart per project)
    std::shared_ptr<ve::media::DecodePool> _decodePool;
    std::unique_ptr<ve::thumbs::ThumbnailService> _thumbnails;
    std::unique_ptr<ve::thumbs::WaveformService> _waveforms;
    std::unique_ptr<ve::playback::PlaybackController> _playback;
    uint64_t _playbackGeneration; // _projectGeneration the controller's sequence belongs to
    bool _playbackPublished;

    // Source monitor: a pool of its own (a playback controller replaces its pool's whole target
    // set), a still provider for scrubbing and a controller over a private one-clip project that
    // is created when the monitor first plays.
    std::shared_ptr<ve::media::DecodePool> _sourcePool;
    std::shared_ptr<ve::facade::ProgramFrameProvider> _sourceProvider;
    std::unique_ptr<ve::playback::PlaybackController> _sourcePlayback;
    __weak VEPreviewView *_sourceView;
    ve::AssetId _sourceAsset;
    CMTime _sourceTime;
    std::optional<ve::Project> _sourceProject;   // for _sourceAsset
    bool _sourceSharpening;                  // the sharpening the source monitor last drew with
    ve::AssetId _sourcePlaybackAsset;            // asset of the source controller's sequence
    bool _sourceUsesController;              // the source view shows the controller's picture
    BOOL _sourceMonitorVisible;              // see -setSourceMonitorVisible:
    std::map<ve::AssetId, ve::media::RoutedMediaInfo> _routing;

    ve::Project _project;
    std::unique_ptr<ve::UndoStack> _undo;
    uint64_t _changeBase;      // changeCount of earlier projects' undo stacks
    uint64_t _extraChanges;    // changes outside the undo stack (relinks on open)
    bool _metadataDirty;       // relinked paths not saved yet
    uint64_t _projectGeneration; // drops async results that belong to a replaced project
    uint64_t _idFloor; // highest IdGenerator value the project has reached (see FreshIds)
    std::vector<std::pair<ve::AssetId, size_t>> _lastUseCounts;
    NSArray<NSString *> *_loadWarnings;
    VERippleScope _rippleScope;
    NSMutableArray<dispatch_block_t> *_deferredImports; // imports waiting for a coalescing group
    NSString *_coalescingKey;
    NSString *_gestureEditKey; // set while performInCoalescingGroup:edit: runs its block

    std::map<ve::AssetId, ve::facade::AssetDetails> _details;
    std::set<ve::AssetId> _missing;
    NSMutableDictionary<NSNumber *, NSData *> *_bookmarks;
    NSData *_mediaFolderBookmark; // see -mediaFolderBookmark
    NSMutableArray<NSURL *> *_accessedURLs;
    NSURL *_projectURL;

    NSHashTable<id<VEEngineObserver>> *_observers;
    __weak VEPreviewView *_programView;
    __weak VEPreviewView *_outputView; // mirrors the program (a second display)
    dispatch_queue_t _probeQueue;
    dispatch_source_t _memoryPressureSource;
    double _mainThreadImportSeconds;
    os_log_t _log;

    VEExportHandle *_activeExport;
    NSURL *_exportAccessedURL; // security-scoped output URL accessed for the running export
}
@end

NS_ASSUME_NONNULL_BEGIN

// VEEngine.mm
@interface VEEngine ()
- (void)notifyModelChanged;
- (void)notifyAssetsChanged;
- (void)notifyThumbnailForAsset:(ve::AssetId)asset;
- (void)notifyWaveformForAsset:(ve::AssetId)asset;
@end

// VEEngine+Project.mm
@interface VEEngine (ProjectInternal)
- (void)stopAccessingURLs;
- (void)installProject:(ve::Project)project url:(nullable NSURL *)url;
- (void)resetToEmptyProjectNamed:(NSString *)name;
@end

// VEEngine+Snapshots.mm
@interface VEEngine (SnapshotsInternal)
- (const ve::Sequence &)activeSequence;
- (ve::SequenceId)sequenceId;
@end

// VEEngine+Media.mm
@interface VEEngine (MediaInternal)
- (void)probeDetailsForProjectAssets;
- (void)registerRouting:(const ve::media::RoutedMediaInfo &)routed
               forAsset:(ve::AssetId)asset
                   path:(const std::string &)path;
@end

// VEEngine+Undo.mm
@interface VEEngine (UndoInternal)
- (ve::EditResult)pushCommand:(std::unique_ptr<ve::Command>)command;
- (VEEditResult *)push:(std::unique_ptr<ve::Command>)command created:(NSArray<NSNumber *> * (^_Nullable)(void))created;
- (VEEditResult *)push:(std::unique_ptr<ve::Command>)command
               created:(NSArray<NSNumber *> * (^_Nullable)(void))created
                  note:(nullable NSString *)note;
- (VEEditResult *)pushRipple:(std::unique_ptr<ve::Command> (^)(ve::RippleScope scope))make
                     created:(NSArray<NSNumber *> * (^_Nullable)(void))created;
- (VEEditResult *)pushRipple:(std::unique_ptr<ve::Command> (^)(ve::RippleScope scope))make
                       scope:(VERippleScope)rippleScope
                     created:(NSArray<NSNumber *> * (^_Nullable)(void))created;
- (VEEditResult *)pushRipple:(std::unique_ptr<ve::Command> (^)(ve::RippleScope scope))make
                       scope:(VERippleScope)rippleScope
                     created:(NSArray<NSNumber *> * (^_Nullable)(void))created
                        note:(nullable NSString *)note;
- (void)closeCoalescingIfOpen;
- (void)flushDeferredImports;
@end

// VEEngine+Playback.mm
@interface VEEngine (PlaybackInternal)
- (void)publishPlaybackSnapshot;
- (void)observeController:(ve::playback::PlaybackController &)controller source:(BOOL)isSource;
- (void)pauseProgramIfRunning;
@end

// VEEngine+SourceMonitor.mm
@interface VEEngine (SourceMonitorInternal)
- (void)resetSourceMonitor;
- (void)syncSourceSharpening;
- (void)refreshSourcePicture;
- (void)notifySourcePlayback:(const ve::playback::PlaybackStatus &)status;
- (void)pauseSourceMonitorIfRunning;
- (void)updateSourceIdleLookahead;
@end

// VEEngine+Export.mm
@interface VEEngine (ExportInternal)
- (BOOL)refusesPlaybackForExport;
@end

NS_ASSUME_NONNULL_END
