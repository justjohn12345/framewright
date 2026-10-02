// The histogram (Histogram.h), the clipping counters every scope counts (ScopeStats.h), the monitor's clipping
// overlay (TextureTarget::clippingOverlay), and the scope view's modes through the engine (VEWaveformView):
//   - the histogram on synthetic RGBA16Float frames: flat grey gives one spike per channel, a ramp a flat
//     histogram, pure red counts only in the red channel's top level (green and blue at black), only the
//     frame's rectangle is counted (letterbox bars are not), the tallest bars with and without the end bins;
//   - the display in each style;
//   - the clipping counters from the histogram's and the waveform's passes (exact shares), the tolerance at
//     both ends, and the ring dropping a slot a later frame reused;
//   - the overlay tinting clipped pixels of a monitor and nothing else;
//   - the view in histogram mode drawn with the program monitor's frames, its clipping published on the main
//     thread, a mode change asking for a frame, and the waveform's columns following the view's width;
//   - the GPU cost of each scope at 1080p and 2160p.

#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#include "../../Engine/Facade/VEWaveformView+Internal.h"
#include "../../Engine/Render/Histogram.h"
#include "../../Engine/Render/LumaWaveform.h"
#include "../../Engine/Render/ScopeStats.h"
#import "../../Engine/Render/VEPreviewView+Internal.h"
#include "../Media/TestMedia.h"
#include "CompositorTestSupport.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <numeric>
#include <string>
#include <vector>

using namespace ve;
using namespace ve::render;
using namespace ve::rtest;

namespace {

constexpr std::uint32_t kBins = Histogram::kBins;

std::uint64_t total(const std::array<std::uint32_t, kBins> &counts) {
    return std::accumulate(counts.begin(), counts.end(), std::uint64_t(0));
}

simd_float3 grey(float v) {
    return simd_make_float3(v, v, v);
}

double median(std::vector<double> values) {
    std::sort(values.begin(), values.end());
    return values.empty() ? 0.0 : values[values.size() / 2];
}

} // namespace

@interface ScopeTests : XCTestCase
@end

@implementation ScopeTests {
    std::unique_ptr<Histogram> _histogram;
    std::unique_ptr<ScopeStatsRing> _ring;
    id<MTLCommandQueue> _queue;
}

- (void)setUp {
    auto histogram = Histogram::create(device());
    XCTAssertTrue(histogram.ok(), @"%s", histogram.ok() ? "" : histogram.error().description().c_str());
    if (histogram.ok()) {
        _histogram = std::move(histogram).value();
    }
    auto ring = ScopeStatsRing::create(device());
    XCTAssertTrue(ring.ok());
    if (ring.ok()) {
        _ring = std::move(ring).value();
    }
    _queue = [device() newCommandQueue];
}

/// Counts `frame` of `working` in the histogram (with clipping counters) and waits; the clipping counts.
- (ClipStats)count:(id<MTLTexture>)working frame:(PixelRect)frame {
    const PixelRect counted = clipToTexture(frame, int32_t(working.width), int32_t(working.height));
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    const ScopeStatsSlot slot = _ring->begin(commands, std::uint64_t(counted.width) * std::uint64_t(counted.height));
    XCTAssertTrue(_histogram->encodeAccumulate(commands, working, frame, &slot));
    [commands commit];
    [commands waitUntilCompleted];
    const std::optional<ClipStats> stats = _ring->read(slot);
    XCTAssertTrue(stats.has_value());
    return stats.value_or(ClipStats{});
}

// MARK: - The counts

- (void)testFlatGreyGivesASpike {
    const size_t w = 320, h = 90;
    // 102 / 255: every channel and the luma at level 102 (the half float rounds by far less than a level).
    id<MTLTexture> frame = makeWorkingFrame(w, h, [](size_t, size_t) { return grey(102.0f / 255.0f); });
    [self count:frame frame:PixelRect{0, 0, int32_t(w), int32_t(h)}];
    XCTAssertEqual(_histogram->samples(), w * h);
    for (HistogramChannel channel :
         {HistogramChannel::Red, HistogramChannel::Green, HistogramChannel::Blue, HistogramChannel::Luma}) {
        const auto counts = _histogram->counts(channel);
        XCTAssertEqual(counts[102], w * h, @"channel %u: every pixel in the one bin", unsigned(channel));
        XCTAssertEqual(total(counts), w * h, @"channel %u: nothing elsewhere", unsigned(channel));
    }
    const auto maxima = _histogram->maxima();
    XCTAssertEqual(maxima[0], w * h);
    XCTAssertEqual(maxima[1], w * h);
    XCTAssertEqual(maxima[2], w * h);
    XCTAssertEqual(maxima[3], w * h);
}

- (void)testARampGivesAFlatHistogram {
    // 256 columns, column x at level x: every bin of every channel holds one column's 40 pixels.
    const size_t w = 256, h = 40;
    id<MTLTexture> frame = makeWorkingFrame(w, h, [](size_t x, size_t) { return grey(float(x) / 255.0f); });
    [self count:frame frame:PixelRect{0, 0, int32_t(w), int32_t(h)}];
    for (HistogramChannel channel :
         {HistogramChannel::Red, HistogramChannel::Green, HistogramChannel::Blue, HistogramChannel::Luma}) {
        const auto counts = _histogram->counts(channel);
        for (std::uint32_t b = 0; b < kBins; ++b) {
            XCTAssertEqual(counts[b], h, @"channel %u bin %u", unsigned(channel), b);
        }
    }
    const auto maxima = _histogram->maxima();
    XCTAssertEqual(maxima[0], h);
    XCTAssertEqual(maxima[1], h);
    // A ramp twice as tall in its right half: the tallest bars follow.
    id<MTLTexture> steps = makeWorkingFrame(w, h, [](size_t x, size_t y) {
        return x >= 128 || y < 20 ? grey(float(x) / 255.0f) : grey(1.0f);
    });
    [self count:steps frame:PixelRect{0, 0, int32_t(w), int32_t(h)}];
    const auto luma = _histogram->counts(HistogramChannel::Luma);
    XCTAssertEqual(luma[10], 20u);
    XCTAssertEqual(luma[200], 40u);
    XCTAssertEqual(luma[255], 40u + 128u * 20u, @"the white end: its own column and half of each left column");
    const auto tallest = _histogram->maxima();
    XCTAssertEqual(tallest[1], 40u, @"between the end bins");
    XCTAssertEqual(tallest[3], 40u + 128u * 20u, @"over every bin");
}

- (void)testPureRedCountsOnlyInRed {
    const size_t w = 200, h = 50;
    id<MTLTexture> frame = makeWorkingFrame(w, h, [](size_t, size_t) { return simd_make_float3(1.0f, 0.0f, 0.0f); });
    const ClipStats stats = [self count:frame frame:PixelRect{0, 0, int32_t(w), int32_t(h)}];
    const auto red = _histogram->counts(HistogramChannel::Red);
    const auto green = _histogram->counts(HistogramChannel::Green);
    const auto blue = _histogram->counts(HistogramChannel::Blue);
    const auto luma = _histogram->counts(HistogramChannel::Luma);
    XCTAssertEqual(red[255], w * h, @"red at its top level");
    XCTAssertEqual(total(red), w * h);
    XCTAssertEqual(green[0], w * h, @"green and blue at black");
    XCTAssertEqual(blue[0], w * h);
    XCTAssertEqual(total(green), w * h);
    XCTAssertEqual(total(blue), w * h);
    XCTAssertEqual(luma[54], w * h, @"luma 0.2126 of white");
    // Red is at white and green and blue at black: every pixel is clipped at both ends.
    XCTAssertEqual(stats.samples, w * h);
    XCTAssertEqual(stats.white, w * h);
    XCTAssertEqual(stats.black, w * h);
}

- (void)testOnlyTheFramesRectangleIsCounted {
    // A white 200x100 frame at (20, 10) of a 240x120 working texture, black (letterbox) around it.
    const PixelRect frame{20, 10, 200, 100};
    id<MTLTexture> boxed = makeWorkingFrame(240, 120, [&](size_t x, size_t y) {
        const bool inside = int(x) >= frame.x && int(x) < frame.x + frame.width && int(y) >= frame.y &&
                            int(y) < frame.y + frame.height;
        return inside ? grey(1.0f) : grey(0.0f);
    });
    const ClipStats stats = [self count:boxed frame:frame];
    const auto luma = _histogram->counts(HistogramChannel::Luma);
    XCTAssertEqual(luma[0], 0u, @"the bars are not counted");
    XCTAssertEqual(luma[255], 200u * 100u);
    XCTAssertEqual(stats.black, 0u);
    XCTAssertEqual(stats.white, 200u * 100u);
    // A rectangle reaching outside the texture is clipped to it; an empty one encodes nothing.
    [self count:boxed frame:PixelRect{200, 0, 400, 120}];
    XCTAssertEqual(_histogram->samples(), 40u * 120u);
    XCTAssertTrue(_histogram->countedFrame() == (PixelRect{200, 0, 40, 120}));
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    XCTAssertFalse(_histogram->encodeAccumulate(commands, boxed, PixelRect{300, 0, 10, 10}));
    XCTAssertFalse(_histogram->encodeAccumulate(commands, boxed, PixelRect{}));
    [commands commit];
    // A frame larger than one tile in both directions and not a multiple of it: every pixel once.
    id<MTLTexture> large = makeWorkingFrame(301, 133, [](size_t x, size_t y) { return grey(float((x + y) % 256) / 255.0f); });
    [self count:large frame:PixelRect{0, 0, 301, 133}];
    XCTAssertEqual(total(_histogram->counts(HistogramChannel::Luma)), 301u * 133u);
    XCTAssertEqual(total(_histogram->counts(HistogramChannel::Red)), 301u * 133u);
}

// MARK: - The display

- (void)testTheDisplayDrawsEachStyle {
    const size_t w = 256, h = 64;
    id<MTLTexture> frame = makeWorkingFrame(w, h, [](size_t, size_t) { return grey(102.0f / 255.0f); });
    id<MTLTexture> target = makeTargetTexture(512, 100);
    // Nothing accumulated yet: nothing to draw.
    {
        auto fresh = Histogram::create(device());
        XCTAssertTrue(fresh.ok());
        id<MTLCommandBuffer> empty = [_queue commandBuffer];
        XCTAssertFalse(fresh.value()->encodeDisplay(empty, target, HistogramStyle::RGBAndLuma));
        [empty commit];
    }
    auto draw = [&](HistogramStyle style, id<MTLTexture> into) {
        id<MTLCommandBuffer> commands = [_queue commandBuffer];
        XCTAssertTrue(_histogram->encodeAccumulate(commands, frame, PixelRect{0, 0, int32_t(w), int32_t(h)}));
        XCTAssertTrue(_histogram->encodeDisplay(commands, into, style));
        [commands commit];
        [commands waitUntilCompleted];
    };
    // Level 102 of 256 bins over 512 pixels: columns 204 and 205. The one bar fills 0.94 of the height.
    draw(HistogramStyle::RGBAndLuma, target);
    const RGBA8 bar = texturePixel(target, 204, 90);
    XCTAssertTrue(near(bar, 184, 184, 184, 3), @"R, G and B overlaid: grey (%d %d %d)", bar.r, bar.g, bar.b);
    const RGBA8 top = texturePixel(target, 204, 6); // up = 0.935: the luma bar's top
    XCTAssertGreaterThan(top.r, 230);
    XCTAssertEqual(top.r, top.g);
    const RGBA8 empty = texturePixel(target, 100, 90);
    XCTAssertTrue(near(empty, 0, 0, 0, 0), @"no bar: black (%d %d %d)", empty.r, empty.g, empty.b);
    const RGBA8 quarter = texturePixel(target, 128, 40); // the 25 % line
    XCTAssertGreaterThan(quarter.r, 20);
    draw(HistogramStyle::Luma, target);
    const RGBA8 lumaBar = texturePixel(target, 204, 50);
    XCTAssertTrue(near(lumaBar, 199, 199, 199, 3), @"luma: light grey (%d %d %d)", lumaBar.r, lumaBar.g, lumaBar.b);
    // Parade into 768 pixels: three sections of 256, one pixel per level; level 102 at 102 into each.
    id<MTLTexture> wide = makeTargetTexture(768, 100);
    draw(HistogramStyle::Parade, wide);
    target = wide;
    const RGBA8 redBar = texturePixel(target, 102, 80);
    const RGBA8 greenBar = texturePixel(target, 256 + 102, 80);
    const RGBA8 blueBar = texturePixel(target, 512 + 102, 80);
    const RGBA8 beside = texturePixel(target, 256 + 101, 80);
    XCTAssertTrue(near(beside, 0, 0, 0, 0), @"one level only (%d %d %d)", beside.r, beside.g, beside.b);
    XCTAssertGreaterThan(redBar.r, 200);
    XCTAssertLessThan(redBar.g, 80);
    XCTAssertGreaterThan(greenBar.g, 200);
    XCTAssertLessThan(greenBar.r, 80);
    XCTAssertGreaterThan(blueBar.b, 200);
    XCTAssertLessThan(blueBar.r, 100);
    const RGBA8 divider = texturePixel(target, 257, 50);
    XCTAssertTrue(near(divider, 56, 56, 56, 2), @"the line between sections (%d %d %d)", divider.r, divider.g, divider.b);
}

// MARK: - Clipping

/// A frame of known shares: 10 % white, 5 % (1, 0.5, 0.5) (red at white), 20 % black, 5 % (0.5, 0.5, 0)
/// (blue at black), the rest mid grey; 200 x 100.
- (id<MTLTexture>)clippingFrame {
    return makeWorkingFrame(200, 100, [](size_t x, size_t) {
        if (x < 20) {
            return grey(1.0f);
        }
        if (x < 30) {
            return simd_make_float3(1.0f, 0.5f, 0.5f);
        }
        if (x < 70) {
            return grey(0.0f);
        }
        if (x < 80) {
            return simd_make_float3(0.5f, 0.5f, 0.0f);
        }
        return grey(0.5f);
    });
}

- (void)testTheHistogramPassCountsTheClippedShares {
    const ClipStats stats = [self count:[self clippingFrame] frame:PixelRect{0, 0, 200, 100}];
    XCTAssertEqual(stats.samples, 20000u);
    XCTAssertEqual(stats.white, 3000u);
    XCTAssertEqual(stats.black, 5000u);
    XCTAssertEqualWithAccuracy(stats.whiteFraction(), 0.15, 1e-12);
    XCTAssertEqualWithAccuracy(stats.blackFraction(), 0.25, 1e-12);
}

- (void)testTheWaveformPassCountsTheClippedShares {
    WaveformSettings settings;
    settings.columns = 200;
    settings.maxSampleRows = 360; // the frame's 100 rows are all sampled
    auto created = LumaWaveform::create(device(), settings);
    XCTAssertTrue(created.ok());
    LumaWaveform &waveform = *created.value();
    id<MTLTexture> frame = [self clippingFrame];
    const PixelRect rect{0, 0, 200, 100};
    XCTAssertEqual(waveform.sampleRowsFor(rect, 200, 100), 100u);
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    const ScopeStatsSlot slot = _ring->begin(commands, 200u * waveform.sampleRowsFor(rect, 200, 100));
    XCTAssertTrue(waveform.encodeAccumulate(commands, frame, rect, 50, &slot));
    [commands commit];
    [commands waitUntilCompleted];
    const std::optional<ClipStats> stats = _ring->read(slot);
    XCTAssertTrue(stats.has_value());
    XCTAssertEqual(stats->white, 3000u);
    XCTAssertEqual(stats->black, 5000u);
    // 50 columns chosen for this frame: each counts its 4 pixel columns' 100 samples.
    XCTAssertEqual(waveform.columns(), 50u);
    const std::vector<std::uint32_t> counts = waveform.countsSnapshot();
    for (std::uint32_t c = 0; c < 50; ++c) {
        std::uint64_t column = 0;
        for (std::uint32_t l = 0; l < settings.levels; ++l) {
            column += counts[size_t(l) * 50 + c];
        }
        XCTAssertEqual(column, 400u, @"column %u", c);
    }
    // Rows sampled for a frame taller than the setting.
    XCTAssertEqual(waveform.sampleRowsFor(PixelRect{0, 0, 10, 1000}, 10, 1000), 360u);
    XCTAssertEqual(waveform.sampleRowsFor(PixelRect{20, 0, 10, 10}, 10, 10), 0u);
}

- (void)testTheClippingToleranceAtBothEnds {
    // Columns: the largest half below 1 (not white); 1 (white); 1.5 (white); 10-bit code 1, 2^-10 (not
    // black); the smallest half subnormal, the matrix's residue at video black (black); 0 (black); -0.1
    // (black); mid grey (neither). 8 columns of 10 x 10 pixels.
    const float values[8] = {1.0f - 1.0f / 2048.0f, 1.0f, 1.5f, 1.0f / 1024.0f, 5.96e-8f, 0.0f, -0.1f, 0.5f};
    id<MTLTexture> frame = makeWorkingFrame(80, 10, [&](size_t x, size_t) { return grey(values[x / 10]); });
    const ClipStats stats = [self count:frame frame:PixelRect{0, 0, 80, 10}];
    XCTAssertEqual(stats.white, 2u * 100u, @"1 and 1.5");
    XCTAssertEqual(stats.black, 3u * 100u, @"the residue, 0 and -0.1");
}

- (void)testTheRingDropsASlotALaterFrameReused {
    id<MTLTexture> frame = makeWorkingFrame(64, 64, [](size_t, size_t) { return grey(1.0f); });
    std::vector<ScopeStatsSlot> slots;
    for (std::size_t i = 0; i < ScopeStatsRing::kSlots + 1; ++i) {
        id<MTLCommandBuffer> commands = [_queue commandBuffer];
        slots.push_back(_ring->begin(commands, 64u * 64u));
        XCTAssertTrue(_histogram->encodeAccumulate(commands, frame, PixelRect{0, 0, 64, 64}, &slots.back()));
        [commands commit];
        [commands waitUntilCompleted];
    }
    XCTAssertFalse(_ring->read(slots.front()).has_value(), @"the first slot was reused by the last frame");
    for (std::size_t i = 1; i < slots.size(); ++i) {
        const std::optional<ClipStats> stats = _ring->read(slots[i]);
        XCTAssertTrue(stats.has_value(), @"frame %zu", i);
        XCTAssertEqual(stats.value_or(ClipStats{}).white, 64u * 64u);
    }
    XCTAssertEqual(slots.back().index, slots.front().index);
    XCTAssertNotEqual(slots.back().offset, slots[1].offset);
}

// MARK: - The monitor overlay

- (void)testTheOverlayTintsClippedPixelsOfAMonitorOnly {
    auto created = Compositor::create(device(), {MTLPixelFormatBGRA8Unorm});
    XCTAssertTrue(created.ok());
    Compositor &compositor = *created.value();
    // Three vertical stripes: white, black and mid grey.
    media::PixelBuffer picture = makeBuffer(kCVPixelFormatType_32BGRA, 300, 100);
    fillBGRARect(picture, 0, 0, 100, 100, RGBA8{255, 255, 255, 255});
    fillBGRARect(picture, 100, 0, 200, 100, RGBA8{0, 0, 0, 255});
    fillBGRARect(picture, 200, 0, 300, 100, RGBA8{128, 128, 128, 255});
    RenderGraph graph = makeGraph(300, 100);
    graph.layers.push_back(makeLayer(1));
    const std::vector<TextureSet> textures{texturesFor(compositor, picture)};
    id<MTLTexture> target = makeTargetTexture(300, 100);
    TextureTarget overlay;
    overlay.texture = target;
    overlay.clippingOverlay = true;
    XCTAssertTrue(renderLayers(compositor, graph, textures, overlay).ok());
    XCTAssertTrue(near(texturePixel(target, 50, 50), 255, 0, 0, 0), @"white is shown red");
    XCTAssertTrue(near(texturePixel(target, 150, 50), 0, 64, 255, 1), @"black is shown blue");
    XCTAssertTrue(near(texturePixel(target, 250, 50), 128, 128, 128, 1), @"mid grey is unchanged");
    // Letterboxed in a wider target: the bars stay black.
    id<MTLTexture> wide = makeTargetTexture(400, 100);
    TextureTarget boxed;
    boxed.texture = wide;
    boxed.clippingOverlay = true;
    XCTAssertTrue(renderLayers(compositor, graph, textures, boxed).ok());
    XCTAssertTrue(near(texturePixel(wide, 20, 50), 0, 0, 0, 0), @"a bar is not tinted");
    XCTAssertTrue(near(texturePixel(wide, 380, 50), 0, 0, 0, 0), @"a bar is not tinted");
    XCTAssertTrue(near(texturePixel(wide, 100, 50), 255, 0, 0, 0), @"the frame's white is");
    XCTAssertTrue(near(texturePixel(wide, 200, 50), 0, 64, 255, 1), @"the frame's black is");
    TextureTarget plain;
    plain.texture = target;
    XCTAssertTrue(renderLayers(compositor, graph, textures, plain).ok());
    XCTAssertTrue(near(texturePixel(target, 50, 50), 255, 255, 255, 0));
    XCTAssertTrue(near(texturePixel(target, 150, 50), 0, 0, 0, 0));
    // An export target never has the overlay (it has no such field): BGRA pixel buffers stay white.
    media::PixelBuffer exported = makeBuffer(kCVPixelFormatType_32BGRA, 300, 100);
    XCTAssertTrue(renderLayers(compositor, graph, textures, PixelBufferTarget{exported}).ok());
    XCTAssertTrue(near(pixelAt(exported, 50, 50), 255, 255, 255, 0));
}

// MARK: - The view, through the engine

- (void)testTheViewDrawsTheHistogramAndPublishesTheClipping {
    NSURL *scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
    VEEngine *engine = [[VEEngine alloc] initWithCacheDirectory:[scratch URLByAppendingPathComponent:@"Caches"]];
    std::string error;
    const std::string path = ve::test::testMediaPath("h264_1080p30.mp4", error);
    XCTAssertTrue(error.empty(), @"%s", error.c_str());
    XCTestExpectation *imported = [self expectationWithDescription:@"import"];
    __block VEAssetInfo *asset = nil;
    [engine importMediaAtURLs:@[ [NSURL fileURLWithPath:@(path.c_str())] ]
                   completion:^(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *) {
                       asset = assets.firstObject;
                       [imported fulfill];
                   }];
    [self waitForExpectations:@[ imported ] timeout:60];
    XCTAssertNotNil(asset);
    VEEditResult *placed = [engine overwriteAsset:asset.assetID
                                           atTime:kCMTimeZero
                                       videoTrack:engine.sequence.videoTrackIDs[0].longLongValue
                                       audioTrack:0
                                         sourceIn:CMTimeMake(30, 30)
                                        sourceOut:CMTimeMake(60, 30)];
    XCTAssertTrue(placed.ok, @"%@", placed.message);
    const VEClipID clip = placed.createdIDs.firstObject.longLongValue;

    VEPreviewView *program = [[VEPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 480, 270)];
    VEWaveformView *scope = [[VEWaveformView alloc] initWithFrame:NSMakeRect(0, 0, 320, 180)];
    XCTAssertNil(scope.lastError);
    XCTAssertEqual(scope.mode, VEScopeModeWaveform);
    XCTAssertEqual(scope.histogramStyle, VEHistogramStyleRGBAndLuma);
    id<MTLTexture> target = makeTargetTexture(320, 180);
    [scope setTargetProviderForTesting:^id<MTLTexture> {
        return target;
    }];
    __block NSUInteger handlerCalls = 0;
    __block double lastHighlights = -1, lastShadows = -1;
    scope.clippingHandler = ^(double highlights, double shadows) {
        XCTAssertTrue(NSThread.isMainThread);
        ++handlerCalls;
        lastHighlights = highlights;
        lastShadows = shadows;
    };
    [engine attachProgramView:program];
    [engine attachWaveformView:scope];

    auto renderAndWait = [&] {
        XCTestExpectation *rendered = [self expectationWithDescription:@"rendered"];
        [program renderOnceWithCompletion:^(NSError *) {
            [rendered fulfill];
        }];
        [self waitForExpectations:@[ rendered ] timeout:5];
    };
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    while (program.missingLayerCount != 0 || program.renderCount == 0) {
        renderAndWait();
        if (deadline.timeIntervalSinceNow < 0) {
            break;
        }
    }
    renderAndWait();
    // Waveform mode: as many columns as the view's 320 pixel columns.
    XCTAssertEqual([scope settingsForTesting].columns, 320u);

    // Histogram mode: the change asks the program monitor for a frame by itself.
    const NSUInteger drawnBefore = scope.drawCount;
    scope.mode = VEScopeModeHistogram;
    XCTAssertEqual(scope.mode, VEScopeModeHistogram);
    const BOOL redrawn = [self waitFor:^BOOL {
        return scope.drawCount > drawnBefore;
    } timeout:5];
    XCTAssertTrue(redrawn, @"a mode change draws the scope without a render from the caller");
    renderAndWait();
    const auto luma = [scope histogramCountsForTesting:HistogramChannel::Luma];
    const ClipStats frameStats = [scope clipStatsForTesting];
    XCTAssertGreaterThan(frameStats.samples, 0u);
    XCTAssertEqual(total(luma), frameStats.samples, @"every pixel of the frame counted once");
    XCTAssertEqual(total([scope histogramCountsForTesting:HistogramChannel::Red]), frameStats.samples);

    // Strong exposure: most of the picture clips white; the main thread hears of it.
    XCTAssertTrue([engine setGradeValue:5 forParameter:VEGradeParameterExposure clips:@[ @(clip) ]].ok);
    renderAndWait();
    const BOOL published = [self waitFor:^BOOL {
        return scope.clippedHighlightFraction > 0.3;
    } timeout:5];
    XCTAssertTrue(published, @"highlights %.3f", scope.clippedHighlightFraction);
    XCTAssertGreaterThan(handlerCalls, 0u);
    XCTAssertEqual(lastHighlights, scope.clippedHighlightFraction);
    XCTAssertEqual(lastShadows, scope.clippedShadowFraction);
    const ClipStats bright = [scope clipStatsForTesting];
    XCTAssertEqualWithAccuracy(scope.clippedHighlightFraction, bright.whiteFraction(), 1e-12);
    NSLog(@"SCOPE clipping at exposure +5: %.1f %% highlights, %.1f %% shadows", 100 * bright.whiteFraction(),
          100 * bright.blackFraction());
    // The style changes the drawing only; an invalid mode or style is ignored.
    scope.histogramStyle = VEHistogramStyleParade;
    XCTAssertEqual(scope.histogramStyle, VEHistogramStyleParade);
    scope.mode = VEScopeMode(7);
    XCTAssertEqual(scope.mode, VEScopeModeHistogram);
    scope.histogramStyle = VEHistogramStyle(-1);
    XCTAssertEqual(scope.histogramStyle, VEHistogramStyleParade);

    // The clipping overlay is the program view's, kept for a program view attached later.
    XCTAssertFalse(engine.showsClippingOverlay);
    engine.showsClippingOverlay = YES;
    XCTAssertTrue(engine.showsClippingOverlay);
    XCTAssertTrue(program.clippingOverlay);
    [engine attachProgramView:nil];
    XCTAssertFalse(program.clippingOverlay, @"a detached view loses it");
    VEPreviewView *other = [[VEPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 480, 270)];
    [engine attachProgramView:other];
    XCTAssertTrue(other.clippingOverlay);
    engine.showsClippingOverlay = NO;
    XCTAssertFalse(other.clippingOverlay);
    [engine attachWaveformView:nil];
    [engine attachProgramView:nil];
}

/// Spins the main run loop until `condition` holds or `timeout` seconds pass.
- (BOOL)waitFor:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition()) {
        if (deadline.timeIntervalSinceNow < 0) {
            return NO;
        }
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return YES;
}

// MARK: - Cost

- (void)testTheScopesCost {
    WaveformSettings settings;
    settings.columns = 2048; // the view's
    auto waveformCreated = LumaWaveform::create(device(), settings);
    XCTAssertTrue(waveformCreated.ok());
    LumaWaveform &waveform = *waveformCreated.value();
    Histogram &histogram = *_histogram;
    id<MTLTexture> target = makeTargetTexture(1200, 676); // a wide panel on a Retina display
    struct Scene {
        const char *name;
        size_t width, height;
        bool flat; // every pixel the same grey: all samples on one counter (the worst contention)
    };
    const Scene scenes[] = {{"1080p picture", 1920, 1080, false}, {"1080p flat grey", 1920, 1080, true},
                            {"2160p picture", 3840, 2160, false}, {"2160p flat grey", 3840, 2160, true}};
    for (const Scene &scene : scenes) {
        const size_t w = scene.width, h = scene.height;
        id<MTLTexture> frame = makeWorkingFrame(w, h, [&](size_t x, size_t y) {
            const float v = scene.flat ? 0.5f : float((x * 7 + y * 3) % 256) / 255.0f;
            return scene.flat ? grey(v) : simd_make_float3(v, 1.0f - v, 0.5f * v);
        });
        const PixelRect rect{0, 0, int32_t(w), int32_t(h)};
        for (int which = 0; which < 2; ++which) {
            std::vector<double> gpu;
            for (int i = 0; i < 90; ++i) {
                id<MTLCommandBuffer> commands = [_queue commandBuffer];
                if (which == 0) {
                    const ScopeStatsSlot slot = _ring->begin(commands, std::uint64_t(w) * h);
                    histogram.encodeAccumulate(commands, frame, rect, &slot);
                    histogram.encodeDisplay(commands, target, HistogramStyle::RGBAndLuma);
                } else {
                    const ScopeStatsSlot slot = _ring->begin(commands, std::uint64_t(w) * 360);
                    waveform.encodeAccumulate(commands, frame, rect, 1200, &slot);
                    waveform.encodeDisplay(commands, target);
                }
                [commands commit];
                [commands waitUntilCompleted];
                if (i >= 30) { // warm-up: the GPU's clocks come up
                    gpu.push_back((commands.GPUEndTime - commands.GPUStartTime) * 1000.0);
                }
            }
            const double cost = median(gpu);
            NSLog(@"SCOPE COST %s %s: GPU %.3f ms (median of 60)", which == 0 ? "histogram" : "waveform (1200 columns)",
                  scene.name, cost);
            XCTAssertLessThan(cost, 2.0, @"a small share of a 60 fps frame's 16.7 ms");
        }
    }
}

@end
