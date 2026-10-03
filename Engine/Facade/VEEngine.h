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

// Defined wherever this header is included: the classes the engine coordinates (VEExporter,
// VEMediaLibrary, VESourceMonitor, VEProgramMonitor) refuse to compile with it (#error), so none of them
// can come to depend on the engine.
#define VE_ENGINE_HEADER_INCLUDED 1

@class VEEngine;
@class VEPreviewView;
@class VEWaveformView;

NS_ASSUME_NONNULL_BEGIN

/// Posted after every model change. userInfo[VEEngineChangeCountKey]: NSNumber (uint64).
FOUNDATION_EXPORT NSNotificationName const VEEngineModelDidChangeNotification;
/// Posted when the asset list or an asset's details change (import, removal, probe results,
/// project load).
FOUNDATION_EXPORT NSNotificationName const VEEngineAssetsDidChangeNotification;
/// Posted when the fonts installed on this Mac change (Font Book activated or deactivated one): titles were drawn
/// again with the fonts there are now, and VETitleFont.available and missingTitleFonts may have changed.
FOUNDATION_EXPORT NSNotificationName const VEEngineTitleFontsDidChangeNotification;
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
/// Sets the static video parameters of a clip on a video track (replaces an earlier entry for it);
/// the clip's spans stay (they compose onto the static values).
- (void)setVideoParams:(VEVideoParams)params forClip:(VEClipID)clipID;
/// Sets the audio parameters of a clip on an audio track (replaces an earlier entry for it): its
/// gain and its lane-0 fades (see VEAudioParams).
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

// The API is the class and one category per area below; each area is implemented in
// VEEngine+<Area>.mm, and VEEngine.mm has the lifetime. Swift sees them as one @MainActor class (the
// members of a category of an NS_SWIFT_UI_ACTOR class are main-actor isolated too). A category method
// that takes a completion block is marked NS_SWIFT_UI_ACTOR itself: without it Swift would import the
// block as @Sendable (the class attribute does not reach it), although it runs on the main thread.
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

@end

// MARK: Project

@interface VEEngine (Project)

/// Replaces the project with an empty one: one sequence (tracks V1 V2 / A1 A2) at 1920x1080, 30 fps,
/// 48 kHz, not configured (VESequenceInfo.configured): the first video clip placed on it sets its
/// size and frame rate (see insertAsset:...).
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
/// A bookmark (security-scoped where possible) of the folder the app keeps media received from
/// Photos in, stored with the project (saved next to the asset bookmarks, read back on open) so
/// the app need not ask again; nil when none was chosen. New and Open reset it; setting a
/// different value is an unsaved change of the project (not an undo step). A value that cannot be
/// read on open is left out with a load warning. The engine saves whatever is set; the app stores
/// only a folder the user chose (the "Media" folder next to the project is derived from
/// `projectURL` every time and never stored, so a project saved elsewhere or a copied project
/// folder uses its own) and clears a stored folder that is the Media folder next to the project's
/// old location before a Save As to another folder.
@property (nonatomic, copy, nullable) NSData *mediaFolderBookmark;

@end

// MARK: Snapshots

@interface VEEngine (Snapshots)

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

@end

// MARK: Sequence settings

@interface VEEngine (SequenceSettings)

/// The active sequence's size, frame rate and audio sample rate, and the project's sharpening.
@property (nonatomic, readonly) VESequenceSettings *sequenceSettings;
/// The frame rates a sequence is offered and adopts, slowest first (NSValue CMTime frame durations):
/// 23.976, 24, 25, 29.97, 30, 50, 59.94 and 60 fps.
@property (class, nonatomic, readonly, copy) NSArray<NSValue *> *standardSequenceFrameDurations NS_SWIFT_NONISOLATED;
/// "29.97", "25", "23.976" (another rate to 3 decimals).
+ (NSString *)nameForFrameDuration:(CMTime)frameDuration NS_SWIFT_NONISOLATED NS_SWIFT_NAME(name(for:));
/// What -applySequenceSettings: would do with `settings`, without changing anything: the sentences
/// naming what changes for the clips (a size change rescales every placement so the pictures stay
/// the same; a frame-rate change moves clip edges to the new frame grid and keeps transitions'
/// frame counts, shortening or removing the ones that no longer fit), whether a confirmation is due
/// (the size or frame rate changes and the sequence has clips), or why they are refused.
- (VESequenceSettingsPreview *)previewSequenceSettings:(VESequenceSettings *)settings;
/// Applies `settings` to the active sequence and the project as one undo step ("Sequence Settings"):
/// SetSequenceFormat's conform (EditOps.h) and the sharpening; the sequence is configured afterwards
/// (it no longer adopts its first video clip's settings). Refused like the preview says.
- (VEEditResult *)applySequenceSettings:(VESequenceSettings *)settings;
/// "Sharpen scaled-down sources" (default YES): a picture drawn smaller than 3/4 of its size gets an
/// unsharp mask after its Lanczos pre-scale, in the monitors, the output display and the export.
@property (nonatomic, readonly) BOOL sharpenScaledDownSources;
/// Sets it as an undo step.
- (VEEditResult *)setSharpenScaledDownSources:(BOOL)sharpen;

@end

// MARK: Media

@interface VEEngine (Media)

/// Probes the files on a background queue, then (on the main thread) adds the playable ones
/// to the project as one undoable "Import" step, registers them with the decode pool and
/// starts poster thumbnail and waveform generation. A file already in the project is not
/// added twice (its existing asset is reported). `completion` runs on the main thread with the
/// imported (or already present) assets and one NSError per file that failed. If the project is
/// replaced (New, Open) before the probe finishes, nothing is added and every file reports
/// VEEngineErrorProjectClosed. While a coalescing group is open the import waits for it to end.
- (void)importMediaAtURLs:(NSArray<NSURL *> *)urls
               completion:(nullable void (^)(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors))completion
    NS_SWIFT_UI_ACTOR;
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
               completion:(void (^)(CGImageRef _Nullable image, NSError *_Nullable error))completion
    NS_SWIFT_UI_ACTOR;
/// Audio peaks of the asset (computed once, cached in memory and on disk).
- (void)waveformForAsset:(VEAssetID)assetID
              completion:(void (^)(VEWaveform *_Nullable waveform, NSError *_Nullable error))completion
    NS_SWIFT_UI_ACTOR;
/// The peaks if already in memory, else nil (does not start a computation).
- (nullable VEWaveform *)cachedWaveformForAsset:(VEAssetID)assetID;
/// Blocks until the thumbnail and waveform services have no request queued or in progress (the disk
/// cache file of each finished one written), or until `timeout` seconds pass; NO on timeout. Their
/// completions may still be on their way to the main queue. For tests, which delete the media files
/// and the cache directory afterwards (work still running would create the directory again).
- (BOOL)waitUntilMediaWorkIsIdle:(NSTimeInterval)timeout NS_SWIFT_NAME(waitUntilMediaWorkIsIdle(timeout:));

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

@end

// MARK: Edits (all undoable; ids of 0 mean "none")

@interface VEEngine (Edits)

/// Inserts the asset at `time`, rippling later clips right. The video part goes on
/// `videoTrackID` and the audio part on `audioTrackID` (linked); pass 0 to skip a part.
/// `sourceIn`/`sourceOut` select the used range (kCMTimeInvalid: the whole media).
/// The first video clip placed on a sequence that is not configured (a new project's) sets the
/// sequence's size (the picture's displayed size, after its rotation) and frame rate (the nearest
/// standard rate, see Sequence.h standardFrameDurationFor) in the same undo step, and configures it;
/// clips already on it (stills, sound) are conformed as -applySequenceSettings: does, and `time` is
/// taken on the new frame grid. Placing a still or only the sound never does. The result's note
/// names the settings taken.
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
/// transition is refused (VEEditErrorInsideTransition). The result's dividedSpanIDs pair each
/// effect span the cut divided with its right piece's part.
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
/// Sets the clip's static video parameters (VEClipInfo.videoParams); its spans stay and compose
/// onto them.
- (VEEditResult *)setVideoParams:(VEVideoParams)params forClip:(VEClipID)clipID;
/// Sets the clip's gain and its lane-0 fades (see VEAudioParams), in one undo step.
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
/// Makes the clips play their media backwards (`reversed` YES) or forwards again, their linked
/// partners with them, as one undo step ("Reverse Clip" / "Play Clip Forward"; see
/// VEClipInfo.reversed). A clip keeps its place, length, speed and spans and shows the same media in
/// the other order; a dissolve whose media beyond its cut is not there on the new side is removed
/// (droppedTransitionIDs). Clips already in that state are left alone. Refused: a still
/// (VEEditErrorInvalidArgument, nothing changes), a missing clip, a locked track.
- (VEEditResult *)setReversed:(BOOL)reversed forClips:(NSArray<NSNumber *> *)clipIDs
    NS_SWIFT_NAME(setReversed(_:forClips:));

- (VEEditResult *)linkClip:(VEClipID)clipID withClip:(VEClipID)otherClipID;
- (VEEditResult *)unlinkClip:(VEClipID)clipID;
/// Adds a track on top of its kind (empty name: "V<n>"/"A<n>").
- (VEEditResult *)addTrackOfKind:(VETrackKind)kind name:(nullable NSString *)name;
- (VEEditResult *)removeTrack:(VETrackID)trackID;
- (VEEditResult *)setTrack:(VETrackID)trackID muted:(BOOL)muted;
- (VEEditResult *)setTrack:(VETrackID)trackID solo:(BOOL)solo;
- (VEEditResult *)setTrack:(VETrackID)trackID locked:(BOOL)locked;
- (VEEditResult *)renameTrack:(VETrackID)trackID to:(NSString *)name;

@end

// MARK: Transitions
//
// A transition is a lane-0 span of the clip that owns it (VEEffectSpan, VETransitionStyle): at a
// clip's end it covers a range from inside the clip past its end, a cross dissolve (video) or a
// constant-power crossfade (audio) into the clip touching that end, whose share of each side is the
// range's split at the cut (70/30, all after the cut, ...), limited by the two clips' media beyond
// the cut; ending on the cut it is a fade out to black or silence. At a clip's start it is a fade in,
// allowed only where no clip touches that start (a cut belongs to its outgoing clip). Transition ids
// are span ids. Every call is one undo step and joins a coalescing group like any other edit.

@interface VEEngine (Transitions)

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
/// The same with the kind of the video transition (VETransitionKind: a cross dissolve, a wipe or the
/// iris). A transition added on an audio track (the cut's own, or the linked partners' crossfade) is
/// always a constant-power crossfade whatever `kind` says. Refused with VEEditErrorInvalidArgument
/// for a value outside VETransitionKind.
- (VEEditResult *)addTransitionFromClip:(VEClipID)fromClipID
                                 toClip:(VEClipID)toClipID
                               duration:(CMTime)duration
                                options:(VETransitionOptions)options
                                   kind:(VETransitionKind)kind;
/// Adds a transition at `edge` of `clipID` of `duration` (whole frames): at the clip's end a cross
/// dissolve centred on the cut when a clip touches that end (as addTransitionFromClip:), else a
/// fade out to black / silence over the clip's last `duration`; at its start a fade in from black /
/// silence (refused when a clip touches that start). FitToCut shortens it to what fits;
/// IncludeLinked adds the same transition at the same edge of the linked partner (fitted to its own
/// clip and cut), in the same undo step.
- (VEEditResult *)addTransitionAtEdge:(VEClipEdge)edge
                               ofClip:(VEClipID)clipID
                             duration:(CMTime)duration
                              options:(VETransitionOptions)options
    NS_SWIFT_NAME(addTransition(at:of:duration:options:));
/// The same with the kind of the video transition: at a free edge a wipe or the iris reveals the
/// picture from black (a fade in) or black over it (a fade out). An audio fade is always a fade.
- (VEEditResult *)addTransitionAtEdge:(VEClipEdge)edge
                               ofClip:(VEClipID)clipID
                             duration:(CMTime)duration
                              options:(VETransitionOptions)options
                                 kind:(VETransitionKind)kind
    NS_SWIFT_NAME(addTransition(at:of:duration:options:kind:));
/// Sets what a video transition does to the picture (its range, its role and its linked audio
/// crossfade or fade are unchanged): one undo step "Change Transition Kind". Refused:
/// VEEditErrorTransitionNotFound (not a transition), VEEditErrorTrackKindMismatch (an audio
/// transition, which is always a crossfade or a fade), VEEditErrorTrackLocked,
/// VEEditErrorInvalidArgument (a value outside VETransitionKind).
- (VEEditResult *)setKind:(VETransitionKind)kind
            forTransition:(VETransitionID)transitionID NS_SWIFT_NAME(setTransitionKind(_:for:));
/// The longest transition the cut between the two clips can take and what stops a longer one
/// (maximumFrames 0 with the reason when none fits, e.g. the cut already has a transition).
- (VETransitionLimit *)transitionLimitFromClip:(VEClipID)fromClipID toClip:(VEClipID)toClipID;
/// The longest duration an existing transition can be given (keeping its share before the cut as
/// setDuration:forTransition: does; a fade: the clip's length less its other fade).
- (VETransitionLimit *)transitionLimitForTransition:(VETransitionID)transitionID;
- (VEEditResult *)removeTransition:(VETransitionID)transitionID;
/// Sets the transition's length (whole frames). A centred cross dissolve stays centred; one with an
/// uneven share keeps its share before the cut in proportion (rounded down); a fade keeps its edge.
/// Refused beyond the cut's limit with the same explanation as adding.
- (VEEditResult *)setDuration:(CMTime)duration forTransition:(VETransitionID)transitionID;
/// A dissolve and its linked audio crossfade: the transition on the cut between the linked
/// partners of `transitionID`'s two clips (either way round), or the same fade at the same edge of
/// the owner's linked partner; 0 when there is none.
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
/// Sets the timeline range a transition covers (asymmetric: its edges move independently; whole
/// frames). A tail transition's range starts at or before its cut: each side is fitted to what the
/// clips allow (their lengths, the media beyond the cut, the neighbouring transitions) and the note
/// names a shortening; a range that no longer reaches past the cut becomes a fade out to black /
/// silence, and one reaching past it into a touching clip becomes a cross dissolve again (the note
/// says so). A fade in's range starts at its clip's start. With `includingLinked` the linked
/// transition gets the same range relative to its cut, fitted to its own clips. Refused:
/// VEEditErrorTransitionNotFound, VEEditErrorInvalidTime (a range that does not start inside the
/// clip, or is empty), VEEditErrorTrackLocked, and what AddTransition refuses when not even one
/// frame fits.
- (VEEditResult *)setRangeOfTransition:(VETransitionID)transitionID
                                 range:(CMTimeRange)range
                       includingLinked:(BOOL)includingLinked
    NS_SWIFT_NAME(setTransitionRange(_:range:includingLinked:));

@end

// MARK: Effect spans
//
// A clip's lanes 1-3 hold effect spans (VEEffectSpan): Motion and Opacity on video clips, Gain on
// audio clips. A span is a range of the clip with start and end values; the values compose onto the
// clip's static values (position and rotation add, scale and opacity multiply, gain adds in dB). A
// span does nothing before its start, moves over its range and holds its end values from its end to
// the clip's end (also through a tail transition's handle); a later span on the same lane applies
// on top of what it holds (so one starting neutral continues it without a jump). Spans of one lane
// never overlap. Ranges passed here are timeline times, rounded to whole frames; a span stays on
// its pictures when the clip is trimmed or its speed changes, a trim through it clips it, a split
// divides it, and one a trim or split leaves wholly before a clip's start passes the values it held
// on to that clip's static values (the pictures do not change). Every call is one undo step (joins
// coalescing groups: drags pass the whole change on every step) and returns the span as it is after
// the edit (VEEditResult.span). Refusals: VEEditErrorSpanNotFound, VEEditErrorClipNotFound,
// VEEditErrorTrackKindMismatch (a Motion or Opacity span on an audio clip, a Gain span on a video
// clip), VEEditErrorInvalidArgument (a lane outside 1-3, values outside their range: scale below 0,
// opacity outside 0...1, a parameter of another kind), VEEditErrorInvalidTime (a range outside the
// clip or shorter than a frame), VEEditErrorOverlap (another span of the lane is there;
// VEEditResult.freeRange is the nearest free range), VEEditErrorTrackLocked,
// VEEditErrorNotRepresentable.

@interface VEEngine (EffectSpans)

/// The clip's spans (lane 0 first, then lanes 1-3, each in time order); empty for an unknown clip.
- (NSArray<VEEffectSpan *> *)spansForClip:(VEClipID)clipID NS_SWIFT_NAME(spans(forClip:));
/// The spans of every clip of the track, in clip order.
- (NSArray<VEEffectSpan *> *)spansForTrack:(VETrackID)trackID NS_SWIFT_NAME(spans(forTrack:));
/// The span with that id, or nil.
- (nullable VEEffectSpan *)spanInfo:(VESpanID)spanID;
/// The number of lanes the track's clips use: the highest lane any of its spans is on, plus one
/// (so 1 for a track without spans, lane 0 included; at most 4).
- (NSInteger)laneCountForTrack:(VETrackID)trackID NS_SWIFT_NAME(laneCount(forTrack:));
/// Adds a Motion, Opacity (video) or Gain (audio) span on `lane` (1-3) of the clip over `range`,
/// starting neutral (it changes nothing until its values are set: the picture keeps the clip's
/// framing at the range's edges). createdIDs holds its id and `span` the span.
- (VEEditResult *)addSpanOfKind:(VESpanKind)kind
                           lane:(NSInteger)lane
                           clip:(VEClipID)clipID
                          range:(CMTimeRange)range NS_SWIFT_NAME(addSpan(kind:lane:clip:range:));
/// Moves the span's edges to `range` (a trim of one edge, or a move of the whole span within its
/// clip): a trim stretches its start and end values over the new range.
- (VEEditResult *)setRangeOfSpan:(VESpanID)spanID range:(CMTimeRange)range NS_SWIFT_NAME(setSpanRange(_:range:));
/// Sets the span's start and/or end values (NaN fields unchanged; see VESpanValues).
- (VEEditResult *)setValuesOfSpan:(VESpanID)spanID
                            start:(VESpanValues)start
                              end:(VESpanValues)end NS_SWIFT_NAME(setSpanValues(_:start:end:));
/// Sets how the span moves from its start to its end values (Custom cannot be set).
- (VEEditResult *)setInterpolationOfSpan:(VESpanID)spanID
                           interpolation:(VEKeyframeInterpolation)interpolation
    NS_SWIFT_NAME(setSpanInterpolation(_:interpolation:));
/// Moves the span to another lane (1-3) of its clip.
- (VEEditResult *)moveSpan:(VESpanID)spanID toLane:(NSInteger)lane NS_SWIFT_NAME(moveSpan(_:toLane:));
/// Removes a span (a transition too; removeTransition:includingLinked: also removes its linked one).
- (VEEditResult *)removeSpan:(VESpanID)spanID NS_SWIFT_NAME(removeSpan(_:));
/// Makes the span continue its clip's touching neighbour: VEClipEdgeStart sets its start values so
/// the clip's first frame shows what the previous clip's last frame shows (motion(at:) / gainDb(at:),
/// everything else composing there taken into account); VEClipEdgeEnd sets its end values from the
/// next clip's first frame. When nothing would change it succeeds without an undo step and the note
/// says so. A span that ended before the clip's last frame holds its end values there, so
/// VEClipEdgeEnd sets them to make that frame show the next clip's first frame exactly. Refused:
/// VEEditErrorNotAdjacent (no clip touches that edge), VEEditErrorInvalidArgument (a transition, or
/// a span that starts after that frame of its clip), and the span refusals.
- (VEEditResult *)matchSpanEdge:(VESpanID)spanID
          toAdjacentClipAtEdge:(VEClipEdge)edge NS_SWIFT_NAME(matchSpanEdge(_:toAdjacentClipAt:));
/// Continue on Next Clip: carries the Motion span's move on to the clip touching the end of its clip,
/// as a new Motion span there (one undo step, "Continue on Next Clip"; createdIDs and `span` give the
/// new span). It starts on the next clip's first frame with the placement this clip has at the cut (the
/// span's end placement, the rest held), lasts as long as the span (shortened to the next clip and to
/// the free part of a lane: the span's own lane when free from the first frame, else another), and
/// ends where the same move at the same rate gets to (per-second changes of position and rotation,
/// the per-second zoom ratio), with the same interpolation. EditOps.h planContinueMotion has the rule.
/// Refused with a sentence naming the clips: not a Motion span, not its clip's last move
/// (VEEditErrorInvalidArgument), no clip touching the end (VEEditErrorNotAdjacent), no lane of the next
/// clip free on its first frame (VEEditErrorOverlap), a locked track, a value out of range.
- (VEEditResult *)continueMotionSpanOnNextClip:(VESpanID)spanID NS_SWIFT_NAME(continueMotionSpanOnNextClip(_:));
/// Why continueMotionSpanOnNextClip: would be refused for the span now (its sentence), or nil when it
/// would go ahead. Changes nothing.
- (nullable NSString *)problemContinuingMotionSpanOnNextClip:(VESpanID)spanID
    NS_SWIFT_NAME(continueMotionProblem(forSpan:));
/// The Ken Burns move on a Motion span: its Position X/Y and Scale start and end values set in one
/// step so the picture shows the framing `start` on the span's first frame and `end` at its end
/// (the framings as the monitor shows them: the clip's static values and its other lanes are taken
/// into account), moving with `interpolation` (Ease In and Out is FCP's default; Custom is refused).
- (VEEditResult *)applyKenBurnsToSpan:(VESpanID)spanID
                                start:(VEMotionFraming)start
                                  end:(VEMotionFraming)end
                        interpolation:(VEKeyframeInterpolation)interpolation
    NS_SWIFT_NAME(applyKenBurns(span:start:end:interpolation:));
/// The clip on the same track touching `clipID` at `edge`: the one ending exactly where it starts
/// (VEClipEdgeStart) or starting exactly where it ends (VEClipEdgeEnd); 0 when there is none (a
/// gap, the end of the track, an unknown clip).
- (VEClipID)adjacentClipOfClip:(VEClipID)clipID atEdge:(VEClipEdge)edge NS_SWIFT_NAME(adjacentClip(of:at:));
/// Matches the clip's static Motion to its touching neighbour on the same track: VEClipEdgeStart
/// sets the static position, scale, rotation and opacity so the clip's first frame shows what the
/// previous clip's last frame shows (motion(at:)), the clip's spans acting on that frame taken into
/// account; VEClipEdgeEnd matches the clip's last frame to the next clip's first frame. One undo
/// step ("Match Previous Clip" / "Match Next Clip"); when nothing would change it succeeds without an
/// undo step and the note says so. Refused: VEEditErrorNotAdjacent, VEEditErrorTrackKindMismatch (an
/// audio clip), VEEditErrorTrackLocked, VEEditErrorClipNotFound, VEEditErrorInvalidArgument (the
/// clip's spans make scale or opacity 0 there, so no static value can match).
- (VEEditResult *)matchMotionOfClip:(VEClipID)clipID
                   toAdjacentAtEdge:(VEClipEdge)edge NS_SWIFT_NAME(matchMotion(clip:toAdjacentAt:));

@end

// MARK: Grade (a clip's colour correction; VEEngine+Grade.mm)
//
// A clip's grade is a property of the clip, as its Motion is (VEClipInfo.grade). The calls take the
// clips of a selection: those on audio tracks are left out (a selection of linked picture and sound
// grades the pictures), and when none is left the call is refused with VEEditErrorTrackKindMismatch.
// An id that names no clip is refused (VEEditErrorClipNotFound), and so is a clip on a locked track
// (VEEditErrorTrackLocked). Each edit is one undo step; a control drag made of setGradeValue: calls
// inside one coalescing group (VECoalescingModeReplace) is one step too.

@interface VEEngine (Grade)

/// Sets the fields of `values` that are not NaN on every clip of `clipIDs` (see above) and leaves the
/// others: moving one control over several clips sets that parameter on all of them and keeps what
/// differs between them. Refused (VEEditErrorInvalidArgument) when every field is NaN or a value is
/// outside its range (VEGradeParameterInfo). Undo name "Change <parameter>" for one, else "Change Grade".
- (VEEditResult *)setGradeValues:(VEGradeParams)values
                        forClips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setGrade(_:forClips:));
/// setGradeValues:forClips: with one parameter.
- (VEEditResult *)setGradeValue:(double)value
                   forParameter:(VEGradeParameter)parameter
                          clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setGradeValue(_:for:clips:));
/// Sets the fields of `value` that are not NaN of `wheel` on every clip of `clipIDs` (see above), keeping
/// the rest of their grades: NaN `level` keeps each clip's level (moving the colour over several clips), NaN
/// `cb` and `cr` keep each clip's colour (moving the level). Refused (VEEditErrorInvalidArgument) for a value
/// outside VEGradeWheel, every field NaN, only one of `cb` and `cr`, a level outside [-1, 1] or a colour
/// outside the unit disk. Undo name "Change <wheel>" ("Change Lift"). A drag of a wheel is several of these
/// in one coalescing group (one undo step), as for a slider.
- (VEEditResult *)setGradeWheel:(VEGradeWheelValue)value
                       forWheel:(VEGradeWheel)wheel
                          clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setGradeWheel(_:for:clips:));
/// Sets `curve` of every clip of `clipIDs` (see above) to `points` (NSValue-wrapped points, x increasing, 2
/// to 16 of them, both coordinates 0 to 1; empty, or points on the diagonal from (0, 0) to (1, 1), is the
/// identity), keeping the rest of their grades. Refused (VEEditErrorInvalidArgument) for a value outside
/// VEGradeCurve or points that are not a valid curve. Undo name "Change <curve> Curve" ("Change Luma Curve").
/// A drag of a point is several of these in one coalescing group (one undo step).
- (VEEditResult *)setGradeCurvePoints:(NSArray<NSValue *> *)points
                             forCurve:(VEGradeCurve)curve
                                clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setGradeCurve(_:for:clips:));
/// Reads the .cube file at `url` (a 1D or 3D LUT; Adobe's Cube format, with Resolve's input-range keywords)
/// and keeps it ready for setGradeInputLUT:clips: and setGradeLook:clips:, which copy it into the project.
/// Returns its description, or nil with `error` (VEEngineErrorImportFailed) saying what is wrong with the
/// file and where ("line 12: ..."), or that it cannot be read. Importing the same table again returns the same
/// id.
- (nullable VELUTInfo *)importLUTAtURL:(NSURL *)url error:(NSError **)error NS_SWIFT_NAME(importLUT(at:));
/// The LUT of `lutID` the project holds or was imported this session, or nil.
- (nullable VELUTInfo *)lutWithID:(NSString *)lutID NS_SWIFT_NAME(lut(withID:));
/// Sets the input LUT (applied to each clip's picture before its grade: a camera's log to Rec. 709, say) of
/// every clip of `clipIDs` (see above); nil or "" removes it. Undo name "Change Input LUT". Refused
/// (VEEditErrorInvalidArgument) for an id that is neither in the project nor imported.
- (VEEditResult *)setGradeInputLUT:(nullable NSString *)lutID
                             clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setGradeInputLUT(_:clips:));
/// Sets the look (applied after the grade and the curves, mixed by its strength) of every clip of `clipIDs`
/// (see above); nil or "" removes it (its strength goes back to 1). Undo name "Change Look".
- (VEEditResult *)setGradeLook:(nullable NSString *)lutID
                         clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setGradeLook(_:clips:));
/// Sets the look's strength (0 to 1) of every clip of `clipIDs` that has a look (see above; a clip without a
/// look keeps 1). Undo name "Change Look Strength"; a slider drag is several of these in one coalescing
/// group. Refused (VEEditErrorInvalidArgument) for a value outside [0, 1].
- (VEEditResult *)setGradeLookStrength:(double)strength
                                 clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setGradeLookStrength(_:clips:));
/// Sets hue curve `curve` of every clip of `clipIDs` (see above) to `points` (NSValue-wrapped points, x in
/// [0, 1) increasing, y 0 to 1, at most 16; empty, or every y 0.5, is the identity). Refused
/// (VEEditErrorInvalidArgument) for a value outside VEGradeHueCurve or points that are not a valid hue curve.
/// Undo name "Change Hue vs Saturation Curve" (and so on); a point drag is one coalescing group.
- (VEEditResult *)setGradeHueCurvePoints:(NSArray<NSValue *> *)points
                             forHueCurve:(VEGradeHueCurve)curve
                                   clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setGradeHueCurve(_:for:clips:));
/// Sets every curve (the tone curves and the hue curves) of every clip of `clipIDs` (see above) to the
/// identity, keeping the rest of their grades. Undo name "Reset Curves"; clips without curves make no undo step.
- (VEEditResult *)resetGradeCurvesOfClips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(resetGradeCurves(ofClips:));
/// Sets every wheel of every clip of `clipIDs` (see above) neutral, keeping the rest of their grades. Undo
/// name "Reset Wheels"; clips whose wheels are all neutral make no undo step.
- (VEEditResult *)resetGradeWheelsOfClips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(resetGradeWheels(ofClips:));
/// What the clips of `clipIDs` that can have a grade have for each parameter: the value where they
/// agree, "mixed" where they differ (an empty selection for none).
- (VEGradeSelection *)gradeOfClips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(grade(ofClips:));
/// Copies the clip's grade (every value, and what a newer version wrote that this one keeps) for
/// pasteGradeOntoClips:. Returns NO, keeping what was copied before, for a missing clip or one on an
/// audio track. What is copied stays across New and Open.
- (BOOL)copyGradeOfClip:(VEClipID)clipID NS_SWIFT_NAME(copyGrade(ofClip:));
/// Whether a grade has been copied.
@property (nonatomic, readonly) BOOL hasCopiedGrade;
/// The values of the copied grade (VEGradeParamsNeutral() when none has been copied).
@property (nonatomic, readonly) VEGradeParams copiedGrade;
/// Gives every clip of `clipIDs` (see above) the copied grade, replacing its own. Undo name "Paste
/// Grade". Refused (VEEditErrorInvalidArgument) when no grade has been copied.
- (VEEditResult *)pasteGradeOntoClips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(pasteGrade(ontoClips:));
/// Removes the grade of every clip of `clipIDs` (see above): every value neutral, and nothing kept of
/// what a newer version wrote. Undo name "Reset Grade". Clips without a grade make no undo step.
- (VEEditResult *)resetGradeOfClips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(resetGrade(ofClips:));

@end

// MARK: Titles and colour mattes (VEEngine+Titles.mm; VETitles.h)
//
// A title or a colour matte is a clip of its own on a video track: an overlay over the tracks below, or a card on
// its own. It carries its content (VEClipInfo.title, matteColour) and refers to the project's hidden generator
// asset of its kind, which the first clip of the kind makes in the same undo step (allAssets leaves it out; it is
// not saved while no clip uses it). Every rule about stills applies to it (any length, trims without media bounds,
// no speed or reverse), it may have Motion, Opacity spans, fades and transitions, and it has no grade (the grade
// calls leave titles and mattes out, as they leave out sound). The picture is drawn in memory at the size it is
// shown (its Motion zoom, an export larger than the sequence), so it stays sharp.
//
// Edits take the clips of a selection: those that are not titles (or, for the matte's colour, not mattes) are
// refused (VEEditErrorInvalidArgument), as are values outside a parameter's range (VETitleParameterInfo). Every
// edit is one undo step; a slider drag, a box drag and a typing run made of these calls inside one coalescing group
// (VECoalescingModeReplace) are one step too.

@interface VEEngine (Titles)

/// Adds a title, a lower third, a colour matte, a title card or a caption (`preset`) at `time` (the playhead), 5 s
/// long, on the lowest video track above `videoTrackID` (the target video track; 0: from the bottom track up) that is
/// free for that time and unlocked, or on a new video track added on top: nothing is overwritten or rippled. A title
/// card is two clips, its matte placed so and its title by the same rule above the matte's track. One undo step ("Add
/// Title", "Add Lower Third", "Add Colour Matte", "Add Title Card", "Add Caption") that also adds the generator assets
/// and the new tracks when needed. createdIDs holds the new clips, the top one (the one to select) first.
- (VEEditResult *)addGeneratedPreset:(VEGeneratedPreset)preset
                              atTime:(CMTime)time
                          aboveTrack:(VETrackID)videoTrackID NS_SWIFT_NAME(addGenerated(_:at:aboveTrack:));
/// Places `preset` on `videoTrackID` at `time` as a dropped bin item is placed: overwriting what is under it, or
/// with `insert` rippling later clips right (insertAsset:'s rules); a title card's title then goes above it by the
/// placement rule. One undo step; createdIDs holds the new clips, the top one first.
- (VEEditResult *)placeGeneratedPreset:(VEGeneratedPreset)preset
                               onTrack:(VETrackID)videoTrackID
                                atTime:(CMTime)time
                                insert:(BOOL)insert NS_SWIFT_NAME(placeGenerated(_:onTrack:at:insert:));
/// Sets the text of the titles of `clipIDs` (UTF-8, at most 16384 bytes). Undo name "Edit Title Text".
- (VEEditResult *)setTitleText:(NSString *)text clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setTitleText(_:clips:));
/// Sets a number parameter (VETitleValueTypeNumber) of the titles of `clipIDs`. Undo name "Change <parameter>".
- (VEEditResult *)setTitleNumber:(double)value
                    forParameter:(VETitleParameter)parameter
                           clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setTitleNumber(_:for:clips:));
/// Sets a colour parameter (fill, outline, shadow, box).
- (VEEditResult *)setTitleColour:(VEColour)colour
                    forParameter:(VETitleParameter)parameter
                           clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setTitleColour(_:for:clips:));
/// Turns the outline, the shadow or the background box on or off.
- (VEEditResult *)setTitleToggle:(BOOL)on
                    forParameter:(VETitleParameter)parameter
                           clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setTitleToggle(_:for:clips:));
/// Sets the alignment of the titles of `clipIDs`. Point text keeps its block where it is (its lines align again inside
/// it; its x, which is the block's edge or centre as the lines align, moves with that edge); area text is centred on
/// its x whatever its alignment.
- (VEEditResult *)setTitleAlignment:(VETitleAlignment)alignment
                              clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setTitleAlignment(_:clips:));
/// Makes the titles of `clipIDs` point text (no wrapping: the block is as wide as its widest line and grows with the
/// text) or area text (wrapping at the box width), keeping each title's text where it is: the block's edge or centre
/// its lines align to stays, and so does its top, centre or bottom as it is anchored (each title gets its own
/// position). Undo name "Change Point Text". setTitleToggle:forParameter:clips: with VETitleParameterPointText does
/// the same.
- (VEEditResult *)setTitlePointText:(BOOL)pointText
                              clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setTitlePointText(_:clips:));
/// Anchors the titles of `clipIDs` at their block's top (added lines grow it down), centre or bottom (it grows up),
/// keeping each block where it is (its position moves to the new anchor). Undo name "Change Vertical Anchor".
- (VEEditResult *)setTitleAnchor:(VETitleAnchor)anchor
                           clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setTitleAnchor(_:clips:));
- (VEEditResult *)setTitleFont:(VETitleFont *)font clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setTitleFont(_:clips:));
/// Moves the text blocks of the titles of `clipIDs` to (x, y) and, unless `width` is NaN, gives them that wrap
/// width (fractions of the frame; the box drag on the program monitor). Undo name "Move Title" (or "Resize Title"
/// with a width). Moving renders nothing new.
- (VEEditResult *)setTitlePositionX:(double)x
                                  y:(double)y
                              width:(double)width
                              clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setTitlePosition(x:y:width:clips:));
/// Sets the colour of the colour mattes of `clipIDs`. Undo name "Change Matte Colour".
- (VEEditResult *)setMatteColour:(VEColour)colour clips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(setMatteColour(_:clips:));
/// What the titles and mattes of `clipIDs` have (the others are left out).
- (VETitleSelection *)titleOfClips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(title(ofClips:));
/// A title's text block on its canvas (sequence pixels, origin at the frame's top-left, before the clip's Motion):
/// where its anchor puts it around its position, its width and the height of its lines (titleBlockSizeOfClip:'s);
/// CGRectNull for a clip that is not a title.
- (CGRect)titleBlockOfClip:(VEClipID)clipID NS_SWIFT_NAME(titleBlock(ofClip:));
/// The text of the title `clipID` laid out as it is drawn, placed on the frame through the clip's Motion at `time` (a
/// timeline time; the program monitor's playhead): the program monitor's caret, selection and clicks. Nil for a clip
/// that is not a title.
- (nullable VETitleTextLayout *)titleTextLayoutOfClip:(VEClipID)clipID
                                               atTime:(CMTime)time NS_SWIFT_NAME(titleTextLayout(ofClip:at:));
/// Copy Style: copies the style of the title `clipID` (its font, size, colours, alignment, spacing, outline, shadow
/// and background box; not its text, position, box width, point text or anchor) for pasteTitleStyleOntoClips:.
/// Returns NO, keeping what was copied before, for a clip that is not a title.
- (BOOL)copyTitleStyleOfClip:(VEClipID)clipID NS_SWIFT_NAME(copyTitleStyle(ofClip:));
/// Whether a title style has been copied (it outlives New and Open).
@property (nonatomic, readonly) BOOL hasCopiedTitleStyle;
/// Paste Style: gives the titles of `clipIDs` the copied style, as one undo step ("Paste Style"); each keeps its text,
/// box width, point text and anchor, and its text stays where it is drawn (a point text whose alignment changes keeps
/// its block, as setTitleAlignment:clips: does: its position, the block's edge or centre, moves with the alignment). Refused without a copied style, or when a clip is not a title.
- (VEEditResult *)pasteTitleStyleOntoClips:(NSArray<NSNumber *> *)clipIDs NS_SWIFT_NAME(pasteTitleStyle(ontoClips:));
/// The size of a title's text block in sequence pixels (the box the program monitor draws: the wrap width, or point
/// text's widest line, and the height of its lines; an empty text, or one ending with a line break, has an empty last
/// line); CGSizeZero for a clip that is not a title.
- (CGSize)titleBlockSizeOfClip:(VEClipID)clipID NS_SWIFT_NAME(titleBlockSize(ofClip:));
/// The fonts the active sequence's titles use that this Mac does not have, with how many titles use each (the
/// export sheet asks before exporting them in the system font).
@property (nonatomic, readonly, copy) NSArray<VEMissingTitleFont *> *missingTitleFonts;

@end

// MARK: Undo

@interface VEEngine (Undo)

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

@end

// MARK: Program monitor and playback

@interface VEEngine (Playback)

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
/// Shows the luma waveform of the program monitor's picture in `view` (VEWaveformView), drawn with
/// every frame the program view shows (playing or paused; the program view renders once now so the
/// waveform appears at once); replaces a previously attached waveform view; nil detaches it (it then
/// costs nothing). Without an attached program view nothing is drawn until one is attached.
- (void)attachWaveformView:(nullable VEWaveformView *)view NS_SWIFT_NAME(attachWaveformView(_:));
/// The attached waveform view, if any.
@property (nonatomic, readonly, weak, nullable) VEWaveformView *waveformView;
/// Whether the program monitor tints the pixels the scopes count as clipped (VEWaveformView): red where a
/// channel is at or above white, blue where one is at or below black, as a photo app's clipping warning.
/// Only the program monitor shows it (never the output display, a snapshot or an export); setting it
/// renders the program monitor once, so a paused picture shows it at once. Off by default.
@property (nonatomic) BOOL showsClippingOverlay;
/// Same as seekToTime: (kept for callers that only show stills).
- (void)showProgramFrameAtTime:(CMTime)time;

/// Shows `clipID` alone in the program monitor (the Ken Burns editor's picture): only that clip,
/// whatever its track's visibility and without its transitions, held on its first frame while the
/// playhead is before it and on its last from its end; with `identityMotion` at identity Motion
/// (no offset, scale 1, no rotation, opacity 1: its picture fitted into the frame), otherwise with
/// its own Motion. Seeking, scrubbing and playback work as usual (the audio is the program's). Only
/// the program view shows it: the output view (attachOutputView:) keeps showing the program, and
/// an export renders the program. Replaces a previous solo clip. Returns NO (and clears the
/// override) when `clipID` is not a video clip of the active sequence. The override ends with
/// clearProgramPreviewSolo, when the clip is removed (or leaves the video tracks) and on New/Open.
- (BOOL)setProgramPreviewSoloClip:(VEClipID)clipID
                   identityMotion:(BOOL)identityMotion NS_SWIFT_NAME(setProgramPreviewSolo(clip:identityMotion:));
/// Shows the program again in the program monitor.
- (void)clearProgramPreviewSolo;
/// The clip the program monitor shows alone (0: the program).
@property (nonatomic, readonly) VEClipID programPreviewSoloClipID;
/// Whether that clip is shown at identity Motion (NO without a solo clip).
@property (nonatomic, readonly) BOOL programPreviewSoloIdentityMotion;

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

@end

// MARK: Export

@interface VEEngine (Export)

/// Which presets can be exported at `width` x `height` on this machine and whether their encoder
/// runs in hardware (VideoToolbox asked at that size; hardware encoders are size dependent).
/// The answer is cached per size; the first query of a size takes a few milliseconds, which
/// exportFormatsForWidth:height:completion: spends off the main thread.
- (NSArray<VEExportFormat *> *)exportFormatsForWidth:(NSInteger)width height:(NSInteger)height;
- (void)exportFormatsForWidth:(NSInteger)width
                       height:(NSInteger)height
                   completion:(void (^)(NSArray<VEExportFormat *> *formats))completion
    NS_SWIFT_UI_ACTOR;
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

@end

// MARK: Source monitor

@interface VEEngine (SourceMonitor)

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
