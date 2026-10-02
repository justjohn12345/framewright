// The grade function of ColorGrade.h on the CPU (the same code the fragment shader compiles): the
// section 2 rule of docs/reviews/2026-10-01-grading-pipeline-decision.md over 0, -0, +-epsilon,
// +-epsilon/2, denormals, negatives to -1, 1, large values, NaN and +-inf at contrast 0.5, 1 and 2 (and the
// range's ends): every output finite, monotonic and continuous across epsilon, contrast 1 the identity;
// every control's neutral value the identity; black stays black; what each control does in linear light;
// the uniforms the compositor uploads.

#include "../../Engine/Render/ColorGrade.h"

#include <doctest.h>

#include <algorithm>
#include <bit>
#include <cmath>
#include <limits>
#include <vector>

using namespace ve;
using namespace ve::render;

namespace {

constexpr float kEps = kVEGradeEpsilon;
constexpr float kInf = std::numeric_limits<float>::infinity();
constexpr float kMax = std::numeric_limits<float>::max();
constexpr float kDenorm = std::numeric_limits<float>::denorm_min();
const float kNaN = std::numeric_limits<float>::quiet_NaN();

// The inputs the decision names.
std::vector<float> specialInputs() {
    return {0.0f,    -0.0f,  kEps,  -kEps, kEps / 2, -kEps / 2, kDenorm, -kDenorm, 1e-40f, -1e-40f,
            -1e-3f,  -0.1f,  -0.5f, -1.0f, 1.0f,     0.18f,     0.5f,    2.0f,     1e3f,   1e6f,
            1e30f,   kMax,   -kMax, kNaN,  kInf,     -kInf,     1.0e-4f, -1e-6f};
}

// Contrast values: the decision's three and the range's ends.
const float kContrasts[] = {0.5f, 1.0f, 2.0f, 0.0f, 1.3f};

// The slope of the linear segment for `contrast`, as gradeUniformsFor computes it.
float slopeFor(float contrast) {
    GradeValues values = ClipGrade::neutralValues();
    values[static_cast<std::size_t>(GradeParameter::Contrast)] = contrast;
    return gradeUniformsFor(values, VEGradeTransferBT1886).contrastSlope;
}

bool sameBits(float a, float b) {
    return std::bit_cast<uint32_t>(a) == std::bit_cast<uint32_t>(b);
}

VEGradeUniforms uniformsFor(std::initializer_list<std::pair<GradeParameter, double>> values,
                            VEInt transfer = VEGradeTransferBT1886) {
    GradeValues grade = ClipGrade::neutralValues();
    for (const auto &[parameter, value] : values) {
        grade[static_cast<std::size_t>(parameter)] = value;
    }
    return gradeUniformsFor(grade, transfer);
}

simd_float3 grey(float v) {
    return simd_make_float3(v, v, v);
}

} // namespace

TEST_CASE("Grade: NaN becomes 0 and an infinity the largest float of its sign, before the grade") {
    CHECK(veSanitize(kNaN) == 0.0f);
    CHECK(veSanitize(-kNaN) == 0.0f);
    CHECK(veSanitize(kInf) == kMax);
    CHECK(veSanitize(-kInf) == -kMax);
    for (const float v : {0.0f, -0.0f, 1.0f, -1.0f, kDenorm, kMax, -kMax, kEps}) {
        CHECK(sameBits(veSanitize(v), v));
    }
}

TEST_CASE("Grade: the contrast curve is finite, monotonic, continuous across epsilon, and 1 is the identity") {
    for (const float c : kContrasts) {
        CAPTURE(c);
        const float slope = slopeFor(c);
        // Every special input (made safe first, as the grade does) gives a finite value; the sign is kept.
        for (const float raw : specialInputs()) {
            CAPTURE(raw);
            const float v = veSanitize(raw);
            const float f = veContrast(v, c, slope);
            CHECK(std::isfinite(f));
            if (v > 0.0f) {
                CHECK(f >= 0.0f);
            }
            if (v < 0.0f) {
                CHECK(f <= 0.0f);
            }
            if (c == 1.0f) {
                CHECK(sameBits(f, v)); // bit for bit, -0 and denormals included
            }
        }
        // Zero stays zero (black stays black).
        CHECK(veContrast(0.0f, c, slope) == 0.0f);
        // Monotonic over a dense grid from -1 through the linear segment and across epsilon to large values.
        std::vector<float> grid;
        for (int i = -1000; i <= 1000; ++i) {
            grid.push_back(float(i) / 1000.0f); // -1 ... 1
        }
        for (int i = 0; i <= 400; ++i) {
            const float t = std::exp2(-20.0f + float(i) * 0.1f); // 2^-20 ... 2^20, across epsilon
            grid.push_back(t);
            grid.push_back(-t);
        }
        for (float v = kEps / 4; v < kEps * 4; v = std::nextafter(v, kInf) + kEps / 512) {
            grid.push_back(v);
        }
        grid.push_back(std::nextafter(kEps, 0.0f));
        grid.push_back(kEps);
        grid.push_back(std::nextafter(kEps, kInf));
        std::sort(grid.begin(), grid.end());
        float previous = -kInf;
        for (const float v : grid) {
            const float f = veContrast(v, c, slope);
            CHECK_MESSAGE(f >= previous, "not monotonic at " << v);
            previous = f;
        }
        // Continuous at epsilon: the line meets the curve (relative difference of float rounding only).
        const float below = veContrast(std::nextafter(kEps, 0.0f), c, slope);
        const float at = veContrast(kEps, c, slope);
        CHECK(at > 0.0f);
        CHECK(std::fabs(at - below) <= 1e-5f * at);
        // Below epsilon the straight line through the origin; negatives continue it, sign kept.
        CHECK(veContrast(kEps / 2, c, slope) == doctest::Approx(at / 2).epsilon(1e-5));
        CHECK(veContrast(-kEps / 2, c, slope) == doctest::Approx(-at / 2).epsilon(1e-5));
        CHECK(veContrast(-1.0f, c, slope) == doctest::Approx(-slope).epsilon(1e-6));
        // The pivot is fixed.
        CHECK(veContrast(kVEGradePivot, c, slope) == doctest::Approx(kVEGradePivot).epsilon(1e-6));
    }
    // Contrast 2 squares the ratio to the pivot; 0.5 takes its square root.
    CHECK(veContrast(0.36f, 2.0f, slopeFor(2.0f)) == doctest::Approx(0.72).epsilon(1e-5));
    CHECK(veContrast(0.72f, 0.5f, slopeFor(0.5f)) == doctest::Approx(0.36).epsilon(1e-5));
}

TEST_CASE("Grade: every output is finite for every input, grade and transfer") {
    const VEGradeUniforms grades[] = {
        uniformsFor({}),
        uniformsFor({{GradeParameter::Exposure, 5.0}}),
        uniformsFor({{GradeParameter::Exposure, -5.0}}),
        uniformsFor({{GradeParameter::Contrast, 2.0}, {GradeParameter::Saturation, 2.0}}),
        uniformsFor({{GradeParameter::Contrast, 0.0}}),
        uniformsFor({{GradeParameter::Contrast, 0.5}, {GradeParameter::Temperature, 100.0}, {GradeParameter::Tint, -100.0}}),
        uniformsFor({{GradeParameter::Exposure, 5.0}, {GradeParameter::Contrast, 2.0}, {GradeParameter::Temperature, -100.0},
                     {GradeParameter::Tint, 100.0}, {GradeParameter::Saturation, 2.0}}),
        uniformsFor({{GradeParameter::Saturation, 0.0}}),
    };
    const std::vector<float> inputs = specialInputs();
    for (const VEInt transfer : {VEGradeTransferBT1886, VEGradeTransferSRGB, VEGradeTransferLinear}) {
        for (VEGradeUniforms grade : grades) {
            grade.transfer = transfer;
            for (const float r : inputs) {
                for (const float g : {0.5f, kNaN, -kInf, -0.25f}) {
                    for (const float b : inputs) {
                        const simd_float3 out = gradeReference(simd_make_float3(r, g, b), grade);
                        CHECK_MESSAGE((std::isfinite(out.x) && std::isfinite(out.y) && std::isfinite(out.z)),
                                      "input " << r << " " << g << " " << b << " transfer " << transfer << " gave "
                                               << out.x << " " << out.y << " " << out.z);
                    }
                }
            }
        }
    }
}

TEST_CASE("Grade: black stays exactly black under every grade") {
    for (const VEInt transfer : {VEGradeTransferBT1886, VEGradeTransferSRGB, VEGradeTransferLinear}) {
        for (const double exposure : {-5.0, 0.0, 5.0}) {
            for (const double contrast : {0.0, 0.5, 1.0, 2.0}) {
                for (const double temperature : {-100.0, 0.0, 100.0}) {
                    for (const double saturation : {0.0, 1.0, 2.0}) {
                        const VEGradeUniforms u = uniformsFor({{GradeParameter::Exposure, exposure},
                                                               {GradeParameter::Contrast, contrast},
                                                               {GradeParameter::Temperature, temperature},
                                                               {GradeParameter::Tint, -temperature / 2},
                                                               {GradeParameter::Saturation, saturation}},
                                                              transfer);
                        const simd_float3 out = gradeReference(grey(0.0f), u);
                        CHECK(out.x == 0.0f);
                        CHECK(out.y == 0.0f);
                        CHECK(out.z == 0.0f);
                    }
                }
            }
        }
    }
}

TEST_CASE("Grade: each control's neutral value is the identity") {
    const std::vector<float> inputs = specialInputs();
    // The uniforms of the neutral grade: gains exactly 1, saturation and contrast exactly 1.
    const VEGradeUniforms neutral = uniformsFor({});
    CHECK(neutral.gain.x == 1.0f);
    CHECK(neutral.gain.y == 1.0f);
    CHECK(neutral.gain.z == 1.0f);
    CHECK(neutral.saturation == 1.0f);
    CHECK(neutral.contrast == 1.0f);
    CHECK(neutral.contrastSlope == 1.0f);
    // Temperature and tint at 0 alone leave the gains exactly 1 whatever the exposure; exposure 0 alone
    // leaves the white balance's gains as they are.
    const VEGradeUniforms exposed = uniformsFor({{GradeParameter::Exposure, 2.0}});
    CHECK(exposed.gain.x == 4.0f);
    CHECK(exposed.gain.y == 4.0f);
    CHECK(exposed.gain.z == 4.0f);
    // Each step at its neutral value returns its input bit for bit.
    for (const float a : inputs) {
        for (const float b : {0.25f, -0.0f, kEps / 3}) {
            const simd_float3 rgb = simd_make_float3(veSanitize(a), b, veSanitize(-a));
            const simd_float3 gained = veGain(rgb, simd_make_float3(1.0f, 1.0f, 1.0f));
            const simd_float3 saturated = veApplySaturation(rgb, 1.0f);
            for (int i = 0; i < 3; ++i) {
                CHECK(sameBits(gained[i], rgb[i]));
                CHECK(sameBits(saturated[i], rgb[i]));
                CHECK(sameBits(veContrast(rgb[i], 1.0f, 1.0f), rgb[i]));
            }
        }
    }
    // The whole grade at neutral values is the transfer curve there and back: the input within float
    // rounding (far below one 10-bit code) over [0, 1].
    for (const VEInt transfer : {VEGradeTransferBT1886, VEGradeTransferSRGB, VEGradeTransferLinear}) {
        VEGradeUniforms u = neutral;
        u.transfer = transfer;
        for (int i = 0; i <= 1023; ++i) {
            const float v = float(i) / 1023.0f;
            const simd_float3 out = gradeReference(simd_make_float3(v, 1.0f - v, v * 0.5f), u);
            CHECK(out.x == doctest::Approx(v).epsilon(2e-6).scale(1e-6));
            CHECK(out.y == doctest::Approx(1.0f - v).epsilon(2e-6).scale(1e-6));
            CHECK(out.z == doctest::Approx(v * 0.5f).epsilon(2e-6).scale(1e-6));
        }
    }
}

TEST_CASE("Grade: what each control does in linear light") {
    const float inputs[] = {0.05f, 0.2f, 0.4f, 0.6f, 0.75f};
    for (const VEInt transfer : {VEGradeTransferBT1886, VEGradeTransferSRGB, VEGradeTransferLinear}) {
        CAPTURE(transfer);
        // Exposure +1 doubles the linear values; -2 quarters them.
        for (const double stops : {1.0, -2.0}) {
            const VEGradeUniforms u = uniformsFor({{GradeParameter::Exposure, stops}}, transfer);
            for (const float v : inputs) {
                const simd_float3 out = gradeReference(simd_make_float3(v, v * 0.9f, v * 0.8f), u);
                for (int i = 0; i < 3; ++i) {
                    const float in = i == 0 ? v : i == 1 ? v * 0.9f : v * 0.8f;
                    CHECK(veLinearise(out[i], transfer) ==
                          doctest::Approx(std::exp2(stops) * veLinearise(in, transfer)).epsilon(1e-5));
                }
            }
        }
        // Saturation 0 gives grey (equal channels) at the input's linear luminance.
        const VEGradeUniforms grey0 = uniformsFor({{GradeParameter::Saturation, 0.0}}, transfer);
        const simd_float3 colourful = simd_make_float3(0.8f, 0.3f, 0.1f);
        const simd_float3 out = gradeReference(colourful, grey0);
        CHECK(out.x == out.y);
        CHECK(out.y == out.z);
        const float luminance = 0.2126f * veLinearise(0.8f, transfer) + 0.7152f * veLinearise(0.3f, transfer) +
                                0.0722f * veLinearise(0.1f, transfer);
        CHECK(veLinearise(out.x, transfer) == doctest::Approx(luminance).epsilon(1e-5));
        // Temperature and tint keep a grey's luminance and tilt its channels: warm is redder than blue,
        // magenta less green.
        for (const auto &[temperature, tint] : {std::pair{60.0, 0.0}, std::pair{-60.0, 0.0}, std::pair{0.0, 80.0},
                                               std::pair{40.0, -70.0}}) {
            CAPTURE(temperature);
            CAPTURE(tint);
            const VEGradeUniforms wb =
                uniformsFor({{GradeParameter::Temperature, temperature}, {GradeParameter::Tint, tint}}, transfer);
            const simd_float3 o = gradeReference(grey(0.5f), wb);
            const float before = veLinearise(0.5f, transfer);
            const float after = 0.2126f * veLinearise(o.x, transfer) + 0.7152f * veLinearise(o.y, transfer) +
                                0.0722f * veLinearise(o.z, transfer);
            CHECK(after == doctest::Approx(before).epsilon(1e-5));
            if (temperature > 0) {
                CHECK(o.x > o.z);
            } else if (temperature < 0) {
                CHECK(o.x < o.z);
            }
            if (tint > 0) {
                CHECK(o.y < 0.5f);
            } else if (tint < 0) {
                CHECK(o.y > 0.5f);
            }
        }
        // Contrast pivots on linear 0.18: grey 0.18 in linear light stays; brighter gets brighter at 2.
        const VEGradeUniforms steep = uniformsFor({{GradeParameter::Contrast, 2.0}}, transfer);
        const float pivotEncoded = veEncode(0.18f, transfer);
        CHECK(gradeReference(grey(pivotEncoded), steep).x == doctest::Approx(pivotEncoded).epsilon(1e-5));
        CHECK(gradeReference(grey(0.8f), steep).x > 0.8f);
        CHECK(gradeReference(grey(0.1f), steep).x < 0.1f);
    }
}

TEST_CASE("Grade: sub-black and out-of-range values stay ordered and finite through the curves") {
    for (const VEInt transfer : {VEGradeTransferBT1886, VEGradeTransferSRGB, VEGradeTransferLinear}) {
        // The transfer curves are mirrored: odd, monotonic, inverse of each other.
        float previous = -kInf;
        for (int i = -2000; i <= 2000; ++i) {
            const float v = float(i) / 1000.0f; // -2 ... 2
            const float linear = veLinearise(v, transfer);
            CHECK(linear >= previous);
            previous = linear;
            CHECK(sameBits(veLinearise(-v, transfer), -linear));
            CHECK(veEncode(linear, transfer) == doctest::Approx(v).epsilon(1e-5).scale(1e-6));
        }
        // An encoded value beyond 256 is taken as 256 (a picture never has one): the grade stays finite.
        const VEGradeUniforms u = uniformsFor({{GradeParameter::Exposure, 5.0}, {GradeParameter::Contrast, 2.0}}, transfer);
        const simd_float3 huge = gradeReference(simd_make_float3(1e30f, 256.0f, -kMax), u);
        CHECK(huge.x == huge.y);
        CHECK(std::isfinite(huge.z));
        CHECK(huge.z < 0.0f);
    }
}

TEST_CASE("Grade: the transfer a source is linearised by") {
    using media::TransferFunction;
    CHECK(gradeTransferFor(TransferFunction::BT709, false) == VEGradeTransferBT1886);
    CHECK(gradeTransferFor(TransferFunction::SMPTE240M, false) == VEGradeTransferBT1886);
    CHECK(gradeTransferFor(TransferFunction::PQ, false) == VEGradeTransferBT1886);
    CHECK(gradeTransferFor(TransferFunction::HLG, false) == VEGradeTransferBT1886);
    CHECK(gradeTransferFor(TransferFunction::Unknown, false) == VEGradeTransferBT1886);
    CHECK(gradeTransferFor(TransferFunction::Unknown, true) == VEGradeTransferSRGB);
    CHECK(gradeTransferFor(TransferFunction::SRGB, false) == VEGradeTransferSRGB);
    CHECK(gradeTransferFor(TransferFunction::SRGB, true) == VEGradeTransferSRGB);
    CHECK(gradeTransferFor(TransferFunction::Linear, false) == VEGradeTransferLinear);
    CHECK(gradeTransferFor(TransferFunction::BT709, true) == VEGradeTransferBT1886); // a tag wins
}
