// VEMediaLibrary: see VEMediaLibrary+Internal.h.

#import "VEMediaLibrary+Internal.h"

#import "VEFacadeSupport+Internal.h"

#include "../Media/AssetImport.h"

#include <algorithm>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <utility>
#include <vector>

// This class knows nothing of the engine (VEEngine+Internal.h, "Facade layout"): neither its header nor
// this file may bring in the engine's headers, directly or through another header.
#if defined(VE_ENGINE_HEADER_INCLUDED) || defined(VE_ENGINE_INTERNAL_HEADER_INCLUDED)
#error "VEMediaLibrary must not depend on VEEngine: it reaches it only through what the engine passes in"
#endif

using namespace ve;
using namespace ve::facade;

namespace {

/// Size of the poster thumbnail generated at import (matches the media bin's request).
constexpr int kPosterMaxDimension = 320;
/// Longest the main thread waits for the bookmarks of a project being opened (they resolve in
/// parallel, never mounting volumes or showing UI); an asset whose bookmark is not resolved in
/// time keeps its stored path.
constexpr double kBookmarkResolutionTimeout = 3.0;

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

NSNumber *keyFor(AssetId asset) {
    return @(static_cast<int64_t>(asset.value()));
}

} // namespace

@implementation VEMediaLibrary {
    std::shared_ptr<media::BackendRouter> _router;
    std::unique_ptr<thumbs::ThumbnailService> _thumbnails;
    std::unique_ptr<thumbs::WaveformService> _waveforms;
    // Concurrent: probes files and hands the results to the main queue.
    dispatch_queue_t _probeQueue;
    // Advanced by forgetProjectAssets: results of requests made for an earlier project are dropped.
    uint64_t _generation;
    NSUInteger _requestsInFlight; // see -requestsInFlight

    std::map<AssetId, media::RoutedMediaInfo> _routing; // handed to every decode path
    std::map<AssetId, AssetDetails> _details;           // probe details not stored in the project file
    std::set<AssetId> _missing;                         // files not found when the project was opened
    // Asset id -> security-scoped bookmark, saved with the project.
    NSMutableDictionary<NSNumber *, NSData *> *_bookmarks;
    // Security-scoped URLs accessed for this project (stopAccessingURLs ends the access).
    NSMutableArray<NSURL *> *_accessedURLs;
    // Waveform requests not completed yet, by asset: New/Open cancels them (the service computes on one
    // thread, so the new project's waveforms would otherwise wait behind the closed project's).
    std::map<AssetId, std::set<thumbs::WaveformService::RequestId>> _waveformRequests;
}

- (instancetype)initWithRouter:(std::shared_ptr<media::BackendRouter>)router cacheDirectory:(nullable NSURL *)cacheDirectory {
    VE_ASSERT_MAIN();
    if ((self = [super init])) {
        _router = std::move(router);
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
        _probeQueue = dispatch_queue_create(
            "com.justjohn12345.framewright.engine.probe",
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_CONCURRENT, QOS_CLASS_USER_INITIATED, 0));
        _bookmarks = [NSMutableDictionary dictionary];
        _accessedURLs = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    [self stopAccessingURLs];
}

// MARK: - Import

- (void)probeFilesAtURLs:(NSArray<NSURL *> *)urls completion:(VEMediaProbeCompletion)completion {
    VE_ASSERT_MAIN();
    auto router = _router;
    const size_t count = urls.count;
    auto results = std::make_shared<std::vector<ProbedMediaFile>>(count);
    NSArray<NSURL *> *files = [urls copy];
    VEMediaProbeCompletion done = [completion copy];
    dispatch_queue_t queue = _probeQueue;
    dispatch_async(queue, ^{
        // Probe in parallel (each probe blocks on file I/O).
        dispatch_apply(count, queue, ^(size_t i) {
            ProbedMediaFile &file = (*results)[i];
            NSURL *url = files[i];
            const std::string path = toStd(url.path);
            BOOL accessing = [url startAccessingSecurityScopedResource];
            auto routed = router->probe(path);
            if (!routed.ok()) {
                file.error = routed.error();
            } else {
                auto asset = media::makeMediaAsset(routed.value(), AssetId(1));
                if (!asset.ok()) {
                    file.error = asset.error();
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
            done(results);
        });
    });
}

- (void)addImportedAsset:(AssetId)asset file:(const ProbedMediaFile &)file url:(NSURL *)url {
    VE_ASSERT_MAIN();
    _details[asset] = file.details;
    // Ids are never reused, but never let a stale entry name another file.
    _bookmarks[keyFor(asset)] = file.bookmark;
    _missing.erase(asset);
    // Keep sandbox access to the file for this session (bookmark resolution grants it again after
    // reopening).
    [self keepAccessToURL:url];
    if (file.routed) {
        _routing[asset] = *file.routed;
    }
}

- (void)startPosterAndWaveformForAsset:(const MediaAsset &)asset
                        thumbnailReady:(VEMediaAssetReady)thumbnailReady
                         waveformReady:(VEMediaAssetReady)waveformReady {
    VE_ASSERT_MAIN();
    const uint64_t generation = _generation;
    const AssetId id = asset.id;
    __weak VEMediaLibrary *weakSelf = self;
    if (asset.hasVideo()) {
        thumbs::ThumbnailRequest request;
        request.asset = id;
        request.url = asset.url;
        request.time = kCMTimeZero;
        request.maxDimension = kPosterMaxDimension;
        VEMediaAssetReady ready = [thumbnailReady copy];
        ++_requestsInFlight;
        _thumbnails->request(request, dispatch_get_main_queue(), [weakSelf, generation, id, ready](auto result) {
            VEMediaLibrary *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            --strongSelf->_requestsInFlight;
            if (strongSelf->_generation == generation && result.ok()) {
                ready(id);
            }
        });
    }
    if (asset.hasAudio()) {
        thumbs::WaveformRequest request;
        request.asset = id;
        request.url = asset.url;
        VEMediaAssetReady ready = [waveformReady copy];
        auto requestId = std::make_shared<thumbs::WaveformService::RequestId>(0);
        ++_requestsInFlight;
        *requestId = _waveforms->request(
            request, dispatch_get_main_queue(), [weakSelf, generation, id, ready, requestId](auto result) {
                VEMediaLibrary *strongSelf = weakSelf;
                if (strongSelf == nil) {
                    return;
                }
                --strongSelf->_requestsInFlight;
                [strongSelf waveformRequest:*requestId ofAssetEnded:id];
                if (strongSelf->_generation == generation && result.ok()) {
                    ready(id);
                }
            });
        [self waveformRequest:*requestId ofAssetStarted:id];
    }
}

/// Records a waveform request until its completion (the service never completes inline, so the
/// completion always comes after this).
- (void)waveformRequest:(thumbs::WaveformService::RequestId)requestId ofAssetStarted:(AssetId)asset {
    if (requestId != 0) {
        _waveformRequests[asset].insert(requestId);
    }
}

- (void)waveformRequest:(thumbs::WaveformService::RequestId)requestId ofAssetEnded:(AssetId)asset {
    auto it = _waveformRequests.find(asset);
    if (it != _waveformRequests.end() && it->second.erase(requestId) != 0 && it->second.empty()) {
        _waveformRequests.erase(it);
    }
}

/// Cancels the waveform requests of `asset` that have not completed (each completes as cancelled).
- (void)cancelWaveformRequestsOfAsset:(AssetId)asset {
    auto it = _waveformRequests.find(asset);
    if (it == _waveformRequests.end()) {
        return;
    }
    const std::set<thumbs::WaveformService::RequestId> requests = std::move(it->second);
    _waveformRequests.erase(it);
    for (thumbs::WaveformService::RequestId requestId : requests) {
        _waveforms->cancel(requestId);
    }
}

// MARK: - Open and save

- (std::vector<AssetRelink>)locateOpenedAssets:(const std::vector<MediaAsset> &)assets
                                     bookmarks:(NSDictionary<NSNumber *, NSData *> *)bookmarks {
    VE_ASSERT_MAIN();
    // Resolve every asset: through its bookmark (follows moves and grants sandbox access), else by
    // path. The bookmarks resolve in parallel off the main thread, bounded in time.
    NSMutableArray<NSData *> *toResolve = [NSMutableArray array];
    std::vector<size_t> resolvedAsset; // index into `assets` per entry of toResolve
    for (size_t i = 0; i < assets.size(); ++i) {
        if (NSData *bookmark = bookmarks[keyFor(assets[i].id)]) {
            [toResolve addObject:bookmark];
            resolvedAsset.push_back(i);
        }
    }
    const std::vector<ResolvedBookmark> resolutions = resolveBookmarks(toResolve);
    std::vector<std::optional<ResolvedBookmark>> resolutionOf(assets.size());
    for (size_t k = 0; k < resolutions.size(); ++k) {
        resolutionOf[resolvedAsset[k]] = resolutions[k];
    }
    std::vector<AssetRelink> relinks;
    for (size_t i = 0; i < assets.size(); ++i) {
        const MediaAsset &asset = assets[i];
        std::string path = asset.url;
        NSData *bookmark = bookmarks[keyFor(asset.id)];
        if (resolutionOf[i]) {
            NSURL *resolved = resolutionOf[i]->url;
            const BOOL stale = resolutionOf[i]->stale;
            if (resolved != nil) {
                [self keepAccessToURL:resolved];
                // Bookmarks resolve to canonical paths (/private/var/...): only a different file
                // counts as a relink.
                NSString *canonicalResolved = resolved.URLByResolvingSymlinksInPath.path;
                NSString *canonicalStored = [NSURL fileURLWithPath:toNS(asset.url)].URLByResolvingSymlinksInPath.path;
                const std::string resolvedPath = toStd(resolved.path);
                if (!resolvedPath.empty() && ![canonicalResolved isEqualToString:canonicalStored]) {
                    path = resolvedPath;
                    relinks.push_back(AssetRelink{i, resolvedPath});
                }
                if (!stale) {
                    _bookmarks[keyFor(asset.id)] = bookmark; // re-saving is byte identical
                }
            }
        }
        if (![NSFileManager.defaultManager fileExistsAtPath:toNS(path)]) {
            _missing.insert(asset.id);
        }
    }
    return relinks;
}

- (void)probeDetailsOfAssets:(const std::vector<MediaAsset> &)assets completion:(VEMediaDetailsCompletion)completion {
    VE_ASSERT_MAIN();
    const uint64_t generation = _generation;
    auto router = _router;
    __weak VEMediaLibrary *weakSelf = self;
    VEMediaDetailsCompletion done = [completion copy];
    for (const MediaAsset &asset : assets) {
        if (_missing.count(asset.id)) {
            continue;
        }
        const AssetId assetId = asset.id;
        const std::string path = asset.url;
        ++_requestsInFlight;
        dispatch_async(_probeQueue, ^{
            auto routed = std::make_shared<media::Result<media::RoutedMediaInfo>>(router->probe(path));
            dispatch_async(dispatch_get_main_queue(), ^{
                VEMediaLibrary *strongSelf = weakSelf;
                if (strongSelf == nil) {
                    return;
                }
                --strongSelf->_requestsInFlight;
                if (strongSelf->_generation != generation || !routed->ok()) {
                    return;
                }
                done(assetId, path, routed->value());
            });
        });
    }
}

- (void)recordProbe:(const media::RoutedMediaInfo &)routed forAsset:(AssetId)asset {
    VE_ASSERT_MAIN();
    _details[asset] = detailsFor(routed);
    _routing[asset] = routed;
}

- (nullable NSData *)bookmarkForSavingAsset:(const MediaAsset &)asset {
    VE_ASSERT_MAIN();
    NSNumber *key = keyFor(asset.id);
    NSData *bookmark = _bookmarks[key];
    if (bookmark == nil && !_missing.count(asset.id)) {
        bookmark = makeBookmark(toNS(asset.url));
        if (bookmark != nil) {
            _bookmarks[key] = bookmark;
        }
    }
    return bookmark;
}

// MARK: - What is known per asset

- (const std::map<AssetId, media::RoutedMediaInfo> &)routing {
    VE_ASSERT_MAIN();
    return _routing;
}

- (std::optional<AssetDetails>)detailsForAsset:(AssetId)asset {
    VE_ASSERT_MAIN();
    auto details = _details.find(asset);
    return details == _details.end() ? std::nullopt : std::optional<AssetDetails>(details->second);
}

- (BOOL)isAssetMissing:(AssetId)asset {
    VE_ASSERT_MAIN();
    return _missing.count(asset) > 0;
}

- (NSUInteger)requestsInFlight {
    VE_ASSERT_MAIN();
    return _requestsInFlight;
}

- (const std::set<AssetId> &)missingAssets {
    VE_ASSERT_MAIN();
    return _missing;
}

// MARK: - Thumbnails and waveforms

- (void)thumbnailOfAsset:(const MediaAsset &)asset
                  atTime:(CMTime)time
            maxDimension:(NSInteger)maxDimension
              completion:(VEMediaThumbnailCompletion)completion {
    VE_ASSERT_MAIN();
    thumbs::ThumbnailRequest request;
    request.asset = asset.id;
    request.url = asset.url;
    request.time = asset.isStill() || !CMTIME_IS_NUMERIC(time) ? kCMTimeZero : time;
    request.maxDimension = int(std::clamp<NSInteger>(maxDimension, 16, 4096));
    const uint64_t generation = _generation;
    __weak VEMediaLibrary *weakSelf = self;
    VEMediaThumbnailCompletion done = [completion copy];
    ++_requestsInFlight;
    _thumbnails->request(request, dispatch_get_main_queue(),
                         [weakSelf, generation, done](media::Result<thumbs::ThumbnailImage> result) {
                             VEMediaLibrary *strongSelf = weakSelf;
                             if (strongSelf != nil) {
                                 --strongSelf->_requestsInFlight;
                             }
                             if (strongSelf == nil || strongSelf->_generation != generation) {
                                 done(nullptr);
                             } else {
                                 done(&result);
                             }
                         });
}

- (void)waveformOfAsset:(const MediaAsset &)asset completion:(VEMediaWaveformCompletion)completion {
    VE_ASSERT_MAIN();
    thumbs::WaveformRequest request;
    request.asset = asset.id;
    request.url = asset.url;
    const uint64_t generation = _generation;
    __weak VEMediaLibrary *weakSelf = self;
    VEMediaWaveformCompletion done = [completion copy];
    const AssetId id = asset.id;
    auto requestId = std::make_shared<thumbs::WaveformService::RequestId>(0);
    ++_requestsInFlight;
    *requestId = _waveforms->request(
        request, dispatch_get_main_queue(), [weakSelf, generation, done, id, requestId](thumbs::WaveformResult result) {
            VEMediaLibrary *strongSelf = weakSelf;
            if (strongSelf != nil) {
                --strongSelf->_requestsInFlight;
            }
            [strongSelf waveformRequest:*requestId ofAssetEnded:id];
            if (strongSelf == nil || strongSelf->_generation != generation) {
                done(nullptr);
            } else {
                done(&result);
            }
        });
    [self waveformRequest:*requestId ofAssetStarted:id];
}

- (std::shared_ptr<const thumbs::WaveformPeaks>)cachedWaveformOfAsset:(const MediaAsset &)asset {
    VE_ASSERT_MAIN();
    return _waveforms->cached(asset.id, asset.url);
}

- (void)purgeThumbnailsAndWaveformsOfAssets:(const std::vector<MediaAsset> &)assets {
    VE_ASSERT_MAIN();
    for (const MediaAsset &asset : assets) {
        _thumbnails->purge(asset.id);
        _waveforms->purge(asset.id);
    }
}

- (void)forgetThumbnailsAndWaveformsOfAssets:(const std::vector<MediaAsset> &)assets {
    VE_ASSERT_MAIN();
    for (const MediaAsset &asset : assets) {
        _thumbnails->cancelPending(asset.id);
        _thumbnails->purge(asset.id);
        [self cancelWaveformRequestsOfAsset:asset.id];
        _waveforms->purge(asset.id);
    }
}

// MARK: - New/Open and lifetime

- (void)forgetProjectAssets {
    VE_ASSERT_MAIN();
    _routing.clear();
    _details.clear();
    _missing.clear();
    [_bookmarks removeAllObjects];
    [self stopAccessingURLs];
    // Requests of assets no longer in the project (removed before New/Open) end too.
    while (!_waveformRequests.empty()) {
        [self cancelWaveformRequestsOfAsset:_waveformRequests.begin()->first];
    }
    ++_generation;
}

/// Keeps sandbox access to `url` for this project (when it grants security-scoped access);
/// stopAccessingURLs ends it.
- (void)keepAccessToURL:(NSURL *)url {
    if ([url startAccessingSecurityScopedResource]) {
        [_accessedURLs addObject:url];
    }
}

// No main-thread check: the engine's dealloc calls it (the engine only logs a fault when its last
// reference goes away off the main thread), and so does this class's.
- (void)stopAccessingURLs {
    for (NSURL *url in _accessedURLs) {
        [url stopAccessingSecurityScopedResource];
    }
    [_accessedURLs removeAllObjects];
}

@end
