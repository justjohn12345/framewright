// VEEngine: the engine facade for the Swift UI layer.
//
// One VEEngine owns one open project plus the media services behind it: the backend router
// (Apple + FFmpeg backends), frame cache, decode pool, thumbnail and waveform services.
//
// Rules:
// - Main thread only. Every instance method must be called on the main thread; a call from
//   another thread raises NSInternalInconsistencyException (in every build configuration).
//   Swift sees the class as @MainActor (NS_SWIFT_UI_ACTOR), so the compiler rejects such calls
//   there instead. Completion blocks and notifications are delivered on the main thread. The
//   last reference must also be released on the main thread: -dealloc detaches the monitor
//   views (AppKit work). The class properties (versions, license) may be read on any thread.
// - Nothing here blocks on media I/O. Model calls are synchronous and cheap; probing, decoding,
//   thumbnails and waveforms run on background threads and report back asynchronously.
// - Snapshots, never pointers: the info objects returned (VETypes.h) are immutable copies of
//   the model at the time of the call. After VEEngineModelDidChangeNotification, ask again.
// - Every model edit is an undoable command. Edits return a VEEditResult; a refused edit
//   changes nothing. `changeCount` increases with every change (edit, undo, redo, coalesced
//   drag step, import, asset removal, project load) and serves as the model version.
// - Continuous gestures: call beginCoalescingWithKey: before the first edit of a drag, make
//   every edit of the gesture inside performInCoalescingGroup:edit: with the same key, and call
//   endCoalescing on release (one undo step) or cancelCoalescing on Escape (reverts the drag).
//   Within the group each edit replaces the previous edit of the group, so express every step
//   relative to the state before the gesture (e.g. "move clip 7 to 12 s"); a group opened with
//   VECoalescingModeAccumulate instead applies each edit on top of the previous one and merges
//   them (a burst of keyboard nudges is one undo step). Only those tagged
//   edits join the group. Any other edit made while it is open (a menu command, a key) first
//   ends the group, committing the gesture as its own undo step, and then applies as a separate
//   step; the gesture's later edits are refused with VEEditErrorBusy (its group has ended), so
//   they can never replace or resurrect what the other edit did. (The app does not issue edit
//   commands during a gesture at all; this is the engine's guarantee.) An import that finishes
//   while a group is open is added when the group ends (endCoalescing, cancelCoalescing, undo,
//   redo); removeAsset: is refused with VEEditErrorBusy while a group is open.
// - Playback: the engine owns one playback controller for the active sequence (program monitor)
//   and one for the source monitor. Transport calls never block (each returns in well under a
//   millisecond); the state follows asynchronously through VEEnginePlaybackDidChangeNotification
//   (at most once per displayed frame). One monitor plays at a time: starting the program
//   (play, togglePlay, setRate:, shuttle) pauses the source monitor, and starting the source
//   monitor pauses the program. While an export runs (isExporting) playback does not start:
//   play, togglePlay (from paused), setRate: with a rate, the shuttles and the source monitor's
//   equivalents do nothing (pausing, stepping and scrubbing still work). The owner of a monitor view un-pauses it
//   (VEPreviewView.paused = NO) while the monitor's status isRunning, and keeps it paused
//   otherwise; the engine renders the paused picture itself.

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

#import <FramewrightEngine/VEExport.h>
#import <FramewrightEngine/VETypes.h>

@class VEEngine;
@class VEPreviewView;

NS_ASSUME_NONNULL_BEGIN

/// Posted after every model change. userInfo[VEEngineChangeCountKey]: NSNumber (uint64).
FOUNDATION_EXPORT NSNotificationName const VEEngineModelDidChangeNotification;
/// Posted when the asset list or an asset's details change (import, removal, probe results,
/// project load).
FOUNDATION_EXPORT NSNotificationName const VEEngineAssetsDidChangeNotification;
/// Posted when an asset's poster thumbnail finished generating after import.
/// userInfo[VEEngineAssetIDKey]: NSNumber (VEAssetID).
FOUNDATION_EXPORT NSNotificationName const VEEngineThumbnailDidBecomeAvailableNotification;
/// Posted when an asset's waveform peaks are available. userInfo[VEEngineAssetIDKey].
FOUNDATION_EXPORT NSNotificationName const VEEngineWaveformDidBecomeAvailableNotification;

/// Posted when the program monitor's playback state or position changes (at most once per
/// displayed frame while playing). userInfo[VEEnginePlaybackStatusKey]: VEPlaybackStatus.
FOUNDATION_EXPORT NSNotificationName const VEEnginePlaybackDidChangeNotification;
/// The same for the source monitor.
FOUNDATION_EXPORT NSNotificationName const VEEngineSourcePlaybackDidChangeNotification;
/// Posted (after the engine released its own caches) when the system reports memory pressure
/// or -handleMemoryPressure: is called; UI caches should shrink. userInfo[VEEngineCriticalKey]:
/// NSNumber (BOOL).
FOUNDATION_EXPORT NSNotificationName const VEEngineMemoryPressureNotification;

/// Posted (at most 10 times a second) while an export runs. userInfo[VEEngineExportProgressKey]:
/// VEExportProgress.
FOUNDATION_EXPORT NSNotificationName const VEEngineExportDidProgressNotification;
/// Posted when an export ends, right before its completion runs. userInfo[VEEngineExportSummaryKey]:
/// VEExportSummary on success, else userInfo[VEEngineExportErrorKey]: NSError.
FOUNDATION_EXPORT NSNotificationName const VEEngineExportDidFinishNotification;

FOUNDATION_EXPORT NSString *const VEEngineExportProgressKey;
FOUNDATION_EXPORT NSString *const VEEngineExportSummaryKey;
FOUNDATION_EXPORT NSString *const VEEngineExportErrorKey;
FOUNDATION_EXPORT NSString *const VEEngineChangeCountKey;
FOUNDATION_EXPORT NSString *const VEEngineAssetIDKey;
FOUNDATION_EXPORT NSString *const VEEnginePlaybackStatusKey;
FOUNDATION_EXPORT NSString *const VEEngineCriticalKey;

/// Error domain for NSErrors from the facade (open/save/import).
FOUNDATION_EXPORT NSErrorDomain const VEEngineErrorDomain;

typedef NS_ERROR_ENUM(VEEngineErrorDomain, VEEngineErrorCode) {
    VEEngineErrorReadFailed = 1,
    VEEngineErrorWriteFailed = 2,
    VEEngineErrorInvalidProject = 3,
    VEEngineErrorImportFailed = 4,
    /// The project was replaced (New, Open) before an import finished; nothing was added.
    VEEngineErrorProjectClosed = 5,
    /// An export failed while running (decode, encode, write or GPU error; see the description).
    VEEngineErrorExportFailed = 6,
    /// An export was cancelled (its temporary file is deleted; an existing output file is kept).
    VEEngineErrorExportCancelled = 7,
    /// An export was refused: media used by the sequence is missing or unreadable.
    VEEngineErrorMissingMedia = 8,
    /// An export was refused: the output file cannot be written.
    VEEngineErrorOutputNotWritable = 9,
    /// Refused because something else is in progress (an edit gesture, another export).
    VEEngineErrorBusy = 10,
    /// An export was refused: the settings are invalid or no encoder can write them (or the
    /// sequence is empty).
    VEEngineErrorExportUnsupported = 11,
};

/// Which tracks close or open time when an edit ripples (ripple delete, speed change, insert).
typedef NS_ENUM(NSInteger, VERippleScope) {
    /// Every unlocked track, so everything after the edit stays in sync. When another track
    /// has a clip in the way (VEEditErrorOverlap) the edit falls back to the synced tracks and
    /// says so in VEEditResult.note.
    VERippleScopeAllTracks = 0,
    /// Only the edited clips' tracks and the tracks of their linked partners.
    VERippleScopeSyncedTracks = 1,
};

/// How the edits of a coalescing group combine into its one undo step.
typedef NS_ENUM(NSInteger, VECoalescingMode) {
    /// Each edit replaces the previous edit of the group (drags: express every step relative to
    /// the state before the gesture).
    VECoalescingModeReplace = 0,
    /// Each edit applies on top of the previous one and their changes merge (repeated nudges:
    /// "x + 1" ten times is one undo step of +10; changes that cancel out leave no step).
    VECoalescingModeAccumulate = 1,
};

/// Options of -addTransitionFromClip:toClip:duration:options:.
typedef NS_OPTIONS(NSUInteger, VETransitionOptions) {
    VETransitionOptionNone = 0,
    /// Shorten the transition to what the cut allows (at least one frame) instead of refusing;
    /// the result's note says so. Still refused when not even one frame fits.
    VETransitionOptionFitToCut = 1 << 0,
    /// Also add a transition on the cut between the two clips' linked partners (the audio
    /// crossfade of a video dissolve) of the requested duration, in the same undo step. With
    /// FitToCut each of the two is fitted to its own cut independently (a tight audio cut never
    /// shortens the video dissolve, nor the other way round) and the note names each shortening.
    /// When the partners do not meet at a cut, or theirs cannot take the transition, only the
    /// requested one is added and the note says why.
    VETransitionOptionIncludeLinked = 1 << 1,
};

/// New parameters for several clips, applied by -applyClipParams: as one undo step.
/// Main thread only, like VEEngine (Swift sees it as @MainActor): build it where the edit is made.
NS_SWIFT_UI_ACTOR
@interface VEClipParamsBatch : NSObject
/// Sets the video parameters of a clip on a video track (replaces an earlier entry for it).
- (void)setVideoParams:(VEVideoParams)params forClip:(VEClipID)clipID;
/// Sets the audio parameters of a clip on an audio track (replaces an earlier entry for it).
- (void)setAudioParams:(VEAudioParams)params forClip:(VEClipID)clipID;
/// Number of clips in the batch.
@property (nonatomic, readonly) NSUInteger count;
@end

/// Alternative to the notifications: register with -addObserver:. All methods are optional
/// and called on the main thread.
@protocol VEEngineObserver <NSObject>
@optional
- (void)engine:(VEEngine *)engine modelDidChange:(uint64_t)changeCount;
- (void)engineAssetsDidChange:(VEEngine *)engine;
- (void)engine:(VEEngine *)engine thumbnailAvailableForAsset:(VEAssetID)assetID;
- (void)engine:(VEEngine *)engine waveformAvailableForAsset:(VEAssetID)assetID;
- (void)engine:(VEEngine *)engine playbackDidChange:(VEPlaybackStatus *)status;
- (void)engine:(VEEngine *)engine sourcePlaybackDidChange:(VEPlaybackStatus *)status;
@end

NS_SWIFT_UI_ACTOR
@interface VEEngine : NSObject

// MARK: Versions

/// Engine version, from the framework's CFBundleShortVersionString (e.g. "0.1.0").
/// Not named `version`: NSObject already has `+ (NSInteger)version` (NSCoder class versioning).
@property (class, nonatomic, readonly, copy) NSString *engineVersion NS_SWIFT_NONISOLATED;

/// Version of the FFmpeg libraries the engine is running against (av_version_info(), e.g. "7.1.5").
@property (class, nonatomic, readonly, copy) NSString *ffmpegVersion NS_SWIFT_NONISOLATED;

/// License string reported by the loaded libavcodec (avcodec_license()).
@property (class, nonatomic, readonly, copy) NSString *ffmpegLicense NS_SWIFT_NONISOLATED;

// MARK: Lifetime

/// Caches (thumbnails, waveforms) under Application Support/Framewright/Caches.
- (instancetype)init;
/// Caches under `cacheDirectory` (nil: no disk caches). Starts with a new untitled project.
- (instancetype)initWithCacheDirectory:(nullable NSURL *)cacheDirectory NS_DESIGNATED_INITIALIZER;

/// Registers a weakly held observer.
- (void)addObserver:(id<VEEngineObserver>)observer;
- (void)removeObserver:(id<VEEngineObserver>)observer;

// MARK: Project

/// Replaces the project with an empty one (one 1080p30 sequence, tracks V1 V2 / A1 A2).
- (void)newProjectWithName:(NSString *)name;
/// Loads a .framewright file. Asset paths are resolved through their stored security-scoped
/// bookmarks (a moved file is followed; resolution runs off the main thread, never mounts a
/// volume and is given at most a few seconds, after which the stored path is used); files that
/// cannot be found are listed in `missingAssetIDs`. On failure the current project is kept.
- (BOOL)openProjectAtURL:(NSURL *)url error:(NSError *_Nullable *_Nullable)error;
/// Writes the project as JSON (atomic write), with a security-scoped bookmark next to every
/// asset path, marks it clean and remembers `url` as `projectURL`.
- (BOOL)saveProjectToURL:(NSURL *)url error:(NSError *_Nullable *_Nullable)error;

@property (nonatomic, readonly, copy) NSString *projectName;
/// Where the project was last opened from or saved to; nil for a new project.
@property (nonatomic, readonly, nullable) NSURL *projectURL;
/// Unsaved changes since the last save/open/new.
@property (nonatomic, readonly) BOOL isDirty;
/// Model version; increases on every change.
@property (nonatomic, readonly) uint64_t changeCount;
/// Assets whose file was not found when the project was opened.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *missingAssetIDs;
/// What had to be adjusted to load the last opened project (unknown transition kinds, migrated
/// fields, ...); empty after New or a clean load.
@property (nonatomic, readonly, copy) NSArray<NSString *> *loadWarnings;
/// The project's JSON as it would be saved, without the bookmarks (diagnostics and tests).
@property (nonatomic, readonly, copy) NSString *projectJSON;

// MARK: Snapshots

@property (nonatomic, readonly) VESequenceInfo *sequence;
- (nullable VEClipInfo *)clipInfo:(VEClipID)clipID;
- (nullable VETrackInfo *)trackInfo:(VETrackID)trackID;
- (nullable VEAssetInfo *)assetInfo:(VEAssetID)assetID;
- (nullable VETransitionInfo *)transitionInfo:(VETransitionID)transitionID;
/// Every asset, in import order.
@property (nonatomic, readonly, copy) NSArray<VEAssetInfo *> *allAssets;
/// Tracks of the active sequence: video bottom to top, then audio.
@property (nonatomic, readonly, copy) NSArray<VETrackInfo *> *allTracks;
/// Clips of one track in timeline order (empty for an unknown track).
- (NSArray<VEClipInfo *> *)clipsOnTrack:(VETrackID)trackID;
/// Every clip of the active sequence.
@property (nonatomic, readonly, copy) NSArray<VEClipInfo *> *allClips;
/// Clips covering `time` (video bottom to top, then audio).
- (NSArray<NSNumber *> *)clipIDsAtTime:(CMTime)time;

// MARK: Media

/// Probes the files on a background queue, then (on the main thread) adds the playable ones
/// to the project as one undoable "Import" step, registers them with the decode pool and
/// starts poster thumbnail and waveform generation. A file already in the project is not
/// added twice (its existing asset is reported). `completion` runs on the main thread with the
/// imported (or already present) assets and one NSError per file that failed. If the project is
/// replaced (New, Open) before the probe finishes, nothing is added and every file reports
/// VEEngineErrorProjectClosed. While a coalescing group is open the import waits for it to end.
- (void)importMediaAtURLs:(NSArray<NSURL *> *)urls
               completion:(nullable void (^)(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors))completion;
/// Imports whose files were probed and that wait for the open coalescing group to end
/// (diagnostics and tests).
@property (nonatomic, readonly) NSUInteger deferredImportCount;
/// Removes an asset (undoable). Refused while any clip of any sequence uses it, and while a
/// coalescing group is open.
- (VEEditResult *)removeAsset:(VEAssetID)assetID;

/// A thumbnail of the asset's picture at source time `time`, longest side <= maxDimension
/// pixels. `completion` runs on the main thread with the image or an error.
- (void)thumbnailForAsset:(VEAssetID)assetID
                   atTime:(CMTime)time
             maxDimension:(NSInteger)maxDimension
               completion:(void (^)(CGImageRef _Nullable image, NSError *_Nullable error))completion;
/// Audio peaks of the asset (computed once, cached in memory and on disk).
- (void)waveformForAsset:(VEAssetID)assetID
              completion:(void (^)(VEWaveform *_Nullable waveform, NSError *_Nullable error))completion;
/// The peaks if already in memory, else nil (does not start a computation).
- (nullable VEWaveform *)cachedWaveformForAsset:(VEAssetID)assetID;

/// VideoToolbox capabilities.
@property (nonatomic, readonly) VEHardwareCaps *hardwareCaps;
/// Registered decoder backends in priority order ("apple", "ffmpeg").
@property (nonatomic, readonly, copy) NSArray<NSString *> *backendNames;
/// Backend preferred for new probes and decoders; nil = automatic routing.
@property (nonatomic, copy, nullable) NSString *preferredBackend;
/// Frame cache budget in bytes (default 512 MB).
@property (nonatomic) NSUInteger frameCacheBudgetBytes;
/// Releases what is only a cache: frame cache (to a fraction under warning, all unpinned
/// frames when critical), preview texture and compositor scratch memory of the attached
/// monitors, in-memory thumbnails and waveforms; then posts VEEngineMemoryPressureNotification.
/// Called automatically on system memory pressure.
- (void)handleMemoryPressure:(BOOL)critical;

/// Main-thread time spent in import bookkeeping since the engine was created (seconds;
/// diagnostics: import must never stall the UI).
@property (nonatomic, readonly) double mainThreadImportSeconds;

// MARK: Edits (all undoable; ids of 0 mean "none")

/// Inserts the asset at `time`, rippling later clips right. The video part goes on
/// `videoTrackID` and the audio part on `audioTrackID` (linked); pass 0 to skip a part.
/// `sourceIn`/`sourceOut` select the used range (kCMTimeInvalid: the whole media).
- (VEEditResult *)insertAsset:(VEAssetID)assetID
                       atTime:(CMTime)time
                   videoTrack:(VETrackID)videoTrackID
                   audioTrack:(VETrackID)audioTrackID
                     sourceIn:(CMTime)sourceIn
                    sourceOut:(CMTime)sourceOut;
/// Like insert, but overwrites what is under the new clips instead of rippling.
- (VEEditResult *)overwriteAsset:(VEAssetID)assetID
                          atTime:(CMTime)time
                      videoTrack:(VETrackID)videoTrackID
                      audioTrack:(VETrackID)audioTrackID
                        sourceIn:(CMTime)sourceIn
                       sourceOut:(CMTime)sourceOut;
/// Moves one clip (its linked partner follows in time) with overwrite semantics.
- (VEEditResult *)moveClip:(VEClipID)clipID toTrack:(VETrackID)trackID start:(CMTime)start;
/// Moves several clips by `delta` and `trackOffset` tracks within their kind (linked partners
/// follow in time). One undo step. Inside a coalescing group the offsets are relative to the
/// positions when the group began, so a drag passes its total offset on every step. Every clip
/// is lifted before any is placed, so the moved clips never cut each other; refused if two of
/// them would overlap.
- (VEEditResult *)moveClips:(NSArray<NSNumber *> *)clipIDs byTime:(CMTime)delta trackOffset:(NSInteger)trackOffset;
/// Like moveClips:byTime:trackOffset:, but only clips on tracks of `kind` change tracks (a drag
/// that moves between video rows keeps the selected audio clips on their tracks).
- (VEEditResult *)moveClips:(NSArray<NSNumber *> *)clipIDs
                     byTime:(CMTime)delta
                trackOffset:(NSInteger)trackOffset
                 ofTrackKind:(VETrackKind)kind;
/// Moves the clip's start (end fixed). `clamp` limits the time to what is possible instead of refusing.
- (VEEditResult *)trimClipHead:(VEClipID)clipID toTime:(CMTime)time clamp:(BOOL)clamp;
/// Moves the clip's end (start fixed).
- (VEEditResult *)trimClipTail:(VEClipID)clipID toTime:(CMTime)time clamp:(BOOL)clamp;
- (VEEditResult *)splitClip:(VEClipID)clipID atTime:(CMTime)time;
/// Splits the given clips at `time` (clips not spanning `time` are skipped); an empty list
/// splits every clip under `time` on unlocked tracks. One undo step. A split inside a
/// transition is refused (VEEditErrorInsideTransition).
- (VEEditResult *)splitClips:(NSArray<NSNumber *> *)clipIDs atTime:(CMTime)time;
/// Like splitClips:atTime:, but with `breakingTransitions` a transition around the split point
/// is removed (listed in droppedTransitionIDs) instead of refusing.
- (VEEditResult *)splitClips:(NSArray<NSNumber *> *)clipIDs
                      atTime:(CMTime)time
         breakingTransitions:(BOOL)breakingTransitions;
/// Removes clips (and their linked partners), leaving gaps.
- (VEEditResult *)removeClips:(NSArray<NSNumber *> *)clipIDs;
/// Removes clips and closes the gaps on the tracks `rippleScope` chooses.
- (VEEditResult *)rippleDeleteClips:(NSArray<NSNumber *> *)clipIDs;
/// Tracks that move with ripple edits (ripple delete, speed changes, insert). Default AllTracks.
@property (nonatomic) VERippleScope rippleScope;
- (VEEditResult *)setVideoParams:(VEVideoParams)params forClip:(VEClipID)clipID;
- (VEEditResult *)setAudioParams:(VEAudioParams)params forClip:(VEClipID)clipID;
/// Constant speed (0.01...100, approximated by a fraction with a denominator <= 1000); later
/// clips ripple by the change in duration (see rippleScope).
/// Sets the parameters of every clip in `batch` as one undo step (a multi-selection change).
/// Video parameters apply to clips on video tracks and audio parameters to clips on audio
/// tracks only (VEEditErrorTrackKindMismatch otherwise); refused as a whole when any clip is
/// missing, locked or given invalid parameters. Inside an Accumulate group successive batches
/// merge into one step.
- (VEEditResult *)applyClipParams:(VEClipParamsBatch *)batch;
- (VEEditResult *)setSpeed:(double)speed forClip:(VEClipID)clipID;
/// Exact speed numerator / denominator (e.g. 1/3); refused unless it reduces to a valid speed.
- (VEEditResult *)setSpeedNumerator:(int64_t)numerator denominator:(int64_t)denominator forClip:(VEClipID)clipID;
/// Sets the exact speed of several clips (their linked partners follow) as one undo step. With
/// `ripple`, later clips move by the change in duration on the tracks `scope` chooses (AllTracks
/// falls back to the synced tracks when another track is in the way, and says so in the note);
/// without it a clip that would run into the next one is refused. Stills are refused.
- (VEEditResult *)setSpeedNumerator:(int64_t)numerator
                        denominator:(int64_t)denominator
                           forClips:(NSArray<NSNumber *> *)clipIDs
                             ripple:(BOOL)ripple
                              scope:(VERippleScope)scope;
/// Adds a cross dissolve (video track) or constant-power crossfade (audio track), centred on the
/// cut where `fromClipID` ends and `toClipID` starts. A refusal for lack of media or length says
/// what limits the cut and the longest transition it allows.
- (VEEditResult *)addTransitionFromClip:(VEClipID)fromClipID toClip:(VEClipID)toClipID duration:(CMTime)duration;
/// The same with options (fit to the cut, include the linked partners' cut). createdIDs lists
/// the requested transition first, then the partners' one if it was added.
- (VEEditResult *)addTransitionFromClip:(VEClipID)fromClipID
                                 toClip:(VEClipID)toClipID
                               duration:(CMTime)duration
                                options:(VETransitionOptions)options;
/// The longest transition the cut between the two clips can take and what stops a longer one
/// (maximumFrames 0 with the reason when none fits, e.g. the cut already has a transition).
- (VETransitionLimit *)transitionLimitFromClip:(VEClipID)fromClipID toClip:(VEClipID)toClipID;
/// The longest duration an existing transition can be given.
- (VETransitionLimit *)transitionLimitForTransition:(VETransitionID)transitionID;
- (VEEditResult *)removeTransition:(VETransitionID)transitionID;
/// Refused beyond the cut's limit with the same explanation as adding.
- (VEEditResult *)setDuration:(CMTime)duration forTransition:(VETransitionID)transitionID;
/// A dissolve and its linked audio crossfade: the transition on the cut between the linked
/// partners of `transitionID`'s two clips (either way round), or 0 when there is none (a clip is
/// unlinked, the partners do not meet at a cut, or no transition joins them).
- (VETransitionID)linkedTransitionForTransition:(VETransitionID)transitionID;
/// Removes the transition and, with `includingLinked`, its linked transition too, as one undo
/// step ("Remove Transitions"). A linked transition on a locked track is kept (the note says so).
- (VEEditResult *)removeTransition:(VETransitionID)transitionID includingLinked:(BOOL)includingLinked;
/// Sets the transition's duration and, with `includingLinked`, gives its linked transition the
/// same duration fitted to that transition's own cut (the note names a shortening, or why it was
/// left alone: no room at all, a locked track), as one undo step. Refused like
/// setDuration:forTransition: when the transition itself does not take the duration. Inside a
/// coalescing group (a handle drag, inspector nudges) the steps coalesce like single changes.
- (VEEditResult *)setDuration:(CMTime)duration
                forTransition:(VETransitionID)transitionID
              includingLinked:(BOOL)includingLinked;
- (VEEditResult *)linkClip:(VEClipID)clipID withClip:(VEClipID)otherClipID;
- (VEEditResult *)unlinkClip:(VEClipID)clipID;
/// Adds a track on top of its kind (empty name: "V<n>"/"A<n>").
- (VEEditResult *)addTrackOfKind:(VETrackKind)kind name:(nullable NSString *)name;
- (VEEditResult *)removeTrack:(VETrackID)trackID;
- (VEEditResult *)setTrack:(VETrackID)trackID muted:(BOOL)muted;
- (VEEditResult *)setTrack:(VETrackID)trackID solo:(BOOL)solo;
- (VEEditResult *)setTrack:(VETrackID)trackID locked:(BOOL)locked;
- (VEEditResult *)renameTrack:(VETrackID)trackID to:(NSString *)name;

// MARK: Undo

/// Same as beginCoalescingWithKey:mode: with VECoalescingModeReplace.
- (void)beginCoalescingWithKey:(NSString *)key;
/// Opens a coalescing group (ending any open one first). See the rules at the top of this file.
- (void)beginCoalescingWithKey:(NSString *)key mode:(VECoalescingMode)mode;
/// Key of the open coalescing group, or nil.
@property (nonatomic, readonly, copy, nullable) NSString *coalescingKey;
/// Runs `edit` (which calls edit methods of this engine) as a step of the open coalescing group
/// `key`: only edits made inside it join the group (see the rules above). Refused with
/// VEEditErrorBusy, without running `edit`, when no group with that key is open (it was never
/// begun, or another edit ended it). Returns what `edit` returned.
- (VEEditResult *)performInCoalescingGroup:(NSString *)key
                                      edit:(NS_NOESCAPE VEEditResult * (^)(void))edit
    NS_SWIFT_NAME(performInCoalescingGroup(_:edit:));
- (void)endCoalescing;
/// Reverts the edits of the open coalescing group and closes it.
- (void)cancelCoalescing;
@property (nonatomic, readonly) BOOL isCoalescing;
- (BOOL)undo;
- (BOOL)redo;
@property (nonatomic, readonly) BOOL canUndo;
@property (nonatomic, readonly) BOOL canRedo;
/// "Move Clip", ... or "" when there is nothing to undo/redo.
@property (nonatomic, readonly, copy) NSString *undoActionName;
@property (nonatomic, readonly, copy) NSString *redoActionName;

// MARK: Program monitor and playback

/// Shows the active sequence in `view`: installs the playback controller's frame source (the
/// paused picture at currentTime, and the playing picture); pass nil to detach. Keep the view
/// paused while the playback status is not running (see the rules above).
- (void)attachProgramView:(nullable VEPreviewView *)view NS_SWIFT_NAME(attachProgramView(_:));
/// The program monitor view, if attached.
@property (nonatomic, readonly, weak, nullable) VEPreviewView *programView;
/// Mirrors the program monitor in a second view (a full-screen output window on another
/// display): the same playback controller drives both, the pictures are decoded once and each
/// view maps them to its own textures, and both show the same frame of the same clock. Unlike
/// the program view, the engine runs and pauses this view's render loop itself (running while
/// the program plays or pre-rolls) and renders its paused picture; playback is refused while an
/// export runs, as for the monitors. Replaces a previously attached output view. The view's
/// playback counters are not added to playbackStats (the program view's are the HUD's).
- (void)attachOutputView:(VEPreviewView *)view NS_SWIFT_NAME(attachOutputView(_:));
/// Detaches the output view (it stops showing frames and its render loop is paused).
- (void)detachOutputView;
/// The attached output view, if any.
@property (nonatomic, readonly, weak, nullable) VEPreviewView *outputView;
/// Same as seekToTime: (kept for callers that only show stills).
- (void)showProgramFrameAtTime:(CMTime)time;

- (void)play;
- (void)pause;
- (void)togglePlay;
/// Moves the playhead (while playing: continues from there after a short pre-roll).
- (void)seekToTime:(CMTime)time;
/// Plays at `rate` in [-8, 8] (0 pauses). Audio plays at 1x and 2x.
- (void)setRate:(double)rate;
/// L: 1x, then 2x, 4x, 8x on repeated presses.
- (void)shuttleForward;
/// J: -1x, then -2x, -4x, -8x.
- (void)shuttleReverse;
/// K: stops.
- (void)shuttleStop;
/// Pauses and moves by `frames` sequence frames.
- (void)stepFrames:(NSInteger)frames;
/// Shows the frame at `time` as soon as it can be decoded (coalescing), without audio; call
/// endScrub when the gesture ends.
- (void)scrubToTime:(CMTime)time;
- (void)endScrub;
@property (nonatomic, getter=isMuted) BOOL muted;
@property (nonatomic, readonly) VEPlaybackState playbackState;
@property (nonatomic, readonly) double playbackRate;
/// The playhead on the sequence frame grid (the clock while playing).
@property (nonatomic, readonly) CMTime currentTime;
/// The most recent audio problem ("" when none).
@property (nonatomic, readonly, copy) NSString *playbackError;
@property (nonatomic, readonly) VEPlaybackStatus *playbackStatus;
@property (nonatomic, readonly) VEPlaybackStats *playbackStats;

// MARK: Export

/// Which presets can be exported at `width` x `height` on this machine and whether their encoder
/// runs in hardware (VideoToolbox asked at that size; hardware encoders are size dependent).
/// The answer is cached per size; the first query of a size takes a few milliseconds, which
/// exportFormatsForWidth:height:completion: spends off the main thread.
- (NSArray<VEExportFormat *> *)exportFormatsForWidth:(NSInteger)width height:(NSInteger)height;
- (void)exportFormatsForWidth:(NSInteger)width
                       height:(NSInteger)height
                   completion:(void (^)(NSArray<VEExportFormat *> *formats))completion;
/// The output size `settings` give the active sequence.
- (CGSize)exportSizeForSettings:(VEExportSettings *)settings;
/// Approximate size in bytes of an export of the active sequence with `settings` (from the bit
/// rate, or for quality settings a typical bits-per-pixel figure; 0 for an empty sequence).
- (int64_t)estimatedFileSizeForSettings:(VEExportSettings *)settings;
/// Starts exporting the active sequence to `outputURL` (security-scoped URLs from a save panel
/// are accessed for the export's lifetime). The movie is written to a temporary file on the
/// same volume and moved to `outputURL` only once it is complete, replacing a file there then; a
/// cancelled or failed export deletes the temporary file and leaves an existing file untouched. Refused, returning nil with
/// an error and without creating any file, when: a coalescing group is open or another export
/// runs (VEEngineErrorBusy), the settings are invalid, no encoder takes them or the sequence is
/// empty (VEEngineErrorExportUnsupported), media a playing clip uses is missing
/// (VEEngineErrorMissingMedia), or the output cannot be written (VEEngineErrorOutputNotWritable).
/// Otherwise both monitors pause and the export runs in the background with its own decoders
/// (the monitors keep theirs); edits made meanwhile do not affect it (it renders the sequence as
/// it was when it started). `progress` (at most 10 Hz) and `completion` (once) run on the main
/// thread; the completion gets the summary, or an error (VEEngineErrorExportCancelled after
/// -[VEExportHandle cancel], VEEngineErrorExportFailed with the reason otherwise). The output
/// must not be any of the project's media (VEEngineErrorExportUnsupported). Unreadable media is
/// VEEngineErrorMissingMedia too. New/Open cancels a running export.
- (nullable VEExportHandle *)beginExportWithSettings:(VEExportSettings *)settings
                                           outputURL:(NSURL *)outputURL
                                            progress:(nullable void (^)(VEExportProgress *progress))progress
                                          completion:(void (^)(VEExportSummary *_Nullable summary,
                                                               NSError *_Nullable error))completion
                                               error:(NSError *_Nullable *_Nullable)error;
/// The running export, or nil.
@property (nonatomic, readonly, nullable) VEExportHandle *activeExport;
@property (nonatomic, readonly) BOOL isExporting;

// MARK: Source monitor

/// Shows the source monitor's asset in `view` (nil detaches).
- (void)attachSourceView:(nullable VEPreviewView *)view NS_SWIFT_NAME(attachSourceView(_:));
/// Shows `assetID` at source time `time` (snapped down to the asset's frame grid; 0 clears the
/// monitor). Scrubbing: the newest request wins. Stops source playback when the asset changes.
- (void)sourceMonitorShowAsset:(VEAssetID)assetID atTime:(CMTime)time;
@property (nonatomic, readonly) VEAssetID sourceMonitorAssetID;
/// The shown source time (the clock while the source monitor plays).
@property (nonatomic, readonly) CMTime sourceMonitorTime;
@property (nonatomic, readonly) VEPlaybackState sourceMonitorPlaybackState;
@property (nonatomic, readonly) VEPlaybackStatus *sourceMonitorPlaybackStatus;
/// `time` snapped down to the frame grid of `assetID` (its nominal frame duration; the
/// sequence's for stills and audio), clamped to the media.
- (CMTime)frameTimeForAsset:(VEAssetID)assetID atTime:(CMTime)time;
/// Source monitor transport over the whole asset (video and audio), like the program's.
- (void)sourceMonitorTogglePlay;
- (void)sourceMonitorPause;
- (void)sourceMonitorShuttleForward;
- (void)sourceMonitorShuttleReverse;
- (void)sourceMonitorStepFrames:(NSInteger)frames;
/// Whether the source monitor is on screen (default YES; the app mirrors its View > Show Source
/// Monitor setting here). While it is hidden, and while an export runs, the source monitor's
/// playback controller keeps no stopped lookahead: its decode pool holds no streams (decoders or
/// lookahead frames). Once it is shown and no export runs, the lookahead resumes at its paused
/// frame. Hiding does not pause it; the app pauses it first (-sourceMonitorPause).
@property (nonatomic) BOOL sourceMonitorVisible;
/// The source monitor's playback counters (all zero until it first plays), e.g. its pool's
/// decodeStreams.
@property (nonatomic, readonly) VEPlaybackStats *sourceMonitorPlaybackStats;

@end

NS_ASSUME_NONNULL_END
