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
    case GeneratedPreset::TitleCard:
        return "Add Title Card";
    case GeneratedPreset::Caption:
        return "Add Caption";
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

/// Posted (main thread) after the Mac's fonts changed and media::advanceTitleFontGeneration advanced the titles'
/// keys: every engine then drops its titles' pictures and draws them again (titleFontsChanged).
NSNotificationName const kTitleFontGenerationDidAdvance = @"VEEngineTitleFontGenerationDidAdvance";

/// Watches the Mac's fonts for the whole process, once: Core Text's registry (fonts activated or removed, by Font
/// Book or an app) and AppKit's font set. One change posts both, often more than once: the burst is coalesced into
/// one advance of the font generation and one kTitleFontGenerationDidAdvance on the main queue's next turn, so every
/// title renders again once per change, whatever the number of engines.
void watchTitleFonts() {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      static bool pending = false; // main thread only
      void (^changed)(NSNotification *) = ^(NSNotification *) {
        if (pending) {
            return;
        }
        pending = true;
        dispatch_async(dispatch_get_main_queue(), ^{
          pending = false;
          media::advanceTitleFontGeneration();
          [NSNotificationCenter.defaultCenter postNotificationName:kTitleFontGenerationDidAdvance object:nil];
        });
      };
      [NSNotificationCenter.defaultCenter addObserverForName:(__bridge NSString *)kCTFontManagerRegisteredFontsChangedNotification
                                                      object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:changed];
      [NSNotificationCenter.defaultCenter addObserverForName:NSFontSetChangedNotification
                                                      object:nil
                                                       queue:NSOperationQueue.mainQueue
                                                  usingBlock:changed];
    });
}

/// Title blocks measured (titleBlockSizeOfClip:), per content and frame size: the box follows a drag without
/// measuring again. Forgotten when the Mac's fonts change (a block measured in a fallback font). Main thread only.
std::map<std::pair<ContentId, std::pair<int32_t, int32_t>>, CGRect> &measuredTitleBlocks() {
    static std::map<std::pair<ContentId, std::pair<int32_t, int32_t>>, CGRect> measured;
    return measured;
}

} // namespace

@implementation VEEngine (Titles)

// MARK: - Adding

/// `placement`, preceded by adding the project's generator assets of `kinds` it does not have yet, as one command named
/// `name`.
- (std::unique_ptr<Command>)withGeneratorAssets:(const std::vector<GeneratorKind> &)kinds
                                      placement:(std::unique_ptr<Command>)placement
                                           name:(const char *)name {
    std::vector<MediaAsset> missing;
    for (const GeneratorKind kind : kinds) {
        const bool listed = std::any_of(missing.begin(), missing.end(),
                                        [kind](const MediaAsset &asset) { return asset.generator == kind; });
        if (_project.findGeneratorAsset(kind) == nullptr && !listed) {
            missing.push_back(makeGeneratorAsset(kind));
        }
    }
    if (missing.empty()) {
        return placement;
    }
    std::vector<std::unique_ptr<Command>> children;
    children.push_back(std::make_unique<ImportAssets>(std::move(missing)));
    children.push_back(std::move(placement));
    return std::make_unique<CompositeCommand>(name, std::move(children));
}

/// The generator kinds of `contents`.
static std::vector<GeneratorKind> kindsOf(const std::vector<std::shared_ptr<const GeneratedContent>> &contents) {
    std::vector<GeneratorKind> kinds;
    for (const auto &content : contents) {
        kinds.push_back(content->kind());
    }
    return kinds;
}

/// `ids` from the top clip down (the clip to select first).
static NSArray<NSNumber *> *topFirst(const std::vector<ClipId> &ids) {
    NSMutableArray<NSNumber *> *numbers = [NSMutableArray arrayWithCapacity:ids.size()];
    for (auto id = ids.rbegin(); id != ids.rend(); ++id) {
        [numbers addObject:@(static_cast<int64_t>(id->value()))];
    }
    return numbers;
}

- (double)titleSafeFraction {
    VE_ASSERT_MAIN();
    return _titleSafeFraction;
}

- (void)setTitleSafeFraction:(double)fraction {
    VE_ASSERT_MAIN();
    if (std::isfinite(fraction) && fraction > 0.0 && fraction <= 1.0) {
        _titleSafeFraction = fraction;
    }
}

- (VEEditResult *)addGeneratedPreset:(VEGeneratedPreset)preset atTime:(CMTime)time aboveTrack:(VETrackID)videoTrackID {
    VE_ASSERT_MAIN();
    const auto generatedPreset = fromVE(preset);
    if (!generatedPreset) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"Unknown title preset."];
    }
    const char *name = undoNameOf(*generatedPreset);
    std::vector<std::shared_ptr<const GeneratedContent>> layers = presetLayers(*generatedPreset, _titleSafeFraction);
    const std::vector<GeneratorKind> kinds = kindsOf(layers);
    auto add = std::make_unique<AddGeneratedClip>([self sequenceId], time, toTrackId(videoTrackID), std::move(layers),
                                                  defaultStillDuration(), name);
    AddGeneratedClip *raw = add.get();
    return [self push:[self withGeneratorAssets:kinds placement:std::move(add) name:name]
              created:^NSArray<NSNumber *> * {
                  return topFirst(raw->createdClipIds());
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
    // The bottom layer goes where it was dropped; a title card's title above it by the placement rule.
    std::vector<std::shared_ptr<const GeneratedContent>> layers = presetLayers(*generatedPreset, _titleSafeFraction);
    const std::vector<GeneratorKind> kinds = kindsOf(layers);
    ClipPlacement placement;
    placement.trackId = track->id;
    placement.generated = layers.front();
    placement.sourceIn = kCMTimeZero;
    placement.sourceOut = defaultStillDuration();
    std::vector<std::shared_ptr<const GeneratedContent>> above(layers.begin() + 1, layers.end());
    const SequenceId sequenceId = [self sequenceId];
    const TrackId trackId = track->id;
    const char *name = undoNameOf(*generatedPreset);
    // The placement and, for a stack, the layers above it, as one command; `aboveRaw` is set to the second part.
    auto withLayersAbove = [sequenceId, trackId, time, above, name](std::unique_ptr<Command> placed,
                                                                   AddGeneratedClip **aboveRaw) -> std::unique_ptr<Command> {
        if (above.empty()) {
            return placed;
        }
        auto stack = std::make_unique<AddGeneratedClip>(sequenceId, time, trackId, above, defaultStillDuration(), name);
        *aboveRaw = stack.get();
        std::vector<std::unique_ptr<Command>> children;
        children.push_back(std::move(placed));
        children.push_back(std::move(stack));
        return std::make_unique<CompositeCommand>(name, std::move(children));
    };
    if (!insert) {
        auto command = std::make_unique<OverwriteClip>(sequenceId, time, std::vector<ClipPlacement>{placement}, false);
        OverwriteClip *raw = command.get();
        AddGeneratedClip *aboveRaw = nullptr;
        std::unique_ptr<Command> placed = withLayersAbove(std::move(command), &aboveRaw);
        return [self push:[self withGeneratorAssets:kinds placement:std::move(placed) name:name]
                  created:^NSArray<NSNumber *> * {
                      std::vector<ClipId> ids = raw->createdClipIds();
                      if (aboveRaw != nullptr) {
                          ids.insert(ids.end(), aboveRaw->createdClipIds().begin(), aboveRaw->createdClipIds().end());
                      }
                      return topFirst(ids);
                  }];
    }
    __block InsertClip *raw = nullptr;
    __block AddGeneratedClip *aboveRaw = nullptr;
    __weak VEEngine *weakSelf = self;
    return [self pushRipple:^std::unique_ptr<Command>(RippleScope scope) {
        InsertOptions options;
        options.linkPair = false;
        options.ripple = scope;
        auto command = std::make_unique<InsertClip>(sequenceId, time, std::vector<ClipPlacement>{placement}, options);
        raw = command.get();
        AddGeneratedClip *aboveTarget = nullptr;
        std::unique_ptr<Command> placed = withLayersAbove(std::move(command), &aboveTarget);
        aboveRaw = aboveTarget;
        VEEngine *strongSelf = weakSelf;
        return strongSelf != nil ? [strongSelf withGeneratorAssets:kinds placement:std::move(placed) name:name]
                                 : std::move(placed);
    }
                    created:^NSArray<NSNumber *> * {
                        std::vector<ClipId> ids = raw != nullptr ? raw->createdClipIds() : std::vector<ClipId>{};
                        if (aboveRaw != nullptr) {
                            ids.insert(ids.end(), aboveRaw->createdClipIds().begin(), aboveRaw->createdClipIds().end());
                        }
                        return topFirst(ids);
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
    if (parameter == VETitleParameterPointText) {
        return [self setTitlePointText:on clips:clipIDs];
    }
    return [self setTitleValue:on == YES forParameter:parameter type:TitleValueType::Toggle clips:clipIDs];
}

- (VEEditResult *)setTitleAlignment:(VETitleAlignment)alignment clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    const auto titleAlignment = fromVE(alignment);
    if (!titleAlignment) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"Unknown alignment."];
    }
    return [self pushTitleChangeKeepingPlace:TitleChange::of(TitleParameter::Alignment, *titleAlignment)
                                       clips:clipIDs
                                        name:{}];
}

- (VEEditResult *)setTitlePointText:(BOOL)pointText clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    return [self pushTitleChangeKeepingPlace:TitleChange::of(TitleParameter::PointText, pointText == YES)
                                       clips:clipIDs
                                        name:{}];
}

- (VEEditResult *)setTitleAnchor:(VETitleAnchor)anchor clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    const auto titleAnchor = fromVE(anchor);
    if (!titleAnchor) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"Unknown anchor."];
    }
    return [self pushTitleChangeKeepingPlace:TitleChange::of(TitleParameter::Anchor, *titleAnchor)
                                       clips:clipIDs
                                        name:{}];
}

/// `change` (of a parameter that says where the text block lies: point text, the anchor, the alignment) on the titles
/// of `clipIDs`, each title's position moved so its block stays where it was: horizontally the block's point at the
/// fraction its lines align to (its left edge, centre or right edge), vertically the point at its anchor's fraction
/// (top, centre, bottom). An alignment change of point text, or an anchor change, leaves the block exactly where it
/// is; point text turned on or off keeps the edge (or centre) its lines align to and the side it is anchored at.
/// Clips that are not titles are passed on as they are (the edit refuses them).
- (VEEditResult *)pushTitleChangeKeepingPlace:(TitleChange)change clips:(NSArray<NSNumber *> *)clipIDs name:(std::string)name {
    std::vector<ClipId> clips = clipIdsOf(clipIDs);
    if (clips.empty()) {
        return [VEEditResult failureWithMessage:@"Nothing selected."];
    }
    const Sequence &sequence = [self activeSequence];
    const double width = double(sequence.width);
    const double height = double(sequence.height);
    const TitleParameterInfo &xInfo = infoOf(TitleParameter::PositionX);
    const TitleParameterInfo &yInfo = infoOf(TitleParameter::PositionY);
    std::vector<std::pair<ClipId, TitleChange>> changes;
    for (const ClipId id : clips) {
        TitleChange own = change;
        const Clip *clip = sequence.findClip(id);
        const bool valid = std::none_of(kTitleParameters.begin(), kTitleParameters.end(), [&](TitleParameter parameter) {
            return change[parameter] && titleValueProblem(parameter, *change[parameter]);
        });
        if (clip != nullptr && clip->generated && clip->generated->isTitle() && valid && width > 0 && height > 0) {
            const TitleContent &before = clip->generated->title();
            const TitleContent after = change.appliedTo(before);
            const media::TitleBlockSize b = media::measureTitleBlock(before, width, height);
            const media::TitleBlockSize a = media::measureTitleBlock(after, width, height);
            const double flush = after.alignment == TitleAlignment::Left    ? 0.0
                                 : after.alignment == TitleAlignment::Right ? 1.0
                                                                            : 0.5;
            const double anchor = after.anchor == TitleAnchor::Top ? 0.0 : after.anchor == TitleAnchor::Bottom ? 1.0 : 0.5;
            const double left = before.x * width + b.left + flush * (b.width - a.width);
            const double top = before.y * height + b.top + anchor * (b.height - a.height);
            const double x = std::clamp((left - a.left) / width, xInfo.minimum, xInfo.maximum);
            const double y = std::clamp((top - a.top) / height, yInfo.minimum, yInfo.maximum);
            if (std::abs(x - before.x) > 1e-12) {
                own[TitleParameter::PositionX] = x;
            }
            if (std::abs(y - before.y) > 1e-12) {
                own[TitleParameter::PositionY] = y;
            }
        }
        changes.emplace_back(id, std::move(own));
    }
    if (name.empty()) {
        // Named after the parameter asked for, not the position the edit moves with it.
        name = [&] {
            for (const TitleParameter parameter : kTitleParameters) {
                if (change[parameter]) {
                    return std::string("Change ") + displayNameOf(parameter);
                }
            }
            return std::string("Change Title");
        }();
    }
    return [self push:std::make_unique<SetGeneratedContent>([self sequenceId], std::move(changes), std::move(name))
              created:nil];
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

// MARK: - Copy Style, Paste Style

- (BOOL)copyTitleStyleOfClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    const Clip *clip = [self activeSequence].findClip(toClipId(clipID));
    if (clip == nullptr || !clip->generated || !clip->generated->isTitle()) {
        return NO;
    }
    _copiedTitleStyle = clip->generated->title();
    return YES;
}

- (BOOL)hasCopiedTitleStyle {
    VE_ASSERT_MAIN();
    return _copiedTitleStyle.has_value();
}

- (VEEditResult *)pasteTitleStyleOntoClips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    if (!_copiedTitleStyle) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"No title style has been copied."];
    }
    // Kept in place: the style's alignment says where point text's x is on its block, so each title's position moves
    // with it and its text stays where it is drawn.
    return [self pushTitleChangeKeepingPlace:TitleChange::style(*_copiedTitleStyle) clips:clipIDs name:"Paste Style"];
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

- (CGRect)titleBlockOfClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const Clip *clip = sequence.findClip(toClipId(clipID));
    if (clip == nullptr || !clip->generated || !clip->generated->isTitle()) {
        return CGRectNull;
    }
    const CGRect block = [self measuredTitleBlock:*clip->generated sequence:sequence];
    const TitleContent &title = clip->generated->title();
    return CGRectOffset(block, title.x * double(sequence.width), title.y * double(sequence.height));
}

- (nullable VETitleTextLayout *)titleTextLayoutOfClip:(VEClipID)clipID atTime:(CMTime)time {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const Clip *clip = sequence.findClip(toClipId(clipID));
    if (clip == nullptr || !clip->generated || !clip->generated->isTitle() || sequence.width <= 0 || sequence.height <= 0) {
        return nil;
    }
    const TitleContent &title = clip->generated->title();
    const double width = double(sequence.width);
    const double height = double(sequence.height);
    return makeTitleTextLayout(media::TitleTextLayout::make(title, width, height), toNS(title.text),
                               CGPointMake(title.x * width, title.y * height),
                               canvasToFrameTransform(motionValuesAt(*clip, time), width, height));
}

/// The block of `content` relative to its position (measureTitleBlock), remembered per content and frame size.
- (CGRect)measuredTitleBlock:(const GeneratedContent &)content sequence:(const Sequence &)sequence {
    auto &measured = measuredTitleBlocks();
    const auto key = std::make_pair(content.contentId(), std::make_pair(sequence.width, sequence.height));
    if (const auto found = measured.find(key); found != measured.end()) {
        return found->second;
    }
    const media::TitleBlockSize block =
        media::measureTitleBlock(content.title(), double(sequence.width), double(sequence.height));
    const CGRect rect = CGRectMake(block.left, block.top, block.width, block.height);
    if (measured.size() > 512) {
        measured.clear();
    }
    measured.emplace(key, rect);
    return rect;
}

- (CGSize)titleBlockSizeOfClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const Clip *clip = sequence.findClip(toClipId(clipID));
    if (clip == nullptr || !clip->generated || !clip->generated->isTitle()) {
        return CGSizeZero;
    }
    return [self measuredTitleBlock:*clip->generated sequence:sequence].size;
}

/// The title fonts of `sequences` this Mac does not have, with how many title clips use each, in the order first
/// met.
- (std::vector<std::pair<TitleFont, NSInteger>>)missingFontsIn:(const std::vector<const Sequence *> &)sequences {
    std::vector<std::pair<TitleFont, NSInteger>> missing;
    for (const Sequence *sequence : sequences) {
        for (const Track &track : sequence->videoTracks) {
            if (track.muted) {
                continue; // a hidden track is not shown or exported
            }
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
    // Titles drawn in a fallback (or in a font now gone) are drawn again. The font generation was advanced before
    // this (watchTitleFonts), so every title's key is new: a picture a worker finishes with the old fonts after this
    // point is stored under the old key, which nothing asks for. The program monitor's pool first retires its title
    // streams (so no worker goes on rendering for them), then the frame cache drops the old pictures (memory), then
    // the monitors ask for the new keys. (Only the program monitor shows titles; a running export keeps the
    // generation it started with and says the fonts changed, ExportSummary::titleFontsChanged.)
    if (const MediaAsset *titles = _project.findGeneratorAsset(GeneratorKind::Title)) {
        [_programMonitor invalidateGeneratedAsset:titles->id];
        _services.frameCache->purge(titles->id);
        [self publishPlaybackSnapshot];
    }
    [NSNotificationCenter.defaultCenter postNotificationName:VEEngineTitleFontsDidChangeNotification object:self];
}

- (void)startObservingTitleFonts {
    watchTitleFonts();
    __weak VEEngine *weakSelf = self;
    _fontObservers = @[ [NSNotificationCenter.defaultCenter addObserverForName:kTitleFontGenerationDidAdvance
                                                                        object:nil
                                                                         queue:NSOperationQueue.mainQueue
                                                                    usingBlock:^(NSNotification *) {
                                                                      [weakSelf titleFontsChanged];
                                                                    }] ];
}

- (void)stopObservingTitleFonts {
    for (id observer in _fontObservers) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
    }
    _fontObservers = @[];
}

@end
