// VEEngine (Media): importing files (VEMediaLibrary probes them off the main thread; the engine adds
// them to the model), thumbnails and waveforms, backend and cache preferences, and memory pressure.
// What is known per asset beyond the model lives in VEMediaLibrary (VEMediaLibrary+Internal.h).

#import "VEEngine+Internal.h"

#import "VEExporter+Internal.h"
#import "VEFacadeCommands+Internal.h"
#import "VEMediaLibrary+Internal.h"
#import "VEProgramMonitor+Internal.h"
#import "VESourceMonitor+Internal.h"

#include "../Media/MediaTypes.h"

#include <os/signpost.h>

#include <algorithm>
#include <memory>
#include <string>
#include <vector>

using namespace ve;
using namespace ve::facade;

namespace {

NSError *makeError(const media::MediaError &error, NSString *context) {
    NSString *message = [NSString stringWithFormat:@"%@: %@", context, toNS(error.message.empty() ? error.description()
                                                                                                    : error.message)];
    return [NSError errorWithDomain:VEEngineErrorDomain
                               code:VEEngineErrorImportFailed
                           userInfo:@{NSLocalizedDescriptionKey : message, @"mediaErrorCode" : @(int(error.code))}];
}

} // namespace

@implementation VEEngine (Media)

// MARK: - Media

- (void)importMediaAtURLs:(NSArray<NSURL *> *)urls
               completion:(nullable void (^)(NSArray<VEAssetInfo *> *, NSArray<NSError *> *))completion {
    VE_ASSERT_MAIN();
    const uint64_t generation = _document.generation;
    NSArray<NSURL *> *files = [urls copy];
    __weak VEEngine *weakSelf = self;
    [_media probeFilesAtURLs:files
                  completion:^(std::shared_ptr<std::vector<ProbedMediaFile>> results) {
                    [weakSelf finishImport:results urls:files generation:generation completion:completion];
                  }];
}

- (void)finishImport:(std::shared_ptr<std::vector<ProbedMediaFile>>)probed
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
        [self deferUntilCoalescingEnds:^{
            [weakSelf finishImport:probed urls:urls generation:generation completion:completion];
        }];
        return;
    }
    std::vector<ProbedMediaFile> &results = *probed;
    const os_signpost_id_t signpost = os_signpost_id_generate(_log);
    os_signpost_interval_begin(_log, signpost, "ImportMainThread", "%zu files", results.size());
    const CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();

    NSMutableArray<NSError *> *errors = [NSMutableArray array];
    NSMutableArray<NSNumber *> *reportedIDs = [NSMutableArray array];
    std::vector<MediaAsset> toAdd;
    std::vector<size_t> sourceIndex;
    for (size_t i = 0; i < results.size(); ++i) {
        ProbedMediaFile &file = results[i];
        if (!file.asset) {
            [errors addObject:file.error ? makeError(*file.error, urls[i].lastPathComponent)
                                         : makeError(VEEngineErrorImportFailed, @"import failed")];
            continue;
        }
        auto existing = std::find_if(_project.assets.begin(), _project.assets.end(),
                                     [&](const MediaAsset &a) { return a.isFileBacked() && a.url == file.asset->url; });
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
            __weak VEEngine *weakSelf = self;
            for (size_t k = 0; k < ids.size(); ++k) {
                ProbedMediaFile &file = results[sourceIndex[k]];
                const AssetId id = ids[k];
                // Its details, bookmark and routing, and sandbox access to the file for this
                // session (bookmark resolution grants it again after reopening).
                [_media addImportedAsset:id file:file url:urls[sourceIndex[k]]];
                [self handRoutingToMonitors:*file.routed forAsset:id path:file.asset->url];
                if (const MediaAsset *asset = _project.findAsset(id)) {
                    [_media startPosterAndWaveformForAsset:*asset
                        thumbnailReady:^(AssetId ready) {
                          [weakSelf notifyThumbnailForAsset:ready];
                        }
                        waveformReady:^(AssetId ready) {
                          [weakSelf notifyWaveformForAsset:ready];
                        }];
                }
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
        [self notifyAssetsAndModelChanged];
    }
    if (completion) {
        completion(assets, errors);
    }
}

- (NSUInteger)deferredImportCount {
    VE_ASSERT_MAIN();
    return _undo.deferredImports.count;
}

- (VEEditResult *)removeAsset:(VEAssetID)assetID {
    VE_ASSERT_MAIN();
    const AssetId id = toAssetId(assetID);
    if (_undo.coalescingKey != nil) {
        return [VEEditResult failureWithCode:VEEditErrorBusy
                                     message:@"Finish the current edit before removing media."];
    }
    EditResult result = [self pushCommand:std::make_unique<RemoveAsset>(id)];
    if (result) {
        [self notifyAssetsAndModelChanged];
    }
    return toVE(result);
}

- (void)thumbnailForAsset:(VEAssetID)assetID
                   atTime:(CMTime)time
             maxDimension:(NSInteger)maxDimension
               completion:(void (^)(CGImageRef _Nullable, NSError *_Nullable))completion {
    VE_ASSERT_MAIN();
    const AssetId id = toAssetId(assetID);
    const MediaAsset *asset = _project.findAsset(id);
    if (asset == nullptr || !asset->hasVideo() || !asset->isFileBacked() || [_media isAssetMissing:id]) {
        NSError *error = makeError(VEEngineErrorReadFailed, asset == nullptr        ? @"unknown asset"
                                                            : !asset->hasVideo()     ? @"the asset has no picture"
                                                            : !asset->isFileBacked() ? @"a generated picture has no thumbnail"
                                                                                     : @"the media file is missing");
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(NULL, error);
        });
        return;
    }
    [_media thumbnailOfAsset:*asset
                      atTime:time
                maxDimension:maxDimension
                  completion:^(const media::Result<thumbs::ThumbnailImage> *result) {
                    if (result == nullptr) {
                        completion(NULL, makeError(VEEngineErrorProjectClosed, @"the project was closed"));
                    } else if (!result->ok()) {
                        completion(NULL, makeError(result->error(), @"thumbnail"));
                    } else {
                        completion(result->value().get(), nil);
                    }
                  }];
}

- (void)waveformForAsset:(VEAssetID)assetID completion:(void (^)(VEWaveform *_Nullable, NSError *_Nullable))completion {
    VE_ASSERT_MAIN();
    const AssetId id = toAssetId(assetID);
    const MediaAsset *asset = _project.findAsset(id);
    if (asset == nullptr || !asset->hasAudio() || [_media isAssetMissing:id]) {
        NSError *error = makeError(VEEngineErrorReadFailed, asset == nullptr ? @"unknown asset"
                                                            : !asset->hasAudio() ? @"the asset has no audio"
                                                                                 : @"the media file is missing");
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, error);
        });
        return;
    }
    [_media waveformOfAsset:*asset
                 completion:^(const thumbs::WaveformResult *result) {
                   if (result == nullptr) {
                       completion(nil, makeError(VEEngineErrorProjectClosed, @"the project was closed"));
                   } else if (!result->ok()) {
                       completion(nil, makeError(result->error(), @"waveform"));
                   } else {
                       completion(makeWaveform(id, result->value()), nil);
                   }
                 }];
}

- (nullable VEWaveform *)cachedWaveformForAsset:(VEAssetID)assetID {
    VE_ASSERT_MAIN();
    const AssetId id = toAssetId(assetID);
    const MediaAsset *asset = _project.findAsset(id);
    if (asset == nullptr || !asset->hasAudio() || [_media isAssetMissing:id]) {
        return nil;
    }
    auto peaks = [_media cachedWaveformOfAsset:*asset];
    return peaks ? makeWaveform(id, peaks) : nil;
}

- (BOOL)waitUntilMediaWorkIsIdle:(NSTimeInterval)timeout {
    VE_ASSERT_MAIN();
    return [_media waitUntilServicesAreIdle:timeout];
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
    return _mainThreadImportSeconds;
}

- (void)handleMemoryPressure:(BOOL)critical {
    VE_ASSERT_MAIN();
    _services.frameCache->handleMemoryPressure(critical ? media::MemoryPressure::Critical
                                                        : media::MemoryPressure::Warning);
    [_programMonitor handleMemoryPressure];
    [_sourceMonitor handleMemoryPressure];
    [_exporter handleMemoryPressure:critical];
    [_media purgeThumbnailsAndWaveformsOfAssets:_project.assets];
    [NSNotificationCenter.defaultCenter postNotificationName:VEEngineMemoryPressureNotification
                                                      object:self
                                                    userInfo:@{VEEngineCriticalKey : @(critical)}];
}

@end

@implementation VEEngine (MediaInternal)

// MARK: - Private (VEEngine+Internal.h declares them)

/// Hands an asset's routing to both monitors' decode paths (saves a probe per decoder); the
/// library keeps it for exports and a new source controller.
- (void)handRoutingToMonitors:(const media::RoutedMediaInfo &)routed
                     forAsset:(AssetId)asset
                         path:(const std::string &)path {
    [_programMonitor registerAsset:asset path:path routing:routed];
    [_sourceMonitor registerAsset:asset path:path routing:routed];
}

/// Re-probes the project's assets in the background for the details that are not stored in
/// the project file (codec names, routing reason), and hands the routing to the decode pools.
- (void)probeDetailsForProjectAssets {
    __weak VEEngine *weakSelf = self;
    [_media probeDetailsOfAssets:_project.assets
                      completion:^(AssetId assetId, const std::string &path, const media::RoutedMediaInfo &routed) {
                        VEEngine *strongSelf = weakSelf;
                        if (strongSelf == nil) {
                            return;
                        }
                        const MediaAsset *current = strongSelf->_project.findAsset(assetId);
                        if (current == nullptr || current->url != path) {
                            return;
                        }
                        [strongSelf->_media recordProbe:routed forAsset:assetId];
                        [strongSelf handRoutingToMonitors:routed forAsset:assetId path:path];
                        [strongSelf notifyAssetsChanged];
                      }];
}

@end
