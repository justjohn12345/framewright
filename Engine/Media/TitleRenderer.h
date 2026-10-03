// The title and matte renderers: a title's text laid out by Core Text and drawn by Core Graphics into an
// IOSurface-backed buffer (PictureDrawing), and a colour matte's solid colour, in memory, on the decode pool's
// threads (never the render or main thread). docs/plans/2026-10-02-titles-design.md, sections 3 and 7.
//
// Raster scale. A picture is drawn at k raster pixels per sequence pixel (the largest scale its clip reaches in
// that output: TitleSource's key carries k), so a title zoomed by Motion or exported larger than the sequence
// stays sharp. Every size of the title (font size, wrap width, outline, shadow distance and blur, padding,
// corner radius) is its fraction of the frame times the frame's size times k; Core Graphics' shadow offset and
// blur are in the context's base space, which no transform scales, so they are multiplied by k here. Past
// kMaxRasterSide pixels on a side or kMaxRasterBytes the raster scale is lowered until the picture fits, and
// the compositor magnifies it (softer, not missing).
//
// Layout. An attributed string with the font, the fill colour and the tracking (kCTTrackingAttributeName, in
// points: thousandths of an em times the font size) is broken into lines at the wrap width (the title's box
// width) by a CTTypesetter: Core Text shapes it, wraps it, lays out bidirectional text and falls back per
// character to fonts that have the glyphs (Japanese typed in Helvetica draws in a Japanese font). Each line takes
// its ascent, descent and leading times the line spacing and is placed at its pen offset for the alignment; the
// renderer places the lines itself (a CTFrame rounds line heights to whole points, so a title's lines would sit
// differently at different raster scales). The text block is the wrap width wide and as tall as its lines. Point
// text (TitleContent::pointText) breaks only at line breaks and its block is as wide as its widest line. A text that
// ends with a line break has an empty last line in its block (where the caret goes after Return).
//
// Drawing, in order: the background box (a rounded rectangle around the block, grown by the padding); then, in
// one transparency layer so that the outline and every glyph cast one shadow, the outline (each glyph's outline
// path stroked at twice the outline width with round joins, so it lies outside the letter, which the fill then
// covers) and the fill (the glyph paths filled); the shadow is cast by the layer as a whole. Colour bitmap glyphs
// (Apple Color Emoji) have no outline path: they are drawn as they are and get no outline. Anti-aliasing is on,
// font smoothing (LCD) off, subpixel positioning on and quantisation off, so glyph positions scale exactly with
// k. The picture holds only the rectangle that has something in it (box, ink, outline, shadow) with a
// transparent margin of kRasterMargin sequence pixels, snapped to whole sequence pixels around the block so
// pictures of one title at different integer k cover the same canvas rectangle; its CanvasGeometry places it
// relative to the title's position (the point the block is anchored at: its centre for area text anchored at its
// centre; TitleBlockSize), which is not part of the picture. (The compositor puts
// the corner of a picture it draws texel for pixel on a whole target pixel, so a fractional position does not
// blur it.)
//
// Fonts (section 7). The system font is named by its weight (a descriptor of the UI font with the weight
// trait). Any other font is named by its PostScript name and opened with CTFontCreateWithName, which
// substitutes silently: a font whose PostScript name differs from the one asked for is missing on this Mac, and
// the title is drawn in the system font at the weight its style name says (Bold, Light, ...; Regular when it
// says none), the stored name unchanged. The renderer reports the substitution (RenderedTitle::fontMissing); the
// facade asks isTitleFontAvailable for its warnings.
//
// Colour: the components are sRGB, drawn into the sRGB context unchanged (white is exactly 255), and the
// picture is tagged as every still is (premultiplied, BT.709 primaries, sRGB transfer).
//
// Mattes: a 4 x 4 'RGhA' picture of the colour (half float: a colour is exact to 10 bits in a 10-bit export),
// stretched over the whole canvas.
//
// Thread-safety: every function may be called from any thread; nothing here touches AppKit or the main thread.

#pragma once

#include "../Model/GeneratedContent.h"
#include "CFRef.h"
#include "GeneratedSource.h"

#import <CoreText/CoreText.h>

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace ve::media {

/// The largest raster side (Metal's 2D texture limit on Apple GPUs) and picture size (an eighth of the frame
/// cache's default budget).
inline constexpr double kMaxRasterSide = 16384.0;
inline constexpr double kMaxRasterBytes = 64.0 * 1024.0 * 1024.0;
/// Transparent sequence pixels around a picture's content (k raster pixels each), so the compositor's edge ramp
/// lies on transparent texels.
inline constexpr double kRasterMargin = 2.0;

/// The weight of the system font a title named by `font` is drawn in when `font` is missing: the one its style
/// name says ("Bold", "Semibold", "Light", ... and the condensed "Black"/"Heavy"), else Regular. The system
/// font's own weight for the system font.
SystemFontWeight fallbackWeightFor(const TitleFont &font);

/// Whether `font` can be drawn as itself on this Mac (always for the system font).
bool isTitleFontAvailable(const TitleFont &font);

/// The Core Text font a title with `font` is drawn with at `pointSize`, and whether `font` is missing on this
/// Mac (then the font is the system font at fallbackWeightFor(font)).
struct ResolvedTitleFont {
    CFRef<CTFontRef> font;
    bool missing = false;
};
ResolvedTitleFont resolveTitleFont(const TitleFont &font, double pointSize);

/// A title's text block at k = 1 in sequence pixels: its width (the wrap width; point text: its widest line) and the
/// height of its lines (an empty text, or one ending with a line break, has an empty last line, as tall as a line of
/// its font), and where its top-left corner lies relative to the title's position (the anchor: area text is centred
/// on x, point text has x at its left edge, centre or right edge as it aligns; y is its top, centre or bottom).
struct TitleBlockSize {
    double width = 0;
    double height = 0;
    double left = 0;
    double top = 0;
};
TitleBlockSize measureTitleBlock(const TitleContent &content, double canvasWidth, double canvasHeight);

/// A title's text laid out as the renderer draws it (the same lines, at k = 1), for the program monitor's caret,
/// selection and clicks. In sequence pixels on the title's canvas, relative to the title's position (x right, y
/// down): the caller places them through the clip's Motion. Indices are UTF-16 offsets into the text (NSString's),
/// from 0 to length(); a caret at a line the box wrapped shows at the start of the next line. Not thread-safe to
/// share; cheap to make (one layout of the text).
class TitleTextLayout {
  public:
    struct Line {
        CFIndex start = 0;  // its characters (the empty last line: the text's length, 0)
        CFIndex length = 0;
        double top = 0;      // its ascent above the baseline
        double baseline = 0;
        double bottom = 0;   // its descent below the baseline
        double leading = 0;  // below its bottom
        double left = 0;     // where the line starts (its pen offset in the block, for the alignment)
        double width = 0;    // its typographic width (trailing white space included)
        bool endsWithBreak = false;
    };
    struct Caret {
        double x = 0;
        double top = 0;
        double bottom = 0;
        std::size_t line = 0;
    };

    static TitleTextLayout make(const TitleContent &content, double canvasWidth, double canvasHeight);

    /// The text block (measureTitleBlock's), relative to the position.
    CGRect block() const {
        return block_;
    }
    CFIndex length() const {
        return length_;
    }
    double fontSize() const {
        return fontSize_;
    }
    bool fontMissing() const {
        return fontMissing_;
    }
    std::size_t lineCount() const {
        return lineInfo_.size();
    }
    const Line &line(std::size_t i) const {
        return lineInfo_[i];
    }
    /// The line the caret at `index` is on.
    std::size_t lineOf(CFIndex index) const;
    /// The caret at `index`: a vertical segment from the line's top to its bottom at x.
    Caret caret(CFIndex index) const;
    /// The caret index on line `i` nearest `x` (never past the line's break, nor at the start of the next line).
    CFIndex indexOnLine(std::size_t i, double x) const;
    /// The caret index nearest `point`: on the line whose band holds its y (else the nearest line).
    CFIndex indexAt(CGPoint point) const;
    /// The rectangles covering the text from `start` to `end`: per line, the spans of its selected glyphs (a selected
    /// line break a little past the line's end), each from the line's top to its bottom and leading.
    std::vector<CGRect> selectionRects(CFIndex start, CFIndex end) const;

  private:
    double offsetInLine(std::size_t i, CFIndex index) const;
    CFIndex lastCaretIndexOf(std::size_t i) const;

    std::vector<CFRef<CTLineRef>> lines_;
    std::vector<Line> lineInfo_;
    CFRef<CFStringRef> text_;
    CFIndex length_ = 0;
    double fontSize_ = 0;
    CGRect block_ = CGRectZero;
    bool fontMissing_ = false;
};

/// A rendered title: the picture (tagged with `geometry`), the raster scale it was drawn at (k, or less when
/// the limits lowered it) and whether its font is missing on this Mac.
struct RenderedTitle {
    PixelBuffer picture;
    CanvasGeometry geometry;
    double rasterScale = 1.0;
    bool fontMissing = false;
};

/// Renders `content` for a `canvasWidth` x `canvasHeight` sequence at raster scale `k` (see the header comment).
/// Cancelled when `interrupt` is requested (polled between the layout, the lines and the passes). An empty text
/// gives a transparent picture.
Result<RenderedTitle> renderTitle(const TitleContent &content, double canvasWidth, double canvasHeight, double k,
                                  const DecodeInterrupt *interrupt = nullptr);

/// A colour matte's picture: 4 x 4 'RGhA' pixels of `colour`, tagged to cover the whole canvas.
Result<PixelBuffer> renderMatte(const SRGBColour &colour, double canvasWidth, double canvasHeight);

/// The raster scale a generated layer's picture is rendered at for an output of `outputScale` output pixels per
/// sequence pixel (titles design, section 3): the largest Motion scale its clip reaches (VideoLayer::maxMotionScale)
/// times max(1, outputScale), never below the sequence's resolution (1). A non-finite or negative input counts as 1.
double rasterScaleFor(double maxMotionScale, double outputScale);

/// The generation of the fonts on this Mac as titles see them: 1 at launch, advanced by advanceTitleFontGeneration
/// when a font is activated or removed (the facade does, on Core Text's notification, before it drops the titles'
/// pictures). Part of every title's GeneratedKey, so the change is a key change. Any thread.
std::uint32_t titleFontGeneration();
/// Advances titleFontGeneration and returns the new generation.
std::uint32_t advanceTitleFontGeneration();

/// The cache identity of `content` drawn on a `canvasWidth` x `canvasHeight` sequence at raster scale `k` (k is
/// quantised as rasterScale64 does) with the fonts of `fontGeneration`: what the render thread looks a generated
/// layer's picture up by, without making its source. A matte's ignores k and the fonts (its picture has no detail
/// to sharpen and no text).
GeneratedKey generatedKeyFor(const GeneratedContent &content, std::int32_t canvasWidth, std::int32_t canvasHeight,
                             double k, std::uint32_t fontGeneration);

/// The source of `content`'s picture on a `canvasWidth` x `canvasHeight` sequence at raster scale `k`, keyed with
/// the fonts of `fontGeneration`: a title (renderTitle) or a matte (renderMatte); its key is generatedKeyFor's.
/// (It draws with the fonts the Mac has when it renders: a caller that keeps an older generation, an export, knows
/// it and says so.) Null for a null `content`.
std::shared_ptr<const GeneratedPictureSource> makeGeneratedSource(std::shared_ptr<const GeneratedContent> content,
                                                                  std::int32_t canvasWidth, std::int32_t canvasHeight,
                                                                  double k, std::uint32_t fontGeneration);

} // namespace ve::media
