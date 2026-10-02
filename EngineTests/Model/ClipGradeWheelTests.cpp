// The colour wheels of a clip's grade (ClipGrade.h, slice 2): the wheel table, a wheel's validity and
// limiting, neutral means no grade, validation; the project file (flat keys written only when not zero,
// read back exactly; a wheel outside its range limited with a warning; a non-number refused; slice 1's
// unknown keys "lift" and "curves" stay unknown); SetClipGrade with wheels (one or several clips, the
// others' values kept, refusals, names, a whole grade and Reset carry them, a drag coalesces into one undo
// step); the selection's agreement and "mixed" per wheel, and identical grades.

#include "ModelFixtures.h"

#include "../../Engine/Edit/GradeEdits.h"
#include "../../Engine/Edit/UndoStack.h"

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

struct WheelClips : Fixture {
    ClipId a, b, sound;
    WheelClips() {
        std::tie(a, sound) = addLinkedPair(0, 30, 0);
        b = addClip(v1, av30, 30, 30, 60);
        sequence().findClip(a)->grade[GradeWheel::Lift] = WheelValue{0.2, 0.1, -0.1};
        sequence().findClip(a)->grade[GradeParameter::Exposure] = 0.5;
        sequence().findClip(b)->grade[GradeWheel::Gain] = WheelValue{-0.3, 0.0, 0.0};
        requireValid();
    }
    const ClipGrade &grade(ClipId id) const {
        return clip(id).grade;
    }
};

} // namespace

TEST_CASE("Grade wheels: the table, validity and limiting") {
    CHECK(kGradeWheelCount == 3);
    CHECK(std::string(nameOf(GradeWheel::Lift)) == "lift");
    CHECK(std::string(nameOf(GradeWheel::Gamma)) == "gamma");
    CHECK(std::string(nameOf(GradeWheel::Gain)) == "gain");
    CHECK(std::string(displayNameOf(GradeWheel::Gamma)) == "Gamma");
    CHECK(std::string(infoOf(GradeWheel::Gain).tonalRange) == "highlights");
    CHECK(gradeWheelNamed("gamma") == GradeWheel::Gamma);
    CHECK_FALSE(gradeWheelNamed("Lift").has_value());
    CHECK(&infoOf(static_cast<GradeWheel>(9)) == &infoOf(GradeWheel::Lift));
    // The slice 1 table is unchanged: "lift" is no basic parameter.
    CHECK_FALSE(gradeParameterNamed("lift").has_value());

    CHECK(isValidWheel(WheelValue{}));
    CHECK(isValidWheel(WheelValue{1.0, 0.0, 1.0}));
    CHECK(isValidWheel(WheelValue{-1.0, std::sqrt(0.5), -std::sqrt(0.5)}));
    CHECK_FALSE(isValidWheel(WheelValue{1.01, 0, 0}));
    CHECK_FALSE(isValidWheel(WheelValue{0, 0.8, 0.8}));
    CHECK_FALSE(isValidWheel(WheelValue{std::numeric_limits<double>::quiet_NaN(), 0, 0}));
    CHECK_FALSE(isValidWheel(WheelValue{0, std::numeric_limits<double>::infinity(), 0}));
    const WheelValue limited = clampWheel(WheelValue{3.0, 3.0, 4.0});
    CHECK(limited.level == 1.0);
    CHECK(limited.cb == doctest::Approx(0.6));
    CHECK(limited.cr == doctest::Approx(0.8));
    CHECK(isValidWheel(limited));
    const WheelValue cleaned = clampWheel(WheelValue{std::numeric_limits<double>::quiet_NaN(), -0.5, 0.25});
    CHECK(cleaned.level == 0.0);
    CHECK(cleaned.cb == -0.5);
}

TEST_CASE("Grade wheels: neutral means no grade; validation") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 30, 0);
    fx.requireValid();
    for (const GradeWheel wheel : kGradeWheels) {
        ClipGrade grade;
        grade[wheel].cr = 0.25;
        CHECK_FALSE(grade.isNeutral());
        CHECK_FALSE(grade.isEmpty());
        CHECK_FALSE(grade == ClipGrade{});
    }
    fx.sequence().findClip(v)->grade[GradeWheel::Gamma] = WheelValue{0.0, 0.9, 0.5};
    CHECK(problemOf(fx.project).find("grade Gamma wheel (level 0, colour 0.9, 0.5) is outside its range") !=
          std::string::npos);
    fx.sequence().findClip(v)->grade = ClipGrade{};
    fx.sequence().findClip(a)->grade[GradeWheel::Lift].level = 0.5;
    CHECK(problemOf(fx.project).find("a clip on an audio track has no grade") != std::string::npos);
}

TEST_CASE("Grade wheels: the project file") {
    WheelClips fx;
    // Only the members that are not zero, as flat keys beside the basic values.
    CHECK(gradeJsonOf(fx.project, fx.a) ==
          json{{"exposure", 0.5}, {"liftLevel", 0.2}, {"liftCb", 0.1}, {"liftCr", -0.1}});
    CHECK(gradeJsonOf(fx.project, fx.b) == json{{"gainLevel", -0.3}});
    const ProjectLoadResult loaded = parseProject(serializeProject(fx.project));
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == fx.project);
    CHECK(serializeProject(*loaded.project) == serializeProject(fx.project));
    // Every wheel at its extremes round trips exactly.
    for (const GradeWheel wheel : kGradeWheels) {
        for (const WheelValue value : {WheelValue{-1.0, -1.0, 0.0}, WheelValue{1.0, 0.0, 1.0},
                                       WheelValue{0.123456789, -0.6, 0.8}}) {
            Project project = fx.project;
            project.sequences[0].findClip(fx.b)->grade[wheel] = value;
            const ProjectLoadResult again = parseProject(serializeProject(project));
            REQUIRE(again.ok());
            CHECK(*again.project == project);
        }
    }

    SUBCASE("a wheel outside its range is limited, with a warning") {
        const ProjectLoadResult limited = projectFromJson(
            withGrade(fx.project, fx.b, json{{"gainLevel", 2.5}, {"gammaCb", 3.0}, {"gammaCr", 4.0}}));
        REQUIRE_MESSAGE(limited.ok(), doctest::String(limited.error.c_str()));
        REQUIRE(limited.warnings.size() == 2);
        CHECK(limited.warnings[0].find("the Gamma wheel (level 0, colour 3, 4) is outside its range; limited to level "
                                       "0, colour 0.6") != std::string::npos);
        CHECK(limited.warnings[1].find("the Gain wheel (level 2.5") != std::string::npos);
        const ClipGrade &grade = limited.project->sequences[0].findClip(fx.b)->grade;
        CHECK(grade[GradeWheel::Gain].level == 1.0);
        CHECK(grade[GradeWheel::Gamma].cb == doctest::Approx(0.6));
        CHECK(grade[GradeWheel::Gamma].cr == doctest::Approx(0.8));
    }
    SUBCASE("a value that is not a number fails the load with its path") {
        const ProjectLoadResult refused = projectFromJson(withGrade(fx.project, fx.b, json{{"liftCr", "red"}}));
        REQUIRE_FALSE(refused.ok());
        CHECK(refused.error.find("grade.liftCr") != std::string::npos);
    }
    SUBCASE("slice 1's examples of a newer version's keys stay unknown and are kept") {
        const json grade = {{"liftLevel", 0.25}, {"lift", json::array({0.1, 0.0, 0.0})}, {"curves", {{"r", 1}}}};
        const ProjectLoadResult kept = projectFromJson(withGrade(fx.project, fx.b, grade));
        REQUIRE(kept.ok());
        CHECK(kept.warnings.size() == 2);
        const ClipGrade &keptGrade = kept.project->sequences[0].findClip(fx.b)->grade;
        CHECK(keptGrade[GradeWheel::Lift].level == 0.25);
        CHECK(keptGrade.foreign == R"({"curves":{"r":1},"lift":[0.1,0.0,0.0]})");
        CHECK(gradeJsonOf(*kept.project, fx.b) == grade);
    }
}

TEST_CASE("Grade wheels: SetClipGrade sets a wheel and keeps the rest") {
    WheelClips fx;
    SUBCASE("one wheel on several clips") {
        SetClipGrade command(fx.seq, {fx.a, fx.b}, GradeChange::of(GradeWheel::Gamma, WheelValue{0.4, 0.0, 0.3}));
        CHECK(command.name() == "Change Gamma");
        applyReversible(fx.project, command);
        for (const ClipId id : {fx.a, fx.b}) {
            CHECK(fx.grade(id)[GradeWheel::Gamma] == WheelValue{0.4, 0.0, 0.3});
        }
        CHECK(fx.grade(fx.a)[GradeWheel::Lift] == WheelValue{0.2, 0.1, -0.1}); // kept
        CHECK(fx.grade(fx.a)[GradeParameter::Exposure] == 0.5);
        CHECK(fx.grade(fx.b)[GradeWheel::Gain] == WheelValue{-0.3, 0.0, 0.0});
    }
    SUBCASE("the colour alone keeps each clip's level; the level alone keeps each colour") {
        SetClipGrade colour(fx.seq, {fx.a, fx.b}, GradeChange::of(GradeWheel::Lift, WheelChange{std::nullopt, 0.0, 0.6}));
        CHECK(colour.name() == "Change Lift");
        applyReversible(fx.project, colour);
        CHECK(fx.grade(fx.a)[GradeWheel::Lift] == WheelValue{0.2, 0.0, 0.6});
        CHECK(fx.grade(fx.b)[GradeWheel::Lift] == WheelValue{0.0, 0.0, 0.6});
        SetClipGrade level(fx.seq, {fx.a, fx.b}, GradeChange::of(GradeWheel::Lift, WheelChange{-0.5, {}, {}}));
        applyReversible(fx.project, level);
        CHECK(fx.grade(fx.a)[GradeWheel::Lift] == WheelValue{-0.5, 0.0, 0.6});
        CHECK(fx.grade(fx.b)[GradeWheel::Lift] == WheelValue{-0.5, 0.0, 0.6});
        // Only one of cb and cr: refused.
        SetClipGrade half(fx.seq, {fx.a}, GradeChange::of(GradeWheel::Gain, WheelChange{std::nullopt, 0.3, std::nullopt}));
        applyRefused(fx.project, half, EditError::InvalidArgument);
    }
    SUBCASE("a wheel and a value together, and a whole grade") {
        GradeChange change = GradeChange::of(GradeWheel::Lift, WheelValue{});
        change[GradeParameter::Contrast] = 1.2;
        SetClipGrade both(fx.seq, {fx.a}, change);
        CHECK(both.name() == "Change Grade");
        applyReversible(fx.project, both);
        CHECK(fx.grade(fx.a)[GradeWheel::Lift].isNeutral());
        SetClipGrade paste(fx.seq, {fx.a}, GradeChange::whole(fx.grade(fx.b)), "Paste Grade");
        applyReversible(fx.project, paste);
        CHECK(fx.grade(fx.a) == fx.grade(fx.b));
        SetClipGrade reset(fx.seq, {fx.a, fx.b}, GradeChange::whole(ClipGrade{}), "Reset Grade");
        applyReversible(fx.project, reset);
        CHECK(fx.grade(fx.b).isEmpty());
    }
    SUBCASE("refusals change nothing") {
        for (const WheelValue bad : {WheelValue{1.5, 0, 0}, WheelValue{0, 0.9, 0.9},
                                     WheelValue{std::numeric_limits<double>::quiet_NaN(), 0, 0}}) {
            SetClipGrade command(fx.seq, {fx.a}, GradeChange::of(GradeWheel::Gain, bad));
            const EditResult r = applyRefused(fx.project, command, EditError::InvalidArgument);
            CHECK(r.message.find("The Gain wheel's level must be a number from -1 to 1") != std::string::npos);
        }
        SetClipGrade sound(fx.seq, {fx.sound}, GradeChange::of(GradeWheel::Lift, WheelValue{0.1, 0, 0}));
        applyRefused(fx.project, sound, EditError::TrackKindMismatch);
    }
    SUBCASE("setting what a clip has records no step") {
        UndoStack stack;
        const EditResult r = stack.push(
            fx.project, std::make_unique<SetClipGrade>(fx.seq, std::vector<ClipId>{fx.b},
                                                       GradeChange::of(GradeWheel::Gain, WheelValue{-0.3, 0.0, 0.0})));
        CHECK(r.ok());
        CHECK_FALSE(stack.canUndo());
    }
    SUBCASE("a wheel drag is one undo step") {
        UndoStack stack;
        stack.beginCoalescing("lift drag", CoalesceMode::ReplacePrevious);
        for (const double cr : {0.1, 0.2, 0.35, 0.5}) {
            auto command = std::make_unique<SetClipGrade>(fx.seq, std::vector<ClipId>{fx.a, fx.b},
                                                          GradeChange::of(GradeWheel::Lift, WheelValue{0.0, 0.0, cr}));
            command->setCoalescingKey("lift drag");
            REQUIRE(stack.push(fx.project, std::move(command)).ok());
        }
        stack.endCoalescing();
        CHECK(fx.grade(fx.b)[GradeWheel::Lift].cr == 0.5);
        CHECK(stack.undoCount() == 1);
        CHECK(stack.undoName() == "Change Lift");
        REQUIRE(stack.undo(fx.project));
        CHECK_FALSE(stack.canUndo());
        CHECK(fx.grade(fx.a)[GradeWheel::Lift] == WheelValue{0.2, 0.1, -0.1});
        CHECK(fx.grade(fx.b)[GradeWheel::Lift].isNeutral());
    }
}

TEST_CASE("Grade wheels: the selection's agreement, mixed and identical grades") {
    WheelClips fx;
    const GradeSummary one = summarizeGrades(fx.sequence(), {fx.a});
    CHECK(one.valueOf(GradeWheel::Lift) == WheelValue{0.2, 0.1, -0.1});
    CHECK_FALSE(one.isMixed(GradeWheel::Lift));
    const GradeSummary both = summarizeGrades(fx.sequence(), {fx.a, fx.sound, fx.b});
    CHECK(both.isMixed(GradeWheel::Lift));
    CHECK_FALSE(both.valueOf(GradeWheel::Lift).has_value());
    CHECK(both.isMixed(GradeWheel::Gain));
    CHECK_FALSE(both.isMixed(GradeWheel::Gamma));
    CHECK(both.valueOf(GradeWheel::Gamma) == WheelValue{});
    CHECK_FALSE(both.identical);
    // Equal values but a different wheel: not identical.
    fx.sequence().findClip(fx.b)->grade = fx.grade(fx.a);
    CHECK(summarizeGrades(fx.sequence(), {fx.a, fx.b}).identical);
    fx.sequence().findClip(fx.b)->grade[GradeWheel::Gamma].level = 0.01;
    CHECK_FALSE(summarizeGrades(fx.sequence(), {fx.a, fx.b}).identical);
    const GradeSummary none = summarizeGrades(fx.sequence(), {fx.sound});
    for (const GradeWheel wheel : kGradeWheels) {
        CHECK_FALSE(none.valueOf(wheel).has_value());
        CHECK_FALSE(none.isMixed(wheel));
    }
    // A clip graded by a wheel alone counts as graded.
    fx.sequence().findClip(fx.a)->grade = ClipGrade{};
    fx.sequence().findClip(fx.a)->grade[GradeWheel::Gain].cb = 0.2;
    CHECK(summarizeGrades(fx.sequence(), {fx.a}).anyGraded);
}
