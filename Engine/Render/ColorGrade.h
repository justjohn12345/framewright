// A source picture's colour grade (ClipGrade.h), per pixel: one header compiled by Shaders.metal (the
// fragment shader grades each graded source with it) and by C++ (the CPU reference the tests hold the
// GPU to, and the uniforms the compositor uploads). The placement and the arithmetic follow
// docs/reviews/2026-10-01-grading-pipeline-decision.md (sections 1-3 and 6):
//
//   1. The source's R'G'B' after its conversion (unclamped: a graded source skips the conversion's clamp),
//      made safe: NaN -> 0, +-inf -> +-float max (veSanitize), then limited to +-kVEGradeEncodedLimit (256:
//      an R'G'B' beyond 256 times white is not a picture, and the limit keeps every later step finite;
//      256^2.4 is about 6e5 in linear light). A value within kVEGradeBlackResidue (2^-20) of 0 is 0: the
//      YCbCr matrix leaves a float residue of 2e-8 to 5e-8 at video black (measured), which exposure +5
//      would lift toward 1e-6; 2^-20 is a sixteenth of a 16-bit code, so no picture value is lost, and a
//      graded black frame stays exactly black.
//   2. Linearised by the source's transfer (VEGradeTransfer): BT.1886's pure 2.4 power for BT.709, BT.601,
//      SMPTE 240M and untagged video, the sRGB curve for sRGB-tagged sources and stills, identity for
//      linear; each mirrored for negative values (sign(v) * curve(|v|)), so sub-blacks stay ordered and
//      nothing is NaN.
//   3. In linear light: the channel gains (exposure 2^stops times the temperature/tint gains, normalised on
//      the CPU to keep BT.709 luminance with the divisor kept away from 0: VEGradeUniforms::gain), then
//      saturation (a mix toward BT.709 linear luminance), then contrast about linear 0.18 by the section 2
//      rule (veContrast): f(v) = pivot * (v / pivot)^c for v >= epsilon (2^-14), written as
//      pivot * exp2(c * (log2 v - log2 pivot)) with log2 only ever seeing v >= epsilon; below epsilon the
//      straight line through the origin that meets the curve at epsilon, f(v) = v * f(epsilon) / epsilon,
//      which negative values continue (sign kept); contrast 1 returns v unchanged.
//   4. Re-encoded with the inverse of step 2's curve (mirrored). The caller then clamps to [0, 1] (the clamp
//      moved from the conversion to the end of the grade).
//
// Each step at its neutral value (gain 1, saturation 1, contrast 1) returns its input bit for bit; a grade
// whose every value is neutral is never run (the compositor picks the ungraded pipeline). Every value the
// grade outputs is finite for every input, NaN and infinities included.
//
// Metal compiles with fast math: NaN and infinity are recognised by their bits (veSanitize), and every pow and
// log2 sees a positive argument. The curves use metal::fast: against the CPU reference (libm) the largest
// difference over 2.7 million values of 30 grades is 8e-6, the same as with metal::precise, at a quarter of
// the GPU time (ColorGradeRenderTests, GRADE GPU vs CPU and GRADE COST).

#pragma once

#include "ShaderTypes.h"

#ifdef __METAL_VERSION__

#define VE_GRADE_FUNC static inline
typedef metal::float3 VEGradeFloat3;
#define VE_GRADE_POW(x, y) metal::fast::pow(x, y)
#define VE_GRADE_EXP2(x) metal::fast::exp2(x)
#define VE_GRADE_LOG2(x) metal::fast::log2(x)
#define VE_GRADE_ABS(x) metal::abs(x)
#define VE_GRADE_COPYSIGN(x, s) metal::copysign(x, s)
#define VE_GRADE_FLOAT_BITS(x) as_type<uint>(x)
#define VE_GRADE_BITS_FLOAT(x) as_type<float>(x)
#define VE_GRADE_DOT(a, b) metal::dot(a, b)
typedef uint VEGradeBits;

#else

#include <simd/simd.h>

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>

#define VE_GRADE_FUNC inline
typedef simd_float3 VEGradeFloat3;
#define VE_GRADE_POW(x, y) std::pow(float(x), float(y))
#define VE_GRADE_EXP2(x) std::exp2(float(x))
#define VE_GRADE_LOG2(x) std::log2(float(x))
#define VE_GRADE_ABS(x) std::fabs(float(x))
#define VE_GRADE_COPYSIGN(x, s) std::copysign(float(x), float(s))
#define VE_GRADE_FLOAT_BITS(x) std::bit_cast<uint32_t>(float(x))
#define VE_GRADE_BITS_FLOAT(x) std::bit_cast<float>(uint32_t(x))
#define VE_GRADE_DOT(a, b) simd_dot(a, b)
typedef uint32_t VEGradeBits;

#endif

// The contrast pivot (linear 18 % grey), the threshold of the curve's linear segment, the limit of an
// encoded value (step 1), the residue taken as black (step 1) and the limit of the contrast curve's input.
#define kVEGradePivot 0.18f
#define kVEGradeEpsilon 6.103515625e-05f /* 2^-14 */
#define kVEGradeEncodedLimit 256.0f
#define kVEGradeBlackResidue 9.5367431640625e-07f /* 2^-20 */
#define kVEGradeContrastLimit 1.152921504606846976e18f /* 2^60 */

// v with NaN as 0 and an infinity as the largest finite float of its sign, decided on the bits (fast math
// may assume neither occurs).
VE_GRADE_FUNC float veSanitize(float v) {
    const VEGradeBits bits = VE_GRADE_FLOAT_BITS(v);
    if ((bits & 0x7f800000u) != 0x7f800000u) {
        return v;
    }
    if ((bits & 0x007fffffu) != 0u) {
        return 0.0f; // NaN
    }
    return VE_GRADE_BITS_FLOAT((bits & 0x80000000u) | 0x7f7fffffu); // +-float max
}

// The transfer curve (step 2) of |v|, mirrored for negative values.
VE_GRADE_FUNC float veLinearise(float v, int transfer) {
    const float a = VE_GRADE_ABS(v);
    float linear;
    if (transfer == VEGradeTransferLinear) {
        return v;
    } else if (transfer == VEGradeTransferSRGB) {
        linear = a <= 0.04045f ? a * (1.0f / 12.92f) : VE_GRADE_POW((a + 0.055f) * (1.0f / 1.055f), 2.4f);
    } else {
        linear = a > 0.0f ? VE_GRADE_POW(a, 2.4f) : 0.0f;
    }
    return VE_GRADE_COPYSIGN(linear, v);
}

// The inverse of veLinearise.
VE_GRADE_FUNC float veEncode(float v, int transfer) {
    const float a = VE_GRADE_ABS(v);
    float encoded;
    if (transfer == VEGradeTransferLinear) {
        return v;
    } else if (transfer == VEGradeTransferSRGB) {
        encoded = a <= 0.0031308f ? a * 12.92f : 1.055f * VE_GRADE_POW(a, 1.0f / 2.4f) - 0.055f;
    } else {
        encoded = a > 0.0f ? VE_GRADE_POW(a, 1.0f / 2.4f) : 0.0f;
    }
    return VE_GRADE_COPYSIGN(encoded, v);
}

// The contrast curve of section 2 (see the header). `slope` is f(epsilon) / epsilon (VEGradeUniforms::
// contrastSlope, computed on the CPU in double precision), the linear segment's slope.
VE_GRADE_FUNC float veContrast(float v, float contrast, float slope) {
    if (contrast == 1.0f) {
        return v;
    }
    // Limited to +-2^60 so the curve is finite on its own at every contrast of the range (0.18 (2^60 /
    // 0.18)^2 and 2^60 times the steepest slope are far below float max); the grade's linear values never
    // come near it (step 1's limit keeps them below 2^28).
    v = v > kVEGradeContrastLimit ? kVEGradeContrastLimit : v < -kVEGradeContrastLimit ? -kVEGradeContrastLimit : v;
    const float safe = v >= kVEGradeEpsilon ? v : kVEGradeEpsilon; // log2 never sees less than epsilon
    const float curve = kVEGradePivot * VE_GRADE_EXP2(contrast * (VE_GRADE_LOG2(safe) - VE_GRADE_LOG2(kVEGradePivot)));
    return v >= kVEGradeEpsilon ? curve : v * slope;
}

// Saturation in linear light: a mix toward BT.709 luminance (1 changes nothing, 0 gives grey).
VE_GRADE_FUNC VEGradeFloat3 veApplySaturation(VEGradeFloat3 rgb, float saturation) {
    if (saturation == 1.0f) {
        return rgb;
    }
    const VEGradeFloat3 weights = {0.2126f, 0.7152f, 0.0722f};
    const float luminance = VE_GRADE_DOT(weights, rgb);
    return luminance + saturation * (rgb - luminance);
}

// The channel gains (exposure, temperature, tint); a gain of 1 changes nothing.
VE_GRADE_FUNC VEGradeFloat3 veGain(VEGradeFloat3 rgb, VEGradeFloat3 gain) {
    return rgb * gain;
}

// Steps 1 and 2 for one channel: made safe, limited, black residue taken as black, linearised.
VE_GRADE_FUNC float veLinearChannel(float v, int transfer) {
    v = veSanitize(v);
    v = v > kVEGradeEncodedLimit ? kVEGradeEncodedLimit : v < -kVEGradeEncodedLimit ? -kVEGradeEncodedLimit : v;
    if (VE_GRADE_ABS(v) < kVEGradeBlackResidue) {
        v = 0.0f;
    }
    return veLinearise(v, transfer);
}

// The whole grade of one R'G'B' value (steps 1-4), unclamped.
VE_GRADE_FUNC VEGradeFloat3 veGrade(VEGradeFloat3 rgb, float gainR, float gainG, float gainB, float saturation,
                                    float contrast, float slope, int transfer) {
    const VEGradeFloat3 linear = {veLinearChannel(rgb.x, transfer), veLinearChannel(rgb.y, transfer),
                                  veLinearChannel(rgb.z, transfer)};
    const VEGradeFloat3 gain = {gainR, gainG, gainB};
    const VEGradeFloat3 graded = veApplySaturation(veGain(linear, gain), saturation);
    const VEGradeFloat3 out = {veEncode(veContrast(graded.x, contrast, slope), transfer),
                               veEncode(veContrast(graded.y, contrast, slope), transfer),
                               veEncode(veContrast(graded.z, contrast, slope), transfer)};
    return out;
}

#ifndef __METAL_VERSION__

#include "../Model/ClipGrade.h"
#include "../Media/MediaTypes.h"

namespace ve::render {

// The transfer a source is linearised by (decision section 6): sRGB for an sRGB-tagged source (every
// decoded still is) and an untagged still, identity for linear, BT.1886 (2.4) for everything else (BT.709,
// SMPTE 240M and untagged video; PQ and HLG are shown as SDR, as everywhere else).
inline VEInt gradeTransferFor(media::TransferFunction tag, bool isStill) {
    switch (tag) {
    case media::TransferFunction::SRGB:
        return VEGradeTransferSRGB;
    case media::TransferFunction::Linear:
        return VEGradeTransferLinear;
    case media::TransferFunction::Unknown:
        return isStill ? VEGradeTransferSRGB : VEGradeTransferBT1886;
    case media::TransferFunction::BT709:
    case media::TransferFunction::PQ:
    case media::TransferFunction::HLG:
    case media::TransferFunction::SMPTE240M:
        return VEGradeTransferBT1886;
    }
    return VEGradeTransferBT1886;
}

// The uniforms of a grade (computed in double precision): the channel gains 2^exposure times the
// white-balance gains (temperature t and tint m over 100: red 2^(t/2), green 2^(-m/2), blue 2^(-t/2)),
// divided by their BT.709 luminance (kept at least 1e-6) so a white-balance change keeps luminance;
// exactly 1 for neutral values. The contrast and its segment's slope f(epsilon) / epsilon.
inline VEGradeUniforms gradeUniformsFor(const GradeValues &grade, VEInt transfer) {
    const double exposure = std::exp2(grade[static_cast<std::size_t>(GradeParameter::Exposure)]);
    const double t = grade[static_cast<std::size_t>(GradeParameter::Temperature)] / 100.0;
    const double m = grade[static_cast<std::size_t>(GradeParameter::Tint)] / 100.0;
    double r = 1.0, g = 1.0, b = 1.0;
    if (t != 0.0 || m != 0.0) {
        r = std::exp2(0.5 * t);
        g = std::exp2(-0.5 * m);
        b = std::exp2(-0.5 * t);
        const double luminance = std::max(0.2126 * r + 0.7152 * g + 0.0722 * b, 1e-6);
        r /= luminance;
        g /= luminance;
        b /= luminance;
    }
    const double contrast = grade[static_cast<std::size_t>(GradeParameter::Contrast)];
    const double epsilon = double(kVEGradeEpsilon);
    const double pivot = double(kVEGradePivot);
    VEGradeUniforms u{};
    u.gain = simd_make_float4(float(exposure * r), float(exposure * g), float(exposure * b), 0.0f);
    u.saturation = float(grade[static_cast<std::size_t>(GradeParameter::Saturation)]);
    u.contrast = float(contrast);
    u.contrastSlope = contrast == 1.0 ? 1.0f : float(pivot * std::pow(epsilon / pivot, contrast) / epsilon);
    u.transfer = transfer;
    return u;
}

// The CPU reference of the shader's grade with `u`'s values (unclamped; the shader then clamps to [0, 1]).
inline simd_float3 gradeReference(simd_float3 rgb, const VEGradeUniforms &u) {
    return veGrade(rgb, u.gain.x, u.gain.y, u.gain.z, u.saturation, u.contrast, u.contrastSlope, u.transfer);
}

} // namespace ve::render

#endif
