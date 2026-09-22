#import "VEEngine.h"

#import "VEPreviewView.h"

#import "../Render/VEPreviewView+Internal.h"
#import "VEFacadeCommands+Internal.h"
#import "VEProgramFrameProvider+Internal.h"
#import "VETypes+Internal.h"

#include "../Edit/EditOps.h"
#include "../Edit/UndoStack.h"
#include "../Media/AssetImport.h"
#include "../Media/BackendRouter.h"
#include "../Media/DecodePool.h"
#include "../Media/FFmpeg/FFmpegBackend.h"
#include "../Media/FrameCache.h"
#include "../Media/HardwareCaps.h"
#include "../Media/MediaTypes.h"
#include "../Render/Scheduler.h"
#include "../Serialize/ProjectJSON.h"
#include "../Thumbs/ThumbnailService.h"
#include "../Thumbs/WaveformService.h"

#include <json.hpp>

#include <os/signpost.h>

#include <algorithm>
#include <map>
#include <memory>
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
NSString *const VEEngineChangeCountKey = @"changeCount";
NSString *const VEEngineAssetIDKey = @"assetID";
NSErrorDomain const VEEngineErrorDomain = @"VidEditEngine.VEEngine";

/// Engine model calls are confined to the main thread.
#define VE_ASSERT_MAIN() NSAssert(NSThread.isMainThread, @"VEEngine must be used on the main thread")

namespace {

/// Size of the poster thumbnail generated at import (matches the media bin's request).
constexpr int kPosterMaxDimension = 320;
/// Key under which the project file stores security-scoped bookmarks (asset id -> base64).
constexpr const char *kBookmarksKey = "assetBookmarks";

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

VEEditResult *toVE(const EditResult &result, NSArray<NSNumber *> *created = @[]) {
    if (result.ok()) {
        return [VEEditResult successWithCreatedIDs:created];
    }
    NSString *message = toNS(result.message);
    return [VEEditResult failureWithMessage:message.length > 0 ? message : @(nameOf(result.error))];
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

/// Result of probing one file on the background queue.
struct ProbedFile {
    std::optional<MediaAsset> asset;
    std::optional<media::RoutedMediaInfo> routed;
    AssetDetails details;
    NSData *bookmark = nil;
    NSError *error = nil;
};

} // namespace

@implementation VEEngine {
    std::shared_ptr<media::BackendRouter> _router;
    std::shared_ptr<media::FrameCache> _frameCache;
    std::shared_ptr<media::DecodePool> _decodePool;
    std::unique_ptr<thumbs::ThumbnailService> _thumbnails;
    std::unique_ptr<thumbs::WaveformService> _waveforms;
    std::shared_ptr<ProgramFrameProvider> _program;

    Project _project;
    std::unique_ptr<UndoStack> _undo;
    uint64_t _changeBase;      // changeCount of earlier projects' undo stacks
    uint64_t _extraChanges;    // changes outside the undo stack (relinks on open)
    bool _metadataDirty;       // relinked paths not saved yet
    uint64_t _projectGeneration; // drops async results that belong to a replaced project
    NSString *_coalescingKey;
    // Active sequence as it was when the open coalescing group began: relative edits (moveClips)
    // are computed against it because each step of the group replaces the previous one.
    std::optional<Sequence> _coalescingBase;

    std::map<AssetId, AssetDetails> _details;
    std::set<AssetId> _missing;
    NSMutableDictionary<NSNumber *, NSData *> *_bookmarks;
    NSMutableArray<NSURL *> *_accessedURLs;
    NSURL *_projectURL;

    NSHashTable<id<VEEngineObserver>> *_observers;
    __weak VEPreviewView *_programView;
    CMTime _programTime;
    dispatch_queue_t _probeQueue;
    dispatch_source_t _memoryPressureSource;
    double _mainThreadImportSeconds;
    os_log_t _log;
}

// MARK: - Versions

+ (NSString *)engineVersion {
    NSBundle *bundle = [NSBundle bundleForClass:self];
    NSString *version = [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSAssert(version.length > 0, @"VidEditEngine.framework Info.plist has no CFBundleShortVersionString");
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
    return [[support URLByAppendingPathComponent:@"VidEdit" isDirectory:YES] URLByAppendingPathComponent:@"Caches"
                                                                                               isDirectory:YES];
}

- (instancetype)init {
    return [self initWithCacheDirectory:[VEEngine defaultCacheDirectory]];
}

- (instancetype)initWithCacheDirectory:(nullable NSURL *)cacheDirectory {
    VE_ASSERT_MAIN();
    if ((self = [super init])) {
        _log = os_log_create("com.justjohn12345.videdit.engine", "Facade");
        _router = media::BackendRouter::makeDefault();
        (void)_router->registerBackend(media::ffmpeg::makeFFmpegBackend());
        _frameCache = std::make_shared<media::FrameCache>();
        _decodePool = std::make_shared<media::DecodePool>(_router, _frameCache);
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
        _program = std::make_shared<ProgramFrameProvider>(_decodePool);
        _undo = std::make_unique<UndoStack>();
        _changeBase = 0;
        _extraChanges = 0;
        _metadataDirty = false;
        _projectGeneration = 0;
        _programTime = kCMTimeZero;
        _bookmarks = [NSMutableDictionary dictionary];
        _accessedURLs = [NSMutableArray array];
        _observers = [NSHashTable weakObjectsHashTable];
        _probeQueue = dispatch_queue_create("com.justjohn12345.videdit.engine.probe",
                                            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT,
                                                                                    QOS_CLASS_USER_INITIATED, 0));
        // Probe VideoToolbox once off the main thread so the Preferences pane never waits.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            (void)media::HardwareCaps::get();
        });
        std::weak_ptr<media::FrameCache> weakCache = _frameCache;
        _memoryPressureSource = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0, DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
        dispatch_source_t source = _memoryPressureSource;
        dispatch_source_set_event_handler(_memoryPressureSource, ^{
            const unsigned long level = dispatch_source_get_data(source);
            if (auto cache = weakCache.lock()) {
                cache->handleMemoryPressure((level & DISPATCH_MEMORYPRESSURE_CRITICAL) != 0
                                                ? media::MemoryPressure::Critical
                                                : media::MemoryPressure::Warning);
            }
        });
        dispatch_resume(_memoryPressureSource);
        [self resetToEmptyProjectNamed:@"Untitled"];
    }
    return self;
}

- (void)dealloc {
    if (_memoryPressureSource != nil) {
        dispatch_source_cancel(_memoryPressureSource);
    }
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
    const uint64_t count = self.changeCount;
    [NSNotificationCenter.defaultCenter postNotificationName:VEEngineModelDidChangeNotification
                                                      object:self
                                                    userInfo:@{VEEngineChangeCountKey : @(count)}];
    for (id<VEEngineObserver> observer in _observers.allObjects) {
        if ([observer respondsToSelector:@selector(engine:modelDidChange:)]) {
            [observer engine:self modelDidChange:count];
        }
    }
    [self refreshProgramFrame];
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
    for (const MediaAsset &asset : _project.assets) {
        _thumbnails->cancelPending(asset.id);
        _thumbnails->purge(asset.id);
        _waveforms->purge(asset.id);
        _decodePool->invalidate(asset.id);
    }
    _decodePool->setTargets({});
    _frameCache->purgeAll();
    _program->cancel();
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
    _undo = std::make_unique<UndoStack>();
    _coalescingKey = nil;
    _coalescingBase.reset();
    _project = std::move(project);
    _projectURL = url;
    _programTime = kCMTimeZero;
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
                               [NSString stringWithFormat:@"%@ is not a valid VidEdit project: %@",
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

    [self installProject:std::move(project) url:url];

    // Resolve every asset: through its bookmark (follows moves and grants sandbox access),
    // else by path.
    bool relinked = false;
    for (MediaAsset &asset : _project.assets) {
        NSNumber *key = @(static_cast<int64_t>(asset.id.value()));
        NSData *bookmark = bookmarks[key];
        if (bookmark != nil) {
            BOOL stale = NO;
            NSURL *resolved = [NSURL URLByResolvingBookmarkData:bookmark
                                                        options:NSURLBookmarkResolutionWithSecurityScope |
                                                                NSURLBookmarkResolutionWithoutUI
                                                  relativeToURL:nil
                                            bookmarkDataIsStale:&stale
                                                          error:nil];
            if (resolved == nil) {
                resolved = [NSURL URLByResolvingBookmarkData:bookmark
                                                     options:NSURLBookmarkResolutionWithoutUI
                                               relativeToURL:nil
                                         bookmarkDataIsStale:&stale
                                                       error:nil];
            }
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

    for (const MediaAsset &asset : _project.assets) {
        if (!_missing.count(asset.id)) {
            _decodePool->registerAsset(asset.id, asset.url);
        }
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
                strongSelf->_decodePool->registerAsset(assetId, path, routed->value());
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
    const std::string text = json.dump(2) + "\n";
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
    return clip ? makeClipInfo(*clip, *track, _project) : nil;
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
            [clips addObject:makeClipInfo(clip, *track, _project)];
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
                [clips addObject:makeClipInfo(clip, track, _project)];
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
            VEEngine *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            [strongSelf finishImport:*results urls:files completion:completion];
        });
    });
}

- (void)finishImport:(std::vector<ProbedFile> &)results
                urls:(NSArray<NSURL *> *)urls
          completion:(nullable void (^)(NSArray<VEAssetInfo *> *, NSArray<NSError *> *))completion {
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
        [self closeCoalescingIfOpen];
        EditResult result = _undo->push(_project, std::move(command));
        if (!result) {
            [errors addObject:makeError(VEEngineErrorImportFailed, toNS(result.message))];
        } else {
            const std::vector<AssetId> &ids = import->createdAssetIds();
            for (size_t k = 0; k < ids.size(); ++k) {
                ProbedFile &file = results[sourceIndex[k]];
                const AssetId id = ids[k];
                _details[id] = file.details;
                if (file.bookmark != nil) {
                    _bookmarks[@(static_cast<int64_t>(id.value()))] = file.bookmark;
                }
                _missing.erase(id);
                // Keep sandbox access to the file for this session (bookmark resolution
                // grants it again after reopening).
                NSURL *url = urls[sourceIndex[k]];
                if ([url startAccessingSecurityScopedResource]) {
                    [_accessedURLs addObject:url];
                }
                _decodePool->registerAsset(id, file.asset->url, *file.routed);
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
    [self closeCoalescingIfOpen];
    EditResult result = _undo->push(_project, std::make_unique<RemoveAsset>(id));
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
                                 completion(NULL, makeError(VEEngineErrorReadFailed, @"the project was closed"));
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
                                completion(nil, makeError(VEEngineErrorReadFailed, @"the project was closed"));
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
    return makeHardwareCaps();
}

- (NSArray<NSString *> *)backendNames {
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

// MARK: - Edits

- (SequenceId)sequenceId {
    return _project.activeSequenceId;
}

/// Pushes an edit (tagged with the open coalescing group's key) and notifies on success.
- (VEEditResult *)push:(std::unique_ptr<Command>)command created:(NSArray<NSNumber *> * (^_Nullable)(void))created {
    if (_coalescingKey != nil) {
        command->setCoalescingKey(toStd(_coalescingKey));
    }
    EditResult result = _undo->push(_project, std::move(command));
    if (!result) {
        return toVE(result);
    }
    NSArray<NSNumber *> *ids = created ? created() : @[];
    [self notifyModelChanged];
    return toVE(result, ids);
}

- (void)closeCoalescingIfOpen {
    if (_coalescingKey != nil) {
        _undo->endCoalescing();
        _coalescingKey = nil;
    }
    _coalescingBase.reset();
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
    if (overwrite) {
        auto command = std::make_unique<OverwriteClip>([self sequenceId], time, std::move(placements), link);
        OverwriteClip *raw = command.get();
        return [self push:std::move(command)
                  created:^NSArray<NSNumber *> * {
                      return toNumbers(raw->createdClipIds());
                  }];
    }
    auto command = std::make_unique<InsertClip>([self sequenceId], time, std::move(placements), link);
    InsertClip *raw = command.get();
    return [self push:std::move(command)
              created:^NSArray<NSNumber *> * {
                  return toNumbers(raw->createdClipIds());
              }];
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
    if (!CMTIME_IS_NUMERIC(delta)) {
        return [VEEditResult failureWithMessage:@"Invalid time."];
    }
    const Sequence &sequence = _coalescingBase ? *_coalescingBase : [self activeSequence];
    std::vector<ClipId> ids = toClipIds(clipIDs);
    // A linked partner is carried along by MoveClip; moving it again would double the move.
    std::set<ClipId> chosen;
    struct Move {
        ClipId clip;
        TrackId destination;
        CMTime start;
    };
    std::vector<Move> moves;
    for (ClipId id : ids) {
        auto location = sequence.locateClip(id);
        if (!location) {
            return [VEEditResult failureWithMessage:@"A selected clip no longer exists."];
        }
        const Clip &clip = sequence.tracks(location->trackKind)[location->trackIndex].clips[location->clipIndex];
        if (chosen.count(id) || (clip.linkedClipId && chosen.count(*clip.linkedClipId))) {
            continue;
        }
        chosen.insert(id);
        const auto &tracks = sequence.tracks(location->trackKind);
        const NSInteger destinationIndex = NSInteger(location->trackIndex) + trackOffset;
        if (destinationIndex < 0 || destinationIndex >= NSInteger(tracks.size())) {
            return [VEEditResult failureWithMessage:@"There is no track there."];
        }
        const CMTime newStart = clip.timelineStart + delta;
        if (newStart < kCMTimeZero) {
            return [VEEditResult failureWithMessage:@"Clips cannot move before the sequence start."];
        }
        moves.push_back(Move{id, tracks[size_t(destinationIndex)].id, newStart});
    }
    if (moves.empty()) {
        return [VEEditResult failureWithMessage:@"Nothing to move."];
    }
    // Move the leading clips first so a moved clip never overwrites one still waiting to move.
    const bool forward = delta > kCMTimeZero;
    std::stable_sort(moves.begin(), moves.end(), [&](const Move &a, const Move &b) {
        const Clip *ca = sequence.findClip(a.clip);
        const Clip *cb = sequence.findClip(b.clip);
        return forward ? cb->timelineStart < ca->timelineStart : ca->timelineStart < cb->timelineStart;
    });
    if (moves.size() == 1) {
        return [self push:std::make_unique<MoveClip>([self sequenceId], moves[0].clip, moves[0].destination,
                                                     moves[0].start)
                  created:nil];
    }
    std::vector<std::unique_ptr<Command>> children;
    for (const Move &m : moves) {
        children.push_back(std::make_unique<MoveClip>([self sequenceId], m.clip, m.destination, m.start));
    }
    return [self push:std::make_unique<CompositeCommand>("Move Clips", std::move(children)) created:nil];
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
        auto split = std::make_unique<SplitClip>([self sequenceId], id, at);
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
    return [self push:std::make_unique<RippleDelete>([self sequenceId], std::move(ids)) created:nil];
}

- (VEEditResult *)setVideoParams:(VEVideoParams)params forClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<SetVideoParams>([self sequenceId],
                                                       ClipId(static_cast<ClipId::ValueType>(clipID)), fromVE(params))
              created:nil];
}

- (VEEditResult *)setAudioParams:(VEAudioParams)params forClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<SetAudioParams>([self sequenceId],
                                                       ClipId(static_cast<ClipId::ValueType>(clipID)), fromVE(params))
              created:nil];
}

- (VEEditResult *)setSpeed:(double)speed forClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    SpeedOptions options;
    options.ripple = true;
    return [self push:std::make_unique<SetClipSpeed>([self sequenceId], ClipId(static_cast<ClipId::ValueType>(clipID)),
                                                     speed, options)
              created:nil];
}

- (VEEditResult *)addTransitionFromClip:(VEClipID)fromClipID toClip:(VEClipID)toClipID duration:(CMTime)duration {
    VE_ASSERT_MAIN();
    auto command = std::make_unique<AddTransition>([self sequenceId],
                                                   ClipId(static_cast<ClipId::ValueType>(fromClipID)),
                                                   ClipId(static_cast<ClipId::ValueType>(toClipID)), duration);
    AddTransition *raw = command.get();
    return [self push:std::move(command)
              created:^NSArray<NSNumber *> * {
                  return @[ @(static_cast<int64_t>(raw->createdTransitionId().value())) ];
              }];
}

- (VEEditResult *)removeTransition:(VETransitionID)transitionID {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<RemoveTransition>([self sequenceId],
                                                         TransitionId(static_cast<TransitionId::ValueType>(transitionID)))
              created:nil];
}

- (VEEditResult *)setDuration:(CMTime)duration forTransition:(VETransitionID)transitionID {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<SetTransitionDuration>(
                          [self sequenceId], TransitionId(static_cast<TransitionId::ValueType>(transitionID)), duration)
              created:nil];
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
    [self closeCoalescingIfOpen];
    _coalescingKey = [key copy];
    _coalescingBase = [self activeSequence];
    _undo->beginCoalescing(toStd(_coalescingKey));
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
    _coalescingBase.reset();
    const bool reverted = _undo->cancelCoalescing(_project);
    if (reverted) {
        [self notifyAssetsChanged];
        [self notifyModelChanged];
    }
}

- (BOOL)isCoalescing {
    VE_ASSERT_MAIN();
    return _coalescingKey != nil;
}

- (BOOL)undo {
    VE_ASSERT_MAIN();
    _coalescingKey = nil;
    _coalescingBase.reset();
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
    _coalescingBase.reset();
    if (!_undo->redo(_project)) {
        return NO;
    }
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

// MARK: - Program monitor

- (void)attachProgramView:(nullable VEPreviewView *)view {
    VE_ASSERT_MAIN();
    VEPreviewView *previous = _programView;
    if (previous != nil && previous != view) {
        [previous setFrameSource:ve::render::PreviewFrameSource{}];
    }
    _programView = view;
    if (view != nil) {
        [view setFrameSource:_program->makeSource()];
        [self refreshProgramFrame];
    } else {
        _program->cancel();
    }
}

- (void)showProgramFrameAtTime:(CMTime)time {
    VE_ASSERT_MAIN();
    _programTime = CMTIME_IS_NUMERIC(time) ? time : kCMTimeZero;
    [self refreshProgramFrame];
}

- (void)refreshProgramFrame {
    if (_programView == nil) {
        return;
    }
    RenderGraph graph = Scheduler::renderGraphAt([self activeSequence], _project, _programTime);
    const Sequence &sequence = [self activeSequence];
    graph.width = sequence.width;
    graph.height = sequence.height;
    __weak VEEngine *weakSelf = self;
    _program->show(std::move(graph), [weakSelf] {
        VEEngine *strongSelf = weakSelf;
        if (strongSelf != nil) {
            [strongSelf->_programView renderOnce];
        }
    });
}

@end
