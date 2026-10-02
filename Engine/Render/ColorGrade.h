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

// MARK: - Slice 2 (veGradeExtended)

// The address space of the uniforms the extended grade reads (constant memory on the GPU).
#ifdef __METAL_VERSION__
#define VE_GRADE_UNIFORMS constant VEGradeUniforms &
#else
#define VE_GRADE_UNIFORMS const VEGradeUniforms &
#endif

// The largest |v| the wheels' power sees: (2^40)^(2^1.5) is about 2^113, finite, and the contrast after it
// limits its own input to 2^60. The grade's linear values stay far below it (step 1's limit, the gains).
#define kVEGradePowerLimit 1.099511627776e12f /* 2^40 */

// v^exponent for v >= epsilon, and below epsilon (negative values included) the straight line through the
// origin that meets the curve at epsilon: v * slope with slope = epsilon^exponent / epsilon (computed on the
// CPU). The section 2 rule: pow (as exp2 and log2) only ever sees v >= epsilon; continuous, monotonic, 0
// maps to 0, finite for every input. An exponent of 1 returns v unchanged.
VE_GRADE_FUNC float vePower(float v, float exponent, float slope) {
    if (exponent == 1.0f) {
        return v;
    }
    v = v > kVEGradePowerLimit ? kVEGradePowerLimit : v < -kVEGradePowerLimit ? -kVEGradePowerLimit : v;
    const float safe = v >= kVEGradeEpsilon ? v : kVEGradeEpsilon;
    const float curve = VE_GRADE_EXP2(exponent * VE_GRADE_LOG2(safe));
    return v >= kVEGradeEpsilon ? curve : v * slope;
}

// The lift / gamma / gain wheels on one linear channel (ClipGrade.h, GradeWheel):
// out = (gain * (v + lift * (1 - v)))^(1 / gamma). Each part at its neutral value (lift 0, gain 1, exponent
// 1) returns its input bit for bit. Monotonic for every setting of the range (lift > -1, gain > 0).
VE_GRADE_FUNC float veWheelChannel(float v, float lift, float gain, float inverseGamma, float slope) {
    if (lift != 0.0f) {
        v = v + lift * (1.0f - v);
    }
    return vePower(v * gain, inverseGamma, slope);
}

VE_GRADE_FUNC VEGradeFloat3 veApplyWheels(VEGradeFloat3 rgb, VE_GRADE_UNIFORMS u) {
    const VEGradeFloat3 out = {veWheelChannel(rgb.x, u.lift.x, u.wheelGain.x, u.inverseGamma.x, u.gammaSlope.x),
                               veWheelChannel(rgb.y, u.lift.y, u.wheelGain.y, u.inverseGamma.y, u.gammaSlope.y),
                               veWheelChannel(rgb.z, u.lift.z, u.wheelGain.z, u.inverseGamma.z, u.gammaSlope.z)};
    return out;
}

// The grade's tables (ShaderTypes.h, VEGradeTableRow): a texture on the GPU, the same floats on the CPU
// (gradeTableData), and none (the identity) where no stage reads one. Read texel by texel, so both sides
// interpolate the same way.
#ifdef __METAL_VERSION__
typedef metal::texture2d<float, metal::access::read> VEGradeTables;
VE_GRADE_FUNC float veTableRead(VEGradeTables tables, uint x, uint row) {
    return tables.read(metal::uint2(x, row)).r;
}
#else
struct VEGradeTables {
    const float *values = nullptr; // VEGradeTableRowCount rows of kVEGradeTableWidth
};
VE_GRADE_FUNC float veTableRead(VEGradeTables tables, uint32_t x, uint32_t row) {
    return tables.values[row * kVEGradeTableWidth + x];
}
#endif
struct VENoGradeTables {};
VE_GRADE_FUNC float veTableRead(VENoGradeTables, VEGradeBits x, VEGradeBits) {
    return float(x) / float(kVEGradeTableWidth - 1u);
}

// Row `row` of the tables at `x` (limited to [0, 1], NaN as 0): the linear interpolation of the two samples
// around it.
template <typename Tables> VE_GRADE_FUNC float veTableLookup(Tables tables, float x, VEGradeBits row) {
    const float limited = x > 0.0f ? (x < 1.0f ? x : 1.0f) : 0.0f;
    const float position = limited * float(kVEGradeTableWidth - 1u);
    const VEGradeBits i0 = VEGradeBits(position);
    const VEGradeBits i1 = i0 + 1u < kVEGradeTableWidth ? i0 + 1u : kVEGradeTableWidth - 1u;
    const float f = position - float(i0);
    const float a = veTableRead(tables, i0, row);
    const float b = veTableRead(tables, i1, row);
    return a + (b - a) * f;
}

// The tone curves on encoded R'G'B' (ClipGrade.h, GradeCurve): the luma curve moves the BT.709 luma, adding
// the same amount to each channel; then each channel's curve. A curve whose bit of `mask` is clear is skipped.
template <typename Tables>
VE_GRADE_FUNC VEGradeFloat3 veApplyCurves(VEGradeFloat3 rgb, VEGradeBits mask, Tables tables) {
    if ((mask & (1u << VEGradeTableRowLuma)) != 0u) {
        const VEGradeFloat3 weights = {0.2126f, 0.7152f, 0.0722f};
        const float luma = VE_GRADE_DOT(weights, rgb);
        const float moved = veTableLookup(tables, luma, VEGradeTableRowLuma) - luma;
        rgb = rgb + moved;
    }
    if ((mask & (1u << VEGradeTableRowRed)) != 0u) {
        rgb.x = veTableLookup(tables, rgb.x, VEGradeTableRowRed);
    }
    if ((mask & (1u << VEGradeTableRowGreen)) != 0u) {
        rgb.y = veTableLookup(tables, rgb.y, VEGradeTableRowGreen);
    }
    if ((mask & (1u << VEGradeTableRowBlue)) != 0u) {
        rgb.z = veTableLookup(tables, rgb.z, VEGradeTableRowBlue);
    }
    return rgb;
}

// The grade with the slice 2 stages (the source's extended-grade function constant): steps 1-4 of veGrade
// with the wheels (VEGradeStageWheels) in linear light after saturation and before contrast, then the tone
// curves (VEGradeStageCurves) on the re-encoded values. A stage whose bit is clear is skipped, so with no
// bit set this is veGrade, value for value.
template <typename Tables> VE_GRADE_FUNC VEGradeFloat3 veGradeExtended(VEGradeFloat3 rgb, VE_GRADE_UNIFORMS u, Tables tables) {
    const int transfer = u.transfer;
    const VEGradeFloat3 linear = {veLinearChannel(rgb.x, transfer), veLinearChannel(rgb.y, transfer),
                                  veLinearChannel(rgb.z, transfer)};
    const VEGradeFloat3 gain = {u.gain.x, u.gain.y, u.gain.z};
    VEGradeFloat3 graded = veApplySaturation(veGain(linear, gain), u.saturation);
    if ((u.stages & VEGradeStageWheels) != 0u) {
        graded = veApplyWheels(graded, u);
    }
    VEGradeFloat3 out = {veEncode(veContrast(graded.x, u.contrast, u.contrastSlope), transfer),
                         veEncode(veContrast(graded.y, u.contrast, u.contrastSlope), transfer),
                         veEncode(veContrast(graded.z, u.contrast, u.contrastSlope), transfer)};
    if ((u.stages & VEGradeStageCurves) != 0u) {
        out = veApplyCurves(out, u.curveMask, tables);
    }
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

// A wheel's colour (cb, cr) as a zero-luminance direction in R, G, B (ClipGrade.h, GradeWheel): BT.709
// chroma converted with Y' = 0, divided by the blue axis's length 2 (1 - Kb) = 1.8556.
inline simd_double3 wheelColourDirection(double cb, double cr) {
    constexpr double kr = 0.2126, kb = 0.0722, kg = 1.0 - kr - kb;
    const double r = 2.0 * (1.0 - kr) * cr;
    const double g = -2.0 * kb * (1.0 - kb) / kg * cb - 2.0 * kr * (1.0 - kr) / kg * cr;
    const double b = 2.0 * (1.0 - kb) * cb;
    return simd_make_double3(r, g, b) / (2.0 * (1.0 - kb));
}

// Whether a grade needs the extended grade (a slice 2 stage is in use).
inline bool needsExtendedGrade(const GradeWheels &wheels, const GradeCurves &curves = {}) {
    return !isNeutralWheels(wheels) || !isIdentityCurves(curves);
}

// The tables of `curves` (VEGradeTableRow rows of kVEGradeTableWidth samples; an identity curve's row is the
// identity), what the compositor uploads and the CPU reference reads.
inline std::vector<float> gradeTableData(const GradeCurves &curves) {
    std::vector<float> data(std::size_t(VEGradeTableRowCount) * kVEGradeTableWidth);
    const GradeCurve rows[VEGradeTableRowCount] = {GradeCurve::Luma, GradeCurve::Red, GradeCurve::Green, GradeCurve::Blue};
    for (int row = 0; row < VEGradeTableRowCount; ++row) {
        const std::vector<float> samples = sampleCurve(curves[static_cast<std::size_t>(rows[row])], kVEGradeTableWidth);
        std::copy(samples.begin(), samples.end(), data.begin() + std::ptrdiff_t(row) * kVEGradeTableWidth);
    }
    return data;
}

// The uniforms of a grade with its slice 2 stages: gradeUniformsFor's, then per wheel and channel c (w the
// wheel's colour direction): lift 0.1 (level + 0.5 w_c), gain 2^(level + 0.5 w_c), gamma 2^(level + 0.5
// w_c) as the exponent 1 / gamma with its linear segment's slope epsilon^(1 / gamma) / epsilon; exactly 0, 1,
// 1 and 1 for a neutral wheel, whose stage bit stays clear when every wheel is neutral.
inline VEGradeUniforms gradeUniformsFor(const GradeValues &grade, const GradeWheels &wheels, VEInt transfer) {
    VEGradeUniforms u = gradeUniformsFor(grade, transfer);
    u.lift = simd_make_float4(0.0f, 0.0f, 0.0f, 0.0f);
    u.wheelGain = simd_make_float4(1.0f, 1.0f, 1.0f, 0.0f);
    u.inverseGamma = simd_make_float4(1.0f, 1.0f, 1.0f, 0.0f);
    u.gammaSlope = simd_make_float4(1.0f, 1.0f, 1.0f, 0.0f);
    u.stages = 0u;
    u.curveMask = 0u;
    if (isNeutralWheels(wheels)) {
        return u;
    }
    u.stages |= VEGradeStageWheels;
    const WheelValue &lift = wheels[static_cast<std::size_t>(GradeWheel::Lift)];
    const WheelValue &gamma = wheels[static_cast<std::size_t>(GradeWheel::Gamma)];
    const WheelValue &gain = wheels[static_cast<std::size_t>(GradeWheel::Gain)];
    const simd_double3 liftColour = wheelColourDirection(lift.cb, lift.cr);
    const simd_double3 gammaColour = wheelColourDirection(gamma.cb, gamma.cr);
    const simd_double3 gainColour = wheelColourDirection(gain.cb, gain.cr);
    const double epsilon = double(kVEGradeEpsilon);
    for (int c = 0; c < 3; ++c) {
        const double liftValue = lift.isNeutral() ? 0.0 : 0.1 * (lift.level + 0.5 * liftColour[c]);
        const double gainValue = gain.isNeutral() ? 1.0 : std::exp2(gain.level + 0.5 * gainColour[c]);
        const double inverse = gamma.isNeutral() ? 1.0 : 1.0 / std::exp2(gamma.level + 0.5 * gammaColour[c]);
        const float inverseFloat = float(inverse);
        u.lift[c] = float(liftValue);
        u.wheelGain[c] = float(gainValue);
        u.inverseGamma[c] = inverseFloat;
        u.gammaSlope[c] = inverseFloat == 1.0f ? 1.0f : float(std::pow(epsilon, double(inverseFloat)) / epsilon);
    }
    return u;
}

// The uniforms of a grade with its wheels and curves: the wheels' (above), and the curves' stage bit and mask
// when a curve is not the identity.
inline VEGradeUniforms gradeUniformsFor(const GradeValues &grade, const GradeWheels &wheels, const GradeCurves &curves,
                                        VEInt transfer) {
    VEGradeUniforms u = gradeUniformsFor(grade, wheels, transfer);
    const GradeCurve rows[VEGradeTableRowCount] = {GradeCurve::Luma, GradeCurve::Red, GradeCurve::Green, GradeCurve::Blue};
    for (int row = 0; row < VEGradeTableRowCount; ++row) {
        if (!isIdentityCurve(curves[static_cast<std::size_t>(rows[row])])) {
            u.curveMask |= 1u << row;
        }
    }
    if (u.curveMask != 0u) {
        u.stages |= VEGradeStageCurves;
    }
    return u;
}

// The CPU reference of the shader's grade with `u`'s values (unclamped; the shader then clamps to [0, 1]):
// the extended grade when a slice 2 stage is set (with `tables`, gradeTableData's floats, when a stage reads
// them), else the slice 1 grade.
inline simd_float3 gradeReference(simd_float3 rgb, const VEGradeUniforms &u, const float *tables = nullptr) {
    if (u.stages != 0u) {
        if (tables != nullptr) {
            return veGradeExtended(rgb, u, VEGradeTables{tables});
        }
        return veGradeExtended(rgb, u, VENoGradeTables{});
    }
    return veGrade(rgb, u.gain.x, u.gain.y, u.gain.z, u.saturation, u.contrast, u.contrastSlope, u.transfer);
}

} // namespace ve::render

#endif
