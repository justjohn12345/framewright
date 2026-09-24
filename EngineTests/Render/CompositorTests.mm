// Compositor pixel tests: identity, opacity blending, YCbCr matrices, transforms, dissolves,
// letterboxing, export targets, missing pictures, and steady-state performance/memory.

#import <XCTest/XCTest.h>

#include "../../Engine/Media/ColorTags.h"
#include "../../Engine/Render/Compositor.h"
#include "../Media/BurnIn.h"
#include "../Media/RouterTestSupport.h"
#include "../Media/TestMedia.h"
#include "CompositorTestSupport.h"

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <condition_variable>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <tuple>
#include <vector>

using namespace ve;
using namespace ve::render;
using namespace ve::rtest;
using media::YCbCrMatrix;

namespace {

// Frame numbers of completed renders, in completion order.
struct FrameLog {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<uint64_t> frames;

    void add(uint64_t frame) {
        std::lock_guard<std::mutex> lock(mutex);
        frames.push_back(frame);
        changed.notify_all();
    }
    std::vector<uint64_t> snapshot() {
        std::lock_guard<std::mutex> lock(mutex);
        return frames;
    }
    void clear() {
        std::lock_guard<std::mutex> lock(mutex);
        frames.clear();
    }
    bool waitFor(size_t count) {
        std::unique_lock<std::mutex> lock(mutex);
        return changed.wait_for(lock, std::chrono::seconds(10), [&] { return frames.size() >= count; });
    }
};

} // namespace

@interface CompositorTests : XCTestCase
@end

@implementation CompositorTests {
    std::unique_ptr<Compositor> _compositor;
}

- (void)setUp {
    auto compositor = Compositor::create(device());
    XCTAssertTrue(compositor.ok(), @"%s", compositor.ok() ? "" : compositor.error().description().c_str());
    if (compositor.ok()) {
        _compositor = std::move(compositor).value();
    }
}

- (RenderResult)render:(const RenderGraph &)graph
              textures:(const std::vector<TextureSet> &)textures
                target:(const RenderTarget &)target {
    auto result = renderLayers(*_compositor, graph, textures, target);
    XCTAssertTrue(result.ok(), @"%s", result.ok() ? "" : result.error().description().c_str());
    if (!result.ok()) {
        return {};
    }
    XCTAssertTrue(result->status.ok(), @"%s", result->status.ok() ? "" : result->status.error().description().c_str());
    return std::move(result).value();
}

// (a) BGRA at identity: output equals input within 1/255.
- (void)testSingleBGRALayerAtIdentityIsExact {
    const size_t w = 320, h = 180;
    media::PixelBuffer source = makeBuffer(kCVPixelFormatType_32BGRA, w, h);
    {
        media::PixelBufferLock lock(source.get(), false);
        auto *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(source.get()));
        const size_t stride = CVPixelBufferGetBytesPerRow(source.get());
        for (size_t y = 0; y < h; ++y) {
            for (size_t x = 0; x < w; ++x) {
                uint8_t *p = base + y * stride + x * 4;
                p[0] = static_cast<uint8_t>((x * 7 + y * 3) & 0xFF);
                p[1] = static_cast<uint8_t>((x * 5 + y * 11) & 0xFF);
                p[2] = static_cast<uint8_t>((x ^ y) & 0xFF);
                p[3] = 255;
            }
        }
    }
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, w, h);
    RenderGraph g = makeGraph(int32_t(w), int32_t(h));
    g.layers.push_back(makeLayer(1));
    RenderResult r = [self render:g textures:{texturesFor(*_compositor, source)} target:PixelBufferTarget{out}];
    XCTAssertEqual(r.drawnLayers, 1u);
    XCTAssertTrue(r.skippedLayers.empty());

    media::PixelBufferLock a(source.get(), true);
    media::PixelBufferLock b(out.get(), true);
    const auto *pa = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(source.get()));
    const auto *pb = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(out.get()));
    const size_t sa = CVPixelBufferGetBytesPerRow(source.get());
    const size_t sb = CVPixelBufferGetBytesPerRow(out.get());
    int maxDiff = 0;
    for (size_t y = 0; y < h; ++y) {
        for (size_t x = 0; x < w * 4; ++x) {
            maxDiff = std::max(maxDiff, std::abs(int(pa[y * sa + x]) - int(pb[y * sb + x])));
        }
    }
    XCTAssertLessThanOrEqual(maxDiff, 1);
}

// No layers: black.
- (void)testEmptyGraphIsBlack {
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
    fillBGRA(out, {200, 200, 200, 255});
    RenderResult r = [self render:makeGraph(64, 36) textures:{} target:PixelBufferTarget{out}];
    XCTAssertEqual(r.drawnLayers, 0u);
    XCTAssertTrue(near(pixelAt(out, 10, 10), 0, 0, 0, 0));
    XCTAssertEqual(pixelAt(out, 10, 10).a, 255);
}

// (b) Two 420v burn-in frames at 50 % opacity each.
- (void)testTwoBurnInLayersAtHalfOpacityBlend {
    const size_t w = 1920, h = 1080;
    const int indexA = 5;  // palette[5] = {150, 60, 160}; squares 13 and 15 white
    const int indexB = 10; // palette[2] = {60, 60, 200};  squares 12 and 14 white
    media::PixelBuffer a = makeBurnIn420v(indexA, w, h);
    media::PixelBuffer b = makeBurnIn420v(indexB, w, h);
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, w, h);
    RenderGraph g = makeGraph(int32_t(w), int32_t(h));
    g.layers.push_back(makeLayer(1, 0.5));
    g.layers.push_back(makeLayer(2, 0.5));
    [self render:g textures:{texturesFor(*_compositor, a), texturesFor(*_compositor, b)} target:PixelBufferTarget{out}];

    // Result = 0.5 B + 0.5 * (0.5 A) over black.
    const test::RGB pa = test::kBurnInPalette[indexA % 8];
    const test::RGB pb = test::kBurnInPalette[indexB % 8];
    const RGBA8 background = pixelAt(out, 960, 700);
    XCTAssertTrue(near(background, 0.5 * pb.r + 0.25 * pa.r, 0.5 * pb.g + 0.25 * pa.g, 0.5 * pb.b + 0.25 * pa.b, 3),
                  @"background %d %d %d", background.r, background.g, background.b);
    const double cell = double(w) / 18.0;
    auto squareCentre = [&](int i) { return pixelAt(out, size_t((i + 1.5) * cell), size_t(cell)); };
    const RGBA8 bothBlack = squareCentre(0);
    const RGBA8 onlyA = squareCentre(13);
    const RGBA8 onlyB = squareCentre(12);
    XCTAssertTrue(near(bothBlack, 0, 0, 0, 2), @"%d %d %d", bothBlack.r, bothBlack.g, bothBlack.b);
    XCTAssertTrue(near(onlyA, 63.75, 63.75, 63.75, 2), @"%d %d %d", onlyA.r, onlyA.g, onlyA.b);
    XCTAssertTrue(near(onlyB, 127.5, 127.5, 127.5, 2), @"%d %d %d", onlyB.r, onlyB.g, onlyB.b);
}

// (c) YCbCr -> RGB for each matrix, range and bit depth against a CPU reference.
- (void)testYCbCrMatricesRangesAndBitDepths {
    struct Case {
        OSType format;
        YCbCrMatrix matrix;
        int y, cb, cr;
    };
    const Case cases[] = {
        {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, YCbCrMatrix::BT709, 100, 90, 170},
        {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, YCbCrMatrix::BT601, 100, 90, 170},
        {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, YCbCrMatrix::BT2020, 150, 160, 100},
        {kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, YCbCrMatrix::BT709, 120, 100, 160},
        {kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, YCbCrMatrix::BT601, 120, 100, 160},
        {kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, YCbCrMatrix::BT709, 400, 360, 680},
        {kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, YCbCrMatrix::BT601, 400, 360, 680},
        {kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, YCbCrMatrix::BT709, 500, 420, 610},
        {kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, YCbCrMatrix::BT709, 700, 600, 400},
        {kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, YCbCrMatrix::BT601, 700, 600, 400},
        {kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, YCbCrMatrix::BT709, 300, 540, 480},
        {kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, YCbCrMatrix::BT2020, 520, 450, 560},
        // Black and white at video range limits.
        {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, YCbCrMatrix::BT709, 16, 128, 128},
        {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, YCbCrMatrix::BT709, 235, 128, 128},
        {kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, YCbCrMatrix::BT709, 940, 512, 512},
    };
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, 64, 64);
    for (const Case &c : cases) {
        const std::string name = fourCCString(c.format) + " matrix " + std::to_string(int(c.matrix));
        media::PixelBuffer source = makeBuffer(c.format, 64, 64);
        fillYCbCr(source, c.y, c.cb, c.cr, c.matrix);
        RenderGraph g = makeGraph(64, 64);
        g.layers.push_back(makeLayer(1));
        [self render:g textures:{texturesFor(*_compositor, source)} target:PixelBufferTarget{out}];
        const int depth = bitDepthOf(c.format);
        const RGBd ref = referenceRGB(c.y, c.cb, c.cr, depth, media::isFullRangeYCbCr(c.format), c.matrix);
        auto clamp255 = [](double v) { return std::clamp(v, 0.0, 255.0); };
        const RGBA8 p = pixelAt(out, 32, 32);
        XCTAssertTrue(near(p, clamp255(ref.r), clamp255(ref.g), clamp255(ref.b), 1.0),
                      @"%s: got %d %d %d expected %.2f %.2f %.2f", name.c_str(), p.r, p.g, p.b, ref.r, ref.g, ref.b);
    }
}

// Non-uniform fills: luma and chroma gradients, so a chroma sample drawn half a luma pixel off
// (wrong siting), a wrong subsampling or a wrong matrix shows up as a colour error. Every
// output pixel of a 1:1 render is compared with the CPU reference (bilinear chroma at the
// buffer's siting). Covers every siting, 4:2:0 / 4:2:2 / 4:4:4, 8 and 10 bit, video and full
// range, the BT.709 / BT.601 / BT.2020 / SMPTE 240M matrices, odd sizes, and untagged buffers
// (BT.709 from 720 lines up, BT.601 below; left-sited chroma).
- (void)testChromaSitingSubsamplingAndMatricesWithGradients {
    struct Case {
        OSType format;
        size_t width, height;
        std::optional<YCbCrMatrix> tagMatrix;
        std::optional<ChromaSiting> tagSiting;
        YCbCrMatrix expectedMatrix;
        ChromaSiting expectedSiting;
    };
    const OSType k420v = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    const OSType k420f = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    const OSType k422v = kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange;
    const OSType k444v = kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange;
    const OSType kx420 = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    const OSType kxf20 = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
    const OSType kx422 = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange;
    const OSType kx444 = kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange;
    const OSType kxf44 = kCVPixelFormatType_444YpCbCr10BiPlanarFullRange;
    using S = ChromaSiting;
    using M = YCbCrMatrix;
    const Case cases[] = {
        {k420v, 32, 16, M::BT709, S::Left, M::BT709, S::Left},
        {k420v, 32, 16, M::BT709, S::Center, M::BT709, S::Center},
        {k420v, 32, 16, M::BT709, S::TopLeft, M::BT709, S::TopLeft},
        {k420v, 32, 16, M::BT709, S::Top, M::BT709, S::Top},
        {k420v, 32, 16, M::BT709, S::BottomLeft, M::BT709, S::BottomLeft},
        {k420v, 32, 16, M::BT709, S::Bottom, M::BT709, S::Bottom},
        {k420v, 32, 16, M::BT709, std::nullopt, M::BT709, S::Left}, // untagged siting: left
        {k420v, 31, 15, M::BT601, S::Left, M::BT601, S::Left},      // odd sizes
        {k420v, 33, 17, M::BT709, S::Center, M::BT709, S::Center},
        {k420v, 32, 16, M::SMPTE240M, S::Left, M::SMPTE240M, S::Left},
        {k420v, 32, 16, M::BT2020, S::Left, M::BT2020, S::Left},
        {k420f, 32, 16, M::BT601, S::Center, M::BT601, S::Center},
        {k422v, 32, 16, M::BT709, S::Left, M::BT709, S::Left},
        {k422v, 32, 16, M::BT601, S::Center, M::BT601, S::Center},
        {k422v, 31, 16, M::BT709, S::TopLeft, M::BT709, S::TopLeft}, // vertical part ignored for 4:2:2
        {k444v, 32, 16, M::BT709, S::Left, M::BT709, S::Left},       // no siting at 4:4:4
        {kx420, 32, 16, M::BT2020, S::TopLeft, M::BT2020, S::TopLeft},
        {kxf20, 32, 16, M::BT709, S::Left, M::BT709, S::Left},
        {kxf20, 33, 15, M::SMPTE240M, S::Bottom, M::SMPTE240M, S::Bottom},
        {kx422, 32, 16, M::BT601, S::Left, M::BT601, S::Left},
        {kx444, 32, 16, M::BT709, std::nullopt, M::BT709, S::Left},
        {kxf44, 32, 16, M::BT2020, S::Center, M::BT2020, S::Center},
        // Untagged matrix: BT.709 from 720 lines up, BT.601 below.
        {k420v, 1280, 720, std::nullopt, S::Left, M::BT709, S::Left},
        {k420v, 1280, 719, std::nullopt, S::Left, M::BT601, S::Left},
        {kx420, 720, 576, std::nullopt, std::nullopt, M::BT601, S::Left},
    };
    for (const Case &c : cases) {
        const std::string name = fourCCString(c.format) + " " + std::to_string(c.width) + "x" +
                                 std::to_string(c.height) + " matrix " + std::to_string(int(c.expectedMatrix)) +
                                 " siting " + std::to_string(int(c.expectedSiting)) +
                                 (c.tagSiting ? "" : " (untagged siting)") + (c.tagMatrix ? "" : " (untagged matrix)");
        media::PixelBuffer source = makeBuffer(c.format, c.width, c.height);
        XCTAssertTrue(source, @"%s", name.c_str());
        if (!source) {
            continue;
        }
        const double s = bitDepthOf(c.format) == 8 ? 1.0 : 4.0;
        const double w = double(c.width), h = double(c.height);
        // Steep chroma gradients (a half-luma-pixel shift moves Cb by ~2 and Cr by ~3 8-bit codes)
        // that stay inside the R'G'B' cube, so no clamping hides an error.
        const double cw = double(CVPixelBufferGetWidthOfPlane(source.get(), 1));
        const double ch = double(CVPixelBufferGetHeightOfPlane(source.get(), 1));
        fillYCbCrPattern(
            source, [&](size_t x, size_t y) { return s * (80.0 + 40.0 * x / w + 30.0 * y / h); },
            [&](size_t i, size_t j) {
                return std::pair<double, double>{s * (96.0 + 74.0 * i / cw), s * (96.0 + 64.0 * j / ch)};
            });
        tagYCbCr(source, c.tagMatrix, c.tagSiting);
        const TextureSet set = texturesFor(*_compositor, source);
        const bool is444 = CVPixelBufferGetWidthOfPlane(source.get(), 1) == c.width;
        XCTAssertEqual(set.chromaSiting(), is444 ? S::Center : c.expectedSiting, @"%s", name.c_str());
        media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, c.width, c.height);
        RenderGraph g = makeGraph(int32_t(c.width), int32_t(c.height));
        g.layers.push_back(makeLayer(1));
        [self render:g textures:{set} target:PixelBufferTarget{out}];

        struct Worst {
            double error = 0;
            size_t x = 0, y = 0;
        };
        auto compare = [&](YCbCrMatrix matrix, ChromaSiting siting) {
            Worst worst;
            for (size_t y = 0; y < c.height; y += (c.height > 100 ? 5 : 1)) {
                for (size_t x = 0; x < c.width; x += (c.width > 100 ? 7 : 1)) {
                    const RGBd ref = referencePixel(source, x, y, matrix, siting);
                    const RGBA8 got = pixelAt(out, x, y);
                    const double err =
                        std::max({std::fabs(got.r - ref.r), std::fabs(got.g - ref.g), std::fabs(got.b - ref.b)});
                    if (err > worst.error) {
                        worst = {err, x, y};
                    }
                }
            }
            return worst;
        };
        const Worst worst = compare(c.expectedMatrix, c.expectedSiting);
        XCTAssertLessThanOrEqual(worst.error, 1.5, @"%s: worst error %.2f at (%zu, %zu)", name.c_str(), worst.error,
                                 worst.x, worst.y);
        if (c.format == k420v && c.width == 32 && c.expectedSiting == S::Left) {
            // The gradients are steep enough to see half a luma pixel of misplacement either way.
            XCTAssertGreaterThan(compare(c.expectedMatrix, S::Center).error, 1.5, @"%s: horizontal", name.c_str());
            XCTAssertGreaterThan(compare(c.expectedMatrix, S::TopLeft).error, 1.5, @"%s: vertical", name.c_str());
        }
    }
}

// (d) Scale 0.5 + offset lands at the expected pixels; rotation 90 moves the marker clockwise.
- (void)testScaleOffsetAndRotation {
    const RGBA8 white{255, 255, 255, 255};
    const RGBA8 red{255, 0, 0, 255};
    {
        media::PixelBuffer source = makeBuffer(kCVPixelFormatType_32BGRA, 1920, 1080);
        fillBGRA(source, white);
        fillBGRARect(source, 0, 0, 100, 100, red);
        media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, 1920, 1080);
        RenderGraph g = makeGraph(1920, 1080);
        VideoLayer layer = makeLayer(1);
        layer.transform.scale = 0.5;
        layer.transform.x = 200;
        layer.transform.y = 100;
        g.layers.push_back(layer);
        [self render:g textures:{texturesFor(*_compositor, source)} target:PixelBufferTarget{out}];
        // Centre (1160, 640), size 960x540: x in [680, 1640), y in [370, 910); marker [680,730)x[370,420).
        // At half size the picture is Lanczos-filtered (minification), so probes near the marker
        // stay 3+ pixels (the filter's reach) away from its edges.
        XCTAssertTrue(near(pixelAt(out, 681, 371), 255, 0, 0, 1));
        XCTAssertTrue(near(pixelAt(out, 726, 416), 255, 0, 0, 1));
        XCTAssertTrue(near(pixelAt(out, 734, 390), 255, 255, 255, 1));
        XCTAssertTrue(near(pixelAt(out, 700, 424), 255, 255, 255, 1));
        XCTAssertTrue(near(pixelAt(out, 679, 400), 0, 0, 0, 0));
        XCTAssertTrue(near(pixelAt(out, 700, 369), 0, 0, 0, 0));
        XCTAssertTrue(near(pixelAt(out, 1639, 909), 255, 255, 255, 1));
        XCTAssertTrue(near(pixelAt(out, 1640, 909), 0, 0, 0, 0));
        XCTAssertTrue(near(pixelAt(out, 1639, 910), 0, 0, 0, 0));
    }
    {
        media::PixelBuffer source = makeBuffer(kCVPixelFormatType_32BGRA, 1080, 1080);
        fillBGRA(source, white);
        fillBGRARect(source, 0, 0, 100, 100, red);
        media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, 1920, 1080);
        RenderGraph g = makeGraph(1920, 1080);
        VideoLayer layer = makeLayer(1);
        layer.transform.rotationDegrees = 90;
        g.layers.push_back(layer);
        [self render:g textures:{texturesFor(*_compositor, source)} target:PixelBufferTarget{out}];
        // Square occupies x in [420, 1500); the top-left marker moves to the top-right corner.
        XCTAssertTrue(near(pixelAt(out, 1450, 50), 255, 0, 0, 1));
        XCTAssertTrue(near(pixelAt(out, 470, 50), 255, 255, 255, 1));
        XCTAssertTrue(near(pixelAt(out, 470, 1030), 255, 255, 255, 1));
        XCTAssertTrue(near(pixelAt(out, 1450, 1030), 255, 255, 255, 1));
        XCTAssertTrue(near(pixelAt(out, 419, 540), 0, 0, 0, 0));
        XCTAssertTrue(near(pixelAt(out, 1500, 540), 0, 0, 0, 0));
    }
}

// Container rotation: the storage-orientation picture is turned clockwise by
// sourceRotationDegrees, fitted using the turned size, then the clip transform is applied. A red
// marker in the storage top-left corner and a green one in the storage top-right corner show
// where each corner lands (two markers also tell a rotation from a mirror).
- (void)testContainerRotationTurnsFitsThenTransforms {
    const RGBA8 white{255, 255, 255, 255};
    const RGBA8 red{255, 0, 0, 255};
    const RGBA8 green{0, 255, 0, 255};
    media::PixelBuffer source = makeBuffer(kCVPixelFormatType_32BGRA, 1280, 720);
    fillBGRA(source, white);
    fillBGRARect(source, 0, 0, 100, 100, red);
    fillBGRARect(source, 1180, 0, 1280, 100, green);
    const TextureSet bgra = texturesFor(*_compositor, source);
    const TextureSet yuv = texturesFor(*_compositor, convertBGRATo420v(source));

    struct Probe {
        size_t x, y;
        RGBA8 color;
    };
    auto check = [&](const TextureSet &set, int32_t rotation, double clipRotation, std::vector<Probe> probes,
                     double tolerance) {
        media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, 1920, 1080);
        RenderGraph g = makeGraph(1920, 1080);
        VideoLayer layer = makeLayer(1);
        layer.sourceRotationDegrees = rotation;
        layer.transform.rotationDegrees = clipRotation;
        g.layers.push_back(layer);
        [self render:g textures:{set} target:PixelBufferTarget{out}];
        for (const Probe &p : probes) {
            const RGBA8 got = pixelAt(out, p.x, p.y);
            XCTAssertTrue(near(got, p.color.r, p.color.g, p.color.b, tolerance),
                          @"rotation %d + clip %.0f, %s source, pixel (%zu, %zu): got %d %d %d expected %d %d %d",
                          rotation, clipRotation, fourCCString(set.pixelFormat()).c_str(), p.x, p.y, got.r, got.g,
                          got.b, p.color.r, p.color.g, p.color.b);
        }
    };
    const RGBA8 black{0, 0, 0, 255};
    // 0: 1280x720 fills the 1920x1080 frame (x1.5); markers stay in the top corners.
    check(bgra, 0, 0, {{20, 20, red}, {1900, 20, green}, {20, 1060, white}, {1900, 1060, white}}, 1);
    // 90: the picture is 720x1280 on screen, fitted to 607.5x1080 at x in [656.25, 1263.75):
    // pillarboxed; top-left -> top-right, top-right -> bottom-right.
    const std::vector<Probe> quarter{{1250, 40, red},    {1250, 1040, green}, {670, 40, white},
                                     {670, 1040, white}, {640, 540, black},   {1280, 540, black}};
    check(bgra, 90, 0, quarter, 1);
    check(bgra, 450, 0, quarter, 1);
    // 180: top-left -> bottom-right, top-right -> bottom-left.
    check(bgra, 180, 0, {{1900, 1060, red}, {20, 1060, green}, {20, 20, white}, {1900, 20, white}}, 1);
    // 270 (= -90): top-left -> bottom-left, top-right -> top-left.
    const std::vector<Probe> threeQuarters{{670, 1040, red},    {670, 40, green},   {1250, 40, white},
                                           {1250, 1040, white}, {640, 540, black}, {1280, 540, black}};
    check(bgra, 270, 0, threeQuarters, 1);
    check(bgra, -90, 0, threeQuarters, 1);
    // Container 90 then the clip's own 90 clockwise: the fitted 607.5x1080 portrait picture is
    // turned back to landscape (1080 x 607.5 at x in [420, 1500), y in [236.25, 843.75)), 180
    // in total: top-left -> bottom-right, top-right -> bottom-left.
    check(bgra, 90, 90, {{1490, 834, red}, {430, 834, green}, {430, 246, white}, {1490, 246, white},
                          {960, 230, black}, {960, 850, black}}, 1);
    // A YCbCr source turns the same way (both planes are sampled at the turned uv).
    check(yuv, 90, 0, quarter, 4);
}

- (void)addDissolvePairTo:(RenderGraph &)g mix:(double)mix {
    VideoLayer outgoing = makeLayer(1);
    VideoLayer incoming = makeLayer(2);
    LayerTransition t;
    t.transitionId = SpanId{77};
    t.mix = mix;
    t.isIncoming = false;
    t.partnerClipId = incoming.clipId;
    t.partnerLayerIndex = g.layers.size() + 1;
    outgoing.transition = t;
    t.isIncoming = true;
    t.partnerClipId = outgoing.clipId;
    t.partnerLayerIndex = g.layers.size();
    incoming.transition = t;
    g.layers.push_back(outgoing);
    g.layers.push_back(incoming);
}

// (e) Dissolve mix 0, 0.5, 1; and no dip when dissolving between transparent layers.
- (void)testDissolveMix {
    media::PixelBuffer red = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
    media::PixelBuffer blue = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
    fillBGRA(red, {255, 0, 0, 255});
    fillBGRA(blue, {0, 0, 255, 255});
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
    for (double mix : {0.0, 0.5, 1.0}) {
        RenderGraph g = makeGraph(64, 36);
        [self addDissolvePairTo:g mix:mix];
        RenderResult r = [self render:g
                             textures:{texturesFor(*_compositor, red), texturesFor(*_compositor, blue)}
                               target:PixelBufferTarget{out}];
        XCTAssertEqual(r.drawnLayers, 2u);
        const RGBA8 p = pixelAt(out, 30, 20);
        XCTAssertTrue(near(p, 255 * (1 - mix), 0, 255 * mix, 1), @"mix %.1f: %d %d %d", mix, p.r, p.g, p.b);
    }

    // Two identical half-transparent layers (premultiplied gray 0.5 at alpha 0.5): a correct
    // one-pass dissolve at 0.5 equals the single layer (64); layering them would give ~56.
    media::PixelBuffer translucent = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
    fillBGRA(translucent, {64, 64, 64, 128});
    tagAlpha(translucent, AlphaMode::Premultiplied);
    RenderGraph g = makeGraph(64, 36);
    [self addDissolvePairTo:g mix:0.5];
    TextureSet t = texturesFor(*_compositor, translucent);
    [self render:g textures:{t, t} target:PixelBufferTarget{out}];
    const RGBA8 p = pixelAt(out, 30, 20);
    XCTAssertTrue(near(p, 64, 64, 64, 1), @"%d %d %d", p.r, p.g, p.b);

    // Partner missing: the present layer is drawn alone with its transition weight.
    RenderGraph lone = makeGraph(64, 36);
    [self addDissolvePairTo:lone mix:0.25];
    RenderResult r = [self render:lone textures:{texturesFor(*_compositor, red), TextureSet{}}
                           target:PixelBufferTarget{out}];
    XCTAssertEqual(r.skippedLayers.size(), 1u);
    XCTAssertTrue(near(pixelAt(out, 30, 20), 255 * 0.75, 0, 0, 1));
}

// Straight vs premultiplied alpha: a 50 %-alpha red layer over opaque blue gives half red,
// half blue whichever way its colour is stored, as long as the compositor knows which. Tagged
// buffers follow the tag; untagged ones are straight for video and premultiplied for stills.
// Straight pictures are premultiplied per texel before filtering: magnifying one whose
// transparent texels carry green shows no green fringe.
- (void)testStraightAndPremultipliedAlpha {
    media::PixelBuffer blue = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
    fillBGRA(blue, {0, 0, 255, 255});
    media::PixelBuffer straight = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
    fillBGRA(straight, {255, 0, 0, 128}); // red at alpha 128/255, colour not multiplied
    media::PixelBuffer premultiplied = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
    fillBGRA(premultiplied, {128, 0, 0, 128}); // the same pixel, premultiplied

    const double a = 128.0 / 255.0;
    const double expectedRed = 255.0 * a;       // 128
    const double expectedBlue = 255.0 * (1 - a); // 127
    struct Case {
        const char *name;
        const media::PixelBuffer *buffer;
        AlphaMode tag;
        bool isStill;
    };
    const Case cases[] = {
        {"straight, tagged, video", &straight, AlphaMode::Straight, false},
        {"straight, tagged, still", &straight, AlphaMode::Straight, true},
        {"straight, untagged, video", &straight, AlphaMode::Unspecified, false},
        {"premultiplied, tagged, video", &premultiplied, AlphaMode::Premultiplied, false},
        {"premultiplied, untagged, still", &premultiplied, AlphaMode::Unspecified, true},
    };
    for (const Case &c : cases) {
        tagAlpha(*c.buffer, c.tag);
        const TextureSet top = texturesFor(*_compositor, *c.buffer);
        XCTAssertEqual(top.alphaMode(), c.tag, @"%s", c.name);
        XCTAssertEqual(top.alphaIsPremultiplied(c.isStill), c.buffer == &premultiplied, @"%s", c.name);
        media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
        RenderGraph g = makeGraph(64, 36);
        g.layers.push_back(makeLayer(1));
        VideoLayer layer = makeLayer(2);
        layer.isStill = c.isStill;
        g.layers.push_back(layer);
        [self render:g textures:{texturesFor(*_compositor, blue), top} target:PixelBufferTarget{out}];
        const RGBA8 p = pixelAt(out, 30, 20);
        XCTAssertTrue(near(p, expectedRed, 0, expectedBlue, 1.5), @"%s: got %d %d %d", c.name, p.r, p.g, p.b);
    }

    // setAlphaMode overrides the tag (for producers that cannot tag); YCbCr stays opaque.
    tagAlpha(straight, AlphaMode::Premultiplied); // wrong tag
    TextureSet corrected = texturesFor(*_compositor, straight);
    corrected.setAlphaMode(AlphaMode::Straight);
    XCTAssertFalse(corrected.alphaIsPremultiplied(true));
    TextureSet yuv = texturesFor(*_compositor, makeBurnIn420v(1, 64, 36));
    yuv.setAlphaMode(AlphaMode::Straight);
    XCTAssertEqual(yuv.alphaMode(), AlphaMode::Premultiplied);

    // No fringe: a 4x2 straight picture, left half transparent green (colour without coverage),
    // right half opaque red, magnified 16x over black. Every output pixel is a shade of red.
    media::PixelBuffer edge = makeBuffer(kCVPixelFormatType_32BGRA, 4, 2);
    fillBGRARect(edge, 0, 0, 2, 2, {0, 255, 0, 0});
    fillBGRARect(edge, 2, 0, 4, 2, {255, 0, 0, 255});
    tagAlpha(edge, AlphaMode::Straight);
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, 64, 32);
    RenderGraph g = makeGraph(64, 32);
    g.layers.push_back(makeLayer(3));
    [self render:g textures:{texturesFor(*_compositor, edge)} target:PixelBufferTarget{out}];
    int maxGreen = 0;
    int minRedAtRight = 255;
    for (size_t y = 0; y < 32; ++y) {
        for (size_t x = 0; x < 64; ++x) {
            const RGBA8 p = pixelAt(out, x, y);
            maxGreen = std::max(maxGreen, int(p.g));
            if (x >= 40) {
                minRedAtRight = std::min(minRedAtRight, int(p.r));
            }
        }
    }
    XCTAssertLessThanOrEqual(maxGreen, 0, @"transparent texels bled their colour");
    XCTAssertGreaterThanOrEqual(minRedAtRight, 254);
    // Across the boundary (between output columns 31 and 32) coverage ramps linearly: pixel 32's
    // centre is 0.53125 of the way from texel 1 to texel 2, pixel 31's 0.46875.
    const RGBA8 right = pixelAt(out, 32, 16);
    const RGBA8 left = pixelAt(out, 31, 16);
    XCTAssertTrue(near(right, 0.53125 * 255, 0, 0, 1.5), @"%d %d %d", right.r, right.g, right.b);
    XCTAssertTrue(near(left, 0.46875 * 255, 0, 0, 1.5), @"%d %d %d", left.r, left.g, left.b);
}

// (f) A 4:3 source in a 16:9 sequence is pillarboxed; the sequence is letterboxed in the target.
- (void)testLetterbox {
    media::PixelBuffer source = makeBuffer(kCVPixelFormatType_32BGRA, 1440, 1080);
    fillBGRA(source, {0, 200, 0, 255});
    RenderGraph g = makeGraph(1920, 1080);
    g.layers.push_back(makeLayer(1));
    id<MTLTexture> target = makeTargetTexture(1920, 1080);
    [self render:g textures:{texturesFor(*_compositor, source)} target:TextureTarget{target, {}, nil}];
    // (1920 - 1440) / 2 = 240 px bars.
    XCTAssertTrue(near(texturePixel(target, 0, 540), 0, 0, 0, 0));
    XCTAssertTrue(near(texturePixel(target, 239, 540), 0, 0, 0, 0));
    XCTAssertTrue(near(texturePixel(target, 240, 540), 0, 200, 0, 1));
    XCTAssertTrue(near(texturePixel(target, 1679, 540), 0, 200, 0, 1));
    XCTAssertTrue(near(texturePixel(target, 1680, 540), 0, 0, 0, 0));
    XCTAssertTrue(near(texturePixel(target, 1919, 540), 0, 0, 0, 0));
    XCTAssertTrue(near(texturePixel(target, 960, 0), 0, 200, 0, 1));
    XCTAssertTrue(near(texturePixel(target, 960, 1079), 0, 200, 0, 1));

    // 16:9 sequence in a square target: fitRect gives a 1000x563 viewport at y = 218.
    const PixelRect fitted = fitRect(1920, 1080, 1000, 1000);
    XCTAssertEqual(fitted, (PixelRect{0, 218, 1000, 563}));
    media::PixelBuffer full = makeBuffer(kCVPixelFormatType_32BGRA, 1920, 1080);
    fillBGRA(full, {0, 0, 200, 255});
    id<MTLTexture> square = makeTargetTexture(1000, 1000);
    [self render:g textures:{texturesFor(*_compositor, full)} target:TextureTarget{square, {}, nil}];
    XCTAssertTrue(near(texturePixel(square, 500, 217), 0, 0, 0, 0));
    XCTAssertTrue(near(texturePixel(square, 500, 218), 0, 0, 200, 1));
    XCTAssertTrue(near(texturePixel(square, 500, 780), 0, 0, 200, 1));
    XCTAssertTrue(near(texturePixel(square, 500, 781), 0, 0, 0, 0));
}

// A caller's viewport may reach outside the texture: it is clipped (the scissor rectangle must
// lie inside the render target) and the frame is still mapped through the whole viewport.
- (void)testViewportOutsideTheTextureIsClipped {
    media::PixelBuffer source = makeBuffer(kCVPixelFormatType_32BGRA, 256, 144);
    fillBGRARect(source, 0, 0, 128, 144, {255, 0, 0, 255});
    fillBGRARect(source, 128, 0, 256, 144, {0, 255, 0, 255});
    RenderGraph g = makeGraph(256, 144);
    g.layers.push_back(makeLayer(1));
    const TextureSet set = texturesFor(*_compositor, source);
    id<MTLTexture> target = makeTargetTexture(256, 144);
    // Shifted half a frame left: the texture shows the green right half, then black.
    [self render:g textures:{set} target:TextureTarget{target, PixelRect{-128, 0, 256, 144}, nil}];
    XCTAssertTrue(near(texturePixel(target, 5, 70), 0, 255, 0, 1));
    XCTAssertTrue(near(texturePixel(target, 120, 70), 0, 255, 0, 1));
    XCTAssertTrue(near(texturePixel(target, 130, 70), 0, 0, 0, 0));
    XCTAssertTrue(near(texturePixel(target, 250, 70), 0, 0, 0, 0));
    // Larger than the texture on every side: the middle of the frame fills it.
    [self render:g textures:{set} target:TextureTarget{target, PixelRect{-256, -144, 768, 432}, nil}];
    XCTAssertTrue(near(texturePixel(target, 60, 70), 255, 0, 0, 1));
    XCTAssertTrue(near(texturePixel(target, 200, 70), 0, 255, 0, 1));
    // Entirely outside: nothing drawn, the texture is cleared.
    [self render:g textures:{set} target:TextureTarget{target, PixelRect{300, 0, 256, 144}, nil}];
    XCTAssertTrue(near(texturePixel(target, 128, 70), 0, 0, 0, 0));
}

// (g) Export targets: the burn-in survives 420v -> composite -> 420v (and -> BGRA).
- (void)testExportTargetsPreserveBurnIn {
    const int index = 1234;
    media::PixelBuffer source = makeBurnIn420v(index, 1920, 1080);
    XCTAssertEqual(test::readBurnIn(source.get()).value_or(-1), index);
    RenderGraph g = makeGraph(1920, 1080);
    g.layers.push_back(makeLayer(1));
    for (OSType format : {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_32BGRA}) {
        media::PixelBuffer out = makeBuffer(format, 1920, 1080);
        [self render:g textures:{texturesFor(*_compositor, source)} target:PixelBufferTarget{out}];
        XCTAssertEqual(test::readBurnIn(out.get()).value_or(-1), index, @"%s", fourCCString(format).c_str());
    }
    // The 420v output is tagged BT.709.
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 1920, 1080);
    [self render:g textures:{texturesFor(*_compositor, source)} target:PixelBufferTarget{out}];
    CFTypeRef matrix = CVBufferCopyAttachment(out.get(), kCVImageBufferYCbCrMatrixKey, nullptr);
    XCTAssertTrue(matrix != nullptr && CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2));
    if (matrix) {
        CFRelease(matrix);
    }

    // Unsupported target format is an error, not a silent no-op.
    media::PixelBuffer bad = makeBuffer(kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, 64, 64);
    auto result = renderLayers(*_compositor, g, {}, PixelBufferTarget{bad});
    XCTAssertFalse(result.ok());
    if (!result.ok()) {
        XCTAssertEqual(result.error().code, media::MediaErrorCode::UnsupportedFormat);
    }
}

// Export to 4:2:0 (video and full range, 8 and 10 bits, even and odd sizes): every luma sample
// and every chroma sample is checked against a CPU reference of the left-sited filter (the
// [1 2 1] / 4 horizontal filter around the block's left column, averaged over its rows, edges
// repeated), 10-bit samples are whole codes in the high bits (the low 6 bits zero), and the
// buffer is tagged BT.709 with left chroma siting. A BGRA target drops stale YCbCr tags.
- (void)testExport420ChromaIsLeftSitedFilteredAndTagged {
    for (OSType format : {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                          kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                          kCVPixelFormatType_420YpCbCr10BiPlanarFullRange}) {
        for (const auto &[w, h] : {std::pair<size_t, size_t>{64, 36}, std::pair<size_t, size_t>{63, 35}}) {
            const std::string name = fourCCString(format) + " " + std::to_string(w) + "x" + std::to_string(h);
            media::PixelBuffer source = makeBuffer(kCVPixelFormatType_32BGRA, w, h);
            {
                media::PixelBufferLock lock(source.get(), false);
                auto *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(source.get()));
                const size_t stride = CVPixelBufferGetBytesPerRow(source.get());
                for (size_t y = 0; y < h; ++y) {
                    for (size_t x = 0; x < w; ++x) {
                        uint8_t *p = base + y * stride + x * 4;
                        p[0] = static_cast<uint8_t>((x * 53 + y * 17) % 256); // B: sharp, varies per pixel
                        p[1] = static_cast<uint8_t>(40 + (x * 3 + y * 5) % 180);
                        p[2] = static_cast<uint8_t>((x % 2) ? 230 : 20); // R: one-pixel stripes
                        p[3] = 255;
                    }
                }
            }
            media::PixelBuffer out = makeBuffer(format, w, h);
            RenderGraph g = makeGraph(int32_t(w), int32_t(h));
            g.layers.push_back(makeLayer(1));
            [self render:g textures:{texturesFor(*_compositor, source)} target:PixelBufferTarget{out}];

            const bool full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                              format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
            const bool ten = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                             format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
            const double kr = 0.2126, kb = 0.0722, kg = 1.0 - kr - kb;
            const double step = ten ? 4.0 : 1.0, maxCode = ten ? 1023.0 : 255.0;
            const double ySpan = full ? maxCode : 219.0 * step, yBase = full ? 0.0 : 16.0 * step;
            const double cSpan = full ? maxCode : 224.0 * step, cBase = 128.0 * step;
            int lowBitsSet = 0;
            // Sample `index` of a plane row as an integer code (counts 10-bit samples with low bits set).
            auto code = [&](const uint8_t *row, size_t index) -> double {
                if (!ten) {
                    return row[index];
                }
                uint16_t v;
                std::memcpy(&v, row + index * 2, 2);
                lowBitsSet += (v & 0x3F) != 0;
                return v >> 6;
            };
            auto rgbAt = [&](size_t x, size_t y) {
                const RGBA8 p = pixelAt(source, x, y);
                return RGBd{p.r / 255.0, p.g / 255.0, p.b / 255.0};
            };
            media::PixelBufferLock lock(out.get(), true);
            const auto *luma = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(out.get(), 0));
            const auto *chroma = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(out.get(), 1));
            const size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(out.get(), 0);
            const size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(out.get(), 1);
            double worstLuma = 0, worstChroma = 0;
            for (size_t y = 0; y < h; ++y) {
                for (size_t x = 0; x < w; ++x) {
                    const RGBd c = rgbAt(x, y);
                    const double expected = yBase + ySpan * (kr * c.r + kg * c.g + kb * c.b);
                    worstLuma = std::max(worstLuma, std::fabs(code(luma + y * lumaStride, x) - expected));
                }
            }
            for (size_t j = 0; j < (h + 1) / 2; ++j) {
                for (size_t i = 0; i < (w + 1) / 2; ++i) {
                    RGBd sum{0, 0, 0};
                    int rows = 0;
                    for (size_t y = 2 * j; y < std::min(h, 2 * j + 2); ++y) {
                        const size_t x0 = 2 * i;
                        const RGBd centre = rgbAt(x0, y);
                        const RGBd left = x0 > 0 ? rgbAt(x0 - 1, y) : centre;
                        const RGBd right = x0 + 1 < w ? rgbAt(x0 + 1, y) : centre;
                        sum.r += 0.25 * left.r + 0.5 * centre.r + 0.25 * right.r;
                        sum.g += 0.25 * left.g + 0.5 * centre.g + 0.25 * right.g;
                        sum.b += 0.25 * left.b + 0.5 * centre.b + 0.25 * right.b;
                        ++rows;
                    }
                    const double r = sum.r / rows, gg = sum.g / rows, b = sum.b / rows;
                    const double yy = kr * r + kg * gg + kb * b;
                    const double cb = cBase + cSpan * (b - yy) / (2.0 * (1.0 - kb));
                    const double cr = cBase + cSpan * (r - yy) / (2.0 * (1.0 - kr));
                    const uint8_t *row = chroma + j * chromaStride;
                    worstChroma = std::max({worstChroma, std::fabs(code(row, i * 2) - cb),
                                            std::fabs(code(row, i * 2 + 1) - cr)});
                }
            }
            // Half-float intermediate: 10-bit codes may be off by one more step than 8-bit ones.
            XCTAssertLessThanOrEqual(worstLuma, ten ? 1.5 : 1.0, @"%s luma", name.c_str());
            XCTAssertLessThanOrEqual(worstChroma, ten ? 1.5 : 1.0, @"%s chroma", name.c_str());
            XCTAssertEqual(lowBitsSet, 0, @"%s: 10-bit samples must be whole codes", name.c_str());

            auto attachment = [&](CFStringRef key) {
                return media::CFRef<CFTypeRef>::adopt(CVBufferCopyAttachment(out.get(), key, nullptr));
            };
            auto top = attachment(kCVImageBufferChromaLocationTopFieldKey);
            auto bottom = attachment(kCVImageBufferChromaLocationBottomFieldKey);
            auto matrix = attachment(kCVImageBufferYCbCrMatrixKey);
            XCTAssertTrue(top && CFEqual(top.get(), kCVImageBufferChromaLocation_Left), @"%s", name.c_str());
            XCTAssertTrue(bottom && CFEqual(bottom.get(), kCVImageBufferChromaLocation_Left), @"%s", name.c_str());
            XCTAssertTrue(matrix && CFEqual(matrix.get(), kCVImageBufferYCbCrMatrix_ITU_R_709_2), @"%s", name.c_str());
            XCTAssertEqual(chromaSitingOf(out.get(), ChromaSiting::Center), ChromaSiting::Left);
        }
    }

    // A BGRA target (e.g. a recycled pool buffer) loses stale YCbCr tags.
    media::PixelBuffer source = makeBuffer(kCVPixelFormatType_32BGRA, 32, 18);
    fillBGRA(source, {10, 200, 30, 255});
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, 32, 18);
    CVBufferSetAttachment(out.get(), kCVImageBufferChromaLocationTopFieldKey, kCVImageBufferChromaLocation_Center,
                          kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(out.get(), kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4,
                          kCVAttachmentMode_ShouldPropagate);
    RenderGraph g = makeGraph(32, 18);
    g.layers.push_back(makeLayer(1));
    [self render:g textures:{texturesFor(*_compositor, source)} target:PixelBufferTarget{out}];
    XCTAssertFalse(media::CFRef<CFTypeRef>::adopt(
        CVBufferCopyAttachment(out.get(), kCVImageBufferChromaLocationTopFieldKey, nullptr)));
    XCTAssertFalse(media::CFRef<CFTypeRef>::adopt(CVBufferCopyAttachment(out.get(), kCVImageBufferYCbCrMatrixKey, nullptr)));
    XCTAssertTrue(near(pixelAt(out, 5, 5), 10, 200, 30, 1));
}

// Minification: a picture drawn smaller than ~3/4 of its size is filtered (Lanczos pre-scale)
// instead of point-sampled by bilinear taps. One-pixel stripes shrunk to 700 and 533 pixels
// wide must come out as flat mid-grey (they alias to near 0/255 with plain bilinear sampling),
// vertically and horizontally, for RGBA and YCbCr sources, for a scaled-down clip (picture in
// picture) and for straight alpha (transparent texels carry green that must not show).
- (void)testMinifiedSourcesAreFilteredNotAliased {
    struct Range {
        int min = 255, max = 0;
    };
    auto stripes = [](OSType format, bool vertical, bool straightGreen) {
        media::PixelBuffer b = makeBuffer(format, 1920, 1080);
        if (format == kCVPixelFormatType_32BGRA) {
            fillBGRA(b, {0, 0, 0, 255});
            for (size_t i = 1; i < (vertical ? 1920u : 1080u); i += 2) {
                if (vertical) {
                    fillBGRARect(b, i, 0, i + 1, 1080, {255, 255, 255, 255});
                } else {
                    fillBGRARect(b, 0, i, 1920, i + 1, {255, 255, 255, 255});
                }
            }
            if (straightGreen) {
                for (size_t i = 0; i < 1920; i += 2) {
                    fillBGRARect(b, i, 0, i + 1, 1080, {0, 255, 0, 0}); // transparent, colour green
                }
                tagAlpha(b, AlphaMode::Straight);
            }
        } else {
            fillYCbCrPattern(
                b, [vertical](size_t x, size_t y) { return ((vertical ? x : y) & 1) ? 235.0 : 16.0; },
                [](size_t, size_t) { return std::pair<double, double>{128.0, 128.0}; });
            tagYCbCr(b, YCbCrMatrix::BT709, ChromaSiting::Left);
        }
        return b;
    };
    // Range of the R and G channels over the interior of the middle row (vertical stripes) or
    // column (horizontal stripes) of the picture area.
    auto measure = [](id<MTLTexture> t, bool vertical, PixelRect area, Range &red, Range &green) {
        const size_t n = vertical ? size_t(area.width) : size_t(area.height);
        for (size_t k = 3; k + 3 < n; ++k) {
            const size_t x = vertical ? size_t(area.x) + k : size_t(area.x + area.width / 2);
            const size_t y = vertical ? size_t(area.y + area.height / 2) : size_t(area.y) + k;
            const RGBA8 p = texturePixel(t, x, y);
            red.min = std::min(red.min, int(p.r));
            red.max = std::max(red.max, int(p.r));
            green.min = std::min(green.min, int(p.g));
            green.max = std::max(green.max, int(p.g));
        }
    };
    struct Case {
        const char *name;
        OSType format;
        bool vertical;
        bool straightGreen;
        size_t targetWidth;
        double clipScale;
    };
    const Case cases[] = {
        {"BGRA vertical stripes -> 700", kCVPixelFormatType_32BGRA, true, false, 700, 1.0},
        {"BGRA vertical stripes -> 533", kCVPixelFormatType_32BGRA, true, false, 533, 1.0},
        {"BGRA horizontal stripes -> 700", kCVPixelFormatType_32BGRA, false, false, 700, 1.0},
        {"420v vertical stripes -> 700", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, true, false, 700, 1.0},
        {"420v horizontal stripes -> 533", kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, false, false, 533, 1.0},
        {"x420 vertical stripes -> 533", kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, true, false, 533, 1.0},
        {"BGRA stripes, clip scale 0.3 at 1920", kCVPixelFormatType_32BGRA, true, false, 1920, 0.3},
        {"straight alpha stripes -> 700", kCVPixelFormatType_32BGRA, true, true, 700, 1.0},
    };
    for (const Case &c : cases) {
        media::PixelBuffer source = stripes(c.format, c.vertical, c.straightGreen);
        if (c.format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) {
            fillYCbCrPattern(
                source, [](size_t x, size_t) { return (x & 1) ? 940.0 : 64.0; },
                [](size_t, size_t) { return std::pair<double, double>{512.0, 512.0}; });
        }
        const size_t targetHeight = size_t(std::lround(c.targetWidth * 1080.0 / 1920.0));
        id<MTLTexture> target = makeTargetTexture(c.targetWidth, targetHeight);
        RenderGraph g = makeGraph(1920, 1080);
        VideoLayer layer = makeLayer(1);
        layer.transform.scale = c.clipScale;
        g.layers.push_back(layer);
        const RenderResult r = [self render:g
                                   textures:{texturesFor(*_compositor, source)}
                                     target:TextureTarget{target, {}, nil}];
        XCTAssertGreaterThanOrEqual(r.prescaledPlanes, 1u, @"%s", c.name);
        const PixelRect frame = fitRect(1920, 1080, int32_t(c.targetWidth), int32_t(targetHeight));
        PixelRect area = frame;
        if (c.clipScale != 1.0) {
            area.width = int32_t(frame.width * c.clipScale);
            area.height = int32_t(frame.height * c.clipScale);
            area.x = frame.x + (frame.width - area.width) / 2;
            area.y = frame.y + (frame.height - area.height) / 2;
        }
        Range red, green;
        measure(target, c.vertical, area, red, green);
        // Ideal: 127.5 (white and black stripes averaged; 50 % coverage of white for straight alpha).
        XCTAssertGreaterThanOrEqual(red.min, 118, @"%s: R range %d...%d", c.name, red.min, red.max);
        XCTAssertLessThanOrEqual(red.max, 138, @"%s: R range %d...%d", c.name, red.min, red.max);
        if (c.straightGreen) {
            XCTAssertLessThanOrEqual(green.max - red.max, 0, @"%s: transparent green bled (G %d...%d)", c.name,
                                     green.min, green.max);
        }
        NSLog(@"Minification %s: R %d...%d, G %d...%d", c.name, red.min, red.max, green.min, green.max);
    }

    // Only minified planes are pre-scaled: 1:1 and magnified pictures take no extra pass, and a
    // 4:2:0 picture at 1/2 size only needs its luma plane (the chroma plane is drawn at 1:1).
    media::PixelBuffer small = makeBuffer(kCVPixelFormatType_32BGRA, 640, 360);
    fillBGRA(small, {90, 90, 90, 255});
    media::PixelBuffer hd = makeBurnIn420v(3, 1920, 1080);
    RenderGraph g = makeGraph(1920, 1080);
    g.layers.push_back(makeLayer(1));
    for (const auto &[buffer, targetWidth, expected] :
         {std::tuple<media::PixelBuffer, size_t, size_t>{small, 1920, 0}, {hd, 1920, 0}, {hd, 1440, 0}, {hd, 960, 1},
          {hd, 480, 2}}) {
        id<MTLTexture> target = makeTargetTexture(targetWidth, targetWidth * 9 / 16);
        const RenderResult r = [self render:g textures:{texturesFor(*_compositor, buffer)} target:TextureTarget{target, {}, nil}];
        XCTAssertEqual(r.prescaledPlanes, expected, @"%s -> %zu", fourCCString(buffer.pixelFormat()).c_str(), targetWidth);
    }
    // The pool keeps one texture per plane size in use, not one per frame.
    const size_t pooled = _compositor->stats().scratchTextures;
    for (int i = 0; i < 20; ++i) {
        id<MTLTexture> target = makeTargetTexture(480, 270);
        [self render:g textures:{texturesFor(*_compositor, hd)} target:TextureTarget{target, {}, nil}];
    }
    XCTAssertEqual(_compositor->stats().scratchTextures, pooled);
    _compositor->releaseScratchMemory();
    XCTAssertEqual(_compositor->stats().scratchTextures, 0u);
}

// (h) Layers without a picture are skipped and reported; the rest still renders.
- (void)testMissingTexturesAreSkippedAndReported {
    media::PixelBuffer green = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
    fillBGRA(green, {0, 255, 0, 255});
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
    RenderGraph g = makeGraph(64, 36);
    g.layers.push_back(makeLayer(11));
    g.layers.push_back(makeLayer(12));
    g.layers.push_back(makeLayer(13, 0.5));
    RenderResult r = [self render:g
                         textures:{texturesFor(*_compositor, green), TextureSet{}, TextureSet{}}
                           target:PixelBufferTarget{out}];
    XCTAssertEqual(r.drawnLayers, 1u);
    XCTAssertEqual(r.skippedLayers.size(), 2u);
    if (r.skippedLayers.size() == 2) {
        XCTAssertTrue((r.skippedLayers[0] == SkippedLayer{1, ClipId{12}}));
        XCTAssertTrue((r.skippedLayers[1] == SkippedLayer{2, ClipId{13}}));
    }
    XCTAssertTrue(near(pixelAt(out, 20, 20), 0, 255, 0, 1));
}

// A render that fails after taking a uniform slot (uniform buffer, command buffer or render
// encoder failure) gives the slot back: frames already on the GPU keep their slot, every
// completion fires exactly once, in submission order, with its own result, and later frames
// render correctly.
- (void)testFailedSubmissionsKeepUniformSlotsConsistent {
    auto log = std::make_shared<FrameLog>();
    media::PixelBuffer red = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
    media::PixelBuffer green = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
    fillBGRA(red, {255, 0, 0, 255});
    fillBGRA(green, {0, 255, 0, 255});
    const TextureSet redSet = texturesFor(*_compositor, red);
    const TextureSet greenSet = texturesFor(*_compositor, green);
    RenderGraph g = makeGraph(64, 36);
    g.layers.push_back(makeLayer(1));
    auto lookupFor = [](const TextureSet &set) {
        return [set](const VideoLayer &, std::size_t, TextureSet &out) {
            out = set;
            return true;
        };
    };

    for (Compositor::Fault fault :
         {Compositor::Fault::UniformBuffer, Compositor::Fault::CommandBuffer, Compositor::Fault::RenderEncoder}) {
        log->clear();
        // Frame 1 stays "in flight" (its completion blocks) while a failing render and two more
        // frames are submitted: with kFramesInFlight == 3 the third one needs the slot the failed
        // render took, not frame 1's.
        auto gate = std::make_shared<test::Gate>();
        media::PixelBuffer out1 = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
        media::PixelBuffer out2 = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
        media::PixelBuffer out3 = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
        auto record = [log](const RenderResult &r) { log->add(r.frameNumber); };
        auto first = _compositor->render(g, lookupFor(redSet), PixelBufferTarget{out1},
                                         [record, gate](const RenderResult &r) {
                                             record(r);
                                             gate->pass();
                                         });
        XCTAssertTrue(first.ok() && first.value() == Submission::Submitted);
        XCTAssertTrue(log->waitFor(1));
        const uint64_t firstFrame = log->snapshot().empty() ? 0 : log->snapshot()[0];

        _compositor->injectFaultForTesting(fault);
        auto failed = _compositor->render(g, lookupFor(greenSet), PixelBufferTarget{out2}, record);
        XCTAssertFalse(failed.ok(), @"fault %d must fail the render", int(fault));

        auto second = _compositor->render(g, lookupFor(greenSet), PixelBufferTarget{out2}, record);
        auto third = _compositor->render(g, lookupFor(greenSet), PixelBufferTarget{out3}, record,
                                         RenderOptions{false});
        XCTAssertTrue(second.ok() && second.value() == Submission::Submitted);
        XCTAssertTrue(third.ok() && third.value() == Submission::Submitted,
                      @"a slot must be free: frame 1 holds one, frame 2 another");
        gate->open();
        XCTAssertTrue(log->waitFor(3));
        const std::vector<uint64_t> frames = log->snapshot();
        XCTAssertEqual(frames.size(), 3u, @"fault %d: every completion fires once", int(fault));
        if (frames.size() == 3) {
            XCTAssertEqual(frames[0], firstFrame);
            XCTAssertEqual(frames[1], firstFrame + 1, @"fault %d", int(fault));
            XCTAssertEqual(frames[2], firstFrame + 2, @"fault %d", int(fault));
        }
        XCTAssertTrue(near(pixelAt(out1, 10, 10), 255, 0, 0, 1));
        XCTAssertTrue(near(pixelAt(out2, 10, 10), 0, 255, 0, 1));
        XCTAssertTrue(near(pixelAt(out3, 10, 10), 0, 255, 0, 1));
        XCTAssertEqual(_compositor->freeSlotCount(), Compositor::kFramesInFlight);
    }

    // Afterwards every slot is usable again: a long run of synchronous renders is correct.
    for (int i = 0; i < 12; ++i) {
        media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, 64, 36);
        const bool useRed = (i % 2) == 0;
        auto r = renderLayers(*_compositor, g, {useRed ? redSet : greenSet}, PixelBufferTarget{out});
        XCTAssertTrue(r.ok() && r->status.ok());
        XCTAssertTrue(near(pixelAt(out, 10, 10), useRed ? 255 : 0, useRed ? 0 : 255, 0, 1), @"frame %d", i);
    }
}

// GPU intervals of completed frames; busy() is their union (frames in flight overlap).
struct GPUTimeline {
    std::mutex mutex;
    std::vector<std::pair<double, double>> intervals;
    std::atomic<int> completed{0};

    void add(const RenderResult &r) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            intervals.emplace_back(r.gpuStartTime, r.gpuEndTime);
        }
        completed.fetch_add(1);
    }
    void reset() {
        std::lock_guard<std::mutex> lock(mutex);
        intervals.clear();
        completed.store(0);
    }
    double busySeconds() {
        std::lock_guard<std::mutex> lock(mutex);
        std::sort(intervals.begin(), intervals.end());
        double total = 0, curStart = 0, curEnd = -1;
        for (const auto &[a, b] : intervals) {
            if (a > curEnd) {
                total += std::max(0.0, curEnd - curStart);
                curStart = a;
                curEnd = b;
            } else {
                curEnd = std::max(curEnd, b);
            }
        }
        return total + std::max(0.0, curEnd - curStart);
    }
    bool waitFor(int count) {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
        while (completed.load() < count && std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
        return completed.load() >= count;
    }
};

struct Throughput {
    double wallMs = 0; // per frame, pipelined
    double gpuMs = 0;  // GPU busy time per frame (union of intervals)
};

// Submits `frames` renders back to back (pipelined, up to kFramesInFlight on the GPU), mapping
// the sources each frame like playback does, and waits for all of them.
static Throughput runPipelined(Compositor &compositor, const RenderGraph &graph,
                               const std::vector<media::PixelBuffer> &sources,
                               const std::function<RenderTarget()> &makeTarget, int frames) {
    auto timeline = std::make_shared<GPUTimeline>();
    const auto start = std::chrono::steady_clock::now();
    for (int i = 0; i < frames; ++i) {
        @autoreleasepool {
            std::vector<TextureSet> textures;
            for (const media::PixelBuffer &b : sources) {
                textures.push_back(texturesFor(compositor, b));
            }
            auto lookup = [&textures](const VideoLayer &, std::size_t index, TextureSet &out) {
                out = textures[index];
                return true;
            };
            auto submitted = compositor.render(graph, lookup, makeTarget(),
                                               [timeline](const RenderResult &r) { timeline->add(r); });
            if (!submitted.ok() || submitted.value() != Submission::Submitted) {
                return {};
            }
        }
    }
    timeline->waitFor(frames);
    const double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    return {wall / frames * 1000.0, timeline->busySeconds() / frames * 1000.0};
}

// (i) Steady state at 1080p, export and preview paths: frame time, GPU load, and no growth of
// memory or pooled objects over 6000 frames.
- (void)testSteadyStatePerformanceAndMemory {
    const size_t w = 1920, h = 1080;
    media::PixelBuffer a = makeBurnIn420v(1, w, h);
    media::PixelBuffer b = makeBurnIn420v(2, w, h);
    auto pool = media::PixelBufferPool::create(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, w, h);
    XCTAssertTrue(pool.ok());
    if (!pool.ok()) {
        return;
    }
    RenderGraph g = makeGraph(int32_t(w), int32_t(h));
    g.layers.push_back(makeLayer(1));
    g.layers.push_back(makeLayer(2, 0.5));
    g.layers[1].transform.scale = 0.8;
    g.layers[1].transform.rotationDegrees = 10;
    auto exportTarget = [&pool]() -> RenderTarget { return PixelBufferTarget{pool->makeBuffer().value()}; };
    // The preview path: a BGRA8 render-target texture like the CAMetalLayer drawable (three
    // of them in rotation, as the layer has).
    std::vector<id<MTLTexture>> drawables{makeTargetTexture(w, h), makeTargetTexture(w, h), makeTargetTexture(w, h)};
    size_t nextDrawable = 0;
    auto previewTarget = [&]() -> RenderTarget {
        return TextureTarget{drawables[nextDrawable++ % drawables.size()], {}, nil};
    };

    runPipelined(*_compositor, g, {a, b}, exportTarget, 60); // warm up pools, caches and pipelines
    runPipelined(*_compositor, g, {a, b}, previewTarget, 60);
    const Throughput exportRun = runPipelined(*_compositor, g, {a, b}, exportTarget, 600);
    const Throughput previewRun = runPipelined(*_compositor, g, {a, b}, previewTarget, 600);
    NSLog(@"Compositor 1080p, 2 x 420v layers (one scaled and rotated): export -> 420v %.3f ms/frame wall, "
          @"%.3f ms/frame GPU busy; preview -> BGRA8 texture %.3f ms/frame wall, %.3f ms/frame GPU busy",
          exportRun.wallMs, exportRun.gpuMs, previewRun.wallMs, previewRun.gpuMs);
    XCTAssertGreaterThan(exportRun.wallMs, 0.0);
    XCTAssertGreaterThan(previewRun.wallMs, 0.0);
    XCTAssertLessThan(exportRun.wallMs, 1.5);
    XCTAssertLessThan(previewRun.wallMs, 1.5);
    XCTAssertLessThan(exportRun.gpuMs, 1.5);
    XCTAssertLessThan(previewRun.gpuMs, 1.5);

    // Latency of one frame end to end (encode + GPU + completion), no pipelining.
    std::vector<TextureSet> textures{texturesFor(*_compositor, a), texturesFor(*_compositor, b)};
    const int syncFrames = 100;
    const auto syncStart = std::chrono::steady_clock::now();
    for (int i = 0; i < syncFrames; ++i) {
        @autoreleasepool {
            auto r = renderLayers(*_compositor, g, textures, previewTarget());
            XCTAssertTrue(r.ok() && r->status.ok());
        }
    }
    const double syncMs =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - syncStart).count() / syncFrames * 1000.0;
    NSLog(@"Compositor 1080p preview synchronous latency: %.3f ms/frame", syncMs);
    XCTAssertLessThan(syncMs, 2.0);

    // Memory: 6000 more frames through both paths leave the footprint and the compositor's
    // pools where they were. 3 MB over 6000 frames catches a leak of 0.5 KB per frame (the
    // footprint also moves with unrelated activity in the process, e.g. other tests' threads
    // winding down).
    // A half-size preview as well, so minified layers go through the pre-scale pool.
    std::vector<id<MTLTexture>> small{makeTargetTexture(960, 540), makeTargetTexture(960, 540),
                                      makeTargetTexture(960, 540)};
    size_t nextSmall = 0;
    auto smallTarget = [&]() -> RenderTarget { return TextureTarget{small[nextSmall++ % small.size()], {}, nil}; };
    // Warm up every path well past first use: Metal, MPS and the allocators keep growing their
    // caches for the first thousand or so frames (measured: +111 MB on the first frame, +25 MB
    // over the next 2000, then flat), which is not a leak.
    for (int round = 0; round < 3; ++round) {
        runPipelined(*_compositor, g, {a, b}, exportTarget, 300);
        runPipelined(*_compositor, g, {a, b}, previewTarget, 300);
        runPipelined(*_compositor, g, {a, b}, smallTarget, 300);
    }
    const uint64_t before = test::physicalFootprint();
    const Compositor::Stats statsBefore = _compositor->stats();
    XCTAssertGreaterThan(statsBefore.scratchTextures, 0u);
    for (int round = 0; round < 10; ++round) {
        runPipelined(*_compositor, g, {a, b}, exportTarget, 200);
        runPipelined(*_compositor, g, {a, b}, previewTarget, 200);
        runPipelined(*_compositor, g, {a, b}, smallTarget, 200);
    }
    const uint64_t after = test::physicalFootprint();
    const Compositor::Stats statsAfter = _compositor->stats();
    const double growthMB = (double(after) - double(before)) / (1024.0 * 1024.0);
    NSLog(@"Compositor footprint over 6000 frames: %.1f MB -> %.1f MB (%+.2f MB); pooled textures %zu -> %zu",
          before / 1048576.0, after / 1048576.0, growthMB, statsBefore.scratchTextures, statsAfter.scratchTextures);
    XCTAssertLessThan(growthMB, 3.0);
    XCTAssertEqual(statsAfter.scratchTextures, statsBefore.scratchTextures);
    XCTAssertEqual(statsAfter.freeSlots, Compositor::kFramesInFlight, @"every frame's slot came back");
}

// A 3840x2160 4:2:0 source shown in a 1920x1080 preview (the luma plane is Lanczos pre-scaled,
// the chroma plane is drawn at 1:1): frame time and GPU load, pipelined and one at a time.
- (void)testPreviewOf4KSourceTiming {
    media::PixelBuffer source = makeBurnIn420v(7, 3840, 2160);
    RenderGraph g = makeGraph(3840, 2160);
    g.layers.push_back(makeLayer(1));
    std::vector<id<MTLTexture>> drawables{makeTargetTexture(1920, 1080), makeTargetTexture(1920, 1080),
                                          makeTargetTexture(1920, 1080)};
    size_t next = 0;
    auto previewTarget = [&]() -> RenderTarget { return TextureTarget{drawables[next++ % drawables.size()], {}, nil}; };
    const TextureSet set = texturesFor(*_compositor, source);
    auto first = renderLayers(*_compositor, g, {set}, previewTarget());
    XCTAssertTrue(first.ok() && first->status.ok());
    if (first.ok()) {
        XCTAssertEqual(first->prescaledPlanes, 1u);
    }
    runPipelined(*_compositor, g, {source}, previewTarget, 30); // warm up
    const Throughput run = runPipelined(*_compositor, g, {source}, previewTarget, 300);

    double gpuSum = 0;
    const int syncFrames = 60;
    const auto syncStart = std::chrono::steady_clock::now();
    for (int i = 0; i < syncFrames; ++i) {
        auto r = renderLayers(*_compositor, g, {set}, previewTarget());
        XCTAssertTrue(r.ok() && r->status.ok());
        if (r.ok()) {
            gpuSum += r->gpuSeconds;
        }
    }
    const double syncMs =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - syncStart).count() / syncFrames * 1000.0;
    NSLog(@"Compositor 4K 420v -> 1080p preview: %.3f ms/frame wall pipelined, %.3f ms/frame GPU busy; "
          @"one at a time %.3f ms/frame latency, %.3f ms GPU",
          run.wallMs, run.gpuMs, syncMs, gpuSum / syncFrames * 1000.0);
    // Real time needs < 16.7 ms per frame at 60 fps; this leaves most of it for decode and UI.
    XCTAssertLessThan(run.gpuMs, 4.0);
    XCTAssertLessThan(run.wallMs, 5.0);
    XCTAssertLessThan(syncMs, 6.0);
}

@end
