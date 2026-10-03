// Generated pictures in the compositor (titles design, sections 3 and 12; slice 1, item 6): a title picture stands
// for a frame-sized canvas and lands where its CanvasGeometry and the layer's anchor put it, texel for pixel when it
// is drawn at its raster scale (an export at the sequence's size at k = 1, a Motion zoom of 2 at k = 2, a 1080p export
// of a 720p-shaped sequence at k = 1.5), never sharpened, and in a half-size monitor as sharp as a Lanczos reduction
// of the full-size frame; a matte covers the whole frame with its colour.

#import <XCTest/XCTest.h>

#include "../../Engine/Media/TitleRenderer.h"
#include "../../Engine/Render/Compositor.h"
#include "../Media/TextCard.h"
#include "CompositorTestSupport.h"

#include <array>
#include <cmath>
#include <vector>

using namespace ve;
using namespace ve::render;
using namespace ve::rtest;
using ve::media::CanvasGeometry;
using ve::media::PixelBuffer;

namespace {

constexpr int32_t kWidth = 640;
constexpr int32_t kHeight = 360;

TitleContent sampleTitle() {
    TitleContent content;
    content.text = "Sharp Title\nsecond line";
    content.size = 0.09;
    content.x = 0.3013; // a fraction of a pixel off the grid
    content.y = 0.6;
    content.fillColour = SRGBColour{1.0, 0.85, 0.4};
    content.outline = true;
    content.outlineColour = SRGBColour{0.1, 0.1, 0.5};
    content.shadow = true;
    return content;
}

media::RenderedTitle rendered(const TitleContent &content, double k) {
    auto result = media::renderTitle(content, kWidth, kHeight, k);
    return result.ok() ? std::move(result).value() : media::RenderedTitle{};
}

/// A layer showing a title of `content` (its anchor at the title's position on a kWidth x kHeight frame).
VideoLayer titleLayer(const TitleContent &content) {
    VideoLayer layer = makeLayer(1);
    layer.isStill = true;
    layer.generated = GeneratedContent::makeTitle(content);
    layer.canvasAnchorX = content.x * kWidth;
    layer.canvasAnchorY = content.y * kHeight;
    return layer;
}

struct Image {
    size_t width = 0;
    size_t height = 0;
    std::vector<uint8_t> bgra;

    const uint8_t *at(size_t x, size_t y) const { return &bgra[(y * width + x) * 4]; }
};

Image imageOf(const PixelBuffer &buffer) {
    Image image;
    image.width = buffer.width();
    image.height = buffer.height();
    image.bgra.resize(image.width * image.height * 4);
    CVPixelBufferLockBaseAddress(buffer.get(), kCVPixelBufferLock_ReadOnly);
    const auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(buffer.get()));
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer.get());
    for (size_t y = 0; y < image.height; ++y) {
        std::memcpy(&image.bgra[y * image.width * 4], base + y * stride, image.width * 4);
    }
    CVPixelBufferUnlockBaseAddress(buffer.get(), kCVPixelBufferLock_ReadOnly);
    return image;
}

Image imageOf(id<MTLTexture> texture) {
    Image image;
    image.width = texture.width;
    image.height = texture.height;
    image.bgra.resize(image.width * image.height * 4);
    [texture getBytes:image.bgra.data()
          bytesPerRow:image.width * 4
           fromRegion:MTLRegionMake2D(0, 0, image.width, image.height)
          mipmapLevel:0];
    return image;
}

/// The largest difference (in codes, B G R) between the target and the picture placed with its top-left texel on
/// target pixel (left, top) over black (premultiplied colour is what shows over black), over the picture's texels
/// inside the target; and how many texels were compared.
struct Match {
    int worst = 0;
    size_t compared = 0;
    size_t coloured = 0; // compared texels that are not transparent
};

Match compareAt(const Image &target, const Image &picture, long left, long top) {
    Match m;
    for (size_t j = 0; j < picture.height; ++j) {
        for (size_t i = 0; i < picture.width; ++i) {
            const long x = left + long(i), y = top + long(j);
            if (x < 0 || y < 0 || x >= long(target.width) || y >= long(target.height)) {
                continue;
            }
            const uint8_t *t = target.at(size_t(x), size_t(y));
            const uint8_t *p = picture.at(i, j);
            for (int c = 0; c < 3; ++c) {
                m.worst = std::max(m.worst, std::abs(int(t[c]) - int(p[c])));
            }
            ++m.compared;
            m.coloured += p[3] > 0 ? 1 : 0;
        }
    }
    return m;
}

/// A whole-frame match: the picture placed at (left, top) and black elsewhere.
int worstOutside(const Image &target, const Image &picture, long left, long top) {
    int worst = 0;
    for (size_t y = 0; y < target.height; ++y) {
        for (size_t x = 0; x < target.width; ++x) {
            const long i = long(x) - left, j = long(y) - top;
            if (i >= 0 && j >= 0 && i < long(picture.width) && j < long(picture.height)) {
                continue;
            }
            const uint8_t *t = target.at(x, y);
            worst = std::max({worst, int(t[0]), int(t[1]), int(t[2])});
        }
    }
    return worst;
}

/// Lanczos-3 reduction of a grey image by 2 on each axis (each output pixel the a = 3 kernel stretched over the
/// source by 2, normalised): the reference a half-size monitor is compared with.
test::GrayImage lanczosHalf(const test::GrayImage &source) {
    auto lanczos = [](double x) {
        if (x == 0) {
            return 1.0;
        }
        if (std::fabs(x) >= 3) {
            return 0.0;
        }
        const double px = M_PI * x;
        return 3.0 * std::sin(px) * std::sin(px / 3.0) / (px * px);
    };
    const size_t w = source.width / 2, h = source.height / 2;
    std::vector<double> rows(w * source.height);
    for (size_t y = 0; y < source.height; ++y) {
        for (size_t x = 0; x < w; ++x) {
            const double centre = 2.0 * x + 1.0; // source position of the output pixel's centre
            double sum = 0, weights = 0;
            for (long i = long(centre) - 6; i <= long(centre) + 6; ++i) {
                const double weight = lanczos((double(i) + 0.5 - centre) / 2.0);
                const long clamped = std::clamp<long>(i, 0, long(source.width) - 1);
                sum += weight * source.at(size_t(clamped), y);
                weights += weight;
            }
            rows[y * w + x] = sum / weights;
        }
    }
    test::GrayImage out;
    out.width = w;
    out.height = h;
    out.pixels.resize(w * h);
    for (size_t y = 0; y < h; ++y) {
        for (size_t x = 0; x < w; ++x) {
            const double centre = 2.0 * y + 1.0;
            double sum = 0, weights = 0;
            for (long j = long(centre) - 6; j <= long(centre) + 6; ++j) {
                const double weight = lanczos((double(j) + 0.5 - centre) / 2.0);
                const long clamped = std::clamp<long>(j, 0, long(source.height) - 1);
                sum += weight * rows[size_t(clamped) * w + x];
                weights += weight;
            }
            out.pixels[y * w + x] = uint8_t(std::clamp(std::lround(sum / weights), 0L, 255L));
        }
    }
    return out;
}

test::GrayImage grayOf(const Image &image) {
    test::GrayImage gray;
    gray.width = image.width;
    gray.height = image.height;
    gray.pixels.resize(image.width * image.height);
    for (size_t i = 0; i < gray.pixels.size(); ++i) {
        const uint8_t *p = &image.bgra[i * 4];
        gray.pixels[i] = uint8_t(std::clamp(std::lround(0.2126 * p[2] + 0.7152 * p[1] + 0.0722 * p[0]), 0L, 255L));
    }
    return gray;
}

} // namespace

@interface CompositorGeneratedTests : XCTestCase
@end

@implementation CompositorGeneratedTests {
    std::unique_ptr<Compositor> _compositor;
}

- (void)setUp {
    auto created = Compositor::create(device());
    XCTAssertTrue(created.ok());
    if (created.ok()) {
        _compositor = std::move(created).value();
    }
}

/// Renders `layer` with `picture` into a new BGRA pixel buffer of `width` x `height` (an export's path).
- (Image)exportLayer:(const VideoLayer &)layer
             picture:(const PixelBuffer &)picture
               width:(size_t)width
              height:(size_t)height
              result:(RenderResult *)out {
    RenderGraph graph = makeGraph(kWidth, kHeight);
    graph.layers.push_back(layer);
    PixelBuffer target = makeBuffer(kCVPixelFormatType_32BGRA, width, height);
    auto result = renderLayers(*_compositor, graph, {texturesFor(*_compositor, picture)}, PixelBufferTarget{target});
    XCTAssertTrue(result.ok() && result->status.ok() && result->skippedLayers.empty());
    if (result.ok() && out != nullptr) {
        *out = result.value();
    }
    return imageOf(target);
}

- (void)testATitleAtTheSequencesSizeIsDrawnTexelForPixel {
    const TitleContent content = sampleTitle();
    const media::RenderedTitle title = rendered(content, 1.0);
    XCTAssertTrue(static_cast<bool>(title.picture));
    const VideoLayer layer = titleLayer(content);
    // Its corner: the anchor plus the geometry's offset, on a whole pixel.
    const long left = std::lround(layer.canvasAnchorX + title.geometry.x);
    const long top = std::lround(layer.canvasAnchorY + title.geometry.y);
    XCTAssertNotEqual(layer.canvasAnchorX + title.geometry.x, double(left), @"the position is off the pixel grid");
    const Image picture = imageOf(title.picture);
    RenderResult result;
    const Image exported = [self exportLayer:layer picture:title.picture width:kWidth height:kHeight result:&result];
    const Match match = compareAt(exported, picture, left, top);
    NSLog(@"TITLE 1:1 export: %zu texels compared (%zu coloured), worst %d codes", match.compared, match.coloured,
          match.worst);
    XCTAssertGreaterThan(match.coloured, size_t(2000));
    XCTAssertLessThanOrEqual(match.worst, 1, @"the renderer's picture, drawn directly");
    XCTAssertEqual(worstOutside(exported, picture, left, top), 0, @"transparent everywhere else");
    XCTAssertEqual(result.prescaledPlanes, 0u);
    // The monitor's path (a texture target through the working texture and the output pass) shows the same.
    RenderGraph graph = makeGraph(kWidth, kHeight);
    graph.layers.push_back(layer);
    id<MTLTexture> texture = makeTargetTexture(kWidth, kHeight);
    auto shown = renderLayers(*_compositor, graph, {texturesFor(*_compositor, title.picture)}, TextureTarget{texture, {}, nil});
    XCTAssertTrue(shown.ok() && shown->status.ok());
    XCTAssertLessThanOrEqual(compareAt(imageOf(texture), picture, left, top).worst, 1);
    // Moved: the same picture at another position, nothing rendered again.
    VideoLayer moved = layer;
    moved.canvasAnchorX += 50.4;
    moved.canvasAnchorY -= 20.6;
    const Image elsewhere = [self exportLayer:moved picture:title.picture width:kWidth height:kHeight result:nullptr];
    XCTAssertLessThanOrEqual(compareAt(elsewhere, picture, std::lround(moved.canvasAnchorX + title.geometry.x),
                                       std::lround(moved.canvasAnchorY + title.geometry.y))
                                 .worst,
                             1);
}

/// The luma-weighted mean column of `image`: where its content is, to a fraction of a pixel.
- (double)centroidX:(const Image &)image {
    double sum = 0;
    double weighted = 0;
    for (size_t y = 0; y < image.height; ++y) {
        for (size_t x = 0; x < image.width; ++x) {
            const uint8_t *p = image.at(x, y);
            const double luma = 0.0722 * p[0] + 0.7152 * p[1] + 0.2126 * p[2];
            sum += luma;
            weighted += luma * double(x);
        }
    }
    return sum > 0 ? weighted / sum : 0;
}

/// A title whose Motion moves it, drawn texel for pixel (review fix round, finding 3): each frame is at its exact
/// place, so a move of a third of a pixel moves the picture by a third of a pixel, not by none or a whole one (a
/// title snapped to the pixel grid on every frame steps instead of gliding, and jumps when a zoom ends texel for
/// pixel). A still title at the same place is snapped.
- (void)testAnAnimatedTitleIsNotSnappedToThePixelGrid {
    const TitleContent content = sampleTitle();
    const media::RenderedTitle title = rendered(content, 1.0);
    VideoLayer layer = titleLayer(content);
    layer.motionAnimated = true;
    const Image at0 = [self exportLayer:layer picture:title.picture width:kWidth height:kHeight result:nullptr];
    layer.transform.x = 1.0 / 3.0;
    const Image atThird = [self exportLayer:layer picture:title.picture width:kWidth height:kHeight result:nullptr];
    layer.transform.x = 2.0 / 3.0;
    const Image atTwoThirds = [self exportLayer:layer picture:title.picture width:kWidth height:kHeight result:nullptr];
    const double c0 = [self centroidX:at0];
    const double step1 = [self centroidX:atThird] - c0;
    const double step2 = [self centroidX:atTwoThirds] - c0;
    NSLog(@"TITLE animated by 1/3 px steps: moved %.3f and %.3f px", step1, step2);
    XCTAssertEqualWithAccuracy(step1, 1.0 / 3.0, 0.05);
    XCTAssertEqualWithAccuracy(step2, 2.0 / 3.0, 0.05);
    // Still, the same place is put on a whole pixel: the picture drawn directly.
    layer.motionAnimated = false;
    const Image still = [self exportLayer:layer picture:title.picture width:kWidth height:kHeight result:nullptr];
    const long left = std::lround(layer.canvasAnchorX + layer.transform.x + title.geometry.x);
    const long top = std::lround(layer.canvasAnchorY + title.geometry.y);
    XCTAssertLessThanOrEqual(compareAt(still, imageOf(title.picture), left, top).worst, 1);
}

- (void)testATitleZoomedByMotionIsDrawnAtItsRasterScale {
    TitleContent content = sampleTitle();
    content.x = 0.5;
    content.y = 0.5;
    const media::RenderedTitle title = rendered(content, 2.0);
    VideoLayer layer = titleLayer(content);
    layer.transform.scale = 2.0;
    const Image picture = imageOf(title.picture);
    RenderResult result;
    const Image exported = [self exportLayer:layer picture:title.picture width:kWidth height:kHeight result:&result];
    // A canvas point X lands at W/2 + 2 (X - W/2): the corner at 2 (anchor + offset) - W/2, put on a whole pixel.
    const long left = std::lround(2.0 * (layer.canvasAnchorX + title.geometry.x) - kWidth / 2.0);
    const long top = std::lround(2.0 * (layer.canvasAnchorY + title.geometry.y) - kHeight / 2.0);
    const Match match = compareAt(exported, picture, left, top);
    NSLog(@"TITLE zoomed x2 at k = 2: %zu texels compared (%zu coloured), worst %d codes", match.compared,
          match.coloured, match.worst);
    XCTAssertGreaterThan(match.coloured, size_t(2000));
    XCTAssertLessThanOrEqual(match.worst, 1);
    XCTAssertEqual(result.prescaledPlanes, 0u);
}

- (void)testALargerExportDrawsTheTitleAtItsRasterScale {
    const TitleContent content = sampleTitle();
    const media::RenderedTitle title = rendered(content, 1.5); // a 960x540 export of the 640x360 sequence
    const VideoLayer layer = titleLayer(content);
    const Image picture = imageOf(title.picture);
    const Image exported = [self exportLayer:layer picture:title.picture width:960 height:540 result:nullptr];
    const long left = std::lround(1.5 * (layer.canvasAnchorX + title.geometry.x));
    const long top = std::lround(1.5 * (layer.canvasAnchorY + title.geometry.y));
    const Match match = compareAt(exported, picture, left, top);
    NSLog(@"TITLE 1.5x export at k = 1.5: %zu texels compared (%zu coloured), worst %d codes", match.compared,
          match.coloured, match.worst);
    XCTAssertGreaterThan(match.coloured, size_t(3000));
    XCTAssertLessThanOrEqual(match.worst, 1);
}

- (void)testAGeneratedPictureIsNeverSharpened {
    const TitleContent content = sampleTitle();
    const media::RenderedTitle title = rendered(content, 1.0);
    VideoLayer layer = titleLayer(content);
    layer.transform.scale = 0.4; // minified: Lanczos pre-scaled
    RenderResult generated;
    [self exportLayer:layer picture:title.picture width:kWidth height:kHeight result:&generated];
    XCTAssertEqual(generated.prescaledPlanes, 1u);
    XCTAssertEqual(generated.sharpenedPlanes, 0u, @"even with \"Sharpen scaled-down sources\" on");
    // The same picture on a layer that is not generated would be sharpened: the rule is the layer's.
    VideoLayer media = layer;
    media.generated.reset();
    RenderResult plain;
    [self exportLayer:media picture:title.picture width:kWidth height:kHeight result:&plain];
    XCTAssertEqual(plain.sharpenedPlanes, 1u);
}

/// The edge measure of `layer` showing `title` in a half-size monitor, and of a Lanczos-3 reduction of the full-size
/// frame (the reference), over the text's region.
- (std::pair<double, double>)halfSizeEdges:(const VideoLayer &)layer title:(const media::RenderedTitle &)title {
    RenderGraph graph = makeGraph(kWidth, kHeight);
    graph.layers.push_back(layer);
    id<MTLTexture> full = makeTargetTexture(kWidth, kHeight);
    id<MTLTexture> half = makeTargetTexture(kWidth / 2, kHeight / 2);
    const TextureSet textures = texturesFor(*_compositor, title.picture);
    XCTAssertTrue(renderLayers(*_compositor, graph, {textures}, TextureTarget{full, {}, nil}).ok());
    auto shown = renderLayers(*_compositor, graph, {textures}, TextureTarget{half, {}, nil});
    XCTAssertTrue(shown.ok());
    if (shown.ok()) {
        XCTAssertEqual(shown->prescaledPlanes, 1u);
        XCTAssertEqual(shown->sharpenedPlanes, 0u);
    }
    const test::GrayImage monitor = grayOf(imageOf(half));
    const test::GrayImage reference = lanczosHalf(grayOf(imageOf(full)));
    // The text's region (the box), in the half-size frame.
    const size_t x = size_t((layer.canvasAnchorX + title.geometry.x) / 2) + 4;
    const size_t y = size_t((layer.canvasAnchorY + title.geometry.y) / 2) + 4;
    const size_t w = size_t(title.geometry.width / 2) - 8;
    const size_t h = size_t(title.geometry.height / 2) - 8;
    return {test::edgeMeasure(monitor, x, y, w, h), test::edgeMeasure(reference, x, y, w, h)};
}

- (void)testAHalfSizeMonitorIsAsSharpAsALanczosReduction {
    TitleContent content = sampleTitle();
    content.text = "Small print 0123456789\nThe quick brown fox jumps";
    content.size = 0.05;
    content.shadow = false;
    content.outline = false;
    content.box = true;
    content.boxColour = kWhite;
    content.boxOpacity = 1.0;
    content.fillColour = kBlack;
    content.width = 0.9;
    content.x = 0.5;
    content.y = 0.5;
    const media::RenderedTitle title = rendered(content, 1.0);
    // The monitor reduces the picture with the Lanczos pre-scale and samples it where it lies: a still title is put
    // on the monitor's pixel grid, so it is as sharp as the reference whatever its position (here its corner on an
    // even canvas pixel, a whole monitor pixel, and one canvas pixel off, half a monitor pixel).
    VideoLayer onGrid = titleLayer(content);
    const double rx = onGrid.canvasAnchorX + title.geometry.x, ry = onGrid.canvasAnchorY + title.geometry.y;
    onGrid.canvasAnchorX += 2.0 * std::round(rx / 2.0) - rx;
    onGrid.canvasAnchorY += 2.0 * std::round(ry / 2.0) - ry;
    VideoLayer offGrid = onGrid;
    offGrid.canvasAnchorX += 1.0;
    offGrid.canvasAnchorY += 1.0;
    const auto [onShown, onReference] = [self halfSizeEdges:onGrid title:title];
    const auto [offShown, offReference] = [self halfSizeEdges:offGrid title:title];
    NSLog(@"TITLE half-size monitor: edge measure %.4f against the Lanczos reference's %.4f (%.1f %%) on the monitor's "
          @"pixel grid, %.4f against %.4f (%.1f %%) half a pixel off it",
          onShown, onReference, 100.0 * onShown / onReference, offShown, offReference, 100.0 * offShown / offReference);
    XCTAssertGreaterThan(onShown, 0.97 * onReference, @"the reference's sharpness");
    XCTAssertGreaterThan(offShown, 0.97 * offReference, @"also from half a monitor pixel off the grid");
    XCTAssertLessThan(onShown, 1.03 * onReference, @"not sharpened beyond it");
    XCTAssertLessThan(offShown, 1.03 * offReference);
    // A title whose Motion changes keeps its exact place (smooth), so half a pixel off the grid it is softer.
    VideoLayer moving = offGrid;
    moving.motionAnimated = true;
    const auto [movingShown, movingReference] = [self halfSizeEdges:moving title:title];
    NSLog(@"TITLE half-size monitor, Motion animated: %.4f against %.4f (%.1f %%)", movingShown, movingReference,
          100.0 * movingShown / movingReference);
    XCTAssertLessThan(movingShown, 0.9 * movingReference, @"(70 %% measured before the grid rule)");
}

- (void)testAMatteCoversTheWholeFrameWithItsColour {
    auto matte = media::renderMatte(SRGBColour{0.25, 0.5, 1.0}, kWidth, kHeight);
    XCTAssertTrue(matte.ok());
    if (!matte.ok()) {
        return;
    }
    VideoLayer layer = makeLayer(1);
    layer.isStill = true;
    layer.generated = GeneratedContent::makeMatte(SRGBColour{0.25, 0.5, 1.0});
    const Image exported = [self exportLayer:layer picture:matte.value() width:kWidth height:kHeight result:nullptr];
    int worst = 0;
    for (size_t i = 0; i < exported.width * exported.height; ++i) {
        const uint8_t *p = &exported.bgra[i * 4];
        worst = std::max({worst, std::abs(p[0] - 255), std::abs(p[1] - 128), std::abs(p[2] - 64)});
    }
    XCTAssertLessThanOrEqual(worst, 1, @"every pixel the matte's colour (0.25, 0.5, 1.0 as 64, 128, 255)");
    // At half its scale it covers the frame's central quarter, as a frame-sized still would.
    layer.transform.scale = 0.5;
    const Image half = [self exportLayer:layer picture:matte.value() width:kWidth height:kHeight result:nullptr];
    XCTAssertEqual(half.at(kWidth / 2, kHeight / 2)[2], 64);
    XCTAssertEqual(half.at(10, 10)[2], 0);
    XCTAssertEqual(half.at(kWidth / 4 + 2, kHeight / 4 + 2)[2], 64);
    XCTAssertEqual(half.at(kWidth / 4 - 2, kHeight / 4 - 2)[2], 0);
}

- (void)testColoursAreExactInTheExportsFormats {
    // What the export hands its encoder: the compositor's conversion into 'x420' and '420v' (BT.709, video range).
    // White text and a white matte are video white (940 / 235, chroma 512 / 128), black is 64 / 16, and an sRGB
    // colour is its BT.709 encoding to within one code: a matte's exactly (its picture is half float), a title's as
    // its 8-bit picture holds it (each component to the nearest 255th).
    auto encode10 = [](const SRGBColour &c) {
        const double y = 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue;
        return std::array<double, 3>{64.0 + 876.0 * y, 512.0 + 896.0 * (c.blue - y) / 1.8556,
                                     512.0 + 896.0 * (c.red - y) / 1.5748};
    };
    auto centre = [](const PixelBuffer &buffer) {
        const bool ten = media::isTenBitPixelFormat(buffer.pixelFormat());
        CVPixelBufferLockBaseAddress(buffer.get(), kCVPixelBufferLock_ReadOnly);
        auto at = [&](size_t plane, size_t x, size_t y, size_t component, size_t components) {
            const auto *row = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(buffer.get(), plane)) +
                              y * CVPixelBufferGetBytesPerRowOfPlane(buffer.get(), plane);
            if (!ten) {
                return double(row[x * components + component]);
            }
            uint16_t v;
            std::memcpy(&v, row + (x * components + component) * 2, 2);
            return double(v >> 6);
        };
        const std::array<double, 3> codes{at(0, kWidth / 2, kHeight / 2, 0, 1), at(1, kWidth / 4, kHeight / 4, 0, 2),
                                          at(1, kWidth / 4, kHeight / 4, 1, 2)};
        CVPixelBufferUnlockBaseAddress(buffer.get(), kCVPixelBufferLock_ReadOnly);
        return codes;
    };
    for (const SRGBColour colour : {kWhite, kBlack, SRGBColour{0.25, 0.5, 1.0}, SRGBColour{0.8, 0.3, 0.1}}) {
        auto matte = media::renderMatte(colour, kWidth, kHeight);
        XCTAssertTrue(matte.ok());
        if (!matte.ok()) {
            return;
        }
        VideoLayer layer = makeLayer(1);
        layer.isStill = true;
        layer.generated = GeneratedContent::makeMatte(colour);
        // A title's fill over the same colour: a large block letter's inside is the fill colour exactly.
        TitleContent big;
        big.text = "\u2588"; // a full block
        big.size = 0.6;
        big.shadow = false;
        big.fillColour = colour;
        const media::RenderedTitle title = rendered(big, 1.0);
        VideoLayer titleOver = titleLayer(big);
        for (const OSType format :
             {kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange}) {
            const double scale = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ? 1.0 : 0.25;
            const SRGBColour eightBit{std::round(colour.red * 255) / 255, std::round(colour.green * 255) / 255,
                                      std::round(colour.blue * 255) / 255};
            for (const bool useTitle : {false, true}) {
                const std::array<double, 3> expected = encode10(useTitle ? eightBit : colour);
                RenderGraph graph = makeGraph(kWidth, kHeight);
                graph.layers.push_back(useTitle ? titleOver : layer);
                PixelBuffer target = makeBuffer(format, kWidth, kHeight);
                auto result = renderLayers(*_compositor, graph,
                                           {texturesFor(*_compositor, useTitle ? title.picture : matte.value())},
                                           PixelBufferTarget{target});
                XCTAssertTrue(result.ok() && result->status.ok());
                const std::array<double, 3> codes = centre(target);
                for (int c = 0; c < 3; ++c) {
                    XCTAssertEqualWithAccuracy(codes[size_t(c)], expected[size_t(c)] * scale, 1.0,
                                               @"%s of (%.2f, %.2f, %.2f), %s, component %d",
                                               useTitle ? "a title's fill" : "a matte", colour.red, colour.green,
                                               colour.blue, scale == 1.0 ? "x420" : "420v", c);
                }
            }
        }
    }
}

@end
