#import "VEEngine.h"

#import "VEPreviewView.h"

#import "VEExport+Internal.h"

#import "../Render/VEPreviewView+Internal.h"
#import "VEFacadeCommands+Internal.h"
#import "VEProgramFrameProvider+Internal.h"
#import "VETypes+Internal.h"

#include "../Edit/EditOps.h"
#include "../Edit/UndoStack.h"
#include "../Export/ExportJob.h"
#include "../Media/AssetImport.h"
#include "../Media/BackendRouter.h"
#include "../Media/DecodePool.h"
#include "../Media/FFmpeg/FFmpegBackend.h"
#include "../Media/FrameCache.h"
#include "../Media/HardwareCaps.h"
#include "../Media/MediaTypes.h"
#include "../Playback/PlaybackController.h"
#include "../Render/Scheduler.h"
#include "../Serialize/ProjectJSON.h"
#include "../Thumbs/ThumbnailService.h"
#include "../Thumbs/WaveformService.h"

#include <json.hpp>

#include <os/signpost.h>

#include <algorithm>
#include <climits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
}

using namespace ve;
using namespace ve::facade;

NSNotificationName const VEEngineModelDidChangeNotification = @"VEEngineModelDidChangeNotification";
NSNotificationName const VEEngineAssetsDidChangeNotification = @"VEEngineAssetsDidChangeNotification";
NSNotificationName const VEEngineThumbnailDidBecomeAvailableNotification =
    @"VEEngineThumbnailDidBecomeAvailableNotification";
NSNotificationName const VEEngineWaveformDidBecomeAvailableNotification =
    @"VEEngineWaveformDidBecomeAvailableNotification";
NSNotificationName const VEEnginePlaybackDidChangeNotification = @"VEEnginePlaybackDidChangeNotification";
NSNotificationName const VEEngineSourcePlaybackDidChangeNotification = @"VEEngineSourcePlaybackDidChangeNotification";
NSNotificationName const VEEngineMemoryPressureNotification = @"VEEngineMemoryPressureNotification";
NSNotificationName const VEEngineExportDidProgressNotification = @"VEEngineExportDidProgressNotification";
NSNotificationName const VEEngineExportDidFinishNotification = @"VEEngineExportDidFinishNotification";
NSString *const VEEngineExportProgressKey = @"exportProgress";
NSString *const VEEngineExportSummaryKey = @"exportSummary";
NSString *const VEEngineExportErrorKey = @"exportError";
NSString *const VEEngineChangeCountKey = @"changeCount";
NSString *const VEEngineAssetIDKey = @"assetID";
NSString *const VEEnginePlaybackStatusKey = @"playbackStatus";
NSString *const VEEngineCriticalKey = @"critical";
NSErrorDomain const VEEngineErrorDomain = @"FramewrightEngine.VEEngine";

/// Raises NSInternalInconsistencyException: a VEEngine method was called off the main thread.
[[noreturn]] static void veMainThreadViolation(const char *function) {
    [NSException raise:NSInternalInconsistencyException
                format:@"VEEngine must be used on the main thread (%s called on %@)", function, NSThread.currentThread];
    __builtin_unreachable();
}

/// Engine model calls are confined to the main thread. Active in every build configuration: a
/// call from another thread would race the model, so it fails loudly instead.
#define VE_ASSERT_MAIN()                                                                                               \
    do {                                                                                                               \
        if (__builtin_expect(!NSThread.isMainThread, 0)) {                                                             \
            veMainThreadViolation(__PRETTY_FUNCTION__);                                                                \
        }                                                                                                              \
    } while (0)

namespace {

/// Size of the poster thumbnail generated at import (matches the media bin's request).
constexpr int kPosterMaxDimension = 320;
/// Key under which the project file stores security-scoped bookmarks (asset id -> base64).
constexpr const char *kBookmarksKey = "assetBookmarks";
/// Key under which the project file stores the media folder's bookmark (base64).
constexpr const char *kMediaFolderBookmarkKey = "mediaFolderBookmark";

NSError *makeError(VEEngineErrorCode code, NSString *message) {
    return [NSError errorWithDomain:VEEngineErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

NSError *makeError(const media::MediaError &error, NSString *context) {
    NSString *message = [NSString stringWithFormat:@"%@: %@", context, toNS(error.message.empty() ? error.description()
                                                                                                    : error.message)];
    return [NSError errorWithDomain:VEEngineErrorDomain
                               code:VEEngineErrorImportFailed
                           userInfo:@{NSLocalizedDescriptionKey : message, @"mediaErrorCode" : @(int(error.code))}];
}

VEEditResult *toVE(const EditResult &result, NSArray<NSNumber *> *created = @[], NSString *note = nil) {
    return makeEditResult(result, created, note);
}

/// Shares of the frame cache budget the two decode pools may fill with lookahead windows. They
/// add up to the single pool's former 0.75, leaving the rest for scrubbed and pinned frames;
/// the program monitor gets the larger share (it plays multi-layer sequences).
constexpr double kProgramPoolBudgetShare = 0.5;
constexpr double kSourcePoolBudgetShare = 0.25;
/// An export's decode pool (the program and source shares plus this add up to 1).
constexpr double kExportPoolBudgetShare = 0.25;
/// Longest the main thread waits for the bookmarks of a project being opened (they resolve in
/// parallel, never mounting volumes or showing UI); an asset whose bookmark is not resolved in
/// time keeps its stored path.
constexpr double kBookmarkResolutionTimeout = 3.0;

/// Lanes of DecodePool::requestFrame: the program controller's layers use kProgramLaneBase + i,
/// the source monitor's scrub provider and controller their own ranges (on the source pool).
constexpr uint64_t kProgramLaneBase = 0;
constexpr uint64_t kSourceScrubLaneBase = uint64_t(1) << 40;
constexpr uint64_t kSourcePlaybackLaneBase = uint64_t(2) << 40;
/// First id of the source monitor's private one-clip project (never collides with model ids).
constexpr uint64_t kSourceProjectFirstId = uint64_t(1) << 56;
/// Clip id of the source monitor's picture in its still graphs.
const ClipId kSourceVideoClip{kSourceProjectFirstId + 10};

/// The source monitor's private project: `asset` (same id as in the real project, so the
/// frame cache and routing are shared) as one clip over the whole media, video on V1 and audio
/// on A1 (linked), on a sequence at the asset's own frame rate and size. Nullopt for stills and
/// media without a positive duration.
std::optional<Project> makeSourceProject(const MediaAsset &asset, CMTime fallbackFrameDuration) {
    if (asset.isStill() || !CMTIME_IS_NUMERIC(asset.duration) || asset.duration <= kCMTimeZero) {
        return std::nullopt;
    }
    Project project;
    project.name = "Source";
    project.ids = IdGenerator(kSourceProjectFirstId);
    project.assets.push_back(asset);
    const CMTime fd = asset.hasVideo() && isPositive(asset.frameDuration) ? asset.frameDuration : fallbackFrameDuration;
    const SequenceId sequenceId = project.addSequence("Source", fd, asset.hasVideo() ? std::max(1, asset.width) : 16,
                                                      asset.hasVideo() ? std::max(1, asset.height) : 9, 1, 1);
    Sequence &sequence = *project.findSequence(sequenceId);
    const CMTime length = snapToFrame(asset.duration, fd, SnapMode::Floor);
    if (length <= kCMTimeZero) {
        return std::nullopt;
    }
    Clip video;
    video.id = kSourceVideoClip;
    video.assetId = asset.id;
    video.trackId = sequence.videoTracks.front().id;
    video.timelineStart = kCMTimeZero;
    video.timelineDuration = length;
    video.sourceIn = kCMTimeZero;
    Clip audio = video;
    audio.id = ClipId(kSourceProjectFirstId + 11);
    audio.trackId = sequence.audioTracks.front().id;
    // The picture ends where the media's video ends (the audio may run on).
    const CMTime videoLength = snapToFrame(asset.videoEnd(), fd, SnapMode::Floor);
    if (videoLength > kCMTimeZero && videoLength < length) {
        video.timelineDuration = videoLength;
    }
    if (asset.hasVideo() && asset.hasAudio()) {
        video.linkedClipId = audio.id;
        audio.linkedClipId = video.id;
    }
    if (asset.hasVideo()) {
        sequence.videoTracks.front().clips.push_back(video);
    }
    if (asset.hasAudio()) {
        sequence.audioTracks.front().clips.push_back(audio);
    }
    return project;
}

template <class IdType> NSArray<NSNumber *> *toNumbers(const std::vector<IdType> &ids) {
    NSMutableArray<NSNumber *> *numbers = [NSMutableArray arrayWithCapacity:ids.size()];
    for (const IdType &id : ids) {
        [numbers addObject:@(static_cast<int64_t>(id.value()))];
    }
    return numbers;
}

std::vector<ClipId> toClipIds(NSArray<NSNumber *> *numbers) {
    std::vector<ClipId> ids;
    ids.reserve(numbers.count);
    for (NSNumber *n : numbers) {
        const int64_t value = n.longLongValue;
        if (value > 0) {
            ids.emplace_back(static_cast<ClipId::ValueType>(value));
        }
    }
    return ids;
}

/// Security-scoped bookmark for a file, falling back to a plain bookmark (outside the sandbox
/// security scope may be unavailable). Nil if the file cannot be bookmarked.
NSData *makeBookmark(NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    NSData *data = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope |
                                                NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess
                 includingResourceValuesForKeys:nil
                                  relativeToURL:nil
                                          error:nil];
    if (data == nil) {
        data = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
    }
    return data;
}

AssetDetails detailsFor(const media::RoutedMediaInfo &routed) {
    AssetDetails details;
    const media::MediaInfo &info = routed.info;
    const media::TrackInfo *visual = info.firstTrack(media::TrackKind::Video);
    if (visual == nullptr) {
        visual = info.firstTrack(media::TrackKind::Still);
    }
    const media::TrackInfo *audio = info.firstTrack(media::TrackKind::Audio);
    if (visual != nullptr) {
        details.codecName = visual->codec.name.empty() ? media::codecDisplayName(visual->codec.fourCC) : visual->codec.name;
    }
    if (audio != nullptr) {
        details.audioCodecName = audio->codec.name.empty() ? media::codecDisplayName(audio->codec.fourCC) : audio->codec.name;
    }
    if (details.codecName.empty()) {
        details.codecName = details.audioCodecName;
    }
    details.container = info.container;
    std::string reason;
    for (const media::TrackRoute &route : routed.routes) {
        if (!reason.empty()) {
            reason += "\n";
        }
        reason += std::string(media::toString(route.kind)) + ": " + (route.backend.empty() ? "unroutable" : route.backend) +
                  (route.hardwareDecode ? " (hardware)" : "") + " - " + route.reason;
    }
    details.routingReason = reason.empty() ? routed.reason : reason;
    return details;
}

/// A bookmark resolved by resolveBookmarks(): nil url when it could not be resolved (in time).
struct ResolvedBookmark {
    NSURL *url = nil;
    BOOL stale = NO;
};

/// Resolves `bookmarks` concurrently on a background queue, security-scoped first, then plain,
/// without mounting volumes or showing UI; waits at most kBookmarkResolutionTimeout seconds in
/// total. Results that arrive later are discarded. Security-scoped access is not started here.
std::vector<ResolvedBookmark> resolveBookmarks(NSArray<NSData *> *bookmarks) {
    struct Shared {
        std::mutex mutex;
        std::vector<ResolvedBookmark> results;
        bool abandoned = false;
    };
    auto shared = std::make_shared<Shared>();
    shared->results.resize(bookmarks.count);
    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    for (NSUInteger i = 0; i < bookmarks.count; ++i) {
        NSData *data = bookmarks[i];
        dispatch_group_async(group, queue, ^{
            const NSURLBookmarkResolutionOptions options =
                NSURLBookmarkResolutionWithoutUI | NSURLBookmarkResolutionWithoutMounting;
            BOOL stale = NO;
            NSURL *url = [NSURL URLByResolvingBookmarkData:data
                                                   options:options | NSURLBookmarkResolutionWithSecurityScope
                                             relativeToURL:nil
                                       bookmarkDataIsStale:&stale
                                                     error:nil];
            if (url == nil) {
                stale = NO;
                url = [NSURL URLByResolvingBookmarkData:data
                                                options:options
                                          relativeToURL:nil
                                    bookmarkDataIsStale:&stale
                                                  error:nil];
            }
            std::lock_guard<std::mutex> lock(shared->mutex);
            if (!shared->abandoned) {
                shared->results[i] = ResolvedBookmark{url, stale};
            }
        });
    }
    dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, int64_t(kBookmarkResolutionTimeout * NSEC_PER_SEC)));
    std::lock_guard<std::mutex> lock(shared->mutex);
    shared->abandoned = true;
    return shared->results;
}

/// Result of probing one file on the background queue.
struct ProbedFile {
    std::optional<MediaAsset> asset;
    std::optional<media::RoutedMediaInfo> routed;
    AssetDetails details;
    NSData *bookmark = nil;
    NSError *error = nil;
};

} // namespace

@interface VEClipParamsBatch ()
/// The batch as engine changes, in the order clips were first added (video parameters without
/// keyframes: the engine command gets each clip's keyframes from -applyClipParams:).
@property (nonatomic, readonly) std::vector<ClipParamsChange> changes;
/// Whether the batch removes the clip's Motion keyframes (setVideoParams:clearingKeyframesForClip:).
- (BOOL)clearsKeyframesOfClip:(ClipId)clipId;
@end

@implementation VEClipParamsBatch {
    std::vector<ClipParamsChange> _changes;
    std::set<ClipId> _clearsKeyframes; // clips whose Motion keyframes the batch removes
}

- (ClipParamsChange &)entryForClip:(VEClipID)clipID {
    const ClipId id(static_cast<ClipId::ValueType>(clipID));
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
    _clearsKeyframes.erase(ClipId(static_cast<ClipId::ValueType>(clipID)));
}

- (void)setVideoParams:(VEVideoParams)params clearingKeyframesForClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    [self entryForClip:clipID].video = fromVE(params);
    _clearsKeyframes.insert(ClipId(static_cast<ClipId::ValueType>(clipID)));
}

- (void)setAudioParams:(VEAudioParams)params forClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    [self entryForClip:clipID].audio = fromVE(params);
}

- (NSUInteger)count {
    VE_ASSERT_MAIN();
    return _changes.size();
}

- (std::vector<ClipParamsChange>)changes {
    return _changes;
}

- (BOOL)clearsKeyframesOfClip:(ClipId)clipId {
    return _clearsKeyframes.count(clipId) > 0;
}

@end

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

@implementation VEEngine {
    std::shared_ptr<media::BackendRouter> _router;
    std::shared_ptr<media::FrameCache> _frameCache;
    media::FrameCache::Epoch _mediaEpoch; // advanced on every New/Open (ids restart per project)
    std::shared_ptr<media::DecodePool> _decodePool;
    std::unique_ptr<thumbs::ThumbnailService> _thumbnails;
    std::unique_ptr<thumbs::WaveformService> _waveforms;
    std::unique_ptr<playback::PlaybackController> _playback;
    uint64_t _playbackGeneration; // _projectGeneration the controller's sequence belongs to
    bool _playbackPublished;

    // Source monitor: a pool of its own (a playback controller replaces its pool's whole target
    // set), a still provider for scrubbing and a controller over a private one-clip project that
    // is created when the monitor first plays.
    std::shared_ptr<media::DecodePool> _sourcePool;
    std::shared_ptr<ProgramFrameProvider> _sourceProvider;
    std::unique_ptr<playback::PlaybackController> _sourcePlayback;
    __weak VEPreviewView *_sourceView;
    AssetId _sourceAsset;
    CMTime _sourceTime;
    std::optional<Project> _sourceProject;   // for _sourceAsset
    AssetId _sourcePlaybackAsset;            // asset of the source controller's sequence
    bool _sourceUsesController;              // the source view shows the controller's picture
    BOOL _sourceMonitorVisible;              // see -setSourceMonitorVisible:
    std::map<AssetId, media::RoutedMediaInfo> _routing;

    Project _project;
    std::unique_ptr<UndoStack> _undo;
    uint64_t _changeBase;      // changeCount of earlier projects' undo stacks
    uint64_t _extraChanges;    // changes outside the undo stack (relinks on open)
    bool _metadataDirty;       // relinked paths not saved yet
    uint64_t _projectGeneration; // drops async results that belong to a replaced project
    uint64_t _idFloor; // highest IdGenerator value the project has reached (see FreshIds)
    std::vector<std::pair<AssetId, size_t>> _lastUseCounts;
    NSArray<NSString *> *_loadWarnings;
    VERippleScope _rippleScope;
    NSMutableArray<dispatch_block_t> *_deferredImports; // imports waiting for a coalescing group
    NSString *_coalescingKey;
    NSString *_gestureEditKey; // set while performInCoalescingGroup:edit: runs its block

    std::map<AssetId, AssetDetails> _details;
    std::set<AssetId> _missing;
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

// MARK: - Versions

+ (NSString *)engineVersion {
    NSBundle *bundle = [NSBundle bundleForClass:self];
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSAssert(version.length > 0, @"FramewrightEngine.framework Info.plist has no CFBundleShortVersionString");
    return version ?: @"";
}

+ (NSString *)ffmpegVersion {
    return @(av_version_info());
}

+ (NSString *)ffmpegLicense {
    return @(avcodec_license());
}

// MARK: - Lifetime

+ (nullable NSURL *)defaultCacheDirectory {
    NSURL *support = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
                                                          inDomain:NSUserDomainMask
                                                 appropriateForURL:nil
                                                            create:YES
                                                             error:nil];
    return [[support URLByAppendingPathComponent:@"Framewright" isDirectory:YES] URLByAppendingPathComponent:@"Caches"
                                                                                               isDirectory:YES];
}

- (instancetype)init {
    return [self initWithCacheDirectory:[VEEngine defaultCacheDirectory]];
}

- (instancetype)initWithCacheDirectory:(nullable NSURL *)cacheDirectory {
    VE_ASSERT_MAIN();
    if ((self = [super init])) {
        _log = os_log_create("com.justjohn12345.framewright.engine", "Facade");
        _router = media::BackendRouter::makeDefault();
        (void)_router->registerBackend(media::ffmpeg::makeFFmpegBackend());
        _frameCache = std::make_shared<media::FrameCache>();
        _mediaEpoch = _frameCache->epoch();
        media::DecodePool::Config programPoolConfig;
        programPoolConfig.budgetFraction = kProgramPoolBudgetShare;
        _decodePool = std::make_shared<media::DecodePool>(_router, _frameCache, programPoolConfig);
        thumbs::ThumbnailService::Config thumbConfig;
        thumbs::WaveformService::Config waveConfig;
        if (cacheDirectory != nil) {
            thumbConfig.diskCacheDirectory =
                toStd([cacheDirectory URLByAppendingPathComponent:@"Thumbnails" isDirectory:YES].path);
            waveConfig.diskCacheDirectory =
                toStd([cacheDirectory URLByAppendingPathComponent:@"Waveforms" isDirectory:YES].path);
        }
        _thumbnails = std::make_unique<thumbs::ThumbnailService>(_router, thumbConfig);
        _waveforms = std::make_unique<thumbs::WaveformService>(_router, waveConfig);
        media::DecodePool::Config sourcePoolConfig;
        sourcePoolConfig.budgetFraction = kSourcePoolBudgetShare;
        _sourcePool = std::make_shared<media::DecodePool>(_router, _frameCache, sourcePoolConfig);
        _sourceProvider = std::make_shared<ProgramFrameProvider>(_sourcePool, kSourceScrubLaneBase);
        _sourceTime = kCMTimeZero;
        _sourceUsesController = false;
        _sourceMonitorVisible = YES;
        _playbackGeneration = 0;
        _playbackPublished = false;
        _idFloor = 0;
        _loadWarnings = @[];
        _rippleScope = VERippleScopeAllTracks;
        _deferredImports = [NSMutableArray array];
        playback::PlaybackConfig config;
        config.scrubLaneBase = kProgramLaneBase;
        _playback = std::make_unique<playback::PlaybackController>(_router, _frameCache, _decodePool, config);
        [self observeController:*_playback source:NO];
        _undo = std::make_unique<UndoStack>();
        _changeBase = 0;
        _extraChanges = 0;
        _metadataDirty = false;
        _projectGeneration = 0;
        _bookmarks = [NSMutableDictionary dictionary];
        _accessedURLs = [NSMutableArray array];
        _observers = [NSHashTable weakObjectsHashTable];
        _probeQueue = dispatch_queue_create("com.justjohn12345.framewright.engine.probe",
                                            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT,
                                                                                    QOS_CLASS_USER_INITIATED, 0));
        // Probe VideoToolbox once off the main thread so the Preferences pane never waits.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            (void)media::HardwareCaps::get();
        });
        // The handler runs on the main queue: it touches the preview views and the model's asset
        // list, and the frame cache purge is cheap.
        _memoryPressureSource = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0, DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
            dispatch_get_main_queue());
        dispatch_source_t source = _memoryPressureSource;
        __weak VEEngine *weakSelf = self;
        dispatch_source_set_event_handler(_memoryPressureSource, ^{
            const unsigned long level = dispatch_source_get_data(source);
            [weakSelf handleMemoryPressure:(level & DISPATCH_MEMORYPRESSURE_CRITICAL) != 0];
        });
        dispatch_resume(_memoryPressureSource);
        [self resetToEmptyProjectNamed:@"Untitled"];
        [self publishPlaybackSnapshot];
    }
    return self;
}

- (void)dealloc {
    // The last reference must be released on the main thread (see VEEngine.h): detaching the
    // monitor views below is main-thread AppKit work.
    if (!NSThread.isMainThread) {
        os_log_fault(_log, "VEEngine deallocated off the main thread; release it on the main thread");
    }
    if (_memoryPressureSource != nil) {
        dispatch_source_cancel(_memoryPressureSource);
    }
    [_activeExport cancel]; // the job deletes its partial file on its own queue
    // The views may outlive the engine: they must stop calling into the controllers first.
    [_programView setFrameSource:ve::render::PreviewFrameSource{}];
    [_outputView setFrameSource:ve::render::PreviewFrameSource{}];
    [_sourceView setFrameSource:ve::render::PreviewFrameSource{}];
    [self stopAccessingURLs];
}

- (void)addObserver:(id<VEEngineObserver>)observer {
    VE_ASSERT_MAIN();
    [_observers addObject:observer];
}

- (void)removeObserver:(id<VEEngineObserver>)observer {
    VE_ASSERT_MAIN();
    [_observers removeObject:observer];
}

// MARK: - Notifications

- (void)notifyModelChanged {
    [self publishPlaybackSnapshot];
    [self updateUseCounts];
    const uint64_t count = self.changeCount;
    [NSNotificationCenter.defaultCenter postNotificationName:VEEngineModelDidChangeNotification
                                                      object:self
                                                    userInfo:@{VEEngineChangeCountKey : @(count)}];
    for (id<VEEngineObserver> observer in _observers.allObjects) {
        if ([observer respondsToSelector:@selector(engine:modelDidChange:)]) {
            [observer engine:self modelDidChange:count];
        }
    }
}

/// Posts an assets notification when a clip edit changed how often an asset is used
/// (VEAssetInfo.useCount), so the media bin does not show stale counts.
- (void)updateUseCounts {
    std::map<AssetId, size_t> counts;
    for (const Sequence &sequence : _project.sequences) {
        for (const auto *tracks : {&sequence.videoTracks, &sequence.audioTracks}) {
            for (const Track &track : *tracks) {
                for (const Clip &clip : track.clips) {
                    ++counts[clip.assetId];
                }
            }
        }
    }
    std::vector<std::pair<AssetId, size_t>> current;
    current.reserve(_project.assets.size());
    for (const MediaAsset &asset : _project.assets) {
        auto it = counts.find(asset.id);
        current.emplace_back(asset.id, it == counts.end() ? 0 : it->second);
    }
    if (current != _lastUseCounts) {
        _lastUseCounts = std::move(current);
        [self notifyAssetsChanged];
    }
}

- (void)notifyAssetsChanged {
    [NSNotificationCenter.defaultCenter postNotificationName:VEEngineAssetsDidChangeNotification
                                                      object:self
                                                    userInfo:nil];
    for (id<VEEngineObserver> observer in _observers.allObjects) {
        if ([observer respondsToSelector:@selector(engineAssetsDidChange:)]) {
            [observer engineAssetsDidChange:self];
        }
    }
}

- (void)notifyThumbnailForAsset:(AssetId)asset {
    const auto assetID = static_cast<VEAssetID>(asset.value());
    [NSNotificationCenter.defaultCenter postNotificationName:VEEngineThumbnailDidBecomeAvailableNotification
                                                      object:self
                                                    userInfo:@{VEEngineAssetIDKey : @(assetID)}];
    for (id<VEEngineObserver> observer in _observers.allObjects) {
        if ([observer respondsToSelector:@selector(engine:thumbnailAvailableForAsset:)]) {
            [observer engine:self thumbnailAvailableForAsset:assetID];
        }
    }
}

- (void)notifyWaveformForAsset:(AssetId)asset {
    const auto assetID = static_cast<VEAssetID>(asset.value());
    [NSNotificationCenter.defaultCenter postNotificationName:VEEngineWaveformDidBecomeAvailableNotification
                                                      object:self
                                                    userInfo:@{VEEngineAssetIDKey : @(assetID)}];
    for (id<VEEngineObserver> observer in _observers.allObjects) {
        if ([observer respondsToSelector:@selector(engine:waveformAvailableForAsset:)]) {
            [observer engine:self waveformAvailableForAsset:assetID];
        }
    }
}

// MARK: - Project

- (void)stopAccessingURLs {
    for (NSURL *url in _accessedURLs) {
        [url stopAccessingSecurityScopedResource];
    }
    [_accessedURLs removeAllObjects];
}

/// Forgets everything cached for the current project's assets (ids restart in every project).
- (void)forgetProjectMedia {
    // A running export renders the old project, whose ids are about to name other media.
    [_activeExport cancel];
    // The controllers stop using the old assets first (their ids will name other files).
    _playback->setSequence(std::make_shared<const Project>(), SequenceId{});
    _playbackPublished = false;
    [self resetSourceMonitor]; // stops the source controller and drops its private project
    for (const MediaAsset &asset : _project.assets) {
        _thumbnails->cancelPending(asset.id);
        _thumbnails->purge(asset.id);
        _waveforms->purge(asset.id);
    }
    // A new media epoch: the frame cache drops every frame and refuses any decoded for the old
    // ids, and both decode pools forget every asset, target, scrub request and decoder, so no
    // decode in flight can publish the previous project's picture under a reused id (see
    // FrameCache.h and DecodePool.h). The controllers register the new project's assets again.
    _mediaEpoch = _frameCache->beginEpoch();
    _decodePool->beginEpoch(_mediaEpoch);
    _sourcePool->beginEpoch(_mediaEpoch);
    _playback->forgetMedia();
    if (_sourcePlayback) {
        _sourcePlayback->forgetMedia();
    }
    _routing.clear();
    _details.clear();
    _missing.clear();
    [_bookmarks removeAllObjects];
    [self stopAccessingURLs];
    ++_projectGeneration;
}

/// Installs `project` as the current project with a fresh undo history.
- (void)installProject:(Project)project url:(nullable NSURL *)url {
    [self forgetProjectMedia];
    _changeBase += _undo->changeCount() + _extraChanges + 1;
    _extraChanges = 0;
    _metadataDirty = false;
    _mediaFolderBookmark = nil;
    _undo = std::make_unique<UndoStack>();
    _coalescingKey = nil;
    _project = std::move(project);
    _projectURL = url;
    _idFloor = _project.ids.nextValue();
    _loadWarnings = @[];
    _lastUseCounts.clear();
    // Imports waiting for the old project's gesture belong to the old project: run them now
    // (they see the new generation and report the project as closed).
    [self flushDeferredImports];
}

- (void)resetToEmptyProjectNamed:(NSString *)name {
    Project project;
    project.name = toStd(name);
    project.addSequence("Sequence 1", CMTimeMake(1, 30), 1920, 1080, 2, 2);
    [self installProject:std::move(project) url:nil];
}

- (void)newProjectWithName:(NSString *)name {
    VE_ASSERT_MAIN();
    [self resetToEmptyProjectNamed:name];
    [self notifyAssetsChanged];
    [self notifyModelChanged];
}

- (BOOL)openProjectAtURL:(NSURL *)url error:(NSError *_Nullable *_Nullable)error {
    VE_ASSERT_MAIN();
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&readError];
    if (data == nil) {
        if (error != nullptr) {
            *error = makeError(VEEngineErrorReadFailed,
                               [NSString stringWithFormat:@"Cannot read %@: %@", url.lastPathComponent,
                                                          readError.localizedDescription ?: @"unknown error"]);
        }
        return NO;
    }
    const std::string text(static_cast<const char *>(data.bytes), data.length);
    ProjectLoadResult loaded = parseProject(text);
    if (!loaded.ok()) {
        if (error != nullptr) {
            *error = makeError(VEEngineErrorInvalidProject,
                               [NSString stringWithFormat:@"%@ is not a valid Framewright project: %@",
                                                          url.lastPathComponent, toNS(loaded.error)]);
        }
        return NO;
    }
    Project project = std::move(*loaded.project);
    if (project.activeSequence() == nullptr) {
        if (error != nullptr) {
            *error = makeError(VEEngineErrorInvalidProject,
                               [NSString stringWithFormat:@"%@ has no sequence", url.lastPathComponent]);
        }
        return NO;
    }

    // Bookmarks are an extension of the model's JSON (unknown keys are ignored by the parser).
    NSMutableDictionary<NSNumber *, NSData *> *bookmarks = [NSMutableDictionary dictionary];
    const nlohmann::json json = nlohmann::json::parse(text, nullptr, false);
    if (json.is_object()) {
        auto it = json.find(kBookmarksKey);
        if (it != json.end() && it->is_object()) {
            for (auto entry = it->begin(); entry != it->end(); ++entry) {
                if (!entry.value().is_string()) {
                    continue;
                }
                NSString *base64 = toNS(entry.value().get<std::string>());
                NSData *bookmark = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
                const long long assetValue = std::atoll(entry.key().c_str());
                if (bookmark != nil && assetValue > 0) {
                    bookmarks[@(assetValue)] = bookmark;
                }
            }
        }
    }

    NSData *mediaFolderBookmark = nil;
    if (json.is_object()) {
        auto it = json.find(kMediaFolderBookmarkKey);
        if (it != json.end() && it->is_string()) {
            mediaFolderBookmark = [[NSData alloc] initWithBase64EncodedString:toNS(it->get<std::string>()) options:0];
        }
    }

    std::vector<std::string> warnings = std::move(loaded.warnings);
    [self installProject:std::move(project) url:url];
    _mediaFolderBookmark = mediaFolderBookmark;
    NSMutableArray<NSString *> *warningStrings = [NSMutableArray arrayWithCapacity:warnings.size()];
    for (const std::string &warning : warnings) {
        [warningStrings addObject:toNS(warning)];
    }
    _loadWarnings = warningStrings;

    // Resolve every asset: through its bookmark (follows moves and grants sandbox access),
    // else by path. The bookmarks resolve in parallel off the main thread, bounded in time.
    NSMutableArray<NSData *> *toResolve = [NSMutableArray array];
    std::vector<size_t> resolvedAsset; // index into _project.assets per entry of toResolve
    for (size_t i = 0; i < _project.assets.size(); ++i) {
        if (NSData *bookmark = bookmarks[@(static_cast<int64_t>(_project.assets[i].id.value()))]) {
            [toResolve addObject:bookmark];
            resolvedAsset.push_back(i);
        }
    }
    const std::vector<ResolvedBookmark> resolutions = resolveBookmarks(toResolve);
    std::vector<std::optional<ResolvedBookmark>> resolutionOf(_project.assets.size());
    for (size_t k = 0; k < resolutions.size(); ++k) {
        resolutionOf[resolvedAsset[k]] = resolutions[k];
    }
    bool relinked = false;
    for (size_t i = 0; i < _project.assets.size(); ++i) {
        MediaAsset &asset = _project.assets[i];
        NSNumber *key = @(static_cast<int64_t>(asset.id.value()));
        NSData *bookmark = bookmarks[key];
        if (resolutionOf[i]) {
            NSURL *resolved = resolutionOf[i]->url;
            const BOOL stale = resolutionOf[i]->stale;
            if (resolved != nil) {
                if ([resolved startAccessingSecurityScopedResource]) {
                    [_accessedURLs addObject:resolved];
                }
                // Bookmarks resolve to canonical paths (/private/var/...): only a different
                // file counts as a relink.
                NSString *canonicalResolved = resolved.URLByResolvingSymlinksInPath.path;
                NSString *canonicalStored = [NSURL fileURLWithPath:toNS(asset.url)].URLByResolvingSymlinksInPath.path;
                const std::string resolvedPath = toStd(resolved.path);
                if (!resolvedPath.empty() && ![canonicalResolved isEqualToString:canonicalStored]) {
                    asset.url = resolvedPath;
                    relinked = true;
                }
                if (!stale) {
                    _bookmarks[key] = bookmark; // reused on save so re-saving is byte identical
                }
            }
        }
        if (![NSFileManager.defaultManager fileExistsAtPath:toNS(asset.url)]) {
            _missing.insert(asset.id);
        }
    }
    if (relinked) {
        _metadataDirty = true;
        ++_extraChanges;
    }

    // Every asset is registered with both decode pools now, the missing ones included (their
    // decodes fail as missing instead of finding whatever the id named before).
    for (const MediaAsset &asset : _project.assets) {
        _decodePool->registerAsset(asset.id, asset.url);
        _sourcePool->registerAsset(asset.id, asset.url);
    }
    [self probeDetailsForProjectAssets];
    [self notifyAssetsChanged];
    [self notifyModelChanged];
    return YES;
}

/// Re-probes the project's assets in the background for the details that are not stored in
/// the project file (codec names, routing reason), and hands the routing to the decode pool.
- (void)probeDetailsForProjectAssets {
    const uint64_t generation = _projectGeneration;
    auto router = _router;
    __weak VEEngine *weakSelf = self;
    for (const MediaAsset &asset : _project.assets) {
        if (_missing.count(asset.id)) {
            continue;
        }
        const AssetId assetId = asset.id;
        const std::string path = asset.url;
        dispatch_async(_probeQueue, ^{
            auto routed = std::make_shared<media::Result<media::RoutedMediaInfo>>(router->probe(path));
            dispatch_async(dispatch_get_main_queue(), ^{
                VEEngine *strongSelf = weakSelf;
                if (strongSelf == nil || strongSelf->_projectGeneration != generation || !routed->ok()) {
                    return;
                }
                const MediaAsset *current = strongSelf->_project.findAsset(assetId);
                if (current == nullptr || current->url != path) {
                    return;
                }
                strongSelf->_details[assetId] = detailsFor(routed->value());
                [strongSelf registerRouting:routed->value() forAsset:assetId path:path];
                [strongSelf notifyAssetsChanged];
            });
        });
    }
}

- (BOOL)saveProjectToURL:(NSURL *)url error:(NSError *_Nullable *_Nullable)error {
    VE_ASSERT_MAIN();
    nlohmann::json json = projectToJson(_project);
    nlohmann::json bookmarks = nlohmann::json::object();
    for (const MediaAsset &asset : _project.assets) {
        NSNumber *key = @(static_cast<int64_t>(asset.id.value()));
        NSData *bookmark = _bookmarks[key];
        if (bookmark == nil && !_missing.count(asset.id)) {
            bookmark = makeBookmark(toNS(asset.url));
            if (bookmark != nil) {
                _bookmarks[key] = bookmark;
            }
        }
        if (bookmark != nil) {
            bookmarks[std::to_string(asset.id.value())] = toStd([bookmark base64EncodedStringWithOptions:0]);
        }
    }
    json[kBookmarksKey] = std::move(bookmarks);
    if (_mediaFolderBookmark != nil) {
        json[kMediaFolderBookmarkKey] = toStd([_mediaFolderBookmark base64EncodedStringWithOptions:0]);
    }
    // Invalid UTF-8 in names or paths is written as U+FFFD rather than throwing.
    const std::string text = json.dump(2, ' ', false, nlohmann::json::error_handler_t::replace) + "\n";
    NSData *data = [NSData dataWithBytes:text.data() length:text.size()];
    NSError *writeError = nil;
    if (![data writeToURL:url options:NSDataWritingAtomic error:&writeError]) {
        if (error != nullptr) {
            *error = makeError(VEEngineErrorWriteFailed,
                               [NSString stringWithFormat:@"Cannot save %@: %@", url.lastPathComponent,
                                                          writeError.localizedDescription ?: @"unknown error"]);
        }
        return NO;
    }
    _projectURL = url;
    _undo->markClean();
    _metadataDirty = false;
    [self notifyModelChanged];
    return YES;
}

- (NSString *)projectName {
    VE_ASSERT_MAIN();
    if (_projectURL != nil) {
        return _projectURL.URLByDeletingPathExtension.lastPathComponent;
    }
    return toNS(_project.name);
}

- (nullable NSURL *)projectURL {
    VE_ASSERT_MAIN();
    return _projectURL;
}

- (BOOL)isDirty {
    VE_ASSERT_MAIN();
    return _undo->isDirty() || _metadataDirty;
}

- (uint64_t)changeCount {
    VE_ASSERT_MAIN();
    return _changeBase + _undo->changeCount() + _extraChanges;
}

- (NSArray<NSString *> *)loadWarnings {
    VE_ASSERT_MAIN();
    return _loadWarnings;
}

- (NSArray<NSNumber *> *)missingAssetIDs {
    VE_ASSERT_MAIN();
    NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
    for (AssetId id : _missing) {
        [ids addObject:@(static_cast<int64_t>(id.value()))];
    }
    return ids;
}

- (NSString *)projectJSON {
    VE_ASSERT_MAIN();
    return toNS(serializeProject(_project));
}

- (nullable NSData *)mediaFolderBookmark {
    VE_ASSERT_MAIN();
    return _mediaFolderBookmark;
}

- (void)setMediaFolderBookmark:(nullable NSData *)mediaFolderBookmark {
    VE_ASSERT_MAIN();
    if (mediaFolderBookmark == _mediaFolderBookmark || [mediaFolderBookmark isEqualToData:_mediaFolderBookmark]) {
        return;
    }
    _mediaFolderBookmark = [mediaFolderBookmark copy];
    // Saved with the project: an unsaved change, outside the undo history.
    _metadataDirty = true;
    ++_extraChanges;
    [self notifyModelChanged];
}

// MARK: - Snapshots

- (const Sequence &)activeSequence {
    const Sequence *sequence = _project.activeSequence();
    NSAssert(sequence != nullptr, @"the project always has an active sequence");
    return *sequence;
}

- (VESequenceInfo *)sequence {
    VE_ASSERT_MAIN();
    return makeSequenceInfo([self activeSequence]);
}

- (nullable VEClipInfo *)clipInfo:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const ClipId id(static_cast<ClipId::ValueType>(clipID));
    const Track *track = sequence.trackOfClip(id);
    const Clip *clip = track ? track->find(id) : nullptr;
    return clip ? makeClipInfo(*clip, *track, _project, sequence.frameDuration) : nil;
}

- (nullable VETrackInfo *)trackInfo:(VETrackID)trackID {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    for (const auto *tracks : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (size_t i = 0; i < tracks->size(); ++i) {
            if ((*tracks)[i].id.value() == static_cast<TrackId::ValueType>(trackID)) {
                return makeTrackInfo((*tracks)[i], NSInteger(i));
            }
        }
    }
    return nil;
}

- (nullable VEAssetInfo *)assetInfo:(VEAssetID)assetID {
    VE_ASSERT_MAIN();
    const MediaAsset *asset = _project.findAsset(AssetId(static_cast<AssetId::ValueType>(assetID)));
    return asset ? [self makeInfoForAsset:*asset] : nil;
}

- (VEAssetInfo *)makeInfoForAsset:(const MediaAsset &)asset {
    auto details = _details.find(asset.id);
    return makeAssetInfo(asset, details == _details.end() ? nullptr : &details->second, _missing.count(asset.id) > 0,
                         NSInteger(countAssetUses(_project, asset.id)));
}

- (nullable VETransitionInfo *)transitionInfo:(VETransitionID)transitionID {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const Transition *t = sequence.findTransition(TransitionId(static_cast<TransitionId::ValueType>(transitionID)));
    return t ? makeTransitionInfo(*t, sequence) : nil;
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
    const Track *track = [self activeSequence].findTrack(TrackId(static_cast<TrackId::ValueType>(trackID)));
    NSMutableArray<VEClipInfo *> *clips = [NSMutableArray array];
    if (track != nullptr) {
        for (const Clip &clip : track->clips) {
            [clips addObject:makeClipInfo(clip, *track, _project, [self activeSequence].frameDuration)];
        }
    }
    return clips;
}

- (NSArray<VEClipInfo *> *)allClips {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    NSMutableArray<VEClipInfo *> *clips = [NSMutableArray array];
    for (const auto *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (const Track &track : *list) {
            for (const Clip &clip : track.clips) {
                [clips addObject:makeClipInfo(clip, track, _project, sequence.frameDuration)];
            }
        }
    }
    return clips;
}

- (NSArray<NSNumber *> *)clipIDsAtTime:(CMTime)time {
    VE_ASSERT_MAIN();
    return toNumbers(Scheduler::clipsAt([self activeSequence], time));
}

// MARK: - Media

- (void)importMediaAtURLs:(NSArray<NSURL *> *)urls
               completion:(nullable void (^)(NSArray<VEAssetInfo *> *, NSArray<NSError *> *))completion {
    VE_ASSERT_MAIN();
    auto router = _router;
    const size_t count = urls.count;
    const uint64_t generation = _projectGeneration;
    auto results = std::make_shared<std::vector<ProbedFile>>(count);
    NSArray<NSURL *> *files = [urls copy];
    __weak VEEngine *weakSelf = self;
    dispatch_queue_t queue = _probeQueue;
    dispatch_async(queue, ^{
        // Probe in parallel (each probe blocks on file I/O).
        dispatch_apply(count, queue, ^(size_t i) {
            ProbedFile &file = (*results)[i];
            NSURL *url = files[i];
            const std::string path = toStd(url.path);
            BOOL accessing = [url startAccessingSecurityScopedResource];
            auto routed = router->probe(path);
            if (!routed.ok()) {
                file.error = makeError(routed.error(), url.lastPathComponent);
            } else {
                auto asset = media::makeMediaAsset(routed.value(), AssetId(1));
                if (!asset.ok()) {
                    file.error = makeError(asset.error(), url.lastPathComponent);
                } else {
                    file.details = detailsFor(routed.value());
                    file.asset = std::move(asset).value();
                    file.routed = std::move(routed).value();
                    file.bookmark = makeBookmark(url.path);
                }
            }
            if (accessing) {
                [url stopAccessingSecurityScopedResource];
            }
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishImport:results urls:files generation:generation completion:completion];
        });
    });
}

- (void)finishImport:(std::shared_ptr<std::vector<ProbedFile>>)probed
                urls:(NSArray<NSURL *> *)urls
          generation:(uint64_t)generation
          completion:(nullable void (^)(NSArray<VEAssetInfo *> *, NSArray<NSError *> *))completion {
    if (generation != _projectGeneration) {
        // The project was replaced while probing: these files belong to a closed project.
        NSMutableArray<NSError *> *errors = [NSMutableArray arrayWithCapacity:urls.count];
        for (NSURL *url in urls) {
            [errors addObject:makeError(VEEngineErrorProjectClosed,
                                        [NSString stringWithFormat:@"%@ was not imported: the project was closed",
                                                                   url.lastPathComponent])];
        }
        if (completion) {
            completion(@[], errors);
        }
        return;
    }
    if (_coalescingKey != nil) {
        // A gesture is in progress: adding the assets now would end its undo group (and its
        // edits are expressed against the state when it began). Add them when it ends.
        __weak VEEngine *weakSelf = self;
        [_deferredImports addObject:^{
            [weakSelf finishImport:probed urls:urls generation:generation completion:completion];
        }];
        return;
    }
    std::vector<ProbedFile> &results = *probed;
    const os_signpost_id_t signpost = os_signpost_id_generate(_log);
    os_signpost_interval_begin(_log, signpost, "ImportMainThread", "%zu files", results.size());
    const CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();

    NSMutableArray<NSError *> *errors = [NSMutableArray array];
    NSMutableArray<NSNumber *> *reportedIDs = [NSMutableArray array];
    std::vector<MediaAsset> toAdd;
    std::vector<size_t> sourceIndex;
    for (size_t i = 0; i < results.size(); ++i) {
        ProbedFile &file = results[i];
        if (!file.asset) {
            [errors addObject:file.error ?: makeError(VEEngineErrorImportFailed, @"import failed")];
            continue;
        }
        auto existing = std::find_if(_project.assets.begin(), _project.assets.end(),
                                     [&](const MediaAsset &a) { return a.url == file.asset->url; });
        if (existing != _project.assets.end()) {
            [reportedIDs addObject:@(static_cast<int64_t>(existing->id.value()))];
            continue;
        }
        toAdd.push_back(*file.asset);
        sourceIndex.push_back(i);
    }
    if (!toAdd.empty()) {
        auto command = std::make_unique<ImportAssets>(std::move(toAdd));
        ImportAssets *import = command.get();
        EditResult result = [self pushCommand:std::move(command)];
        if (!result) {
            [errors addObject:makeError(VEEngineErrorImportFailed, toNS(result.message))];
        } else {
            const std::vector<AssetId> &ids = import->createdAssetIds();
            for (size_t k = 0; k < ids.size(); ++k) {
                ProbedFile &file = results[sourceIndex[k]];
                const AssetId id = ids[k];
                _details[id] = file.details;
                // Ids are never reused, but never let a stale entry name another file.
                _bookmarks[@(static_cast<int64_t>(id.value()))] = file.bookmark;
                _missing.erase(id);
                // Keep sandbox access to the file for this session (bookmark resolution
                // grants it again after reopening).
                NSURL *url = urls[sourceIndex[k]];
                if ([url startAccessingSecurityScopedResource]) {
                    [_accessedURLs addObject:url];
                }
                [self registerRouting:*file.routed forAsset:id path:file.asset->url];
                [self startPosterAndWaveformForAsset:id];
                [reportedIDs addObject:@(static_cast<int64_t>(id.value()))];
            }
        }
    }
    NSMutableArray<VEAssetInfo *> *assets = [NSMutableArray array];
    for (NSNumber *n in reportedIDs) {
        if (VEAssetInfo *info = [self assetInfo:n.longLongValue]) {
            [assets addObject:info];
        }
    }
    const bool changed = !toAdd.empty() || reportedIDs.count > 0;
    _mainThreadImportSeconds += CFAbsoluteTimeGetCurrent() - start;
    os_signpost_interval_end(_log, signpost, "ImportMainThread");
    if (changed) {
        [self notifyAssetsChanged];
        [self notifyModelChanged];
    }
    if (completion) {
        completion(assets, errors);
    }
}

- (NSUInteger)deferredImportCount {
    VE_ASSERT_MAIN();
    return _deferredImports.count;
}

- (void)startPosterAndWaveformForAsset:(AssetId)id {
    const MediaAsset *asset = _project.findAsset(id);
    if (asset == nullptr) {
        return;
    }
    const uint64_t generation = _projectGeneration;
    __weak VEEngine *weakSelf = self;
    if (asset->hasVideo()) {
        thumbs::ThumbnailRequest request;
        request.asset = id;
        request.url = asset->url;
        request.time = kCMTimeZero;
        request.maxDimension = kPosterMaxDimension;
        _thumbnails->request(request, dispatch_get_main_queue(), [weakSelf, generation, id](auto result) {
            VEEngine *strongSelf = weakSelf;
            if (strongSelf != nil && strongSelf->_projectGeneration == generation && result.ok()) {
                [strongSelf notifyThumbnailForAsset:id];
            }
        });
    }
    if (asset->hasAudio()) {
        thumbs::WaveformRequest request;
        request.asset = id;
        request.url = asset->url;
        _waveforms->request(request, dispatch_get_main_queue(), [weakSelf, generation, id](auto result) {
            VEEngine *strongSelf = weakSelf;
            if (strongSelf != nil && strongSelf->_projectGeneration == generation && result.ok()) {
                [strongSelf notifyWaveformForAsset:id];
            }
        });
    }
}

- (VEEditResult *)removeAsset:(VEAssetID)assetID {
    VE_ASSERT_MAIN();
    const AssetId id(static_cast<AssetId::ValueType>(assetID));
    if (_coalescingKey != nil) {
        return [VEEditResult failureWithCode:VEEditErrorBusy
                                     message:@"Finish the current edit before removing media."];
    }
    EditResult result = [self pushCommand:std::make_unique<RemoveAsset>(id)];
    if (result) {
        [self notifyAssetsChanged];
        [self notifyModelChanged];
    }
    return toVE(result);
}

- (void)thumbnailForAsset:(VEAssetID)assetID
                   atTime:(CMTime)time
             maxDimension:(NSInteger)maxDimension
               completion:(void (^)(CGImageRef _Nullable, NSError *_Nullable))completion {
    VE_ASSERT_MAIN();
    const AssetId id(static_cast<AssetId::ValueType>(assetID));
    const MediaAsset *asset = _project.findAsset(id);
    if (asset == nullptr || !asset->hasVideo() || _missing.count(id)) {
        NSError *error = makeError(VEEngineErrorReadFailed, asset == nullptr ? @"unknown asset"
                                                            : !asset->hasVideo() ? @"the asset has no picture"
                                                                                 : @"the media file is missing");
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NULL, error);
        });
        return;
    }
    thumbs::ThumbnailRequest request;
    request.asset = id;
    request.url = asset->url;
    request.time = asset->isStill() || !CMTIME_IS_NUMERIC(time) ? kCMTimeZero : time;
    request.maxDimension = int(std::clamp<NSInteger>(maxDimension, 16, 4096));
    const uint64_t generation = _projectGeneration;
    __weak VEEngine *weakSelf = self;
    _thumbnails->request(request, dispatch_get_main_queue(),
                         [weakSelf, generation, completion](media::Result<thumbs::ThumbnailImage> result) {
                             VEEngine *strongSelf = weakSelf;
                             if (strongSelf == nil || strongSelf->_projectGeneration != generation) {
                                 completion(NULL, makeError(VEEngineErrorProjectClosed, @"the project was closed"));
                             } else if (!result.ok()) {
                                 completion(NULL, makeError(result.error(), @"thumbnail"));
                             } else {
                                 completion(result.value().get(), nil);
                             }
                         });
}

- (void)waveformForAsset:(VEAssetID)assetID completion:(void (^)(VEWaveform *_Nullable, NSError *_Nullable))completion {
    VE_ASSERT_MAIN();
    const AssetId id(static_cast<AssetId::ValueType>(assetID));
    const MediaAsset *asset = _project.findAsset(id);
    if (asset == nullptr || !asset->hasAudio() || _missing.count(id)) {
        NSError *error = makeError(VEEngineErrorReadFailed, asset == nullptr ? @"unknown asset"
                                                            : !asset->hasAudio() ? @"the asset has no audio"
                                                                                 : @"the media file is missing");
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, error);
        });
        return;
    }
    thumbs::WaveformRequest request;
    request.asset = id;
    request.url = asset->url;
    const uint64_t generation = _projectGeneration;
    __weak VEEngine *weakSelf = self;
    _waveforms->request(request, dispatch_get_main_queue(),
                        [weakSelf, generation, completion, id](thumbs::WaveformResult result) {
                            VEEngine *strongSelf = weakSelf;
                            if (strongSelf == nil || strongSelf->_projectGeneration != generation) {
                                completion(nil, makeError(VEEngineErrorProjectClosed, @"the project was closed"));
                            } else if (!result.ok()) {
                                completion(nil, makeError(result.error(), @"waveform"));
                            } else {
                                completion(makeWaveform(id, result.value()), nil);
                            }
                        });
}

- (nullable VEWaveform *)cachedWaveformForAsset:(VEAssetID)assetID {
    VE_ASSERT_MAIN();
    const AssetId id(static_cast<AssetId::ValueType>(assetID));
    auto peaks = _waveforms->cached(id);
    return peaks ? makeWaveform(id, peaks) : nil;
}

- (VEHardwareCaps *)hardwareCaps {
    VE_ASSERT_MAIN();
    return makeHardwareCaps();
}

- (NSArray<NSString *> *)backendNames {
    VE_ASSERT_MAIN();
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (const std::string &name : _router->backendNames()) {
        [names addObject:toNS(name)];
    }
    return names;
}

- (nullable NSString *)preferredBackend {
    VE_ASSERT_MAIN();
    auto policy = _router->defaultPolicy();
    return policy.preferBackendName ? toNS(*policy.preferBackendName) : nil;
}

- (void)setPreferredBackend:(nullable NSString *)preferredBackend {
    VE_ASSERT_MAIN();
    media::RoutingPolicy policy = _router->defaultPolicy();
    if (preferredBackend.length > 0) {
        policy.preferBackendName = toStd(preferredBackend);
    } else {
        policy.preferBackendName.reset();
    }
    _router->setDefaultPolicy(policy);
}

- (NSUInteger)frameCacheBudgetBytes {
    VE_ASSERT_MAIN();
    return _frameCache->budget();
}

- (void)setFrameCacheBudgetBytes:(NSUInteger)frameCacheBudgetBytes {
    VE_ASSERT_MAIN();
    _frameCache->setBudget(std::max<NSUInteger>(frameCacheBudgetBytes, NSUInteger(16) << 20));
}

- (double)mainThreadImportSeconds {
    VE_ASSERT_MAIN();
    return _mainThreadImportSeconds;
}

- (void)handleMemoryPressure:(BOOL)critical {
    VE_ASSERT_MAIN();
    _frameCache->handleMemoryPressure(critical ? media::MemoryPressure::Critical : media::MemoryPressure::Warning);
    [_programView handleMemoryPressure];
    [_outputView handleMemoryPressure];
    [_sourceView handleMemoryPressure];
    if (auto job = exportJobOf(_activeExport)) {
        job->handleMemoryPressure(critical);
    }
    for (const MediaAsset &asset : _project.assets) {
        _thumbnails->purge(asset.id);
        _waveforms->purge(asset.id);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:VEEngineMemoryPressureNotification
                                                      object:self
                                                    userInfo:@{VEEngineCriticalKey : @(critical)}];
}

/// Hands an asset's routing to every decode path (saves a probe per decoder).
- (void)registerRouting:(const media::RoutedMediaInfo &)routed forAsset:(AssetId)asset path:(const std::string &)path {
    _routing[asset] = routed;
    _decodePool->registerAsset(asset, path, routed);
    _sourcePool->registerAsset(asset, path, routed);
    _playback->setAssetRouting(asset, routed);
    if (_sourcePlayback) {
        _sourcePlayback->setAssetRouting(asset, routed);
    }
}

// MARK: - Edits

- (SequenceId)sequenceId {
    return _project.activeSequenceId;
}

/// Pushes a command onto the undo stack, wrapped so it never reuses an id (see FreshIds). Only
/// the open gesture's own edits (made inside performInCoalescingGroup:edit: with the group's
/// key) join its coalescing group; any other edit first ends the group, committing the gesture
/// as one undo step, and is then pushed on its own.
- (EditResult)pushCommand:(std::unique_ptr<Command>)command {
    if (_coalescingKey != nil && ![_gestureEditKey isEqualToString:_coalescingKey]) {
        [self closeCoalescingIfOpen];
    }
    _idFloor = std::max(_idFloor, _project.ids.nextValue());
    auto wrapped = std::make_unique<FreshIds>(std::move(command), _idFloor);
    if (_coalescingKey != nil) {
        wrapped->setCoalescingKey(toStd(_coalescingKey));
    }
    EditResult result = _undo->push(_project, std::move(wrapped));
    _idFloor = std::max(_idFloor, _project.ids.nextValue());
    return result;
}

/// Pushes an edit and notifies on success.
- (VEEditResult *)push:(std::unique_ptr<Command>)command created:(NSArray<NSNumber *> * (^_Nullable)(void))created {
    return [self push:std::move(command) created:created note:nil];
}

- (VEEditResult *)push:(std::unique_ptr<Command>)command
               created:(NSArray<NSNumber *> * (^_Nullable)(void))created
                  note:(nullable NSString *)note {
    EditResult result = [self pushCommand:std::move(command)];
    if (!result) {
        return toVE(result);
    }
    NSArray<NSNumber *> *ids = created ? created() : @[];
    [self notifyModelChanged];
    return toVE(result, ids, note);
}

/// Pushes the ripple edit `make` builds for `scope`; with the all-tracks scope refused because
/// another track is in the way, retries on the synced tracks and says so.
- (VEEditResult *)pushRipple:(std::unique_ptr<Command> (^)(RippleScope scope))make
                     created:(NSArray<NSNumber *> * (^_Nullable)(void))created {
    return [self pushRipple:make scope:_rippleScope created:created];
}

- (VEEditResult *)pushRipple:(std::unique_ptr<Command> (^)(RippleScope scope))make
                       scope:(VERippleScope)rippleScope
                     created:(NSArray<NSNumber *> * (^_Nullable)(void))created {
    return [self pushRipple:make scope:rippleScope created:created note:nil];
}

/// `note`: what the user should know when the edit succeeds (joined with the ripple fallback's).
- (VEEditResult *)pushRipple:(std::unique_ptr<Command> (^)(RippleScope scope))make
                       scope:(VERippleScope)rippleScope
                     created:(NSArray<NSNumber *> * (^_Nullable)(void))created
                        note:(nullable NSString *)note {
    if (rippleScope == VERippleScopeSyncedTracks) {
        return [self push:make(RippleScope::SyncedTracks) created:created note:note];
    }
    EditResult result = [self pushCommand:make(RippleScope::AllUnlockedTracks)];
    if (result.error == EditError::Overlap) {
        NSString *fallback = @"Other tracks have clips in the way, so only the edited clips' tracks were rippled.";
        return [self push:make(RippleScope::SyncedTracks)
                  created:created
                     note:note.length > 0 ? [NSString stringWithFormat:@"%@ %@", note, fallback] : fallback];
    }
    if (!result) {
        return toVE(result);
    }
    NSArray<NSNumber *> *ids = created ? created() : @[];
    [self notifyModelChanged];
    return toVE(result, ids, note);
}

- (void)closeCoalescingIfOpen {
    if (_coalescingKey != nil) {
        _undo->endCoalescing();
        _coalescingKey = nil;
    }
    [self flushDeferredImports];
}

/// Runs the imports that finished while a coalescing group was open (on the next main-queue
/// turn, so the caller that ended the group finishes first).
- (void)flushDeferredImports {
    if (_deferredImports.count == 0) {
        return;
    }
    NSArray<dispatch_block_t> *pending = [_deferredImports copy];
    [_deferredImports removeAllObjects];
    for (dispatch_block_t block in pending) {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

- (std::vector<ClipPlacement>)placementsForAsset:(const MediaAsset &)asset
                                      videoTrack:(VETrackID)videoTrackID
                                      audioTrack:(VETrackID)audioTrackID
                                        sourceIn:(CMTime)sourceIn
                                       sourceOut:(CMTime)sourceOut {
    std::vector<ClipPlacement> placements;
    auto configure = [&](TrackId track) {
        ClipPlacement p = placementForAsset(asset, track);
        if (asset.isStill()) {
            if (CMTIME_IS_NUMERIC(sourceIn) && CMTIME_IS_NUMERIC(sourceOut) && sourceIn < sourceOut) {
                p.sourceIn = kCMTimeZero;
                p.sourceOut = sourceOut - sourceIn;
            }
        } else {
            if (CMTIME_IS_NUMERIC(sourceIn)) {
                p.sourceIn = sourceIn;
            }
            if (CMTIME_IS_NUMERIC(sourceOut)) {
                p.sourceOut = sourceOut;
            }
        }
        placements.push_back(p);
    };
    if (asset.hasVideo() && videoTrackID != 0) {
        configure(TrackId(static_cast<TrackId::ValueType>(videoTrackID)));
    }
    if (asset.hasAudio() && audioTrackID != 0) {
        configure(TrackId(static_cast<TrackId::ValueType>(audioTrackID)));
    }
    return placements;
}

- (VEEditResult *)placeAsset:(VEAssetID)assetID
                      atTime:(CMTime)time
                  videoTrack:(VETrackID)videoTrackID
                  audioTrack:(VETrackID)audioTrackID
                    sourceIn:(CMTime)sourceIn
                   sourceOut:(CMTime)sourceOut
                   overwrite:(BOOL)overwrite {
    VE_ASSERT_MAIN();
    const MediaAsset *asset = _project.findAsset(AssetId(static_cast<AssetId::ValueType>(assetID)));
    if (asset == nullptr) {
        return [VEEditResult failureWithMessage:@"The media is not in the project."];
    }
    std::vector<ClipPlacement> placements = [self placementsForAsset:*asset
                                                          videoTrack:videoTrackID
                                                          audioTrack:audioTrackID
                                                            sourceIn:sourceIn
                                                           sourceOut:sourceOut];
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
    if (overwrite) {
        auto command = std::make_unique<OverwriteClip>([self sequenceId], time, std::move(placements), link);
        OverwriteClip *raw = command.get();
        return [self push:std::move(command)
                  created:^NSArray<NSNumber *> * {
                      return toNumbers(raw->createdClipIds());
                  }
                     note:note];
    }
    __block InsertClip *raw = nullptr;
    const SequenceId sequenceId = [self sequenceId];
    return [self pushRipple:^std::unique_ptr<Command>(RippleScope scope) {
        InsertOptions options;
        options.linkPair = link;
        options.ripple = scope;
        auto command = std::make_unique<InsertClip>(sequenceId, time, placements, options);
        raw = command.get();
        return command;
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
    return [self push:std::make_unique<MoveClip>([self sequenceId], ClipId(static_cast<ClipId::ValueType>(clipID)),
                                                 TrackId(static_cast<TrackId::ValueType>(trackID)), start)
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
    return [self push:std::make_unique<TrimClipHead>([self sequenceId], ClipId(static_cast<ClipId::ValueType>(clipID)),
                                                     time, options)
              created:nil];
}

- (VEEditResult *)trimClipTail:(VEClipID)clipID toTime:(CMTime)time clamp:(BOOL)clamp {
    VE_ASSERT_MAIN();
    TrimOptions options;
    options.clampToLimits = clamp;
    return [self push:std::make_unique<TrimClipTail>([self sequenceId], ClipId(static_cast<ClipId::ValueType>(clipID)),
                                                     time, options)
              created:nil];
}

- (VEEditResult *)splitClip:(VEClipID)clipID atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    auto command =
        std::make_unique<SplitClip>([self sequenceId], ClipId(static_cast<ClipId::ValueType>(clipID)), time);
    SplitClip *raw = command.get();
    return [self push:std::move(command)
              created:^NSArray<NSNumber *> * {
                  return toNumbers(raw->createdClipIds());
              }];
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
    std::vector<ClipId> candidates = clipIDs.count > 0 ? toClipIds(clipIDs) : Scheduler::clipsAt(sequence, at);
    std::set<ClipId> covered;
    std::vector<std::unique_ptr<Command>> children;
    std::vector<SplitClip *> splits;
    for (ClipId id : candidates) {
        const Track *track = sequence.trackOfClip(id);
        const Clip *clip = track ? track->find(id) : nullptr;
        if (clip == nullptr || covered.count(id) || !(clip->timelineStart < at && at < clip->timelineEnd())) {
            continue;
        }
        if (clipIDs.count == 0 && track->locked) {
            continue;
        }
        covered.insert(id);
        if (clip->linkedClipId) {
            covered.insert(*clip->linkedClipId); // SplitClip splits the partner too
        }
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
    if (children.size() == 1) {
        return [self push:std::move(children.front()) created:createdBlock];
    }
    return [self push:std::make_unique<CompositeCommand>("Split", std::move(children)) created:createdBlock];
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
    const ClipId id(static_cast<ClipId::ValueType>(clipID));
    VideoParams video = fromVE(params);
    if (const Clip *clip = [self activeSequence].findClip(id)) {
        video.keyframes = clip->video.keyframes; // static values only; the keyframes stay
    }
    return [self push:std::make_unique<SetVideoParams>([self sequenceId], id, std::move(video)) created:nil];
}

- (VEEditResult *)setAudioParams:(VEAudioParams)params forClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<SetAudioParams>([self sequenceId],
                                                       ClipId(static_cast<ClipId::ValueType>(clipID)), fromVE(params))
              created:nil];
}

- (VEEditResult *)applyClipParams:(VEClipParamsBatch *)batch {
    VE_ASSERT_MAIN();
    if (batch.count == 0) {
        return [VEEditResult failureWithMessage:@"Nothing selected."];
    }
    std::vector<ClipParamsChange> changes = batch.changes;
    const Sequence &sequence = [self activeSequence];
    for (ClipParamsChange &change : changes) {
        const Clip *clip = sequence.findClip(change.clipId);
        if (change.video && clip != nullptr && ![batch clearsKeyframesOfClip:change.clipId]) {
            change.video->keyframes = clip->video.keyframes; // static values only; the keyframes stay
        }
    }
    return [self push:std::make_unique<SetClipsParams>([self sequenceId], std::move(changes)) created:nil];
}

// MARK: - Keyframed Motion

/// Refusal of a Motion edit of `clipID` at timeline time `time` (nil when allowed): the clip must
/// exist on a video track and, with `needsFrame`, the sequence frame containing `time` must be one
/// of its frames. Sets `clip` and `frame` (the frame's start) when allowed.
- (nullable VEEditResult *)refuseMotionEditOfClip:(VEClipID)clipID
                                           atTime:(CMTime)time
                                       needsFrame:(BOOL)needsFrame
                                             clip:(const Clip **)clip
                                            frame:(CMTime *)frame {
    const Sequence &sequence = [self activeSequence];
    const ClipId id(static_cast<ClipId::ValueType>(clipID));
    const Track *track = sequence.trackOfClip(id);
    const Clip *found = track != nullptr ? track->find(id) : nullptr;
    if (found == nullptr) {
        return [VEEditResult failureWithCode:VEEditErrorClipNotFound message:@"The clip no longer exists."];
    }
    if (track->kind != TrackKind::Video) {
        return [VEEditResult failureWithCode:VEEditErrorTrackKindMismatch
                                     message:@"Audio clips have no Motion to animate."];
    }
    *clip = found;
    *frame = CMTIME_IS_NUMERIC(time) ? snapToFrame(time, sequence.frameDuration, SnapMode::Floor) : kCMTimeInvalid;
    if (needsFrame && (!CMTIME_IS_NUMERIC(*frame) || *frame < found->timelineStart || *frame >= found->timelineEnd())) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidTime
                                     message:@"Move the playhead over the clip to work with its keyframes."];
    }
    return nil;
}

- (VEEditResult *)keyframeTimeRefusal:(const Clip &)clip {
    return [VEEditResult failureWithCode:VEEditErrorNotRepresentable
                                 message:[NSString stringWithFormat:@"The source time of clip %lld at the playhead "
                                                                    @"cannot be represented.",
                                                                    static_cast<long long>(clip.id.value())]];
}

- (VEEditResult *)addKeyframeToClip:(VEClipID)clipID parameter:(VEMotionParameter)parameter atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const Clip *clip = nullptr;
    CMTime frame = kCMTimeInvalid;
    if (VEEditResult *refusal = [self refuseMotionEditOfClip:clipID atTime:time needsFrame:YES clip:&clip frame:&frame]) {
        return refusal;
    }
    const MotionParameter p = fromVE(parameter);
    if (keyframeIndexForFrame(*clip, p, frame, [self activeSequence].frameDuration)) {
        return [VEEditResult failureWithCode:VEEditErrorAlreadyExists
                                     message:[NSString stringWithFormat:@"%s already has a keyframe at the playhead.",
                                                                        displayNameOf(p)]];
    }
    const std::optional<CMTime> at = keyframeTimeForFrame(*clip, frame);
    if (!at) {
        return [self keyframeTimeRefusal:*clip];
    }
    return [self push:std::make_unique<AddKeyframe>([self sequenceId], clip->id, p, *at) created:nil];
}

- (VEEditResult *)removeKeyframeFromClip:(VEClipID)clipID parameter:(VEMotionParameter)parameter atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const Clip *clip = nullptr;
    CMTime frame = kCMTimeInvalid;
    if (VEEditResult *refusal = [self refuseMotionEditOfClip:clipID atTime:time needsFrame:YES clip:&clip frame:&frame]) {
        return refusal;
    }
    const MotionParameter p = fromVE(parameter);
    const auto index = keyframeIndexForFrame(*clip, p, frame, [self activeSequence].frameDuration);
    if (!index) {
        return [VEEditResult failureWithCode:VEEditErrorKeyframeNotFound
                                     message:[NSString stringWithFormat:@"%s has no keyframe at the playhead.",
                                                                        displayNameOf(p)]];
    }
    const CMTime at = clip->video.keyframes.track(p)[*index].time;
    return [self push:std::make_unique<RemoveKeyframe>([self sequenceId], clip->id, p, at) created:nil];
}

- (VEEditResult *)setMotionValue:(double)value
                       parameter:(VEMotionParameter)parameter
                            clip:(VEClipID)clipID
                          atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const Clip *clip = nullptr;
    CMTime frame = kCMTimeInvalid;
    if (VEEditResult *refusal = [self refuseMotionEditOfClip:clipID atTime:time needsFrame:NO clip:&clip frame:&frame]) {
        return refusal;
    }
    const MotionParameter p = fromVE(parameter);
    std::optional<CMTime> keyframeTime;
    if (clip->video.isAnimated(p)) {
        // An animated parameter changes at the playhead: the keyframe there, or a new one.
        if (VEEditResult *refusal = [self refuseMotionEditOfClip:clipID
                                                          atTime:time
                                                      needsFrame:YES
                                                            clip:&clip
                                                           frame:&frame]) {
            return refusal;
        }
        if (const auto index = keyframeIndexForFrame(*clip, p, frame, [self activeSequence].frameDuration)) {
            keyframeTime = clip->video.keyframes.track(p)[*index].time;
        } else {
            keyframeTime = keyframeTimeForFrame(*clip, frame);
            if (!keyframeTime) {
                return [self keyframeTimeRefusal:*clip];
            }
        }
    }
    return [self push:std::make_unique<SetMotionValue>([self sequenceId], clip->id, p, keyframeTime, value) created:nil];
}

- (VEEditResult *)setKeyframeInterpolation:(VEKeyframeInterpolation)interpolation
                                 parameter:(VEMotionParameter)parameter
                                      clip:(VEClipID)clipID
                                    atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const std::optional<KeyframeInterpolation> engineInterpolation = fromVE(interpolation);
    if (!engineInterpolation || *engineInterpolation == KeyframeInterpolation::Bezier) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                     message:@"Choose Hold, Linear or an ease (a custom curve comes only from a split)."];
    }
    const Clip *clip = nullptr;
    CMTime frame = kCMTimeInvalid;
    if (VEEditResult *refusal = [self refuseMotionEditOfClip:clipID atTime:time needsFrame:YES clip:&clip frame:&frame]) {
        return refusal;
    }
    const MotionParameter p = fromVE(parameter);
    const auto index = keyframeIndexForFrame(*clip, p, frame, [self activeSequence].frameDuration);
    if (!index) {
        return [VEEditResult failureWithCode:VEEditErrorKeyframeNotFound
                                     message:[NSString stringWithFormat:@"%s has no keyframe at the playhead.",
                                                                        displayNameOf(p)]];
    }
    const CMTime at = clip->video.keyframes.track(p)[*index].time;
    return [self push:std::make_unique<SetKeyframeInterpolation>([self sequenceId], clip->id, p, at,
                                                                 *engineInterpolation)
              created:nil];
}

- (VEEditResult *)moveKeyframeOfClip:(VEClipID)clipID
                           parameter:(VEMotionParameter)parameter
                            fromTime:(CMTime)from
                              toTime:(CMTime)to {
    VE_ASSERT_MAIN();
    const Clip *clip = nullptr;
    CMTime fromFrame = kCMTimeInvalid;
    if (VEEditResult *refusal = [self refuseMotionEditOfClip:clipID
                                                      atTime:from
                                                  needsFrame:YES
                                                        clip:&clip
                                                       frame:&fromFrame]) {
        return refusal;
    }
    CMTime toFrame = kCMTimeInvalid;
    if (VEEditResult *refusal = [self refuseMotionEditOfClip:clipID atTime:to needsFrame:YES clip:&clip frame:&toFrame]) {
        return refusal;
    }
    const MotionParameter p = fromVE(parameter);
    const auto index = keyframeIndexForFrame(*clip, p, fromFrame, [self activeSequence].frameDuration);
    if (!index) {
        return [VEEditResult failureWithCode:VEEditErrorKeyframeNotFound
                                     message:[NSString stringWithFormat:@"%s has no keyframe there.", displayNameOf(p)]];
    }
    const std::optional<CMTime> destination = keyframeTimeForFrame(*clip, toFrame);
    if (!destination) {
        return [self keyframeTimeRefusal:*clip];
    }
    const CMTime at = clip->video.keyframes.track(p)[*index].time;
    return [self push:std::make_unique<MoveKeyframe>([self sequenceId], clip->id, p, at, *destination) created:nil];
}

- (nullable VEKeyframeGroup *)keyframeGroupOfClip:(VEClipID)clipID atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const Clip *clip = nullptr;
    CMTime frame = kCMTimeInvalid;
    if ([self refuseMotionEditOfClip:clipID atTime:time needsFrame:YES clip:&clip frame:&frame] != nil) {
        return nil;
    }
    const Sequence &sequence = [self activeSequence];
    const CMTime fd = sequence.frameDuration;
    std::vector<MotionParameter> parameters;
    for (MotionParameter parameter : kMotionParameters) {
        if (keyframeIndexForFrame(*clip, parameter, frame, fd)) {
            parameters.push_back(parameter);
        }
    }
    if (parameters.empty()) {
        return nil;
    }
    MotionKeyframeGroup group;
    const EditResult found = motionKeyframeGroupAt(*clip, fd, frame, group);
    NSString *refusal = found ? nil : toNS(found.message);
    if (found) {
        const Track *track = sequence.trackOfClip(clip->id);
        if (track != nullptr && track->locked) {
            refusal = [NSString stringWithFormat:@"Track %@ is locked.", toNS(track->name)];
        }
    } else if (group.crowdedParameter) {
        refusal = [NSString stringWithFormat:@"This frame shows several %s keyframes (the clip plays faster than the "
                                             @"sequence), so they cannot be moved together.",
                                             displayNameOf(*group.crowdedParameter)];
    }
    return makeKeyframeGroup(clip->id, frame, parameters, group.earliestFrame, group.latestFrame, refusal);
}

- (VEEditResult *)moveKeyframeGroupOfClip:(VEClipID)clipID fromTime:(CMTime)from toTime:(CMTime)to {
    VE_ASSERT_MAIN();
    const Clip *clip = nullptr;
    CMTime fromFrame = kCMTimeInvalid;
    if (VEEditResult *refusal = [self refuseMotionEditOfClip:clipID
                                                      atTime:from
                                                  needsFrame:YES
                                                        clip:&clip
                                                       frame:&fromFrame]) {
        return refusal;
    }
    CMTime toFrame = kCMTimeInvalid;
    if (VEEditResult *refusal = [self refuseMotionEditOfClip:clipID
                                                      atTime:to
                                                  needsFrame:YES
                                                        clip:&clip
                                                       frame:&toFrame]) {
        return refusal;
    }
    // Planned by the command against the model it applies to (in a drag's group: the model before
    // the drag), not against the model now.
    return [self push:std::make_unique<MoveKeyframeGroup>([self sequenceId], clip->id, fromFrame, toFrame) created:nil];
}

- (VEEditResult *)removeAnimationFromClip:(VEClipID)clipID parameter:(VEMotionParameter)parameter atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const Clip *clip = nullptr;
    CMTime frame = kCMTimeInvalid;
    if (VEEditResult *refusal = [self refuseMotionEditOfClip:clipID atTime:time needsFrame:NO clip:&clip frame:&frame]) {
        return refusal;
    }
    const MotionParameter p = fromVE(parameter);
    if (!clip->video.isAnimated(p)) {
        return [VEEditResult failureWithCode:VEEditErrorKeyframeNotFound
                                     message:[NSString stringWithFormat:@"%s is not animated.", displayNameOf(p)]];
    }
    // The parameter keeps the value it has at the playhead (the clip's nearest frame when the
    // playhead is elsewhere), like turning Premiere's animation stopwatch off.
    const CMTime fd = [self activeSequence].frameDuration;
    const CMTime last = checkedSubtract(clip->timelineEnd(), fd).value_or(clip->timelineStart);
    const CMTime at = CMTIME_IS_NUMERIC(frame) ? clampTime(frame, clip->timelineStart, maxTime(last, clip->timelineStart))
                                               : clip->timelineStart;
    const auto source = clip->exactSourceTimeAt(at);
    const double value = source ? clip->video.valueAt(p, *source) : clip->video.staticValue(p);
    MotionTrackChange change;
    change.parameter = p;
    change.staticValue = value;
    return [self push:std::make_unique<SetMotionTracks>([self sequenceId], clip->id,
                                                        std::vector<MotionTrackChange>{change}, "Remove Animation")
              created:nil];
}

- (VEEditResult *)applyKenBurnsToClip:(VEClipID)clipID
                                start:(VEMotionFraming)start
                                  end:(VEMotionFraming)end
                        interpolation:(VEKeyframeInterpolation)interpolation {
    VE_ASSERT_MAIN();
    const Clip *clip = nullptr;
    CMTime frame = kCMTimeInvalid;
    if (VEEditResult *refusal = [self refuseMotionEditOfClip:clipID
                                                      atTime:kCMTimeInvalid
                                                  needsFrame:NO
                                                        clip:&clip
                                                       frame:&frame]) {
        return refusal;
    }
    const CMTime fd = [self activeSequence].frameDuration;
    const std::optional<CMTime> lastFrame = checkedSubtract(clip->timelineEnd(), fd);
    if (!lastFrame || !(*lastFrame > clip->timelineStart)) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                     message:@"The clip is one frame long: a Ken Burns move needs at least two frames."];
    }
    // FCP: the start framing on the clip's first frame, the end framing on its last.
    return [self applyKenBurnsToClip:clipID
                               start:start
                                 end:end
                       interpolation:interpolation
                          rangeStart:clip->timelineStart
                            duration:clip->timelineDuration];
}

/// "HH:MM:SS:FF" of timeline time `time` (non-drop-frame, as the app shows timecode).
static NSString *timecodeOf(CMTime time, CMTime frameDuration) {
    const std::int64_t frames = std::max<std::int64_t>(0, frameIndexAt(time, frameDuration, SnapMode::Floor));
    const std::int64_t fps = std::max<std::int64_t>(1, std::llround(1.0 / toSeconds(frameDuration)));
    const std::int64_t seconds = frames / fps;
    return [NSString stringWithFormat:@"%02lld:%02lld:%02lld:%02lld", static_cast<long long>(seconds / 3600),
                                      static_cast<long long>((seconds / 60) % 60), static_cast<long long>(seconds % 60),
                                      static_cast<long long>(frames % fps)];
}

/// "Position X", "Position X and Scale", "Position X, Position Y and Scale".
static NSString *parameterList(const std::vector<MotionParameter> &parameters) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (MotionParameter parameter : parameters) {
        [names addObject:@(displayNameOf(parameter))];
    }
    if (names.count <= 1) {
        return names.firstObject ?: @"";
    }
    NSString *head = [[names subarrayWithRange:NSMakeRange(0, names.count - 1)] componentsJoinedByString:@", "];
    return [NSString stringWithFormat:@"%@ and %@", head, names.lastObject];
}

/// Where a kept keyframe (source time `time`) plays, for a note.
static NSString *keyframePlace(const Clip &clip, CMTime time, CMTime frameDuration) {
    if (const auto frame = frameShowingSourceTime(clip, time, frameDuration)) {
        return [NSString stringWithFormat:@"at %@", timecodeOf(*frame, frameDuration)];
    }
    const auto at = clip.exactTimelineTimeAt(time);
    const auto start = ExactTime::from(clip.timelineStart);
    const bool before = at && start && at->compare(*start) < 0;
    return before ? @"before the clip's start (hidden by a trim)" : @"after the clip's end (hidden by a trim)";
}

- (VEEditResult *)applyKenBurnsToClip:(VEClipID)clipID
                                start:(VEMotionFraming)start
                                  end:(VEMotionFraming)end
                        interpolation:(VEKeyframeInterpolation)interpolation
                           rangeStart:(CMTime)rangeStart
                             duration:(CMTime)duration {
    VE_ASSERT_MAIN();
    const std::optional<KeyframeInterpolation> engineInterpolation = fromVE(interpolation);
    if (!engineInterpolation || *engineInterpolation == KeyframeInterpolation::Bezier) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                     message:@"Choose Linear or an ease for the Ken Burns move."];
    }
    const Clip *clip = nullptr;
    CMTime first = kCMTimeInvalid;
    if (VEEditResult *refusal = [self refuseMotionEditOfClip:clipID
                                                      atTime:rangeStart
                                                  needsFrame:NO
                                                        clip:&clip
                                                       frame:&first]) {
        return refusal;
    }
    const CMTime fd = [self activeSequence].frameDuration;
    if (!CMTIME_IS_NUMERIC(first) || first < clip->timelineStart || first >= clip->timelineEnd()) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidTime
                                     message:[NSString stringWithFormat:@"The move must start on a frame of the clip "
                                                                        @"(%@ to %@).",
                                                                        timecodeOf(clip->timelineStart, fd),
                                                                        timecodeOf(clip->timelineEnd() - fd, fd)]];
    }
    const std::optional<std::int64_t> frames =
        CMTIME_IS_NUMERIC(duration) ? checkedFrameIndexAt(duration, fd, SnapMode::Round) : std::nullopt;
    if (!frames || *frames < 2) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                     message:@"A Ken Burns move needs at least two frames."];
    }
    const std::int64_t available = frameIndexAt(clip->timelineEnd() - first, fd, SnapMode::Round);
    if (*frames > available) {
        return [VEEditResult
            failureWithCode:VEEditErrorInvalidTime
                    message:[NSString stringWithFormat:@"The move runs past the end of the clip: from %@ there are %lld "
                                                       @"frames left, not %lld.",
                                                       timecodeOf(first, fd), static_cast<long long>(available),
                                                       static_cast<long long>(*frames)]];
    }
    MotionMoveRequest request;
    request.firstFrame = first;
    request.lastFrame = first + timeForFrame(*frames - 1, fd);
    request.start = MotionFraming{start.x, start.y, start.scale};
    request.end = MotionFraming{end.x, end.y, end.scale};
    request.interpolation = *engineInterpolation;
    MotionMovePlan plan;
    if (EditResult planned = planMotionMove(*clip, fd, request, plan); !planned) {
        return toVE(planned);
    }
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    if (!plan.before.parameters.empty()) {
        const bool several = plan.before.parameters.size() > 1;
        [notes addObject:[NSString stringWithFormat:@"The framing does not hold before the move: the %@ keyframe%@ "
                                                    @"%@ lead%@ into its start from a different framing.",
                                                    parameterList(plan.before.parameters), several ? @"s" : @"",
                                                    keyframePlace(*clip, plan.before.keyframeTime, fd),
                                                    several ? @"" : @"s"]];
    }
    if (!plan.after.parameters.empty()) {
        [notes addObject:[NSString stringWithFormat:@"The end framing does not hold after the move: it changes on "
                                                    @"to the %@ keyframe%@ %@.",
                                                    parameterList(plan.after.parameters),
                                                    plan.after.parameters.size() > 1 ? @"s" : @"",
                                                    keyframePlace(*clip, plan.after.keyframeTime, fd)]];
    }
    return [self push:std::make_unique<SetMotionTracks>([self sequenceId], clip->id, std::move(plan.changes), "Ken Burns")
              created:nil
                 note:notes.count > 0 ? [notes componentsJoinedByString:@" "] : nil];
}

- (VEEditResult *)toggleMotionKeyframesOfClip:(VEClipID)clipID atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const Clip *clip = nullptr;
    CMTime frame = kCMTimeInvalid;
    if (VEEditResult *refusal = [self refuseMotionEditOfClip:clipID atTime:time needsFrame:YES clip:&clip frame:&frame]) {
        return refusal;
    }
    MotionKeyframeToggle plan;
    if (EditResult planned = planMotionKeyframeToggle(*clip, [self activeSequence].frameDuration, frame, plan); !planned) {
        return toVE(planned);
    }
    const NSUInteger count = plan.changes.size();
    NSString *note = plan.removing ? @"Keyframes removed"
                                   : [NSString stringWithFormat:@"%@ added on %lu parameter%@",
                                                                count == 1 ? @"Keyframe" : @"Keyframes",
                                                                static_cast<unsigned long>(count), count == 1 ? @"" : @"s"];
    return [self push:std::make_unique<SetMotionTracks>([self sequenceId], clip->id, std::move(plan.changes),
                                                        plan.removing ? "Remove Keyframes" : "Add Keyframes")
              created:nil
                 note:note];
}

- (VEClipID)adjacentClipOfClip:(VEClipID)clipID atEdge:(VEClipEdge)edge {
    VE_ASSERT_MAIN();
    const Clip *neighbour = adjacentClip([self activeSequence], ClipId(static_cast<ClipId::ValueType>(clipID)),
                                         edge == VEClipEdgeStart ? ClipEdge::Head : ClipEdge::Tail);
    return neighbour != nullptr ? static_cast<VEClipID>(neighbour->id.value()) : 0;
}

- (VEEditResult *)matchMotionOfClip:(VEClipID)clipID toAdjacentAtEdge:(VEClipEdge)edge {
    VE_ASSERT_MAIN();
    const Clip *clip = nullptr;
    CMTime unused = kCMTimeInvalid;
    if (VEEditResult *refusal = [self refuseMotionEditOfClip:clipID
                                                      atTime:kCMTimeInvalid
                                                  needsFrame:NO
                                                        clip:&clip
                                                       frame:&unused]) {
        return refusal;
    }
    const bool previous = edge == VEClipEdgeStart;
    const Sequence &sequence = [self activeSequence];
    const CMTime fd = sequence.frameDuration;
    const Clip *neighbour = adjacentClip(sequence, clip->id, previous ? ClipEdge::Head : ClipEdge::Tail);
    if (neighbour == nullptr) {
        return [VEEditResult failureWithCode:VEEditErrorNotAdjacent
                                     message:previous ? @"No clip ends where this clip starts on its track."
                                                      : @"No clip starts where this clip ends on its track."];
    }
    // The neighbour's frame at the cut, as the monitors and export draw it; this clip's frame there.
    const CMTime neighbourFrame = previous ? neighbour->timelineEnd() - fd : neighbour->timelineStart;
    const CMTime frame = previous ? clip->timelineStart : clip->timelineEnd() - fd;
    const VideoParams values = Scheduler::motionAt(*neighbour, neighbourFrame);
    std::vector<MotionTrackChange> changes;
    if (EditResult planned = planMotionAtFrame(*clip, fd, frame, values, changes); !planned) {
        return toVE(planned);
    }
    std::vector<MotionParameter> keyframed;
    std::vector<MotionParameter> statics;
    bool changesAnything = false;
    for (const MotionTrackChange &change : changes) {
        (change.keyframes.empty() ? statics : keyframed).push_back(change.parameter);
        if (change.keyframes != clip->video.keyframes.track(change.parameter) ||
            change.staticValue != clip->video.staticValue(change.parameter)) {
            changesAnything = true;
        }
    }
    NSString *what = previous ? @"the previous clip's end" : @"the next clip's start";
    if (!changesAnything) {
        if (const Track *track = sequence.trackOfClip(clip->id); track != nullptr && track->locked) {
            return [VEEditResult failureWithCode:VEEditErrorTrackLocked
                                         message:[NSString stringWithFormat:@"Track %s is locked.", track->name.c_str()]];
        }
        return toVE(EditResult::success(), @[], [NSString stringWithFormat:@"This clip already matches %@.", what]);
    }
    NSString *frameName = previous ? @"first frame" : @"last frame";
    NSString *note;
    if (keyframed.empty()) {
        note = [NSString stringWithFormat:@"Matched %@: set as this clip's static values.", what];
    } else if (statics.empty()) {
        note = [NSString stringWithFormat:@"Matched %@: set as keyframes on this clip's %@.", what, frameName];
    } else {
        note = [NSString stringWithFormat:@"Matched %@: %@ got keyframes on this clip's %@; %@ became static values.",
                                          what, parameterList(keyframed), frameName, parameterList(statics)];
    }
    return [self push:std::make_unique<SetMotionTracks>([self sequenceId], clip->id, std::move(changes),
                                                        previous ? "Match Previous Clip" : "Match Next Clip")
              created:nil
                 note:note];
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
    const ClipId clip(static_cast<ClipId::ValueType>(clipID));
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
    std::set<ClipId> covered;
    for (ClipId id : toClipIds(clipIDs)) {
        const Clip *clip = sequence.findClip(id);
        if (clip == nullptr) {
            return [VEEditResult failureWithCode:VEEditErrorClipNotFound message:@"A selected clip no longer exists."];
        }
        if (clip->isStill) {
            return [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                         message:@"Still images have no playback speed; change their duration by "
                                                 @"trimming instead."];
        }
        if (!covered.insert(id).second) {
            continue;
        }
        if (clip->linkedClipId) {
            covered.insert(*clip->linkedClipId); // SetClipSpeed changes the partner too
        }
        targets.push_back(id);
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

- (VEEditResult *)addTransitionFromClip:(VEClipID)fromClipID toClip:(VEClipID)toClipID duration:(CMTime)duration {
    VE_ASSERT_MAIN();
    return [self addTransitionFromClip:fromClipID toClip:toClipID duration:duration options:VETransitionOptionNone];
}

- (VEEditResult *)addTransitionFromClip:(VEClipID)fromClipID
                                 toClip:(VEClipID)toClipID
                               duration:(CMTime)duration
                                options:(VETransitionOptions)options {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const CMTime frameDuration = sequence.frameDuration;
    if (!CMTIME_IS_NUMERIC(duration)) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidTime message:@"The transition duration is not a valid time."];
    }
    const int64_t frames =
        frameIndexAt(snapToFrame(duration, frameDuration, SnapMode::Round), frameDuration, SnapMode::Round);
    if (frames < 1) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                     message:@"A transition must be at least one frame long."];
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

    // The linked partners' cut (the audio under a video dissolve).
    std::optional<std::pair<ClipId, ClipId>> partners;
    int64_t partnerFrames = requested;
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
                if (partnerFrames > linked.maximumFrames) {
                    partnerFrames = linked.maximumFrames;
                    [notes addObject:[NSString stringWithFormat:@"The linked clips' transition was shortened to %@: %@",
                                                                describeFrames(partnerFrames, frameDuration),
                                                                toNS(linked.reason)]];
                }
                partners = std::make_pair(*fromClip->linkedClipId, *toClip->linkedClipId);
            }
        } else if (fromClip && toClip && (fromClip->linkedClipId || toClip->linkedClipId)) {
            [notes addObject:@"The linked clips do not meet at a cut, so they got no transition."];
        }
    }

    auto main = std::make_unique<AddTransition>(sequenceId, from, to, timeForFrame(mainFrames, frameDuration));
    AddTransition *mainRaw = main.get();
    AddTransition *partnerRaw = nullptr;
    std::unique_ptr<Command> command;
    if (partners) {
        auto partner = std::make_unique<AddTransition>(sequenceId, partners->first, partners->second,
                                                       timeForFrame(partnerFrames, frameDuration));
        partnerRaw = partner.get();
        std::vector<std::unique_ptr<Command>> children;
        children.push_back(std::move(main));
        children.push_back(std::move(partner));
        command = std::make_unique<CompositeCommand>("Add Transitions", std::move(children));
    } else {
        command = std::move(main);
    }
    if (isThroughEdit(sequence, from, to)) {
        // A plain split: both sides are the same media, so the transition changes nothing.
        const Track *track = sequence.findTrack(sequence.findClip(from)->trackId);
        [notes addObject:track != nullptr && track->kind == TrackKind::Audio
                             ? @"Both sides play the same audio here; trim or move one side to hear the crossfade."
                             : @"Both sides show the same frames here; trim or move one side to see the dissolve."];
    }
    NSString *note = notes.count > 0 ? [notes componentsJoinedByString:@" "] : nil;
    return [self push:std::move(command)
              created:^NSArray<NSNumber *> * {
                  NSMutableArray<NSNumber *> *ids =
                      [NSMutableArray arrayWithObject:@(static_cast<int64_t>(mainRaw->createdTransitionId().value()))];
                  if (partnerRaw != nullptr) {
                      [ids addObject:@(static_cast<int64_t>(partnerRaw->createdTransitionId().value()))];
                  }
                  return ids;
              }
                 note:note];
}

- (VETransitionLimit *)transitionLimitFromClip:(VEClipID)fromClipID toClip:(VEClipID)toClipID {
    VE_ASSERT_MAIN();
    return makeTransitionLimit(transitionLimit(_project, [self sequenceId],
                                               ClipId(static_cast<ClipId::ValueType>(fromClipID)),
                                               ClipId(static_cast<ClipId::ValueType>(toClipID))));
}

- (VETransitionLimit *)transitionLimitForTransition:(VETransitionID)transitionID {
    VE_ASSERT_MAIN();
    const TransitionId id(static_cast<TransitionId::ValueType>(transitionID));
    const Transition *transition = [self activeSequence].findTransition(id);
    if (transition == nullptr) {
        TransitionLimit none;
        none.limitError = EditError::TransitionNotFound;
        none.reason = "The transition no longer exists.";
        return makeTransitionLimit(none);
    }
    return makeTransitionLimit(
        transitionLimit(_project, [self sequenceId], transition->fromClipId, transition->toClipId, id));
}

- (VEEditResult *)removeTransition:(VETransitionID)transitionID {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<RemoveTransition>([self sequenceId],
                                                         TransitionId(static_cast<TransitionId::ValueType>(transitionID)))
              created:nil];
}

- (VETransitionID)linkedTransitionForTransition:(VETransitionID)transitionID {
    VE_ASSERT_MAIN();
    const auto partner =
        linkedTransition([self activeSequence], TransitionId(static_cast<TransitionId::ValueType>(transitionID)));
    return partner ? static_cast<VETransitionID>(partner->value()) : 0;
}

- (VEEditResult *)removeTransition:(VETransitionID)transitionID includingLinked:(BOOL)includingLinked {
    VE_ASSERT_MAIN();
    const TransitionId id(static_cast<TransitionId::ValueType>(transitionID));
    const Sequence &sequence = [self activeSequence];
    const auto partner = includingLinked ? linkedTransition(sequence, id) : std::nullopt;
    if (!partner || sequence.findTransition(id) == nullptr) {
        return [self removeTransition:transitionID];
    }
    const Transition *linked = sequence.findTransition(*partner);
    const Track *linkedTrack = linked != nullptr ? sequence.findTrack(linked->trackId) : nullptr;
    if (linkedTrack != nullptr && linkedTrack->locked) {
        // The pair's other half is protected: remove the requested one and say why the other stays.
        VEEditResult *result = [self push:std::make_unique<RemoveTransition>([self sequenceId], id)
                                  created:nil
                                     note:[NSString stringWithFormat:@"The linked transition on %@ was kept: the "
                                                                     @"track is locked.",
                                                                     toNS(linkedTrack->name)]];
        return result;
    }
    return [self push:std::make_unique<RemoveTransitions>([self sequenceId], std::vector<TransitionId>{id, *partner})
              created:nil];
}

- (VEEditResult *)setDuration:(CMTime)duration
                forTransition:(VETransitionID)transitionID
              includingLinked:(BOOL)includingLinked {
    VE_ASSERT_MAIN();
    const TransitionId id(static_cast<TransitionId::ValueType>(transitionID));
    const Sequence &sequence = [self activeSequence];
    const auto partner = includingLinked ? linkedTransition(sequence, id) : std::nullopt;
    if (!partner || !CMTIME_IS_NUMERIC(duration)) {
        return [self setDuration:duration forTransition:transitionID];
    }
    const CMTime frameDuration = sequence.frameDuration;
    const int64_t frames =
        frameIndexAt(snapToFrame(duration, frameDuration, SnapMode::Round), frameDuration, SnapMode::Round);
    std::vector<SetTransitionDurations::Change> changes{{id, duration}};
    NSString *note = nil;
    const Transition *linked = sequence.findTransition(*partner);
    const Track *linkedTrack = sequence.findTrack(linked->trackId);
    if (linkedTrack != nullptr && linkedTrack->locked) {
        note = [NSString stringWithFormat:@"The linked transition on %@ was not changed: the track is locked.",
                                          toNS(linkedTrack->name)];
    } else if (frames >= 1) {
        // The linked transition gets the same length, fitted to its own cut.
        const TransitionLimit limit =
            transitionLimit(_project, [self sequenceId], linked->fromClipId, linked->toClipId, *partner);
        if (limit.maximumFrames == 0) {
            note = [NSString stringWithFormat:@"The linked transition was not changed: %@", toNS(limit.reason)];
        } else {
            int64_t linkedFrames = frames;
            if (linkedFrames > limit.maximumFrames) {
                linkedFrames = limit.maximumFrames;
                note = [NSString stringWithFormat:@"The linked transition was limited to %@: %@",
                                                  describeFrames(linkedFrames, frameDuration), toNS(limit.reason)];
            }
            changes.push_back({*partner, timeForFrame(linkedFrames, frameDuration)});
        }
    }
    VEEditResult *result =
        [self push:std::make_unique<SetTransitionDurations>([self sequenceId], std::move(changes)) created:nil note:note];
    return [self explainDurationRefusal:result transition:id duration:duration];
}

- (VEEditResult *)setDuration:(CMTime)duration forTransition:(VETransitionID)transitionID {
    VE_ASSERT_MAIN();
    const TransitionId id(static_cast<TransitionId::ValueType>(transitionID));
    VEEditResult *result = [self push:std::make_unique<SetTransitionDuration>([self sequenceId], id, duration)
                              created:nil];
    return [self explainDurationRefusal:result transition:id duration:duration];
}

/// A refused duration change of `id` that is about length gets the user-facing explanation of
/// the cut's limit (as adding one does); anything else is returned as is.
- (VEEditResult *)explainDurationRefusal:(VEEditResult *)result transition:(TransitionId)id duration:(CMTime)duration {
    const Sequence &sequence = [self activeSequence];
    const Transition *transition = sequence.findTransition(id);
    if (result.ok || transition == nullptr || !CMTIME_IS_NUMERIC(duration) ||
        !(result.errorCode == VEEditErrorInsufficientHandles || result.errorCode == VEEditErrorInvalidArgument ||
          result.errorCode == VEEditErrorOverlap)) {
        return result;
    }
    const TransitionLimit limit =
        transitionLimit(_project, [self sequenceId], transition->fromClipId, transition->toClipId, id);
    const int64_t frames =
        frameIndexAt(snapToFrame(duration, sequence.frameDuration, SnapMode::Round), sequence.frameDuration,
                     SnapMode::Round);
    if (frames <= limit.maximumFrames) {
        return result; // refused for another reason (e.g. shorter than a frame)
    }
    return [VEEditResult failureWithCode:result.errorCode
                                 message:transitionRefusal(limit, frames, sequence.frameDuration)];
}

- (VEEditResult *)linkClip:(VEClipID)clipID withClip:(VEClipID)otherClipID {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<LinkClips>([self sequenceId], ClipId(static_cast<ClipId::ValueType>(clipID)),
                                                  ClipId(static_cast<ClipId::ValueType>(otherClipID)))
              created:nil];
}

- (VEEditResult *)unlinkClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<UnlinkClip>([self sequenceId], ClipId(static_cast<ClipId::ValueType>(clipID)))
              created:nil];
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
    const Track *track = sequence.findTrack(TrackId(static_cast<TrackId::ValueType>(trackID)));
    if (track != nullptr && sequence.tracks(track->kind).size() <= 1) {
        return [VEEditResult failureWithMessage:@"A sequence keeps at least one track of each kind."];
    }
    return [self push:std::make_unique<RemoveTrack>([self sequenceId], TrackId(static_cast<TrackId::ValueType>(trackID)))
              created:nil];
}

- (VEEditResult *)updateTrack:(VETrackID)trackID with:(const TrackFlagsUpdate &)update {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<SetTrackFlags>([self sequenceId],
                                                      TrackId(static_cast<TrackId::ValueType>(trackID)), update)
              created:nil];
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

// MARK: - Undo

- (void)beginCoalescingWithKey:(NSString *)key {
    VE_ASSERT_MAIN();
    [self beginCoalescingWithKey:key mode:VECoalescingModeReplace];
}

- (void)beginCoalescingWithKey:(NSString *)key mode:(VECoalescingMode)mode {
    VE_ASSERT_MAIN();
    [self closeCoalescingIfOpen];
    _coalescingKey = [key copy];
    _undo->beginCoalescing(toStd(_coalescingKey), mode == VECoalescingModeAccumulate ? CoalesceMode::Accumulate
                                                                                   : CoalesceMode::ReplacePrevious);
}

- (nullable NSString *)coalescingKey {
    VE_ASSERT_MAIN();
    return _coalescingKey;
}

- (VEEditResult *)performInCoalescingGroup:(NSString *)key edit:(NS_NOESCAPE VEEditResult * (^)(void))edit {
    VE_ASSERT_MAIN();
    if (_coalescingKey == nil || ![_coalescingKey isEqualToString:key]) {
        return [VEEditResult failureWithCode:VEEditErrorBusy
                                     message:@"The gesture's edit group has ended (another edit committed it)."];
    }
    NSString *outer = _gestureEditKey;
    _gestureEditKey = [key copy];
    VEEditResult *result = edit();
    _gestureEditKey = outer;
    return result ?: [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"The edit returned no result."];
}

- (void)endCoalescing {
    VE_ASSERT_MAIN();
    [self closeCoalescingIfOpen];
}

- (void)cancelCoalescing {
    VE_ASSERT_MAIN();
    if (_coalescingKey == nil) {
        return;
    }
    _coalescingKey = nil;
    const bool reverted = _undo->cancelCoalescing(_project);
    if (reverted) {
        [self notifyAssetsChanged];
        [self notifyModelChanged];
    }
    [self flushDeferredImports];
}

- (BOOL)isCoalescing {
    VE_ASSERT_MAIN();
    return _coalescingKey != nil;
}

- (BOOL)undo {
    VE_ASSERT_MAIN();
    _coalescingKey = nil;
    [self flushDeferredImports];
    if (!_undo->undo(_project)) {
        return NO;
    }
    [self notifyAssetsChanged];
    [self notifyModelChanged];
    return YES;
}

- (BOOL)redo {
    VE_ASSERT_MAIN();
    _coalescingKey = nil;
    [self flushDeferredImports];
    if (!_undo->redo(_project)) {
        return NO;
    }
    _idFloor = std::max(_idFloor, _project.ids.nextValue());
    [self notifyAssetsChanged];
    [self notifyModelChanged];
    return YES;
}

- (BOOL)canUndo {
    VE_ASSERT_MAIN();
    return _undo->canUndo();
}

- (BOOL)canRedo {
    VE_ASSERT_MAIN();
    return _undo->canRedo();
}

- (NSString *)undoActionName {
    VE_ASSERT_MAIN();
    return toNS(_undo->undoName());
}

- (NSString *)redoActionName {
    VE_ASSERT_MAIN();
    return toNS(_undo->redoName());
}

// MARK: - Playback

static bool isRunning(playback::PlaybackState state) {
    return state == playback::PlaybackState::Playing || state == playback::PlaybackState::Prerolling;
}

/// Hands the controllers the model: the active sequence of a new project (setSequence, which
/// stops and moves to frame 0), or the edited snapshot (modelChanged, which keeps playing).
- (void)publishPlaybackSnapshot {
    auto snapshot = std::make_shared<const Project>(_project);
    if (!_playbackPublished || _playbackGeneration != _projectGeneration) {
        _playbackPublished = true;
        _playbackGeneration = _projectGeneration;
        _playback->setSequence(std::move(snapshot), _project.activeSequenceId);
    } else {
        _playback->modelChanged(std::move(snapshot));
    }
    // The source monitor's asset may have been removed (undo of its import).
    if (_sourceAsset && _project.findAsset(_sourceAsset) == nullptr) {
        [self resetSourceMonitor];
        [self notifySourcePlayback:_sourcePlayback ? _sourcePlayback->status() : playback::PlaybackStatus{}];
    }
}

- (void)observeController:(playback::PlaybackController &)controller source:(BOOL)isSource {
    __weak VEEngine *weakSelf = self;
    playback::PlaybackObserver observer;
    observer.statusChanged = [weakSelf, isSource](const playback::PlaybackStatus &status) {
        VEEngine *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (isSource) {
            [strongSelf notifySourcePlayback:status];
        } else {
            [strongSelf notifyPlayback:status];
        }
    };
    observer.needsDisplay = [weakSelf, isSource] {
        VEEngine *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (isSource) {
            if (strongSelf->_sourceUsesController) {
                [strongSelf->_sourceView renderOnce];
            }
        } else {
            [strongSelf->_programView renderOnce];
            [strongSelf->_outputView renderOnce];
        }
    };
    controller.setObserver(dispatch_get_main_queue(), std::move(observer));
}

- (void)notifyPlayback:(const playback::PlaybackStatus &)status {
    if (VEPreviewView *output = _outputView) {
        // The output view's render loop follows the program's transport (the owner of the
        // program view does this for it).
        const BOOL paused = !isRunning(status.state);
        if (output.paused != paused) {
            output.paused = paused;
        }
    }
    VEPlaybackStatus *info = makePlaybackStatus(status);
    [NSNotificationCenter.defaultCenter postNotificationName:VEEnginePlaybackDidChangeNotification
                                                      object:self
                                                    userInfo:@{VEEnginePlaybackStatusKey : info}];
    for (id<VEEngineObserver> observer in _observers.allObjects) {
        if ([observer respondsToSelector:@selector(engine:playbackDidChange:)]) {
            [observer engine:self playbackDidChange:info];
        }
    }
}

- (void)notifySourcePlayback:(const playback::PlaybackStatus &)status {
    VEPlaybackStatus *info = makePlaybackStatus(status);
    if (!_sourceUsesController) {
        // The controller is not what the monitor shows: report the scrub position, stopped.
        playback::PlaybackStatus shown;
        shown.time = _sourceTime;
        info = makePlaybackStatus(shown);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:VEEngineSourcePlaybackDidChangeNotification
                                                      object:self
                                                    userInfo:@{VEEnginePlaybackStatusKey : info}];
    for (id<VEEngineObserver> observer in _observers.allObjects) {
        if ([observer respondsToSelector:@selector(engine:sourcePlaybackDidChange:)]) {
            [observer engine:self sourcePlaybackDidChange:info];
        }
    }
}

- (void)attachProgramView:(nullable VEPreviewView *)view {
    VE_ASSERT_MAIN();
    VEPreviewView *previous = _programView;
    if (previous != nil && previous != view) {
        [previous setFrameSource:ve::render::PreviewFrameSource{}];
    }
    _programView = view;
    if (view != nil) {
        [view setFrameSource:_playback->frameSource()];
        [view renderOnce];
    }
}

- (nullable VEPreviewView *)programView {
    VE_ASSERT_MAIN();
    return _programView;
}

- (void)attachOutputView:(VEPreviewView *)view {
    VE_ASSERT_MAIN();
    if (_outputView != nil && _outputView != view) {
        [self detachOutputView];
    }
    _outputView = view;
    // A mirror source: the same frames as the program view, without adding to its counters.
    [view setFrameSource:_playback->frameSource(playback::PlaybackController::SourceRole::Mirror)];
    view.paused = !isRunning(_playback->state());
    [view renderOnce];
}

- (void)detachOutputView {
    VE_ASSERT_MAIN();
    VEPreviewView *view = _outputView;
    _outputView = nil;
    if (view != nil) {
        [view setFrameSource:ve::render::PreviewFrameSource{}];
        view.paused = YES;
    }
}

- (nullable VEPreviewView *)outputView {
    VE_ASSERT_MAIN();
    return _outputView;
}

- (void)showProgramFrameAtTime:(CMTime)time {
    VE_ASSERT_MAIN();
    [self seekToTime:time];
}

/// One monitor plays at a time (as in Premiere): starting the program pauses the source monitor.
- (void)pauseSourceMonitorIfRunning {
    if (_sourceUsesController && _sourcePlayback && isRunning(_sourcePlayback->state())) {
        _sourcePlayback->pause();
    }
}

/// Starting the source monitor pauses the program.
- (void)pauseProgramIfRunning {
    if (isRunning(_playback->state())) {
        _playback->pause();
    }
}

/// Playback does not start while an export runs (the export has the decoders and the GPU; the
/// monitors were paused when it began).
- (BOOL)refusesPlaybackForExport {
    return _activeExport != nil;
}

- (void)play {
    VE_ASSERT_MAIN();
    if ([self refusesPlaybackForExport]) {
        return;
    }
    [self pauseSourceMonitorIfRunning];
    _playback->play();
}

- (void)pause {
    VE_ASSERT_MAIN();
    _playback->pause();
}

- (void)togglePlay {
    VE_ASSERT_MAIN();
    if (!isRunning(_playback->state())) {
        if ([self refusesPlaybackForExport]) {
            return;
        }
        [self pauseSourceMonitorIfRunning];
    }
    _playback->togglePlay();
}

- (void)seekToTime:(CMTime)time {
    VE_ASSERT_MAIN();
    _playback->seek(CMTIME_IS_NUMERIC(time) ? time : kCMTimeZero, playback::SeekMode::Exact);
}

- (void)setRate:(double)rate {
    VE_ASSERT_MAIN();
    if (rate != 0) {
        if ([self refusesPlaybackForExport]) {
            return;
        }
        [self pauseSourceMonitorIfRunning];
    }
    _playback->setRate(rate);
}

- (void)shuttleForward {
    VE_ASSERT_MAIN();
    if ([self refusesPlaybackForExport]) {
        return;
    }
    [self pauseSourceMonitorIfRunning];
    _playback->shuttleForward();
}

- (void)shuttleReverse {
    VE_ASSERT_MAIN();
    if ([self refusesPlaybackForExport]) {
        return;
    }
    [self pauseSourceMonitorIfRunning];
    _playback->shuttleReverse();
}

- (void)shuttleStop {
    VE_ASSERT_MAIN();
    _playback->pause();
}

- (void)stepFrames:(NSInteger)frames {
    VE_ASSERT_MAIN();
    _playback->stepFrames(static_cast<int>(std::clamp<NSInteger>(frames, INT_MIN, INT_MAX)));
}

- (void)scrubToTime:(CMTime)time {
    VE_ASSERT_MAIN();
    if (CMTIME_IS_NUMERIC(time)) {
        _playback->scrubTo(time);
    }
}

- (void)endScrub {
    VE_ASSERT_MAIN();
    _playback->endScrub();
}

- (BOOL)isMuted {
    VE_ASSERT_MAIN();
    return _playback->isMuted();
}

- (void)setMuted:(BOOL)muted {
    VE_ASSERT_MAIN();
    _playback->setMuted(muted);
    if (_sourcePlayback) {
        _sourcePlayback->setMuted(muted);
    }
}

- (VEPlaybackState)playbackState {
    VE_ASSERT_MAIN();
    return playbackStateToVE(_playback->state());
}

- (double)playbackRate {
    VE_ASSERT_MAIN();
    return _playback->rate();
}

- (CMTime)currentTime {
    VE_ASSERT_MAIN();
    return _playback->currentTime();
}

- (NSString *)playbackError {
    VE_ASSERT_MAIN();
    const playback::PlaybackStatus status = _playback->status();
    return status.lastError ? toNS(status.lastError->message) : @"";
}

- (VEPlaybackStatus *)playbackStatus {
    VE_ASSERT_MAIN();
    return makePlaybackStatus(_playback->status());
}

- (VEPlaybackStats *)playbackStats {
    VE_ASSERT_MAIN();
    return makePlaybackStats(_playback->stats(), _playback->lastPresented());
}

// MARK: - Source monitor

- (void)attachSourceView:(nullable VEPreviewView *)view {
    VE_ASSERT_MAIN();
    VEPreviewView *previous = _sourceView;
    if (previous != nil && previous != view) {
        [previous setFrameSource:ve::render::PreviewFrameSource{}];
    }
    _sourceView = view;
    if (view != nil) {
        [view setFrameSource:_sourceUsesController && _sourcePlayback ? _sourcePlayback->frameSource()
                                                                       : _sourceProvider->makeSource()];
        [self refreshSourcePicture];
    }
}

/// Clears the source monitor (no asset, provider picture, controller stopped and emptied).
- (void)resetSourceMonitor {
    _sourceProvider->cancel();
    if (_sourceUsesController) {
        _sourceUsesController = false;
        [_sourceView setFrameSource:_sourceProvider->makeSource()];
    }
    if (_sourcePlayback && _sourcePlaybackAsset) {
        // Stops it and drops its private project (and decode targets) until the next play.
        _sourcePlayback->setSequence(std::make_shared<const Project>(), SequenceId{});
        _sourcePlaybackAsset = AssetId{};
    }
    _sourceAsset = AssetId{};
    _sourceProject.reset();
    _sourceTime = kCMTimeZero;
    [self refreshSourcePicture];
}

/// Shows the provider's picture of the source asset at _sourceTime (black without an asset).
- (void)refreshSourcePicture {
    if (_sourceUsesController) {
        [_sourceView renderOnce];
        return;
    }
    RenderGraph graph;
    if (_sourceProject) {
        const Sequence &sequence = *_sourceProject->activeSequence();
        graph = Scheduler::renderGraphAt(sequence, *_sourceProject, _sourceTime);
        graph.width = sequence.width;
        graph.height = sequence.height;
    } else if (const MediaAsset *asset = _project.findAsset(_sourceAsset); asset != nullptr && asset->isStill()) {
        VideoLayer layer;
        layer.clipId = kSourceVideoClip;
        layer.assetId = asset->id;
        layer.isStill = true;
        layer.sourceRotationDegrees = asset->rotationDegrees;
        graph.layers.push_back(layer);
        graph.time = kCMTimeZero;
        graph.width = std::max(1, asset->width);
        graph.height = std::max(1, asset->height);
    }
    if (_sourceView == nil) {
        _sourceProvider->cancel();
        return;
    }
    __weak VEEngine *weakSelf = self;
    _sourceProvider->show(std::move(graph), [weakSelf] {
        VEEngine *strongSelf = weakSelf;
        if (strongSelf != nil && !strongSelf->_sourceUsesController) {
            [strongSelf->_sourceView renderOnce];
        }
    });
}

- (CMTime)frameTimeForAsset:(VEAssetID)assetID atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const MediaAsset *asset = _project.findAsset(AssetId(static_cast<AssetId::ValueType>(assetID)));
    if (asset == nullptr || !CMTIME_IS_NUMERIC(time) || time < kCMTimeZero || asset->isStill()) {
        return kCMTimeZero;
    }
    const CMTime fd = asset->hasVideo() && isPositive(asset->frameDuration) ? asset->frameDuration
                                                                             : [self activeSequence].frameDuration;
    CMTime t = snapToFrame(time, fd, SnapMode::Floor);
    if (CMTIME_IS_NUMERIC(asset->duration) && asset->duration > kCMTimeZero) {
        const CMTime last = snapToFrame(asset->duration, fd, SnapMode::Floor);
        const CMTime lastStart = last == asset->duration ? last - fd : last;
        if (t > lastStart) {
            t = std::max(kCMTimeZero, lastStart);
        }
    }
    return t;
}

- (void)sourceMonitorShowAsset:(VEAssetID)assetID atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const AssetId id(static_cast<AssetId::ValueType>(assetID));
    const MediaAsset *asset = assetID > 0 ? _project.findAsset(id) : nullptr;
    if (asset == nullptr) {
        [self resetSourceMonitor];
        [self notifySourcePlayback:playback::PlaybackStatus{}];
        return;
    }
    const CMTime t = [self frameTimeForAsset:assetID atTime:time];
    if (id != _sourceAsset) {
        [self resetSourceMonitor];
        _sourceAsset = id;
        _sourceProject = makeSourceProject(*asset, [self activeSequence].frameDuration);
    }
    _sourceTime = t;
    if (_sourceUsesController && _sourcePlayback) {
        _sourcePlayback->seek(t, playback::SeekMode::Exact);
        return; // the controller reports the new position
    }
    [self refreshSourcePicture];
    [self notifySourcePlayback:playback::PlaybackStatus{}];
}

- (VEAssetID)sourceMonitorAssetID {
    VE_ASSERT_MAIN();
    return static_cast<VEAssetID>(_sourceAsset.value());
}

- (CMTime)sourceMonitorTime {
    VE_ASSERT_MAIN();
    return _sourceUsesController && _sourcePlayback ? _sourcePlayback->currentTime() : _sourceTime;
}

- (VEPlaybackState)sourceMonitorPlaybackState {
    VE_ASSERT_MAIN();
    return _sourceUsesController && _sourcePlayback ? playbackStateToVE(_sourcePlayback->state())
                                                    : VEPlaybackStateStopped;
}

- (VEPlaybackStatus *)sourceMonitorPlaybackStatus {
    VE_ASSERT_MAIN();
    if (_sourceUsesController && _sourcePlayback) {
        return makePlaybackStatus(_sourcePlayback->status());
    }
    playback::PlaybackStatus shown;
    shown.time = _sourceTime;
    return makePlaybackStatus(shown);
}

/// Makes the source controller play the monitor's asset and shows its picture. False when the
/// asset cannot play (none, a still, no duration).
- (BOOL)prepareSourcePlayback {
    if (!_sourceProject) {
        return NO;
    }
    if (!_sourcePlayback) {
        playback::PlaybackConfig config;
        config.scrubLaneBase = kSourcePlaybackLaneBase;
        _sourcePlayback = std::make_unique<playback::PlaybackController>(_router, _frameCache, _sourcePool, config);
        _sourcePlayback->setMuted(_playback->isMuted());
        for (const auto &[asset, routed] : _routing) {
            _sourcePlayback->setAssetRouting(asset, routed);
        }
        [self observeController:*_sourcePlayback source:YES];
        [self updateSourceIdleLookahead];
    }
    if (_sourcePlaybackAsset != _sourceAsset) {
        _sourcePlaybackAsset = _sourceAsset;
        _sourcePlayback->setSequence(std::make_shared<const Project>(*_sourceProject),
                                     _sourceProject->activeSequenceId);
    }
    if (!_sourceUsesController) {
        _sourceProvider->cancel();
        _sourceUsesController = true;
        _sourcePlayback->seek(_sourceTime, playback::SeekMode::Exact);
        [_sourceView setFrameSource:_sourcePlayback->frameSource()];
        [_sourceView renderOnce];
    }
    return YES;
}

- (void)sourceMonitorTogglePlay {
    VE_ASSERT_MAIN();
    const bool running = _sourceUsesController && _sourcePlayback && isRunning(_sourcePlayback->state());
    if (!running && [self refusesPlaybackForExport]) {
        return;
    }
    if ([self prepareSourcePlayback]) {
        if (!isRunning(_sourcePlayback->state())) {
            [self pauseProgramIfRunning];
        }
        _sourcePlayback->togglePlay();
    }
}

- (void)sourceMonitorPause {
    VE_ASSERT_MAIN();
    if (_sourceUsesController && _sourcePlayback) {
        _sourcePlayback->pause();
    }
}

- (BOOL)sourceMonitorVisible {
    VE_ASSERT_MAIN();
    return _sourceMonitorVisible;
}

- (void)setSourceMonitorVisible:(BOOL)visible {
    VE_ASSERT_MAIN();
    _sourceMonitorVisible = visible;
    [self updateSourceIdleLookahead];
}

/// The source controller keeps its stopped lookahead only while the monitor is on screen and no
/// export runs (the export gets the decoders; a hidden monitor needs no frames ahead).
- (void)updateSourceIdleLookahead {
    if (_sourcePlayback) {
        _sourcePlayback->setIdleLookahead(_sourceMonitorVisible && _activeExport == nil);
    }
}

- (VEPlaybackStats *)sourceMonitorPlaybackStats {
    VE_ASSERT_MAIN();
    return _sourcePlayback ? makePlaybackStats(_sourcePlayback->stats(), _sourcePlayback->lastPresented())
                           : makePlaybackStats(playback::PlaybackStats{}, playback::PresentedFrame{});
}

- (void)sourceMonitorShuttleForward {
    VE_ASSERT_MAIN();
    if ([self refusesPlaybackForExport]) {
        return;
    }
    if ([self prepareSourcePlayback]) {
        [self pauseProgramIfRunning];
        _sourcePlayback->shuttleForward();
    }
}

- (void)sourceMonitorShuttleReverse {
    VE_ASSERT_MAIN();
    if ([self refusesPlaybackForExport]) {
        return;
    }
    if ([self prepareSourcePlayback]) {
        [self pauseProgramIfRunning];
        _sourcePlayback->shuttleReverse();
    }
}

- (void)sourceMonitorStepFrames:(NSInteger)frames {
    VE_ASSERT_MAIN();
    if (_sourceUsesController && _sourcePlayback) {
        _sourcePlayback->stepFrames(static_cast<int>(std::clamp<NSInteger>(frames, INT_MIN, INT_MAX)));
        return;
    }
    if (!_sourceProject) {
        return;
    }
    const CMTime fd = _sourceProject->activeSequence()->frameDuration;
    const CMTime t = std::max(kCMTimeZero, _sourceTime + CMTimeMultiply(fd, static_cast<int32_t>(std::clamp<NSInteger>(
                                                                                 frames, INT32_MIN, INT32_MAX))));
    [self sourceMonitorShowAsset:static_cast<VEAssetID>(_sourceAsset.value()) atTime:t];
}


// MARK: - Export

- (NSArray<VEExportFormat *> *)exportFormatsForWidth:(NSInteger)width height:(NSInteger)height {
    VE_ASSERT_MAIN();
    return makeExportFormats(width, height);
}

- (void)exportFormatsForWidth:(NSInteger)width
                       height:(NSInteger)height
                   completion:(void (^)(NSArray<VEExportFormat *> *formats))completion {
    VE_ASSERT_MAIN();
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSArray<VEExportFormat *> *formats = makeExportFormats(width, height);
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(formats);
      });
    });
}

- (CGSize)exportSizeForSettings:(VEExportSettings *)settings {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    return [settings outputSizeForSequenceWidth:sequence.width height:sequence.height];
}

- (int64_t)estimatedFileSizeForSettings:(VEExportSettings *)settings {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const CMTime duration = sequence.duration();
    if (!(duration > kCMTimeZero) || !isPositive(sequence.frameDuration)) {
        return 0;
    }
    const CGSize size = [settings outputSizeForSequenceWidth:sequence.width height:sequence.height];
    return estimatedExportBytes(settings, size, 1.0 / CMTimeGetSeconds(sequence.frameDuration),
                                CMTimeGetSeconds(duration));
}

- (nullable VEExportHandle *)activeExport {
    VE_ASSERT_MAIN();
    return _activeExport;
}

- (BOOL)isExporting {
    VE_ASSERT_MAIN();
    return _activeExport != nil;
}

- (void)stopAccessingExportURL {
    [_exportAccessedURL stopAccessingSecurityScopedResource];
    _exportAccessedURL = nil;
}

- (nullable VEExportHandle *)beginExportWithSettings:(VEExportSettings *)settings
                                           outputURL:(NSURL *)outputURL
                                            progress:(nullable void (^)(VEExportProgress *progress))progress
                                          completion:(void (^)(VEExportSummary *_Nullable summary,
                                                               NSError *_Nullable error))completion
                                               error:(NSError *_Nullable *_Nullable)error {
    VE_ASSERT_MAIN();
    auto refuse = [&](VEEngineErrorCode code, NSString *message) -> VEExportHandle * {
        if (error != nullptr) {
            *error = makeError(code, message);
        }
        return nil;
    };
    if (_activeExport != nil) {
        return refuse(VEEngineErrorBusy, @"An export is already running.");
    }
    if (_coalescingKey != nil) {
        return refuse(VEEngineErrorBusy, @"Finish the current edit (a drag or slider) before exporting.");
    }
    if (NSString *invalid = settings.validationMessage) {
        return refuse(VEEngineErrorExportUnsupported, invalid);
    }
    if (!outputURL.isFileURL) {
        return refuse(VEEngineErrorOutputNotWritable, @"The export needs a file location.");
    }
    const Sequence &sequence = [self activeSequence];
    const CGSize size = [settings outputSizeForSequenceWidth:sequence.width height:sequence.height];
    if (size.width < 2 || size.height < 2) {
        return refuse(VEEngineErrorExportUnsupported, @"The export frame size is not usable.");
    }
    exporting::ExportRequest request;
    request.project = std::make_shared<const Project>(_project);
    request.sequenceId = _project.activeSequenceId;
    request.encode = makeEncodeSettings(settings, size, request.videoBitDepth);
    request.outputPath = outputURL.path.fileSystemRepresentation ?: "";
    exporting::ExportServices services;
    services.router = _router;
    services.cache = _frameCache;
    services.epoch = _mediaEpoch;
    services.routing = _routing;
    exporting::ExportOptions options;
    options.poolBudgetFraction = kExportPoolBudgetShare;

    const BOOL accessing = [outputURL startAccessingSecurityScopedResource];
    VEExportHandle *handle = makeExportHandle(outputURL, settings);
    __weak VEEngine *weakSelf = self;
    __weak VEExportHandle *weakHandle = handle;
    void (^progressBlock)(VEExportProgress *) = [progress copy];
    void (^completionBlock)(VEExportSummary *, NSError *) = [completion copy];
    auto onProgress = [weakSelf, progressBlock](const exporting::ExportProgress &p) {
        VEEngine *strongSelf = weakSelf;
        VEExportProgress *report = makeExportProgress(p);
        if (strongSelf != nil) {
            [NSNotificationCenter.defaultCenter postNotificationName:VEEngineExportDidProgressNotification
                                                              object:strongSelf
                                                            userInfo:@{VEEngineExportProgressKey : report}];
        }
        if (progressBlock) {
            progressBlock(report);
        }
    };
    auto onCompletion = [weakSelf, weakHandle, completionBlock](media::Result<exporting::ExportSummary> result) {
        VEEngine *strongSelf = weakSelf;
        VEExportSummary *summary = nil;
        NSError *failure = nil;
        if (result.ok()) {
            summary = makeExportSummary(result.value());
        } else {
            const media::MediaError &e = result.error();
            failure = makeError(e.code == media::MediaErrorCode::Cancelled ? VEEngineErrorExportCancelled
                                                                           : VEEngineErrorExportFailed,
                                toNS(e.message.empty() ? e.description() : e.message));
        }
        if (strongSelf != nil) {
            if (strongSelf->_activeExport == weakHandle) {
                strongSelf->_activeExport = nil;
                [strongSelf stopAccessingExportURL];
                // The monitors' stopped lookahead resumes at their paused frames (the source
                // monitor's only while it is on screen).
                strongSelf->_playback->setIdleLookahead(true);
                [strongSelf updateSourceIdleLookahead];
            }
            [NSNotificationCenter.defaultCenter
                postNotificationName:VEEngineExportDidFinishNotification
                              object:strongSelf
                            userInfo:summary ? @{VEEngineExportSummaryKey : summary} : @{VEEngineExportErrorKey : failure}];
        }
        completionBlock(summary, failure);
    };
    auto started = exporting::ExportJob::start(std::move(request), std::move(services), options,
                                               dispatch_get_main_queue(), onProgress, onCompletion);
    if (!started.ok()) {
        if (accessing) {
            [outputURL stopAccessingSecurityScopedResource];
        }
        const media::MediaError &e = started.error();
        VEEngineErrorCode code = VEEngineErrorExportUnsupported;
        if (e.code == media::MediaErrorCode::FileNotFound) {
            code = VEEngineErrorMissingMedia;
        } else if (e.code == media::MediaErrorCode::PermissionDenied) {
            code = VEEngineErrorOutputNotWritable;
        }
        return refuse(code, toNS(e.message));
    }
    attachExportJob(handle, std::move(started).value());
    _activeExport = handle;
    _exportAccessedURL = accessing ? outputURL : nil;
    // The monitors pause (the export gets the decoders and the GPU); they keep their own pools,
    // and both stop decoding their stopped lookahead (their decoders are released) until the
    // export ends. The paused pictures still come through the scrub path.
    _playback->pause();
    _playback->setIdleLookahead(false);
    if (_sourcePlayback) {
        _sourcePlayback->pause();
    }
    [self updateSourceIdleLookahead];
    return handle;
}

@end
