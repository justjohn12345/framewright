// VEEngine (Media): importing files (probing off the main thread), the asset details and routing
// kept per asset, thumbnails and waveforms, backend and cache preferences, and memory pressure.

#import "VEEngine+Internal.h"

#import "VEPreviewView.h"

#import "VEExport+Internal.h"
#import "VEFacadeCommands+Internal.h"

#include "../Media/AssetImport.h"
#include "../Media/MediaTypes.h"

#include <os/signpost.h>

#include <algorithm>
#include <memory>
#include <optional>
#include <string>
#include <vector>

using namespace ve;
using namespace ve::facade;

namespace {

/// Size of the poster thumbnail generated at import (matches the media bin's request).
constexpr int kPosterMaxDimension = 320;

NSError *makeError(const media::MediaError &error, NSString *context) {
    NSString *message = [NSString stringWithFormat:@"%@: %@", context, toNS(error.message.empty() ? error.description()
                                                                                                    : error.message)];
    return [NSError errorWithDomain:VEEngineErrorDomain
                               code:VEEngineErrorImportFailed
                           userInfo:@{NSLocalizedDescriptionKey : message, @"mediaErrorCode" : @(int(error.code))}];
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

namespace ve::facade {

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

} // namespace ve::facade

@implementation VEEngine (Media)

// MARK: - Media

- (void)importMediaAtURLs:(NSArray<NSURL *> *)urls
               completion:(nullable void (^)(NSArray<VEAssetInfo *> *, NSArray<NSError *> *))completion {
    VE_ASSERT_MAIN();
    auto router = _services.router;
    const size_t count = urls.count;
    const uint64_t generation = _document.generation;
    auto results = std::make_shared<std::vector<ProbedFile>>(count);
    NSArray<NSURL *> *files = [urls copy];
    __weak VEEngine *weakSelf = self;
    dispatch_queue_t queue = _services.probeQueue;
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
    if (generation != _document.generation) {
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
    if (_undo.coalescingKey != nil) {
        // A gesture is in progress: adding the assets now would end its undo group (and its
        // edits are expressed against the state when it began). Add them when it ends.
        __weak VEEngine *weakSelf = self;
        [_undo.deferredImports addObject:^{
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
                _assets.details[id] = file.details;
                // Ids are never reused, but never let a stale entry name another file.
                _assets.bookmarks[@(static_cast<int64_t>(id.value()))] = file.bookmark;
                _assets.missing.erase(id);
                // Keep sandbox access to the file for this session (bookmark resolution
                // grants it again after reopening).
                NSURL *url = urls[sourceIndex[k]];
                if ([url startAccessingSecurityScopedResource]) {
                    [_assets.accessedURLs addObject:url];
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
    _assets.mainThreadImportSeconds += CFAbsoluteTimeGetCurrent() - start;
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
    return _undo.deferredImports.count;
}

- (void)startPosterAndWaveformForAsset:(AssetId)id {
    const MediaAsset *asset = _project.findAsset(id);
    if (asset == nullptr) {
        return;
    }
    const uint64_t generation = _document.generation;
    __weak VEEngine *weakSelf = self;
    if (asset->hasVideo()) {
        thumbs::ThumbnailRequest request;
        request.asset = id;
        request.url = asset->url;
        request.time = kCMTimeZero;
        request.maxDimension = kPosterMaxDimension;
        _services.thumbnails->request(request, dispatch_get_main_queue(), [weakSelf, generation, id](auto result) {
            VEEngine *strongSelf = weakSelf;
            if (strongSelf != nil && strongSelf->_document.generation == generation && result.ok()) {
                [strongSelf notifyThumbnailForAsset:id];
            }
        });
    }
    if (asset->hasAudio()) {
        thumbs::WaveformRequest request;
        request.asset = id;
        request.url = asset->url;
        _services.waveforms->request(request, dispatch_get_main_queue(), [weakSelf, generation, id](auto result) {
            VEEngine *strongSelf = weakSelf;
            if (strongSelf != nil && strongSelf->_document.generation == generation && result.ok()) {
                [strongSelf notifyWaveformForAsset:id];
            }
        });
    }
}

- (VEEditResult *)removeAsset:(VEAssetID)assetID {
    VE_ASSERT_MAIN();
    const AssetId id(static_cast<AssetId::ValueType>(assetID));
    if (_undo.coalescingKey != nil) {
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
    if (asset == nullptr || !asset->hasVideo() || _assets.missing.count(id)) {
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
    const uint64_t generation = _document.generation;
    __weak VEEngine *weakSelf = self;
    _services.thumbnails->request(request, dispatch_get_main_queue(),
                                  [weakSelf, generation, completion](media::Result<thumbs::ThumbnailImage> result) {
                                      VEEngine *strongSelf = weakSelf;
                                      if (strongSelf == nil || strongSelf->_document.generation != generation) {
                                          completion(NULL,
                                                     makeError(VEEngineErrorProjectClosed, @"the project was closed"));
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
    if (asset == nullptr || !asset->hasAudio() || _assets.missing.count(id)) {
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
    const uint64_t generation = _document.generation;
    __weak VEEngine *weakSelf = self;
    _services.waveforms->request(
        request, dispatch_get_main_queue(), [weakSelf, generation, completion, id](thumbs::WaveformResult result) {
            VEEngine *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf->_document.generation != generation) {
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
    auto peaks = _services.waveforms->cached(id);
    return peaks ? makeWaveform(id, peaks) : nil;
}

- (VEHardwareCaps *)hardwareCaps {
    VE_ASSERT_MAIN();
    return makeHardwareCaps();
}

- (NSArray<NSString *> *)backendNames {
    VE_ASSERT_MAIN();
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (const std::string &name : _services.router->backendNames()) {
        [names addObject:toNS(name)];
    }
    return names;
}

- (nullable NSString *)preferredBackend {
    VE_ASSERT_MAIN();
    auto policy = _services.router->defaultPolicy();
    return policy.preferBackendName ? toNS(*policy.preferBackendName) : nil;
}

- (void)setPreferredBackend:(nullable NSString *)preferredBackend {
    VE_ASSERT_MAIN();
    media::RoutingPolicy policy = _services.router->defaultPolicy();
    if (preferredBackend.length > 0) {
        policy.preferBackendName = toStd(preferredBackend);
    } else {
        policy.preferBackendName.reset();
    }
    _services.router->setDefaultPolicy(policy);
}

- (NSUInteger)frameCacheBudgetBytes {
    VE_ASSERT_MAIN();
    return _services.frameCache->budget();
}

- (void)setFrameCacheBudgetBytes:(NSUInteger)frameCacheBudgetBytes {
    VE_ASSERT_MAIN();
    _services.frameCache->setBudget(std::max<NSUInteger>(frameCacheBudgetBytes, NSUInteger(16) << 20));
}

- (double)mainThreadImportSeconds {
    VE_ASSERT_MAIN();
    return _assets.mainThreadImportSeconds;
}

- (void)handleMemoryPressure:(BOOL)critical {
    VE_ASSERT_MAIN();
    _services.frameCache->handleMemoryPressure(critical ? media::MemoryPressure::Critical
                                                        : media::MemoryPressure::Warning);
    [_program.view handleMemoryPressure];
    [_program.outputView handleMemoryPressure];
    [_source.view handleMemoryPressure];
    if (auto job = exportJobOf(_export.active)) {
        job->handleMemoryPressure(critical);
    }
    for (const MediaAsset &asset : _project.assets) {
        _services.thumbnails->purge(asset.id);
        _services.waveforms->purge(asset.id);
    }
    [NSNotificationCenter.defaultCenter postNotificationName:VEEngineMemoryPressureNotification
                                                      object:self
                                                    userInfo:@{VEEngineCriticalKey : @(critical)}];
}

@end

@implementation VEEngine (MediaInternal)

/// Re-probes the project's assets in the background for the details that are not stored in
/// the project file (codec names, routing reason), and hands the routing to the decode pool.
- (void)probeDetailsForProjectAssets {
    const uint64_t generation = _document.generation;
    auto router = _services.router;
    __weak VEEngine *weakSelf = self;
    for (const MediaAsset &asset : _project.assets) {
        if (_assets.missing.count(asset.id)) {
            continue;
        }
        const AssetId assetId = asset.id;
        const std::string path = asset.url;
        dispatch_async(_services.probeQueue, ^{
            auto routed = std::make_shared<media::Result<media::RoutedMediaInfo>>(router->probe(path));
            dispatch_async(dispatch_get_main_queue(), ^{
                VEEngine *strongSelf = weakSelf;
                if (strongSelf == nil || strongSelf->_document.generation != generation || !routed->ok()) {
                    return;
                }
                const MediaAsset *current = strongSelf->_project.findAsset(assetId);
                if (current == nullptr || current->url != path) {
                    return;
                }
                strongSelf->_assets.details[assetId] = detailsFor(routed->value());
                [strongSelf registerRouting:routed->value() forAsset:assetId path:path];
                [strongSelf notifyAssetsChanged];
            });
        });
    }
}

/// Hands an asset's routing to every decode path (saves a probe per decoder).
- (void)registerRouting:(const media::RoutedMediaInfo &)routed forAsset:(AssetId)asset path:(const std::string &)path {
    _assets.routing[asset] = routed;
    _program.pool->registerAsset(asset, path, routed);
    _source.pool->registerAsset(asset, path, routed);
    _program.playback->setAssetRouting(asset, routed);
    if (_source.playback) {
        _source.playback->setAssetRouting(asset, routed);
    }
}

@end
