// Private interface of VEEngine, shared by its implementation files: VEEngine.mm (lifetime,
// versions, observers, notifications) and one VEEngine+<Area>.mm per category of VEEngine.h. It
// holds the engine's instance variables, the helpers several files use and the private methods
// one file calls on another, grouped by the file that implements them.
// Private to the facade implementation: excluded from the framework's headers (project.yml).

#pragma once

#import "VEEngine.h"

#import "VEFacadeSupport+Internal.h"
#import "VETypes+Internal.h"

#include "../Edit/Command.h"
#include "../Edit/EditOps.h"
#include "../Edit/UndoStack.h"
#include "../Media/BackendRouter.h"
#include "../Media/FrameCache.h"
#include "../Model/Project.h"
#include "../Playback/PlaybackController.h"

#include <os/log.h>

#include <algorithm>
#include <climits>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <utility>
#include <vector>

// The classes VEEngine coordinates (each in its own VE<Name>+Internal.h, included by the files that
// use it); they know nothing of the engine.
@class VEExporter;
@class VEMediaLibrary;
@class VEProgramMonitor;
@class VESourceMonitor;

namespace ve::facade {

/// Shares of the frame cache budget the two decode pools may fill with lookahead windows. They
/// add up to the single pool's former 0.75, leaving the rest for scrubbed and pinned frames;
/// the program monitor gets the larger share (it plays multi-layer sequences).
constexpr double kProgramPoolBudgetShare = 0.5;
constexpr double kSourcePoolBudgetShare = 0.25;
/// An export's decode pool (the program and source shares plus this add up to 1).
constexpr double kExportPoolBudgetShare = 0.25;

/// Lanes of DecodePool::requestFrame: the program controller's layers use kProgramLaneBase + i,
/// the source monitor's scrub provider and controller their own ranges (on the source pool). The
/// engine hands the shares and lanes to the monitors' and the exporter's constructors or starts.
constexpr uint64_t kProgramLaneBase = 0;
constexpr uint64_t kSourceScrubLaneBase = uint64_t(1) << 40;
constexpr uint64_t kSourcePlaybackLaneBase = uint64_t(2) << 40;

NS_ASSUME_NONNULL_BEGIN

// Helpers several files use; each is defined in the file named after it.

/// An NSError of VEEngineErrorDomain with `message` as its description (VEEngine.mm).
VE_FACADE_HIDDEN NSError *makeError(VEEngineErrorCode code, NSString *message);
/// The facade's result for an engine edit result: makeEditResult without a span (VEEngine.mm).
VE_FACADE_HIDDEN VEEditResult *toVE(const EditResult &result, NSArray<NSNumber *> *created = @[],
                                    NSString *_Nullable note = nil);
/// Model ids as NSNumbers (int64), in order.
template <class IdType> VE_FACADE_HIDDEN NSArray<NSNumber *> *toNumbers(const std::vector<IdType> &ids) {
    NSMutableArray<NSNumber *> *numbers = [NSMutableArray arrayWithCapacity:ids.size()];
    for (const IdType &id : ids) {
        [numbers addObject:@(static_cast<int64_t>(id.value()))];
    }
    return numbers;
}
/// The model id a facade id names (0 is the invalid id in both).
VE_FACADE_HIDDEN inline ClipId toClipId(VEClipID id) {
    return ClipId(static_cast<ClipId::ValueType>(id));
}
VE_FACADE_HIDDEN inline TrackId toTrackId(VETrackID id) {
    return TrackId(static_cast<TrackId::ValueType>(id));
}
/// Span ids; transition ids (VETransitionID) are span ids too.
VE_FACADE_HIDDEN inline SpanId toSpanId(VESpanID id) {
    return SpanId(static_cast<SpanId::ValueType>(id));
}
VE_FACADE_HIDDEN inline AssetId toAssetId(VEAssetID id) {
    return AssetId(static_cast<AssetId::ValueType>(id));
}
/// `value` clamped into the range of int (lanes, frame steps from Swift's Int).
VE_FACADE_HIDDEN inline int clampToInt(NSInteger value) {
    return static_cast<int>(std::clamp<NSInteger>(value, INT_MIN, INT_MAX));
}
NS_ASSUME_NONNULL_END

} // namespace ve::facade

// ----- The engine's state -----
//
// The areas that own real state and lifecycle are classes of their own, each with its state private
// to its .mm and knowing nothing of the engine (VEExporter, VEMediaLibrary, VESourceMonitor,
// VEProgramMonitor; see their +Internal.h headers): the engine owns one instance of each and
// coordinates them. The rest is grouped by the file that owns it: only that file's methods change a
// struct's fields, and other files ask it through the private methods below. The one exception is
// construction: -initWithCacheDirectory: (VEEngine.mm) creates the services, the classes and the
// first undo stack. Everything here is main thread only unless a field says otherwise: the engine's
// methods run on the main thread (VE_ASSERT_MAIN), and the classes hand their results back on the
// main queue. The objects the pointers name (router, frame cache) are thread safe themselves.

namespace ve::facade {

/// The shared media services: the router and the frame cache every area decodes through (the
/// media library's probes and thumbnails, both monitors' pools and controllers, the exports), and
/// the media epoch the cache and the pools are in. A dependency the engine injects into the
/// classes that need it, not owned by any of them. Created by -initWithCacheDirectory:
/// (VEEngine.mm) and never replaced; afterwards only -beginMediaEpoch (VEEngine.mm, called on
/// New/Open) changes it, advancing `epoch`. Other files may call the router's and the cache's
/// methods (they are thread safe).
struct MediaServices {
    std::shared_ptr<media::BackendRouter> router;
    std::shared_ptr<media::FrameCache> frameCache;
    media::FrameCache::Epoch epoch = 0; // advanced on every New/Open (ids restart per project)
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

/// The undo history and the gesture in progress (VEEngine+Undo.mm; New/Open starts a new history
/// with startUndoHistory, an import finishing during a gesture waits with deferUntilCoalescingEnds:).
struct UndoState {
    std::unique_ptr<UndoStack> stack;
    uint64_t idFloor = 0; // highest IdGenerator value the project has reached (see FreshIds)
    NSString *_Nullable coalescingKey = nil;
    NSString *_Nullable gestureEditKey = nil; // set while performInCoalescingGroup:edit: runs its block
    // Imports that finished while a coalescing group was open (flushDeferredImports runs them).
    NSMutableArray<dispatch_block_t> *_Nonnull deferredImports = [NSMutableArray array];
};

} // namespace ve::facade

@interface VEEngine () {
    // The model. Only commands (VEEngine+Undo.mm) and New/Open (VEEngine+Project.mm, with the relinks
    // of an opened project's assets) change it.
    ve::Project _project;
    ve::facade::MediaServices _services;
    // What is known about the project's media files beyond the model: a class of its own
    // (VEMediaLibrary+Internal.h) that knows nothing of the engine. VEEngine+Media.mm imports
    // through it; Open, Save and New/Open (VEEngine+Project.mm) and the snapshots ask it.
    VEMediaLibrary *_media;
    double _mainThreadImportSeconds; // see -mainThreadImportSeconds (VEEngine+Media.mm)
    ve::facade::DocumentState _document;
    ve::facade::UndoState _undo;
    // The program monitor: a class of its own (VEProgramMonitor+Internal.h) that knows nothing of
    // the engine. VEEngine+Playback.mm drives it; model changes, New/Open, imports, exports,
    // memory pressure and the source monitor's transport reach it through its methods.
    VEProgramMonitor *_programMonitor;
    // The source monitor: a class of its own (VESourceMonitor+Internal.h) that knows nothing of
    // the engine. VEEngine+SourceMonitor.mm drives it; New/Open, imports, exports, memory pressure
    // and the program transport reach it through its methods.
    VESourceMonitor *_sourceMonitor;
    // The running export: a class of its own (VEExporter+Internal.h) that knows nothing of the
    // engine. VEEngine+Export.mm starts it, the engine's other files only ask and cancel it.
    VEExporter *_exporter;
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
/// Starts a new media epoch (New/Open): the frame cache drops every frame and refuses frames of
/// the old epoch, and both monitors' decode pools forget every asset (see forgetProjectMedia).
- (void)beginMediaEpoch;
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
/// Probes the project's present assets again for their details and routing (Open).
- (void)probeDetailsForProjectAssets;
/// Hands an asset's routing to both monitors' decode pools and controllers.
- (void)handRoutingToMonitors:(const ve::media::RoutedMediaInfo &)routed
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
/// As above, and `lateNote` (called only after the edit succeeded, so it can read the applied
/// command's report) adds its sentences after `note`'s.
- (VEEditResult *)push:(std::unique_ptr<ve::Command>)command
               created:(NSArray<NSNumber *> * (^_Nullable)(void))created
                  note:(nullable NSString *)note
              lateNote:(NSString *_Nullable (^_Nullable)(void))lateNote;
- (VEEditResult *)pushRipple:(std::unique_ptr<ve::Command> (^)(ve::RippleScope scope))make
                       scope:(VERippleScope)rippleScope
                     created:(NSArray<NSNumber *> * (^_Nullable)(void))created
                        note:(nullable NSString *)note
                    lateNote:(NSString *_Nullable (^_Nullable)(void))lateNote;
- (void)closeCoalescingIfOpen;
/// Runs `block` when the open coalescing group ends (flushDeferredImports).
- (void)deferUntilCoalescingEnds:(dispatch_block_t)block;
- (void)flushDeferredImports;
/// A fresh undo history for the project just installed (New/Open): no coalescing group, the id
/// floor at the project's generator.
- (void)startUndoHistory;
@end

// VEEngine+Playback.mm
@interface VEEngine (PlaybackInternal)
/// Hands the program monitor the model (every model change, and the first after New/Open).
- (void)publishPlaybackSnapshot;
/// Posts VEEnginePlaybackDidChangeNotification (and tells the observers) with `status`.
- (void)postPlaybackStatus:(VEPlaybackStatus *)status;
@end

// VEEngine+SourceMonitor.mm
@interface VEEngine (SourceMonitorInternal)
/// Follows a model change: clears the monitor when its asset was removed (the undo of its import)
/// and follows the project's sharpening.
- (void)sourceMonitorModelChanged;
/// Posts VEEngineSourcePlaybackDidChangeNotification (and tells the observers) with `status`.
- (void)postSourcePlaybackStatus:(VEPlaybackStatus *)status;
/// Allows the source monitor's stopped lookahead unless an export runs (export start and end).
- (void)updateSourceIdleLookahead;
@end

// VEEngine+Export.mm
@interface VEEngine (ExportInternal)
- (BOOL)refusesPlaybackForExport;
@end

NS_ASSUME_NONNULL_END
