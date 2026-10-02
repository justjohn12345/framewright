// The slice 2 grade on the GPU (ColorGrade.h's veGradeExtended through Shaders.metal, selected by the
// sources' extended-grade function constants):
// - the shader's extended grade against the CPU reference on a grid of inputs (specials included), value by
//   value, for strong wheel settings under every transfer;
// - rendered through the compositor (straight into an RGBA32Float target): a graded picture equals the CPU
//   reference applied to the ungraded picture; gain and gamma keep a black frame exactly black; each side of
//   a dissolve gets its own grade when one side is extended and the other is not;
// - the cost on the GPU of a 1080p and a 2160p layer with each slice 2 stage, logged (GRADE EXTENDED COST).

#import <XCTest/XCTest.h>

#include "../../Engine/Render/ColorGrade.h"
#include "../../Engine/Render/Compositor.h"
#include "CompositorTestSupport.h"

#include <algorithm>
#include <cmath>
#include <functional>
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

GradeWheels wheelsOf(WheelValue lift, WheelValue gamma, WheelValue gain) {
    return {lift, gamma, gain};
}

std::vector<GradeWheels> strongWheels() {
    const WheelValue none{};
    return {
        wheelsOf({1.0, 0, 0}, none, none),           wheelsOf({-1.0, 0, 0}, none, none),
        wheelsOf(none, {1.0, 0, 0}, none),           wheelsOf(none, {-1.0, 0, 0}, none),
        wheelsOf(none, none, {1.0, 0, 0}),           wheelsOf(none, none, {-1.0, 0, 0}),
        wheelsOf({0, 1.0, 0}, {0, 0, 1.0}, {0, -0.7071, 0.7071}),
        wheelsOf({1.0, -1.0, 0}, {-1.0, 0, -1.0}, {1.0, 0.6, -0.8}),
        wheelsOf({-0.4, 0.2, 0.3}, {0.3, -0.5, 0.1}, {0.2, 0.1, -0.2}),
    };
}

// A 10-bit picture in video range with a luma ramp across and chroma that varies, every R'G'B' within [0, 1]
// (luma 190-800, chroma +-60 codes), so the ungraded picture is not clamped and equals the grade's input.
media::PixelBuffer colourRamp(size_t w, size_t h) {
    media::PixelBuffer buffer = makeBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, w, h);
    const double cw = double(CVPixelBufferGetWidthOfPlane(buffer.get(), 1));
    const double ch = double(CVPixelBufferGetHeightOfPlane(buffer.get(), 1));
    fillYCbCrPattern(
        buffer, [&](size_t x, size_t y) { return 200.0 + 600.0 * double(x) / double(w - 1) - 10.0 * double(y) / double(h); },
        [&](size_t i, size_t j) {
            return std::pair<double, double>{512.0 + 60.0 * std::sin(double(i) / cw * 6.0),
                                             512.0 + 60.0 * std::cos(double(j) / ch * 4.0)};
        });
    tagYCbCr(buffer, media::YCbCrMatrix::BT709, ChromaSiting::Left);
    return buffer;
}

// A 3D LUT of `size` per side from `f` (red fastest).
CubeLut cubeOf(std::uint32_t size, const std::function<simd_float3(simd_float3)> &f) {
    CubeLut lut;
    lut.kind = CubeKind::ThreeD;
    lut.size = size;
    for (std::uint32_t b = 0; b < size; ++b) {
        for (std::uint32_t g = 0; g < size; ++g) {
            for (std::uint32_t r = 0; r < size; ++r) {
                const float last = float(size - 1);
                const simd_float3 v = f(simd_make_float3(float(r) / last, float(g) / last, float(b) / last));
                lut.table.insert(lut.table.end(), {v.x, v.y, v.z});
            }
        }
    }
    return lut;
}

// A 1D LUT of `size` entries from `f`, the same for each channel but a tilt per channel.
CubeLut curveOf(std::uint32_t size, const std::function<float(float)> &f) {
    CubeLut lut;
    lut.kind = CubeKind::OneD;
    lut.size = size;
    for (std::uint32_t i = 0; i < size; ++i) {
        const float v = f(float(i) / float(size - 1));
        lut.table.insert(lut.table.end(), {v, 0.95f * v + 0.02f, std::min(1.0f, 1.05f * v)});
    }
    return lut;
}

// A LUT's texture as the compositor makes it: RGBA32Float, its side the LUT's size (a 1x1x1 stand-in for none).
id<MTLTexture> cubeTexture(const CubeLut *lut) {
    const NSUInteger side = lut != nullptr && lut->kind == CubeKind::ThreeD ? lut->size : 1;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor new];
    desc.textureType = MTLTextureType3D;
    desc.pixelFormat = MTLPixelFormatRGBA32Float;
    desc.width = desc.height = desc.depth = side;
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device() newTextureWithDescriptor:desc];
    std::vector<float> rgba(side * side * side * 4, 0.0f);
    if (side > 1) {
        for (size_t i = 0; i < side * side * side; ++i) {
            rgba[i * 4] = lut->table[i * 3];
            rgba[i * 4 + 1] = lut->table[i * 3 + 1];
            rgba[i * 4 + 2] = lut->table[i * 3 + 2];
        }
    }
    [texture replaceRegion:MTLRegionMake3D(0, 0, 0, side, side, side)
               mipmapLevel:0
                     slice:0
                 withBytes:rgba.data()
               bytesPerRow:side * 16
             bytesPerImage:side * side * 16];
    return texture;
}

} // namespace

@interface ColorGradeExtendedRenderTests : XCTestCase
@end

@implementation ColorGradeExtendedRenderTests {
    std::unique_ptr<Compositor> _compositor;
}

- (void)setUp {
    auto compositor = Compositor::create(device());
    XCTAssertTrue(compositor.ok(), @"%s", compositor.ok() ? "" : compositor.error().description().c_str());
    if (compositor.ok()) {
        _compositor = std::move(compositor).value();
    }
}

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

// MARK: - The shader against the CPU reference

/// Runs `ve_grade_samples` over `inputs` with each of `uniforms` and returns the largest difference to the
/// CPU reference (relative above 1, absolute below); fails on a value that is not finite.
- (double)largestDifferenceOver:(const std::vector<simd_float4> &)inputs uniforms:(const std::vector<VEGradeUniforms> &)uniforms {
    return [self largestDifferenceOver:inputs uniforms:uniforms tables:{}];
}

/// The same with the grade's tables (`ve_grade_samples_tables`, the tables bound as a texture and given to the
/// CPU reference) when `tables` is not empty.
- (double)largestDifferenceOver:(const std::vector<simd_float4> &)inputs
                       uniforms:(const std::vector<VEGradeUniforms> &)uniforms
                         tables:(const std::vector<float> &)tables {
    id<MTLDevice> gpu = device();
    NSError *error = nil;
    NSBundle *engine = [NSBundle bundleWithIdentifier:@"com.justjohn12345.framewright.engine"];
    id<MTLLibrary> library = [gpu newDefaultLibraryWithBundle:engine error:&error];
    NSString *name = tables.empty() ? @"ve_grade_samples" : @"ve_grade_samples_tables";
    id<MTLComputePipelineState> pipeline = [gpu newComputePipelineStateWithFunction:[library newFunctionWithName:name]
                                                                               error:&error];
    id<MTLTexture> tableTexture = nil;
    if (!tables.empty()) {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                        width:kVEGradeTableWidth
                                                                                       height:VEGradeTableRowCount
                                                                                    mipmapped:NO];
        desc.storageMode = MTLStorageModeShared;
        tableTexture = [gpu newTextureWithDescriptor:desc];
        [tableTexture replaceRegion:MTLRegionMake2D(0, 0, kVEGradeTableWidth, VEGradeTableRowCount)
                        mipmapLevel:0
                          withBytes:tables.data()
                        bytesPerRow:kVEGradeTableWidth * sizeof(float)];
    }
    XCTAssertNotNil(pipeline, @"%@", error);
    if (pipeline == nil) {
        return INFINITY;
    }
    const uint32_t count = uint32_t(inputs.size());
    id<MTLBuffer> in = [gpu newBufferWithBytes:inputs.data()
                                        length:inputs.size() * sizeof(simd_float4)
                                       options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [gpu newBufferWithLength:inputs.size() * sizeof(simd_float4) options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [gpu newCommandQueue];
    double worst = 0.0;
    for (const VEGradeUniforms &u : uniforms) {
        id<MTLCommandBuffer> commands = [queue commandBuffer];
        id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:in offset:0 atIndex:0];
        [encoder setBuffer:out offset:0 atIndex:1];
        [encoder setBytes:&u length:sizeof u atIndex:2];
        [encoder setBytes:&count length:sizeof count atIndex:3];
        if (tableTexture != nil) {
            [encoder setTexture:tableTexture atIndex:0];
        }
        [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
            threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(pipeline.maxTotalThreadsPerThreadgroup, 256), 1, 1)];
        [encoder endEncoding];
        [commands commit];
        [commands waitUntilCompleted];
        const auto *gpuValues = static_cast<const simd_float4 *>(out.contents);
        for (uint32_t i = 0; i < count; ++i) {
            const simd_float3 cpu = gradeReference(inputs[i].xyz, u, tables.empty() ? nullptr : tables.data());
            for (int c = 0; c < 3; ++c) {
                const float g = gpuValues[i][c];
                if (!std::isfinite(g) || !std::isfinite(cpu[c])) {
                    XCTFail(@"not finite: input (%g, %g, %g) channel %d: GPU %g, CPU %g", inputs[i].x, inputs[i].y,
                            inputs[i].z, c, g, cpu[c]);
                    return INFINITY;
                }
                worst = std::max(worst, std::fabs(double(g) - double(cpu[c])) / std::max(1.0, std::fabs(double(cpu[c]))));
            }
        }
    }
    return worst;
}

/// The grid of the slice 1 test: 31 values per channel, specials included.
- (std::vector<simd_float4>)gridInputs {
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
    return inputs;
}

- (void)testTheShaderWheelsMatchTheCPUReference {
    std::vector<VEGradeUniforms> uniforms;
    for (const VEInt transfer : {VEGradeTransferBT1886, VEGradeTransferSRGB, VEGradeTransferLinear}) {
        for (const GradeWheels &wheels : strongWheels()) {
            uniforms.push_back(gradeUniformsFor(ClipGrade::neutralValues(), wheels, transfer));
        }
        uniforms.push_back(gradeUniformsFor(GradeValues{2.0, 1.6, 30.0, -20.0, 1.5}, strongWheels()[7], transfer));
    }
    for (const VEGradeUniforms &u : uniforms) {
        XCTAssertEqual(u.stages, VEGradeStageWheels);
    }
    const double worst = [self largestDifferenceOver:[self gridInputs] uniforms:uniforms];
    NSLog(@"GRADE EXTENDED GPU vs CPU (wheels): %zu grades, largest difference %.3g", uniforms.size(), worst);
    // Both sides run the same float code, differing by the GPU's fast exp2/log2/pow (slice 1: 8e-6, bound
    // 2e-5). The wheels chain a third power before contrast and the re-encoding, with exponents up to 2.83,
    // which multiply the relative error of log2; 5e-5 is a twentieth of a 10-bit code.
    XCTAssertLessThanOrEqual(worst, 5e-5);
}

- (void)testTheShaderCurvesMatchTheCPUReference {
    const GradeCurves curves{CurvePoints{{0.0, 0.0}, {0.25, 0.18}, {0.75, 0.84}, {1.0, 1.0}},
                             CurvePoints{{0.0, 1.0}, {1.0, 0.0}}, CurvePoints{{0.0, 0.05}, {0.5, 0.4}, {1.0, 0.9}},
                             CurvePoints{{0.1, 0.0}, {0.3, 0.6}, {0.9, 1.0}}};
    const std::vector<float> tables = gradeTableData(curves);
    std::vector<VEGradeUniforms> uniforms;
    for (const VEInt transfer : {VEGradeTransferBT1886, VEGradeTransferSRGB, VEGradeTransferLinear}) {
        uniforms.push_back(gradeUniformsFor(ClipGrade::neutralValues(), GradeWheels{}, curves, transfer));
        uniforms.push_back(gradeUniformsFor(GradeValues{1.0, 1.4, -30.0, 10.0, 1.2}, strongWheels()[8], curves, transfer));
    }
    for (const VEGradeUniforms &u : uniforms) {
        XCTAssertTrue((u.stages & VEGradeStageCurves) != 0u);
        XCTAssertEqual(u.curveMask, 15u);
    }
    const double worst = [self largestDifferenceOver:[self gridInputs] uniforms:uniforms tables:tables];
    NSLog(@"GRADE EXTENDED GPU vs CPU (curves): %zu grades, largest difference %.3g", uniforms.size(), worst);
    // The curves add a table read and a linear interpolation, the same arithmetic on both sides; the bound is
    // the wheels' (the GPU's fast exp2/log2/pow before them).
    XCTAssertLessThanOrEqual(worst, 5e-5);
}

- (void)testTheShaderLutsMatchTheCPUReference {
    id<MTLDevice> gpu = device();
    NSError *error = nil;
    NSBundle *engine = [NSBundle bundleWithIdentifier:@"com.justjohn12345.framewright.engine"];
    id<MTLLibrary> library = [gpu newDefaultLibraryWithBundle:engine error:&error];
    id<MTLComputePipelineState> pipeline =
        [gpu newComputePipelineStateWithFunction:[library newFunctionWithName:@"ve_grade_samples_luts"] error:&error];
    XCTAssertNotNil(pipeline, @"%@", error);
    if (pipeline == nil) {
        return;
    }
    const CubeLut cube = cubeOf(33, [](simd_float3 v) {
        return simd_make_float3(0.9f * v.x * v.x + 0.1f * v.y, std::sqrt(v.y) * 0.8f + 0.1f * v.z, 1.0f - 0.7f * v.z);
    });
    CubeLut shifted = cubeOf(17, [](simd_float3 v) { return simd_make_float3(v.z, v.x, v.y) * 0.9f + 0.05f; });
    shifted.domainMin = {-0.25f, -0.25f, -0.25f};
    shifted.domainMax = {1.25f, 1.25f, 1.25f};
    const CubeLut curve = curveOf(4096, [](float x) { return std::pow(x, 0.6f); });
    struct Case {
        const CubeLut *input;
        const CubeLut *look;
        double strength;
    };
    const Case cases[] = {{&cube, nullptr, 1.0}, {nullptr, &cube, 0.7}, {&curve, &shifted, 0.5}, {&shifted, &curve, 1.0}};
    const std::vector<simd_float4> inputs = [self gridInputs];
    const uint32_t count = uint32_t(inputs.size());
    id<MTLBuffer> in = [gpu newBufferWithBytes:inputs.data()
                                        length:inputs.size() * sizeof(simd_float4)
                                       options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [gpu newBufferWithLength:inputs.size() * sizeof(simd_float4) options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> queue = [gpu newCommandQueue];
    double worst = 0.0;
    for (const Case &c : cases) {
        for (const VEInt transfer : {VEGradeTransferBT1886, VEGradeTransferLinear}) {
            const VEGradeUniforms u = gradeUniformsFor(GradeValues{0.5, 1.2, 10.0, 0.0, 1.1}, strongWheels()[8],
                                                       GradeCurves{}, c.input, c.look, c.strength, transfer);
            const std::vector<float> tableData = gradeTableData(GradeCurves{}, c.input, c.look);
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                            width:kVEGradeTableWidth
                                                                                           height:VEGradeTableRowCount
                                                                                        mipmapped:NO];
            desc.storageMode = MTLStorageModeShared;
            id<MTLTexture> tables = [gpu newTextureWithDescriptor:desc];
            [tables replaceRegion:MTLRegionMake2D(0, 0, kVEGradeTableWidth, VEGradeTableRowCount)
                      mipmapLevel:0
                        withBytes:tableData.data()
                      bytesPerRow:kVEGradeTableWidth * sizeof(float)];
            id<MTLCommandBuffer> commands = [queue commandBuffer];
            id<MTLComputeCommandEncoder> encoder = [commands computeCommandEncoder];
            [encoder setComputePipelineState:pipeline];
            [encoder setBuffer:in offset:0 atIndex:0];
            [encoder setBuffer:out offset:0 atIndex:1];
            [encoder setBytes:&u length:sizeof u atIndex:2];
            [encoder setBytes:&count length:sizeof count atIndex:3];
            [encoder setTexture:tables atIndex:0];
            [encoder setTexture:cubeTexture(c.input) atIndex:1];
            [encoder setTexture:cubeTexture(c.look) atIndex:2];
            [encoder dispatchThreads:MTLSizeMake(count, 1, 1)
                threadsPerThreadgroup:MTLSizeMake(std::min<NSUInteger>(pipeline.maxTotalThreadsPerThreadgroup, 256), 1, 1)];
            [encoder endEncoding];
            [commands commit];
            [commands waitUntilCompleted];
            const auto *gpuValues = static_cast<const simd_float4 *>(out.contents);
            for (uint32_t i = 0; i < count; ++i) {
                const simd_float3 cpu = gradeReference(inputs[i].xyz, u, tableData.data(), c.input, c.look);
                for (int ch = 0; ch < 3; ++ch) {
                    const float g = gpuValues[i][ch];
                    if (!std::isfinite(g)) {
                        XCTFail(@"not finite: input (%g, %g, %g)", inputs[i].x, inputs[i].y, inputs[i].z);
                        return;
                    }
                    worst = std::max(worst, std::fabs(double(g) - double(cpu[ch])) / std::max(1.0, std::fabs(double(cpu[ch]))));
                }
            }
        }
    }
    NSLog(@"GRADE EXTENDED GPU vs CPU (LUTs, with wheels and a basic grade): largest difference %.3g", worst);
    // The LUT stages read texels and interpolate with the same arithmetic on both sides; what differs comes
    // from the grade's powers before them, so the wheels' bound holds.
    XCTAssertLessThanOrEqual(worst, 5e-5);
}

// MARK: - Rendered

- (void)testAPictureWithLutsIsTheReferenceOfTheUngradedPicture {
    const size_t w = 128, h = 32;
    const TextureSet set = texturesFor(*_compositor, colourRamp(w, h));
    RenderGraph plain = makeGraph(int32_t(w), int32_t(h));
    plain.layers.push_back(makeLayer(1));
    const std::vector<float> before = [self render:plain textures:{set} width:w height:h];
    const auto cube = std::make_shared<const CubeLut>(
        cubeOf(17, [](simd_float3 v) { return simd_make_float3(v.y, 0.5f * v.x + 0.4f * v.z, v.z * v.z); }));
    const auto curve = std::make_shared<const CubeLut>(curveOf(64, [](float x) { return std::sqrt(x); }));
    double worst = 0.0;
    for (const auto &[input, look] : std::vector<std::pair<std::shared_ptr<const CubeLut>, std::shared_ptr<const CubeLut>>>{
             {cube, nullptr}, {nullptr, cube}, {curve, cube}, {cube, curve}}) {
        RenderGraph graded = plain;
        graded.layers[0].gradeInputLut = input;
        graded.layers[0].gradeInputLutId = input ? cubeContentId(*input) : std::string();
        graded.layers[0].gradeLookLut = look;
        graded.layers[0].gradeLookLutId = look ? cubeContentId(*look) : std::string();
        graded.layers[0].gradeLookStrength = look ? 0.75 : 1.0;
        const std::vector<float> after = [self render:graded textures:{set} width:w height:h];
        const VEGradeUniforms u = gradeUniformsFor(ClipGrade::neutralValues(), GradeWheels{}, GradeCurves{}, input.get(),
                                                   look.get(), look ? 0.75 : 1.0, VEGradeTransferBT1886);
        const std::vector<float> tables = gradeTableData(GradeCurves{}, input.get(), look.get());
        for (size_t i = 0; i + 3 < before.size() && i + 3 < after.size(); i += 4) {
            const simd_float3 expected = simd_clamp(
                gradeReference(simd_make_float3(before[i], before[i + 1], before[i + 2]), u, tables.data(), input.get(),
                               look.get()),
                simd_make_float3(0.0f, 0.0f, 0.0f), simd_make_float3(1.0f, 1.0f, 1.0f));
            for (int c = 0; c < 3; ++c) {
                worst = std::max(worst, double(std::fabs(after[i + c] - expected[c])));
            }
        }
    }
    NSLog(@"GRADE EXTENDED rendered LUTs against the reference of the ungraded picture: %.3g", worst);
    XCTAssertLessThan(worst, 1e-4);
}

- (void)testAPictureGradedWithCurvesIsTheReferenceOfTheUngradedPicture {
    const size_t w = 128, h = 32;
    const TextureSet set = texturesFor(*_compositor, colourRamp(w, h));
    RenderGraph plain = makeGraph(int32_t(w), int32_t(h));
    plain.layers.push_back(makeLayer(1));
    const std::vector<float> before = [self render:plain textures:{set} width:w height:h];
    const std::vector<GradeCurves> looks = {
        GradeCurves{{CurvePoints{{0.0, 0.0}, {0.25, 0.18}, {0.75, 0.84}, {1.0, 1.0}}, {}, {}, {}}},
        GradeCurves{{{}, CurvePoints{{0.0, 1.0}, {1.0, 0.0}}, {}, CurvePoints{{0.0, 0.2}, {1.0, 0.7}}}},
        GradeCurves{{CurvePoints{{0.0, 0.1}, {1.0, 0.9}}, CurvePoints{{0.0, 0.0}, {0.5, 0.6}, {1.0, 1.0}},
                    CurvePoints{{0.2, 0.0}, {0.8, 1.0}}, CurvePoints{{0.0, 0.0}, {0.4, 0.3}, {1.0, 1.0}}}},
    };
    double worst = 0.0;
    for (const GradeCurves &curves : looks) {
        RenderGraph graded = plain;
        graded.layers[0].gradeCurves = curves;
        const std::vector<float> after = [self render:graded textures:{set} width:w height:h];
        const VEGradeUniforms u =
            gradeUniformsFor(ClipGrade::neutralValues(), GradeWheels{}, curves, VEGradeTransferBT1886);
        const std::vector<float> tables = gradeTableData(curves);
        for (size_t i = 0; i + 3 < before.size() && i + 3 < after.size(); i += 4) {
            const simd_float3 expected =
                simd_clamp(gradeReference(simd_make_float3(before[i], before[i + 1], before[i + 2]), u, tables.data()),
                           simd_make_float3(0.0f, 0.0f, 0.0f), simd_make_float3(1.0f, 1.0f, 1.0f));
            for (int c = 0; c < 3; ++c) {
                worst = std::max(worst, double(std::fabs(after[i + c] - expected[c])));
            }
        }
    }
    NSLog(@"GRADE EXTENDED rendered curves against the reference of the ungraded picture: %.3g", worst);
    XCTAssertLessThan(worst, 1e-4);
    // Two clips with different curves in one frame use their own tables (the compositor's cache).
    RenderGraph two = makeGraph(int32_t(w), int32_t(h));
    VideoLayer left = makeLayer(1);
    left.gradeCurves = looks[1];
    left.transform.scale = 0.5;
    left.transform.x = -double(w) / 4.0;
    VideoLayer right = makeLayer(2);
    right.gradeCurves = looks[2];
    right.transform.scale = 0.5;
    right.transform.x = double(w) / 4.0;
    two.layers = {left, right};
    const std::vector<float> both = [self render:two textures:{set, set} width:w height:h];
    RenderGraph leftAlone = makeGraph(int32_t(w), int32_t(h));
    leftAlone.layers = {left};
    RenderGraph rightAlone = makeGraph(int32_t(w), int32_t(h));
    rightAlone.layers = {right};
    const std::vector<float> l = [self render:leftAlone textures:{set} width:w height:h];
    const std::vector<float> r = [self render:rightAlone textures:{set} width:w height:h];
    double worstPair = 0.0;
    double sidesDiffer = 0.0;
    for (size_t y = 0; y < h; ++y) {
        for (size_t x = 0; x < w; ++x) {
            const size_t i = (y * w + x) * 4;
            const std::vector<float> &alone = x < w / 2 ? l : r;
            for (int c = 0; c < 3; ++c) {
                worstPair = std::max(worstPair, double(std::fabs(both[i + c] - alone[i + c])));
                sidesDiffer = std::max(sidesDiffer, double(std::fabs(l[(y * w + (x % (w / 2))) * 4 + c] -
                                                                      r[(y * w + (x % (w / 2)) + w / 2) * 4 + c])));
            }
        }
    }
    XCTAssertLessThan(worstPair, 1e-6, @"each layer graded by its own curves");
    XCTAssertGreaterThan(sidesDiffer, 0.1, @"the two looks differ");
}

- (void)testAPictureGradedWithWheelsIsTheReferenceOfTheUngradedPicture {
    const size_t w = 128, h = 32;
    const TextureSet set = texturesFor(*_compositor, colourRamp(w, h));
    RenderGraph plain = makeGraph(int32_t(w), int32_t(h));
    plain.layers.push_back(makeLayer(1));
    const std::vector<float> before = [self render:plain textures:{set} width:w height:h];
    double worst = 0.0;
    for (const GradeWheels &wheels : strongWheels()) {
        RenderGraph graded = plain;
        graded.layers[0].gradeWheels = wheels;
        const std::vector<float> after = [self render:graded textures:{set} width:w height:h];
        XCTAssertEqual(before.size(), after.size());
        // An untagged 10-bit video picture: BT.1886.
        const VEGradeUniforms u = gradeUniformsFor(ClipGrade::neutralValues(), wheels, VEGradeTransferBT1886);
        for (size_t i = 0; i + 3 < before.size() && i + 3 < after.size(); i += 4) {
            const simd_float3 expected =
                simd_clamp(gradeReference(simd_make_float3(before[i], before[i + 1], before[i + 2]), u),
                           simd_make_float3(0.0f, 0.0f, 0.0f), simd_make_float3(1.0f, 1.0f, 1.0f));
            for (int c = 0; c < 3; ++c) {
                worst = std::max(worst, double(std::fabs(after[i + c] - expected[c])));
            }
        }
    }
    NSLog(@"GRADE EXTENDED rendered wheels against the reference of the ungraded picture: %.3g", worst);
    XCTAssertLessThan(worst, 1e-4);
}

- (void)testGainAndGammaKeepABlackFrameBlack {
    const size_t w = 32, h = 16;
    for (const OSType format : {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_32BGRA}) {
        media::PixelBuffer black = makeBuffer(format, w, h);
        if (format == kCVPixelFormatType_32BGRA) {
            fillBGRA(black, {0, 0, 0, 255});
        } else {
            fillYCbCr(black, bitDepthOf(format) == 10 ? 64 : 16, bitDepthOf(format) == 10 ? 512 : 128,
                      bitDepthOf(format) == 10 ? 512 : 128, media::YCbCrMatrix::BT709);
        }
        const TextureSet set = texturesFor(*_compositor, black);
        for (const GradeWheels &wheels :
             {wheelsOf({}, {1.0, 0.5, 0.5}, {1.0, -0.6, 0.8}), wheelsOf({}, {-1.0, 0, 1.0}, {0.7, 1.0, 0})}) {
            RenderGraph g = makeGraph(int32_t(w), int32_t(h));
            VideoLayer layer = makeLayer(1);
            layer.gradeWheels = wheels;
            layer.grade[static_cast<std::size_t>(GradeParameter::Exposure)] = 5.0;
            g.layers.push_back(layer);
            const std::vector<float> v = [self render:g textures:{set} width:w height:h];
            size_t notBlack = 0;
            for (size_t i = 0; i < v.size(); i += 4) {
                notBlack += (v[i] != 0.0f || v[i + 1] != 0.0f || v[i + 2] != 0.0f) ? 1 : 0;
            }
            XCTAssertEqual(notBlack, 0u, @"format %u", unsigned(format));
        }
        // Lift raises it (what lift is for).
        RenderGraph lifted = makeGraph(int32_t(w), int32_t(h));
        VideoLayer layer = makeLayer(1);
        layer.gradeWheels = wheelsOf({0.5, 0, 0}, {}, {});
        lifted.layers.push_back(layer);
        const std::vector<float> v = [self render:lifted textures:{set} width:w height:h];
        XCTAssertEqualWithAccuracy(v[0], std::pow(0.05, 1.0 / 2.4), 1e-4);
    }
}

- (void)testEachSideOfADissolveGetsItsOwnGradeWithOneSideExtended {
    const size_t w = 64, h = 16;
    const TextureSet ta = texturesFor(*_compositor, colourRamp(w, h));
    const TextureSet tb = texturesFor(*_compositor, colourRamp(w, h));
    const GradeWheels wheelsA = wheelsOf({0.2, 0.3, 0}, {0.4, 0, -0.5}, {-0.3, 0, 0});
    GradeValues basicB = ClipGrade::neutralValues();
    basicB[static_cast<std::size_t>(GradeParameter::Contrast)] = 1.8;
    auto single = [&](const TextureSet &set, const GradeWheels &wheels, const GradeValues &basic) {
        RenderGraph g = makeGraph(int32_t(w), int32_t(h));
        VideoLayer layer = makeLayer(1);
        layer.gradeWheels = wheels;
        layer.grade = basic;
        g.layers.push_back(layer);
        return [self render:g textures:{set} width:w height:h];
    };
    const std::vector<float> aGraded = single(ta, wheelsA, ClipGrade::neutralValues());
    const std::vector<float> bGraded = single(tb, GradeWheels{}, basicB);
    for (const bool extendedFirst : {true, false}) {
        for (const double mix : {0.0, 0.4, 1.0}) {
            RenderGraph g = makeGraph(int32_t(w), int32_t(h));
            VideoLayer out = makeLayer(1);
            VideoLayer in = makeLayer(2);
            if (extendedFirst) {
                out.gradeWheels = wheelsA;
                in.grade = basicB;
            } else {
                out.grade = basicB;
                in.gradeWheels = wheelsA;
            }
            LayerTransition t;
            t.mix = mix;
            t.partnerClipId = in.clipId;
            t.partnerLayerIndex = 1;
            out.transition = t;
            t.isIncoming = true;
            t.partnerClipId = out.clipId;
            t.partnerLayerIndex = 0;
            in.transition = t;
            g.layers = {out, in};
            const std::vector<float> v = [self render:g textures:{extendedFirst ? ta : tb, extendedFirst ? tb : ta}
                                                width:w
                                               height:h];
            const std::vector<float> &first = extendedFirst ? aGraded : bGraded;
            const std::vector<float> &second = extendedFirst ? bGraded : aGraded;
            double worst = 0.0;
            for (size_t i = 0; i < v.size(); ++i) {
                if (i % 4 != 3) {
                    worst = std::max(worst, std::fabs(double(v[i]) - ((1.0 - mix) * first[i] + mix * second[i])));
                }
            }
            XCTAssertLessThan(worst, 1e-5, @"mix %.1f, extended %s", mix, extendedFirst ? "outgoing" : "incoming");
        }
    }
}

// MARK: - Cost

- (void)testTheExtendedGradeCostOnTheGPU {
    for (const size_t height : {size_t(1080), size_t(2160)}) {
        const size_t width = height * 16 / 9;
        const TextureSet set = texturesFor(*_compositor, colourRamp(width, height));
        id<MTLTexture> target = makeFloatTarget(width, height);
        auto timeOf = [&](const RenderGraph &graph) {
            TextureTarget t{target, {}, nil};
            auto result = renderLayers(*_compositor, graph, {set}, t);
            return result.ok() ? result->gpuSeconds * 1000.0 : -1.0;
        };
        RenderGraph plain = makeGraph(int32_t(width), int32_t(height));
        plain.layers.push_back(makeLayer(1));
        RenderGraph basic = plain;
        basic.layers[0].grade = GradeValues{0.5, 1.2, 20.0, -10.0, 1.1};
        RenderGraph wheels = basic;
        wheels.layers[0].gradeWheels = strongWheels()[8];
        RenderGraph curves = wheels;
        curves.layers[0].gradeCurves =
            GradeCurves{{CurvePoints{{0.0, 0.0}, {0.25, 0.18}, {0.75, 0.84}, {1.0, 1.0}}, CurvePoints{{0.0, 0.05}, {1.0, 0.95}},
                        CurvePoints{{0.0, 0.0}, {0.5, 0.55}, {1.0, 1.0}}, CurvePoints{{0.0, 0.1}, {1.0, 1.0}}}};
        struct Scene {
            const char *name;
            const RenderGraph *graph;
            std::vector<double> times;
        };
        RenderGraph luts = curves;
        const auto look = std::make_shared<const CubeLut>(
            cubeOf(33, [](simd_float3 v) { return simd_make_float3(v.y, 0.5f * v.x + 0.4f * v.z, v.z * v.z); }));
        const auto shaper = std::make_shared<const CubeLut>(curveOf(1024, [](float x) { return std::sqrt(x); }));
        luts.layers[0].gradeInputLut = shaper;
        luts.layers[0].gradeInputLutId = cubeContentId(*shaper);
        luts.layers[0].gradeLookLut = look;
        luts.layers[0].gradeLookLutId = cubeContentId(*look);
        luts.layers[0].gradeLookStrength = 0.8;
        Scene scenes[] = {{"ungraded", &plain, {}},
                          {"basic grade", &basic, {}},
                          {"basic grade + wheels", &wheels, {}},
                          {"basic grade + wheels + curves", &curves, {}},
                          {"everything: + 1D input LUT + 33^3 look", &luts, {}}};
        for (int i = 0; i < 70; ++i) {
            for (Scene &scene : scenes) {
                const double ms = timeOf(*scene.graph);
                if (i >= 10) {
                    scene.times.push_back(ms);
                }
            }
        }
        for (Scene &scene : scenes) {
            std::sort(scene.times.begin(), scene.times.end());
            const double median = scene.times[scene.times.size() / 2];
            NSLog(@"GRADE EXTENDED COST %zup %s: GPU %.3f ms per frame (median of 60)", height, scene.name, median);
            XCTAssertLessThan(median, 8.0);
        }
    }
}

@end
