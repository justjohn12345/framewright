#include "TitleRenderer.h"

#include "PictureDrawing.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <cstring>
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

// A title laid out at raster scale k, in the block's coordinates: raster pixels, y up, the block from (0, 0) to
// (wrapWidth, blockHeight), so its top is y = blockHeight (the "frame" Core Text's drawing works in).
//
// The lines are broken by a CTTypesetter at the wrap width (it stops at every paragraph separator, so Return
// makes a line) and placed here rather than by a CTFrame: each line takes (ascent + descent + leading) times the
// line spacing, the extra (or missing) part above its text, and its pen offset for the alignment
// (CTLineGetPenOffsetForFlush, which leaves trailing white space out). Core Text's own frames round their line
// heights to whole points, which would move the lines of one title differently at different raster scales;
// placed here, a title's layout scales exactly with k.
struct Layout {
    std::vector<CFRef<CTLineRef>> lines;
    std::vector<CGPoint> origins; // each line's baseline origin
    double fontSize = 0;
    double wrapWidth = 0;
    double blockHeight = 0;
    double frameHeight = 0; // == blockHeight (the block's top)
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
    Layout layout;
    layout.fontSize = std::max(0.01, c.size * canvasHeight * k);
    layout.wrapWidth = std::max(1.0, c.width * canvasWidth * k);
    ResolvedTitleFont resolved = resolveTitleFont(c.font, layout.fontSize);
    layout.fontMissing = resolved.missing;
    if (c.text.empty() || !resolved.font) {
        return layout;
    }
    CFRef<CFStringRef> text = cfString(c.text);
    if (!text) {
        return layout;
    }
    const CGFloat tracking = c.tracking / 1000.0 * layout.fontSize; // thousandths of an em, in points
    CFRef<CFNumberRef> trackingNumber = CFRef<CFNumberRef>::adopt(CFNumberCreate(nullptr, kCFNumberCGFloatType, &tracking));
    CFRef<CGColorRef> fill = srgbColour(c.fillColour, 1.0);
    const void *keys[] = {kCTFontAttributeName, kCTTrackingAttributeName, kCTForegroundColorAttributeName};
    const void *values[] = {resolved.font.get(), trackingNumber.get(), fill.get()};
    CFRef<CFDictionaryRef> attributes = CFRef<CFDictionaryRef>::adopt(
        CFDictionaryCreate(nullptr, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    CFRef<CFAttributedStringRef> attributed =
        CFRef<CFAttributedStringRef>::adopt(CFAttributedStringCreate(nullptr, text.get(), attributes.get()));
    CFRef<CTTypesetterRef> typesetter =
        CFRef<CTTypesetterRef>::adopt(CTTypesetterCreateWithAttributedString(attributed.get()));
    if (!typesetter) {
        return layout;
    }
    const double flush = c.alignment == TitleAlignment::Left ? 0.0 : c.alignment == TitleAlignment::Right ? 1.0 : 0.5;
    const CFIndex length = CFStringGetLength(text.get());
    struct Placed {
        double penOffset;
        double baselineDown; // from the block's top
    };
    std::vector<Placed> placed;
    double top = 0.0;
    for (CFIndex start = 0; start < length;) {
        CFIndex count = CTTypesetterSuggestLineBreak(typesetter.get(), start, layout.wrapWidth);
        if (count <= 0) {
            count = 1; // never stall on a glyph wider than the box
        }
        CFRef<CTLineRef> line = CFRef<CTLineRef>::adopt(CTTypesetterCreateLine(typesetter.get(), CFRangeMake(start, count)));
        start += count;
        if (!line) {
            continue;
        }
        CGFloat ascent = 0, descent = 0, leading = 0;
        CTLineGetTypographicBounds(line.get(), &ascent, &descent, &leading);
        const double natural = ascent + descent + leading;
        const double height = natural * c.lineSpacing;
        placed.push_back({CTLineGetPenOffsetForFlush(line.get(), flush, layout.wrapWidth),
                          top + height - descent - leading});
        top += height;
        layout.lines.push_back(std::move(line));
    }
    layout.blockHeight = top;
    layout.frameHeight = top;
    for (std::size_t i = 0; i < layout.lines.size(); ++i) {
        CTLineRef line = layout.lines[i].get();
        const CGPoint origin = CGPointMake(placed[i].penOffset, layout.frameHeight - placed[i].baselineDown);
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
            for (CFIndex g = 0; g < count; ++g) {
                const CGPoint at = CGPointMake(origin.x + positions[std::size_t(g)].x, origin.y + positions[std::size_t(g)].y);
                const CGAffineTransform place = CGAffineTransformMakeTranslation(at.x, at.y);
                CFRef<CGPathRef> path = CFRef<CGPathRef>::adopt(CTFontCreatePathForGlyph(font, glyphs[std::size_t(g)], &place));
                if (path) {
                    CGPathAddPath(drawing.outlines.get(), nullptr, path.get());
                } else if ((CTFontGetSymbolicTraits(font) & kCTFontTraitColorGlyphs) != 0) {
                    drawing.bitmaps.push_back({CFRef<CTFontRef>::retain(font), glyphs[std::size_t(g)], at});
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
    TitleSource(std::shared_ptr<const GeneratedContent> content, std::int32_t width, std::int32_t height, double k)
        : content_(std::move(content)), width_(width), height_(height),
          key_(generatedKeyFor(*content_, width, height, k)) {}

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
          key_(generatedKeyFor(*content_, width, height, 1.0)) {}

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
    const Layout layout = layoutTitle(content, canvasWidth, canvasHeight, 1.0);
    return TitleBlockSize{layout.wrapWidth, layout.lineCount() > 0 ? layout.blockHeight : 0.0};
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
        // Relative to the block's centre (the title's position, which the layer gives).
        const double blockWidth = layout.wrapWidth / k;
        const double blockHeight = layout.blockHeight / k;
        rendered.geometry = CanvasGeometry{canvasWidth,
                                           canvasHeight,
                                           raster.left - blockWidth / 2.0,
                                           raster.top - blockHeight / 2.0,
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

GeneratedKey generatedKeyFor(const GeneratedContent &content, std::int32_t canvasWidth, std::int32_t canvasHeight,
                             double k) {
    const ContentId id = contentIdOnCanvas(content.contentId(), canvasWidth, canvasHeight);
    return GeneratedKey{id.high, id.low, content.isTitle() ? rasterScale64(k) : 64u};
}

std::shared_ptr<const GeneratedPictureSource> makeGeneratedSource(std::shared_ptr<const GeneratedContent> content,
                                                                  std::int32_t canvasWidth, std::int32_t canvasHeight,
                                                                  double k) {
    if (!content) {
        return nullptr;
    }
    if (content->isMatte()) {
        return std::make_shared<MatteSource>(std::move(content), canvasWidth, canvasHeight);
    }
    return std::make_shared<TitleSource>(std::move(content), canvasWidth, canvasHeight, k);
}

} // namespace ve::media
