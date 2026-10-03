// What a generated clip shows: a title (styled text) or a colour matte (a solid colour), the content of a
// clip of its own on a video track (docs/plans/2026-10-02-titles-design.md, sections 1, 6 and 8).
//
// The model:
//   - A title clip or a matte clip refers to the project's hidden generator asset of its kind
//     (MediaAsset::generator: one "Title" and one "Colour Matte" asset per project, a still without a
//     file), so the rule "a clip has an asset" holds unchanged, and every rule about stills applies: any
//     length, speed 1, sourceIn 0, never reversed.
//   - The clip keeps its own content (Clip::generated): a split gives two independent titles, and a clip
//     copy copies its content. The content is shared and immutable (std::shared_ptr<const
//     GeneratedContent>), like the project's LUTs, so copying a frame's model or an undo snapshot copies
//     no strings and a render graph's layer can point at it without allocating. Equality compares
//     contents.
//   - Title and matte clips are allowed only on video tracks, have no grade (section 5), and may have
//     Motion, Opacity spans, fades and transitions like any clip.
//
// A title's parameters are rows of the TitleParameterInfo table (name, display name, type, unit, default
// and range), in the descriptor style of GradeParameterInfo: the file, the validation, the facade and the
// inspector read the same table. Positions are fractions of the frame's width and height; sizes (font
// size, outline width, shadow distance and blur, padding, corner radius) fractions of its height, so a
// title looks the same after the sequence changes from 1080p to 4K. Colours are sRGB components in [0, 1]
// (drawn into an sRGB context unchanged and composited as stills are; white is exactly video white).
//
// The content id (contentIdOf) is a 128-bit FNV-1a hash of the canonical form of everything that changes
// the pixels: for a title its text, font, size, colours, alignment, spacing, outline, shadow, box, box width,
// point text and vertical anchor (these two place the picture relative to the position), not its position (a drag that moves the box renders nothing new); for a matte its colour. It is
// computed once, when the content is made. With the raster scale it is the picture's cache identity
// (GeneratedKey, Engine/Media/GeneratedSource.h).
//
// Plain C++: unit-testable without Core Text, Metal or media.

#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <variant>

namespace ve {

// What a generator asset generates (MediaAsset::generator); None for an asset that is a file.
enum class GeneratorKind {
    None,
    Title,
    ColourMatte,
};

// "none", "title", "colourMatte" (the project file's names).
const char *nameOf(GeneratorKind kind);
// "Media", "Title", "Colour Matte" (the asset's name and messages).
const char *displayNameOf(GeneratorKind kind);
// The kind named `name` (nameOf), or nullopt.
std::optional<GeneratorKind> generatorKindNamed(std::string_view name);

// A colour as sRGB components in [0, 1] (the colour picker's colour converted to sRGB).
struct SRGBColour {
    double red = 0.0;
    double green = 0.0;
    double blue = 0.0;

    friend bool operator==(const SRGBColour &, const SRGBColour &) = default;
};

// Whether every component is finite and within [0, 1].
bool isValidColour(const SRGBColour &colour);

inline constexpr SRGBColour kWhite{1.0, 1.0, 1.0};
inline constexpr SRGBColour kBlack{0.0, 0.0, 0.0};

// How the lines of a title align inside its box.
enum class TitleAlignment {
    Left,
    Centre,
    Right,
};

// "left", "centre", "right".
const char *nameOf(TitleAlignment alignment);
std::optional<TitleAlignment> titleAlignmentNamed(std::string_view name);

// Where a title's position (TitleContent::y) lies on its text block, and so which way the block grows when
// lines are added (schema 11, titles slice 2): the block's top (it grows down), its centre (it grows both ways,
// the slice 1 behaviour) or its bottom (it grows up).
enum class TitleAnchor {
    Top,
    Centre,
    Bottom,
};

// "top", "centre", "bottom".
const char *nameOf(TitleAnchor anchor);
std::optional<TitleAnchor> titleAnchorNamed(std::string_view name);

// The weights of the system font, which a title names by weight, never by the private PostScript name the
// system gives it (".SFNS-Semibold"), which changes between macOS versions.
enum class SystemFontWeight {
    UltraLight,
    Thin,
    Light,
    Regular,
    Medium,
    Semibold,
    Bold,
    Heavy,
    Black,
};

inline constexpr std::array<SystemFontWeight, 9> kSystemFontWeights{
    SystemFontWeight::UltraLight, SystemFontWeight::Thin,     SystemFontWeight::Light,
    SystemFontWeight::Regular,    SystemFontWeight::Medium,   SystemFontWeight::Semibold,
    SystemFontWeight::Bold,       SystemFontWeight::Heavy,    SystemFontWeight::Black};

// "ultraLight", "thin", ..., "black" (the file's names).
const char *nameOf(SystemFontWeight weight);
// "Ultralight", "Thin", ..., "Black" (the style popup's names, as Font Book names them).
const char *displayNameOf(SystemFontWeight weight);
std::optional<SystemFontWeight> systemFontWeightNamed(std::string_view name);

// A title's font: the system font at a weight, or an installed font by PostScript name with the family and
// style names it was chosen as (for display, and for the message when the font is missing on this Mac: the
// name is kept unchanged, so installing the font brings the title back exactly).
struct TitleFont {
    bool isSystem = true;
    SystemFontWeight weight = SystemFontWeight::Semibold; // the system font's weight
    std::string postScriptName;                          // an installed font ("Helvetica-Bold"); empty for the system font
    std::string family;                                  // "Helvetica" (empty for the system font)
    std::string style;                                   // "Bold" (empty for the system font)

    static TitleFont system(SystemFontWeight weight) {
        TitleFont font;
        font.weight = weight;
        return font;
    }
    static TitleFont named(std::string postScriptName, std::string family, std::string style) {
        TitleFont font;
        font.isSystem = false;
        font.postScriptName = std::move(postScriptName);
        font.family = std::move(family);
        font.style = std::move(style);
        return font;
    }
    // "System Semibold", or the family and style ("Helvetica Bold"; the PostScript name when they are empty).
    std::string displayName() const;

    friend bool operator==(const TitleFont &, const TitleFont &) = default;
};

// The parameters of a title (section 6, slice 1: one style per title).
enum class TitleParameter {
    Text,
    Font,
    Size,
    FillColour,
    Alignment,
    LineSpacing,
    Tracking,
    Outline,
    OutlineColour,
    OutlineWidth,
    Shadow,
    ShadowColour,
    ShadowOpacity,
    ShadowAngle,
    ShadowDistance,
    ShadowBlur,
    Box,
    BoxColour,
    BoxOpacity,
    BoxPadding,
    BoxCornerRadius,
    PositionX,
    PositionY,
    BoxWidth,
    PointText,
    Anchor,
};

inline constexpr std::size_t kTitleParameterCount = 26;

inline constexpr std::array<TitleParameter, kTitleParameterCount> kTitleParameters{
    TitleParameter::Text,          TitleParameter::Font,         TitleParameter::Size,
    TitleParameter::FillColour,    TitleParameter::Alignment,    TitleParameter::LineSpacing,
    TitleParameter::Tracking,      TitleParameter::Outline,      TitleParameter::OutlineColour,
    TitleParameter::OutlineWidth,  TitleParameter::Shadow,       TitleParameter::ShadowColour,
    TitleParameter::ShadowOpacity, TitleParameter::ShadowAngle,  TitleParameter::ShadowDistance,
    TitleParameter::ShadowBlur,    TitleParameter::Box,          TitleParameter::BoxColour,
    TitleParameter::BoxOpacity,    TitleParameter::BoxPadding,   TitleParameter::BoxCornerRadius,
    TitleParameter::PositionX,     TitleParameter::PositionY,    TitleParameter::BoxWidth,
    TitleParameter::PointText,     TitleParameter::Anchor};

// The kind of value a parameter takes (TitleValue's alternative).
enum class TitleValueType {
    Text,   // std::string (UTF-8; Return makes a line)
    Font,   // TitleFont
    Number, // double, within the row's range
    Colour, // SRGBColour
    Choice, // TitleAlignment
    Toggle, // bool
    Anchor, // TitleAnchor
};

// What a number is measured in (the inspector converts the fractions of the frame to pixels of the sequence).
enum class TitleUnit {
    None,          // text, font, colour, choice, toggle
    FrameHeight,   // a fraction of the frame's height (sizes)
    FrameWidth,    // a fraction of the frame's width (the box width, the position's x)
    Multiple,      // a multiple of the font's line height (line spacing)
    ThousandthsEm, // thousandths of an em (tracking, as Adobe and Final Cut measure it)
    Degrees,       // the shadow's angle: where the light comes from, counter-clockwise from the right
                   // (Adobe's convention; the shadow falls the other way, so 135 casts it down and right)
    Fraction,      // 0 to 1 (opacities)
};

struct TitleParameterInfo {
    TitleParameter parameter;
    const char *name;        // the project file's key ("text", "font", "size", "fillColour", ...)
    const char *displayName; // messages and the inspector ("Text", "Font", "Size", "Fill Colour", ...)
    TitleValueType type;
    TitleUnit unit;
    double defaultValue; // a number's default (a toggle's: 0 or 1; unused for the other types)
    double minimum;      // a number's valid range [minimum, maximum] (finite)
    double maximum;
    // Whether it changes the picture's pixels (part of the content id): every parameter but the position.
    bool changesPixels;
};

// The row describing `parameter` (the first row for a value outside the enum).
const TitleParameterInfo &infoOf(TitleParameter parameter);
const char *nameOf(TitleParameter parameter);
const char *displayNameOf(TitleParameter parameter);
// The parameter named `name` (nameOf), or nullopt.
std::optional<TitleParameter> titleParameterNamed(std::string_view name);

// A title's text is at most this many bytes of UTF-8.
inline constexpr std::size_t kMaxTitleTextBytes = 16384;

// One parameter's value (TitleParameterInfo::type says which alternative).
using TitleValue = std::variant<std::string, TitleFont, double, SRGBColour, TitleAlignment, bool, TitleAnchor>;

// A title's content: every parameter (section 6). The defaults are the Title preset's (titlePreset).
struct TitleContent {
    std::string text = "Title";
    TitleFont font = TitleFont::system(SystemFontWeight::Semibold);
    double size = 0.06; // of the frame height: 65 px at 1080 lines
    SRGBColour fillColour = kWhite;
    TitleAlignment alignment = TitleAlignment::Centre;
    double lineSpacing = 1.0;
    double tracking = 0.0;
    bool outline = false;
    SRGBColour outlineColour = kBlack;
    double outlineWidth = 0.003;
    bool shadow = true;
    SRGBColour shadowColour = kBlack;
    double shadowOpacity = 0.5;
    double shadowAngle = 135.0;
    double shadowDistance = 0.003;
    double shadowBlur = 0.004;
    bool box = false;
    SRGBColour boxColour = kBlack;
    double boxOpacity = 0.6;
    double boxPadding = 0.015;
    double boxCornerRadius = 0.0;
    double x = 0.5; // the box's centre, as fractions of the frame's width and height
    double y = 0.5;
    double width = 0.8; // the box's width, a fraction of the frame's width; its height follows the text
    // Point text (schema 11): the lines break only where the text has a line break (Return), the block is as wide
    // as its widest line and grows with the text, and `width` is kept but not used. Its position's x is then the
    // block's left edge, centre or right edge as its lines align (left, centre, right), so typing grows the text
    // away from that point, as Premiere's and Final Cut's point text do. Area text (false, slice 1): the lines
    // wrap at `width`, and x is the block's centre.
    bool pointText = false;
    // Where y lies on the block (TitleAnchor; schema 11): its top, centre (slice 1) or bottom.
    TitleAnchor anchor = TitleAnchor::Centre;

    friend bool operator==(const TitleContent &, const TitleContent &) = default;
};

// The value of `parameter` in `content`.
TitleValue valueOf(const TitleContent &content, TitleParameter parameter);
// Sets `parameter` of `content` to `value`. Returns false, changing nothing, when the value is not of the
// parameter's type.
bool setValue(TitleContent &content, TitleParameter parameter, const TitleValue &value);
// Why `value` cannot be `parameter`'s (the wrong type, a number not finite or outside its range, a colour
// outside [0, 1], a text longer than kMaxTitleTextBytes or not UTF-8, a font without a PostScript name), as
// a sentence naming the parameter, or nullopt.
std::optional<std::string> titleValueProblem(TitleParameter parameter, const TitleValue &value);
// The first problem of any parameter of `content` (titleValueProblem), or nullopt.
std::optional<std::string> titleContentProblem(const TitleContent &content);

// The presets (section 9), as code: a centred title, a lower third (left-aligned in the lower left inside
// title-safe, "Name" and "Role" on a 60 % black box), and a black colour matte.
enum class GeneratedPreset {
    Title,
    LowerThird,
    ColourMatte,
};

// "Title", "Lower Third", "Colour Matte".
const char *displayNameOf(GeneratedPreset preset);
// The generator kind a preset makes.
GeneratorKind generatorKindOf(GeneratedPreset preset);
// A preset's title content (the Title preset's for ColourMatte, which has none).
TitleContent titlePreset(GeneratedPreset preset);

// A 128-bit content id (see the header comment).
struct ContentId {
    std::uint64_t high = 0;
    std::uint64_t low = 0;

    friend bool operator==(const ContentId &, const ContentId &) = default;
    friend auto operator<=>(const ContentId &, const ContentId &) = default;
};

ContentId contentIdOf(const TitleContent &content);
ContentId matteContentIdOf(const SRGBColour &colour);
// `id` drawn on a `width` x `height` canvas (the sequence's frame): the same content on another frame size is
// another picture (its sizes are fractions of the frame), so the picture's cache identity covers the size.
ContentId contentIdOnCanvas(const ContentId &id, std::int32_t width, std::int32_t height);

// A generated clip's content: what kind it is, the title's or the matte's values, and what a newer version
// wrote in the file's object that this one does not read (`foreign`, compact JSON text of an object, written
// back on save; "" when there is none; the grade's foreign rule). Immutable once made: shared by the clip,
// its copies and the render graphs; edits make a new one.
class GeneratedContent {
  public:
    static std::shared_ptr<const GeneratedContent> makeTitle(TitleContent title, std::string foreign = {});
    static std::shared_ptr<const GeneratedContent> makeMatte(SRGBColour colour, std::string foreign = {});
    // A preset's content (makeTitle or makeMatte).
    static std::shared_ptr<const GeneratedContent> makePreset(GeneratedPreset preset);

    GeneratorKind kind() const {
        return kind_;
    }
    bool isTitle() const {
        return kind_ == GeneratorKind::Title;
    }
    bool isMatte() const {
        return kind_ == GeneratorKind::ColourMatte;
    }
    // The title's values (the Title preset's for a matte).
    const TitleContent &title() const {
        return title_;
    }
    // The matte's colour (black for a title).
    const SRGBColour &matteColour() const {
        return matteColour_;
    }
    const std::string &foreign() const {
        return foreign_;
    }
    // The id of what the picture shows (see the header comment).
    const ContentId &contentId() const {
        return contentId_;
    }

    // The same kind, values and foreign entries.
    friend bool operator==(const GeneratedContent &a, const GeneratedContent &b);

  private:
    GeneratedContent() = default;
    GeneratorKind kind_ = GeneratorKind::Title;
    TitleContent title_;
    SRGBColour matteColour_ = kBlack;
    std::string foreign_;
    ContentId contentId_;
};

// Whether two clips' contents are the same: both absent, or both present and equal.
bool sameContent(const std::shared_ptr<const GeneratedContent> &a, const std::shared_ptr<const GeneratedContent> &b);

// Why `content` is not valid (a title's values: titleContentProblem; a matte's colour), or nullopt.
std::optional<std::string> generatedContentProblem(const GeneratedContent &content);

// The first line of a title's text ("Title" when it is empty or only spaces): the clip's name on the timeline.
std::string titleDisplayName(const TitleContent &content);

} // namespace ve
