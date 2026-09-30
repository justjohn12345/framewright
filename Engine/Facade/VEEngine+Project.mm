// VEEngine (Project, SequenceSettings): the project document (new, open with its bookmarks
// resolved and relinked, save), its properties, and the active sequence's settings.

#import "VEEngine+Internal.h"

#import "VEFacadeCommands+Internal.h"

#include "../Serialize/ProjectJSON.h"

#include <json.hpp>

#include <algorithm>
#include <climits>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

using namespace ve;
using namespace ve::facade;

namespace {

/// Key under which the project file stores security-scoped bookmarks (asset id -> base64).
constexpr const char *kBookmarksKey = "assetBookmarks";
/// Key under which the project file stores the media folder's bookmark (base64).
constexpr const char *kMediaFolderBookmarkKey = "mediaFolderBookmark";
/// Longest the main thread waits for the bookmarks of a project being opened (they resolve in
/// parallel, never mounting volumes or showing UI); an asset whose bookmark is not resolved in
/// time keeps its stored path.
constexpr double kBookmarkResolutionTimeout = 3.0;

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

} // namespace

@implementation VEEngine (Project)

// MARK: - Project

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
    bool unreadableMediaFolder = false;
    if (json.is_object()) {
        auto it = json.find(kMediaFolderBookmarkKey);
        if (it != json.end() && it->is_string()) {
            mediaFolderBookmark = [[NSData alloc] initWithBase64EncodedString:toNS(it->get<std::string>()) options:0];
            unreadableMediaFolder = mediaFolderBookmark == nil || mediaFolderBookmark.length == 0;
            if (unreadableMediaFolder) {
                mediaFolderBookmark = nil;
            }
        } else if (it != json.end() && !it->is_null()) {
            unreadableMediaFolder = true;
        }
    }

    std::vector<std::string> warnings = std::move(loaded.warnings);
    if (unreadableMediaFolder) {
        warnings.push_back(std::string(kMediaFolderBookmarkKey) +
                           ": the folder for media received from Photos could not be read; it will be asked for again");
    }
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

@end

@implementation VEEngine (ProjectInternal)

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
    const SequenceId sequenceId = project.addSequence("Sequence 1", CMTimeMake(1, 30), 1920, 1080, 2, 2);
    // Not configured: the first video clip placed on it sets its size and frame rate (Sequence.h).
    project.findSequence(sequenceId)->configured = false;
    [self installProject:std::move(project) url:nil];
}

@end

@implementation VEEngine (SequenceSettings)

// MARK: - Sequence settings

+ (NSArray<NSValue *> *)standardSequenceFrameDurations {
    return makeFrameDurationValues(standardFrameDurations());
}

+ (NSString *)nameForFrameDuration:(CMTime)frameDuration {
    return toNS(frameRateName(frameDuration));
}

- (VESequenceSettings *)sequenceSettings {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    return [[VESequenceSettings alloc] initWithWidth:sequence.width
                                              height:sequence.height
                                       frameDuration:sequence.frameDuration
                                     audioSampleRate:sequence.audioSampleRate
                            sharpenScaledDownSources:_project.sharpenScaledDownSources];
}

/// The model settings `settings` ask for (configured). Values that do not fit the model's integers
/// are left out of range, so sequenceFormatProblem refuses them.
static SequenceFormat sequenceFormatFrom(VESequenceSettings *settings) {
    auto side = [](NSInteger value) {
        return static_cast<int32_t>(std::clamp<NSInteger>(value, 0, INT32_MAX));
    };
    SequenceFormat format;
    format.width = side(settings.width);
    format.height = side(settings.height);
    format.frameDuration = settings.frameDuration;
    format.audioSampleRate = side(settings.audioSampleRate);
    format.configured = true;
    return format;
}

- (VESequenceSettingsPreview *)previewSequenceSettings:(VESequenceSettings *)settings {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const SequenceFormat format = sequenceFormatFrom(settings);
    const SequenceFormat current = sequence.format();
    const bool sizeOrRate = format.width != current.width || format.height != current.height ||
                            !(format.frameDuration == current.frameDuration);
    const bool sharpenChanges = bool(settings.sharpenScaledDownSources) != _project.sharpenScaledDownSources;
    const bool changes = !(format == current) || sharpenChanges;
    if (auto problem = sequenceFormatProblem(format)) {
        return makeSequenceSettingsPreview(nullptr, toNS(*problem), changes, NO, @[]);
    }
    // A dry run of the command on a copy of the project.
    Project scratch = _project;
    SetSequenceFormat command(sequence.id, format);
    const EditResult result = command.apply(scratch);
    if (!result) {
        return makeSequenceSettingsPreview(nullptr, toNS(result.message), changes, NO, @[]);
    }
    NSMutableArray<NSString *> *sentences = [NSMutableArray array];
    for (const std::string &sentence : command.report().sentences) {
        [sentences addObject:toNS(sentence)];
    }
    if (!result.droppedTransitionIds.empty()) {
        const size_t n = result.droppedTransitionIds.size();
        [sentences addObject:[NSString stringWithFormat:@"%zu more transition%@ %@ removed: %@ no longer valid at "
                                                        @"these settings.",
                                                        n, n == 1 ? @"" : @"s", n == 1 ? @"is" : @"are",
                                                        n == 1 ? @"it is" : @"they are"]];
    }
    if (!current.configured) {
        [sentences addObject:@"The sequence keeps these settings: the first video clip placed on it will not change "
                             @"them."];
    }
    if (sharpenChanges) {
        [sentences addObject:settings.sharpenScaledDownSources ? @"Scaled-down sources are sharpened."
                                                               : @"Scaled-down sources are no longer sharpened."];
    }
    return makeSequenceSettingsPreview(&command.report(), nil, changes, sizeOrRate && !sequence.isEmpty(), sentences);
}

- (VEEditResult *)applySequenceSettings:(VESequenceSettings *)settings {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const SequenceFormat format = sequenceFormatFrom(settings);
    if (auto problem = sequenceFormatProblem(format)) {
        return [VEEditResult failureWithMessage:toNS(*problem)];
    }
    std::vector<std::unique_ptr<Command>> children;
    children.push_back(std::make_unique<SetSequenceFormat>(sequence.id, format));
    children.push_back(std::make_unique<SetSharpenScaledDownSources>(settings.sharpenScaledDownSources));
    return [self push:std::make_unique<CompositeCommand>("Sequence Settings", std::move(children)) created:nil];
}

- (BOOL)sharpenScaledDownSources {
    VE_ASSERT_MAIN();
    return _project.sharpenScaledDownSources;
}

- (VEEditResult *)setSharpenScaledDownSources:(BOOL)sharpen {
    VE_ASSERT_MAIN();
    return [self push:std::make_unique<SetSharpenScaledDownSources>(sharpen) created:nil];
}

@end
