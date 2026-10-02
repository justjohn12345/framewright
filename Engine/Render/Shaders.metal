// Engine Metal shaders. Compiled into FramewrightEngine.framework/Resources/default.metallib;
// load with [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:VEEngine.class] error:].
//
// Compositing model (see Compositor.h): every layer is drawn as a quad covering its footprint
// in sequence pixels; the fragment shader maps each output position back to source uv
// (inverse affine), samples bilinearly, converts YCbCr to gamma-encoded R'G'B', grades a graded
// source (ColorGrade.h; function constants select it per source), applies an
// anti-aliased edge coverage and the layer weight, and returns premultiplied colour for
// ONE / ONE_MINUS_SOURCE_ALPHA blending. A dissolve pair is drawn in one pass as
// mix(A, B, m) of the two premultiplied samples, so the crossfade is exact over transparency; m is the
// uniform mix for a cross dissolve and the per-pixel reveal for a wipe or the iris (transitionReveal: the
// soft edge averaged over the frame's exposure).

#include <metal_stdlib>
#include "ShaderTypes.h"
#include "ColorGrade.h"

using namespace metal;

// MARK: - Layer compositing

constant bool kSourceAIsYCbCr [[function_constant(VEFunctionConstantSourceAIsYCbCr)]];
constant bool kHasPartner [[function_constant(VEFunctionConstantHasPartner)]];
constant bool kSourceBIsYCbCr [[function_constant(VEFunctionConstantSourceBIsYCbCr)]];
constant bool kSourceBHasChroma = kHasPartner && kSourceBIsYCbCr;
// A graded source (ColorGrade.h): its R'G'B' stays unclamped through the grade, which clamps at its end.
// Absent (older pipelines, tests that specialise only the three above), a source is ungraded.
constant bool kSourceAHasGradeValue [[function_constant(VEFunctionConstantSourceAHasGrade)]];
constant bool kSourceBHasGradeValue [[function_constant(VEFunctionConstantSourceBHasGrade)]];
constant bool kSourceAHasGrade = is_function_constant_defined(kSourceAHasGradeValue) && kSourceAHasGradeValue;
constant bool kSourceBHasGrade =
    kHasPartner && is_function_constant_defined(kSourceBHasGradeValue) && kSourceBHasGradeValue;

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

// `uv` over a plane's picture as uv in its texture: the picture fills the top-left `extent` of the texture
// (VESourceUniforms::planeExtent; (1, 1) for a source plane), and the sample is kept half a texel inside that
// region's right and bottom edges, as clamp_to_edge keeps it inside a whole texture's (the left and top
// edges are the texture's own).
static float2 planeUV(float2 uv, float2 extent, texture2d<float> plane) {
    const float2 halfTexel = 0.5 / float2(plane.get_width(), plane.get_height());
    return min(uv * extent, extent - halfTexel);
}

// Chroma is sampled at the luma position mapped through the source's chroma transform, so
// left/top/bottom-sited chroma lines up with the luma it belongs to (see TextureCache.h).
// An ungraded source's R'G'B' is limited to [0, 1] here; a graded one (`graded`) keeps the values below
// black and above white for its grade, which limits its result (grading decision, section 3).
static float4 sampleYCbCr(texture2d<float> luma, texture2d<float> chroma, float2 uv, constant VESourceUniforms &source,
                          bool graded) {
    constexpr sampler bilinear(address::clamp_to_edge, filter::linear);
    const float y = luma.sample(bilinear, planeUV(uv, source.planeExtent.xy, luma)).r;
    const float2 chromaUV = uv * source.chromaTransform.xy + source.chromaTransform.zw;
    const float2 cbcr = chroma.sample(bilinear, planeUV(chromaUV, source.planeExtent.zw, chroma)).rg;
    const float3 converted = (source.colorMatrix * float4(y, cbcr, 1.0)).rgb;
    return float4(graded ? converted : saturate(converted), 1.0);
}

// A texel or sample as the blend may see it: limited to [0, 1] for an ungraded source; for a graded one
// only its alpha is (its colour goes through the grade, which limits it).
static float4 limitSample(float4 c, bool graded) {
    return graded ? float4(c.rgb, saturate(c.a)) : saturate(c);
}

// Premultiplied sources are filtered by the sampler. Straight-alpha sources are filtered by hand
// (the same bilinear footprint, edges clamped) with every texel premultiplied first: filtering
// straight colour and premultiplying afterwards would let the colour of fully transparent texels
// bleed into the edge of the visible ones. Values are limited to [0, 1] as sampleYCbCr limits R'G'B'
// (grading decision, section 3: an ungraded source keeps the clamp): a no-op for unorm textures, it
// keeps an extended-range still ('RGhA') and its float pre-scale's Lanczos overshoot to what the
// blend has always seen. A graded source (`graded`) keeps its colour for the grade; its alpha is limited.
static float4 sampleRGBA(texture2d<float> rgba, float2 uv, constant VESourceUniforms &source, bool graded) {
    constexpr sampler bilinear(address::clamp_to_edge, filter::linear);
    if (source.straightAlpha == 0) {
        return limitSample(rgba.sample(bilinear, planeUV(uv, source.planeExtent.xy, rgba)), graded);
    }
    // The picture's own texels: the top-left extent of the texture.
    const int2 size = max(int2(rint(float2(rgba.get_width(), rgba.get_height()) * source.planeExtent.xy)), int2(1));
    const float2 p = uv * float2(size) - 0.5;
    const float2 f = fract(p);
    const int2 i0 = int2(floor(p));
    const int2 lo = clamp(i0, int2(0), size - 1);
    const int2 hi = clamp(i0 + 1, int2(0), size - 1);
    float4 t00 = limitSample(rgba.read(uint2(lo.x, lo.y)), graded);
    float4 t10 = limitSample(rgba.read(uint2(hi.x, lo.y)), graded);
    float4 t01 = limitSample(rgba.read(uint2(lo.x, hi.y)), graded);
    float4 t11 = limitSample(rgba.read(uint2(hi.x, hi.y)), graded);
    t00.rgb *= t00.a;
    t10.rgb *= t10.a;
    t01.rgb *= t01.a;
    t11.rgb *= t11.a;
    return mix(mix(t00, t10, f.x), mix(t01, t11, f.x), f.y);
}

// G(x) - max(x, 0), where G is the integral of the soft edge S(x) = smoothstep(-f, f, x) up to x: zero
// outside the band |x| < f, where G(x) = 2f (t^3 - t^4 / 2), t = (x + f) / (2f). Split this way the
// frame's reveal below is a difference of small numbers, not of two large G values.
static float softEdgeIntegralExcess(float x, float f) {
    if (x <= -f || x >= f) {
        return 0.0;
    }
    const float t = (x + f) / (2.0 * f);
    return 2.0 * f * t * t * t * (1.0 - 0.5 * t) - max(x, 0.0);
}

// The reveal m of a shaped transition (VETransitionShape, not None) at sequence position p of a
// `frame`-sized frame exposed over the progress interval [p0, p1], with a soft edge `feather` pixels wide
// on each side: the formula documented in RenderGraph.h (transitionReveal, kTransitionFeather), the soft
// edge averaged over the interval. 0 shows none of the incoming picture, 1 all of it; the intervals [0, 0]
// and [1, 1] give exactly 0 and 1 everywhere in the frame.
static float transitionReveal(int shape, float p0, float p1, float feather, float2 p, float2 frame) {
    float d;
    float travel;
    switch (shape) {
    case VETransitionShapeWipeLeft:
        d = frame.x - p.x;
        travel = frame.x;
        break;
    case VETransitionShapeWipeRight:
        d = p.x;
        travel = frame.x;
        break;
    case VETransitionShapeWipeUp:
        d = frame.y - p.y;
        travel = frame.y;
        break;
    case VETransitionShapeWipeDown:
        d = p.y;
        travel = frame.y;
        break;
    default: // VETransitionShapeIris
        d = length(p - 0.5 * frame);
        travel = 0.5 * length(frame);
        break;
    }
    const float f = max(feather, 1.0e-3);
    const float e0 = p0 * (travel + 2.0 * f) - f;
    const float e1 = p1 * (travel + 2.0 * f) - f;
    const float sweep = e1 - e0;
    if (sweep < 1.0e-3) {
        // A frame without length: the soft edge at its instant.
        const float r = 0.5 * (e0 + e1);
        const float t = saturate((d - (r - f)) / (2.0 * f));
        return 1.0 - t * t * (3.0 - 2.0 * t);
    }
    // 1 - (G(d - e0) - G(d - e1)) / sweep, with G(x) = max(x, 0) + excess(x) and
    // max(d - e0, 0) - max(d - e1, 0) = clamp(d - e0, 0, sweep).
    const float covered = clamp(d - e0, 0.0, sweep) + softEdgeIntegralExcess(d - e0, f) -
                          softEdgeIntegralExcess(d - e1, f);
    return saturate(1.0 - covered / sweep);
}

// A graded source's premultiplied sample, graded (ColorGrade.h) and limited to [0, 1]: the grade sees the
// unpremultiplied colour (divided by alpha, kept at 0 where alpha is 0) and the result is premultiplied
// again; opaque YCbCr samples have alpha 1.
static float4 gradeSample(float4 premultiplied, constant VEGradeUniforms &grade) {
    const float alpha = premultiplied.a;
    const float3 colour = alpha > 0.0 ? premultiplied.rgb / alpha : float3(0.0);
    const float3 graded = saturate(veGrade(colour, grade.gain.x, grade.gain.y, grade.gain.z, grade.saturation,
                                           grade.contrast, grade.contrastSlope, grade.transfer));
    return float4(graded * alpha, alpha);
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
        colorA = sampleYCbCr(a0, a1, uvA, uniforms.a, kSourceAHasGrade);
    } else {
        colorA = sampleRGBA(a0, uvA, uniforms.a, kSourceAHasGrade);
    }
    if (kSourceAHasGrade) {
        colorA = gradeSample(colorA, uniforms.a.grade);
    }
    colorA *= coverageA * uniforms.a.weight;
    constant VETransitionUniforms &transition = uniforms.transition;
    const int shape = transition.shape;
    if (!kHasPartner) {
        if (shape != VETransitionShapeNone) {
            const float m = transitionReveal(shape, transition.progressStart, transition.progressEnd,
                                             transition.feather, in.framePosition, uniforms.frameSize.xy);
            colorA *= transition.incoming != 0 ? m : 1.0 - m;
        }
        return colorA;
    }

    const float2 uvB = sourceUV(uniforms.b, in.framePosition);
    const float coverageB = edgeCoverage(uvB);
    float4 colorB;
    if (kSourceBIsYCbCr) {
        colorB = sampleYCbCr(b0, b1, uvB, uniforms.b, kSourceBHasGrade);
    } else {
        colorB = sampleRGBA(b0, uvB, uniforms.b, kSourceBHasGrade);
    }
    if (kSourceBHasGrade) {
        colorB = gradeSample(colorB, uniforms.b.grade);
    }
    colorB *= coverageB * uniforms.b.weight;
    if (shape == VETransitionShapeNone) {
        return mix(colorA, colorB, transition.mix);
    }
    return mix(colorA, colorB, transitionReveal(shape, transition.progressStart, transition.progressEnd,
                                                transition.feather, in.framePosition, uniforms.frameSize.xy));
}

// MARK: - The grade over a list of values (for the tests)

// Grades `count` R'G'B' values of `input` (float4 each, w ignored) with `grade` into `output` (float4, w 0),
// unclamped: the same function the fragment shader runs on a graded source (ColorGrade.h), so the tests can
// hold it to the CPU reference value by value. Not used for rendering.
kernel void ve_grade_samples(device const float4 *input [[buffer(0)]],
                             device float4 *output [[buffer(1)]],
                             constant VEGradeUniforms &grade [[buffer(2)]],
                             constant uint &count [[buffer(3)]],
                             uint gid [[thread_position_in_grid]]) {
    if (gid >= count) {
        return;
    }
    const float3 graded = veGrade(input[gid].rgb, grade.gain.x, grade.gain.y, grade.gain.z, grade.saturation,
                                  grade.contrast, grade.contrastSlope, grade.transfer);
    output[gid] = float4(graded, 0.0);
}

// MARK: - Minification

// Straight-alpha RGBA -> premultiplied RGBA8 (RGBA16Float for a deep picture), before a straight-alpha
// picture is resampled for minification (see Compositor.h).
kernel void ve_premultiply(texture2d<float, access::read> source [[texture(0)]],
                           texture2d<float, access::write> destination [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= source.get_width() || gid.y >= source.get_height()) {
        return;
    }
    const float4 c = source.read(gid);
    destination.write(float4(c.rgb * c.a, c.a), gid);
}

// MARK: - Sharpening of pre-scaled planes

// Compositor.h "Sharpening": out = c + amount * g(c - blur), blur the separable binomial [1 4 6 4 1] / 16
// (sigma 1 texel) with the edge texels repeated, g(d) = d * smoothstep(t, 2t, |d|).
kernel void ve_unsharp(texture2d<float, access::read> source [[texture(VETextureIndexUnsharpSource)]],
                       texture2d<float, access::write> destination [[texture(VETextureIndexUnsharpDestination)]],
                       constant VEUnsharpUniforms &uniforms [[buffer(VEBufferIndexUnsharp)]],
                       uint2 gid [[thread_position_in_grid]]) {
    // The pre-scaled plane fills the top-left width x height of its pooled texture.
    const int width = int(uniforms.width);
    const int height = int(uniforms.height);
    if (int(gid.x) >= width || int(gid.y) >= height) {
        return;
    }
    const float weights[5] = {1.0, 4.0, 6.0, 4.0, 1.0};
    const bool luma = uniforms.isLuma != 0;
    float4 blur = float4(0.0);
    for (int j = -2; j <= 2; ++j) {
        const int y = clamp(int(gid.y) + j, 0, height - 1);
        float4 row = float4(0.0);
        for (int i = -2; i <= 2; ++i) {
            const int x = clamp(int(gid.x) + i, 0, width - 1);
            row += weights[i + 2] * source.read(uint2(uint(x), uint(y)));
        }
        blur += weights[j + 2] * row;
    }
    blur *= 1.0 / 256.0;
    const float4 c = source.read(gid);
    const float amount = uniforms.amount;
    const float t = uniforms.threshold;
    const float4 d = c - blur;
    const float4 sharpened = c + amount * d * smoothstep(float4(t), float4(2.0 * t), abs(d));
    if (luma) {
        const float lo = min(uniforms.rangeLow, c.r);
        const float hi = max(uniforms.rangeHigh, c.r);
        destination.write(float4(clamp(sharpened.r, lo, hi), 0.0, 0.0, 1.0), gid);
    } else {
        destination.write(float4(clamp(sharpened.rgb, float3(0.0), float3(c.a)), c.a), gid);
    }
}

// MARK: - Monitor output (RGBA16Float working texture -> texture target)

struct VEOutputVertexOut {
    float4 position [[position]];
};

// One triangle covering the whole target (vertices at (-1, -1), (3, -1) and (-1, 3) in clip space).
vertex VEOutputVertexOut ve_output_vertex(uint vertexID [[vertex_id]]) {
    const float2 p = float2((vertexID << 1) & 2, vertexID & 2);
    VEOutputVertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

// The working texture's pixel under each target pixel (both have the target's pixel grid: the working
// texture may be larger, the frame lies in its top-left corner), limited to [0, 1] as ve_convert_to_bgra
// limits the export's, and opaque (the composite is cleared to opaque black).
//
// With the clipping overlay (a monitor's, VEFunctionConstantClippingOverlay) a pixel of the frame (inside
// `frame`, so never a letterbox bar) with a channel at or above white (within kVEScopeClipTolerance) is shown
// red and one with a channel at or below black blue (red wins for a pixel that is both), as a photo app's
// clipping warning; the scopes' clipping counters count the same pixels. Never used by export.
constant bool kClippingOverlayValue [[function_constant(VEFunctionConstantClippingOverlay)]];
constant bool kClippingOverlay = is_function_constant_defined(kClippingOverlayValue) && kClippingOverlayValue;

fragment float4 ve_output_fragment(VEOutputVertexOut in [[stage_in]],
                                   texture2d<float, access::read> working [[texture(VETextureIndexWorking)]],
                                   constant float4 &frame [[buffer(VEBufferIndexOutputFrame),
                                                            function_constant(kClippingOverlay)]]) {
    const float4 c = working.read(uint2(in.position.xy));
    const float2 p = in.position.xy;
    if (kClippingOverlay && p.x >= frame.x && p.y >= frame.y && p.x < frame.z && p.y < frame.w) {
        if (max3(c.r, c.g, c.b) >= 1.0 - kVEScopeClipTolerance) {
            return float4(1.0, 0.0, 0.0, 1.0);
        }
        if (min3(c.r, c.g, c.b) <= kVEScopeClipTolerance) {
            return float4(0.0, 0.25, 1.0, 1.0);
        }
    }
    return float4(saturate(c.rgb), 1.0);
}

// MARK: - Scopes: clipping counters (ScopeStats.h)

// Counts a sample of the working picture in the frame's clipping counters (stats[0]: a channel at or above
// white, stats[1]: a channel at or below black, each within kVEScopeClipTolerance) when `active`. Summed over
// the SIMD group first, so a frame that is all white or all black costs one device atomic per group, not one
// per pixel. Called by every lane of the group (inactive lanes pass `active` false).
static inline void countClipping(device atomic_uint *stats, float3 rgb, bool active) {
    const bool white = active && max3(rgb.r, rgb.g, rgb.b) >= 1.0 - kVEScopeClipTolerance;
    const bool black = active && min3(rgb.r, rgb.g, rgb.b) <= kVEScopeClipTolerance;
    const uint whites = simd_sum(white ? 1u : 0u);
    const uint blacks = simd_sum(black ? 1u : 0u);
    if (simd_is_first()) {
        if (whites != 0) {
            atomic_fetch_add_explicit(&stats[0], whites, memory_order_relaxed);
        }
        if (blacks != 0) {
            atomic_fetch_add_explicit(&stats[1], blacks, memory_order_relaxed);
        }
    }
}

// MARK: - Luma waveform (LumaWaveform.h)

// One thread per sampled pixel: x across the frame's whole width, y one of `sampleRows` evenly spaced rows.
// The pixel's luma (BT.709 weights on the R'G'B' the monitor shows, limited to [0, 1]) is counted in its
// waveform column (x scaled to `columns`) at its level (rounded to `levels` steps).
// The sampled pixels are also counted in the frame's clipping counters (countClipping).
kernel void ve_waveform_accumulate(texture2d<float, access::read> working [[texture(VETextureIndexWorking)]],
                                   device atomic_uint *counts [[buffer(VEBufferIndexWaveformCounts)]],
                                   constant VEWaveformUniforms &u [[buffer(VEBufferIndexWaveform)]],
                                   device atomic_uint *stats [[buffer(VEBufferIndexScopeStats)]],
                                   uint2 gid [[thread_position_in_grid]]) {
    const uint width = uint(u.frame.z);
    const uint height = uint(u.frame.w);
    const bool active = gid.x < width && gid.y < u.sampleRows && height != 0;
    float3 sample = float3(0.5);
    if (active) {
        const uint row = min(height - 1, uint((float(gid.y) + 0.5) * float(height) / float(u.sampleRows)));
        sample = working.read(uint2(uint(u.frame.x) + gid.x, uint(u.frame.y) + row)).rgb;
        const float3 rgb = saturate(sample);
        const float luma = dot(float3(0.2126, 0.7152, 0.0722), rgb);
        const uint level = min(u.levels - 1, uint(rint(luma * float(u.levels - 1))));
        const uint column = min(u.columns - 1, gid.x * u.columns / width);
        atomic_fetch_add_explicit(&counts[level * u.columns + column], 1u, memory_order_relaxed);
    }
    countClipping(stats, sample, active);
}

// The waveform drawn over the whole target (ve_output_vertex's triangle): column across, level up (0 IRE at
// the bottom, 100 at the top), the trace's brightness 1 - exp(-count * gain) in green, over a graticule
// every 10 IRE (brighter at 0, 50 and 100).
fragment float4 ve_waveform_fragment(VEOutputVertexOut in [[stage_in]],
                                     device const uint *counts [[buffer(VEBufferIndexWaveformCounts)]],
                                     constant VEWaveformUniforms &u [[buffer(VEBufferIndexWaveform)]]) {
    const float2 size = max(u.target.xy, float2(1.0));
    const float2 p = in.position.xy;
    const uint column = min(u.columns - 1, uint(p.x / size.x * float(u.columns)));
    const float up = 1.0 - p.y / size.y; // 0 at the bottom edge, 1 at the top (at the pixel's centre)
    // The levels the pixel's row covers (several when the target has fewer rows than levels): the
    // brightest of them, so no level falls between rows.
    const float top = 1.0 - floor(p.y) / size.y;
    const float bottom = 1.0 - (floor(p.y) + 1.0) / size.y;
    const uint highest = min(u.levels - 1, uint(max(top, 0.0) * float(u.levels)));
    const uint lowest = min(highest, uint(max(bottom, 0.0) * float(u.levels)));
    uint count = 0;
    for (uint level = lowest; level <= highest; ++level) {
        count = max(count, counts[level * u.columns + column]);
    }
    const float trace = 1.0 - exp(-float(count) * u.gain);
    const float ire = up * 100.0;
    const float nearest = rint(ire / 10.0) * 10.0;
    const float pixelsAway = abs(ire - nearest) * size.y / 100.0;
    const bool major = nearest == 0.0 || nearest == 50.0 || nearest == 100.0;
    const float grid = pixelsAway < 0.75 ? (major ? 0.32 : 0.16) : 0.0;
    const float3 colour = max(float3(grid), float3(0.35, 1.0, 0.45) * trace);
    return float4(colour, 1.0);
}

// MARK: - Histogram (Histogram.h)

// The histogram bin of a value: rounded to kVEHistogramBins steps of [0, 1] (bin 0 is black, the last white).
static inline uint histogramBin(float v) {
    return min(kVEHistogramBins - 1, uint(rint(saturate(v) * float(kVEHistogramBins - 1))));
}

// Adds a thread's run of `count` samples at `bin` of channel row `row` to the group's histogram.
static inline void addHistogramRun(threadgroup atomic_uint *groupCounts, uint row, uint bin, uint count) {
    if (count != 0) {
        atomic_fetch_add_explicit(&groupCounts[row * kVEHistogramBins + bin], count, memory_order_relaxed);
    }
}

// One threadgroup per kVEHistogramTileSide-pixel square tile of the frame, kVEHistogramGroupSide^2 threads:
// each thread counts (tile side / group side)^2 pixels, strided so neighbouring threads read neighbouring
// pixels, into the group's own histogram in threadgroup memory; the group then adds its non-zero bins to the
// counts. Every pixel of the frame is counted (R, G, B and BT.709 luma of the R'G'B' the monitor shows,
// limited to [0, 1]) and in the clipping counters. A thread keeps a run per channel (its samples at one bin
// in a row) and adds the run when the bin changes; at the end, a SIMD group whose runs share a bin adds them
// as one sum. A flat picture (all of a group's samples on one counter) thus costs one threadgroup atomic per
// SIMD group and channel, not one per sample.
kernel void ve_histogram_accumulate(texture2d<float, access::read> working [[texture(VETextureIndexWorking)]],
                                    device atomic_uint *counts [[buffer(VEBufferIndexScopeCounts)]],
                                    constant VEHistogramUniforms &u [[buffer(VEBufferIndexScopeUniforms)]],
                                    device atomic_uint *stats [[buffer(VEBufferIndexScopeStats)]],
                                    uint2 tile [[threadgroup_position_in_grid]],
                                    uint2 local [[thread_position_in_threadgroup]],
                                    uint index [[thread_index_in_threadgroup]]) {
    threadgroup atomic_uint groupCounts[kVEHistogramMaximaOffset];
    constexpr uint threads = kVEHistogramGroupSide * kVEHistogramGroupSide;
    for (uint i = index; i < kVEHistogramMaximaOffset; i += threads) {
        atomic_store_explicit(&groupCounts[i], 0u, memory_order_relaxed);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    const uint width = uint(u.frame.z);
    const uint height = uint(u.frame.w);
    const uint2 origin = uint2(u.frame.xy);
    constexpr uint steps = kVEHistogramTileSide / kVEHistogramGroupSide;
    uint runBin[kVEHistogramChannels] = {0, 0, 0, 0};
    uint runCount[kVEHistogramChannels] = {0, 0, 0, 0};
    for (uint j = 0; j < steps; ++j) {
        for (uint i = 0; i < steps; ++i) {
            const uint x = tile.x * kVEHistogramTileSide + local.x + i * kVEHistogramGroupSide;
            const uint y = tile.y * kVEHistogramTileSide + local.y + j * kVEHistogramGroupSide;
            const bool active = x < width && y < height;
            float3 sample = float3(0.5);
            if (active) {
                sample = working.read(origin + uint2(x, y)).rgb;
                const float3 rgb = saturate(sample);
                const uint bins[kVEHistogramChannels] = {histogramBin(rgb.r), histogramBin(rgb.g), histogramBin(rgb.b),
                                                         histogramBin(dot(float3(0.2126, 0.7152, 0.0722), rgb))};
                for (uint c = 0; c < kVEHistogramChannels; ++c) {
                    if (runCount[c] != 0 && bins[c] != runBin[c]) {
                        addHistogramRun(groupCounts, c, runBin[c], runCount[c]);
                        runCount[c] = 0;
                    }
                    runBin[c] = bins[c];
                    runCount[c] += 1;
                }
            }
            countClipping(stats, sample, active);
        }
    }
    for (uint c = 0; c < kVEHistogramChannels; ++c) {
        // Lanes without samples (outside the frame) join any bin.
        const uint first = simd_broadcast_first(runBin[c]);
        if (simd_all(runCount[c] == 0 || runBin[c] == first)) {
            const uint sum = simd_sum(runCount[c]);
            if (simd_is_first()) {
                addHistogramRun(groupCounts, c, first, sum);
            }
        } else {
            addHistogramRun(groupCounts, c, runBin[c], runCount[c]);
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint i = index; i < kVEHistogramMaximaOffset; i += threads) {
        const uint n = atomic_load_explicit(&groupCounts[i], memory_order_relaxed);
        if (n != 0) {
            atomic_fetch_add_explicit(&counts[i], n, memory_order_relaxed);
        }
    }
}

// One threadgroup of kVEHistogramBins threads (thread b reads bin b of every channel): the tallest red,
// green or blue bar and the tallest luma bar, between the end bins and over every bin, into the counts' last
// four uints (kVEHistogramMaximaOffset). The display scales the bars by them.
kernel void ve_histogram_finish(device uint *counts [[buffer(VEBufferIndexScopeCounts)]],
                                uint bin [[thread_index_in_threadgroup]],
                                uint simdLane [[thread_index_in_simdgroup]],
                                uint simdGroup [[simdgroup_index_in_threadgroup]],
                                uint simdGroups [[simdgroups_per_threadgroup]]) {
    threadgroup uint partial[4][32];
    const uint rgb = max3(counts[bin], counts[kVEHistogramBins + bin], counts[2 * kVEHistogramBins + bin]);
    const uint luma = counts[3 * kVEHistogramBins + bin];
    const bool inner = bin > 0 && bin + 1 < kVEHistogramBins;
    const uint values[4] = {inner ? rgb : 0u, inner ? luma : 0u, rgb, luma};
    for (uint k = 0; k < 4; ++k) {
        const uint m = simd_max(values[k]);
        if (simdLane == 0) {
            partial[k][simdGroup] = m;
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (bin < 4) {
        uint m = 0;
        for (uint g = 0; g < simdGroups; ++g) {
            m = max(m, partial[bin][g]);
        }
        counts[kVEHistogramMaximaOffset + bin] = m;
    }
}

// A bar's height (0 ... 0.94 of the target, leaving room above the tallest) for `count` with the scale's
// reference count `reference` (the tallest bar between the end bins, or over every bin when those are empty);
// an end bin taller than the reference reaches the top.
static inline float histogramHeight(uint count, uint reference) {
    return reference == 0 ? 0.0 : min(1.0, float(count) / float(reference)) * 0.94;
}

// The histogram drawn over the whole target (ve_output_vertex's triangle): level across (black at the left,
// white at the right), samples up. Styles: 0, R, G and B filled and overlaid additively (overlaps show as
// their mixtures, all three as grey) with the luma bars' tops as a white line, on one scale; 1, the luma bars
// filled in light grey; 2, an RGB parade: the red, green and blue histograms side by side, on one scale.
// A faint graticule marks the quarters of the range.
fragment float4 ve_histogram_fragment(VEOutputVertexOut in [[stage_in]],
                                      device const uint *counts [[buffer(VEBufferIndexScopeCounts)]],
                                      constant VEHistogramUniforms &u [[buffer(VEBufferIndexScopeUniforms)]]) {
    const float2 size = max(u.target.xy, float2(1.0));
    const float2 p = in.position.xy;
    const bool parade = u.style == 2;
    const float sectionWidth = parade ? size.x / 3.0 : size.x;
    const uint section = parade ? min(2u, uint(p.x / sectionWidth)) : 0u;
    const float x = p.x - float(section) * sectionWidth; // within the section
    if (parade && section > 0 && x < 2.0) {
        return float4(0.22, 0.22, 0.22, 1.0); // the line between parade sections
    }
    const float across = x / sectionWidth;
    const uint bin = min(kVEHistogramBins - 1, uint(across * float(kVEHistogramBins)));
    const float up = 1.0 - p.y / size.y; // 0 at the bottom edge, 1 at the top
    const float pixel = 1.0 / size.y;
    const device uint *maxima = counts + kVEHistogramMaximaOffset;
    const uint referenceRGB = maxima[0] != 0 ? maxima[0] : maxima[2];
    const uint referenceLuma = maxima[1] != 0 ? maxima[1] : maxima[3];
    const uint referenceAll = max(referenceRGB, referenceLuma);
    float3 colour = float3(0.0);
    // The quarters of the range (25, 50, 75 %).
    const float quarter = across * 4.0;
    if (abs(quarter - rint(quarter)) * sectionWidth / 4.0 < 0.6 && rint(quarter) > 0.0 && rint(quarter) < 4.0) {
        colour = float3(0.14);
    }
    if (u.style == 1) {
        const float h = histogramHeight(counts[3 * kVEHistogramBins + bin], referenceLuma);
        if (up <= h) {
            colour = float3(0.78);
        }
    } else if (parade) {
        const float h = histogramHeight(counts[section * kVEHistogramBins + bin], referenceRGB);
        if (up <= h) {
            const float3 channels[3] = {float3(1.0, 0.25, 0.25), float3(0.3, 1.0, 0.35), float3(0.35, 0.5, 1.0)};
            colour = channels[section] * 0.85;
        }
    } else {
        const float r = histogramHeight(counts[bin], referenceAll);
        const float g = histogramHeight(counts[kVEHistogramBins + bin], referenceAll);
        const float b = histogramHeight(counts[2 * kVEHistogramBins + bin], referenceAll);
        const float3 fill = float3(up <= r ? 0.72 : 0.0, up <= g ? 0.72 : 0.0, up <= b ? 0.72 : 0.0);
        colour = max(colour, fill);
        // The luma bars' tops, a white line.
        const float l = histogramHeight(counts[3 * kVEHistogramBins + bin], referenceAll);
        if (l > 0.0 && abs(up - l) < 1.5 * pixel) {
            colour = float3(0.95);
        }
    }
    return float4(colour, 1.0);
}

// MARK: - Export conversion (RGBA16Float composite -> target pixel buffer planes)

kernel void ve_convert_to_bgra(texture2d<float, access::read> composite [[texture(VETextureIndexComposite)]],
                               texture2d<float, access::write> output [[texture(VETextureIndexOut0)]],
                               constant VEConvertUniforms &uniforms [[buffer(VEBufferIndexConvert)]],
                               uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= uniforms.width || gid.y >= uniforms.height) {
        return;
    }
    const float4 c = composite.read(gid);
    // The composite is opaque (cleared to opaque black); write it out as such.
    output.write(float4(saturate(c.rgb), 1.0), gid);
}

// A plane value for the target: 8-bit planes round in the unorm write; 10-bit planes ('x420')
// store the code in the high bits of a 16-bit word, so the value is rounded to a whole 10-bit
// code first (otherwise the low 6 bits, which CoreVideo defines as zero, would carry noise).
static inline float quantizePlane(float v, uint tenBit) {
    if (tenBit == 0) {
        return v;
    }
    const float code = clamp(rint(v * (65535.0 / 64.0)), 0.0, 1023.0);
    return code * (64.0 / 65535.0);
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
    const uint2 size = uint2(uniforms.width, uniforms.height);
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
        const uint tenBit = uniforms.tenBitCodes;
        luma.write(float4(quantizePlane(dot(uniforms.yRow.xyz, centre) + uniforms.yRow.w, tenBit)), uint2(x0, y));
        if (hasRight) {
            luma.write(float4(quantizePlane(dot(uniforms.yRow.xyz, right) + uniforms.yRow.w, tenBit)),
                       uint2(x0 + 1, y));
        }
        sum += 0.25 * left + 0.5 * centre + 0.25 * right;
        rows += 1.0;
    }
    const float3 filtered = sum / rows;
    const float cb = quantizePlane(dot(uniforms.cbRow.xyz, filtered) + uniforms.cbRow.w, uniforms.tenBitCodes);
    const float cr = quantizePlane(dot(uniforms.crRow.xyz, filtered) + uniforms.crRow.w, uniforms.tenBitCodes);
    chroma.write(float4(cb, cr, 0.0, 0.0), gid);
}
