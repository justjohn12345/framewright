// The grade on the GPU (ColorGrade.h through Shaders.metal):
// - the shader's grade function against the CPU reference on a grid of inputs (specials included), value
//   by value, within a stated bound;
// - rendered through the compositor (composited straight into an RGBA32Float target, so nothing rounds the
//   values or hides a NaN): a graded black frame stays exactly black; a graded sub-black (and super-white,
//   out-of-gamut) ramp has no NaN and stays in [0, 1]; exposure +1 doubles linear values; saturation 0 gives
//   grey; 8-bit and 10-bit sources of one picture grade alike; a straight-alpha picture is graded
//   unpremultiplied; each side of a dissolve gets its own grade;
// - the grade's cost on the GPU, logged (GRADE COST) and bounded loosely.
// That ungraded layers are drawn exactly as before is shown by the compositor, transition, working-buffer
// and parity suites passing unchanged.

#import <XCTest/XCTest.h>

#include "../../Engine/Render/ColorGrade.h"
#include "../../Engine/Render/Compositor.h"
#include "CompositorTestSupport.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <limits>
#include <string>
#include <vector>

using namespace ve;
using namespace ve::render;
using namespace ve::rtest;

namespace {

id<MTLTexture> makeFloatTarget(size_t width, size_t height) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    return [device() newTextureWithDescriptor:desc];
}

std::vector<float> valuesOf(id<MTLTexture> texture) {
    const size_t w = texture.width, h = texture.height;
    std::vector<float> values(w * h * 4);
    [texture getBytes:values.data() bytesPerRow:w * 16 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    return values;
}

GradeValues gradeOf(std::initializer_list<std::pair<GradeParameter, double>> values) {
    GradeValues grade = ClipGrade::neutralValues();
    for (const auto &[parameter, value] : values) {
        grade[static_cast<std::size_t>(parameter)] = value;
    }
    return grade;
}

// The graded looks the render tests use: each control far from neutral, and all together.
std::vector<GradeValues> strongGrades() {
    using P = GradeParameter;
    return {
        gradeOf({{P::Exposure, 5.0}}),
        gradeOf({{P::Exposure, -5.0}}),
        gradeOf({{P::Contrast, 2.0}}),
        gradeOf({{P::Contrast, 0.0}}),
        gradeOf({{P::Contrast, 0.5}}),
        gradeOf({{P::Temperature, 100.0}, {P::Tint, -100.0}}),
        gradeOf({{P::Saturation, 2.0}}),
        gradeOf({{P::Saturation, 0.0}}),
        gradeOf({{P::Exposure, 3.0}, {P::Contrast, 2.0}, {P::Temperature, -80.0}, {P::Tint, 60.0}, {P::Saturation, 2.0}}),
    };
}

// The BT.1886 curve (2.4 power), mirrored.
double linearOf(double v) {
    return std::copysign(std::pow(std::fabs(v), 2.4), v);
}

} // namespace

@interface ColorGradeRenderTests : XCTestCase
@end

@implementation ColorGradeRenderTests {
    std::unique_ptr<Compositor> _compositor;
}

- (void)setUp {
    auto compositor = Compositor::create(device());
    XCTAssertTrue(compositor.ok(), @"%s", compositor.ok() ? "" : compositor.error().description().c_str());
    if (compositor.ok()) {
        _compositor = std::move(compositor).value();
    }
}

/// Renders `graph` with `textures` straight into a `width` x `height` RGBA32Float target and returns its
/// values (R, G, B, A per pixel).
- (std::vector<float>)render:(const RenderGraph &)graph
                    textures:(const std::vector<TextureSet> &)textures
                       width:(size_t)width
                      height:(size_t)height {
    id<MTLTexture> target = makeFloatTarget(width, height);
    TextureTarget textureTarget{target, {}, nil};
    textureTarget.compositeDirectlyForTesting = true;
    auto result = renderLayers(*_compositor, graph, textures, textureTarget);
    XCTAssertTrue(result.ok() && result->status.ok() && result->skippedLayers.empty());
    if (!result.ok()) {
        return {};
    }
    return valuesOf(target);
}

// MARK: - The shader's grade against the CPU reference

- (void)testTheShaderGradeMatchesTheCPUReference {
    id<MTLDevice> gpu = device();
    NSError *error = nil;
    NSBundle *engine = [NSBundle bundleWithIdentifier:@"com.justjohn12345.framewright.engine"];
    XCTAssertNotNil(engine);
    id<MTLLibrary> library = [gpu newDefaultLibraryWithBundle:engine error:&error];
    XCTAssertNotNil(library, @"%@", error);
    id<MTLFunction> function = [library newFunctionWithName:@"ve_grade_samples"];
    XCTAssertNotNil(function);
    id<MTLComputePipelineState> pipeline = [gpu newComputePipelineStateWithFunction:function error:&error];
    XCTAssertNotNil(pipeline, @"%@", error);
    if (pipeline == nil) {
        return;
    }
    const float eps = kVEGradeEpsilon;
    const float inf = std::numeric_limits<float>::infinity();
    const float values[] = {-1.0f,   -0.5f,   -0.1f, -1e-3f, -eps,  -eps / 2, -0.0f, 0.0f,  1e-40f,
                            eps / 2, eps,     1e-3f, 0.01f,  0.05f, 0.1f,     0.18f, 0.25f, 0.5f,
                            0.75f,   0.9f,    1.0f,  1.05f,  1.5f,  2.0f,     10.0f, 256.0f, 1e30f,
                            std::numeric_limits<float>::max(), std::numeric_limits<float>::quiet_NaN(), inf, -inf};
    std::vector<simd_float4> inputs;
    for (const float r : values) {
        for (const float g : values) {
            for (const float b : values) {
                inputs.push_back(simd_make_float4(r, g, b, 0.0f));
            }
        }
    }
    const uint32_t count = uint32_t(inputs.size());
    id<MTLBuffer> in = [gpu newBufferWithBytes:inputs.data()
                                        length:inputs.size() * sizeof(simd_float4)
                                       options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [gpu newBufferWithLength:inputs.size() * sizeof(simd_float4) options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [gpu newCommandQueue];
    std::vector<GradeValues> grades = strongGrades();
    grades.push_back(gradeOf({{GradeParameter::Contrast, 1.3}, {GradeParameter::Exposure, 0.5}}));
    double worst = 0.0;  // the largest |gpu - cpu| / max(1, |cpu|)
    size_t compared = 0;
    for (const VEInt transfer : {VEGradeTransferBT1886, VEGradeTransferSRGB, VEGradeTransferLinear}) {
        for (const GradeValues &grade : grades) {
            const VEGradeUniforms uniforms = gradeUniformsFor(grade, transfer);
            id<MTLCommandBuffer> commands = [queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
            [encoder setComputePipelineState:pipeline];
            [encoder setBuffer:in offset:0 atIndex:0];
            [encoder setBuffer:out offset:0 atIndex:1];
            [encoder setBytes:&uniforms length:sizeof uniforms atIndex:2];
            [encoder setBytes:&count length:sizeof count atIndex:3];
            [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(pipeline.maxTotalThreadsPerThreadgroup, 256), 1, 1)];
            [encoder endEncoding];
            [commands commit];
            [commands waitUntilCompleted];
            const auto *gpuValues = static_cast<const simd_float4 *>(out.contents);
            for (uint32_t i = 0; i < count; ++i) {
                const simd_float3 cpu = gradeReference(inputs[i].xyz, uniforms);
                for (int c = 0; c < 3; ++c) {
                    const float g = gpuValues[i][c];
                    if (!std::isfinite(g)) {
                        XCTFail(@"GPU grade not finite: input (%g, %g, %g) channel %d transfer %d gave %g", inputs[i].x,
                                inputs[i].y, inputs[i].z, c, transfer, g);
                        return;
                    }
                    const double difference = std::fabs(double(g) - double(cpu[c])) / std::max(1.0, std::fabs(double(cpu[c])));
                    worst = std::max(worst, difference);
                    ++compared;
                }
            }
        }
    }
    NSLog(@"GRADE GPU vs CPU: %zu values, largest difference %.3g (relative above 1, absolute below)", compared, worst);
    // The bound: 2e-5 of the value (absolute below 1). Both sides run the same float code; they differ only
    // by the GPU's precise pow/exp2/log2 against libm (a few ulps) and the GPU's flushing of denormals.
    XCTAssertLessThanOrEqual(worst, 2e-5);
}

// MARK: - Rendered

- (void)testAGradedBlackFrameStaysExactlyBlack {
    struct Source {
        const char *name;
        media::PixelBuffer buffer;
        bool still;
    };
    std::vector<Source> sources;
    {
        media::PixelBuffer b = makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 64, 32);
        fillYCbCr(b, 16, 128, 128, media::YCbCrMatrix::BT709);
        sources.push_back({"420v black", b, false});
    }
    {
        media::PixelBuffer b = makeBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 64, 32);
        fillYCbCr(b, 64, 512, 512, media::YCbCrMatrix::BT709);
        sources.push_back({"x420 black", b, false});
    }
    {
        media::PixelBuffer b = makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 64, 32);
        fillYCbCr(b, 0, 128, 128, media::YCbCrMatrix::BT601);
        sources.push_back({"420f black", b, false});
    }
    {
        media::PixelBuffer b = makeBuffer(kCVPixelFormatType_32BGRA, 64, 32);
        fillBGRA(b, {0, 0, 0, 255});
        sources.push_back({"BGRA black still", b, true});
    }
    for (const Source &source : sources) {
        const TextureSet set = texturesFor(*_compositor, source.buffer);
        for (const GradeValues &grade : strongGrades()) {
            RenderGraph g = makeGraph(64, 32);
            VideoLayer layer = makeLayer(1);
            layer.isStill = source.still;
            layer.grade = grade;
            g.layers.push_back(layer);
            const std::vector<float> v = [self render:g textures:{set} width:64 height:32];
            XCTAssertFalse(v.empty());
            size_t notBlack = 0;
            for (size_t i = 0; i < v.size(); i += 4) {
                notBlack += (v[i] != 0.0f || v[i + 1] != 0.0f || v[i + 2] != 0.0f) ? 1 : 0;
            }
            XCTAssertEqual(notBlack, 0u, @"%s: graded black is not exactly black (%.9g %.9g %.9g)", source.name, v[0],
                           v[1], v[2]);
        }
    }
}

- (void)testAGradedSubBlackRampHasNoNaNPixels {
    // 10-bit video range: luma from code 0 (far below black, 64) through black, and super-whites to 1019,
    // with chroma at both extremes (out of gamut: negative and above-white channels after the matrix).
    const size_t w = 256, h = 16;
    media::PixelBuffer ramp = makeBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, w, h);
    const double cw = double(CVPixelBufferGetWidthOfPlane(ramp.get(), 1));
    fillYCbCrPattern(
        ramp,
        [&](size_t x, size_t y) {
            return y < h / 2 ? 64.0 * double(x) / double(w - 1) // 0 ... 64: sub-black
                             : 941.0 + 78.0 * double(x) / double(w - 1); // 941 ... 1019: super-white
        },
        [&](size_t i, size_t j) {
            const double t = double(i) / (cw - 1);
            return std::pair<double, double>{j % 2 == 0 ? 1023.0 * t : 512.0, j % 2 == 0 ? 1023.0 * (1.0 - t) : 512.0};
        });
    tagYCbCr(ramp, media::YCbCrMatrix::BT709, ChromaSiting::Left);
    const TextureSet set = texturesFor(*_compositor, ramp);
    for (const GradeValues &grade : strongGrades()) {
        RenderGraph g = makeGraph(int32_t(w), int32_t(h));
        VideoLayer layer = makeLayer(1);
        layer.grade = grade;
        g.layers.push_back(layer);
        const std::vector<float> v = [self render:g textures:{set} width:w height:h];
        XCTAssertFalse(v.empty());
        size_t bad = 0;
        for (size_t i = 0; i < v.size(); ++i) {
            bad += (!std::isfinite(v[i]) || v[i] < 0.0f || v[i] > 1.0f) ? 1 : 0;
        }
        XCTAssertEqual(bad, 0u, @"NaN, infinite or out-of-range samples in a graded sub-black ramp");
    }
    // Sub-black luma with neutral chroma stays black whatever the grade (negatives stay negative, then 0).
    media::PixelBuffer subBlack = makeBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, w, h);
    fillYCbCrPattern(
        subBlack, [&](size_t x, size_t) { return 63.0 * double(x) / double(w - 1); },
        [](size_t, size_t) { return std::pair<double, double>{512.0, 512.0}; });
    tagYCbCr(subBlack, media::YCbCrMatrix::BT709, ChromaSiting::Left);
    const TextureSet subSet = texturesFor(*_compositor, subBlack);
    for (const GradeValues &grade : strongGrades()) {
        RenderGraph g = makeGraph(int32_t(w), int32_t(h));
        VideoLayer layer = makeLayer(1);
        layer.grade = grade;
        g.layers.push_back(layer);
        const std::vector<float> v = [self render:g textures:{subSet} width:w height:h];
        float largest = 0.0f;
        for (size_t i = 0; i < v.size(); i += 4) {
            largest = std::max({largest, v[i], v[i + 1], v[i + 2]});
        }
        XCTAssertEqual(largest, 0.0f, @"sub-black graded above black");
    }
}

/// A 10-bit grey ramp (video range, BT.709) over `w` columns from luma code `from` to `to`.
- (media::PixelBuffer)greyRampFrom:(double)from to:(double)to width:(size_t)w height:(size_t)h {
    media::PixelBuffer ramp = makeBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, w, h);
    fillYCbCrPattern(
        ramp, [&](size_t x, size_t) { return from + (to - from) * double(x) / double(w - 1); },
        [](size_t, size_t) { return std::pair<double, double>{512.0, 512.0}; });
    tagYCbCr(ramp, media::YCbCrMatrix::BT709, ChromaSiting::Left);
    return ramp;
}

- (void)testExposurePlusOneDoublesLinearValues {
    const size_t w = 256, h = 8;
    // Luma codes 64 ... 620: R'G'B' 0 ... 0.63, linear up to 0.33, so doubled stays below white.
    media::PixelBuffer ramp = [self greyRampFrom:64 to:620 width:w height:h];
    const TextureSet set = texturesFor(*_compositor, ramp);
    RenderGraph plain = makeGraph(int32_t(w), int32_t(h));
    plain.layers.push_back(makeLayer(1));
    RenderGraph graded = plain;
    graded.layers[0].grade = gradeOf({{GradeParameter::Exposure, 1.0}});
    const std::vector<float> before = [self render:plain textures:{set} width:w height:h];
    const std::vector<float> after = [self render:graded textures:{set} width:w height:h];
    XCTAssertEqual(before.size(), after.size());
    double worst = 0.0;
    for (size_t i = 0; i + 3 < before.size(); i += 4) {
        for (int c = 0; c < 3; ++c) {
            const double expected = 2.0 * linearOf(before[i + c]);
            const double got = linearOf(after[i + c]);
            worst = std::max(worst, std::fabs(got - expected));
        }
    }
    NSLog(@"GRADE exposure +1: largest |linear(after) - 2 linear(before)| %.3g", worst);
    XCTAssertLessThan(worst, 1e-5);
    // And the picture did get brighter: at the ramp's top 0.63 -> 0.63 * 2^(1/2.4) = 0.84.
    XCTAssertEqualWithAccuracy(after[(w - 1) * 4], before[(w - 1) * 4] * std::pow(2.0, 1.0 / 2.4), 1e-4);
}

- (void)testSaturationZeroGivesGrey {
    const size_t w = 64, h = 32;
    media::PixelBuffer colourful = makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, w, h);
    const double cw = double(CVPixelBufferGetWidthOfPlane(colourful.get(), 1));
    const double ch = double(CVPixelBufferGetHeightOfPlane(colourful.get(), 1));
    fillYCbCrPattern(
        colourful, [&](size_t x, size_t y) { return 60.0 + 120.0 * double(x) / double(w) + 30.0 * double(y) / double(h); },
        [&](size_t i, size_t j) {
            return std::pair<double, double>{70.0 + 110.0 * double(i) / cw, 180.0 - 100.0 * double(j) / ch};
        });
    tagYCbCr(colourful, media::YCbCrMatrix::BT709, ChromaSiting::Left);
    const TextureSet set = texturesFor(*_compositor, colourful);
    RenderGraph g = makeGraph(int32_t(w), int32_t(h));
    VideoLayer layer = makeLayer(1);
    layer.grade = gradeOf({{GradeParameter::Saturation, 0.0}});
    g.layers.push_back(layer);
    const std::vector<float> v = [self render:g textures:{set} width:w height:h];
    size_t coloured = 0;
    for (size_t i = 0; i + 3 < v.size(); i += 4) {
        coloured += (v[i] != v[i + 1] || v[i + 1] != v[i + 2]) ? 1 : 0;
    }
    XCTAssertEqual(coloured, 0u, @"saturation 0 left colour");
    // The ungraded picture is colourful (the test would pass on a grey source otherwise).
    RenderGraph plain = makeGraph(int32_t(w), int32_t(h));
    plain.layers.push_back(makeLayer(1));
    const std::vector<float> p = [self render:plain textures:{set} width:w height:h];
    XCTAssertGreaterThan(std::fabs(p[(16 * w + 40) * 4] - p[(16 * w + 40) * 4 + 2]), 0.05f);
}

- (void)testEightAndTenBitSourcesOfOnePictureGradeAlike {
    const size_t w = 128, h = 64;
    media::PixelBuffer eight = makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, w, h);
    media::PixelBuffer ten = makeBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, w, h);
    const double cw = double(CVPixelBufferGetWidthOfPlane(eight.get(), 1));
    const double ch = double(CVPixelBufferGetHeightOfPlane(eight.get(), 1));
    // The same codes (8-bit c is 10-bit 4c: the same value in video range).
    auto luma = [&](size_t x, size_t y) { return std::round(30.0 + 180.0 * double(x) / double(w) + 20.0 * double(y) / double(h)); };
    auto chroma = [&](size_t i, size_t j) {
        return std::pair<double, double>{std::round(90.0 + 70.0 * double(i) / cw), std::round(150.0 - 60.0 * double(j) / ch)};
    };
    fillYCbCrPattern(eight, luma, chroma);
    fillYCbCrPattern(
        ten, [&](size_t x, size_t y) { return 4.0 * luma(x, y); },
        [&](size_t i, size_t j) {
            const auto c = chroma(i, j);
            return std::pair<double, double>{4.0 * c.first, 4.0 * c.second};
        });
    tagYCbCr(eight, media::YCbCrMatrix::BT709, ChromaSiting::Left);
    tagYCbCr(ten, media::YCbCrMatrix::BT709, ChromaSiting::Left);
    const TextureSet e = texturesFor(*_compositor, eight);
    const TextureSet t = texturesFor(*_compositor, ten);
    double worst = 0.0;
    for (const GradeValues &grade : strongGrades()) {
        RenderGraph g = makeGraph(int32_t(w), int32_t(h));
        VideoLayer layer = makeLayer(1);
        layer.grade = grade;
        g.layers.push_back(layer);
        const std::vector<float> a = [self render:g textures:{e} width:w height:h];
        const std::vector<float> b = [self render:g textures:{t} width:w height:h];
        XCTAssertEqual(a.size(), b.size());
        for (size_t i = 0; i < a.size() && i < b.size(); ++i) {
            worst = std::max(worst, double(std::fabs(a[i] - b[i])));
        }
    }
    NSLog(@"GRADE 8-bit vs 10-bit: largest difference %.3g", worst);
    // The bound: a thousandth (a tenth of a 10-bit code would be 1e-4; the two formats' samples differ by the
    // float rounding of their unorm scales, which contrast 2 and exposure +5 magnify).
    XCTAssertLessThan(worst, 1e-3);
}

- (void)testAStraightAlphaPictureIsGradedUnpremultiplied {
    // Straight orange at alpha 128 over black, graded to grey: the premultiplied result is the grey of the
    // colour times its alpha, and the colour of the transparent half is never seen.
    const size_t w = 32, h = 16;
    media::PixelBuffer picture = makeBuffer(kCVPixelFormatType_32BGRA, w, h);
    fillBGRA(picture, {255, 0, 255, 0});                 // transparent magenta (must not show)
    fillBGRARect(picture, 0, 0, w, h / 2, {230, 140, 40, 128}); // straight orange, half alpha
    tagAlpha(picture, AlphaMode::Straight);
    const TextureSet set = texturesFor(*_compositor, picture);
    RenderGraph g = makeGraph(int32_t(w), int32_t(h));
    VideoLayer layer = makeLayer(1);
    layer.grade = gradeOf({{GradeParameter::Saturation, 0.0}});
    g.layers.push_back(layer);
    const std::vector<float> v = [self render:g textures:{set} width:w height:h];
    const size_t inside = (2 * w + 8) * 4;
    const size_t transparent = (12 * w + 8) * 4;
    const double alpha = 128.0 / 255.0;
    // A video BGRA picture (not a still), untagged: linearised by BT.1886.
    const double l = 0.2126 * linearOf(230.0 / 255.0) + 0.7152 * linearOf(140.0 / 255.0) + 0.0722 * linearOf(40.0 / 255.0);
    const double grey = std::pow(l, 1.0 / 2.4);
    XCTAssertEqualWithAccuracy(v[inside], grey * alpha, 2e-3);
    XCTAssertEqualWithAccuracy(v[inside + 1], grey * alpha, 2e-3);
    XCTAssertEqualWithAccuracy(v[inside + 2], grey * alpha, 2e-3);
    XCTAssertEqual(v[transparent], 0.0f);
    XCTAssertEqual(v[transparent + 1], 0.0f);
    XCTAssertEqual(v[transparent + 2], 0.0f);
}

- (void)testEachSideOfADissolveGetsItsOwnGrade {
    const size_t w = 64, h = 16;
    media::PixelBuffer a = [self greyRampFrom:200 to:700 width:w height:h];
    media::PixelBuffer b = [self greyRampFrom:700 to:200 width:w height:h];
    const TextureSet ta = texturesFor(*_compositor, a);
    const TextureSet tb = texturesFor(*_compositor, b);
    const GradeValues gradeA = gradeOf({{GradeParameter::Exposure, 1.0}});
    const GradeValues gradeB = gradeOf({{GradeParameter::Contrast, 2.0}, {GradeParameter::Exposure, -1.0}});
    auto single = [&](const TextureSet &set, const GradeValues &grade) {
        RenderGraph g = makeGraph(int32_t(w), int32_t(h));
        VideoLayer layer = makeLayer(1);
        layer.grade = grade;
        g.layers.push_back(layer);
        return [self render:g textures:{set} width:w height:h];
    };
    const std::vector<float> aGraded = single(ta, gradeA);
    const std::vector<float> bGraded = single(tb, gradeB);
    for (const double mix : {0.0, 0.3, 1.0}) {
        RenderGraph g = makeGraph(int32_t(w), int32_t(h));
        VideoLayer out = makeLayer(1);
        VideoLayer in = makeLayer(2);
        out.grade = gradeA;
        in.grade = gradeB;
        LayerTransition t;
        t.mix = mix;
        t.isIncoming = false;
        t.partnerClipId = in.clipId;
        t.partnerLayerIndex = 1;
        out.transition = t;
        t.isIncoming = true;
        t.partnerClipId = out.clipId;
        t.partnerLayerIndex = 0;
        in.transition = t;
        g.layers = {out, in};
        const std::vector<float> v = [self render:g textures:{ta, tb} width:w height:h];
        double worst = 0.0;
        for (size_t i = 0; i < v.size(); ++i) {
            if (i % 4 == 3) {
                continue;
            }
            const double expected = (1.0 - mix) * aGraded[i] + mix * bGraded[i];
            worst = std::max(worst, std::fabs(double(v[i]) - expected));
        }
        XCTAssertLessThan(worst, 1e-5, @"mix %.1f: the pair is not mix(graded A, graded B)", mix);
    }
}

// MARK: - Cost

- (void)testTheGradeCostOnTheGPU {
    // A 1080p 10-bit source drawn at 1:1, ungraded and graded (every control), and a graded dissolve pair,
    // interleaved; the median GPU time of 60 frames each.
    const size_t w = 1920, h = 1080;
    media::PixelBuffer source = [self greyRampFrom:64 to:940 width:w height:h];
    const TextureSet set = texturesFor(*_compositor, source);
    id<MTLTexture> target = makeFloatTarget(w, h);
    const GradeValues every = gradeOf({{GradeParameter::Exposure, 0.5}, {GradeParameter::Contrast, 1.2},
                                       {GradeParameter::Temperature, 20.0}, {GradeParameter::Tint, -10.0},
                                       {GradeParameter::Saturation, 1.1}});
    auto timeOf = [&](const RenderGraph &graph, const std::vector<TextureSet> &textures) {
        TextureTarget t{target, {}, nil};
        auto result = renderLayers(*_compositor, graph, textures, t);
        return result.ok() ? result->gpuSeconds * 1000.0 : -1.0;
    };
    RenderGraph plain = makeGraph(int32_t(w), int32_t(h));
    plain.layers.push_back(makeLayer(1));
    RenderGraph graded = plain;
    graded.layers[0].grade = every;
    RenderGraph pair = makeGraph(int32_t(w), int32_t(h));
    {
        VideoLayer out = makeLayer(1);
        VideoLayer in = makeLayer(2);
        LayerTransition t;
        t.mix = 0.5;
        t.partnerClipId = in.clipId;
        t.partnerLayerIndex = 1;
        out.transition = t;
        t.isIncoming = true;
        t.partnerClipId = out.clipId;
        t.partnerLayerIndex = 0;
        in.transition = t;
        pair.layers = {out, in};
    }
    RenderGraph gradedPair = pair;
    gradedPair.layers[0].grade = every;
    gradedPair.layers[1].grade = every;
    std::vector<double> times[4];
    for (int i = 0; i < 70; ++i) {
        const double a = timeOf(plain, {set});
        const double b = timeOf(graded, {set});
        const double c = timeOf(pair, {set, set});
        const double d = timeOf(gradedPair, {set, set});
        if (i >= 10) { // warm-up
            times[0].push_back(a);
            times[1].push_back(b);
            times[2].push_back(c);
            times[3].push_back(d);
        }
    }
    double median[4];
    for (int k = 0; k < 4; ++k) {
        std::sort(times[k].begin(), times[k].end());
        median[k] = times[k][times[k].size() / 2];
        XCTAssertGreaterThan(median[k], 0.0);
    }
    NSLog(@"GRADE COST 1080p (median GPU ms, working texture and output pass included): one layer %.3f ungraded, %.3f "
          @"graded (+%.3f); dissolve pair %.3f ungraded, %.3f both graded (+%.3f)",
          median[0], median[1], median[1] - median[0], median[2], median[3], median[3] - median[2]);
    // Loose: the grade is a few dozen ALU operations per pixel; a millisecond more per 1080p layer would mean
    // something is wrong (it is a sixteenth of a 60 fps frame).
    XCTAssertLessThan(median[1] - median[0], 1.0);
    XCTAssertLessThan(median[3] - median[2], 2.0);

    // A compositor made for a monitor format prepares every layer pipeline (20 with the graded ones, 6
    // before grading): what that costs once the process has compiled them (the case of every compositor
    // after the first: monitors, exports).
    std::vector<double> creations;
    for (int i = 0; i < 5; ++i) {
        const auto start = std::chrono::steady_clock::now();
        auto created = Compositor::create(device(), {MTLPixelFormatBGR10A2Unorm});
        creations.push_back(std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count());
        XCTAssertTrue(created.ok());
    }
    std::sort(creations.begin(), creations.end());
    NSLog(@"GRADE COST compositor creation with every layer pipeline prepared: median %.2f ms (first %.2f)",
          creations[creations.size() / 2], creations.front());
}

@end
