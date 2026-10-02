// The hue curves of ColorGrade.h on the CPU (the code the fragment shader compiles): a grey is untouched;
// Hue vs Saturation desaturates or doubles the colours of its hue and keeps their luminance, leaving other hues
// alone; Hue vs Hue turns them by up to 60 degrees keeping luminance and chroma; Hue vs Luma scales them by up
// to a stop; the effect fades out toward grey; every output finite; the periodic table lookup wraps; the
// uniforms and tables.

#include "../../Engine/Render/ColorGrade.h"

#include <doctest.h>

#include <cmath>
#include <limits>
#include <vector>

using namespace ve;
using namespace ve::render;

namespace {

constexpr double kPi = 3.14159265358979323846;

// A linear-light colour of luminance `y`, chroma `c` and hue `h` (a fraction of the circle, Cb across, Cr up).
simd_float3 colourAt(double y, double c, double h) {
    const double cb = c * std::cos(h * 2 * kPi);
    const double cr = c * std::sin(h * 2 * kPi);
    const double r = y + 1.5748 * cr;
    const double b = y + 1.8556 * cb;
    const double g = (y - 0.2126 * r - 0.0722 * b) / 0.7152;
    return simd_make_float3(float(r), float(g), float(b));
}

double luminanceOf(simd_float3 v) {
    return 0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z;
}

double chromaOf(simd_float3 v) {
    const double y = luminanceOf(v);
    const double cb = (v.z - y) / 1.8556;
    const double cr = (v.x - y) / 1.5748;
    return std::hypot(cb, cr);
}

double hueOf(simd_float3 v) {
    const double y = luminanceOf(v);
    double h = std::atan2((v.x - y) / 1.5748, (v.z - y) / 1.8556) / (2 * kPi);
    return h < 0 ? h + 1 : h;
}

simd_float3 graded(simd_float3 v, const HueCurves &curves) {
    const VEGradeUniforms u = gradeUniformsFor(ClipGrade::neutralValues(), GradeWheels{}, GradeCurves{}, nullptr, nullptr,
                                               1.0, VEGradeTransferLinear, curves);
    const std::vector<float> tables = gradeTableData(GradeCurves{}, nullptr, nullptr, curves);
    return gradeReference(v, u, tables.data());
}

HueCurves only(GradeHueCurve curve, CurvePoints points) {
    HueCurves curves{};
    curves[static_cast<std::size_t>(curve)] = std::move(points);
    return curves;
}

} // namespace

TEST_CASE("Grade hue curves: what each curve does") {
    const double red = 0.29; // the hue of BT.709 red, about 104 degrees
    const simd_float3 reddish = colourAt(0.3, 0.12, red);
    CHECK(hueOf(reddish) == doctest::Approx(red).epsilon(1e-4));
    // A grey has no hue: untouched by every curve.
    const HueCurves all{CurvePoints{{0.0, 0.0}}, CurvePoints{{0.0, 1.0}}, CurvePoints{{0.0, 1.0}}};
    const simd_float3 grey = simd_make_float3(0.4f, 0.4f, 0.4f);
    CHECK(simd_equal(graded(grey, all), grey));
    // Hue vs Saturation: 0 greys the colour, 1 doubles its chroma; luminance kept; other hues alone.
    const HueCurves pale = only(GradeHueCurve::Saturation, {{0.25, 0.5}, {red, 0.0}, {0.33, 0.5}});
    const simd_float3 greyed = graded(reddish, pale);
    CHECK(chromaOf(greyed) < 1e-5);
    CHECK(luminanceOf(greyed) == doctest::Approx(0.3).epsilon(1e-5));
    const simd_float3 blueish = colourAt(0.3, 0.12, 0.0);
    const simd_float3 untouched = graded(blueish, pale);
    CHECK(chromaOf(untouched) == doctest::Approx(0.12).epsilon(1e-4));
    const simd_float3 doubled = graded(reddish, only(GradeHueCurve::Saturation, {{0.5, 1.0}}));
    CHECK(chromaOf(doubled) == doctest::Approx(0.24).epsilon(1e-4));
    CHECK(luminanceOf(doubled) == doctest::Approx(0.3).epsilon(1e-5));
    // Hue vs Hue: y = 1 turns by 60 degrees, keeping luminance and chroma.
    const simd_float3 turned = graded(reddish, only(GradeHueCurve::Hue, {{0.0, 1.0}}));
    CHECK(hueOf(turned) == doctest::Approx(red + 1.0 / 6.0).epsilon(1e-4));
    CHECK(chromaOf(turned) == doctest::Approx(0.12).epsilon(1e-4));
    CHECK(luminanceOf(turned) == doctest::Approx(0.3).epsilon(1e-5));
    // Hue vs Luma: y = 1 doubles the colour, y = 0 halves it.
    CHECK(luminanceOf(graded(reddish, only(GradeHueCurve::Luma, {{0.0, 1.0}}))) == doctest::Approx(0.6).epsilon(1e-4));
    CHECK(luminanceOf(graded(reddish, only(GradeHueCurve::Luma, {{0.0, 0.0}}))) == doctest::Approx(0.15).epsilon(1e-4));
    // Near grey the effect fades: at a chroma of 0.01, a fifth of a stop of the full one.
    const simd_float3 faint = colourAt(0.3, 0.01, red);
    CHECK(luminanceOf(graded(faint, only(GradeHueCurve::Luma, {{0.0, 1.0}}))) ==
          doctest::Approx(0.3 * std::exp2(0.2)).epsilon(1e-3));
}

TEST_CASE("Grade hue curves: finite outputs, the table lookup, the uniforms") {
    const HueCurves all{CurvePoints{{0.1, 0.9}, {0.6, 0.2}}, CurvePoints{{0.3, 0.8}}, CurvePoints{{0.9, 0.1}, {0.95, 0.7}}};
    const float inf = std::numeric_limits<float>::infinity();
    for (const float special : {0.0f, -0.0f, std::numeric_limits<float>::quiet_NaN(), inf, -inf,
                                std::numeric_limits<float>::max(), 1e-40f, -1.0f, 256.0f}) {
        for (const VEInt transfer : {VEGradeTransferBT1886, VEGradeTransferLinear}) {
            const VEGradeUniforms u = gradeUniformsFor(ClipGrade::neutralValues(), GradeWheels{}, GradeCurves{}, nullptr,
                                                       nullptr, 1.0, transfer, all);
            const std::vector<float> tables = gradeTableData(GradeCurves{}, nullptr, nullptr, all);
            const simd_float3 out = gradeReference(simd_make_float3(special, 0.3f, 0.6f), u, tables.data());
            CHECK(std::isfinite(out.x));
            CHECK(std::isfinite(out.y));
            CHECK(std::isfinite(out.z));
        }
    }
    const VEGradeUniforms u = gradeUniformsFor(ClipGrade::neutralValues(), GradeWheels{}, GradeCurves{}, nullptr, nullptr,
                                               1.0, VEGradeTransferLinear, only(GradeHueCurve::Luma, {{0.2, 0.7}}));
    CHECK(u.stages == VEGradeStageHueCurves);
    CHECK(u.hueCurveMask == 4u);
    CHECK(gradeUniformsFor(ClipGrade::neutralValues(), GradeWheels{}, GradeCurves{}, nullptr, nullptr, 1.0,
                           VEGradeTransferLinear, HueCurves{})
              .stages == 0u);
    // The periodic lookup wraps from the last sample to the first.
    const CurvePoints wrapping{{0.0, 1.0}, {0.5, 0.0}};
    const std::vector<float> tables = gradeTableData(GradeCurves{}, nullptr, nullptr, only(GradeHueCurve::Saturation, wrapping));
    const VEGradeTables view{tables.data()};
    const float nearEnd = veHueTableLookup(view, 0.99995f, VEGradeTableRowHueSaturation);
    CHECK(nearEnd == doctest::Approx(1.0f).epsilon(1e-3));
    CHECK(veHueTableLookup(view, 0.5f, VEGradeTableRowHueSaturation) == doctest::Approx(0.0f).epsilon(1e-3));
    CHECK(veHueTableLookup(view, std::numeric_limits<float>::quiet_NaN(), VEGradeTableRowHueSaturation) ==
          doctest::Approx(1.0f));
}
