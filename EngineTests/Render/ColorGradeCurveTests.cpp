// The tone curves of ColorGrade.h on the CPU (the code the fragment shader compiles for an extended grade
// with curves): the table lookup (exact at its samples, linear between them, limited to [0, 1] with NaN as
// 0); the luma curve moves luma and keeps the channels' differences; each channel's curve maps its channel;
// a curve whose bit is clear is skipped; every output finite for the special inputs; monotonic for rising
// curves; the uniforms (the stage bit and mask only for curves that are not the identity) and the tables.

#include "../../Engine/Render/ColorGrade.h"

#include <doctest.h>

#include <bit>
#include <cmath>
#include <limits>
#include <vector>

using namespace ve;
using namespace ve::render;

namespace {

GradeCurves curvesOf(CurvePoints luma, CurvePoints red = {}, CurvePoints green = {}, CurvePoints blue = {}) {
    return {std::move(luma), std::move(red), std::move(green), std::move(blue)};
}

const CurvePoints kSCurve{{0.0, 0.0}, {0.25, 0.18}, {0.75, 0.84}, {1.0, 1.0}};
const CurvePoints kInverted{{0.0, 1.0}, {1.0, 0.0}};
const CurvePoints kCrushed{{0.0, 0.05}, {0.5, 0.4}, {1.0, 0.9}};

VEGradeUniforms uniformsFor(const GradeCurves &curves, VEInt transfer = VEGradeTransferLinear) {
    return gradeUniformsFor(ClipGrade::neutralValues(), GradeWheels{}, curves, transfer);
}

} // namespace

TEST_CASE("Grade curves: the table lookup") {
    const std::vector<float> data = gradeTableData(curvesOf(kSCurve, kInverted));
    const VEGradeTables tables{data.data()};
    REQUIRE(data.size() == std::size_t(VEGradeTableRowCount) * kVEGradeTableWidth);
    // Exact at the samples.
    for (const std::uint32_t i : {0u, 1u, 511u, 1022u, 1023u}) {
        const float x = float(i) / float(kVEGradeTableWidth - 1);
        CHECK(veTableLookup(tables, x, VEGradeTableRowLuma) == doctest::Approx(data[i]).epsilon(1e-6));
    }
    // Linear between two samples.
    const float between = (100.5f) / float(kVEGradeTableWidth - 1);
    CHECK(veTableLookup(tables, between, VEGradeTableRowLuma) == doctest::Approx(0.5f * (data[100] + data[101])).epsilon(1e-5));
    // Limited to [0, 1]; NaN as 0.
    CHECK(veTableLookup(tables, -3.0f, VEGradeTableRowRed) == 1.0f);
    CHECK(veTableLookup(tables, 7.0f, VEGradeTableRowRed) == 0.0f);
    CHECK(veTableLookup(tables, std::numeric_limits<float>::quiet_NaN(), VEGradeTableRowRed) == 1.0f);
    // Identity rows for identity curves; the "no tables" reader is the identity too.
    CHECK(veTableLookup(tables, 0.3f, VEGradeTableRowGreen) == doctest::Approx(0.3f).epsilon(1e-6));
    CHECK(veTableLookup(VENoGradeTables{}, 0.3f, VEGradeTableRowBlue) == doctest::Approx(0.3f).epsilon(1e-6));
}

TEST_CASE("Grade curves: the uniforms") {
    CHECK(uniformsFor(GradeCurves{}).stages == 0u);
    CHECK(uniformsFor(curvesOf({{0, 0}, {1, 1}})).curveMask == 0u); // an identity curve
    const VEGradeUniforms u = uniformsFor(curvesOf(kSCurve, {}, kInverted));
    CHECK(u.stages == VEGradeStageCurves);
    CHECK(u.curveMask == ((1u << VEGradeTableRowLuma) | (1u << VEGradeTableRowGreen)));
    // With wheels too.
    GradeWheels wheels{};
    wheels[0].level = 0.2;
    CHECK(gradeUniformsFor(ClipGrade::neutralValues(), wheels, curvesOf(kSCurve), VEGradeTransferBT1886).stages ==
          (VEGradeStageWheels | VEGradeStageCurves));
}

TEST_CASE("Grade curves: what the curves do") {
    // Linear transfer, no other stage: the curves see the input.
    const GradeCurves channels = curvesOf({}, kInverted, kCrushed, {});
    const std::vector<float> channelTables = gradeTableData(channels);
    const VEGradeUniforms u = uniformsFor(channels);
    const simd_float3 out = gradeReference(simd_make_float3(0.2f, 0.5f, 0.7f), u, channelTables.data());
    CHECK(out.x == doctest::Approx(0.8f).epsilon(1e-4));                          // red inverted
    CHECK(out.y == doctest::Approx(float(evaluateCurve(kCrushed, 0.5))).epsilon(1e-4)); // green crushed
    CHECK(out.z == doctest::Approx(0.7f).epsilon(1e-6));                          // blue untouched (its bit clear)
    // The luma curve: every channel moves by the luma's change, so their differences stay.
    const GradeCurves luma = curvesOf(kSCurve);
    const std::vector<float> lumaTables = gradeTableData(luma);
    const simd_float3 in = simd_make_float3(0.6f, 0.2f, 0.3f);
    const simd_float3 moved = gradeReference(in, uniformsFor(luma), lumaTables.data());
    const float y = 0.2126f * in.x + 0.7152f * in.y + 0.0722f * in.z;
    const float shift = float(evaluateCurve(kSCurve, y)) - y;
    CHECK(moved.x == doctest::Approx(in.x + shift).epsilon(2e-4));
    CHECK(moved.x - moved.y == doctest::Approx(in.x - in.y).epsilon(1e-5));
    CHECK(moved.z - moved.y == doctest::Approx(in.z - in.y).epsilon(1e-5));
    // Rising curves: rising output; every output finite for the special inputs.
    const GradeCurves all = curvesOf(kSCurve, kCrushed, kSCurve, kCrushed);
    const std::vector<float> allTables = gradeTableData(all);
    for (const VEInt transfer : {VEGradeTransferBT1886, VEGradeTransferSRGB, VEGradeTransferLinear}) {
        const VEGradeUniforms every = uniformsFor(all, transfer);
        simd_float3 previous = simd_make_float3(-1, -1, -1);
        for (int i = -20; i <= 1100; ++i) {
            const float v = float(i) / 1000.0f;
            const simd_float3 o = gradeReference(simd_make_float3(v, v, v), every, allTables.data());
            for (int c = 0; c < 3; ++c) {
                CHECK(float(o[c]) >= float(previous[c]) - 1e-6f);
            }
            previous = o;
        }
        const float inf = std::numeric_limits<float>::infinity();
        for (const float special : {0.0f, -0.0f, std::numeric_limits<float>::quiet_NaN(), inf, -inf,
                                    std::numeric_limits<float>::max(), 1e-40f, -1.0f, 256.0f}) {
            const simd_float3 o = gradeReference(simd_make_float3(special, 0.5f, special), every, allTables.data());
            CHECK(std::isfinite(o.x));
            CHECK(std::isfinite(o.y));
            CHECK(std::isfinite(o.z));
        }
    }
}
