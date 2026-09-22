// VEEngine: the engine facade for the Swift UI layer.
//
// One VEEngine owns one open project plus the media services behind it: the backend router
// (Apple + FFmpeg backends), frame cache, decode pool, thumbnail and waveform services.
//
// Rules:
// - Main thread only. Every instance method must be called on the main thread (asserted);
//   completion blocks and notifications are delivered on the main thread.
// - Nothing here blocks on media I/O. Model calls are synchronous and cheap; probing, decoding,
//   thumbnails and waveforms run on background threads and report back asynchronously.
// - Snapshots, never pointers: the info objects returned (VETypes.h) are immutable copies of
//   the model at the time of the call. After VEEngineModelDidChangeNotification, ask again.
// - Every model edit is an undoable command. Edits return a VEEditResult; a refused edit
//   changes nothing. `changeCount` increases with every change (edit, undo, redo, coalesced
//   drag step, import, asset removal, project load) and serves as the model version.
// - Continuous gestures: call beginCoalescingWithKey: before the first edit of a drag,
//   endCoalescing on release (one undo step), or cancelCoalescing on Escape (reverts the drag).
//   While a group is open, each edit replaces the previous edit of the group, so express
//   every step relative to the state before the gesture (e.g. "move clip 7 to 12 s").

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

#import <VidEditEngine/VETypes.h>

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

FOUNDATION_EXPORT NSString *const VEEngineChangeCountKey;
FOUNDATION_EXPORT NSString *const VEEngineAssetIDKey;

/// Error domain for NSErrors from the facade (open/save/import).
FOUNDATION_EXPORT NSErrorDomain const VEEngineErrorDomain;

typedef NS_ERROR_ENUM(VEEngineErrorDomain, VEEngineErrorCode) {
    VEEngineErrorReadFailed = 1,
    VEEngineErrorWriteFailed = 2,
    VEEngineErrorInvalidProject = 3,
    VEEngineErrorImportFailed = 4,
};

/// Alternative to the notifications: register with -addObserver:. All methods are optional
/// and called on the main thread.
@protocol VEEngineObserver <NSObject>
@optional
- (void)engine:(VEEngine *)engine modelDidChange:(uint64_t)changeCount;
- (void)engineAssetsDidChange:(VEEngine *)engine;
- (void)engine:(VEEngine *)engine thumbnailAvailableForAsset:(VEAssetID)assetID;
- (void)engine:(VEEngine *)engine waveformAvailableForAsset:(VEAssetID)assetID;
@end

@interface VEEngine : NSObject

// MARK: Versions

/// Engine version, from the framework's CFBundleShortVersionString (e.g. "0.1.0").
/// Not named `version`: NSObject already has `+ (NSInteger)version` (NSCoder class versioning).
@property (class, nonatomic, readonly, copy) NSString *engineVersion;

/// Version of the FFmpeg libraries the engine is running against (av_version_info(), e.g. "7.1.5").
@property (class, nonatomic, readonly, copy) NSString *ffmpegVersion;

/// License string reported by the loaded libavcodec (avcodec_license()).
@property (class, nonatomic, readonly, copy) NSString *ffmpegLicense;

// MARK: Lifetime

/// Caches (thumbnails, waveforms) under Application Support/VidEdit/Caches.
- (instancetype)init;
/// Caches under `cacheDirectory` (nil: no disk caches). Starts with a new untitled project.
- (instancetype)initWithCacheDirectory:(nullable NSURL *)cacheDirectory NS_DESIGNATED_INITIALIZER;

/// Registers a weakly held observer.
- (void)addObserver:(id<VEEngineObserver>)observer;
- (void)removeObserver:(id<VEEngineObserver>)observer;

// MARK: Project

/// Replaces the project with an empty one (one 1080p30 sequence, tracks V1 V2 / A1 A2).
- (void)newProjectWithName:(NSString *)name;
/// Loads a .videdit file. Asset paths are resolved through their stored security-scoped
/// bookmarks (a moved file is followed); files that cannot be found are listed in
/// `missingAssetIDs`. On failure the current project is kept.
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
/// imported (or already present) assets and one NSError per file that failed.
- (void)importMediaAtURLs:(NSArray<NSURL *> *)urls
               completion:(nullable void (^)(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors))completion;
/// Removes an asset (undoable). Refused while any clip of any sequence uses it.
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
/// follow in time). One undo step.
- (VEEditResult *)moveClips:(NSArray<NSNumber *> *)clipIDs byTime:(CMTime)delta trackOffset:(NSInteger)trackOffset;
/// Moves the clip's start (end fixed). `clamp` limits the time to what is possible instead of refusing.
- (VEEditResult *)trimClipHead:(VEClipID)clipID toTime:(CMTime)time clamp:(BOOL)clamp;
/// Moves the clip's end (start fixed).
- (VEEditResult *)trimClipTail:(VEClipID)clipID toTime:(CMTime)time clamp:(BOOL)clamp;
- (VEEditResult *)splitClip:(VEClipID)clipID atTime:(CMTime)time;
/// Splits the given clips at `time` (clips not spanning `time` are skipped); an empty list
/// splits every clip under `time` on unlocked tracks. One undo step.
- (VEEditResult *)splitClips:(NSArray<NSNumber *> *)clipIDs atTime:(CMTime)time;
/// Removes clips (and their linked partners), leaving gaps.
- (VEEditResult *)removeClips:(NSArray<NSNumber *> *)clipIDs;
/// Removes clips and closes the gaps.
- (VEEditResult *)rippleDeleteClips:(NSArray<NSNumber *> *)clipIDs;
- (VEEditResult *)setVideoParams:(VEVideoParams)params forClip:(VEClipID)clipID;
- (VEEditResult *)setAudioParams:(VEAudioParams)params forClip:(VEClipID)clipID;
/// Constant speed (0.01...100); later clips ripple by the change in duration.
- (VEEditResult *)setSpeed:(double)speed forClip:(VEClipID)clipID;
- (VEEditResult *)addTransitionFromClip:(VEClipID)fromClipID toClip:(VEClipID)toClipID duration:(CMTime)duration;
- (VEEditResult *)removeTransition:(VETransitionID)transitionID;
- (VEEditResult *)setDuration:(CMTime)duration forTransition:(VETransitionID)transitionID;
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

- (void)beginCoalescingWithKey:(NSString *)key;
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

// MARK: Program monitor

/// Shows the sequence frame at a time in `view` (decoded through the scrub path; the view
/// keeps its previous picture until the new one is ready). Replaces the view's frame source;
/// pass nil to detach. PLAYBACK INTEGRATION POINT: the playback controller installs its own
/// frame source on the view instead while it runs.
- (void)attachProgramView:(nullable VEPreviewView *)view;
/// Renders the frame at `time` into the attached program view (no-op without one).
- (void)showProgramFrameAtTime:(CMTime)time;

@end

NS_ASSUME_NONNULL_END
