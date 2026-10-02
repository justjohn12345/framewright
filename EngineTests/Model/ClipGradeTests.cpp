// A clip's grade in the model (ClipGrade.h): the parameter table, "neutral means no grade", validation,
// the project file (written only when there is a grade; unknown grade keys kept; out-of-range values
// limited), and the edits that must carry it (a split, the through-edit rule).

#include "ModelFixtures.h"

#include <cmath>
#include <limits>

using namespace vetest;
using nlohmann::json;

namespace {

bool anyContains(const std::vector<std::string> &list, const std::string &needle) {
    for (const std::string &s : list) {
        if (s.find(needle) != std::string::npos) {
            return true;
        }
    }
    return false;
}

// The JSON of clip `id` in the project's file.
json clipJson(const Project &project, ClipId id) {
    const json document = projectToJson(project);
    for (const json &sequence : document.at("sequences")) {
        for (const char *kind : {"videoTracks", "audioTracks"}) {
            for (const json &track : sequence.at(kind)) {
                for (const json &clip : track.at("clips")) {
                    if (clip.at("id") == id.value()) {
                        return clip;
                    }
                }
            }
        }
    }
    FAIL("clip not in the file");
    return json();
}

// The file of `fx` with `grade` written into clip `id`'s object.
json withGradeJson(const Fixture &fx, ClipId id, const json &grade) {
    json document = projectToJson(fx.project);
    for (json &sequence : document.at("sequences")) {
        for (const char *kind : {"videoTracks", "audioTracks"}) {
            for (json &track : sequence.at(kind)) {
                for (json &clip : track.at("clips")) {
                    if (clip.at("id") == id.value()) {
                        clip["grade"] = grade;
                    }
                }
            }
        }
    }
    return document;
}

} // namespace

TEST_CASE("ClipGrade: the parameter table") {
    struct Row {
        GradeParameter parameter;
        const char *name;
        const char *displayName;
        const char *unit;
        double neutral, minimum, maximum;
    };
    const Row rows[] = {
        {GradeParameter::Exposure, "exposure", "Exposure", "stops", 0.0, -5.0, 5.0},
        {GradeParameter::Contrast, "contrast", "Contrast", "×", 1.0, 0.0, 2.0},
        {GradeParameter::Temperature, "temperature", "Temperature", "", 0.0, -100.0, 100.0},
        {GradeParameter::Tint, "tint", "Tint", "", 0.0, -100.0, 100.0},
        {GradeParameter::Saturation, "saturation", "Saturation", "×", 1.0, 0.0, 2.0},
    };
    REQUIRE(std::size(rows) == kGradeParameterCount);
    for (std::size_t i = 0; i < kGradeParameterCount; ++i) {
        const Row &row = rows[i];
        CAPTURE(row.name);
        CHECK(kGradeParameters[i] == row.parameter);
        const GradeParameterInfo &info = infoOf(row.parameter);
        CHECK(info.parameter == row.parameter);
        CHECK(std::string(nameOf(row.parameter)) == row.name);
        CHECK(std::string(displayNameOf(row.parameter)) == row.displayName);
        CHECK(std::string(unitOf(row.parameter)) == row.unit);
        CHECK(neutralValue(row.parameter) == row.neutral);
        CHECK(info.minimum == row.minimum);
        CHECK(info.maximum == row.maximum);
        CHECK(gradeParameterNamed(row.name) == row.parameter);
        CHECK(ClipGrade{}[row.parameter] == row.neutral);
        // The range is closed; outside it, NaN and the infinities are not valid.
        CHECK(isValidGradeValue(row.parameter, row.minimum));
        CHECK(isValidGradeValue(row.parameter, row.maximum));
        CHECK(isValidGradeValue(row.parameter, row.neutral));
        CHECK_FALSE(isValidGradeValue(row.parameter, std::nextafter(row.minimum, -1e9)));
        CHECK_FALSE(isValidGradeValue(row.parameter, std::nextafter(row.maximum, 1e9)));
        CHECK_FALSE(isValidGradeValue(row.parameter, std::numeric_limits<double>::quiet_NaN()));
        CHECK_FALSE(isValidGradeValue(row.parameter, std::numeric_limits<double>::infinity()));
        CHECK(clampGradeValue(row.parameter, -1e9) == row.minimum);
        CHECK(clampGradeValue(row.parameter, 1e9) == row.maximum);
        CHECK(clampGradeValue(row.parameter, std::numeric_limits<double>::quiet_NaN()) == row.neutral);
        CHECK(clampGradeValue(row.parameter, row.neutral) == row.neutral);
    }
    CHECK_FALSE(gradeParameterNamed("lift").has_value());
    CHECK_FALSE(gradeParameterNamed("Exposure").has_value());
    // Outside the enum: the first row, never out of bounds.
    CHECK(&infoOf(static_cast<GradeParameter>(99)) == &infoOf(GradeParameter::Exposure));
}

TEST_CASE("ClipGrade: neutral means no grade") {
    ClipGrade grade;
    CHECK(grade.isNeutral());
    CHECK(grade.isEmpty());
    for (const GradeParameter parameter : kGradeParameters) {
        CAPTURE(nameOf(parameter));
        ClipGrade changed;
        changed[parameter] = parameter == GradeParameter::Contrast || parameter == GradeParameter::Saturation ? 0.5 : 1.0;
        CHECK_FALSE(changed.isNeutral());
        CHECK_FALSE(changed.isEmpty());
        CHECK_FALSE(changed == grade);
    }
    grade[GradeParameter::Exposure] = -0.0; // -0 is the neutral value too
    CHECK(grade.isNeutral());
    grade.foreign = R"({"lift":[0.1,0,0]})";
    CHECK(grade.isNeutral()); // this version does not apply what it does not know
    CHECK_FALSE(grade.isEmpty());
}

TEST_CASE("ClipGrade: validation") {
    ClipGrade grade;
    CHECK_FALSE(gradeProblem(grade).has_value());
    grade[GradeParameter::Saturation] = 2.5;
    CHECK(gradeProblem(grade) == "grade Saturation 2.5 is outside its range [0, 2]");
    grade[GradeParameter::Saturation] = 1.0;
    grade[GradeParameter::Exposure] = std::numeric_limits<double>::quiet_NaN();
    CHECK(gradeProblem(grade) == "grade Exposure nan is outside its range [-5, 5]");

    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 30, 0);
    fx.sequence().findClip(v)->grade[GradeParameter::Temperature] = -100.0;
    fx.requireValid();
    fx.sequence().findClip(v)->grade[GradeParameter::Temperature] = -101.0;
    CHECK(problemOf(fx.project).find("grade Temperature -101 is outside its range [-100, 100]") != std::string::npos);
    fx.sequence().findClip(v)->grade = ClipGrade{};
    fx.sequence().findClip(a)->grade[GradeParameter::Exposure] = 1.0;
    CHECK(problemOf(fx.project).find("a clip on an audio track has no grade") != std::string::npos);
    fx.sequence().findClip(a)->grade = ClipGrade{};
    fx.sequence().findClip(a)->grade.foreign = R"({"lift":1})";
    CHECK(problemOf(fx.project).find("a clip on an audio track has no grade") != std::string::npos);
}

TEST_CASE("ClipGrade: the project file writes a grade only when there is one") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 30, 0);
    const ClipId still = fx.addClip(fx.v2, fx.still, 0, 30);
    fx.requireValid();
    // No grade: no "grade" key, so a clip writes what version 7 wrote.
    CHECK_FALSE(clipJson(fx.project, v).contains("grade"));
    CHECK_FALSE(clipJson(fx.project, a).contains("grade"));

    ClipGrade &grade = fx.sequence().findClip(v)->grade;
    grade[GradeParameter::Exposure] = 1.5;
    grade[GradeParameter::Tint] = -12.25;
    fx.sequence().findClip(still)->grade[GradeParameter::Saturation] = 0.0;
    fx.requireValid();
    CHECK(clipJson(fx.project, v).at("grade") == json{{"exposure", 1.5}, {"tint", -12.25}});
    CHECK(clipJson(fx.project, still).at("grade") == json{{"saturation", 0.0}});

    const ProjectLoadResult loaded = parseProject(serializeProject(fx.project));
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == fx.project);
    CHECK(serializeProject(*loaded.project) == serializeProject(fx.project));

    // Every parameter at both ends of its range round trips exactly.
    for (const GradeParameter parameter : kGradeParameters) {
        for (const double value : {infoOf(parameter).minimum, infoOf(parameter).maximum}) {
            Project project = fx.project;
            project.sequences[0].findClip(v)->grade[parameter] = value;
            const ProjectLoadResult again = parseProject(serializeProject(project));
            REQUIRE(again.ok());
            CHECK(*again.project == project);
        }
    }
}

TEST_CASE("ClipGrade: a newer version's grade parameters are kept; bad values are limited or refused") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 30, 0);
    fx.requireValid();

    SUBCASE("an unknown parameter is kept and written back, with a warning") {
        const json grade = {{"exposure", 0.5}, {"lift", json::array({0.1, 0.0, 0.0})}, {"curves", {{"r", 1}}}};
        const ProjectLoadResult loaded = projectFromJson(withGradeJson(fx, v, grade));
        REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
        REQUIRE(loaded.warnings.size() == 2);
        CHECK(loaded.warnings[0] ==
              "sequences[0].videoTracks[0].clips[0].grade.curves: unknown grade parameter \"curves\" (from a newer "
              "version of Framewright?); kept as it is and saved with the project, but not applied or editable");
        CHECK(anyContains(loaded.warnings, "grade.lift: unknown grade parameter \"lift\""));
        const Clip &clip = *loaded.project->sequences[0].findClip(v);
        CHECK(clip.grade[GradeParameter::Exposure] == 0.5);
        CHECK(clip.grade.foreign == R"({"curves":{"r":1},"lift":[0.1,0.0,0.0]})");
        CHECK(clipJson(*loaded.project, v).at("grade") == grade);
        // Alone (every known value neutral) it is still written back.
        Project project = *loaded.project;
        project.sequences[0].findClip(v)->grade[GradeParameter::Exposure] = 0.0;
        CHECK(clipJson(project, v).at("grade") == json{{"lift", json::array({0.1, 0.0, 0.0})}, {"curves", {{"r", 1}}}});
    }
    SUBCASE("a value outside its range is limited to it, with a warning") {
        const ProjectLoadResult loaded =
            projectFromJson(withGradeJson(fx, v, json{{"saturation", 9}, {"exposure", -7.5}}));
        REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
        REQUIRE(loaded.warnings.size() == 2);
        CHECK(loaded.warnings[0] == "sequences[0].videoTracks[0].clips[0].grade.exposure: Exposure -7.5 is outside its "
                                    "range [-5.0, 5.0]; limited to -5.0");
        CHECK(loaded.warnings[1] == "sequences[0].videoTracks[0].clips[0].grade.saturation: Saturation 9 is outside "
                                    "its range [0.0, 2.0]; limited to 2.0");
        const Clip &clip = *loaded.project->sequences[0].findClip(v);
        CHECK(clip.grade[GradeParameter::Saturation] == 2.0);
        CHECK(clip.grade[GradeParameter::Exposure] == -5.0);
    }
    SUBCASE("a value that is not a number fails the load with its path") {
        const ProjectLoadResult loaded = projectFromJson(withGradeJson(fx, v, json{{"contrast", "high"}}));
        REQUIRE_FALSE(loaded.ok());
        CHECK(loaded.error.find("sequences[0].videoTracks[0].clips[0].grade.contrast") == 0);
    }
    SUBCASE("a grade that is not an object fails the load with its path") {
        const ProjectLoadResult loaded = projectFromJson(withGradeJson(fx, v, json::array({1, 2})));
        REQUIRE_FALSE(loaded.ok());
        CHECK(loaded.error == "sequences[0].videoTracks[0].clips[0].grade: expected an object, found array");
    }
    SUBCASE("a grade on a clip of an audio track is dropped, with a warning") {
        const ProjectLoadResult loaded = projectFromJson(withGradeJson(fx, a, json{{"exposure", 1}}));
        REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
        REQUIRE(loaded.warnings.size() == 1);
        CHECK(loaded.warnings[0] ==
              "sequences[0].audioTracks[0].clips[0].grade: a clip on an audio track has no grade; dropped");
        CHECK(loaded.project->sequences[0].findClip(a)->grade.isEmpty());
    }
}

TEST_CASE("ClipGrade: a split keeps the grade on both pieces; a through edit needs equal grades") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 60, 0);
    ClipGrade grade;
    grade[GradeParameter::Contrast] = 1.4;
    grade[GradeParameter::Temperature] = 25.0;
    fx.sequence().findClip(v)->grade = grade;
    fx.requireValid();
    SplitClip split(fx.seq, v, f30(20));
    applyReversible(fx.project, split);
    REQUIRE(split.createdClipIds().size() == 2);
    const ClipId right = split.createdClipIds()[0];
    CHECK(fx.clip(v).grade == grade);
    CHECK(fx.clip(right).grade == grade);
    CHECK(fx.clip(split.createdClipIds()[1]).grade.isEmpty()); // the sound's piece has none
    CHECK(isThroughEdit(fx.sequence(), v, right));
    fx.sequence().findClip(right)->grade[GradeParameter::Contrast] = 1.5;
    CHECK_FALSE(isThroughEdit(fx.sequence(), v, right));
}
