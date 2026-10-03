// VEEngine (Titles): titles and colour mattes. The edit rules are in Engine/Edit/TitleEdits.h (SetGeneratedContent,
// summarizeTitles, AddGeneratedClip) and EditOps.h (a ClipPlacement with generated content); this file converts,
// adds the project's generator asset in the same undo step as the first clip of its kind, measures a title's block
// for the program monitor's box, and follows the fonts installed on the Mac.

#import "VEEngine+Internal.h"
#import "VEFacadeCommands+Internal.h"
#import "VEProgramMonitor+Internal.h"
#import "VETitles+Internal.h"

#include "../Edit/TitleEdits.h"
#include "../Media/TitleRenderer.h"

#import <AppKit/AppKit.h>
#import <CoreText/CoreText.h>

#include <cmath>
#include <map>

using namespace ve;
using namespace ve::facade;

NSNotificationName const VEEngineTitleFontsDidChangeNotification = @"VEEngineTitleFontsDidChangeNotification";

namespace {

const char *undoNameOf(GeneratedPreset preset) {
    switch (preset) {
    case GeneratedPreset::Title:
        return "Add Title";
    case GeneratedPreset::LowerThird:
        return "Add Lower Third";
    case GeneratedPreset::ColourMatte:
        return "Add Colour Matte";
    }
    return "Add Title";
}

std::vector<ClipId> clipIdsOf(NSArray<NSNumber *> *clipIDs) {
    std::vector<ClipId> ids;
    ids.reserve(clipIDs.count);
    for (NSNumber *number : clipIDs) {
        ids.push_back(toClipId(number.longLongValue));
    }
    return ids;
}

/// Title blocks measured (titleBlockSizeOfClip:), per content and frame size: the box follows a drag without
/// measuring again. Forgotten when the Mac's fonts change (a block measured in a fallback font). Main thread only.
std::map<std::pair<ContentId, std::pair<int32_t, int32_t>>, CGSize> &measuredTitleBlocks() {
    static std::map<std::pair<ContentId, std::pair<int32_t, int32_t>>, CGSize> measured;
    return measured;
}

} // namespace

@implementation VEEngine (Titles)

// MARK: - Adding

/// `placement`, preceded by adding the project's generator asset of `kind` when it has none, as one command named
/// `name`.
- (std::unique_ptr<Command>)withGeneratorAsset:(GeneratorKind)kind
                                     placement:(std::unique_ptr<Command>)placement
                                          name:(const char *)name {
    if (_project.findGeneratorAsset(kind) != nullptr) {
        return placement;
    }
    std::vector<std::unique_ptr<Command>> children;
    children.push_back(std::make_unique<ImportAssets>(std::vector<MediaAsset>{makeGeneratorAsset(kind)}));
    children.push_back(std::move(placement));
    return std::make_unique<CompositeCommand>(name, std::move(children));
}

- (VEEditResult *)addGeneratedPreset:(VEGeneratedPreset)preset atTime:(CMTime)time aboveTrack:(VETrackID)videoTrackID {
    VE_ASSERT_MAIN();
    const auto generatedPreset = fromVE(preset);
    if (!generatedPreset) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"Unknown title preset."];
    }
    const char *name = undoNameOf(*generatedPreset);
    auto add = std::make_unique<AddGeneratedClip>([self sequenceId], time, toTrackId(videoTrackID),
                                                  GeneratedContent::makePreset(*generatedPreset), defaultStillDuration(),
                                                  name);
    AddGeneratedClip *raw = add.get();
    return [self push:[self withGeneratorAsset:generatorKindOf(*generatedPreset) placement:std::move(add) name:name]
              created:^NSArray<NSNumber *> * {
                  return @[ @(static_cast<int64_t>(raw->createdClipId().value())) ];
              }];
}

- (VEEditResult *)placeGeneratedPreset:(VEGeneratedPreset)preset
                               onTrack:(VETrackID)videoTrackID
                                atTime:(CMTime)time
                                insert:(BOOL)insert {
    VE_ASSERT_MAIN();
    const auto generatedPreset = fromVE(preset);
    if (!generatedPreset) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"Unknown title preset."];
    }
    const Track *track = [self activeSequence].findTrack(toTrackId(videoTrackID));
    if (track == nullptr || track->kind != TrackKind::Video) {
        return [VEEditResult failureWithCode:VEEditErrorTrackKindMismatch message:@"Titles go on video tracks."];
    }
    ClipPlacement placement;
    placement.trackId = track->id;
    placement.generated = GeneratedContent::makePreset(*generatedPreset);
    placement.sourceIn = kCMTimeZero;
    placement.sourceOut = defaultStillDuration();
    const SequenceId sequenceId = [self sequenceId];
    const GeneratorKind kind = generatorKindOf(*generatedPreset);
    const char *name = undoNameOf(*generatedPreset);
    if (!insert) {
        auto command = std::make_unique<OverwriteClip>(sequenceId, time, std::vector<ClipPlacement>{placement}, false);
        OverwriteClip *raw = command.get();
        return [self push:[self withGeneratorAsset:kind placement:std::move(command) name:name]
                  created:^NSArray<NSNumber *> * {
                      return toNumbers(raw->createdClipIds());
                  }];
    }
    __block InsertClip *raw = nullptr;
    __weak VEEngine *weakSelf = self;
    return [self pushRipple:^std::unique_ptr<Command>(RippleScope scope) {
        InsertOptions options;
        options.linkPair = false;
        options.ripple = scope;
        auto command = std::make_unique<InsertClip>(sequenceId, time, std::vector<ClipPlacement>{placement}, options);
        raw = command.get();
        VEEngine *strongSelf = weakSelf;
        return strongSelf != nil ? [strongSelf withGeneratorAsset:kind placement:std::move(command) name:name]
                                 : std::unique_ptr<Command>(std::move(command));
    }
                    created:^NSArray<NSNumber *> * {
                        return raw != nullptr ? toNumbers(raw->createdClipIds()) : @[];
                    }];
}

// MARK: - Content

- (VEEditResult *)pushTitleChange:(TitleChange)change clips:(NSArray<NSNumber *> *)clipIDs name:(std::string)name {
    std::vector<ClipId> clips = clipIdsOf(clipIDs);
    if (clips.empty()) {
        return [VEEditResult failureWithMessage:@"Nothing selected."];
    }
    return [self push:std::make_unique<SetGeneratedContent>([self sequenceId], std::move(clips), std::move(change),
                                                            std::move(name))
              created:nil];
}

/// A title parameter of `parameter` set to `value`, refused for a parameter outside the enum or of another type.
- (VEEditResult *)setTitleValue:(TitleValue)value
                   forParameter:(VETitleParameter)parameter
                           type:(TitleValueType)type
                          clips:(NSArray<NSNumber *> *)clipIDs {
    const auto titleParameter = fromVE(parameter);
    if (!titleParameter || infoOf(*titleParameter).type != type) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                     message:@"That parameter does not take this kind of value."];
    }
    return [self pushTitleChange:TitleChange::of(*titleParameter, std::move(value)) clips:clipIDs name:{}];
}

- (VEEditResult *)setTitleText:(NSString *)text clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    return [self setTitleValue:toStd(text) forParameter:VETitleParameterText type:TitleValueType::Text clips:clipIDs];
}

- (VEEditResult *)setTitleNumber:(double)value forParameter:(VETitleParameter)parameter clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    return [self setTitleValue:value forParameter:parameter type:TitleValueType::Number clips:clipIDs];
}

- (VEEditResult *)setTitleColour:(VEColour)colour forParameter:(VETitleParameter)parameter clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    return [self setTitleValue:fromVE(colour) forParameter:parameter type:TitleValueType::Colour clips:clipIDs];
}

- (VEEditResult *)setTitleToggle:(BOOL)on forParameter:(VETitleParameter)parameter clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    return [self setTitleValue:on == YES forParameter:parameter type:TitleValueType::Toggle clips:clipIDs];
}

- (VEEditResult *)setTitleAlignment:(VETitleAlignment)alignment clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    const auto titleAlignment = fromVE(alignment);
    if (!titleAlignment) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"Unknown alignment."];
    }
    return [self setTitleValue:*titleAlignment forParameter:VETitleParameterAlignment type:TitleValueType::Choice clips:clipIDs];
}

- (VEEditResult *)setTitleFont:(VETitleFont *)font clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    const auto titleFont = fromVE(font);
    if (!titleFont) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"That is not a font a title can use."];
    }
    return [self setTitleValue:*titleFont forParameter:VETitleParameterFont type:TitleValueType::Font clips:clipIDs];
}

- (VEEditResult *)setTitlePositionX:(double)x y:(double)y width:(double)width clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    TitleChange change;
    change[TitleParameter::PositionX] = x;
    change[TitleParameter::PositionY] = y;
    if (!std::isnan(width)) {
        change[TitleParameter::BoxWidth] = width;
    }
    return [self pushTitleChange:std::move(change) clips:clipIDs name:std::isnan(width) ? "Move Title" : "Resize Title"];
}

- (VEEditResult *)setMatteColour:(VEColour)colour clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    return [self pushTitleChange:TitleChange::matte(fromVE(colour)) clips:clipIDs name:{}];
}

// MARK: - Questions

- (VETitleSelection *)titleOfClips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    return makeTitleSelection(summarizeTitles(sequence, clipIdsOf(clipIDs)), sequence);
}

- (CGSize)titleBlockSizeOfClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const Clip *clip = sequence.findClip(toClipId(clipID));
    if (clip == nullptr || !clip->generated || !clip->generated->isTitle()) {
        return CGSizeZero;
    }
    auto &measured = measuredTitleBlocks();
    const auto key = std::make_pair(clip->generated->contentId(), std::make_pair(sequence.width, sequence.height));
    if (const auto found = measured.find(key); found != measured.end()) {
        return found->second;
    }
    const media::TitleBlockSize block =
        media::measureTitleBlock(clip->generated->title(), double(sequence.width), double(sequence.height));
    const CGSize size = CGSizeMake(block.width, block.height);
    if (measured.size() > 512) {
        measured.clear();
    }
    measured.emplace(key, size);
    return size;
}

/// The title fonts of `sequences` this Mac does not have, with how many title clips use each, in the order first
/// met.
- (std::vector<std::pair<TitleFont, NSInteger>>)missingFontsIn:(const std::vector<const Sequence *> &)sequences {
    std::vector<std::pair<TitleFont, NSInteger>> missing;
    for (const Sequence *sequence : sequences) {
        for (const Track &track : sequence->videoTracks) {
            for (const Clip &clip : track.clips) {
                if (!clip.generated || !clip.generated->isTitle()) {
                    continue;
                }
                const TitleFont &font = clip.generated->title().font;
                if (isTitleFontAvailableCached(font)) {
                    continue;
                }
                auto found = std::find_if(missing.begin(), missing.end(),
                                          [&](const auto &entry) { return entry.first == font; });
                if (found == missing.end()) {
                    missing.emplace_back(font, 1);
                } else {
                    ++found->second;
                }
            }
        }
    }
    return missing;
}

- (NSArray<VEMissingTitleFont *> *)missingTitleFonts {
    VE_ASSERT_MAIN();
    NSMutableArray<VEMissingTitleFont *> *fonts = [NSMutableArray array];
    for (const auto &[font, count] : [self missingFontsIn:{&[self activeSequence]}]) {
        [fonts addObject:makeMissingTitleFont(font, count)];
    }
    return fonts;
}

@end

@implementation VEEngine (TitlesInternal)

- (NSArray<NSString *> *)missingTitleFontWarnings {
    std::vector<const Sequence *> sequences;
    for (const Sequence &sequence : _project.sequences) {
        sequences.push_back(&sequence);
    }
    NSMutableArray<NSString *> *warnings = [NSMutableArray array];
    for (const auto &[font, count] : [self missingFontsIn:sequences]) {
        [warnings addObject:[NSString stringWithFormat:@"The font “%@” is not on this Mac: %ld %@ it and %@ shown in the "
                                                       @"system font until it is installed.",
                                                       toNS(font.displayName()), long(count),
                                                       count == 1 ? @"title uses" : @"titles use",
                                                       count == 1 ? @"is" : @"are"]];
    }
    return warnings;
}

- (void)titleFontsChanged {
    VE_ASSERT_MAIN();
    forgetTitleFontAvailability();
    measuredTitleBlocks().clear();
    // Titles drawn in a fallback (or in a font now gone) are drawn again: their pictures are dropped from the frame
    // cache and both monitors' decode pools forget the renders they keep.
    // (Only the program monitor shows titles: the source monitor shows media.)
    if (const MediaAsset *titles = _project.findGeneratorAsset(GeneratorKind::Title)) {
        _services.frameCache->purge(titles->id);
        [_programMonitor invalidateGeneratedAsset:titles->id];
        [self publishPlaybackSnapshot];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:VEEngineTitleFontsDidChangeNotification object:self];
}

- (void)startObservingTitleFonts {
    __weak VEEngine *weakSelf = self;
    void (^changed)(NSNotification *) = ^(NSNotification *) {
      [weakSelf titleFontsChanged];
    };
    // Core Text's registry (fonts activated or deactivated, by Font Book or an app) and AppKit's font set.
    _fontObservers = @[
        [NSNotificationCenter.defaultCenter addObserverForName:(__bridge NSString *)kCTFontManagerRegisteredFontsChangedNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:changed],
        [NSNotificationCenter.defaultCenter addObserverForName:NSFontSetChangedNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:changed],
    ];
}

- (void)stopObservingTitleFonts {
    for (id observer in _fontObservers) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
    }
    _fontObservers = @[];
}

@end
