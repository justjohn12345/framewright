// The LUT stages of ColorGrade.h on the CPU (the code the fragment shader compiles): a generated identity 3D
// LUT returns its input within a bound (tetrahedral interpolation is exact for a linear table) and so does an
// identity 1D LUT (through the tables); a known transform (a LUT that swaps red and blue, one that inverts) is
// reproduced at and between its entries; the domain maps and limits the input; the look's strength mixes; the
// input LUT runs before the grade (exposure after it) and the look after it; every output finite for the
// special inputs; the uniforms and the tables.

#include "../../Engine/Render/ColorGrade.h"

#include <doctest.h>

#include <cmath>
#include <functional>
#include <limits>
#include <vector>

using namespace ve;
using namespace ve::render;

namespace {

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

CubeLut curveOf(std::uint32_t size, const std::function<float(float)> &f) {
    CubeLut lut;
    lut.kind = CubeKind::OneD;
    lut.size = size;
    for (std::uint32_t i = 0; i < size; ++i) {
        const float v = f(float(i) / float(size - 1));
        lut.table.insert(lut.table.end(), {v, v, v});
    }
    return lut;
}

// The whole grade of `rgb` with only `input` and / or `look` (linear transfer, so nothing else changes).
simd_float3 gradeWith(simd_float3 rgb, const CubeLut *input, const CubeLut *look, double strength = 1.0,
                      GradeValues basic = ClipGrade::neutralValues()) {
    const VEGradeUniforms u =
        gradeUniformsFor(basic, GradeWheels{}, GradeCurves{}, input, look, strength, VEGradeTransferLinear);
    const std::vector<float> tables = gradeTableData(GradeCurves{}, input, look);
    return gradeReference(rgb, u, tables.data(), input, look);
}

std::vector<simd_float3> samples() {
    std::vector<simd_float3> out;
    for (int r = 0; r <= 10; ++r) {
        for (int g = 0; g <= 10; ++g) {
            for (int b = 0; b <= 10; ++b) {
                out.push_back(simd_make_float3(r * 0.0987f, g * 0.0999f, b * 0.0991f)); // within [0, 1]
            }
        }
    }
    return out;
}

} // namespace

TEST_CASE("Grade LUTs: the identity returns its input") {
    for (const std::uint32_t size : {2u, 17u, 33u}) {
        const CubeLut identity = cubeOf(size, [](simd_float3 v) { return v; });
        double worst = 0.0;
        for (const simd_float3 &v : samples()) {
            const simd_float3 out = gradeWith(v, &identity, nullptr);
            for (int c = 0; c < 3; ++c) {
                worst = std::max(worst, double(std::fabs(out[c] - v[c])));
            }
        }
        CAPTURE(size);
        CHECK(worst < 1e-6);
    }
    const CubeLut curve = curveOf(1024, [](float x) { return x; });
    const CubeLut coarse = curveOf(5, [](float x) { return x; });
    for (const simd_float3 &v : samples()) {
        const simd_float3 one = gradeWith(v, nullptr, &curve);
        const simd_float3 few = gradeWith(v, &coarse, nullptr);
        for (int c = 0; c < 3; ++c) {
            CHECK(std::fabs(one[c] - v[c]) < 1e-6f);
            CHECK(std::fabs(few[c] - v[c]) < 1e-6f);
        }
    }
}

TEST_CASE("Grade LUTs: a known transform") {
    // Swapping red and blue is linear: exact between the entries too.
    const CubeLut swap = cubeOf(9, [](simd_float3 v) { return simd_make_float3(v.z, v.y, v.x); });
    for (const simd_float3 &v : samples()) {
        const simd_float3 out = gradeWith(v, nullptr, &swap);
        CHECK(out.x == doctest::Approx(v.z).epsilon(1e-5));
        CHECK(out.y == doctest::Approx(v.y).epsilon(1e-5));
        CHECK(out.z == doctest::Approx(v.x).epsilon(1e-5));
    }
    // A nonlinear one (a square per channel): exact at the entries, within the interpolation's error between.
    const CubeLut square = cubeOf(17, [](simd_float3 v) { return v * v; });
    const simd_float3 atEntry = gradeWith(simd_make_float3(0.25f, 0.5f, 0.75f), nullptr, &square);
    CHECK(atEntry.x == doctest::Approx(0.0625f).epsilon(1e-5));
    CHECK(atEntry.z == doctest::Approx(0.5625f).epsilon(1e-5));
    for (const simd_float3 &v : samples()) {
        const simd_float3 out = gradeWith(v, nullptr, &square);
        for (int c = 0; c < 3; ++c) {
            CHECK(std::fabs(out[c] - v[c] * v[c]) < 1.0f / (4.0f * 16.0f * 16.0f) + 1e-6f); // h^2 / 4
        }
    }
    // A 1D inverting curve.
    const CubeLut invert = curveOf(2, [](float x) { return 1.0f - x; });
    const simd_float3 inverted = gradeWith(simd_make_float3(0.2f, 0.5f, 0.9f), &invert, nullptr);
    CHECK(inverted.x == doctest::Approx(0.8f).epsilon(1e-5));
    CHECK(inverted.z == doctest::Approx(0.1f).epsilon(1e-4));
}

TEST_CASE("Grade LUTs: the domain, the strength and the order") {
    // A domain of [-0.5, 1.5]: the input is mapped into it, and limited at its ends.
    CubeLut wide = cubeOf(5, [](simd_float3 v) { return v; });
    wide.domainMin = {-0.5f, -0.5f, -0.5f};
    wide.domainMax = {1.5f, 1.5f, 1.5f};
    CHECK(gradeWith(simd_make_float3(0.5f, 0.5f, 0.5f), &wide, nullptr).x == doctest::Approx(0.5f));
    CHECK(gradeWith(simd_make_float3(1.5f, 0.0f, 0.0f), &wide, nullptr).x == doctest::Approx(1.0f));
    CHECK(gradeWith(simd_make_float3(9.0f, -9.0f, 0.0f), &wide, nullptr).x == doctest::Approx(1.0f));
    CHECK(gradeWith(simd_make_float3(9.0f, -9.0f, 0.0f), &wide, nullptr).y == doctest::Approx(0.0f));
    // The look's strength mixes what it changes.
    const CubeLut black = cubeOf(2, [](simd_float3) { return simd_make_float3(0, 0, 0); });
    const simd_float3 v = simd_make_float3(0.8f, 0.4f, 0.2f);
    CHECK(gradeWith(v, nullptr, &black, 0.0).x == doctest::Approx(0.8f));
    CHECK(gradeWith(v, nullptr, &black, 0.25).x == doctest::Approx(0.6f));
    CHECK(gradeWith(v, nullptr, &black, 1.0).x == doctest::Approx(0.0f));
    // The input LUT runs before the grade: halve, then exposure +1 doubles back.
    const CubeLut halve = cubeOf(3, [](simd_float3 x) { return x * 0.5f; });
    GradeValues brighter = ClipGrade::neutralValues();
    brighter[static_cast<std::size_t>(GradeParameter::Exposure)] = 1.0;
    CHECK(gradeWith(v, &halve, nullptr, 1.0, brighter).x == doctest::Approx(0.8f).epsilon(1e-5));
    // The look runs after it: exposure +1 then halve gives the input.
    CHECK(gradeWith(simd_make_float3(0.3f, 0.2f, 0.1f), nullptr, &halve, 1.0, brighter).x ==
          doctest::Approx(0.3f).epsilon(1e-5));
}

TEST_CASE("Grade LUTs: finite outputs, the uniforms and the tables") {
    const CubeLut cube = cubeOf(5, [](simd_float3 v) { return simd_make_float3(v.y, 1.0f - v.x, v.z * v.z); });
    const CubeLut curve = curveOf(16, [](float x) { return std::sqrt(x); });
    const float inf = std::numeric_limits<float>::infinity();
    for (const float special : {0.0f, -0.0f, std::numeric_limits<float>::quiet_NaN(), inf, -inf,
                                std::numeric_limits<float>::max(), 1e-40f, -1.0f, 256.0f, 1e30f}) {
        for (const auto &[input, look] : std::vector<std::pair<const CubeLut *, const CubeLut *>>{
                 {&cube, &curve}, {&curve, &cube}, {&cube, nullptr}, {nullptr, &curve}}) {
            const simd_float3 out = gradeWith(simd_make_float3(special, 0.5f, special), input, look, 0.7);
            CHECK(std::isfinite(out.x));
            CHECK(std::isfinite(out.y));
            CHECK(std::isfinite(out.z));
        }
    }
    const VEGradeUniforms u = gradeUniformsFor(ClipGrade::neutralValues(), GradeWheels{}, GradeCurves{}, &cube, &curve,
                                               0.4, VEGradeTransferBT1886);
    CHECK(u.stages == (VEGradeStageInputLut | VEGradeStageLookLut));
    CHECK(u.lutFlags == VEGradeLutInputIs3D);
    CHECK(u.inputCubeSize == 5u);
    CHECK(u.lookCubeSize == 0u);
    CHECK(u.lookStrength == doctest::Approx(0.4f));
    CHECK(u.inputDomainScale.x == 1.0f);
    CHECK(gradeUniformsFor(ClipGrade::neutralValues(), GradeWheels{}, GradeCurves{}, nullptr, nullptr, 0.4,
                           VEGradeTransferBT1886)
              .stages == 0u);
    // A 1D LUT's rows in the tables, over its domain; a 3D one leaves its rows the identity.
    const std::vector<float> tables = gradeTableData(GradeCurves{}, &cube, &curve);
    CHECK(tables[std::size_t(VEGradeTableRowInputLut) * kVEGradeTableWidth + 512] ==
          doctest::Approx(512.0 / 1023.0).epsilon(1e-6));
    CHECK(tables[std::size_t(VEGradeTableRowLookLut) * kVEGradeTableWidth + kVEGradeTableWidth - 1] == 1.0f);
    CHECK(tables[std::size_t(VEGradeTableRowLookLut) * kVEGradeTableWidth + 256] ==
          doctest::Approx(std::sqrt(15.0 * 256.0 / 1023.0 / 15.0)).epsilon(0.02));
}
