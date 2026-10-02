// The luma waveform (LumaWaveform.h, VEWaveformView): the compute pass on synthetic RGBA16Float frames (a
// horizontal ramp gives a diagonal, flat grey a line, a colour its luma, only the frame's rectangle is
// counted, every column counts its share of the pixels), the display pass (the trace where the counts are,
// the graticule every 10 IRE), the view drawn with the program monitor's frames through the engine (and
// showing the graded picture; nothing once detached), and the cost on the GPU and on the render thread.

#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#include "../../Engine/Facade/VEWaveformView+Internal.h"
#include "../../Engine/Render/LumaWaveform.h"
#include "../Media/TestMedia.h"
#include "CompositorTestSupport.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <functional>
#include <numeric>
#include <string>
#include <vector>

using namespace ve;
using namespace ve::render;
using namespace ve::rtest;

namespace {

// A shared RGBA16Float texture whose pixel (x, y) is `colour(x, y)` (R, G, B; alpha 1).
id<MTLTexture> makeFrame(size_t width, size_t height, const std::function<simd_float3(size_t, size_t)> &colour) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device() newTextureWithDescriptor:desc];
    std::vector<_Float16> texels(width * height * 4);
    for (size_t y = 0; y < height; ++y) {
        for (size_t x = 0; x < width; ++x) {
            const simd_float3 c = colour(x, y);
            _Float16 *t = &texels[(y * width + x) * 4];
            t[0] = _Float16(c.x);
            t[1] = _Float16(c.y);
            t[2] = _Float16(c.z);
            t[3] = _Float16(1.0f);
        }
    }
    [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:texels.data() bytesPerRow:width * 8];
    return texture;
}

id<MTLTexture> makeTarget(size_t width, size_t height) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    return [device() newTextureWithDescriptor:desc];
}

struct Counts {
    std::vector<std::uint32_t> values;
    std::uint32_t columns = 0;
    std::uint32_t levels = 0;

    std::uint32_t at(std::uint32_t column, std::uint32_t level) const {
        return values[size_t(level) * columns + column];
    }
    std::uint64_t columnTotal(std::uint32_t column) const {
        std::uint64_t total = 0;
        for (std::uint32_t l = 0; l < levels; ++l) {
            total += at(column, l);
        }
        return total;
    }
    // The lowest and highest level the column counted anything at (levels, 0 when none).
    std::pair<std::uint32_t, std::uint32_t> span(std::uint32_t column) const {
        std::uint32_t lo = levels, hi = 0;
        for (std::uint32_t l = 0; l < levels; ++l) {
            if (at(column, l) > 0) {
                lo = std::min(lo, l);
                hi = std::max(hi, l);
            }
        }
        return {lo, hi};
    }
};

} // namespace

@interface LumaWaveformTests : XCTestCase
@end

@implementation LumaWaveformTests {
    std::unique_ptr<LumaWaveform> _waveform;
    id<MTLCommandQueue> _queue;
}

- (void)setUp {
    WaveformSettings settings;
    settings.columns = 128;
    settings.levels = 256;
    settings.maxSampleRows = 90;
    auto created = LumaWaveform::create(device(), settings);
    XCTAssertTrue(created.ok(), @"%s", created.ok() ? "" : created.error().description().c_str());
    if (created.ok()) {
        _waveform = std::move(created).value();
    }
    _queue = [device() newCommandQueue];
}

/// Accumulates `frame` of `working` and waits; the counts.
- (Counts)count:(id<MTLTexture>)working frame:(PixelRect)frame {
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    XCTAssertTrue(_waveform->encodeAccumulate(commands, working, frame));
    [commands commit];
    [commands waitUntilCompleted];
    return Counts{_waveform->countsSnapshot(), _waveform->settings().columns, _waveform->settings().levels};
}

- (void)testARampGivesADiagonal {
    const size_t w = 512, h = 180;
    id<MTLTexture> ramp = makeFrame(w, h, [&](size_t x, size_t) {
        const float v = float(x) / float(w - 1);
        return simd_make_float3(v, v, v);
    });
    const Counts counts = [self count:ramp frame:PixelRect{0, 0, int32_t(w), int32_t(h)}];
    XCTAssertEqual(_waveform->sampleRows(), 90u);
    std::uint32_t previousLow = 0;
    for (std::uint32_t c = 0; c < counts.columns; ++c) {
        // Each column counts its 4 pixel columns times the 90 sampled rows...
        XCTAssertEqual(counts.columnTotal(c), 4u * 90u, @"column %u", c);
        // ... at the levels of their luma, (4c ... 4c + 3) / 511 of 255 (half-float storage rounds by
        // less than a level), so the trace climbs from bottom left to top right.
        const auto [lo, hi] = counts.span(c);
        const double first = 4.0 * c / double(w - 1) * 255.0;
        const double last = (4.0 * c + 3.0) / double(w - 1) * 255.0;
        XCTAssertGreaterThanOrEqual(double(lo), std::floor(first) - 1.0, @"column %u", c);
        XCTAssertLessThanOrEqual(double(hi), std::ceil(last) + 1.0, @"column %u", c);
        XCTAssertGreaterThanOrEqual(lo, previousLow, @"column %u: the diagonal goes up", c);
        previousLow = lo;
    }
    XCTAssertEqual(counts.span(0).first, 0u);
    XCTAssertEqual(counts.span(counts.columns - 1).second, 255u);
}

- (void)testFlatGreyGivesALineAndAColourItsLuma {
    const size_t w = 256, h = 64;
    id<MTLTexture> grey = makeFrame(w, h, [](size_t, size_t) { return simd_make_float3(0.5f, 0.5f, 0.5f); });
    Counts counts = [self count:grey frame:PixelRect{0, 0, int32_t(w), int32_t(h)}];
    const std::uint32_t line = counts.span(0).first;
    XCTAssertTrue(line == 127 || line == 128, @"level %u", line);
    for (std::uint32_t c = 0; c < counts.columns; ++c) {
        XCTAssertEqual(counts.at(c, line), 2u * 64u, @"column %u: every pixel on the one line", c);
        XCTAssertEqual(counts.columnTotal(c), 2u * 64u, @"column %u: nothing elsewhere", c);
    }
    // Pure red: luma 0.2126 (level 54); values outside [0, 1] count as limited.
    id<MTLTexture> red = makeFrame(w, h, [](size_t, size_t) { return simd_make_float3(1.0f, 0.0f, -0.25f); });
    counts = [self count:red frame:PixelRect{0, 0, int32_t(w), int32_t(h)}];
    for (std::uint32_t c = 0; c < counts.columns; ++c) {
        XCTAssertEqual(counts.at(c, 54), 2u * 64u, @"column %u", c);
    }
}

- (void)testOnlyTheFramesRectangleIsCounted {
    // A white 200x100 frame at (20, 10) of a 240x120 working texture, black (letterbox) around it.
    const PixelRect frame{20, 10, 200, 100};
    id<MTLTexture> boxed = makeFrame(240, 120, [&](size_t x, size_t y) {
        const bool inside = int(x) >= frame.x && int(x) < frame.x + frame.width && int(y) >= frame.y &&
                            int(y) < frame.y + frame.height;
        return inside ? simd_make_float3(1, 1, 1) : simd_make_float3(0, 0, 0);
    });
    const Counts counts = [self count:boxed frame:frame];
    std::uint64_t black = 0, white = 0;
    for (std::uint32_t c = 0; c < counts.columns; ++c) {
        black += counts.at(c, 0);
        white += counts.at(c, 255);
    }
    XCTAssertEqual(black, 0u, @"the bars are not counted");
    XCTAssertEqual(white, 200u * 90u, @"every sampled pixel of the frame is white");
    // A rectangle reaching outside the texture is clipped to it; an empty one encodes nothing.
    const Counts clipped = [self count:boxed frame:PixelRect{200, 0, 400, 120}];
    std::uint64_t total = 0;
    for (std::uint32_t c = 0; c < clipped.columns; ++c) {
        total += clipped.columnTotal(c);
    }
    XCTAssertEqual(total, 40u * 90u);
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    XCTAssertFalse(_waveform->encodeAccumulate(commands, boxed, PixelRect{300, 0, 10, 10}));
    XCTAssertFalse(_waveform->encodeAccumulate(commands, boxed, PixelRect{}));
    [commands commit];
}

- (void)testTheDisplayDrawsTheTraceOverTheGraticule {
    const size_t w = 256, h = 64;
    id<MTLTexture> grey = makeFrame(w, h, [](size_t, size_t) { return simd_make_float3(0.5f, 0.5f, 0.5f); });
    // Nothing accumulated yet: nothing to draw.
    id<MTLTexture> target = makeTarget(128, 101);
    id<MTLCommandBuffer> empty = [_queue commandBuffer];
    XCTAssertFalse(_waveform->encodeDisplay(empty, target));
    [empty commit];
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    XCTAssertTrue(_waveform->encodeAccumulate(commands, grey, PixelRect{0, 0, int32_t(w), int32_t(h)}));
    XCTAssertTrue(_waveform->encodeDisplay(commands, target));
    [commands commit];
    [commands waitUntilCompleted];
    // 101 rows: row r shows up = 1 - (r + 0.5) / 101, so the grey (level 127/128 of 256, 50 IRE) is on row
    // 50, which is also the 50 IRE line; the trace is bright green there.
    auto pixel = [&](size_t x, size_t y) { return texturePixel(target, x, y); };
    const RGBA8 trace = pixel(64, 50);
    XCTAssertGreaterThan(trace.g, 200, @"%d %d %d", trace.r, trace.g, trace.b);
    XCTAssertGreaterThan(trace.g, trace.r);
    // Away from the trace: the 20 IRE graticule line is grey, the space between lines black.
    const RGBA8 line = pixel(64, 80); // up = 0.2030...: within 0.75 px of 20 IRE
    XCTAssertGreaterThan(line.g, 20);
    XCTAssertEqual(line.r, line.g);
    const RGBA8 gap = pixel(64, 25);
    XCTAssertEqual(gap.r, 0);
    XCTAssertEqual(gap.g, 0);
    XCTAssertEqual(gap.b, 0);
}

// MARK: - The view, through the engine

- (void)testTheViewDrawsTheProgramMonitorsGradedPicture {
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
    VEWaveformView *waveform = [[VEWaveformView alloc] initWithFrame:NSMakeRect(0, 0, 256, 128)];
    XCTAssertNil(waveform.lastError);
    id<MTLTexture> target = makeTarget(256, 128);
    [waveform setTargetProviderForTesting:^id<MTLTexture> {
        return target;
    }];
    [engine attachProgramView:program];
    [engine attachWaveformView:waveform];
    XCTAssertEqual(engine.waveformView, waveform);

    // The program view renders until its picture is decoded; each render draws the waveform.
    auto renderAndWait = [&] {
        XCTestExpectation *rendered = [self expectationWithDescription:@"rendered"];
        [program renderOnceWithCompletion:^(NSError *) {
            [rendered fulfill];
        }];
        [self waitForExpectations:@[ rendered ] timeout:5];
    };
    auto meanLevel = [&] {
        const std::vector<std::uint32_t> counts = [waveform countsForTesting];
        const WaveformSettings settings = [waveform settingsForTesting];
        double sum = 0, n = 0;
        for (std::uint32_t l = 0; l < settings.levels; ++l) {
            for (std::uint32_t c = 0; c < settings.columns; ++c) {
                sum += double(l) * counts[size_t(l) * settings.columns + c];
                n += counts[size_t(l) * settings.columns + c];
            }
        }
        return n > 0 ? sum / n : -1.0;
    };
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    while (program.missingLayerCount != 0 || program.renderCount == 0) {
        renderAndWait();
        if (deadline.timeIntervalSinceNow < 0) {
            break;
        }
    }
    renderAndWait();
    XCTAssertGreaterThan(waveform.drawCount, 0u);
    const double plain = meanLevel();
    XCTAssertGreaterThan(plain, 10.0, @"the picture is not black");

    // Two stops darker: the trace moves down (the waveform shows the graded picture).
    XCTAssertTrue([engine setGradeValue:-2 forParameter:VEGradeParameterExposure clips:@[ @(clip) ]].ok);
    renderAndWait();
    const double darker = meanLevel();
    NSLog(@"WAVEFORM mean level ungraded %.1f, exposure -2 %.1f (of 255)", plain, darker);
    XCTAssertLessThan(darker, plain * 0.8);

    // Detached: the program view's frames no longer draw it.
    [engine attachWaveformView:nil];
    XCTAssertNil(engine.waveformView);
    const NSUInteger drawn = waveform.drawCount;
    renderAndWait();
    renderAndWait();
    XCTAssertEqual(waveform.drawCount, drawn);
    [engine attachProgramView:nil];
}

// MARK: - Cost

- (void)testTheWaveformsCost {
    WaveformSettings settings; // the view's: 512 columns, 256 levels, 360 rows
    auto created = LumaWaveform::create(device(), settings);
    XCTAssertTrue(created.ok());
    if (!created.ok()) {
        return;
    }
    LumaWaveform &waveform = *created.value();
    id<MTLTexture> target = makeTarget(560, 280); // a panel on a Retina display
    struct Scene {
        const char *name;
        size_t width, height;
        bool flat; // every pixel the same grey: all of a column's samples on one counter (the worst contention)
    };
    const Scene scenes[] = {{"1080p picture", 1920, 1080, false}, {"1080p flat grey", 1920, 1080, true},
                            {"2160p picture", 3840, 2160, false}, {"2160p flat grey", 3840, 2160, true}};
    for (const Scene &scene : scenes) {
        const size_t w = scene.width, h = scene.height;
        id<MTLTexture> frame = makeFrame(w, h, [&](size_t x, size_t y) {
            const float v = scene.flat ? 0.5f : float((x * 7 + y * 3) % 256) / 255.0f;
            return scene.flat ? simd_make_float3(v, v, v) : simd_make_float3(v, 1.0f - v, 0.5f * v);
        });
        std::vector<double> gpu, cpu;
        for (int i = 0; i < 90; ++i) {
            id<MTLCommandBuffer> commands = [_queue commandBuffer];
            const auto start = std::chrono::steady_clock::now();
            waveform.encodeAccumulate(commands, frame, PixelRect{0, 0, int32_t(w), int32_t(h)});
            waveform.encodeDisplay(commands, target);
            const double encode = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
            [commands commit];
            [commands waitUntilCompleted];
            if (i >= 30) { // warm-up: the GPU's clocks come up
                gpu.push_back((commands.GPUEndTime - commands.GPUStartTime) * 1000.0);
                cpu.push_back(encode);
            }
        }
        std::sort(gpu.begin(), gpu.end());
        std::sort(cpu.begin(), cpu.end());
        NSLog(@"WAVEFORM COST %s: GPU %.3f ms (median of 60), encoding on the render thread %.3f ms", scene.name,
              gpu[gpu.size() / 2], cpu[cpu.size() / 2]);
        // A small share of a 60 fps frame's 16.7 ms.
        XCTAssertLessThan(gpu[gpu.size() / 2], 2.0);
        XCTAssertLessThan(cpu[cpu.size() / 2], 1.0);
    }
}

@end
