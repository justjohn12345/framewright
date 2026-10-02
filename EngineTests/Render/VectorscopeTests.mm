// The vectorscope (Vectorscope.h, VEWaveformView's vectorscope mode): synthetic 75 % colour bars land in the
// bins of the graticule's targets (grey at the centre), every sampled pixel counted once (also for a flat
// picture, whose samples a SIMD group adds at once), only the frame's rectangle counted; the display draws the
// trace at a bar's target inside its box, the ring, the skin tone line and black outside the square; the
// clipping counters; the view in vectorscope mode through the engine; the cost.

#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#include "../../Engine/Facade/VEWaveformView+Internal.h"
#include "../../Engine/Render/ScopeStats.h"
#include "../../Engine/Render/Vectorscope.h"
#include "CompositorTestSupport.h"

#include <algorithm>
#include <cmath>
#include <numeric>
#include <vector>

using namespace ve;
using namespace ve::render;
using namespace ve::rtest;

namespace {

constexpr std::uint32_t kBins = Vectorscope::kBins;

// The 75 % colour bars, in the usual order: grey, yellow, cyan, green, magenta, red, blue.
const std::array<std::array<double, 3>, 7> kBars = {
    {{0.75, 0.75, 0.75}, {0.75, 0.75, 0}, {0, 0.75, 0.75}, {0, 0.75, 0}, {0.75, 0, 0.75}, {0.75, 0, 0}, {0, 0, 0.75}}};

id<MTLTexture> barsFrame(size_t barWidth, size_t height) {
    return makeWorkingFrame(barWidth * kBars.size(), height, [&](size_t x, size_t) {
        const auto &bar = kBars[x / barWidth];
        return simd_make_float3(float(bar[0]), float(bar[1]), float(bar[2]));
    });
}

std::uint32_t countAt(const std::vector<std::uint32_t> &counts, std::array<std::uint32_t, 2> bin) {
    return counts[size_t(bin[1]) * kBins + bin[0]];
}

} // namespace

@interface VectorscopeTests : XCTestCase
@end

@implementation VectorscopeTests {
    std::unique_ptr<Vectorscope> _scope;
    std::unique_ptr<ScopeStatsRing> _ring;
    id<MTLCommandQueue> _queue;
}

- (void)setUp {
    auto scope = Vectorscope::create(device());
    XCTAssertTrue(scope.ok(), @"%s", scope.ok() ? "" : scope.error().description().c_str());
    if (scope.ok()) {
        _scope = std::move(scope).value();
    }
    _ring = std::move(ScopeStatsRing::create(device())).value();
    _queue = [device() newCommandQueue];
}

- (ClipStats)count:(id<MTLTexture>)working frame:(PixelRect)frame {
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    const PixelRect counted = clipToTexture(frame, int32_t(working.width), int32_t(working.height));
    const ScopeStatsSlot slot = _ring->begin(
        commands, std::uint64_t(counted.width) *
                      Vectorscope::sampleRowsFor(frame, int32_t(working.width), int32_t(working.height)));
    XCTAssertTrue(_scope->encodeAccumulate(commands, working, frame, &slot));
    [commands commit];
    [commands waitUntilCompleted];
    return _ring->read(slot).value_or(ClipStats{});
}

- (void)testColourBarsLandOnTheirTargets {
    const size_t barWidth = 40, height = 90;
    id<MTLTexture> bars = barsFrame(barWidth, height);
    [self count:bars frame:PixelRect{0, 0, int32_t(barWidth * kBars.size()), int32_t(height)}];
    const std::vector<std::uint32_t> counts = _scope->countsSnapshot();
    XCTAssertEqual(std::accumulate(counts.begin(), counts.end(), std::uint64_t(0)), barWidth * kBars.size() * height,
                   @"every pixel counted once");
    XCTAssertEqual(_scope->samples(), barWidth * kBars.size() * height);
    // Grey at the centre; each colour at its bin.
    XCTAssertEqual(countAt(counts, Vectorscope::binOf(0, 0)), barWidth * height);
    XCTAssertEqual(Vectorscope::binOf(0, 0)[0], kBins / 2);
    for (size_t i = 1; i < kBars.size(); ++i) {
        const auto chroma = Vectorscope::chromaOf(kBars[i]);
        XCTAssertEqual(countAt(counts, Vectorscope::binOf(chroma[0], chroma[1])), barWidth * height, @"bar %zu", i);
    }
    // The graticule's targets are those bars' chroma: red, magenta, blue, cyan, green, yellow.
    const auto targets = Vectorscope::barTargets();
    const auto red = Vectorscope::chromaOf(kBars[5]);
    XCTAssertEqualWithAccuracy(targets[0][0], red[0], 1e-12);
    XCTAssertEqualWithAccuracy(targets[0][1], red[1], 1e-12);
    // Red is up and a little left (Cr positive, Cb negative), blue to the right.
    XCTAssertGreaterThan(red[1], 0.3);
    XCTAssertLessThan(red[0], 0);
    XCTAssertGreaterThan(Vectorscope::chromaOf(kBars[6])[0], 0.3);
}

- (void)testFlatPicturesTheFrameRectangleAndClipping {
    // A flat colour: every sample on one bin (the SIMD groups' sums).
    id<MTLTexture> flat = makeWorkingFrame(301, 123, [](size_t, size_t) { return simd_make_float3(0.2f, 0.6f, 0.9f); });
    [self count:flat frame:PixelRect{0, 0, 301, 123}];
    const std::vector<std::uint32_t> counts = _scope->countsSnapshot();
    const auto chroma = Vectorscope::chromaOf({0.2, 0.6, 0.9});
    XCTAssertEqual(countAt(counts, Vectorscope::binOf(chroma[0], chroma[1])), 301u * 123u);
    // Letterbox bars (black) outside the frame's rectangle are not counted; rows beyond 540 are sampled.
    id<MTLTexture> boxed = makeWorkingFrame(200, 700, [](size_t x, size_t) {
        return x < 20 || x >= 180 ? simd_make_float3(0, 0, 0) : simd_make_float3(0.75f, 0, 0);
    });
    const ClipStats stats = [self count:boxed frame:PixelRect{20, 0, 160, 700}];
    XCTAssertEqual(Vectorscope::sampleRowsFor(PixelRect{20, 0, 160, 700}, 200, 700), 540u);
    const auto red = Vectorscope::chromaOf(kBars[5]);
    XCTAssertEqual(countAt(_scope->countsSnapshot(), Vectorscope::binOf(red[0], red[1])), 160u * 540u);
    XCTAssertEqual(countAt(_scope->countsSnapshot(), Vectorscope::binOf(0, 0)), 0u, @"no black bar counted");
    // 75 % red has green and blue at 0: clipped black in two channels, never white.
    XCTAssertEqual(stats.black, 160u * 540u);
    XCTAssertEqual(stats.white, 0u);
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    XCTAssertFalse(_scope->encodeAccumulate(commands, boxed, PixelRect{300, 0, 10, 10}));
    [commands commit];
}

- (void)testTheDisplayDrawsTheTraceAndTheGraticule {
    id<MTLTexture> bars = barsFrame(40, 90);
    id<MTLTexture> target = makeTargetTexture(600, 400); // the square: 400 x 400 from x = 100
    {
        auto fresh = Vectorscope::create(device());
        id<MTLCommandBuffer> empty = [_queue commandBuffer];
        XCTAssertFalse(fresh.value()->encodeDisplay(empty, target));
        [empty commit];
    }
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    XCTAssertTrue(_scope->encodeAccumulate(commands, bars, PixelRect{0, 0, 280, 90}));
    XCTAssertTrue(_scope->encodeDisplay(commands, target));
    [commands commit];
    [commands waitUntilCompleted];
    const auto pixelOf = [](double cb, double cr) {
        return std::pair<size_t, size_t>{size_t(100 + (cb + 0.5) * 400), size_t((0.5 - cr) * 400)};
    };
    // The trace at red's chroma, in its box.
    const auto red = Vectorscope::chromaOf(kBars[5]);
    const auto [rx, ry] = pixelOf(red[0], red[1]);
    const RGBA8 trace = texturePixel(target, rx, ry);
    XCTAssertGreaterThan(trace.g, 150, @"%d %d %d", trace.r, trace.g, trace.b);
    // The box's edge 0.025 of the square (10 px) from the target, with no trace.
    const RGBA8 box = texturePixel(target, rx + 10, ry);
    XCTAssertGreaterThan(box.r, 90);
    XCTAssertEqual(box.r, box.g);
    // The ring at chroma 0.5 (left edge of the circle) and the skin tone line half way out.
    const RGBA8 ring = texturePixel(target, 100, 200);
    XCTAssertGreaterThan(ring.r, 40);
    const double skin = Vectorscope::kSkinToneDegrees * M_PI / 180.0;
    const auto [sx, sy] = pixelOf(0.25 * std::cos(skin), 0.25 * std::sin(skin));
    XCTAssertGreaterThan(texturePixel(target, sx, sy).r, 60);
    // Outside the square: black; empty chroma away from the graticule: black.
    const RGBA8 outside = texturePixel(target, 40, 200);
    XCTAssertEqual(outside.r + outside.g + outside.b, 0);
    const auto [ex, ey] = pixelOf(0.12, -0.31);
    const RGBA8 empty = texturePixel(target, ex, ey);
    XCTAssertEqual(empty.r + empty.g + empty.b, 0);
}

- (void)testTheViewDrawsTheVectorscope {
    VEWaveformView *scope = [[VEWaveformView alloc] initWithFrame:NSMakeRect(0, 0, 320, 180)];
    XCTAssertNil(scope.lastError);
    scope.mode = VEScopeModeVectorscope;
    XCTAssertEqual(scope.mode, VEScopeModeVectorscope);
    id<MTLTexture> target = makeTargetTexture(320, 180);
    [scope setTargetProviderForTesting:^id<MTLTexture> {
        return target;
    }];
    // The view's reader, run on a frame of colour bars as the program view would.
    const WorkingFrameReader reader = [scope workingFrameReader];
    id<MTLTexture> bars = barsFrame(40, 90);
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    reader(commands, bars, PixelRect{0, 0, 280, 90});
    [commands commit];
    [commands waitUntilCompleted];
    const std::vector<std::uint32_t> counts = [scope vectorscopeCountsForTesting];
    XCTAssertEqual(countAt(counts, Vectorscope::binOf(0, 0)), 40u * 90u);
    const NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (scope.drawCount == 0 && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    XCTAssertEqual(scope.drawCount, 1u);
    XCTAssertEqual([scope clipStatsForTesting].samples, 280u * 90u);
}

- (void)testTheVectorscopesCost {
    id<MTLTexture> target = makeTargetTexture(1200, 676);
    struct Scene {
        const char *name;
        size_t width, height;
        bool flat;
    };
    const Scene scenes[] = {{"1080p picture", 1920, 1080, false}, {"1080p flat", 1920, 1080, true},
                            {"2160p picture", 3840, 2160, false}, {"2160p flat", 3840, 2160, true}};
    for (const Scene &scene : scenes) {
        id<MTLTexture> frame = makeWorkingFrame(scene.width, scene.height, [&](size_t x, size_t y) {
            const float v = scene.flat ? 0.5f : float((x * 7 + y * 3) % 256) / 255.0f;
            return scene.flat ? simd_make_float3(0.7f, 0.3f, 0.2f) : simd_make_float3(v, 1.0f - v, 0.5f * v);
        });
        std::vector<double> gpu;
        for (int i = 0; i < 90; ++i) {
            id<MTLCommandBuffer> commands = [_queue commandBuffer];
            const ScopeStatsSlot slot = _ring->begin(commands, std::uint64_t(scene.width) * 540);
            _scope->encodeAccumulate(commands, frame, PixelRect{0, 0, int32_t(scene.width), int32_t(scene.height)}, &slot);
            _scope->encodeDisplay(commands, target);
            [commands commit];
            [commands waitUntilCompleted];
            if (i >= 30) {
                gpu.push_back((commands.GPUEndTime - commands.GPUStartTime) * 1000.0);
            }
        }
        std::sort(gpu.begin(), gpu.end());
        NSLog(@"SCOPE COST vectorscope %s: GPU %.3f ms (median of 60)", scene.name, gpu[gpu.size() / 2]);
        XCTAssertLessThan(gpu[gpu.size() / 2], 2.0);
    }
}

@end
