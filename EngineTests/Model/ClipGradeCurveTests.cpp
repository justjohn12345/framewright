// The curves of a clip's grade (ClipGrade.h, slice 2): the table; a curve's validity, its sanitizing and its
// identity; the monotone cubic (through its points, monotonic between rising points with no overshoot, flat
// beyond the ends, the samples a table holds); neutral means no grade and validation; the project file (a
// list of [x, y] per curve written only when not the identity, read back exactly, a bad curve repaired with
// a warning, a malformed one refused); SetClipGrade with curves (an identity stored as none, refusals,
// names, a whole grade and Reset carry them); the selection's agreement and "mixed".

#include "ModelFixtures.h"

#include "../../Engine/Edit/GradeEdits.h"

#include <cmath>
#include <limits>

using namespace vetest;
using nlohmann::json;

namespace {

json gradeJsonOf(const Project &project, ClipId id) {
    const json document = projectToJson(project);
    for (const json &sequence : document.at("sequences")) {
        for (const json &track : sequence.at("videoTracks")) {
            for (const json &clip : track.at("clips")) {
                if (clip.at("id") == id.value()) {
                    return clip.contains("grade") ? clip.at("grade") : json();
                }
            }
        }
    }
    FAIL("clip not in the file");
    return json();
}

json withGrade(const Project &project, ClipId id, const json &grade) {
    json document = projectToJson(project);
    for (json &sequence : document.at("sequences")) {
        for (json &track : sequence.at("videoTracks")) {
            for (json &clip : track.at("clips")) {
                if (clip.at("id") == id.value()) {
                    clip["grade"] = grade;
                }
            }
        }
    }
    return document;
}

const CurvePoints kSCurve{{0.0, 0.0}, {0.25, 0.18}, {0.75, 0.84}, {1.0, 1.0}};
const CurvePoints kLifted{{0.0, 0.1}, {1.0, 0.95}};

struct CurveClips : Fixture {
    ClipId a, b, sound;
    CurveClips() {
        std::tie(a, sound) = addLinkedPair(0, 30, 0);
        b = addClip(v1, av30, 30, 30, 60);
        sequence().findClip(a)->grade[GradeCurve::Luma] = kSCurve;
        sequence().findClip(b)->grade[GradeCurve::Red] = kLifted;
        requireValid();
    }
    const ClipGrade &grade(ClipId id) const {
        return clip(id).grade;
    }
};

} // namespace

TEST_CASE("Grade curves: the table, validity, sanitizing and the identity") {
    CHECK(kGradeCurveCount == 4);
    CHECK(std::string(nameOf(GradeCurve::Luma)) == "curveLuma");
    CHECK(std::string(nameOf(GradeCurve::Blue)) == "curveBlue");
    CHECK(std::string(displayNameOf(GradeCurve::Green)) == "Green");
    CHECK(gradeCurveNamed("curveRed") == GradeCurve::Red);
    CHECK_FALSE(gradeCurveNamed("curves").has_value()); // slice 1's example of a newer version's key
    CHECK(&infoOf(static_cast<GradeCurve>(9)) == &infoOf(GradeCurve::Luma));

    CHECK(isIdentityCurve({}));
    CHECK(isIdentityCurve({{0, 0}, {1, 1}}));
    CHECK(isIdentityCurve({{0, 0}, {0.4, 0.4}, {1, 1}}));
    CHECK_FALSE(isIdentityCurve({{0.1, 0.1}, {1, 1}})); // flat below 0.1: not the identity
    CHECK_FALSE(isIdentityCurve(kSCurve));

    CHECK_FALSE(curveProblem({}).has_value());
    CHECK_FALSE(curveProblem(kSCurve).has_value());
    CHECK(curveProblem({{0.5, 0.5}}).has_value());
    CHECK(curveProblem({{0, 0}, {0, 1}}).has_value());     // x not increasing
    CHECK(curveProblem({{0, 0}, {1.2, 1}}).has_value());   // outside [0, 1]
    CHECK(curveProblem({{0, std::numeric_limits<double>::quiet_NaN()}, {1, 1}}).has_value());
    CurvePoints many;
    for (int i = 0; i < 17; ++i) {
        many.push_back({i / 16.0, i / 16.0 * 0.5});
    }
    CHECK(curveProblem(many).has_value());

    const CurvePoints repaired = sanitizedCurve({{0.9, 1.4}, {0.1, -0.2}, {0.1, 0.5}, {std::nan(""), 0.3}, {0.5, 0.5}});
    CHECK(repaired == CurvePoints{{0.1, 0.0}, {0.5, 0.5}, {0.9, 1.0}});
    CHECK(sanitizedCurve({{0, 0}, {1, 1}}).empty());
    CHECK(sanitizedCurve({{0.3, 0.3}}).empty());
    CHECK(sanitizedCurve(many).size() == kMaxCurvePoints);
}

TEST_CASE("Grade curves: the monotone cubic") {
    // Through its points, flat beyond its ends.
    for (const CurvePoint &point : kSCurve) {
        CHECK(evaluateCurve(kSCurve, point.x) == doctest::Approx(point.y).epsilon(1e-12));
    }
    CHECK(evaluateCurve(kLifted, -1.0) == 0.1);
    CHECK(evaluateCurve(kLifted, 2.0) == 0.95);
    CHECK(evaluateCurve({{0.2, 0.3}, {0.8, 0.6}}, 0.1) == 0.3);
    CHECK(evaluateCurve({}, 0.37) == 0.37);
    CHECK(evaluateCurve(kLifted, std::nan("")) == 0.1);
    // Rising points give a rising curve without overshoot, even with steep and flat stretches.
    const CurvePoints steep{{0.0, 0.0}, {0.1, 0.0}, {0.12, 0.9}, {0.5, 0.95}, {0.6, 0.95}, {1.0, 1.0}};
    double previous = -1.0;
    for (int i = 0; i <= 2000; ++i) {
        const double y = evaluateCurve(steep, i / 2000.0);
        CHECK(y >= previous);
        CHECK(y >= 0.0);
        CHECK(y <= 1.0);
        previous = y;
    }
    // A flat stretch stays flat between its equal points.
    CHECK(evaluateCurve(steep, 0.55) == doctest::Approx(0.95));
    CHECK(evaluateCurve(steep, 0.05) == doctest::Approx(0.0));
    // Falling points: falling and within the points' values.
    const CurvePoints inverted{{0, 1}, {0.5, 0.6}, {1, 0}};
    previous = 2.0;
    for (int i = 0; i <= 200; ++i) {
        const double y = evaluateCurve(inverted, i / 200.0);
        CHECK(y <= previous);
        previous = y;
    }
    // The samples a table holds: sample i at x = i / (n - 1), the identity for no points.
    const std::vector<float> table = sampleCurve(kSCurve, 1024);
    REQUIRE(table.size() == 1024);
    CHECK(table.front() == 0.0f);
    CHECK(table.back() == 1.0f);
    CHECK(table[256] == doctest::Approx(evaluateCurve(kSCurve, 256.0 / 1023.0)).epsilon(1e-6));
    const std::vector<float> identity = sampleCurve({}, 5);
    CHECK(identity == std::vector<float>{0.0f, 0.25f, 0.5f, 0.75f, 1.0f});
}

TEST_CASE("Grade curves: neutral means no grade; validation") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 30, 0);
    fx.requireValid();
    ClipGrade grade;
    grade[GradeCurve::Green] = kLifted;
    CHECK_FALSE(grade.isNeutral());
    CHECK_FALSE(grade == ClipGrade{});
    fx.sequence().findClip(v)->grade[GradeCurve::Blue] = CurvePoints{{0.0, 0.0}, {1.0, 1.0}};
    CHECK(problemOf(fx.project).find("grade Blue curve: an identity curve is stored without points") != std::string::npos);
    fx.sequence().findClip(v)->grade[GradeCurve::Blue] = CurvePoints{{0.5, 0.2}};
    CHECK(problemOf(fx.project).find("grade Blue curve: a curve has 2 to 16 points (not 1)") != std::string::npos);
    fx.sequence().findClip(v)->grade = ClipGrade{};
    fx.sequence().findClip(a)->grade[GradeCurve::Luma] = kSCurve;
    CHECK(problemOf(fx.project).find("a clip on an audio track has no grade") != std::string::npos);
}

TEST_CASE("Grade curves: the project file") {
    CurveClips fx;
    CHECK(gradeJsonOf(fx.project, fx.a) ==
          json{{"curveLuma", json::array({json::array({0.0, 0.0}), json::array({0.25, 0.18}), json::array({0.75, 0.84}),
                                          json::array({1.0, 1.0})})}});
    CHECK(gradeJsonOf(fx.project, fx.b) == json{{"curveRed", json::array({json::array({0.0, 0.1}), json::array({1.0, 0.95})})}});
    const ProjectLoadResult loaded = parseProject(serializeProject(fx.project));
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == fx.project);
    CHECK(serializeProject(*loaded.project) == serializeProject(fx.project));

    SUBCASE("an identity curve in the file becomes none, silently") {
        const ProjectLoadResult identity = projectFromJson(
            withGrade(fx.project, fx.b, json{{"curveGreen", json::array({json::array({0, 0}), json::array({1, 1})})}}));
        REQUIRE(identity.ok());
        CHECK(identity.warnings.empty());
        CHECK(identity.project->sequences[0].findClip(fx.b)->grade.isEmpty());
    }
    SUBCASE("a curve that is not valid is repaired, with a warning") {
        const json bad = json::array({json::array({0.8, 1.5}), json::array({0.2, 0.1}), json::array({0.2, 0.9})});
        const ProjectLoadResult repaired = projectFromJson(withGrade(fx.project, fx.b, json{{"curveBlue", bad}}));
        REQUIRE_MESSAGE(repaired.ok(), doctest::String(repaired.error.c_str()));
        REQUIRE(repaired.warnings.size() == 1);
        CHECK(repaired.warnings[0].find("grade.curveBlue: the Blue curve's points are not a valid curve") !=
              std::string::npos);
        CHECK(repaired.warnings[0].find("kept 2 of 3, sorted and limited to [0, 1]") != std::string::npos);
        CHECK(repaired.project->sequences[0].findClip(fx.b)->grade[GradeCurve::Blue] ==
              CurvePoints{{0.2, 0.1}, {0.8, 1.0}});
    }
    SUBCASE("a malformed curve fails the load with its path") {
        for (const json &malformed : {json("steep"), json::array({json::array({0.1, 0.2, 0.3})}),
                                      json::array({json::array({"a", 0.2}), json::array({1, 1})})}) {
            const ProjectLoadResult refused = projectFromJson(withGrade(fx.project, fx.b, json{{"curveLuma", malformed}}));
            REQUIRE_FALSE(refused.ok());
            CHECK(refused.error.find("grade.curveLuma") != std::string::npos);
        }
    }
}

TEST_CASE("Grade curves: SetClipGrade sets a curve and keeps the rest") {
    CurveClips fx;
    SUBCASE("one curve on several clips; an identity is stored as none") {
        SetClipGrade command(fx.seq, {fx.a, fx.b}, GradeChange::of(GradeCurve::Green, kLifted));
        CHECK(command.name() == "Change Green Curve");
        applyReversible(fx.project, command);
        CHECK(fx.grade(fx.a)[GradeCurve::Green] == kLifted);
        CHECK(fx.grade(fx.b)[GradeCurve::Green] == kLifted);
        CHECK(fx.grade(fx.a)[GradeCurve::Luma] == kSCurve); // kept
        CHECK(fx.grade(fx.b)[GradeCurve::Red] == kLifted);
        SetClipGrade identity(fx.seq, {fx.a}, GradeChange::of(GradeCurve::Luma, CurvePoints{{0, 0}, {0.5, 0.5}, {1, 1}}));
        applyReversible(fx.project, identity);
        CHECK(fx.grade(fx.a)[GradeCurve::Luma].empty());
    }
    SUBCASE("a whole grade and Reset carry the curves") {
        SetClipGrade paste(fx.seq, {fx.b}, GradeChange::whole(fx.grade(fx.a)), "Paste Grade");
        applyReversible(fx.project, paste);
        CHECK(fx.grade(fx.b) == fx.grade(fx.a));
        CHECK(fx.grade(fx.b)[GradeCurve::Red].empty());
        SetClipGrade reset(fx.seq, {fx.a, fx.b}, GradeChange::whole(ClipGrade{}), "Reset Grade");
        applyReversible(fx.project, reset);
        CHECK(fx.grade(fx.a).isEmpty());
    }
    SUBCASE("refusals change nothing") {
        for (const CurvePoints &bad : {CurvePoints{{0.5, 0.5}}, CurvePoints{{0, 0}, {0, 1}}, CurvePoints{{0, 0}, {1, 2}}}) {
            SetClipGrade command(fx.seq, {fx.a}, GradeChange::of(GradeCurve::Blue, bad));
            const EditResult r = applyRefused(fx.project, command, EditError::InvalidArgument);
            CHECK(r.message.find("The Blue curve is not valid") != std::string::npos);
        }
    }
}

TEST_CASE("Grade curves: the selection's agreement and mixed") {
    CurveClips fx;
    const GradeSummary both = summarizeGrades(fx.sequence(), {fx.a, fx.sound, fx.b});
    CHECK(both.isMixed(GradeCurve::Luma));
    CHECK(both.isMixed(GradeCurve::Red));
    CHECK_FALSE(both.isMixed(GradeCurve::Blue));
    CHECK(both.valueOf(GradeCurve::Blue) == CurvePoints{});
    CHECK_FALSE(both.valueOf(GradeCurve::Luma).has_value());
    CHECK(summarizeGrades(fx.sequence(), {fx.a}).valueOf(GradeCurve::Luma) == kSCurve);
    fx.sequence().findClip(fx.b)->grade = fx.grade(fx.a);
    CHECK(summarizeGrades(fx.sequence(), {fx.a, fx.b}).identical);
    fx.sequence().findClip(fx.b)->grade[GradeCurve::Green] = kLifted;
    CHECK_FALSE(summarizeGrades(fx.sequence(), {fx.a, fx.b}).identical);
    fx.sequence().findClip(fx.a)->grade = ClipGrade{};
    fx.sequence().findClip(fx.a)->grade[GradeCurve::Red] = kLifted;
    CHECK(summarizeGrades(fx.sequence(), {fx.a}).anyGraded);
}
