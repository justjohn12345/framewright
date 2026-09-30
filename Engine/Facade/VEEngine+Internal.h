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

NS_ASSUME_NONNULL_END

} // namespace ve::facade

// ----- The engine's state -----
//
// Grouped by the file that owns it (creates, mutates and documents it). Everything here is main
// thread only unless a field says otherwise: the engine's methods run on the main thread
// (VE_ASSERT_MAIN), and the probe queue, the decode pools, the thumbnail and waveform services and
// the playback controllers hand their results back on the main queue. The objects the pointers name
// (router, frame cache, pools, services, controllers, frame provider) are thread safe themselves.

namespace ve::facade {

/// The media services behind every area. Created by -initWithCacheDirectory: (VEEngine.mm) and
/// never replaced; New/Open (VEEngine+Project.mm) starts a new media `epoch`.
struct MediaServices {
    std::shared_ptr<media::BackendRouter> router;
    std::shared_ptr<media::FrameCache> frameCache;
    media::FrameCache::Epoch epoch = 0; // advanced on every New/Open (ids restart per project)
    std::unique_ptr<thumbs::ThumbnailService> thumbnails;
    std::unique_ptr<thumbs::WaveformService> waveforms;
    // Concurrent (created by init): probes files and hands the results to the main queue.
    dispatch_queue_t _Null_unspecified probeQueue = nil;
};

/// What the engine knows about the project's media files beyond the model (VEEngine+Media.mm):
/// filled by imports and the background probes, by Open's bookmark resolution
/// (VEEngine+Project.mm), and cleared on New/Open.
struct AssetState {
    std::map<AssetId, media::RoutedMediaInfo> routing; // handed to every decode path (registerRouting)
    std::map<AssetId, AssetDetails> details;           // probe details not stored in the project file
    std::set<AssetId> missing;                         // files not found when the project was opened
    // Asset id -> security-scoped bookmark, saved with the project.
    NSMutableDictionary<NSNumber *, NSData *> *_Nonnull bookmarks = [NSMutableDictionary dictionary];
    // Security-scoped URLs accessed for this project (stopAccessingURLs ends the access).
    NSMutableArray<NSURL *> *_Nonnull accessedURLs = [NSMutableArray array];
    double mainThreadImportSeconds = 0; // see -mainThreadImportSeconds
};

/// The open project as a document (VEEngine+Project.mm): where it lives, its dirty state and what
/// loading it reported.
struct DocumentState {
    NSURL *_Nullable url = nil; // see -projectURL
    uint64_t generation = 0;    // drops async results that belong to a replaced project
    uint64_t changeBase = 0;    // changeCount of earlier projects' undo stacks
    uint64_t extraChanges = 0;  // changes outside the undo stack (relinks on open)
    bool metadataDirty = false; // relinked paths not saved yet
    NSArray<NSString *> *_Nonnull loadWarnings = @[];
    NSData *_Nullable mediaFolderBookmark = nil; // see -mediaFolderBookmark
};

/// The undo history and the gesture in progress (VEEngine+Undo.mm). New/Open
/// (VEEngine+Project.mm) replaces the stack.
struct UndoState {
    std::unique_ptr<UndoStack> stack;
    uint64_t idFloor = 0; // highest IdGenerator value the project has reached (see FreshIds)
    NSString *_Nullable coalescingKey = nil;
    NSString *_Nullable gestureEditKey = nil; // set while performInCoalescingGroup:edit: runs its block
    // Imports that finished while a coalescing group was open (flushDeferredImports runs them).
    NSMutableArray<dispatch_block_t> *_Nonnull deferredImports = [NSMutableArray array];
};

/// The program monitor (VEEngine+Playback.mm): the active sequence's playback controller on its
/// own decode pool, and the views showing it.
struct ProgramMonitorState {
    std::shared_ptr<media::DecodePool> pool;
    std::unique_ptr<playback::PlaybackController> playback;
    uint64_t generation = 0; // DocumentState::generation the controller's sequence belongs to
    bool published = false;  // the controller has the current project's sequence
    __weak VEPreviewView *_Nullable view = nil;
    __weak VEPreviewView *_Nullable outputView = nil; // mirrors the program (a second display)
};

/// The source monitor (VEEngine+SourceMonitor.mm): a pool of its own (a playback controller
/// replaces its pool's whole target set), a still provider for scrubbing and a controller over a
/// private one-clip project that is created when the monitor first plays.
struct SourceMonitorState {
    std::shared_ptr<media::DecodePool> pool;
    std::shared_ptr<ProgramFrameProvider> provider;
    std::unique_ptr<playback::PlaybackController> playback;
    __weak VEPreviewView *_Nullable view = nil;
    AssetId asset;
    CMTime time = kCMTimeZero;
    std::optional<Project> project; // for `asset`
    bool sharpening = true;         // what it last drew with (Project::sharpenScaledDownSources' default)
    AssetId playbackAsset;          // asset of the controller's sequence
    bool usesController = false;    // the view shows the controller's picture
    BOOL visible = YES;             // see -setSourceMonitorVisible:
};

/// The running export (VEEngine+Export.mm).
struct ExportState {
    VEExportHandle *_Nullable active = nil;
    NSURL *_Nullable accessedURL = nil; // security-scoped output URL accessed for the running export
};

} // namespace ve::facade

@interface VEEngine () {
    // The model. Only commands (VEEngine+Undo.mm) and New/Open (VEEngine+Project.mm, with the relinks
    // of an opened project's assets) change it.
    ve::Project _project;
    ve::facade::MediaServices _services;
    ve::facade::AssetState _assets;
    ve::facade::DocumentState _document;
    ve::facade::UndoState _undo;
    ve::facade::ProgramMonitorState _program;
    ve::facade::SourceMonitorState _source;
    ve::facade::ExportState _export;
    VERippleScope _rippleScope; // see -rippleScope (VEEngine+Edits.mm)

    // VEEngine.mm
    NSHashTable<id<VEEngineObserver>> *_observers;
    std::vector<std::pair<ve::AssetId, size_t>> _lastUseCounts; // posted by updateUseCounts
    dispatch_source_t _memoryPressureSource;
    os_log_t _log;
}
@end

NS_ASSUME_NONNULL_BEGIN

// VEEngine.mm
@interface VEEngine ()
- (void)notifyModelChanged;
- (void)notifyAssetsChanged;
/// notifyAssetsChanged, then notifyModelChanged: after a change that may touch the asset list.
- (void)notifyAssetsAndModelChanged;
/// Posts `name` (object: the engine) with `userInfo`, then calls `notify` with every observer that
/// implements `selector`, the VEEngineObserver method that mirrors the notification.
- (void)postNotification:(NSNotificationName)name
                userInfo:(nullable NSDictionary *)userInfo
          observerMethod:(SEL)selector
                  notify:(void(NS_NOESCAPE ^)(id<VEEngineObserver> observer))notify;
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
