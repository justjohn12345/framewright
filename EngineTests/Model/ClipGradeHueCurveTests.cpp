// The hue curves of a clip's grade (ClipGrade.h, GradeHueCurve, slice 2): the table; the identity (none, or
// every y at 0.5), validity and sanitizing; the periodic spline (through its points, continuous where it joins
// itself, one point a constant, no overshoot between points, limited to [0, 1]); the project file (a list of [x, y] per curve, read back
// exactly, a bad curve repaired); SetClipGrade with hue curves (names, an identity stored as none, refusals,
// Reset Grade) and the selection's agreement.

#include "ModelFixtures.h"

#include "../../Engine/Edit/GradeEdits.h"

#include <cmath>
#include <limits>

using namespace vetest;
using nlohmann::json;

namespace {

const CurvePoints kRedsPale{{0.25, 0.5}, {0.29, 0.1}, {0.33, 0.5}};
const CurvePoints kOne{{0.6, 0.8}};

} // namespace

TEST_CASE("Grade hue curves: the table, the identity, validity and sanitizing") {
    CHECK(kGradeHueCurveCount == 3);
    CHECK(std::string(nameOf(GradeHueCurve::Saturation)) == "hueCurveSaturation");
    CHECK(std::string(displayNameOf(GradeHueCurve::Luma)) == "Hue vs Luma");
    CHECK(gradeHueCurveNamed("hueCurveHue") == GradeHueCurve::Hue);
    CHECK_FALSE(gradeHueCurveNamed("curveLuma").has_value());
    CHECK(isIdentityHueCurve({}));
    CHECK(isIdentityHueCurve({{0.1, 0.5}, {0.7, 0.5}}));
    CHECK_FALSE(isIdentityHueCurve(kOne));
    CHECK_FALSE(hueCurveProblem(kOne).has_value());
    CHECK_FALSE(hueCurveProblem({}).has_value());
    CHECK(hueCurveProblem({{1.0, 0.5}}).has_value()); // x = 1 is x = 0
    CHECK(hueCurveProblem({{0.2, 1.2}}).has_value());
    CHECK(hueCurveProblem({{0.4, 0.3}, {0.4, 0.6}}).has_value());
    CHECK(sanitizedHueCurve({{1.5, 0.9}, {0.2, -1.0}, {0.2, 0.4}}).size() == 2);
    CHECK(sanitizedHueCurve({{0.3, 0.5}}).empty());
}

TEST_CASE("Grade hue curves: the periodic spline") {
    CHECK(evaluateHueCurve({}, 0.3) == 0.5);
    CHECK(evaluateHueCurve(kOne, 0.1) == 0.8);
    for (const CurvePoint &point : kRedsPale) {
        CHECK(evaluateHueCurve(kRedsPale, point.x) == doctest::Approx(point.y).epsilon(1e-12));
    }
    // Continuous where it joins itself, and the same a turn away.
    const CurvePoints wrapping{{0.1, 0.2}, {0.5, 0.9}, {0.95, 0.4}};
    CHECK(evaluateHueCurve(wrapping, 0.99999) == doctest::Approx(evaluateHueCurve(wrapping, 0.0)).epsilon(1e-3));
    CHECK(evaluateHueCurve(wrapping, 1.3) == doctest::Approx(evaluateHueCurve(wrapping, 0.3)));
    CHECK(evaluateHueCurve(wrapping, -0.7) == doctest::Approx(evaluateHueCurve(wrapping, 0.3)));
    double previous = evaluateHueCurve(wrapping, 0.0);
    for (int i = 1; i <= 1000; ++i) {
        const double y = evaluateHueCurve(wrapping, i / 1000.0);
        CHECK(y >= 0.0);
        CHECK(y <= 1.0);
        CHECK(std::fabs(y - previous) < 0.02); // no jump anywhere around the circle
        previous = y;
    }
    // Far from a narrow dip the curve stays neutral.
    CHECK(evaluateHueCurve(kRedsPale, 0.7) == doctest::Approx(0.5).epsilon(1e-9));
    const std::vector<float> table = sampleHueCurve(wrapping, 8);
    CHECK(table[4] == doctest::Approx(float(evaluateHueCurve(wrapping, 0.5))));
}

TEST_CASE("Grade hue curves: the file, edits and the selection") {
    Fixture fx;
    const auto [a, sound] = fx.addLinkedPair(0, 30, 0);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 30, 30, 60);
    fx.sequence().findClip(a)->grade[GradeHueCurve::Saturation] = kRedsPale;
    fx.requireValid();
    const json document = projectToJson(fx.project);
    const json clipJson = document.at("sequences")[0].at("videoTracks")[0].at("clips")[0];
    CHECK(clipJson.at("grade").contains("hueCurveSaturation"));
    const ProjectLoadResult loaded = parseProject(serializeProject(fx.project));
    REQUIRE(loaded.ok());
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == fx.project);
    // A bad curve is repaired with a warning.
    json bad = document;
    bad["sequences"][0]["videoTracks"][0]["clips"][0]["grade"]["hueCurveLuma"] = json::array({json::array({1.2, 0.7})});
    const ProjectLoadResult repaired = projectFromJson(bad);
    REQUIRE(repaired.ok());
    REQUIRE(repaired.warnings.size() == 1);
    CHECK(repaired.warnings[0].find("the Hue vs Luma curve's points are not a valid curve") != std::string::npos);
    CHECK(repaired.project->sequences[0].findClip(a)->grade[GradeHueCurve::Luma].size() == 1);

    SetClipGrade set(fx.seq, {a, b}, GradeChange::of(GradeHueCurve::Hue, kOne));
    CHECK(set.name() == "Change Hue vs Hue Curve");
    applyReversible(fx.project, set);
    CHECK(fx.clip(b).grade[GradeHueCurve::Hue] == kOne);
    CHECK(fx.clip(a).grade[GradeHueCurve::Saturation] == kRedsPale); // kept
    SetClipGrade identity(fx.seq, {a}, GradeChange::of(GradeHueCurve::Hue, CurvePoints{{0.2, 0.5}}));
    applyReversible(fx.project, identity);
    CHECK(fx.clip(a).grade[GradeHueCurve::Hue].empty());
    SetClipGrade refused(fx.seq, {a}, GradeChange::of(GradeHueCurve::Luma, CurvePoints{{1.0, 0.2}}));
    applyRefused(fx.project, refused, EditError::InvalidArgument);
    const GradeSummary summary = summarizeGrades(fx.sequence(), {a, sound, b});
    CHECK(summary.isMixed(GradeHueCurve::Saturation));
    CHECK(summary.isMixed(GradeHueCurve::Hue));
    CHECK_FALSE(summary.isMixed(GradeHueCurve::Luma));
    SetClipGrade reset(fx.seq, {a, b}, GradeChange::whole(ClipGrade{}), "Reset Grade");
    applyReversible(fx.project, reset);
    CHECK(fx.clip(a).grade.isEmpty());
    // A clip graded by a hue curve alone counts as graded.
    fx.sequence().findClip(b)->grade[GradeHueCurve::Luma] = kOne;
    CHECK(summarizeGrades(fx.sequence(), {b}).anyGraded);
    CHECK_FALSE(fx.clip(b).grade.isNeutral());
}
