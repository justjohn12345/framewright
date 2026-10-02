// The lift / gamma / gain wheels of ColorGrade.h on the CPU (the code the fragment shader compiles for an
// extended grade): every output finite for the special inputs of the decision's section 2 under strong
// settings; the power's linear segment (no pow of a value below epsilon, continuous and monotonic across
// it); each wheel neutral is the identity bit for bit, and the extended grade without a stage is the slice 1
// grade value for value; what each wheel does in linear light; the colour direction keeps luminance; the
// uniforms (neutral exactly 0, 1, 1, 1; the stage bit only when a wheel is set).

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

std::vector<float> specialInputs() {
    return {0.0f,   -0.0f, kEps,  -kEps, kEps / 2, -kEps / 2, kDenorm, -kDenorm, 1e-40f, -1e-40f, -1e-3f, -0.1f,
            -0.5f,  -1.0f, 1.0f,  0.18f, 0.5f,     2.0f,      1e3f,    1e6f,     1e30f,  kMax,    -kMax,  kNaN,
            kInf,   -kInf, 1e-4f, -1e-6f};
}

GradeWheels wheelsOf(WheelValue lift, WheelValue gamma, WheelValue gain) {
    return {lift, gamma, gain};
}

// Strong settings: each wheel at its ends, colours at the rim, and everything together.
std::vector<GradeWheels> strongWheels() {
    const WheelValue none{};
    return {
        wheelsOf({1.0, 0, 0}, none, none),
        wheelsOf({-1.0, 0, 0}, none, none),
        wheelsOf(none, {1.0, 0, 0}, none),
        wheelsOf(none, {-1.0, 0, 0}, none),
        wheelsOf(none, none, {1.0, 0, 0}),
        wheelsOf(none, none, {-1.0, 0, 0}),
        wheelsOf({0, 1.0, 0}, {0, 0, 1.0}, {0, -0.7071, 0.7071}),
        wheelsOf({1.0, -1.0, 0}, {-1.0, 0, -1.0}, {1.0, 0.6, -0.8}),
        wheelsOf({-1.0, 0, 1.0}, {1.0, 1.0, 0}, {-1.0, -1.0, 0}),
    };
}

VEGradeUniforms uniformsFor(const GradeWheels &wheels, VEInt transfer = VEGradeTransferBT1886,
                            GradeValues basic = ClipGrade::neutralValues()) {
    return gradeUniformsFor(basic, wheels, transfer);
}

} // namespace

TEST_CASE("Grade wheels: every output is finite for every special input") {
    for (const VEInt transfer : {VEGradeTransferBT1886, VEGradeTransferSRGB, VEGradeTransferLinear}) {
        for (const GradeWheels &wheels : strongWheels()) {
            for (const GradeValues &basic :
                 {ClipGrade::neutralValues(), GradeValues{5.0, 2.0, 100.0, -100.0, 2.0}, GradeValues{-5.0, 0.0, 0, 0, 0}}) {
                const VEGradeUniforms u = uniformsFor(wheels, transfer, basic);
                REQUIRE(u.stages == VEGradeStageWheels);
                for (const float r : specialInputs()) {
                    for (const float g : {0.0f, kNaN, 1.0f, -kInf}) {
                        const simd_float3 out = gradeReference(simd_make_float3(r, g, 0.5f), u);
                        CAPTURE(r);
                        CAPTURE(g);
                        CHECK(std::isfinite(out.x));
                        CHECK(std::isfinite(out.y));
                        CHECK(std::isfinite(out.z));
                    }
                }
            }
        }
    }
}

TEST_CASE("Grade wheels: the power follows the section 2 rule") {
    for (const float exponent : {0.3535534f, 0.5f, 0.8f, 1.25f, 2.0f, 2.828427f}) {
        CAPTURE(exponent);
        const float slope = float(std::pow(double(kEps), double(exponent)) / double(kEps));
        // The linear segment through the origin below epsilon; negatives continue it.
        CHECK(vePower(0.0f, exponent, slope) == 0.0f);
        CHECK(vePower(kEps / 2, exponent, slope) == doctest::Approx(kEps / 2 * slope).epsilon(1e-6));
        CHECK(vePower(-1.0f, exponent, slope) == doctest::Approx(-slope).epsilon(1e-6));
        // Continuous at epsilon (relative 1e-5).
        const float below = vePower(std::nextafter(kEps, 0.0f), exponent, slope);
        const float at = vePower(kEps, exponent, slope);
        CHECK(std::fabs(at - below) <= 1e-5f * at);
        // Monotonic over a dense grid through the segment and the curve; finite at the extremes.
        float previous = -kInf;
        for (int i = -2000; i <= 4000; ++i) {
            const float v = i < 0 ? float(i) * kEps / 500.0f : float(std::pow(10.0, i / 500.0 - 6.0));
            const float f = vePower(v, exponent, slope);
            CHECK(std::isfinite(f));
            CHECK(f >= previous);
            previous = f;
        }
        CHECK(std::isfinite(vePower(kMax, exponent, slope)));
        CHECK(std::isfinite(vePower(-kMax, exponent, slope)));
        CHECK(vePower(1.0f, exponent, slope) == doctest::Approx(1.0f).epsilon(1e-6)); // pivots on linear 1
    }
    // Exponent 1 is the identity, bit for bit.
    for (const float v : specialInputs()) {
        CHECK(std::bit_cast<std::uint32_t>(vePower(v, 1.0f, 1.0f)) == std::bit_cast<std::uint32_t>(v));
    }
}

TEST_CASE("Grade wheels: neutral is the identity and no stage is the slice 1 grade") {
    // A neutral wheel channel returns its input bit for bit.
    for (const float v : specialInputs()) {
        if (std::isnan(v)) {
            continue;
        }
        CHECK(std::bit_cast<std::uint32_t>(veWheelChannel(v, 0.0f, 1.0f, 1.0f, 1.0f)) == std::bit_cast<std::uint32_t>(v));
    }
    // Neutral wheels: exact uniforms and no stage bit.
    const VEGradeUniforms neutral = uniformsFor(GradeWheels{});
    CHECK(neutral.stages == 0u);
    for (int c = 0; c < 3; ++c) {
        CHECK(neutral.lift[c] == 0.0f);
        CHECK(neutral.wheelGain[c] == 1.0f);
        CHECK(neutral.inverseGamma[c] == 1.0f);
        CHECK(neutral.gammaSlope[c] == 1.0f);
    }
    // One wheel set: the others stay exactly neutral.
    const VEGradeUniforms gainOnly = uniformsFor(wheelsOf({}, {}, {0.5, 0, 0}));
    for (int c = 0; c < 3; ++c) {
        CHECK(gainOnly.lift[c] == 0.0f);
        CHECK(gainOnly.inverseGamma[c] == 1.0f);
        CHECK(gainOnly.wheelGain[c] == doctest::Approx(std::exp2(0.5)));
    }
    // With a basic grade and no stage, veGradeExtended is veGrade value for value.
    const GradeValues basic{1.5, 1.3, 40.0, -20.0, 1.4};
    VEGradeUniforms u = gradeUniformsFor(basic, VEGradeTransferBT1886);
    for (const float r : specialInputs()) {
        const simd_float3 in = simd_make_float3(r, 0.3f, 0.7f);
        const simd_float3 a = veGradeExtended(in, u, VENoGradeTables{});
        const simd_float3 b = veGrade(in, u.gain.x, u.gain.y, u.gain.z, u.saturation, u.contrast, u.contrastSlope,
                                      u.transfer);
        for (int c = 0; c < 3; ++c) {
            CHECK(std::bit_cast<std::uint32_t>(a[c]) == std::bit_cast<std::uint32_t>(b[c]));
        }
    }
}

TEST_CASE("Grade wheels: what each wheel does in linear light") {
    // Linear transfer: the grade's values are its linear values.
    const auto grade = [](const GradeWheels &wheels, float v) {
        return gradeReference(simd_make_float3(v, v, v), uniformsFor(wheels, VEGradeTransferLinear));
    };
    // Lift: black rises to 0.1 x level, white stays.
    CHECK(grade(wheelsOf({1.0, 0, 0}, {}, {}), 0.0f).x == doctest::Approx(0.1f));
    CHECK(grade(wheelsOf({0.5, 0, 0}, {}, {}), 0.0f).y == doctest::Approx(0.05f));
    CHECK(grade(wheelsOf({1.0, 0, 0}, {}, {}), 1.0f).z == doctest::Approx(1.0f));
    CHECK(grade(wheelsOf({-1.0, 0, 0}, {}, {}), 0.5f).x == doctest::Approx(0.45f));
    // Gain: a stop per level.
    CHECK(grade(wheelsOf({}, {}, {1.0, 0, 0}), 0.25f).x == doctest::Approx(0.5f));
    CHECK(grade(wheelsOf({}, {}, {-1.0, 0, 0}), 0.25f).x == doctest::Approx(0.125f));
    // Gamma: linear 0.18 to 0.18^(1/2) at level 1; black and white stay.
    CHECK(grade(wheelsOf({}, {1.0, 0, 0}, {}), 0.18f).x == doctest::Approx(std::sqrt(0.18f)).epsilon(1e-5));
    CHECK(grade(wheelsOf({}, {-1.0, 0, 0}, {}), 0.18f).x == doctest::Approx(0.18f * 0.18f).epsilon(1e-5));
    CHECK(grade(wheelsOf({}, {1.0, 0, 0}, {}), 0.0f).x == 0.0f);
    CHECK(grade(wheelsOf({}, {1.0, 0, 0}, {}), 1.0f).x == doctest::Approx(1.0f));
    // The order: (gain * (v + lift (1 - v)))^(1 / gamma).
    const float v = 0.3f;
    const float expected = std::pow(2.0f * (v + 0.05f * (1.0f - v)), 1.0f / std::exp2(0.5f));
    CHECK(grade(wheelsOf({0.5, 0, 0}, {0.5, 0, 0}, {1.0, 0, 0}), v).x == doctest::Approx(expected).epsilon(1e-5));
    // Monotonic in the input for every strong setting, per channel.
    for (const GradeWheels &wheels : strongWheels()) {
        const VEGradeUniforms u = uniformsFor(wheels, VEGradeTransferBT1886);
        simd_float3 previous = simd_make_float3(-kInf, -kInf, -kInf);
        for (int i = -50; i <= 1100; ++i) {
            const float x = float(i) / 1000.0f;
            const simd_float3 out = gradeReference(simd_make_float3(x, x, x), u);
            for (int c = 0; c < 3; ++c) {
                CHECK(float(out[c]) >= float(previous[c]));
            }
            previous = out;
        }
    }
}

TEST_CASE("Grade wheels: a colour tilts the channels toward it and keeps luminance") {
    // The direction has no luminance, and points where a vectorscope shows the colour.
    for (const auto &[cb, cr] : std::vector<std::pair<double, double>>{{1, 0}, {0, 1}, {-0.6, 0.8}, {0.3, -0.2}}) {
        const simd_double3 w = wheelColourDirection(cb, cr);
        CHECK(0.2126 * w.x + 0.7152 * w.y + 0.0722 * w.z == doctest::Approx(0.0).epsilon(1e-12));
    }
    CHECK(wheelColourDirection(1, 0).z == doctest::Approx(1.0)); // +cb: blue, the axis's length
    CHECK(wheelColourDirection(0, 1).x > 0.8);                   // +cr: red
    CHECK(wheelColourDirection(0, 1).z == doctest::Approx(0.0));
    // A gain toward red: red up, blue down, the grey's luminance about kept (gains in the log domain keep
    // it to first order).
    const VEGradeUniforms red = uniformsFor(wheelsOf({}, {}, {0, 0, 1.0}), VEGradeTransferLinear);
    const simd_float3 out = gradeReference(simd_make_float3(0.2f, 0.2f, 0.2f), red);
    CHECK(out.x > 0.2f);
    CHECK(out.z == doctest::Approx(0.2f).epsilon(1e-6));
    CHECK(out.y < 0.2f);
    const float luminance = 0.2126f * out.x + 0.7152f * out.y + 0.0722f * out.z;
    CHECK(luminance == doctest::Approx(0.2f).epsilon(0.03));
    // A lift toward blue on black: the offset itself has no luminance.
    const VEGradeUniforms blue = uniformsFor(wheelsOf({0, 1.0, 0}, {}, {}), VEGradeTransferLinear);
    CHECK(0.2126f * blue.lift.x + 0.7152f * blue.lift.y + 0.0722f * blue.lift.z == doctest::Approx(0.0f).epsilon(1e-7));
    CHECK(blue.lift.z == doctest::Approx(0.05f));
}
