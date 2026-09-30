// VEEngine (Project, SequenceSettings): the project document (new, open with its bookmarks
// resolved and relinked, save), its properties, and the active sequence's settings.

#import "VEEngine+Internal.h"
#import "VEExporter+Internal.h"

#import "VEFacadeCommands+Internal.h"
#import "VEMediaLibrary+Internal.h"
#import "VESourceMonitor+Internal.h"

#include "../Serialize/ProjectJSON.h"

#include <json.hpp>

#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

using namespace ve;
using namespace ve::facade;

namespace {

/// Key under which the project file stores security-scoped bookmarks (asset id -> base64).
constexpr const char *kBookmarksKey = "assetBookmarks";
/// Key under which the project file stores the media folder's bookmark (base64).
constexpr const char *kMediaFolderBookmarkKey = "mediaFolderBookmark";

} // namespace

@implementation VEEngine (Project)

// MARK: - Project

- (void)newProjectWithName:(NSString *)name {
    VE_ASSERT_MAIN();
    [self resetToEmptyProjectNamed:name];
    [self notifyAssetsAndModelChanged];
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
    _document.mediaFolderBookmark = mediaFolderBookmark;
    NSMutableArray<NSString *> *warningStrings = [NSMutableArray arrayWithCapacity:warnings.size()];
    for (const std::string &warning : warnings) {
        [warningStrings addObject:toNS(warning)];
    }
    _document.loadWarnings = warningStrings;

    // Find every asset's file: through its bookmark (follows moves and grants sandbox access),
    // else by path (VEMediaLibrary keeps the access, the bookmarks to save and the missing files).
    const std::vector<AssetRelink> relinks = [_media locateOpenedAssets:_project.assets bookmarks:bookmarks];
    for (const AssetRelink &relink : relinks) {
        _project.assets[relink.index].url = relink.path;
    }
    const bool relinked = !relinks.empty();
    if (relinked) {
        _document.metadataDirty = true;
        ++_document.extraChanges;
    }

    // Every asset is registered with both decode pools now, the missing ones included (their
    // decodes fail as missing instead of finding whatever the id named before).
    for (const MediaAsset &asset : _project.assets) {
        _program.pool->registerAsset(asset.id, asset.url);
        [_sourceMonitor registerAsset:asset.id path:asset.url];
    }
    [self probeDetailsForProjectAssets];
    [self notifyAssetsAndModelChanged];
    return YES;
}

- (BOOL)saveProjectToURL:(NSURL *)url error:(NSError *_Nullable *_Nullable)error {
    VE_ASSERT_MAIN();
    nlohmann::json json = projectToJson(_project);
    nlohmann::json bookmarks = nlohmann::json::object();
    for (const MediaAsset &asset : _project.assets) {
        if (NSData *bookmark = [_media bookmarkForSavingAsset:asset]) {
            bookmarks[std::to_string(asset.id.value())] = toStd([bookmark base64EncodedStringWithOptions:0]);
        }
    }
    json[kBookmarksKey] = std::move(bookmarks);
    if (_document.mediaFolderBookmark != nil) {
        json[kMediaFolderBookmarkKey] = toStd([_document.mediaFolderBookmark base64EncodedStringWithOptions:0]);
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
    _document.url = url;
    _undo.stack->markClean();
    _document.metadataDirty = false;
    [self notifyModelChanged];
    return YES;
}

- (NSString *)projectName {
    VE_ASSERT_MAIN();
    if (_document.url != nil) {
        return _document.url.URLByDeletingPathExtension.lastPathComponent;
    }
    return toNS(_project.name);
}

- (nullable NSURL *)projectURL {
    VE_ASSERT_MAIN();
    return _document.url;
}

- (BOOL)isDirty {
    VE_ASSERT_MAIN();
    return _undo.stack->isDirty() || _document.metadataDirty;
}

- (uint64_t)changeCount {
    VE_ASSERT_MAIN();
    return _document.changeBase + _undo.stack->changeCount() + _document.extraChanges;
}

- (NSArray<NSString *> *)loadWarnings {
    VE_ASSERT_MAIN();
    return _document.loadWarnings;
}

- (NSArray<NSNumber *> *)missingAssetIDs {
    VE_ASSERT_MAIN();
    NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
    for (AssetId id : _media.missingAssets) {
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
    return _document.mediaFolderBookmark;
}

- (void)setMediaFolderBookmark:(nullable NSData *)mediaFolderBookmark {
    VE_ASSERT_MAIN();
    if (mediaFolderBookmark == _document.mediaFolderBookmark ||
        [mediaFolderBookmark isEqualToData:_document.mediaFolderBookmark]) {
        return;
    }
    _document.mediaFolderBookmark = [mediaFolderBookmark copy];
    // Saved with the project: an unsaved change, outside the undo history.
    _document.metadataDirty = true;
    ++_document.extraChanges;
    [self notifyModelChanged];
}

@end

@implementation VEEngine (ProjectInternal)

// MARK: - Private (VEEngine+Internal.h declares what other files call)

/// Forgets everything cached for the current project's assets (ids restart in every project).
- (void)forgetProjectMedia {
    // A running export renders the old project, whose ids are about to name other media.
    [_exporter cancel];
    // The controllers stop using the old assets first (their ids will name other files).
    [self detachProgramFromProject];
    [_sourceMonitor resetWithProject:_project]; // stops its controller and drops its private project
    [_media forgetThumbnailsAndWaveformsOfAssets:_project.assets];
    // A new media epoch: the frame cache drops every frame and refuses any decoded for the old
    // ids, and both decode pools forget every asset, target, scrub request and decoder, so no
    // decode in flight can publish the previous project's picture under a reused id (see
    // FrameCache.h and DecodePool.h). The controllers register the new project's assets again.
    [self beginMediaEpoch];
    _program.playback->forgetMedia();
    [_sourceMonitor forgetMedia];
    [_media forgetProjectAssets];
    ++_document.generation;
}

/// Installs `project` as the current project with a fresh undo history.
- (void)installProject:(Project)project url:(nullable NSURL *)url {
    [self forgetProjectMedia];
    _document.changeBase += _undo.stack->changeCount() + _document.extraChanges + 1;
    _document.extraChanges = 0;
    _document.metadataDirty = false;
    _document.mediaFolderBookmark = nil;
    _project = std::move(project);
    [self startUndoHistory];
    _document.url = url;
    _document.loadWarnings = @[];
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

/// The model settings `settings` ask for (requestedSequenceFormat).
static SequenceFormat sequenceFormatFrom(VESequenceSettings *settings) {
    return requestedSequenceFormat(settings.width, settings.height, settings.frameDuration, settings.audioSampleRate);
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
