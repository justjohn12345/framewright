// Engine Metal shaders. Compiled into VidEditEngine.framework/Resources/default.metallib;
// load with [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:VEEngine.class] error:].
//
// Compositing model (see Compositor.h): every layer is drawn as a quad covering its footprint
// in sequence pixels; the fragment shader maps each output position back to source uv
// (inverse affine), samples bilinearly, converts YCbCr to gamma-encoded R'G'B', applies an
// anti-aliased edge coverage and the layer weight, and returns premultiplied colour for
// ONE / ONE_MINUS_SOURCE_ALPHA blending. A dissolve pair is drawn in one pass as
// mix(A, B, m) of the two premultiplied samples, so the crossfade is exact over transparency.

#include <metal_stdlib>
#include "ShaderTypes.h"

using namespace metal;

// MARK: - Passthrough (full-screen triangle, texture copied unchanged)

struct VEPassthroughVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Full-screen triangle generated from the vertex id; draw with 3 vertices and no vertex buffer.
vertex VEPassthroughVertexOut ve_passthrough_vertex(uint vertexID [[vertex_id]]) {
    const float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    VEPassthroughVertexOut out;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.texCoord = uv;
    return out;
}

// Samples the bound texture unchanged.
fragment float4 ve_passthrough_fragment(VEPassthroughVertexOut in [[stage_in]],
                                        texture2d<float> source [[texture(0)]]) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    return source.sample(linearSampler, in.texCoord);
}

// MARK: - Layer compositing

constant bool kSourceAIsYCbCr [[function_constant(VEFunctionConstantSourceAIsYCbCr)]];
constant bool kHasPartner [[function_constant(VEFunctionConstantHasPartner)]];
constant bool kSourceBIsYCbCr [[function_constant(VEFunctionConstantSourceBIsYCbCr)]];
constant bool kSourceBHasChroma = kHasPartner && kSourceBIsYCbCr;

struct VELayerVertexOut {
    float4 position [[position]];
    float2 framePosition; // sequence pixels, origin top left
};

// Quad (triangle strip, 4 vertices) covering uniforms.quadRect.
vertex VELayerVertexOut ve_layer_vertex(uint vertexID [[vertex_id]],
                                        constant VEDrawUniforms &uniforms [[buffer(VEBufferIndexDraw)]]) {
    const float2 corner = float2(vertexID & 1, (vertexID >> 1) & 1);
    const float2 p = mix(uniforms.quadRect.xy, uniforms.quadRect.zw, corner);
    VELayerVertexOut out;
    out.position = float4(p.x * uniforms.frameSize.z * 2.0 - 1.0, 1.0 - p.y * uniforms.frameSize.w * 2.0, 0.0, 1.0);
    out.framePosition = p;
    return out;
}

static float2 sourceUV(constant VESourceUniforms &source, float2 framePosition) {
    const float3 p = float3(framePosition, 1.0);
    return float2(dot(source.uvFromFrameX.xyz, p), dot(source.uvFromFrameY.xyz, p));
}

// Fraction of the output pixel inside the source rectangle [0,1]^2: 1 inside, 0 outside, a
// one-pixel linear ramp across the edge (exact 1/0 for axis-aligned edges on pixel boundaries).
// Must be called in uniform control flow (screen-space derivatives).
static float edgeCoverage(float2 uv) {
    const float2 distanceToEdge = min(uv, 1.0 - uv);
    const float2 pixelsPerUV = 1.0 / max(fwidth(uv), float2(1.0e-7));
    const float2 coverage = saturate(distanceToEdge * pixelsPerUV + 0.5);
    return coverage.x * coverage.y;
}

// Chroma is sampled at the luma position mapped through the source's chroma transform, so
// left/top/bottom-sited chroma lines up with the luma it belongs to (see TextureCache.h).
static float4 sampleYCbCr(texture2d<float> luma, texture2d<float> chroma, float2 uv, constant VESourceUniforms &source) {
    constexpr sampler bilinear(address::clamp_to_edge, filter::linear);
    const float y = luma.sample(bilinear, uv).r;
    const float2 chromaUV = uv * source.chromaTransform.xy + source.chromaTransform.zw;
    const float2 cbcr = chroma.sample(bilinear, chromaUV).rg;
    const float3 rgb = saturate((source.colorMatrix * float4(y, cbcr, 1.0)).rgb);
    return float4(rgb, 1.0);
}

static float4 sampleRGBA(texture2d<float> rgba, float2 uv) {
    constexpr sampler bilinear(address::clamp_to_edge, filter::linear);
    return rgba.sample(bilinear, uv); // premultiplied by convention (see TextureCache.h)
}

fragment float4 ve_layer_fragment(VELayerVertexOut in [[stage_in]],
                                  constant VEDrawUniforms &uniforms [[buffer(VEBufferIndexDraw)]],
                                  texture2d<float> a0 [[texture(VETextureIndexA0)]],
                                  texture2d<float> a1 [[texture(VETextureIndexA1), function_constant(kSourceAIsYCbCr)]],
                                  texture2d<float> b0 [[texture(VETextureIndexB0), function_constant(kHasPartner)]],
                                  texture2d<float> b1 [[texture(VETextureIndexB1), function_constant(kSourceBHasChroma)]]) {
    const float2 uvA = sourceUV(uniforms.a, in.framePosition);
    const float coverageA = edgeCoverage(uvA);
    float4 colorA;
    if (kSourceAIsYCbCr) {
        colorA = sampleYCbCr(a0, a1, uvA, uniforms.a);
    } else {
        colorA = sampleRGBA(a0, uvA);
    }
    colorA *= coverageA * uniforms.a.params.x;
    if (!kHasPartner) {
        return colorA;
    }

    const float2 uvB = sourceUV(uniforms.b, in.framePosition);
    const float coverageB = edgeCoverage(uvB);
    float4 colorB;
    if (kSourceBIsYCbCr) {
        colorB = sampleYCbCr(b0, b1, uvB, uniforms.b);
    } else {
        colorB = sampleRGBA(b0, uvB);
    }
    colorB *= coverageB * uniforms.b.params.x;
    return mix(colorA, colorB, uniforms.mix.x);
}

// MARK: - Export conversion (RGBA16Float composite -> target pixel buffer planes)

kernel void ve_convert_to_bgra(texture2d<float, access::read> composite [[texture(VETextureIndexComposite)]],
                               texture2d<float, access::write> output [[texture(VETextureIndexOut0)]],
                               constant VEConvertUniforms &uniforms [[buffer(VEBufferIndexConvert)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uniforms.size.x || gid.y >= uniforms.size.y) {
        return;
    }
    const float4 c = composite.read(gid);
    // The composite is opaque (cleared to opaque black); write it out as such.
    output.write(float4(saturate(c.rgb), 1.0), gid);
}

// One thread per chroma sample (2x2 luma block, 4:2:0): writes the block's four luma samples and
// one left-sited chroma sample (co-sited with the block's left column, vertically between its
// rows: kCVImageBufferChromaLocation_Left, the H.264/HEVC default). Chroma is the target
// matrix applied to the [1 2 1] / 4 horizontal filter around the left column, averaged over the
// block's two rows; edges repeat the outermost pixel, and a missing second row or column (odd
// sizes) is left out.
kernel void ve_convert_to_420(texture2d<float, access::read> composite [[texture(VETextureIndexComposite)]],
                              texture2d<float, access::write> luma [[texture(VETextureIndexOut0)]],
                              texture2d<float, access::write> chroma [[texture(VETextureIndexOut1)]],
                              constant VEConvertUniforms &uniforms [[buffer(VEBufferIndexConvert)]],
                              uint2 gid [[thread_position_in_grid]]) {
    const uint2 size = uniforms.size.xy;
    const uint2 chromaSize = (size + 1) / 2;
    if (gid.x >= chromaSize.x || gid.y >= chromaSize.y) {
        return;
    }
    const uint x0 = gid.x * 2;
    const bool hasRight = x0 + 1 < size.x;
    float3 sum = float3(0.0);
    float rows = 0.0;
    for (uint dy = 0; dy < 2; ++dy) {
        const uint y = gid.y * 2 + dy;
        if (y >= size.y) {
            break;
        }
        const float3 centre = saturate(composite.read(uint2(x0, y)).rgb);
        const float3 right = hasRight ? saturate(composite.read(uint2(x0 + 1, y)).rgb) : centre;
        const float3 left = x0 > 0 ? saturate(composite.read(uint2(x0 - 1, y)).rgb) : centre;
        luma.write(float4(dot(uniforms.yRow.xyz, centre) + uniforms.yRow.w), uint2(x0, y));
        if (hasRight) {
            luma.write(float4(dot(uniforms.yRow.xyz, right) + uniforms.yRow.w), uint2(x0 + 1, y));
        }
        sum += 0.25 * left + 0.5 * centre + 0.25 * right;
        rows += 1.0;
    }
    const float3 filtered = sum / rows;
    const float cb = dot(uniforms.cbRow.xyz, filtered) + uniforms.cbRow.w;
    const float cr = dot(uniforms.crRow.xyz, filtered) + uniforms.crRow.w;
    chroma.write(float4(cb, cr, 0.0, 0.0), gid);
}
