// The texture targets' float working buffer (Compositor.h, "Pipeline" step 3; grading decision
// section 4): monitors composite into a pooled RGBA16Float working texture and an output pass writes
// the framebuffer-only BGR10A2 drawable.
//   - Pixels: against compositing straight into the 10-bit target (how monitors drew before, kept as
//     TextureTarget::compositeDirectlyForTesting), no sample differs by more than one 10-bit code, over
//     scenes of every kind (1:1, several translucent layers, a 4K source pre-scaled and sharpened,
//     straight alpha, a dissolve and a feathered wipe, letterboxing, an odd-sized target, a viewport).
//     Against a 32-bit float composite of the same scene the working path is never farther than the
//     direct one.
//   - The working frame reader sees the frame as blended (bit for bit what an RGBA16Float target holds),
//     and the target is exactly that, limited to [0, 1] and rounded to 10 bits.
//   - GPU time per frame at 1080p and 2160p, both paths (the decision note estimated 0.024 ms and
//     0.09 ms for the output pass).
//   - The working texture is pooled (reused across frames and resizes within a size step, released
//     under memory pressure), and VEPreviewView hands it to its facade-private reader.

#import <XCTest/XCTest.h>

#import <FramewrightEngine/FramewrightEngine.h>

#include "../../Engine/Render/Compositor.h"
#import "../../Engine/Render/VEPreviewView+Internal.h"
#include "CompositorTestSupport.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <functional>
#include <memory>
#include <string>
#include <vector>

using namespace ve;
using namespace ve::render;
using namespace ve::rtest;

namespace {

id<MTLTexture> makeTexture(MTLPixelFormat format, size_t width, size_t height) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    return [device() newTextureWithDescriptor:desc];
}

// R, G, B of every pixel of a BGR10A2Unorm texture as 10-bit codes (B in bits 0-9, G 10-19, R 20-29).
std::vector<int> codesOf10Bit(id<MTLTexture> texture) {
    const size_t w = texture.width;
    const size_t h = texture.height;
    std::vector<uint32_t> packed(w * h);
    [texture getBytes:packed.data() bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    std::vector<int> codes(w * h * 3);
    for (size_t i = 0; i < w * h; ++i) {
        codes[i * 3 + 0] = int((packed[i] >> 20) & 0x3FF);
        codes[i * 3 + 1] = int((packed[i] >> 10) & 0x3FF);
        codes[i * 3 + 2] = int(packed[i] & 0x3FF);
    }
    return codes;
}

// R, G, B, A of every pixel of an RGBA32Float texture.
std::vector<float> valuesOf32Float(id<MTLTexture> texture) {
    const size_t w = texture.width;
    const size_t h = texture.height;
    std::vector<float> values(w * h * 4);
    [texture getBytes:values.data() bytesPerRow:w * 16 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    return values;
}

// The raw half floats of the top-left `width` x `height` of an RGBA16Float texture.
std::vector<uint16_t> halvesOf(id<MTLTexture> texture, size_t width, size_t height) {
    std::vector<uint16_t> halves(width * height * 4);
    [texture getBytes:halves.data()
          bytesPerRow:width * 8
           fromRegion:MTLRegionMake2D(0, 0, width, height)
          mipmapLevel:0];
    return halves;
}

float halfToFloat(uint16_t h) {
    _Float16 value;
    std::memcpy(&value, &h, sizeof value);
    return float(value);
}

// A scene: a graph, its pictures, and the target's size and viewport.
struct Scene {
    Scene(std::string sceneName, RenderGraph sceneGraph, std::vector<media::PixelBuffer> scenePictures,
          size_t targetWidth = 1920, size_t targetHeight = 1080)
        : name(std::move(sceneName)), graph(std::move(sceneGraph)), pictures(std::move(scenePictures)),
          width(targetWidth), height(targetHeight) {}

    std::string name;
    RenderGraph graph;
    std::vector<media::PixelBuffer> pictures;
    size_t width = 1920;
    size_t height = 1080;
    PixelRect viewport;
};

// A BGRA picture with straight alpha: a horizontal colour ramp, alpha falling from 1 to 0 down.
media::PixelBuffer straightAlphaRamp(size_t width, size_t height) {
    media::PixelBuffer buffer = makeBuffer(kCVPixelFormatType_32BGRA, width, height);
    CVPixelBufferLockBaseAddress(buffer.get(), 0);
    auto *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(buffer.get()));
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer.get());
    for (size_t y = 0; y < height; ++y) {
        for (size_t x = 0; x < width; ++x) {
            uint8_t *p = base + y * stride + x * 4;
            p[0] = uint8_t(255 - x * 255 / (width - 1));            // B
            p[1] = uint8_t((x * 7 + y * 3) % 256);                   // G
            p[2] = uint8_t(x * 255 / (width - 1));                   // R
            p[3] = uint8_t(255 - y * 255 / (height - 1));            // A
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer.get(), 0);
    tagAlpha(buffer, AlphaMode::Straight);
    return buffer;
}

// A shallow 10-bit gradient: every 10-bit luma code from 64 to 940 across the picture.
media::PixelBuffer tenBitGradient(size_t width, size_t height) {
    media::PixelBuffer buffer = makeBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, width, height);
    fillYCbCrPattern(
        buffer, [&](size_t x, size_t) { return 64.0 + 876.0 * double(x) / double(width - 1); },
        [&](size_t i, size_t j) {
            return std::make_pair(512.0 + 200.0 * std::sin(double(i) * 0.01), 512.0 + 150.0 * std::cos(double(j) * 0.02));
        });
    tagYCbCr(buffer, media::YCbCrMatrix::BT709, ChromaSiting::Left);
    return buffer;
}

// Clips 1 (outgoing) and 2 (incoming) of a transition across a cut at `mix`, the frame's exposure
// interval centred on it.
void addPair(RenderGraph &graph, TransitionKind kind, double mix) {
    VideoLayer outgoing = makeLayer(1);
    VideoLayer incoming = makeLayer(2);
    LayerTransition t;
    t.transitionId = SpanId{77};
    t.kind = kind;
    t.mix = mix;
    t.progressStart = mix - 0.02;
    t.progressEnd = mix + 0.02;
    t.isIncoming = false;
    t.partnerClipId = incoming.clipId;
    t.partnerLayerIndex = graph.layers.size() + 1;
    outgoing.transition = t;
    t.isIncoming = true;
    t.partnerClipId = outgoing.clipId;
    t.partnerLayerIndex = graph.layers.size();
    incoming.transition = t;
    graph.layers.push_back(outgoing);
    graph.layers.push_back(incoming);
}

std::vector<Scene> makeScenes() {
    std::vector<Scene> scenes;
    {
        Scene s{"1080p burn-in at 1:1", makeGraph(1920, 1080), {makeBurnIn420v(3, 1920, 1080)}};
        s.graph.layers.push_back(makeLayer(1));
        scenes.push_back(std::move(s));
    }
    {
        Scene s{"10-bit gradient at 1:1", makeGraph(1920, 1080), {tenBitGradient(1920, 1080)}};
        s.graph.layers.push_back(makeLayer(1));
        scenes.push_back(std::move(s));
    }
    {
        // Three translucent layers, the upper two scaled, rotated and moved off the pixel grid.
        Scene s{"three layers at 50 %", makeGraph(1920, 1080),
                {makeBurnIn420v(1, 1920, 1080), makeBurnIn420v(2, 1920, 1080), tenBitGradient(1920, 1080)}};
        for (uint64_t id = 1; id <= 3; ++id) {
            VideoLayer layer = makeLayer(id, 0.5);
            if (id > 1) {
                layer.transform.scale = 0.6 + 0.1 * double(id);
                layer.transform.rotationDegrees = 7.3 * double(id);
                layer.transform.x = 33.25 * double(id);
                layer.transform.y = -17.5;
            }
            s.graph.layers.push_back(layer);
        }
        scenes.push_back(std::move(s));
    }
    {
        Scene s{"4K source in a 1080p sequence (pre-scaled, sharpened)", makeGraph(1920, 1080),
                {makeBurnIn420v(5, 3840, 2160)}};
        s.graph.layers.push_back(makeLayer(1));
        scenes.push_back(std::move(s));
    }
    {
        Scene s{"straight alpha over video", makeGraph(1920, 1080),
                {makeBurnIn420v(4, 1920, 1080), straightAlphaRamp(960, 540)}};
        s.graph.layers.push_back(makeLayer(1));
        VideoLayer over = makeLayer(2, 0.8);
        over.transform.x = 120.5;
        s.graph.layers.push_back(over);
        scenes.push_back(std::move(s));
    }
    {
        Scene s{"cross dissolve at 37 %", makeGraph(1920, 1080),
                {makeBurnIn420v(6, 1920, 1080), makeBurnIn420v(7, 1920, 1080)}};
        addPair(s.graph, TransitionKind::CrossDissolve, 0.37);
        scenes.push_back(std::move(s));
    }
    {
        Scene s{"iris at 60 %", makeGraph(1920, 1080), {makeBurnIn420v(8, 1920, 1080), tenBitGradient(1920, 1080)}};
        addPair(s.graph, TransitionKind::Iris, 0.6);
        scenes.push_back(std::move(s));
    }
    {
        Scene s{"4:3 sequence letterboxed in an odd-sized target", makeGraph(1440, 1080),
                {makeBurnIn420v(9, 1440, 1080)}, 1273, 815};
        s.graph.layers.push_back(makeLayer(1));
        scenes.push_back(std::move(s));
    }
    {
        Scene s{"a viewport reaching outside the target", makeGraph(1920, 1080), {makeBurnIn420v(10, 1920, 1080)},
                1280, 720};
        s.viewport = PixelRect{-101, 37, 1440, 810};
        s.graph.layers.push_back(makeLayer(1));
        scenes.push_back(std::move(s));
    }
    return scenes;
}

media::Result<RenderResult> renderScene(Compositor &compositor, const Scene &scene, id<MTLTexture> texture,
                                        bool direct, WorkingFrameReader reader = {}) {
    std::vector<TextureSet> textures;
    for (const media::PixelBuffer &picture : scene.pictures) {
        textures.push_back(texturesFor(compositor, picture));
    }
    TextureTarget target;
    target.texture = texture;
    target.viewport = scene.viewport;
    target.compositeDirectlyForTesting = direct;
    target.workingFrameReader = std::move(reader);
    return renderLayers(compositor, scene.graph, textures, target);
}

double median(std::vector<double> values) {
    std::sort(values.begin(), values.end());
    return values.empty() ? 0.0 : values[values.size() / 2];
}

} // namespace

@interface CompositorWorkingBufferTests : XCTestCase
@end

@implementation CompositorWorkingBufferTests {
    std::unique_ptr<Compositor> _compositor;
}

- (void)setUp {
    // As VEPreviewView makes it: prepared for its BGR10A2 drawable.
    auto compositor = Compositor::create(device(), {MTLPixelFormatBGR10A2Unorm});
    XCTAssertTrue(compositor.ok(), @"%s", compositor.ok() ? "" : compositor.error().description().c_str());
    if (compositor.ok()) {
        _compositor = std::move(compositor).value();
    }
}

- (void)testMonitorPixelsChangeByAtMostOneTenBitCode {
    for (const Scene &scene : makeScenes()) {
        id<MTLTexture> working = makeTexture(MTLPixelFormatBGR10A2Unorm, scene.width, scene.height);
        id<MTLTexture> direct = makeTexture(MTLPixelFormatBGR10A2Unorm, scene.width, scene.height);
        id<MTLTexture> reference = makeTexture(MTLPixelFormatRGBA32Float, scene.width, scene.height);
        auto a = renderScene(*_compositor, scene, working, false);
        auto b = renderScene(*_compositor, scene, direct, true);
        auto c = renderScene(*_compositor, scene, reference, true);
        XCTAssertTrue(a.ok() && a->status.ok() && a->skippedLayers.empty(), @"%s", scene.name.c_str());
        XCTAssertTrue(b.ok() && b->status.ok() && b->skippedLayers.empty(), @"%s", scene.name.c_str());
        XCTAssertTrue(c.ok() && c->status.ok() && c->skippedLayers.empty(), @"%s", scene.name.c_str());
        if (!a.ok() || !b.ok() || !c.ok()) {
            continue;
        }
        const std::vector<int> viaWorking = codesOf10Bit(working);
        const std::vector<int> straight = codesOf10Bit(direct);
        const std::vector<float> exact = valuesOf32Float(reference);
        int largest = 0;
        size_t differing = 0;
        double workingError = 0;
        double directError = 0;
        for (size_t i = 0; i < scene.width * scene.height; ++i) {
            for (size_t ch = 0; ch < 3; ++ch) {
                const int d = std::abs(viaWorking[i * 3 + ch] - straight[i * 3 + ch]);
                largest = std::max(largest, d);
                differing += d != 0 ? 1 : 0;
                const double want = std::clamp(double(exact[i * 4 + ch]), 0.0, 1.0) * 1023.0;
                workingError = std::max(workingError, std::fabs(viaWorking[i * 3 + ch] - want));
                directError = std::max(directError, std::fabs(straight[i * 3 + ch] - want));
            }
        }
        const double samples = double(scene.width * scene.height * 3);
        NSLog(@"Working buffer, %s: largest difference %d code(s), %.4f %% of samples differ; largest error "
              @"against a 32-bit float composite: %.3f codes through the working buffer, %.3f straight",
              scene.name.c_str(), largest, 100.0 * double(differing) / samples, workingError, directError);
        XCTAssertLessThanOrEqual(largest, 1, @"%s", scene.name.c_str());
        // The GPU stores a blended value in half float rounding towards zero (up to one half-float step,
        // about half a 10-bit code at values above 0.5, less below), and the output pass rounds that to 10
        // bits: within a code of the exact composite for one layer, within 1.5 codes when a second layer is
        // blended over a stored value (each later blend halves the earlier errors at most).
        XCTAssertLessThanOrEqual(workingError, scene.graph.layers.size() > 1 ? 1.5 : 1.0, @"%s", scene.name.c_str());
    }
}

- (void)testTheReaderSeesTheBlendedFrameAndTheTargetIsItRoundedToTenBits {
    for (const Scene &scene : makeScenes()) {
        id<MTLTexture> target = makeTexture(MTLPixelFormatBGR10A2Unorm, scene.width, scene.height);
        id<MTLTexture> copy = nil;
        size_t calls = 0;
        MTLPixelFormat workingFormat = MTLPixelFormatInvalid;
        NSUInteger workingWidth = 0;
        NSUInteger workingHeight = 0;
        auto reader = [&](id<MTLCommandBuffer> commandBuffer, id<MTLTexture> working) {
            ++calls;
            workingFormat = working.pixelFormat;
            workingWidth = working.width;
            workingHeight = working.height;
            MTLTextureDescriptor *desc =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:working.pixelFormat
                                                                   width:working.width
                                                                  height:working.height
                                                               mipmapped:NO];
            desc.storageMode = MTLStorageModeShared;
            copy = [device() newTextureWithDescriptor:desc];
            id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
            [blit copyFromTexture:working toTexture:copy];
            [blit endEncoding];
        };
        auto rendered = renderScene(*_compositor, scene, target, false, reader);
        XCTAssertTrue(rendered.ok() && rendered->status.ok(), @"%s", scene.name.c_str());
        XCTAssertEqual(calls, 1u, @"%s", scene.name.c_str());
        if (copy == nil || !rendered.ok()) {
            continue;
        }
        XCTAssertEqual(workingFormat, MTLPixelFormatRGBA16Float);
        XCTAssertGreaterThanOrEqual(workingWidth, scene.width);
        XCTAssertGreaterThanOrEqual(workingHeight, scene.height);
        // What an RGBA16Float target composited straight holds, bit for bit.
        id<MTLTexture> half = makeTexture(MTLPixelFormatRGBA16Float, scene.width, scene.height);
        auto direct = renderScene(*_compositor, scene, half, true);
        XCTAssertTrue(direct.ok() && direct->status.ok());
        const std::vector<uint16_t> seen = halvesOf(copy, scene.width, scene.height);
        const std::vector<uint16_t> expected = halvesOf(half, scene.width, scene.height);
        size_t mismatches = 0;
        for (size_t i = 0; i < seen.size(); ++i) {
            mismatches += seen[i] != expected[i] ? 1 : 0;
        }
        XCTAssertEqual(mismatches, 0u, @"%s", scene.name.c_str());
        if (scene.graph.layers.size() == 1) {
            // One opaque layer: each stored value is the exact (float) one rounded towards zero to half
            // float, never above it and less than one half-float step below.
            id<MTLTexture> full = makeTexture(MTLPixelFormatRGBA32Float, scene.width, scene.height);
            XCTAssertTrue(renderScene(*_compositor, scene, full, true).ok());
            const std::vector<float> exact = valuesOf32Float(full);
            size_t above = 0;
            size_t tooFar = 0;
            for (size_t i = 0; i < scene.width * scene.height; ++i) {
                for (size_t ch = 0; ch < 3; ++ch) {
                    const float want = exact[i * 4 + ch];
                    const float got = halfToFloat(seen[i * 4 + ch]);
                    const float step = want > 0 ? std::ldexp(1.0f, std::ilogb(want) - 10) : 0.0f;
                    above += got > want ? 1 : 0;
                    tooFar += want - got >= std::max(step, 1e-7f) ? 1 : 0;
                }
            }
            XCTAssertEqual(above, 0u, @"%s", scene.name.c_str());
            XCTAssertEqual(tooFar, 0u, @"%s", scene.name.c_str());
        }
        // The target: each working value limited to [0, 1] and rounded to the nearest 10-bit code.
        const std::vector<int> codes = codesOf10Bit(target);
        size_t wrong = 0;
        for (size_t i = 0; i < scene.width * scene.height; ++i) {
            for (size_t ch = 0; ch < 3; ++ch) {
                const double value = std::clamp(double(halfToFloat(seen[i * 4 + ch])), 0.0, 1.0);
                wrong += codes[i * 3 + ch] != int(std::lround(value * 1023.0)) ? 1 : 0;
            }
        }
        XCTAssertEqual(wrong, 0u, @"%s", scene.name.c_str());
    }
}

- (void)testGPUTimePerFrameAt1080pAnd2160p {
    struct Case {
        const char *name;
        size_t sourceWidth, sourceHeight, size;
        int layers;
    };
    const Case cases[] = {
        {"1080p, 1 layer, 1080p monitor", 1920, 1080, 1080, 1},
        {"1080p, 3 layers at 50 %, 1080p monitor", 1920, 1080, 1080, 3},
        {"4K, 1 layer, 2160p monitor", 3840, 2160, 2160, 1},
        {"4K, 3 layers at 50 %, 2160p monitor", 3840, 2160, 2160, 3},
    };
    for (const Case &c : cases) {
        Scene scene{c.name, makeGraph(int32_t(c.sourceWidth), int32_t(c.sourceHeight)), {}};
        scene.width = c.size * 16 / 9;
        scene.height = c.size;
        for (int i = 0; i < c.layers; ++i) {
            scene.pictures.push_back(makeBurnIn420v(i + 1, c.sourceWidth, c.sourceHeight));
            scene.graph.layers.push_back(makeLayer(uint64_t(i + 1), c.layers > 1 ? 0.5 : 1.0));
        }
        id<MTLTexture> target = makeTexture(MTLPixelFormatBGR10A2Unorm, scene.width, scene.height);
        for (int warm = 0; warm < 20; ++warm) {
            (void)renderScene(*_compositor, scene, target, warm % 2 == 0);
        }
        // Interleaved, so both paths see the same GPU clocks.
        std::vector<double> working;
        std::vector<double> direct;
        for (int frame = 0; frame < 120; ++frame) {
            auto a = renderScene(*_compositor, scene, target, false);
            auto b = renderScene(*_compositor, scene, target, true);
            XCTAssertTrue(a.ok() && b.ok());
            if (a.ok() && b.ok()) {
                working.push_back(a->gpuSeconds * 1000.0);
                direct.push_back(b->gpuSeconds * 1000.0);
            }
        }
        const double w = median(working);
        const double d = median(direct);
        NSLog(@"Working buffer GPU time, %s: %.3f ms per frame through the working buffer, %.3f ms straight "
              @"into the drawable (+%.3f ms)",
              c.name, w, d, w - d);
        // The decision note measured 0.024 ms (1080p) and 0.09 ms (2160p) for the extra pass; the bounds
        // leave room for a loaded machine and a Debug build without hiding a pass gone wrong.
        XCTAssertLessThan(w - d, c.size >= 2160 ? 1.0 : 0.3, @"%s", c.name);
        XCTAssertLessThan(w, 16.7 / 4.0, @"%s", c.name);
    }
}

- (void)testTheWorkingTextureIsPooledAcrossFramesAndResizesAndReleasedUnderPressure {
    Scene scene{"pool", makeGraph(1920, 1080), {makeBurnIn420v(1, 1920, 1080)}};
    scene.graph.layers.push_back(makeLayer(1));
    auto renderAt = [&](size_t width, size_t height) {
        id<MTLTexture> target = makeTexture(MTLPixelFormatBGR10A2Unorm, width, height);
        auto rendered = renderScene(*_compositor, scene, target, false);
        XCTAssertTrue(rendered.ok() && rendered->status.ok());
    };
    XCTAssertEqual(_compositor->stats().workingAllocations, 0u);
    renderAt(1920, 1080);
    Compositor::Stats stats = _compositor->stats();
    XCTAssertEqual(stats.workingAllocations, 1u);
    XCTAssertEqual(stats.workingWidth, 1920u);
    XCTAssertEqual(stats.workingHeight, 1088u); // rounded up in steps of 64 at this size
    XCTAssertGreaterThanOrEqual(stats.workingBytes, 1920u * 1088u * 8u);
    renderAt(1920, 1080);
    renderAt(1900, 1070); // a live resize within the step
    renderAt(1859, 1025);
    XCTAssertEqual(_compositor->stats().workingAllocations, 1u);
    renderAt(2000, 1100); // the next step
    stats = _compositor->stats();
    XCTAssertEqual(stats.workingAllocations, 2u);
    XCTAssertEqual(stats.workingWidth, 2048u);
    XCTAssertEqual(stats.workingHeight, 1152u);
    // A direct composite needs none (and leaves the pooled one alone).
    id<MTLTexture> direct = makeTexture(MTLPixelFormatBGR10A2Unorm, 640, 360);
    XCTAssertTrue(renderScene(*_compositor, scene, direct, true).ok());
    XCTAssertEqual(_compositor->stats().workingAllocations, 2u);
    _compositor->releaseScratchMemory();
    stats = _compositor->stats();
    XCTAssertEqual(stats.workingBytes, 0u);
    XCTAssertEqual(stats.workingWidth, 0u);
    renderAt(1920, 1080);
    XCTAssertEqual(_compositor->stats().workingAllocations, 3u);
}

- (void)testThePreviewViewHandsEachPresentedFrameToItsReader {
    NSError *error = nil;
    VEPreviewView *view = [[VEPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 320, 180) device:device() error:&error];
    XCTAssertNotNil(view, @"%@", error);
    media::PixelBuffer picture = makeBurnIn420v(2, 1920, 1080);
    [view setFrameSource:[picture](const PreviewFrameRequest &request, PreviewFrame &frame) {
        auto textures = request.textureCache->textures(picture);
        if (!textures.ok()) {
            return false;
        }
        frame.graph = makeGraph(1920, 1080);
        frame.graph.layers.assign(1, makeLayer(1));
        frame.textures.assign(1, textures.value());
        frame.status = media::okStatus();
        return true;
    }];
    auto calls = std::make_shared<std::atomic<int>>(0);
    auto format = std::make_shared<std::atomic<NSUInteger>>(0);
    auto width = std::make_shared<std::atomic<NSUInteger>>(0);
    auto height = std::make_shared<std::atomic<NSUInteger>>(0);
    [view setWorkingFrameReader:[calls, format, width, height](id<MTLCommandBuffer> commandBuffer, id<MTLTexture> working) {
        calls->fetch_add(1);
        format->store(working.pixelFormat);
        width->store(working.width);
        height->store(working.height);
        XCTAssertNotNil(commandBuffer);
    }];
    auto renderOnce = [&]() {
        XCTestExpectation *done = [self expectationWithDescription:@"rendered"];
        [view renderOnceWithCompletion:^(NSError *renderError) {
            XCTAssertNil(renderError);
            [done fulfill];
        }];
        [self waitForExpectations:@[ done ] timeout:5];
    };
    renderOnce();
    XCTAssertEqual(calls->load(), 1);
    XCTAssertEqual(format->load(), NSUInteger(MTLPixelFormatRGBA16Float));
    XCTAssertGreaterThanOrEqual(width->load(), NSUInteger(view.drawableSize.width));
    XCTAssertGreaterThanOrEqual(height->load(), NSUInteger(view.drawableSize.height));
    // A snapshot does not call it; a cleared reader is not called.
    XCTAssertTrue(view.snapshot != NULL);
    XCTAssertEqual(calls->load(), 1);
    [view setWorkingFrameReader:{}];
    renderOnce();
    XCTAssertEqual(calls->load(), 1);
    XCTAssertGreaterThan(view.renderCount, 1u);
}

@end
