// The title and matte renderers (titles design, sections 3, 7 and 12; slice 1, item 5): determinism, the
// premultiplied tags, the outline outside the fill, the shadow scaling with the raster scale, emoji without an
// outline, an empty text, font resolution and substitution, the raster limits, the interrupt, the keys, and the
// performance estimates (measured and logged, not asserted).

#import <XCTest/XCTest.h>

#include "../../Engine/Media/TitleRenderer.h"
#include "../../Engine/Render/TextureCache.h"

#include <chrono>
#include <cmath>
#include <vector>

using namespace ve;
using namespace ve::media;

namespace {

/// The BGRA bytes of a 32BGRA buffer, row by row without padding.
struct Pixels {
    std::size_t width = 0;
    std::size_t height = 0;
    std::vector<uint8_t> bgra;

    const uint8_t *at(std::size_t x, std::size_t y) const { return &bgra[(y * width + x) * 4]; }
};

Pixels pixelsOf(const PixelBuffer &buffer) {
    Pixels p;
    CVPixelBufferRef pb = buffer.get();
    p.width = CVPixelBufferGetWidth(pb);
    p.height = CVPixelBufferGetHeight(pb);
    p.bgra.resize(p.width * p.height * 4);
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(pb));
    const std::size_t stride = CVPixelBufferGetBytesPerRow(pb);
    for (std::size_t y = 0; y < p.height; ++y) {
        std::memcpy(&p.bgra[y * p.width * 4], base + y * stride, p.width * 4);
    }
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    return p;
}

TitleContent plain(const char *text) {
    TitleContent content;
    content.text = text;
    content.shadow = false;
    return content;
}

RenderedTitle renderAt(const TitleContent &content, double k = 1.0, double width = 1920, double height = 1080) {
    auto rendered = renderTitle(content, width, height, k);
    if (!rendered.ok()) {
        return RenderedTitle{};
    }
    return std::move(rendered).value();
}

double msSince(std::chrono::steady_clock::time_point start) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
}

} // namespace

@interface TitleRendererTests : XCTestCase
@end

@implementation TitleRendererTests

- (void)testTheSameContentRendersTheSameBytes {
    TitleContent content = titlePreset(GeneratedPreset::LowerThird);
    content.outline = true;
    content.shadow = true;
    const RenderedTitle a = renderAt(content);
    const RenderedTitle b = renderAt(content);
    XCTAssertTrue(static_cast<bool>(a.picture) && static_cast<bool>(b.picture));
    XCTAssertTrue(a.picture != b.picture, @"two buffers");
    const Pixels pa = pixelsOf(a.picture), pb = pixelsOf(b.picture);
    XCTAssertEqual(pa.width, pb.width);
    XCTAssertEqual(pa.height, pb.height);
    XCTAssertTrue(pa.bgra == pb.bgra);
    XCTAssertTrue(a.geometry == b.geometry);
}

- (void)testThePictureIsPremultipliedSRGBAndWhiteIsExact {
    TitleContent content = plain("WHITE");
    content.size = 0.2;
    const RenderedTitle rendered = renderAt(content);
    XCTAssertTrue(static_cast<bool>(rendered.picture));
    if (!rendered.picture) {
        return;
    }
    CVPixelBufferRef pb = rendered.picture.get();
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), kCVPixelFormatType_32BGRA);
    XCTAssertTrue(alphaIsPremultiplied(pb, false), @"tagged premultiplied");
    CFTypeRef transfer = CVBufferCopyAttachment(pb, kCVImageBufferTransferFunctionKey, nullptr);
    XCTAssertTrue(transfer != nullptr && CFEqual(transfer, kCVImageBufferTransferFunction_sRGB));
    if (transfer != nullptr) {
        CFRelease(transfer);
    }
    const Pixels p = pixelsOf(rendered.picture);
    size_t opaque = 0;
    for (size_t y = 0; y < p.height; ++y) {
        for (size_t x = 0; x < p.width; ++x) {
            const uint8_t *px = p.at(x, y);
            XCTAssertTrue(px[0] <= px[3] && px[1] <= px[3] && px[2] <= px[3], @"premultiplied at %zu,%zu", x, y);
            if (px[3] == 255) {
                ++opaque;
                XCTAssertTrue(px[0] == 255 && px[1] == 255 && px[2] == 255, @"white text is 255 at %zu,%zu", x, y);
            }
        }
    }
    XCTAssertGreaterThan(opaque, size_t(1000));
    // The margin is transparent.
    for (size_t x = 0; x < p.width; ++x) {
        XCTAssertEqual(p.at(x, 0)[3], 0);
        XCTAssertEqual(p.at(x, p.height - 1)[3], 0);
    }
}

- (void)testTheOutlineIsOutsideTheFill {
    TitleContent fill = plain("Outline");
    fill.size = 0.15;
    fill.fillColour = SRGBColour{1.0, 0.8, 0.2};
    TitleContent outlined = fill;
    outlined.outline = true;
    outlined.outlineColour = SRGBColour{0.0, 0.0, 1.0};
    outlined.outlineWidth = 0.006;
    const RenderedTitle a = renderAt(fill), b = renderAt(outlined);
    const Pixels pa = pixelsOf(a.picture), pb = pixelsOf(b.picture);
    XCTAssertGreaterThan(pb.width, pa.width, @"the outline widens the picture");
    // The pictures lie at whole sequence pixels around the block: their offset is a whole number of pixels.
    const double dx = a.geometry.x - b.geometry.x, dy = a.geometry.y - b.geometry.y;
    XCTAssertEqual(dx, std::round(dx));
    XCTAssertEqual(dy, std::round(dy));
    size_t inside = 0, changed = 0, outlinePixels = 0;
    for (size_t y = 0; y < pa.height; ++y) {
        for (size_t x = 0; x < pa.width; ++x) {
            const uint8_t *fa = pa.at(x, y);
            const uint8_t *fb = pb.at(size_t(double(x) + dx), size_t(double(y) + dy));
            if (fa[3] == 255) {
                ++inside;
                if (std::memcmp(fa, fb, 4) != 0) {
                    ++changed;
                }
            }
        }
    }
    for (size_t i = 0; i < pb.width * pb.height; ++i) {
        const uint8_t *px = &pb.bgra[i * 4];
        outlinePixels += px[3] == 255 && px[0] == 255 && px[1] == 0 && px[2] == 0 ? 1 : 0; // opaque blue
    }
    XCTAssertGreaterThan(inside, size_t(5000));
    XCTAssertEqual(changed, size_t(0), @"turning the outline on leaves the fill's pixels as they were");
    XCTAssertGreaterThan(outlinePixels, size_t(1000), @"the outline is drawn");
}

- (void)testTheShadowScalesWithTheRasterScale {
    TitleContent content = plain("Shadow");
    content.size = 0.12;
    content.shadow = true;
    content.shadowColour = kBlack;
    content.shadowOpacity = 1.0;
    content.shadowDistance = 0.012;
    content.shadowBlur = 0.008;
    content.fillColour = kWhite;
    const RenderedTitle one = renderAt(content, 1.0);
    const RenderedTitle two = renderAt(content, 2.0);
    XCTAssertTrue(one.geometry == two.geometry, @"one canvas rectangle at both scales");
    const Pixels p1 = pixelsOf(one.picture), p2 = pixelsOf(two.picture);
    XCTAssertEqual(p2.width, p1.width * 2);
    XCTAssertEqual(p2.height, p1.height * 2);
    // The k = 2 picture box-downsampled to k = 1 against the k = 1 picture: the shadow's darkness (alpha where
    // the fill is not) and where its centre of mass lies.
    double sumDiff = 0, worst = 0;
    double mass1 = 0, mass2 = 0, cx1 = 0, cy1 = 0, cx2 = 0, cy2 = 0;
    for (size_t y = 0; y < p1.height; ++y) {
        for (size_t x = 0; x < p1.width; ++x) {
            double alpha2 = 0, grey2 = 0;
            for (int j = 0; j < 2; ++j) {
                for (int i = 0; i < 2; ++i) {
                    const uint8_t *px = p2.at(2 * x + size_t(i), 2 * y + size_t(j));
                    alpha2 += px[3] / 4.0;
                    grey2 += px[1] / 4.0;
                }
            }
            const uint8_t *px1 = p1.at(x, y);
            const double diff = std::fabs(px1[3] - alpha2);
            sumDiff += diff;
            worst = std::max(worst, diff);
            // Shadow alone: what is covered but not white.
            const double shadow1 = px1[3] - px1[1];
            const double shadow2 = alpha2 - grey2;
            mass1 += shadow1;
            cx1 += shadow1 * double(x);
            cy1 += shadow1 * double(y);
            mass2 += shadow2;
            cx2 += shadow2 * double(x);
            cy2 += shadow2 * double(y);
        }
    }
    const double mean = sumDiff / double(p1.width * p1.height);
    NSLog(@"TITLE shadow k=2 downsampled vs k=1: alpha differs by %.3f on average, at most %.1f; shadow centre "
          @"(%.2f, %.2f) vs (%.2f, %.2f), mass %.0f vs %.0f",
          mean, worst, cx2 / mass2, cy2 / mass2, cx1 / mass1, cy1 / mass1, mass2, mass1);
    XCTAssertLessThan(mean, 0.5); // 0.16 measured
    XCTAssertLessThan(worst, 24.0, @"anti-aliased edges differ a little (13 measured); a shadow at half its size differs far more");
    XCTAssertEqualWithAccuracy(cx2 / mass2, cx1 / mass1, 0.1, @"the shadow falls as far at both scales");
    XCTAssertEqualWithAccuracy(cy2 / mass2, cy1 / mass1, 0.1);
    XCTAssertEqualWithAccuracy(mass2 / mass1, 1.0, 0.01, @"as dark and as wide at both scales");
}

/// The width of the inked columns of `p` (alpha above a quarter), in its pixels.
static double inkWidth(const Pixels &p) {
    long first = -1, last = -1;
    for (std::size_t x = 0; x < p.width; ++x) {
        for (std::size_t y = 0; y < p.height; ++y) {
            if (p.at(x, y)[3] > 64) {
                if (first < 0) {
                    first = long(x);
                }
                last = long(x);
                break;
            }
        }
    }
    return first < 0 ? 0 : double(last - first + 1);
}

/// The system font's optical size follows its point size (SF Pro Text below about 20 points, Display above), so a
/// title rendered at k = 2 would use a larger point size, other glyph shapes and advances, and its lines could break
/// elsewhere than at k = 1 (review fix round, finding 5). The raster scale must only magnify: the k = 2 picture
/// box-downsampled is the k = 1 picture, and a wrap width that just fits one line at k = 1 gives one line at k = 2.
- (void)testTheRasterScaleMagnifiesWithoutChangingTheLayout {
    for (const double size : {0.012, 0.06}) {
        TitleContent content = plain("Wrap me where I just fit");
        content.size = size;
        content.font = TitleFont::system(SystemFontWeight::Regular);
        content.fillColour = kWhite;
        // The narrowest wrap width that keeps one line at k = 1.
        const double oneLine = renderAt(content, 1.0).geometry.height;
        double low = 0.02, high = 1.0;
        for (int i = 0; i < 30; ++i) {
            content.width = (low + high) / 2;
            (renderAt(content, 1.0).geometry.height > oneLine * 1.2 ? low : high) = content.width;
        }
        content.width = high;
        const RenderedTitle one = renderAt(content, 1.0);
        const RenderedTitle two = renderAt(content, 2.0);
        const Pixels p1 = pixelsOf(one.picture), p2 = pixelsOf(two.picture);
        double sumDiff = 0, worst = 0;
        const std::size_t w = std::min(p1.width, p2.width / 2), h = std::min(p1.height, p2.height / 2);
        for (std::size_t y = 0; y < h; ++y) {
            for (std::size_t x = 0; x < w; ++x) {
                double alpha2 = 0;
                for (int j = 0; j < 2; ++j) {
                    for (int i = 0; i < 2; ++i) {
                        alpha2 += p2.at(2 * x + std::size_t(i), 2 * y + std::size_t(j))[3] / 4.0;
                    }
                }
                const double diff = std::fabs(p1.at(x, y)[3] - alpha2);
                sumDiff += diff;
                worst = std::max(worst, diff);
            }
        }
        const double ink1 = inkWidth(p1), ink2 = inkWidth(p2) / 2;
        NSLog(@"TITLE optical size, size %.3f (%.1f px at k = 1), wrap %.4f: lines k1 %.1f px tall, k2 %.1f px; ink "
              @"width k1 %.1f, k2/2 %.1f; alpha k2 downsampled vs k1 mean %.3f, worst %.1f",
              size, size * 1080, content.width, one.geometry.height, two.geometry.height, ink1, ink2,
              sumDiff / double(w * h), worst);
        XCTAssertTrue(one.geometry == two.geometry, @"size %.3f: one block at both scales (the same lines)", size);
        XCTAssertEqualWithAccuracy(ink2, ink1, 1.5, @"size %.3f: the same glyph advances", size);
        XCTAssertLessThan(sumDiff / double(w * h), 1.0, @"size %.3f: the same glyphs, magnified", size);
    }
}

- (void)testEmojiDrawWithoutAnOutline {
    TitleContent emoji = plain("🎬");
    emoji.size = 0.2;
    emoji.outline = true;
    emoji.outlineColour = SRGBColour{1.0, 0.0, 1.0}; // magenta, which the clapper board does not have
    emoji.outlineWidth = 0.01;
    auto magentaPixels = [](const RenderedTitle &rendered) {
        const Pixels p = pixelsOf(rendered.picture);
        size_t count = 0;
        for (size_t i = 0; i < p.width * p.height; ++i) {
            const uint8_t *px = &p.bgra[i * 4];
            count += px[3] > 200 && px[2] > 200 && px[1] < 40 && px[0] > 200 ? 1 : 0;
        }
        return count;
    };
    auto colouredPixels = [](const RenderedTitle &rendered) {
        const Pixels p = pixelsOf(rendered.picture);
        size_t count = 0;
        for (size_t i = 0; i < p.width * p.height; ++i) {
            count += p.bgra[i * 4 + 3] > 200 ? 1 : 0;
        }
        return count;
    };
    const RenderedTitle alone = renderAt(emoji);
    XCTAssertGreaterThan(colouredPixels(alone), size_t(2000), @"the emoji is drawn");
    XCTAssertEqual(magentaPixels(alone), size_t(0), @"a colour glyph gets no outline");
    TitleContent mixed = emoji;
    mixed.text = "A🎬";
    XCTAssertGreaterThan(magentaPixels(renderAt(mixed)), size_t(500), @"a letter beside it does");
}

- (void)testAnEmptyTextGivesATransparentPicture {
    for (const char *text : {"", "\n"}) {
        TitleContent empty = plain(text);
        empty.box = true;
        empty.shadow = true;
        const RenderedTitle rendered = renderAt(empty);
        XCTAssertTrue(static_cast<bool>(rendered.picture));
        const Pixels p = pixelsOf(rendered.picture);
        for (size_t i = 0; i < p.width * p.height; ++i) {
            XCTAssertEqual(p.bgra[i * 4 + 3], 0);
        }
        XCTAssertTrue(rendered.geometry.isValid());
    }
    XCTAssertEqual(measureTitleBlock(plain(""), 1920, 1080).height, 0.0);
}

- (void)testFontsResolveAndAMissingFontFallsBackToTheSystemFontAtItsWeight {
    XCTAssertTrue(isTitleFontAvailable(TitleFont::system(SystemFontWeight::Semibold)));
    XCTAssertTrue(isTitleFontAvailable(TitleFont::named("Helvetica-Bold", "Helvetica", "Bold")));
    const TitleFont missing = TitleFont::named("NoSuchFont-Bold", "No Such Font", "Bold");
    XCTAssertFalse(isTitleFontAvailable(missing));
    XCTAssertEqual(fallbackWeightFor(missing), SystemFontWeight::Bold);
    XCTAssertEqual(fallbackWeightFor(TitleFont::named("X-SemiBold", "X", "SemiBold")), SystemFontWeight::Semibold);
    XCTAssertEqual(fallbackWeightFor(TitleFont::named("X-ExtraLight", "X", "Extra Light")), SystemFontWeight::UltraLight);
    XCTAssertEqual(fallbackWeightFor(TitleFont::named("X-Light", "X", "Light")), SystemFontWeight::Light);
    XCTAssertEqual(fallbackWeightFor(TitleFont::named("X-Italic", "X", "Italic")), SystemFontWeight::Regular);
    XCTAssertEqual(fallbackWeightFor(TitleFont::named("X-BlackItalic", "X", "")), SystemFontWeight::Black,
                   @"the PostScript name when the style is empty");
    // The system font's weights are different fonts.
    const ResolvedTitleFont regular = resolveTitleFont(TitleFont::system(SystemFontWeight::Regular), 40);
    const ResolvedTitleFont semibold = resolveTitleFont(TitleFont::system(SystemFontWeight::Semibold), 40);
    XCTAssertFalse(regular.missing || semibold.missing);
    CFStringRef regularName = CTFontCopyPostScriptName(regular.font.get());
    CFStringRef semiboldName = CTFontCopyPostScriptName(semibold.font.get());
    NSLog(@"TITLE system fonts: %@, %@", regularName, semiboldName);
    XCTAssertFalse(CFEqual(regularName, semiboldName), @"the weight trait reaches the system font");
    CFRelease(regularName);
    CFRelease(semiboldName);
    // A missing font draws exactly as the system font at its fallback weight, and says so.
    TitleContent named = plain("Fallback");
    named.font = missing;
    TitleContent system = named;
    system.font = TitleFont::system(SystemFontWeight::Bold);
    const RenderedTitle a = renderAt(named), b = renderAt(system);
    XCTAssertTrue(a.fontMissing);
    XCTAssertFalse(b.fontMissing);
    XCTAssertTrue(pixelsOf(a.picture).bgra == pixelsOf(b.picture).bgra);
    // An installed font is used as itself.
    TitleContent helvetica = named;
    helvetica.font = TitleFont::named("Helvetica-Bold", "Helvetica", "Bold");
    const RenderedTitle c = renderAt(helvetica);
    XCTAssertFalse(c.fontMissing);
    XCTAssertFalse(pixelsOf(c.picture).bgra == pixelsOf(b.picture).bgra);
    // Per-character fallback: Japanese typed in Helvetica draws in a font that has it.
    TitleContent japanese = helvetica;
    japanese.text = "日本語";
    const RenderedTitle d = renderAt(japanese);
    const Pixels pd = pixelsOf(d.picture);
    size_t ink = 0;
    for (size_t i = 0; i < pd.width * pd.height; ++i) {
        ink += pd.bgra[i * 4 + 3] > 128 ? 1 : 0;
    }
    XCTAssertGreaterThan(ink, size_t(500));
}

- (void)testTheBlockAndTheGeometryFollowTheTitlesPositionAndWidth {
    TitleContent one = plain("Line");
    const TitleBlockSize single = measureTitleBlock(one, 1920, 1080);
    XCTAssertEqualWithAccuracy(single.width, 0.8 * 1920, 1e-9);
    XCTAssertGreaterThan(single.height, 0.06 * 1080 * 0.9);
    TitleContent two = one;
    two.text = "Line\nLine";
    const TitleBlockSize twice = measureTitleBlock(two, 1920, 1080);
    XCTAssertEqualWithAccuracy(twice.height, 2 * single.height, 2.0);
    TitleContent spaced = two;
    spaced.lineSpacing = 2.0;
    XCTAssertGreaterThan(measureTitleBlock(spaced, 1920, 1080).height, twice.height * 1.3);
    // Wrapping: a long line in a narrow box takes more lines.
    TitleContent narrow = plain("A long title that wraps inside a narrow box");
    narrow.width = 0.2;
    XCTAssertGreaterThan(measureTitleBlock(narrow, 1920, 1080).height, 2.5 * single.height);
    // A centred title's picture is centred on its position (the block's centre), whatever the position.
    TitleContent centred = plain("Centred");
    centred.size = 0.1;
    const RenderedTitle a = renderAt(centred);
    const double centreX = a.geometry.x + a.geometry.width / 2.0;
    XCTAssertEqualWithAccuracy(centreX, 0.0, 3.0);
    TitleContent moved = centred;
    moved.x = 0.1;
    moved.y = 0.9;
    const RenderedTitle b = renderAt(moved);
    XCTAssertTrue(a.geometry == b.geometry, @"the position is not part of the picture");
    XCTAssertTrue(pixelsOf(a.picture).bgra == pixelsOf(b.picture).bgra);
    // Right alignment puts the ink at the block's right.
    TitleContent right = centred;
    right.alignment = TitleAlignment::Right;
    const RenderedTitle r = renderAt(right);
    XCTAssertGreaterThan(r.geometry.x + r.geometry.width, 0.8 * 1920 / 2.0 - 10.0);
    XCTAssertLessThan(r.geometry.x + r.geometry.width, 0.8 * 1920 / 2.0 + 10.0);
    // The box: wider than the ink by its padding.
    TitleContent boxed = centred;
    boxed.box = true;
    boxed.boxPadding = 0.05;
    const RenderedTitle box = renderAt(boxed);
    XCTAssertGreaterThan(box.geometry.width, a.geometry.width + 2 * 0.05 * 1080 - 6);
}

- (void)testTheRasterStaysWithinItsLimits {
    TitleContent page = plain("A full page of text at a large size that is drawn very large indeed, over and over.");
    page.size = 1.0;
    page.width = 4.0;
    const auto start = std::chrono::steady_clock::now();
    const RenderedTitle huge = renderAt(page, 8.0, 3840, 2160);
    NSLog(@"TITLE an over-large page: k 8 lowered to %.3f, %zu x %zu pixels, %.1f ms", huge.rasterScale,
          CVPixelBufferGetWidth(huge.picture.get()), CVPixelBufferGetHeight(huge.picture.get()), msSince(start));
    XCTAssertTrue(static_cast<bool>(huge.picture));
    XCTAssertLessThanOrEqual(CVPixelBufferGetWidth(huge.picture.get()), size_t(kMaxRasterSide));
    XCTAssertLessThanOrEqual(CVPixelBufferGetHeight(huge.picture.get()), size_t(kMaxRasterSide));
    XCTAssertLessThanOrEqual(double(CVPixelBufferGetWidth(huge.picture.get()) * CVPixelBufferGetHeight(huge.picture.get())) * 4.0,
                             kMaxRasterBytes);
    XCTAssertLessThan(huge.rasterScale, 8.0);
    // Its canvas rectangle is still the title's (the compositor magnifies the smaller raster).
    const RenderedTitle reference = renderAt(page, 1.0, 3840, 2160);
    // (Within a raster pixel's rounding at the lowered scale and the snap to whole sequence pixels.)
    XCTAssertEqualWithAccuracy(huge.geometry.width, reference.geometry.width, 1.0 / huge.rasterScale + 2.0);
}

- (void)testARequestedInterruptCancelsTheRender {
    auto interrupt = std::make_shared<DecodeInterrupt>();
    interrupt->request();
    auto rendered = renderTitle(plain("Interrupted"), 1920, 1080, 1.0, interrupt.get());
    XCTAssertFalse(rendered.ok());
    if (!rendered.ok()) {
        XCTAssertEqual(rendered.error().code, MediaErrorCode::Cancelled);
    }
}

- (void)testAMatteIsATinyExactPictureOfTheWholeCanvas {
    auto matte = renderMatte(SRGBColour{0.25, 0.5, 1.0}, 1920, 1080);
    XCTAssertTrue(matte.ok());
    if (!matte.ok()) {
        return;
    }
    CVPixelBufferRef pb = matte->get();
    XCTAssertEqual(CVPixelBufferGetPixelFormatType(pb), kExtendedRGBAFormat);
    XCTAssertEqual(CVPixelBufferGetWidth(pb), 4u);
    const auto geometry = canvasGeometryOf(pb);
    XCTAssertTrue(geometry.has_value() && *geometry == (CanvasGeometry{1920, 1080, 0, 0, 1920, 1080}));
    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
    const auto *half = static_cast<const __fp16 *>(CVPixelBufferGetBaseAddress(pb));
    XCTAssertEqual(double(half[0]), 0.25);
    XCTAssertEqual(double(half[1]), 0.5);
    XCTAssertEqual(double(half[2]), 1.0);
    XCTAssertEqual(double(half[3]), 1.0);
    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
}

- (void)testKeysAndSources {
    auto title = GeneratedContent::makeTitle(plain("Key"));
    const GeneratedKey key = generatedKeyFor(*title, 1920, 1080, 1.0, 1);
    XCTAssertEqual(key.scale64, 64u);
    XCTAssertTrue(key == generatedKeyFor(*GeneratedContent::makeTitle(plain("Key")), 1920, 1080, 1.0, 1));
    XCTAssertFalse(key == generatedKeyFor(*title, 3840, 2160, 1.0, 1), @"another frame size is another picture");
    XCTAssertFalse(key == generatedKeyFor(*title, 1920, 1080, 2.0, 1), @"another raster scale");
    TitleContent moved = plain("Key");
    moved.x = 0.2;
    XCTAssertTrue(key == generatedKeyFor(*GeneratedContent::makeTitle(moved), 1920, 1080, 1.0, 1), @"a drag renders nothing");
    TitleContent typed = plain("Kez");
    XCTAssertFalse(key == generatedKeyFor(*GeneratedContent::makeTitle(typed), 1920, 1080, 1.0, 1));
    auto matte = GeneratedContent::makeMatte(kBlack);
    XCTAssertTrue(generatedKeyFor(*matte, 1920, 1080, 1.0, 1) == generatedKeyFor(*matte, 1920, 1080, 3.0, 1),
                  @"a matte has no detail to sharpen");
    // A change of the Mac's fonts is a new key for a title (never for a matte, which has no text).
    XCTAssertFalse(key == generatedKeyFor(*title, 1920, 1080, 1.0, 2), @"other fonts, another picture");
    XCTAssertEqual(generatedKeyFor(*title, 1920, 1080, 1.0, 7).fontGeneration, 7u);
    XCTAssertTrue(generatedKeyFor(*matte, 1920, 1080, 1.0, 1) == generatedKeyFor(*matte, 1920, 1080, 1.0, 2));
    const std::uint32_t before = titleFontGeneration();
    XCTAssertEqual(advanceTitleFontGeneration(), before + 1);
    XCTAssertEqual(titleFontGeneration(), before + 1);
    // The sources render what their keys say.
    auto source = makeGeneratedSource(title, 1920, 1080, 1.5, 1);
    XCTAssertTrue(source->key() == generatedKeyFor(*title, 1920, 1080, 1.5, 1));
    XCTAssertTrue(source->isStatic());
    XCTAssertEqual(source->pixelFormat(), kCVPixelFormatType_32BGRA);
    auto frame = source->render(kCMTimeZero, DecodeOptions{});
    XCTAssertTrue(frame.ok());
    if (frame.ok()) {
        const auto geometry = canvasGeometryOf(frame->image.get());
        XCTAssertTrue(geometry.has_value());
        XCTAssertEqualWithAccuracy(double(CVPixelBufferGetWidth(frame->image.get())) / geometry->width, 1.5, 1e-9);
    }
    auto matteSource = makeGeneratedSource(matte, 1920, 1080, 1.0, 1);
    XCTAssertEqual(matteSource->pixelFormat(), kExtendedRGBAFormat);
    XCTAssertTrue(makeGeneratedSource(nullptr, 1920, 1080, 1.0, 1) == nullptr);
    XCTAssertEqual(source->description(), "the title “Key”");
}

- (void)testPerformanceEstimates {
    // Section 3's estimates: a 1080p lower third under 5 ms, a full-frame 4K page with a soft shadow in tens of
    // milliseconds. Measured (median of several renders after a warm-up) and logged, not asserted.
    auto median = [](std::vector<double> v) {
        std::sort(v.begin(), v.end());
        return v[v.size() / 2];
    };
    TitleContent lower = titlePreset(GeneratedPreset::LowerThird);
    lower.text = "Jane Doe\nDirector of Photography";
    renderAt(lower);
    std::vector<double> lowerTimes;
    for (int i = 0; i < 9; ++i) {
        const auto start = std::chrono::steady_clock::now();
        renderAt(lower);
        lowerTimes.push_back(msSince(start));
    }
    TitleContent page = plain("");
    for (int line = 0; line < 14; ++line) {
        page.text += "A credits line, with names and roles " + std::to_string(line) + "\n";
    }
    page.size = 0.05;
    page.width = 0.95;
    page.shadow = true;
    page.shadowBlur = 0.02;
    page.shadowDistance = 0.01;
    page.outline = true;
    renderAt(page, 1.0, 3840, 2160);
    std::vector<double> pageTimes;
    for (int i = 0; i < 5; ++i) {
        const auto start = std::chrono::steady_clock::now();
        renderAt(page, 1.0, 3840, 2160);
        pageTimes.push_back(msSince(start));
    }
    const RenderedTitle pagePicture = renderAt(page, 1.0, 3840, 2160);
    NSLog(@"TITLE performance: a 1080p lower third renders in %.2f ms (median of 9); a full 4K page with a soft "
          @"shadow and an outline (%zu x %zu pixels) in %.1f ms (median of 5)",
          median(lowerTimes), CVPixelBufferGetWidth(pagePicture.picture.get()),
          CVPixelBufferGetHeight(pagePicture.picture.get()), median(pageTimes));
}

@end
