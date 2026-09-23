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
#include <condition_variable>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
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
        XCTAssertTrue(near(pixelAt(out, 681, 371), 255, 0, 0, 1));
        XCTAssertTrue(near(pixelAt(out, 728, 418), 255, 0, 0, 1));
        XCTAssertTrue(near(pixelAt(out, 732, 390), 255, 255, 255, 1));
        XCTAssertTrue(near(pixelAt(out, 700, 422), 255, 255, 255, 1));
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

- (void)addDissolvePairTo:(RenderGraph &)g mix:(double)mix {
    VideoLayer outgoing = makeLayer(1);
    VideoLayer incoming = makeLayer(2);
    LayerTransition t;
    t.transitionId = TransitionId{77};
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
    media::PixelBuffer bad = makeBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 64, 64);
    auto result = renderLayers(*_compositor, g, {}, PixelBufferTarget{bad});
    XCTAssertFalse(result.ok());
    if (!result.ok()) {
        XCTAssertEqual(result.error().code, media::MediaErrorCode::UnsupportedFormat);
    }
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

// (i) 600 renders at 1080p: memory stays flat and the average frame time is under 4 ms.
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
    g.layers[1].transform.scale = 0.7;
    g.layers[1].transform.rotationDegrees = 10;

    std::atomic<int> completed{0};
    std::atomic<double> gpuSeconds{0};
    std::atomic<int> *completedPtr = &completed;
    std::atomic<double> *gpuPtr = &gpuSeconds;
    auto runFrames = [&](int count) {
        for (int i = 0; i < count; ++i) {
            @autoreleasepool {
                // Map the sources every frame, like the playback path does for new frames.
                std::vector<TextureSet> textures{texturesFor(*_compositor, a), texturesFor(*_compositor, b)};
                auto target = pool->makeBuffer();
                XCTAssertTrue(target.ok());
                auto lookup = [&textures](const VideoLayer &, std::size_t index, TextureSet &out) {
                    out = textures[index];
                    return true;
                };
                auto submitted = _compositor->render(g, lookup, PixelBufferTarget{target.value()},
                                                     [completedPtr, gpuPtr](const RenderResult &r) {
                                                         double current = gpuPtr->load();
                                                         while (!gpuPtr->compare_exchange_weak(current, current + r.gpuSeconds)) {
                                                         }
                                                         completedPtr->fetch_add(1);
                                                     });
                XCTAssertTrue(submitted.ok() && submitted.value() == Submission::Submitted);
            }
        }
    };
    auto waitForCompleted = [&](int expected) {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
        while (completed.load() < expected && std::chrono::steady_clock::now() < deadline) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    };

    runFrames(60); // warm up pools, caches and pipelines
    waitForCompleted(60);
    const uint64_t before = test::physicalFootprint();
    gpuSeconds.store(0);
    const int frames = 600;
    const auto start = std::chrono::steady_clock::now();
    runFrames(frames);
    waitForCompleted(60 + frames);
    const double wall = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    const uint64_t after = test::physicalFootprint();
    XCTAssertEqual(completed.load(), 60 + frames);

    const double avgMs = wall / frames * 1000.0;
    const double gpuMs = gpuSeconds.load() / frames * 1000.0;
    const double growthMB = (double(after) - double(before)) / (1024.0 * 1024.0);
    NSLog(@"Compositor 1080p (2 x 420v layers -> 420v export target): %.3f ms/frame wall, %.3f ms/frame GPU, "
          @"footprint %.1f MB -> %.1f MB (%+.2f MB) over %d frames",
          avgMs, gpuMs, before / 1048576.0, after / 1048576.0, growthMB, frames);
    XCTAssertLessThan(avgMs, 4.0);
    XCTAssertLessThan(growthMB, 8.0);

    // Latency of one frame end to end (encode + GPU + completion), no pipelining.
    std::vector<TextureSet> textures{texturesFor(*_compositor, a), texturesFor(*_compositor, b)};
    media::PixelBuffer target = pool->makeBuffer().value();
    const int syncFrames = 100;
    const auto syncStart = std::chrono::steady_clock::now();
    for (int i = 0; i < syncFrames; ++i) {
        @autoreleasepool {
            auto r = renderLayers(*_compositor, g, textures, PixelBufferTarget{target});
            XCTAssertTrue(r.ok() && r->status.ok());
        }
    }
    const double syncMs =
        std::chrono::duration<double>(std::chrono::steady_clock::now() - syncStart).count() / syncFrames * 1000.0;
    NSLog(@"Compositor 1080p synchronous latency: %.3f ms/frame", syncMs);
    XCTAssertLessThan(syncMs, 4.0);
}

@end
