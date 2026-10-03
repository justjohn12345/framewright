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
// differently at different raster scales). The text block is the wrap width wide and as tall as its lines.
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
// relative to the title's position (the block's centre), which is not part of the picture. (The compositor
// puts the picture's corner on a whole canvas pixel, so a title without Motion is drawn texel for pixel.)
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

/// A title's text block at k = 1 in sequence pixels: the wrap width and the height of its lines (0 for no text).
struct TitleBlockSize {
    double width = 0;
    double height = 0;
};
TitleBlockSize measureTitleBlock(const TitleContent &content, double canvasWidth, double canvasHeight);

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

/// The cache identity of `content` drawn on a `canvasWidth` x `canvasHeight` sequence at raster scale `k` (k is
/// quantised as rasterScale64 does): what the render thread looks a generated layer's picture up by, without
/// making its source. A matte's ignores k (its picture has no detail to sharpen).
GeneratedKey generatedKeyFor(const GeneratedContent &content, std::int32_t canvasWidth, std::int32_t canvasHeight,
                             double k);

/// The source of `content`'s picture on a `canvasWidth` x `canvasHeight` sequence at raster scale `k`: a title
/// (renderTitle) or a matte (renderMatte); its key is generatedKeyFor's. Null for a null `content`.
std::shared_ptr<const GeneratedPictureSource> makeGeneratedSource(std::shared_ptr<const GeneratedContent> content,
                                                                  std::int32_t canvasWidth, std::int32_t canvasHeight,
                                                                  double k);

} // namespace ve::media
