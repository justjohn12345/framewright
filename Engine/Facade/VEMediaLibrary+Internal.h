// VEMediaLibrary: what the facade knows about the project's media files beyond the model. It probes
// files off the main thread (imports, and the details of an opened project's assets), keeps each
// asset's routing and probe details, the assets whose files were missing when the project was
// opened, the security-scoped bookmarks saved with the project and the sandbox access to the files,
// and runs the thumbnail and waveform services. It knows nothing of the engine or of the model beyond
// the assets it is handed: the engine adds the imported assets to the model (an undoable command),
// checks that a probed asset is still in the project, hands the routing to the monitors' decode
// paths and posts the notifications.
//
// The router is a shared dependency injected by the engine (the monitors' decode pools and
// controllers and the exports use it too), not owned here. -forgetProjectAssets (New/Open) starts a
// new project for the library: a thumbnail or waveform requested before it completes with nullptr,
// and a poster, waveform (startPosterAndWaveformForAsset:...) or details probe
// (probeDetailsOfAssets:completion:) requested before it is not reported at all. An import probe
// (probeFilesAtURLs:completion:) always completes: whether its files still belong to the open
// project is the caller's to decide.
// Private to the facade implementation: excluded from the framework's headers (project.yml).

#pragma once

#import <Foundation/Foundation.h>

#import "VETypes+Internal.h"

#include "../Media/BackendRouter.h"
#include "../Media/MediaTypes.h"
#include "../Model/Project.h"
#include "../Thumbs/ThumbnailService.h"
#include "../Thumbs/WaveformService.h"

#include <cstddef>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace ve::facade {

/// One file probed for an import (-probeFilesAtURLs:completion:).
struct ProbedMediaFile {
    /// The asset the file makes (with a placeholder id: the model assigns the real one), or nullopt
    /// when the probe failed (see `error`).
    std::optional<MediaAsset> asset;
    std::optional<media::RoutedMediaInfo> routed;
    AssetDetails details;
    /// Security-scoped bookmark of the file (a plain one outside the sandbox scope; nil if none).
    NSData *_Nullable bookmark = nil;
    /// Why the file cannot be imported (set when `asset` is not).
    std::optional<media::MediaError> error;
};

/// An opened project's asset whose bookmark resolved to another file: `path` replaces the stored
/// one of the asset at `index` (-locateOpenedAssets:bookmarks:).
struct AssetRelink {
    size_t index = 0;
    std::string path;
};

} // namespace ve::facade

NS_ASSUME_NONNULL_BEGIN

/// The probed files of one -probeFilesAtURLs:completion: call, in the order of its URLs.
typedef void (^VEMediaProbeCompletion)(std::shared_ptr<std::vector<ve::facade::ProbedMediaFile>> files);
/// One asset of -probeDetailsOfAssets:completion: probed again (only successful probes of the
/// current project are reported).
typedef void (^VEMediaDetailsCompletion)(ve::AssetId asset, const std::string &path,
                                         const ve::media::RoutedMediaInfo &routed);
/// An asset's poster thumbnail or waveform is ready (only for the current project).
typedef void (^VEMediaAssetReady)(ve::AssetId asset);
/// The result of a thumbnail request; nullptr when the project was replaced (or the library
/// released) meanwhile.
typedef void (^VEMediaThumbnailCompletion)(const ve::media::Result<ve::thumbs::ThumbnailImage> *_Nullable result);
/// The result of a waveform request; nullptr when the project was replaced (or the library
/// released) meanwhile.
typedef void (^VEMediaWaveformCompletion)(const ve::thumbs::WaveformResult *_Nullable result);

/// Main thread only; every completion runs on the main queue.
/// Final: the engine coordinates it as it is (no subclass can change its contract).
__attribute__((objc_subclassing_restricted))
@interface VEMediaLibrary : NSObject

/// `router` probes the files and feeds the thumbnail and waveform services, whose disk caches live
/// under `cacheDirectory` (Thumbnails/, Waveforms/; nil: memory caches only).
- (instancetype)initWithRouter:(std::shared_ptr<ve::media::BackendRouter>)router
                cacheDirectory:(nullable NSURL *)cacheDirectory NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

// MARK: Import

/// Probes `urls` in parallel off the main thread (with their security-scoped access for the
/// probe) and hands the results to `completion` on the main queue, always (also after
/// -forgetProjectAssets: the library records nothing until -addImportedAsset:file:url:).
- (void)probeFilesAtURLs:(NSArray<NSURL *> *)urls completion:(VEMediaProbeCompletion)completion;
/// Records `file` (a successful probe) as the media of the imported asset `asset`: its details,
/// routing and bookmark, the file not missing, and sandbox access to `url` kept for this project.
- (void)addImportedAsset:(ve::AssetId)asset file:(const ve::facade::ProbedMediaFile &)file url:(NSURL *)url;
/// Generates the poster thumbnail (assets with a picture) and the waveform (assets with sound) of
/// an imported asset; `thumbnailReady` / `waveformReady` run when one is ready.
- (void)startPosterAndWaveformForAsset:(const ve::MediaAsset &)asset
                        thumbnailReady:(VEMediaAssetReady)thumbnailReady
                         waveformReady:(VEMediaAssetReady)waveformReady;

// MARK: Open and save

/// Finds the files of an opened project's `assets` (the library has just been emptied with
/// -forgetProjectAssets): resolves their `bookmarks` (asset id -> bookmark) in parallel off the
/// main thread, bounded in time, keeps sandbox access to the resolved files, remembers the
/// bookmarks that resolved and are not stale (re-saving is byte identical) and records the assets
/// whose file does not exist. Returns the assets whose bookmark found their file at another path.
- (std::vector<ve::facade::AssetRelink>)locateOpenedAssets:(const std::vector<ve::MediaAsset> &)assets
                                                 bookmarks:(NSDictionary<NSNumber *, NSData *> *)bookmarks;
/// Probes the present files of `assets` again off the main thread, for the details that are not
/// stored in the project file (codec names, routing); `completion` gets each successful probe of
/// the current project. Record it with -recordProbe:forAsset: once the asset is known to be current.
- (void)probeDetailsOfAssets:(const std::vector<ve::MediaAsset> &)assets completion:(VEMediaDetailsCompletion)completion;
/// Records a probe of `asset`'s file: its details and routing.
- (void)recordProbe:(const ve::media::RoutedMediaInfo &)routed forAsset:(ve::AssetId)asset;
/// The bookmark to save for `asset`: the one remembered, else (unless its file is missing) a new
/// one, which is remembered; nil when the file cannot be bookmarked.
- (nullable NSData *)bookmarkForSavingAsset:(const ve::MediaAsset &)asset;

// MARK: What is known per asset

/// Every asset's routing (handed to exports and to a new playback controller). A reference to the
/// library's own map, valid until the library next changes: read it, or copy it, at once. Never send it
/// to nil: a message to nil returns a null reference (undefined behaviour to read), not an empty map. The
/// engine creates its library in -init and keeps it until -dealloc.
- (const std::map<ve::AssetId, ve::media::RoutedMediaInfo> &)routing;
/// `asset`'s probe details, or nullopt.
- (std::optional<ve::facade::AssetDetails>)detailsForAsset:(ve::AssetId)asset;
- (BOOL)isAssetMissing:(ve::AssetId)asset;
/// The assets whose files were missing when the project was opened. A reference to the library's
/// own set, valid until the library next changes. Never send it to nil (see -routing).
- (const std::set<ve::AssetId> &)missingAssets;

// MARK: Thumbnails and waveforms

/// A thumbnail of `asset` (which has a picture) at source time `time` (0 for a still or a time that
/// is not numeric), its longest side `maxDimension` clamped to [16, 4096].
- (void)thumbnailOfAsset:(const ve::MediaAsset &)asset
                  atTime:(CMTime)time
            maxDimension:(NSInteger)maxDimension
              completion:(VEMediaThumbnailCompletion)completion;
/// The waveform peaks of `asset` (which has sound).
- (void)waveformOfAsset:(const ve::MediaAsset &)asset completion:(VEMediaWaveformCompletion)completion;
/// The waveform peaks of `asset`'s file (its current path) already in memory, or nullptr. Asset ids
/// restart per project: peaks computed from another file under the same id are never returned.
- (std::shared_ptr<const ve::thumbs::WaveformPeaks>)cachedWaveformOfAsset:(const ve::MediaAsset &)asset;
/// Drops the in-memory thumbnails and waveforms of `assets` (memory pressure).
- (void)purgeThumbnailsAndWaveformsOfAssets:(const std::vector<ve::MediaAsset> &)assets;
/// Cancels the pending thumbnails and the waveform requests of `assets` and drops their in-memory
/// thumbnails and waveforms (New/Open: their ids are about to name other media). A cancelled waveform
/// request completes as dropped (see -forgetProjectAssets) or, for a poster pass, is not reported.
- (void)forgetThumbnailsAndWaveformsOfAssets:(const std::vector<ve::MediaAsset> &)assets;

// MARK: New/Open and lifetime

/// Forgets the routing, details, missing assets and bookmarks, ends the access to the files, cancels
/// every waveform request still running (also of assets removed before) and starts a new project:
/// results of earlier requests are dropped (New/Open).
- (void)forgetProjectAssets;
/// Thumbnail, waveform, poster and details requests whose completions have not run on the main queue yet
/// (dropped results included): zero once every request made so far has come back.
@property (nonatomic, readonly) NSUInteger requestsInFlight;
/// Blocks until the thumbnail and waveform services have nothing queued or in progress, or `timeout`
/// seconds pass (NO). Completions may still be on their way to the main queue (see requestsInFlight).
- (BOOL)waitUntilServicesAreIdle:(NSTimeInterval)timeout;
/// Ends the security-scoped access of every file the library kept (also done when it is released).
- (void)stopAccessingURLs;

@end

NS_ASSUME_NONNULL_END
