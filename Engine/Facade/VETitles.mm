#import "VETitles+Internal.h"

#import "VEFacadeSupport+Internal.h"
#import "VETypes+Internal.h"

#include "../Media/TitleRenderer.h"

#include <cmath>
#include <limits>
#include <map>
#include <string>

using namespace ve;
using namespace ve::facade;

// MARK: - Class extensions (writable for the factories below)

@interface VETitleParameterInfo ()
@property (nonatomic, readwrite) VETitleParameter parameter;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite, copy) NSString *displayName;
@property (nonatomic, readwrite) VETitleValueType type;
@property (nonatomic, readwrite) VETitleUnit unit;
@property (nonatomic, readwrite) double defaultValue;
@property (nonatomic, readwrite) double minimum;
@property (nonatomic, readwrite) double maximum;
- (instancetype)initInternal;
@end

@interface VETitleFont () {
  @public
    TitleFont _font;
}
- (instancetype)initWithFont:(TitleFont)font;
@end

@interface VETitleInfo () {
  @public
    TitleContent _content;
}
@property (nonatomic, readwrite) VETitleFont *font;
- (instancetype)initWithContent:(TitleContent)content;
@end

@interface VETitleSelection () {
    std::array<bool, kTitleParameterCount> _mixed;
}
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *titleClipIDs;
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *matteClipIDs;
@property (nonatomic, readwrite, nullable) VETitleInfo *firstTitle;
@property (nonatomic, readwrite) VEColour matteColour;
@property (nonatomic, readwrite, getter=isMatteColourMixed) BOOL matteColourMixed;
- (instancetype)initWithMixed:(const std::array<bool, kTitleParameterCount> &)mixed;
@end

@interface VEMissingTitleFont ()
@property (nonatomic, readwrite) VETitleFont *font;
@property (nonatomic, readwrite) NSInteger clipCount;
- (instancetype)initInternal;
@end

// MARK: - Conversions

namespace ve::facade {

namespace {

VETitleValueType valueTypeToVE(TitleValueType type) {
    switch (type) {
    case TitleValueType::Text:
        return VETitleValueTypeText;
    case TitleValueType::Font:
        return VETitleValueTypeFont;
    case TitleValueType::Number:
        return VETitleValueTypeNumber;
    case TitleValueType::Colour:
        return VETitleValueTypeColour;
    case TitleValueType::Choice:
        return VETitleValueTypeChoice;
    case TitleValueType::Toggle:
        return VETitleValueTypeToggle;
    case TitleValueType::Anchor:
        return VETitleValueTypeAnchor;
    }
    return VETitleValueTypeNumber;
}

VETitleUnit unitToVE(TitleUnit unit) {
    switch (unit) {
    case TitleUnit::None:
        return VETitleUnitNone;
    case TitleUnit::FrameHeight:
        return VETitleUnitFrameHeight;
    case TitleUnit::FrameWidth:
        return VETitleUnitFrameWidth;
    case TitleUnit::Multiple:
        return VETitleUnitMultiple;
    case TitleUnit::ThousandthsEm:
        return VETitleUnitThousandthsEm;
    case TitleUnit::Degrees:
        return VETitleUnitDegrees;
    case TitleUnit::Fraction:
        return VETitleUnitFraction;
    }
    return VETitleUnitNone;
}

/// The availability of each font asked about, by its identity (system weight or PostScript name).
std::map<std::string, bool> &fontAvailability() {
    static std::map<std::string, bool> cache;
    return cache;
}

} // namespace

VEColour toVE(const SRGBColour &colour) {
    return VEColour{colour.red, colour.green, colour.blue};
}

SRGBColour fromVE(const VEColour &colour) {
    return SRGBColour{colour.red, colour.green, colour.blue};
}

static_assert(static_cast<std::size_t>(VETitleParameterAnchor) + 1 == kTitleParameterCount &&
                  static_cast<std::size_t>(TitleParameter::Anchor) + 1 == kTitleParameterCount,
              "VETitleParameter mirrors TitleParameter, in order");

VETitleParameter toVE(TitleParameter parameter) {
    return static_cast<VETitleParameter>(static_cast<NSInteger>(parameter));
}

std::optional<TitleParameter> fromVE(VETitleParameter parameter) {
    const auto index = static_cast<NSInteger>(parameter);
    if (index < 0 || index >= NSInteger(kTitleParameterCount)) {
        return std::nullopt;
    }
    return kTitleParameters[std::size_t(index)];
}

VETitleAlignment toVE(TitleAlignment alignment) {
    switch (alignment) {
    case TitleAlignment::Left:
        return VETitleAlignmentLeft;
    case TitleAlignment::Centre:
        return VETitleAlignmentCentre;
    case TitleAlignment::Right:
        return VETitleAlignmentRight;
    }
    return VETitleAlignmentCentre;
}

std::optional<TitleAlignment> fromVE(VETitleAlignment alignment) {
    switch (alignment) {
    case VETitleAlignmentLeft:
        return TitleAlignment::Left;
    case VETitleAlignmentCentre:
        return TitleAlignment::Centre;
    case VETitleAlignmentRight:
        return TitleAlignment::Right;
    }
    return std::nullopt;
}

VETitleAnchor toVE(TitleAnchor anchor) {
    switch (anchor) {
    case TitleAnchor::Top:
        return VETitleAnchorTop;
    case TitleAnchor::Centre:
        return VETitleAnchorCentre;
    case TitleAnchor::Bottom:
        return VETitleAnchorBottom;
    }
    return VETitleAnchorCentre;
}

std::optional<TitleAnchor> fromVE(VETitleAnchor anchor) {
    switch (anchor) {
    case VETitleAnchorTop:
        return TitleAnchor::Top;
    case VETitleAnchorCentre:
        return TitleAnchor::Centre;
    case VETitleAnchorBottom:
        return TitleAnchor::Bottom;
    }
    return std::nullopt;
}

VEGeneratorKind toVE(GeneratorKind kind) {
    switch (kind) {
    case GeneratorKind::None:
        return VEGeneratorKindNone;
    case GeneratorKind::Title:
        return VEGeneratorKindTitle;
    case GeneratorKind::ColourMatte:
        return VEGeneratorKindColourMatte;
    }
    return VEGeneratorKindNone;
}

std::optional<GeneratedPreset> fromVE(VEGeneratedPreset preset) {
    switch (preset) {
    case VEGeneratedPresetTitle:
        return GeneratedPreset::Title;
    case VEGeneratedPresetLowerThird:
        return GeneratedPreset::LowerThird;
    case VEGeneratedPresetColourMatte:
        return GeneratedPreset::ColourMatte;
    }
    return std::nullopt;
}

VETitleFont *makeTitleFont(const TitleFont &font) {
    return [[VETitleFont alloc] initWithFont:font];
}

std::optional<TitleFont> fromVE(VETitleFont *font) {
    if (font == nil || titleValueProblem(TitleParameter::Font, font->_font)) {
        return std::nullopt;
    }
    return font->_font;
}

VETitleInfo *makeTitleInfo(const TitleContent &content) {
    return [[VETitleInfo alloc] initWithContent:content];
}

VETitleSelection *makeTitleSelection(const TitleSummary &summary, const Sequence &sequence) {
    VETitleSelection *selection = [[VETitleSelection alloc] initWithMixed:summary.mixed];
    auto numbers = [](const std::vector<ClipId> &ids) {
        NSMutableArray<NSNumber *> *list = [NSMutableArray arrayWithCapacity:ids.size()];
        for (const ClipId id : ids) {
            [list addObject:@(static_cast<int64_t>(id.value()))];
        }
        return list;
    };
    selection.titleClipIDs = numbers(summary.titles);
    selection.matteClipIDs = numbers(summary.mattes);
    if (!summary.titles.empty()) {
        const Clip *first = sequence.findClip(summary.titles.front());
        selection.firstTitle = first != nullptr && first->generated ? makeTitleInfo(first->generated->title()) : nil;
    }
    if (!summary.mattes.empty()) {
        const Clip *first = sequence.findClip(summary.mattes.front());
        selection.matteColour = first != nullptr && first->generated ? toVE(first->generated->matteColour()) : VEColour{};
    }
    selection.matteColourMixed = summary.matteColourMixed;
    return selection;
}

VEMissingTitleFont *makeMissingTitleFont(const TitleFont &font, NSInteger clipCount) {
    VEMissingTitleFont *missing = [[VEMissingTitleFont alloc] initInternal];
    missing.font = makeTitleFont(font);
    missing.clipCount = clipCount;
    return missing;
}

bool isTitleFontAvailableCached(const TitleFont &font) {
    if (font.isSystem) {
        return true;
    }
    auto &cache = fontAvailability();
    const auto found = cache.find(font.postScriptName);
    if (found != cache.end()) {
        return found->second;
    }
    const bool available = media::isTitleFontAvailable(font);
    cache.emplace(font.postScriptName, available);
    return available;
}

void forgetTitleFontAvailability() {
    fontAvailability().clear();
}

} // namespace ve::facade

// MARK: - Implementations

@implementation VETitleParameterInfo
- (instancetype)initInternal {
    return [super init];
}
+ (NSArray<VETitleParameterInfo *> *)allParameters {
    NSMutableArray<VETitleParameterInfo *> *rows = [NSMutableArray arrayWithCapacity:kTitleParameterCount];
    for (const TitleParameter parameter : kTitleParameters) {
        [rows addObject:[self infoForParameter:ve::facade::toVE(parameter)]];
    }
    return rows;
}
+ (VETitleParameterInfo *)infoForParameter:(VETitleParameter)parameter {
    const TitleParameterInfo &row = infoOf(ve::facade::fromVE(parameter).value_or(TitleParameter::Text));
    VETitleParameterInfo *info = [[VETitleParameterInfo alloc] initInternal];
    info.parameter = ve::facade::toVE(row.parameter);
    info.name = @(row.name);
    info.displayName = @(row.displayName);
    info.type = ve::facade::valueTypeToVE(row.type);
    info.unit = ve::facade::unitToVE(row.unit);
    info.defaultValue = row.defaultValue;
    info.minimum = row.minimum;
    info.maximum = row.maximum;
    return info;
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<VETitleParameterInfo %@ %g in [%g, %g]>", self.name, self.defaultValue,
                                      self.minimum, self.maximum];
}
@end

@implementation VETitleFont
- (instancetype)initWithFont:(TitleFont)font {
    if ((self = [super init])) {
        _font = std::move(font);
    }
    return self;
}
+ (instancetype)systemFontWithWeight:(VESystemFontWeight)weight {
    const auto index = static_cast<NSInteger>(weight);
    const SystemFontWeight systemWeight = index >= 0 && index < NSInteger(kSystemFontWeights.size())
                                              ? kSystemFontWeights[std::size_t(index)]
                                              : SystemFontWeight::Regular;
    return [[self alloc] initWithFont:TitleFont::system(systemWeight)];
}
+ (instancetype)fontWithPostScriptName:(NSString *)postScriptName family:(NSString *)family style:(NSString *)style {
    return [[self alloc] initWithFont:TitleFont::named(toStd(postScriptName), toStd(family), toStd(style))];
}
- (id)copyWithZone:(NSZone *)zone {
    (void)zone;
    return self; // immutable
}
- (BOOL)isSystem {
    return _font.isSystem;
}
- (VESystemFontWeight)weight {
    return _font.isSystem ? static_cast<VESystemFontWeight>(static_cast<NSInteger>(_font.weight))
                          : VESystemFontWeightRegular;
}
- (NSString *)postScriptName {
    return toNS(_font.postScriptName);
}
- (NSString *)family {
    return toNS(_font.family);
}
- (NSString *)style {
    return toNS(_font.style);
}
- (NSString *)displayName {
    return toNS(_font.displayName());
}
- (BOOL)isAvailable {
    return isTitleFontAvailableCached(_font);
}
- (BOOL)isEqual:(id)object {
    if (![object isKindOfClass:VETitleFont.class]) {
        return NO;
    }
    return _font == static_cast<VETitleFont *>(object)->_font;
}
- (NSUInteger)hash {
    return std::hash<std::string>{}(_font.isSystem ? std::string("system:") + nameOf(_font.weight) : _font.postScriptName);
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<VETitleFont %@>", self.displayName];
}
@end

@implementation VETitleInfo
- (instancetype)initWithContent:(TitleContent)content {
    if ((self = [super init])) {
        _content = std::move(content);
        _font = makeTitleFont(_content.font);
    }
    return self;
}
- (NSString *)text {
    return toNS(_content.text);
}
- (double)size {
    return _content.size;
}
- (VEColour)fillColour {
    return ve::facade::toVE(_content.fillColour);
}
- (VETitleAlignment)alignment {
    return ve::facade::toVE(_content.alignment);
}
- (double)lineSpacing {
    return _content.lineSpacing;
}
- (double)tracking {
    return _content.tracking;
}
- (BOOL)outline {
    return _content.outline;
}
- (VEColour)outlineColour {
    return ve::facade::toVE(_content.outlineColour);
}
- (double)outlineWidth {
    return _content.outlineWidth;
}
- (BOOL)shadow {
    return _content.shadow;
}
- (VEColour)shadowColour {
    return ve::facade::toVE(_content.shadowColour);
}
- (double)shadowOpacity {
    return _content.shadowOpacity;
}
- (double)shadowAngle {
    return _content.shadowAngle;
}
- (double)shadowDistance {
    return _content.shadowDistance;
}
- (double)shadowBlur {
    return _content.shadowBlur;
}
- (BOOL)box {
    return _content.box;
}
- (VEColour)boxColour {
    return ve::facade::toVE(_content.boxColour);
}
- (double)boxOpacity {
    return _content.boxOpacity;
}
- (double)boxPadding {
    return _content.boxPadding;
}
- (double)boxCornerRadius {
    return _content.boxCornerRadius;
}
- (double)x {
    return _content.x;
}
- (double)y {
    return _content.y;
}
- (double)width {
    return _content.width;
}
- (BOOL)pointText {
    return _content.pointText;
}
- (VETitleAnchor)anchor {
    return ve::facade::toVE(_content.anchor);
}
- (NSString *)displayName {
    return toNS(titleDisplayName(_content));
}
- (double)numberForParameter:(VETitleParameter)parameter {
    const auto titleParameter = ve::facade::fromVE(parameter);
    if (!titleParameter) {
        return std::numeric_limits<double>::quiet_NaN();
    }
    const TitleValue value = valueOf(_content, *titleParameter);
    const double *number = std::get_if<double>(&value);
    return number != nullptr ? *number : std::numeric_limits<double>::quiet_NaN();
}
- (VEColour)colourForParameter:(VETitleParameter)parameter {
    const auto titleParameter = ve::facade::fromVE(parameter);
    if (!titleParameter) {
        return VEColour{};
    }
    const TitleValue value = valueOf(_content, *titleParameter);
    const SRGBColour *colour = std::get_if<SRGBColour>(&value);
    return colour != nullptr ? ve::facade::toVE(*colour) : VEColour{};
}
- (BOOL)toggleForParameter:(VETitleParameter)parameter {
    const auto titleParameter = ve::facade::fromVE(parameter);
    if (!titleParameter) {
        return NO;
    }
    const TitleValue value = valueOf(_content, *titleParameter);
    const bool *toggle = std::get_if<bool>(&value);
    return toggle != nullptr && *toggle;
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<VETitleInfo “%@”>", self.displayName];
}
@end

@implementation VETitleSelection
- (instancetype)initWithMixed:(const std::array<bool, kTitleParameterCount> &)mixed {
    if ((self = [super init])) {
        _mixed = mixed;
        _titleClipIDs = @[];
        _matteClipIDs = @[];
    }
    return self;
}
- (BOOL)isMixed:(VETitleParameter)parameter {
    const auto titleParameter = ve::facade::fromVE(parameter);
    return titleParameter && _mixed[static_cast<std::size_t>(*titleParameter)];
}
@end

@implementation VEMissingTitleFont
- (instancetype)initInternal {
    return [super init];
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<VEMissingTitleFont %@, %ld clips>", self.font.displayName, long(self.clipCount)];
}
@end
