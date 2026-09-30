// VEEngine: lifetime (init, dealloc), versions, observers and the notifications every area posts,
// with the main-thread check and the makeError / toVE helpers VEEngine+Internal.h declares. The areas
// of VEEngine.h are implemented in the VEEngine+<Area>.mm categories.

#import "VEEngine+Internal.h"
#import "VEExporter+Internal.h"
#import "VEMediaLibrary+Internal.h"
#import "VEProgramMonitor+Internal.h"
#import "VESourceMonitor+Internal.h"

#include "../Media/FFmpeg/FFmpegBackend.h"
#include "../Media/HardwareCaps.h"

#include <memory>
#include <utility>
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

[[noreturn]] void veMainThreadViolation(const char *function) {
    [NSException raise:NSInternalInconsistencyException
                format:@"VEEngine must be used on the main thread (%s called on %@)", function, NSThread.currentThread];
    __builtin_unreachable();
}

namespace ve::facade {

NSError *makeError(VEEngineErrorCode code, NSString *message) {
    return [NSError errorWithDomain:VEEngineErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey : message}];
}

VEEditResult *toVE(const EditResult &result, NSArray<NSNumber *> *created, NSString *note) {
    return makeEditResult(result, created, note);
}

} // namespace ve::facade

@implementation VEEngine

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
        _services.router = media::BackendRouter::makeDefault();
        (void)_services.router->registerBackend(media::ffmpeg::makeFFmpegBackend());
        _services.frameCache = std::make_shared<media::FrameCache>();
        _services.epoch = _services.frameCache->epoch();
        __weak VEEngine *weakEngine = self;
        ProgramMonitorConfig programConfig;
        programConfig.poolBudgetShare = kProgramPoolBudgetShare;
        programConfig.scrubLaneBase = kProgramLaneBase;
        _programMonitor = [[VEProgramMonitor alloc] initWithRouter:_services.router
                                                        frameCache:_services.frameCache
                                                            config:programConfig
                                                          onStatus:^(VEPlaybackStatus *status) {
                                                            [weakEngine postPlaybackStatus:status];
                                                          }];
        _media = [[VEMediaLibrary alloc] initWithRouter:_services.router cacheDirectory:cacheDirectory];
        SourceMonitorConfig sourceConfig;
        sourceConfig.poolBudgetShare = kSourcePoolBudgetShare;
        sourceConfig.scrubLaneBase = kSourceScrubLaneBase;
        sourceConfig.playbackLaneBase = kSourcePlaybackLaneBase;
        _sourceMonitor = [[VESourceMonitor alloc] initWithRouter:_services.router
                                                      frameCache:_services.frameCache
                                                          config:sourceConfig
                                                        onStatus:^(VEPlaybackStatus *status) {
                                                          [weakEngine postSourcePlaybackStatus:status];
                                                        }];
        _rippleScope = VERippleScopeAllTracks;
        _undo.stack = std::make_unique<UndoStack>();
        _exporter = [[VEExporter alloc] init];
        _observers = [NSHashTable weakObjectsHashTable];
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
    [_exporter cancel]; // the job deletes its partial file on its own queue
    // The views may outlive the engine: they must stop calling into the controllers first.
    [_programMonitor disconnectViews];
    [_sourceMonitor disconnectView];
    [_media stopAccessingURLs];
}

- (void)addObserver:(id<VEEngineObserver>)observer {
    VE_ASSERT_MAIN();
    [_observers addObject:observer];
}

- (void)removeObserver:(id<VEEngineObserver>)observer {
    VE_ASSERT_MAIN();
    [_observers removeObject:observer];
}

// MARK: - Media epoch

- (void)beginMediaEpoch {
    _services.epoch = _services.frameCache->beginEpoch();
    [_programMonitor beginMediaEpoch:_services.epoch];
    [_sourceMonitor beginMediaEpoch:_services.epoch];
}

// MARK: - Notifications

- (void)notifyModelChanged {
    [self publishPlaybackSnapshot];
    [self sourceMonitorModelChanged];
    [self updateUseCounts];
    const uint64_t count = self.changeCount;
    [self postNotification:VEEngineModelDidChangeNotification
                  userInfo:@{VEEngineChangeCountKey : @(count)}
            observerMethod:@selector(engine:modelDidChange:)
                    notify:^(id<VEEngineObserver> observer) {
                        [observer engine:self modelDidChange:count];
                    }];
}

/// Posts an assets notification when a clip edit changed how often an asset is used
/// (VEAssetInfo.useCount), so the media bin does not show stale counts.
- (void)updateUseCounts {
    std::vector<std::pair<AssetId, size_t>> current = assetUseCounts(_project);
    if (current != _lastUseCounts) {
        _lastUseCounts = std::move(current);
        [self notifyAssetsChanged];
    }
}

- (void)notifyAssetsChanged {
    [self postNotification:VEEngineAssetsDidChangeNotification
                  userInfo:nil
            observerMethod:@selector(engineAssetsDidChange:)
                    notify:^(id<VEEngineObserver> observer) {
                        [observer engineAssetsDidChange:self];
                    }];
}

- (void)notifyAssetsAndModelChanged {
    [self notifyAssetsChanged];
    [self notifyModelChanged];
}

- (void)notifyThumbnailForAsset:(AssetId)asset {
    const auto assetID = static_cast<VEAssetID>(asset.value());
    [self postNotification:VEEngineThumbnailDidBecomeAvailableNotification
                  userInfo:@{VEEngineAssetIDKey : @(assetID)}
            observerMethod:@selector(engine:thumbnailAvailableForAsset:)
                    notify:^(id<VEEngineObserver> observer) {
                        [observer engine:self thumbnailAvailableForAsset:assetID];
                    }];
}

- (void)notifyWaveformForAsset:(AssetId)asset {
    const auto assetID = static_cast<VEAssetID>(asset.value());
    [self postNotification:VEEngineWaveformDidBecomeAvailableNotification
                  userInfo:@{VEEngineAssetIDKey : @(assetID)}
            observerMethod:@selector(engine:waveformAvailableForAsset:)
                    notify:^(id<VEEngineObserver> observer) {
                        [observer engine:self waveformAvailableForAsset:assetID];
                    }];
}

- (void)postNotification:(NSNotificationName)name
                userInfo:(nullable NSDictionary *)userInfo
          observerMethod:(SEL)selector
                  notify:(void(NS_NOESCAPE ^)(id<VEEngineObserver> observer))notify {
    [NSNotificationCenter.defaultCenter postNotificationName:name object:self userInfo:userInfo];
    for (id<VEEngineObserver> observer in _observers.allObjects) {
        if ([observer respondsToSelector:selector]) {
            notify(observer);
        }
    }
}

@end
