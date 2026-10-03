#include "TitleRenderer.h"

#include "PictureDrawing.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstring>
#include <limits>
#include <utility>
#include <vector>

namespace ve::media {

namespace {

// NSFontWeight's values (AppKit's NSFontWeightUltraLight ... NSFontWeightBlack), which the system font's
// weight trait takes.
CGFloat weightTraitOf(SystemFontWeight weight) {
    switch (weight) {
    case SystemFontWeight::UltraLight:
        return -0.8;
    case SystemFontWeight::Thin:
        return -0.6;
    case SystemFontWeight::Light:
        return -0.4;
    case SystemFontWeight::Regular:
        return 0.0;
    case SystemFontWeight::Medium:
        return 0.23;
    case SystemFontWeight::Semibold:
        return 0.3;
    case SystemFontWeight::Bold:
        return 0.4;
    case SystemFontWeight::Heavy:
        return 0.56;
    case SystemFontWeight::Black:
        return 0.62;
    }
    return 0.0;
}

CFRef<CFStringRef> cfString(const std::string &text) {
    return CFRef<CFStringRef>::adopt(CFStringCreateWithBytes(kCFAllocatorDefault,
                                                             reinterpret_cast<const UInt8 *>(text.data()),
                                                             CFIndex(text.size()), kCFStringEncodingUTF8, false));
}

std::string stdString(CFStringRef text) {
    if (text == nullptr) {
        return {};
    }
    const CFIndex length = CFStringGetLength(text);
    const CFIndex size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    std::string out(std::size_t(size), '\0');
    if (!CFStringGetCString(text, out.data(), size, kCFStringEncodingUTF8)) {
        return {};
    }
    out.resize(std::strlen(out.c_str()));
    return out;
}

CFRef<CTFontRef> systemFont(SystemFontWeight weight, double size) {
    CFRef<CTFontRef> base = CFRef<CTFontRef>::adopt(CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, nullptr));
    if (!base) {
        return base;
    }
    CFRef<CTFontDescriptorRef> descriptor = CFRef<CTFontDescriptorRef>::adopt(CTFontCopyFontDescriptor(base.get()));
    const CGFloat trait = weightTraitOf(weight);
    CFRef<CFNumberRef> weightNumber = CFRef<CFNumberRef>::adopt(CFNumberCreate(nullptr, kCFNumberCGFloatType, &trait));
    const void *traitKeys[] = {kCTFontWeightTrait};
    const void *traitValues[] = {weightNumber.get()};
    CFRef<CFDictionaryRef> traits = CFRef<CFDictionaryRef>::adopt(CFDictionaryCreate(
        nullptr, traitKeys, traitValues, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    const void *keys[] = {kCTFontTraitsAttribute};
    const void *values[] = {traits.get()};
    CFRef<CFDictionaryRef> attributes = CFRef<CFDictionaryRef>::adopt(
        CFDictionaryCreate(nullptr, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    CFRef<CTFontDescriptorRef> weighted =
        CFRef<CTFontDescriptorRef>::adopt(CTFontDescriptorCreateCopyWithAttributes(descriptor.get(), attributes.get()));
    CFRef<CTFontRef> font = CFRef<CTFontRef>::adopt(CTFontCreateWithFontDescriptor(weighted.get(), size, nullptr));
    return font ? font : base;
}

CFRef<CGColorRef> srgbColour(const SRGBColour &colour, double alpha) {
    static CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    const CGFloat components[4] = {colour.red, colour.green, colour.blue, std::clamp(alpha, 0.0, 1.0)};
    return CFRef<CGColorRef>::adopt(CGColorCreate(space, components));
}

bool interrupted(const DecodeInterrupt *interrupt) {
    return interrupt != nullptr && interrupt->requested();
}

MediaError cancelled() {
    return makeError(MediaErrorCode::Cancelled, "the title's render was interrupted");
}

// A title's lines laid out at k = 1, in sequence pixels, relative to its text block's top-left corner (x right, y
// down): what the renderer draws (Layout, magnified k times) and what the program monitor's caret, selection and
// clicks are measured against (TitleTextLayout), so both follow the same lines.
//
// The lines are broken by a CTTypesetter at the wrap width (it stops at every paragraph separator, so Return makes a
// line; point text breaks only there) and placed here rather than by a CTFrame: the first line's ascent from the
// block's top, each next baseline (the previous line's descent and leading and this line's ascent) times the line
// spacing below the previous one, the last line's descent and leading to the block's bottom, and each its pen offset
// for the alignment (CTLineGetPenOffsetForFlush, which leaves trailing white space out). Core Text's own frames round
// their line heights to whole points, which would move the lines of one title differently at different raster
// scales; placed here, a title's layout scales exactly with k.
//
// A text that ends with a line break (or is empty) has an empty last line after it, as tall as a line of the font:
// the line the caret goes to after Return, which the block (and its background box) takes in, as Premiere's and
// Final Cut's do. Its CTLine is a space in the title's attributes, which has the font's metrics and draws nothing.
//
// The block is the wrap width wide (point text: its widest line's visible width) and as tall as its lines. Where it
// lies relative to the title's position (blockLeft, blockTop) is the anchor: area text is centred on x, point text
// has x at its left edge, centre or right edge as its lines align, and y is its top, centre or bottom
// (TitleContent::anchor).
struct TextLines {
    std::vector<CFRef<CTLineRef>> lines;
    std::vector<CFRange> ranges;     // each line's characters (UTF-16 indices of the text; the empty last line: {length, 0})
    std::vector<double> penOffsets;  // each line's start from the block's left
    std::vector<double> baselines;   // each line's baseline down from the block's top
    std::vector<double> ascents;
    std::vector<double> descents;
    std::vector<double> leadings;
    CFRef<CFStringRef> text;
    CFIndex length = 0;              // the text's UTF-16 length
    double fontSize = 0;
    double width = 0;
    double height = 0;
    double blockLeft = 0; // the block's top-left corner relative to the position
    double blockTop = 0;
    bool fontMissing = false;
};

TextLines layoutLines(const TitleContent &c, double canvasWidth, double canvasHeight) {
    TextLines laid;
    laid.fontSize = std::max(0.01, c.size * canvasHeight);
    const double wrapWidth = std::max(1.0, c.width * canvasWidth);
    ResolvedTitleFont resolved = resolveTitleFont(c.font, laid.fontSize);
    laid.fontMissing = resolved.missing;
    const double flush = c.alignment == TitleAlignment::Left ? 0.0 : c.alignment == TitleAlignment::Right ? 1.0 : 0.5;
    const auto place = [&laid, flush, &c, wrapWidth]() {
        // The block's width, then each line's pen offset for the alignment in it, then the block on the position.
        if (c.pointText) {
            double widest = 0.0;
            for (const CFRef<CTLineRef> &line : laid.lines) {
                const double width = CTLineGetTypographicBounds(line.get(), nullptr, nullptr, nullptr);
                widest = std::max(widest, width - CTLineGetTrailingWhitespaceWidth(line.get()));
            }
            laid.width = widest;
        } else {
            laid.width = wrapWidth;
        }
        for (const CFRef<CTLineRef> &line : laid.lines) {
            laid.penOffsets.push_back(CTLineGetPenOffsetForFlush(line.get(), flush, laid.width));
        }
        laid.blockLeft = c.pointText ? -flush * laid.width : -laid.width / 2.0;
        laid.blockTop = c.anchor == TitleAnchor::Top ? 0.0 : c.anchor == TitleAnchor::Bottom ? -laid.height : -laid.height / 2.0;
    };
    CFRef<CFStringRef> text = cfString(c.text);
    if (!resolved.font || !text) {
        place();
        return laid;
    }
    laid.length = CFStringGetLength(text.get());
    laid.text = text;
    const CGFloat tracking = c.tracking / 1000.0 * laid.fontSize; // thousandths of an em, in points
    CFRef<CFNumberRef> trackingNumber = CFRef<CFNumberRef>::adopt(CFNumberCreate(nullptr, kCFNumberCGFloatType, &tracking));
    CFRef<CGColorRef> fill = srgbColour(c.fillColour, 1.0);
    const void *keys[] = {kCTFontAttributeName, kCTTrackingAttributeName, kCTForegroundColorAttributeName};
    const void *values[] = {resolved.font.get(), trackingNumber.get(), fill.get()};
    CFRef<CFDictionaryRef> attributes = CFRef<CFDictionaryRef>::adopt(
        CFDictionaryCreate(nullptr, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    double baseline = 0.0;      // the last line's, down from the block's top
    double previousBelow = 0.0; // the last line's descent and leading
    const auto add = [&](CFRef<CTLineRef> line, CFRange range) {
        CGFloat ascent = 0, descent = 0, leading = 0;
        CTLineGetTypographicBounds(line.get(), &ascent, &descent, &leading);
        // The first line's top is the block's; the line spacing scales the distance between two lines (the
        // previous one's descent and leading and this one's ascent), so lines closer than their natural spacing
        // still start and end inside the block (and the background box).
        baseline = laid.lines.empty() ? ascent : baseline + (previousBelow + ascent) * c.lineSpacing;
        previousBelow = descent + leading;
        laid.lines.push_back(std::move(line));
        laid.ranges.push_back(range);
        laid.baselines.push_back(baseline);
        laid.ascents.push_back(ascent);
        laid.descents.push_back(descent);
        laid.leadings.push_back(leading);
    };
    if (laid.length > 0) {
        CFRef<CFAttributedStringRef> attributed =
            CFRef<CFAttributedStringRef>::adopt(CFAttributedStringCreate(nullptr, text.get(), attributes.get()));
        CFRef<CTTypesetterRef> typesetter =
            CFRef<CTTypesetterRef>::adopt(CTTypesetterCreateWithAttributedString(attributed.get()));
        if (!typesetter) {
            place();
            return laid;
        }
        // Point text breaks only at line breaks: a width no line reaches.
        const double breakWidth = c.pointText ? 1.0e9 : wrapWidth;
        for (CFIndex start = 0; start < laid.length;) {
            CFIndex count = CTTypesetterSuggestLineBreak(typesetter.get(), start, breakWidth);
            if (count <= 0) {
                count = 1; // never stall on a glyph wider than the box
            }
            CFRef<CTLineRef> line =
                CFRef<CTLineRef>::adopt(CTTypesetterCreateLine(typesetter.get(), CFRangeMake(start, count)));
            const CFRange range = CFRangeMake(start, count);
            start += count;
            if (line) {
                add(std::move(line), range);
            }
        }
    }
    // The empty last line after a final line break, or of an empty text.
    const bool endsWithBreak =
        laid.length > 0 && CFCharacterSetIsCharacterMember(CFCharacterSetGetPredefined(kCFCharacterSetNewline),
                                                           CFStringGetCharacterAtIndex(text.get(), laid.length - 1));
    if (laid.length == 0 || endsWithBreak) {
        CFRef<CFAttributedStringRef> space =
            CFRef<CFAttributedStringRef>::adopt(CFAttributedStringCreate(nullptr, CFSTR(" "), attributes.get()));
        CFRef<CTLineRef> line = CFRef<CTLineRef>::adopt(CTLineCreateWithAttributedString(space.get()));
        if (line) {
            add(std::move(line), CFRangeMake(laid.length, 0));
        }
    }
    laid.height = laid.lines.empty() ? 0.0 : baseline + previousBelow;
    place();
    return laid;
}

// A title laid out at raster scale k, in the block's coordinates: raster pixels, y up, the block from (0, 0) to
// (wrapWidth, blockHeight), so its top is y = blockHeight (the "frame" Core Text's drawing works in).
//
// The text is laid out at k = 1 (TextLines: the font at the title's point size in sequence pixels, the lines broken
// at its wrap width there) and the layout is then magnified k times: a font's design can follow its point size (the
// system font's optical size and tracking change with it, as a variable font's 'opsz' axis does), so laying out at
// size x k would draw other glyph shapes and advances, and could break the lines elsewhere, than at k = 1. Magnified,
// a title at any raster scale is the k = 1 title, sharper. The lines (CTLineRef) stay in k = 1 units; everything
// else here is in raster pixels.
struct Layout {
    std::vector<CFRef<CTLineRef>> lines; // laid out at k = 1
    std::vector<CGPoint> origins;        // each line's baseline origin (raster pixels)
    double magnification = 1;            // k: raster pixels per unit of the lines
    double fontSize = 0;
    double wrapWidth = 0; // the block's width
    double blockHeight = 0;
    double frameHeight = 0; // == blockHeight (the block's top)
    double blockLeft = 0;   // the block's top-left corner relative to the title's position (sequence pixels)
    double blockTop = 0;
    bool fontMissing = false;
    CGRect lineExtents = CGRectNull; // the lines' typographic extents (trailing white space left out)
    CGRect ink = CGRectNull;         // the glyphs' paths and the lines' typographic bounds

    CFIndex lineCount() const {
        return CFIndex(lines.size());
    }
    CTLineRef line(CFIndex i) const {
        return lines[std::size_t(i)].get();
    }
};

Layout layoutTitle(const TitleContent &c, double canvasWidth, double canvasHeight, double k) {
    TextLines laid = layoutLines(c, canvasWidth, canvasHeight);
    Layout layout;
    // At k = 1 (see Layout); magnified at the end.
    layout.fontSize = laid.fontSize;
    layout.wrapWidth = laid.width;
    layout.blockHeight = laid.height;
    layout.frameHeight = laid.height;
    layout.blockLeft = laid.blockLeft;
    layout.blockTop = laid.blockTop;
    layout.fontMissing = laid.fontMissing;
    for (std::size_t i = 0; i < laid.lines.size(); ++i) {
        CTLineRef line = laid.lines[i].get();
        const CGPoint origin = CGPointMake(laid.penOffsets[i], layout.frameHeight - laid.baselines[i]);
        layout.origins.push_back(origin);
        CGFloat ascent = 0, descent = 0, leading = 0;
        const double width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        const double visible = std::max(0.0, width - CTLineGetTrailingWhitespaceWidth(line));
        const CGRect typographic = CGRectMake(origin.x, origin.y - descent, visible, ascent + descent);
        if (visible > 0) {
            layout.lineExtents = CGRectUnion(layout.lineExtents, typographic);
            layout.ink = CGRectUnion(layout.ink, typographic);
        }
        const CGRect glyphs = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
        if (!CGRectIsNull(glyphs) && !CGRectIsEmpty(glyphs)) {
            layout.ink = CGRectUnion(layout.ink, CGRectOffset(glyphs, origin.x, origin.y));
        }
        layout.lines.push_back(std::move(laid.lines[i]));
    }
    layout.magnification = k;
    layout.fontSize *= k;
    layout.wrapWidth *= k;
    layout.blockHeight *= k;
    layout.frameHeight *= k;
    const CGAffineTransform scale = CGAffineTransformMakeScale(k, k);
    for (CGPoint &origin : layout.origins) {
        origin = CGPointApplyAffineTransform(origin, scale);
    }
    if (!CGRectIsNull(layout.lineExtents)) {
        layout.lineExtents = CGRectApplyAffineTransform(layout.lineExtents, scale);
    }
    if (!CGRectIsNull(layout.ink)) {
        layout.ink = CGRectApplyAffineTransform(layout.ink, scale);
    }
    return layout;
}

// The glyphs of a laid-out title as paths (in the frame's coordinates), and the colour bitmap glyphs, which have
// no path (drawn as they are).
struct GlyphDrawing {
    CFRef<CGMutablePathRef> outlines = CFRef<CGMutablePathRef>::adopt(CGPathCreateMutable());
    struct Bitmap {
        CFRef<CTFontRef> font;
        CGGlyph glyph = 0;
        CGPoint position{};
    };
    std::vector<Bitmap> bitmaps;
};

Result<GlyphDrawing> glyphsOf(const Layout &layout, const DecodeInterrupt *interrupt) {
    GlyphDrawing drawing;
    std::vector<CGGlyph> glyphs;
    std::vector<CGPoint> positions;
    const double k = layout.magnification; // the lines are at k = 1, the drawing in raster pixels
    for (CFIndex i = 0; i < layout.lineCount(); ++i) {
        if (interrupted(interrupt)) {
            return cancelled();
        }
        const CGPoint origin = layout.origins[std::size_t(i)];
        CFArrayRef runs = CTLineGetGlyphRuns(layout.line(i));
        for (CFIndex r = 0; r < CFArrayGetCount(runs); ++r) {
            CTRunRef run = static_cast<CTRunRef>(CFArrayGetValueAtIndex(runs, r));
            const CFIndex count = CTRunGetGlyphCount(run);
            if (count <= 0) {
                continue;
            }
            auto font = static_cast<CTFontRef>(CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName));
            if (font == nullptr) {
                continue;
            }
            glyphs.resize(std::size_t(count));
            positions.resize(std::size_t(count));
            CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs.data());
            CTRunGetPositions(run, CFRangeMake(0, 0), positions.data());
            CFRef<CTFontRef> magnified; // a colour font at k times its size, made for its first bitmap glyph
            for (CFIndex g = 0; g < count; ++g) {
                const CGPoint at = CGPointMake(origin.x + k * positions[std::size_t(g)].x,
                                               origin.y + k * positions[std::size_t(g)].y);
                // The k = 1 glyph's outline, magnified k times.
                const CGAffineTransform place = CGAffineTransformMake(k, 0, 0, k, at.x, at.y);
                CFRef<CGPathRef> path = CFRef<CGPathRef>::adopt(CTFontCreatePathForGlyph(font, glyphs[std::size_t(g)], &place));
                if (path) {
                    CGPathAddPath(drawing.outlines.get(), nullptr, path.get());
                } else if ((CTFontGetSymbolicTraits(font) & kCTFontTraitColorGlyphs) != 0) {
                    if (!magnified) {
                        magnified = CFRef<CTFontRef>::adopt(CTFontCreateCopyWithAttributes(font, CTFontGetSize(font) * k,
                                                                                           nullptr, nullptr));
                    }
                    drawing.bitmaps.push_back({magnified, glyphs[std::size_t(g)], at});
                }
                // Any other glyph without a path (a space) draws nothing.
            }
        }
    }
    return drawing;
}

// Where a title's picture lies, from its layout: the rectangle with something in it (the box, the ink with its
// outline, the shadow), grown by the margin and snapped outward to whole sequence pixels around the block; and
// the raster that covers it.
struct Raster {
    // In block coordinates (sequence pixels, x from the block's left, y down from its top).
    double left = 0;
    double top = 0;
    double width = 0;  // sequence pixels the raster covers
    double height = 0;
    std::size_t pixelsWide = 0;
    std::size_t pixelsHigh = 0;
};

struct Extents {
    CGRect box = CGRectNull; // in frame coordinates
    CGRect content = CGRectNull;
    CGSize shadowOffset = CGSizeZero; // base space (pixels, y up)
    double shadowBlur = 0;
    double outlineWidth = 0;
    double boxRadius = 0;
};

Extents extentsOf(const TitleContent &c, const Layout &layout, double canvasHeight, double k) {
    Extents e;
    const double unit = canvasHeight * k; // pixels per "fraction of the frame height"
    if (c.box && !CGRectIsNull(layout.lineExtents)) {
        const double padding = c.boxPadding * unit;
        // Horizontally the lines' extent, vertically the whole block, both grown by the padding.
        const CGRect block = CGRectMake(layout.lineExtents.origin.x, layout.frameHeight - layout.blockHeight,
                                        layout.lineExtents.size.width, layout.blockHeight);
        e.box = CGRectInset(block, -padding, -padding);
        e.boxRadius = std::min({c.boxCornerRadius * unit, e.box.size.width / 2.0, e.box.size.height / 2.0});
        e.content = CGRectUnion(e.content, e.box);
    }
    if (!CGRectIsNull(layout.ink)) {
        e.outlineWidth = c.outline ? c.outlineWidth * unit : 0.0;
        const CGRect ink = CGRectInset(layout.ink, -e.outlineWidth, -e.outlineWidth);
        e.content = CGRectUnion(e.content, ink);
        if (c.shadow && c.shadowOpacity > 0) {
            // The light comes from the angle (counter-clockwise from the right); the shadow falls the other way.
            const double theta = c.shadowAngle * M_PI / 180.0;
            const double distance = c.shadowDistance * unit;
            e.shadowOffset = CGSizeMake(-std::cos(theta) * distance, -std::sin(theta) * distance);
            e.shadowBlur = c.shadowBlur * unit;
            // The blur's reach (in pixels; a sequence pixel more for its last faint ramp, so the extents scale
            // with k exactly).
            const double spread = 2.0 * e.shadowBlur + k;
            e.content = CGRectUnion(
                e.content, CGRectInset(CGRectOffset(ink, e.shadowOffset.width, e.shadowOffset.height), -spread, -spread));
        }
    }
    return e;
}

Raster rasterFor(const Layout &layout, const Extents &extents, double k) {
    Raster raster;
    if (CGRectIsNull(extents.content)) {
        return raster;
    }
    // Frame coordinates (y up) to block coordinates (y down from the block's top), in sequence pixels. The margin
    // is in sequence pixels (k raster pixels each), so pictures of one title at different integer k cover the
    // same canvas rectangle.
    const CGRect c = CGRectInset(extents.content, -kRasterMargin * k, -kRasterMargin * k);
    const double blockTop = layout.frameHeight; // the block starts at the frame's top
    const double left = std::floor(CGRectGetMinX(c) / k);
    const double right = std::ceil(CGRectGetMaxX(c) / k);
    const double top = std::floor((blockTop - CGRectGetMaxY(c)) / k);
    const double bottom = std::ceil((blockTop - CGRectGetMinY(c)) / k);
    raster.left = left;
    raster.top = top;
    raster.pixelsWide = std::size_t(std::max(1.0, std::ceil((right - left) * k - 1e-6)));
    raster.pixelsHigh = std::size_t(std::max(1.0, std::ceil((bottom - top) * k - 1e-6)));
    raster.width = double(raster.pixelsWide) / k;
    raster.height = double(raster.pixelsHigh) / k;
    return raster;
}

void drawTitle(CGContextRef ctx, const TitleContent &c, const Layout &layout, const Extents &extents,
               const GlyphDrawing &glyphs, const Raster &raster, double k) {
    CGContextClearRect(ctx, CGRectMake(0, 0, double(raster.pixelsWide), double(raster.pixelsHigh)));
    CGContextSetShouldAntialias(ctx, true);
    CGContextSetAllowsAntialiasing(ctx, true);
    CGContextSetAllowsFontSmoothing(ctx, false);
    CGContextSetShouldSmoothFonts(ctx, false);
    CGContextSetShouldSubpixelPositionFonts(ctx, true);
    CGContextSetShouldSubpixelQuantizeFonts(ctx, false);
    CGContextSetTextMatrix(ctx, CGAffineTransformIdentity);
    // Frame coordinates to the bitmap's: the raster's top-left (block coordinates raster.left, raster.top,
    // y down) is the bitmap's top-left (y up, height pixelsHigh). Only a translation, so the shadow's base-space
    // offset and blur (computed in pixels) are what they say.
    const double tx = -raster.left * k;
    const double ty = double(raster.pixelsHigh) - layout.frameHeight + raster.top * k;
    CGContextTranslateCTM(ctx, tx, ty);

    if (!CGRectIsNull(extents.box)) {
        CFRef<CGPathRef> box = CFRef<CGPathRef>::adopt(
            CGPathCreateWithRoundedRect(extents.box, extents.boxRadius, extents.boxRadius, nullptr));
        CFRef<CGColorRef> colour = srgbColour(c.boxColour, c.boxOpacity);
        CGContextSetFillColorWithColor(ctx, colour.get());
        CGContextAddPath(ctx, box.get());
        CGContextFillPath(ctx);
    }
    const bool shadow = c.shadow && c.shadowOpacity > 0 && !CGRectIsNull(layout.ink);
    if (shadow) {
        CFRef<CGColorRef> colour = srgbColour(c.shadowColour, c.shadowOpacity);
        CGContextSetShadowWithColor(ctx, extents.shadowOffset, extents.shadowBlur, colour.get());
        CGContextBeginTransparencyLayer(ctx, nullptr); // the outline and every glyph cast one shadow
    }
    if (extents.outlineWidth > 0 && !CGPathIsEmpty(glyphs.outlines.get())) {
        CFRef<CGColorRef> colour = srgbColour(c.outlineColour, 1.0);
        CGContextSetStrokeColorWithColor(ctx, colour.get());
        CGContextSetLineWidth(ctx, 2.0 * extents.outlineWidth); // half of it outside the letter
        CGContextSetLineJoin(ctx, kCGLineJoinRound);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextAddPath(ctx, glyphs.outlines.get());
        CGContextStrokePath(ctx);
    }
    CFRef<CGColorRef> fill = srgbColour(c.fillColour, 1.0);
    if (!CGPathIsEmpty(glyphs.outlines.get())) {
        CGContextSetFillColorWithColor(ctx, fill.get());
        CGContextAddPath(ctx, glyphs.outlines.get());
        CGContextFillPath(ctx); // non-zero winding: overlapping glyphs and contours fill once
    }
    for (const GlyphDrawing::Bitmap &bitmap : glyphs.bitmaps) {
        CGContextSetFillColorWithColor(ctx, fill.get());
        CTFontDrawGlyphs(bitmap.font.get(), &bitmap.glyph, &bitmap.position, 1, ctx);
    }
    if (shadow) {
        CGContextEndTransparencyLayer(ctx);
    }
}

// The PostScript name of `font` as Core Text reports it.
std::string postScriptNameOf(CTFontRef font) {
    CFRef<CFStringRef> name = CFRef<CFStringRef>::adopt(CTFontCopyPostScriptName(font));
    return stdString(name.get());
}

std::string lowercased(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char ch) { return char(std::tolower(ch)); });
    std::erase(text, ' ');
    std::erase(text, '-');
    return text;
}

class TitleSource final : public GeneratedPictureSource {
  public:
    TitleSource(std::shared_ptr<const GeneratedContent> content, std::int32_t width, std::int32_t height, double k,
                std::uint32_t fontGeneration)
        : content_(std::move(content)), width_(width), height_(height),
          key_(generatedKeyFor(*content_, width, height, k, fontGeneration)) {}

    GeneratedKey key() const override {
        return key_;
    }
    bool isStatic() const override {
        return true;
    }
    CMTime frameDuration() const override {
        return kCMTimeInvalid;
    }
    OSType pixelFormat() const override {
        return kCVPixelFormatType_32BGRA;
    }
    Result<VideoFrame> render(CMTime, const DecodeOptions &options) const override {
        auto rendered = renderTitle(content_->title(), width_, height_, key_.scale(), options.interrupt.get());
        if (!rendered.ok()) {
            return std::move(rendered).error();
        }
        VideoFrame frame;
        frame.image = std::move(rendered.value().picture);
        return frame;
    }
    std::string description() const override {
        return "the title “" + titleDisplayName(content_->title()) + "”";
    }

  private:
    std::shared_ptr<const GeneratedContent> content_;
    std::int32_t width_;
    std::int32_t height_;
    GeneratedKey key_;
};

class MatteSource final : public GeneratedPictureSource {
  public:
    MatteSource(std::shared_ptr<const GeneratedContent> content, std::int32_t width, std::int32_t height)
        : content_(std::move(content)), width_(width), height_(height),
          key_(generatedKeyFor(*content_, width, height, 1.0, 0)) {}

    GeneratedKey key() const override {
        return key_;
    }
    bool isStatic() const override {
        return true;
    }
    CMTime frameDuration() const override {
        return kCMTimeInvalid;
    }
    OSType pixelFormat() const override {
        return kExtendedRGBAFormat;
    }
    Result<VideoFrame> render(CMTime, const DecodeOptions &options) const override {
        if (interrupted(options.interrupt.get())) {
            return cancelled();
        }
        auto picture = renderMatte(content_->matteColour(), width_, height_);
        if (!picture.ok()) {
            return std::move(picture).error();
        }
        VideoFrame frame;
        frame.image = std::move(picture).value();
        return frame;
    }
    std::string description() const override {
        return "a colour matte";
    }

  private:
    std::shared_ptr<const GeneratedContent> content_;
    std::int32_t width_;
    std::int32_t height_;
    GeneratedKey key_;
};

} // namespace

SystemFontWeight fallbackWeightFor(const TitleFont &font) {
    if (font.isSystem) {
        return font.weight;
    }
    const std::string style = lowercased(font.style.empty() ? font.postScriptName : font.style);
    // Longer names first: "semibold" before "bold", "extralight" before "light".
    static const std::array<std::pair<const char *, SystemFontWeight>, 13> kNames{{
        {"ultralight", SystemFontWeight::UltraLight},
        {"extralight", SystemFontWeight::UltraLight},
        {"hairline", SystemFontWeight::Thin},
        {"thin", SystemFontWeight::Thin},
        {"semibold", SystemFontWeight::Semibold},
        {"demibold", SystemFontWeight::Semibold},
        {"extrabold", SystemFontWeight::Heavy},
        {"ultrabold", SystemFontWeight::Heavy},
        {"heavy", SystemFontWeight::Heavy},
        {"black", SystemFontWeight::Black},
        {"light", SystemFontWeight::Light},
        {"medium", SystemFontWeight::Medium},
        {"bold", SystemFontWeight::Bold},
    }};
    for (const auto &[name, weight] : kNames) {
        if (style.find(name) != std::string::npos) {
            return weight;
        }
    }
    return SystemFontWeight::Regular;
}

ResolvedTitleFont resolveTitleFont(const TitleFont &font, double pointSize) {
    ResolvedTitleFont resolved;
    if (font.isSystem) {
        resolved.font = systemFont(font.weight, pointSize);
        return resolved;
    }
    CFRef<CFStringRef> name = cfString(font.postScriptName);
    if (name) {
        CFRef<CTFontRef> named = CFRef<CTFontRef>::adopt(CTFontCreateWithName(name.get(), pointSize, nullptr));
        // CTFontCreateWithName substitutes a font silently: only the name it reports says whether it found it.
        if (named && postScriptNameOf(named.get()) == font.postScriptName) {
            resolved.font = std::move(named);
            return resolved;
        }
    }
    resolved.missing = true;
    resolved.font = systemFont(fallbackWeightFor(font), pointSize);
    return resolved;
}

bool isTitleFontAvailable(const TitleFont &font) {
    return font.isSystem || !resolveTitleFont(font, 12.0).missing;
}

TitleBlockSize measureTitleBlock(const TitleContent &content, double canvasWidth, double canvasHeight) {
    const TextLines laid = layoutLines(content, canvasWidth, canvasHeight);
    return TitleBlockSize{laid.width, laid.height, laid.blockLeft, laid.blockTop};
}

// MARK: - The text layout (caret, selection, clicks)

TitleTextLayout TitleTextLayout::make(const TitleContent &content, double canvasWidth, double canvasHeight) {
    TextLines laid = layoutLines(content, canvasWidth, canvasHeight);
    TitleTextLayout layout;
    layout.text_ = laid.text;
    layout.length_ = laid.length;
    layout.fontSize_ = laid.fontSize;
    layout.block_ = CGRectMake(laid.blockLeft, laid.blockTop, laid.width, laid.height);
    layout.fontMissing_ = laid.fontMissing;
    for (std::size_t i = 0; i < laid.lines.size(); ++i) {
        Line line;
        line.start = laid.ranges[i].location;
        line.length = laid.ranges[i].length;
        line.baseline = laid.blockTop + laid.baselines[i];
        line.top = line.baseline - laid.ascents[i];
        line.bottom = line.baseline + laid.descents[i];
        line.leading = laid.leadings[i];
        line.left = laid.blockLeft + laid.penOffsets[i];
        line.width = CTLineGetTypographicBounds(laid.lines[i].get(), nullptr, nullptr, nullptr);
        if (line.length == 0) {
            line.width = 0; // the empty last line (a space, which is not text)
        }
        line.endsWithBreak =
            line.length > 0 &&
            CFCharacterSetIsCharacterMember(CFCharacterSetGetPredefined(kCFCharacterSetNewline),
                                            CFStringGetCharacterAtIndex(laid.text.get(), line.start + line.length - 1));
        layout.lineInfo_.push_back(line);
        layout.lines_.push_back(std::move(laid.lines[i]));
    }
    return layout;
}

std::size_t TitleTextLayout::lineOf(CFIndex index) const {
    if (lineInfo_.empty()) {
        return 0;
    }
    index = std::clamp<CFIndex>(index, 0, length_);
    for (std::size_t i = 0; i < lineInfo_.size(); ++i) {
        const Line &line = lineInfo_[i];
        if (index >= line.start && index < line.start + line.length) {
            return i;
        }
    }
    return lineInfo_.size() - 1; // the end of the text
}

double TitleTextLayout::offsetInLine(std::size_t i, CFIndex index) const {
    const Line &line = lineInfo_[i];
    if (line.length == 0) {
        return 0.0;
    }
    return CTLineGetOffsetForStringIndex(lines_[i].get(), std::clamp<CFIndex>(index, line.start, line.start + line.length),
                                         nullptr);
}

TitleTextLayout::Caret TitleTextLayout::caret(CFIndex index) const {
    Caret caret;
    if (lineInfo_.empty()) {
        caret.x = block_.origin.x;
        caret.top = block_.origin.y;
        caret.bottom = block_.origin.y + fontSize_;
        return caret;
    }
    const std::size_t i = lineOf(index);
    const Line &line = lineInfo_[i];
    caret.line = i;
    caret.x = line.left + offsetInLine(i, std::clamp<CFIndex>(index, 0, length_));
    caret.top = line.top;
    caret.bottom = line.bottom;
    return caret;
}

CFIndex TitleTextLayout::lastCaretIndexOf(std::size_t i) const {
    const Line &line = lineInfo_[i];
    const CFIndex end = line.start + line.length;
    if (i + 1 == lineInfo_.size() && !line.endsWithBreak) {
        return end; // the end of the text
    }
    if (line.length == 0) {
        return line.start;
    }
    // Before the line break, or (a line the box wrapped) before the character it wrapped after, which the caret
    // at `end` would show at the start of the next line.
    const CFRange last = CFStringGetRangeOfComposedCharactersAtIndex(text_.get(), end - 1);
    return std::max(line.start, last.location);
}

CFIndex TitleTextLayout::indexOnLine(std::size_t i, double x) const {
    if (lineInfo_.empty()) {
        return 0;
    }
    i = std::min(i, lineInfo_.size() - 1);
    const Line &line = lineInfo_[i];
    if (line.length == 0) {
        return line.start;
    }
    CFIndex index = CTLineGetStringIndexForPosition(lines_[i].get(), CGPointMake(x - line.left, 0.0));
    if (index == kCFNotFound) {
        index = line.start;
    }
    return std::clamp(index, line.start, lastCaretIndexOf(i));
}

CFIndex TitleTextLayout::indexAt(CGPoint point) const {
    if (lineInfo_.empty()) {
        return 0;
    }
    // The line whose band (its top to its bottom and leading) holds the point's y, else the nearest one.
    std::size_t best = 0;
    double bestDistance = std::numeric_limits<double>::infinity();
    for (std::size_t i = 0; i < lineInfo_.size(); ++i) {
        const Line &line = lineInfo_[i];
        const double top = line.top;
        const double bottom = line.bottom + line.leading;
        const double distance = point.y < top ? top - point.y : point.y > bottom ? point.y - bottom : 0.0;
        if (distance < bestDistance) {
            best = i;
            bestDistance = distance;
        }
    }
    return indexOnLine(best, point.x);
}

std::vector<CGRect> TitleTextLayout::selectionRects(CFIndex start, CFIndex end) const {
    std::vector<CGRect> rects;
    start = std::clamp<CFIndex>(start, 0, length_);
    end = std::clamp<CFIndex>(end, 0, length_);
    if (end <= start) {
        return rects;
    }
    for (std::size_t i = 0; i < lineInfo_.size(); ++i) {
        const Line &line = lineInfo_[i];
        const CFIndex lineEnd = line.start + line.length;
        if (line.length == 0 || end <= line.start || start >= lineEnd) {
            continue;
        }
        const double top = line.top;
        const double bottom = line.bottom + line.leading;
        // Glyph by glyph (a run of right-to-left text selects where its glyphs are), merged into spans. Each glyph's
        // cell starts at the caret before its character (its end, right to left) and is its advance wide, so the
        // selection's edges are the carets' (tracking puts half of its space on each side of a glyph: the glyph's own
        // position would shift the cell by half the tracking).
        std::vector<std::pair<double, double>> spans;
        CFArrayRef runs = CTLineGetGlyphRuns(lines_[i].get());
        std::vector<CFIndex> indices;
        std::vector<CGSize> advances;
        for (CFIndex r = 0; r < CFArrayGetCount(runs); ++r) {
            CTRunRef run = static_cast<CTRunRef>(CFArrayGetValueAtIndex(runs, r));
            const CFIndex count = CTRunGetGlyphCount(run);
            if (count <= 0) {
                continue;
            }
            const bool rightToLeft = (CTRunGetStatus(run) & kCTRunStatusRightToLeft) != 0;
            indices.resize(std::size_t(count));
            advances.resize(std::size_t(count));
            CTRunGetStringIndices(run, CFRangeMake(0, 0), indices.data());
            CTRunGetAdvances(run, CFRangeMake(0, 0), advances.data());
            for (CFIndex g = 0; g < count; ++g) {
                const CFIndex at = indices[std::size_t(g)];
                if (at < start || at >= end) {
                    continue;
                }
                // From the caret before the glyph's character to the caret after it (within a run they are its two
                // edges, whichever way it runs); where the caret after it is elsewhere (it starts a run of the other
                // direction), the glyph's advance from the caret before it.
                const CFIndex next = CFStringGetRangeOfComposedCharactersAtIndex(text_.get(), at).location +
                                     CFStringGetRangeOfComposedCharactersAtIndex(text_.get(), at).length;
                const double before = CTLineGetOffsetForStringIndex(lines_[i].get(), at, nullptr);
                const double after = CTLineGetOffsetForStringIndex(lines_[i].get(), std::min(next, lineEnd), nullptr);
                const double advance = std::max(0.0, double(advances[std::size_t(g)].width));
                if (std::abs(after - before) <= 1.5 * advance + 1.0) {
                    spans.emplace_back(std::min(before, after), std::max(before, after));
                } else {
                    spans.emplace_back(rightToLeft ? before - advance : before, rightToLeft ? before : before + advance);
                }
            }
        }
        // The line break itself (or a line the selection runs on past): a little beyond the line's end, as text views
        // show a selected line break.
        if (line.endsWithBreak && start <= lineEnd - 1 && end >= lineEnd) {
            const double x0 = line.width;
            spans.emplace_back(x0, x0 + 0.25 * fontSize_);
        }
        std::sort(spans.begin(), spans.end());
        std::vector<std::pair<double, double>> merged;
        for (const auto &span : spans) {
            if (!merged.empty() && span.first <= merged.back().second + 0.5) {
                merged.back().second = std::max(merged.back().second, span.second);
            } else {
                merged.push_back(span);
            }
        }
        for (const auto &[x0, x1] : merged) {
            if (x1 > x0) {
                rects.push_back(CGRectMake(line.left + x0, top, x1 - x0, bottom - top));
            }
        }
    }
    return rects;
}

Result<RenderedTitle> renderTitle(const TitleContent &content, double canvasWidth, double canvasHeight, double k,
                                  const DecodeInterrupt *interrupt) {
    if (!(canvasWidth > 0) || !(canvasHeight > 0) || !std::isfinite(canvasWidth) || !std::isfinite(canvasHeight)) {
        return makeError(MediaErrorCode::InvalidArgument, "a title needs a canvas of a positive size");
    }
    if (!std::isfinite(k) || !(k > 0)) {
        k = 1.0;
    }
    for (int attempt = 0;; ++attempt) {
        if (interrupted(interrupt)) {
            return cancelled();
        }
        const Layout layout = layoutTitle(content, canvasWidth, canvasHeight, k);
        if (interrupted(interrupt)) {
            return cancelled();
        }
        const Extents extents = extentsOf(content, layout, canvasHeight, k);
        Raster raster = rasterFor(layout, extents, k);
        RenderedTitle rendered;
        rendered.fontMissing = layout.fontMissing;
        rendered.rasterScale = k;
        if (raster.pixelsWide == 0) {
            // Nothing to draw (no text): a transparent picture of a few pixels at the block's centre.
            raster.left = layout.wrapWidth / k / 2.0 - 1.0;
            raster.top = -1.0;
            raster.pixelsWide = raster.pixelsHigh = 2;
            raster.width = raster.height = 2.0 / k;
        }
        const double side = double(std::max(raster.pixelsWide, raster.pixelsHigh));
        const double bytes = double(raster.pixelsWide) * double(raster.pixelsHigh) * 4.0;
        if ((side > kMaxRasterSide || bytes > kMaxRasterBytes) && attempt < 4) {
            // Too large a picture: draw it smaller (the compositor magnifies it).
            k *= std::min(kMaxRasterSide / side, std::sqrt(kMaxRasterBytes / bytes)) * 0.98;
            continue;
        }
        auto glyphs = glyphsOf(layout, interrupt);
        if (!glyphs.ok()) {
            return std::move(glyphs).error();
        }
        if (interrupted(interrupt)) {
            return cancelled();
        }
        auto picture = drawPicture(kCVPixelFormatType_32BGRA, raster.pixelsWide, raster.pixelsHigh, [&](CGContextRef ctx) {
            if (layout.lineCount() > 0) {
                drawTitle(ctx, content, layout, extents, glyphs.value(), raster, k);
            } else {
                CGContextClearRect(ctx, CGRectMake(0, 0, double(raster.pixelsWide), double(raster.pixelsHigh)));
            }
        });
        if (!picture.ok()) {
            return std::move(picture).error();
        }
        // Relative to the title's position (which the layer gives): the block lies at its anchor's offset from it.
        rendered.geometry = CanvasGeometry{canvasWidth,
                                           canvasHeight,
                                           layout.blockLeft + raster.left,
                                           layout.blockTop + raster.top,
                                           raster.width,
                                           raster.height};
        setCanvasGeometry(picture->get(), rendered.geometry);
        rendered.picture = std::move(picture).value();
        return rendered;
    }
}

Result<PixelBuffer> renderMatte(const SRGBColour &colour, double canvasWidth, double canvasHeight) {
    if (!(canvasWidth > 0) || !(canvasHeight > 0)) {
        return makeError(MediaErrorCode::InvalidArgument, "a matte needs a canvas of a positive size");
    }
    constexpr std::size_t kSide = 4;
    auto picture = drawPicture(kExtendedRGBAFormat, kSide, kSide, [&](CGContextRef ctx) {
        CFRef<CGColorRef> fill = srgbColour(colour, 1.0);
        CGContextSetBlendMode(ctx, kCGBlendModeCopy);
        CGContextSetFillColorWithColor(ctx, fill.get());
        CGContextFillRect(ctx, CGRectMake(0, 0, double(kSide), double(kSide)));
    });
    if (!picture.ok()) {
        return picture;
    }
    // The whole canvas (a matte's anchor is the canvas's top-left corner).
    setCanvasGeometry(picture->get(), CanvasGeometry{canvasWidth, canvasHeight, 0, 0, canvasWidth, canvasHeight});
    return picture;
}

double rasterScaleFor(double maxMotionScale, double outputScale) {
    const double motion = std::isfinite(maxMotionScale) && maxMotionScale >= 0 ? maxMotionScale : 1.0;
    const double output = std::isfinite(outputScale) && outputScale > 1.0 ? outputScale : 1.0;
    return std::max(1.0, motion * output);
}

namespace {
std::atomic<std::uint32_t> fontGenerationNow{1};
} // namespace

std::uint32_t titleFontGeneration() {
    return fontGenerationNow.load(std::memory_order_acquire);
}

std::uint32_t advanceTitleFontGeneration() {
    return fontGenerationNow.fetch_add(1, std::memory_order_acq_rel) + 1;
}

GeneratedKey generatedKeyFor(const GeneratedContent &content, std::int32_t canvasWidth, std::int32_t canvasHeight,
                             double k, std::uint32_t fontGeneration) {
    const ContentId id = contentIdOnCanvas(content.contentId(), canvasWidth, canvasHeight);
    if (content.isMatte()) {
        return GeneratedKey{id.high, id.low, 64u, 0};
    }
    return GeneratedKey{id.high, id.low, rasterScale64(k), fontGeneration};
}

std::shared_ptr<const GeneratedPictureSource> makeGeneratedSource(std::shared_ptr<const GeneratedContent> content,
                                                                  std::int32_t canvasWidth, std::int32_t canvasHeight,
                                                                  double k, std::uint32_t fontGeneration) {
    if (!content) {
        return nullptr;
    }
    if (content->isMatte()) {
        return std::make_shared<MatteSource>(std::move(content), canvasWidth, canvasHeight);
    }
    return std::make_shared<TitleSource>(std::move(content), canvasWidth, canvasHeight, k, fontGeneration);
}

} // namespace ve::media
