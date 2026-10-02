// Grade edits (GradeEdits.h): SetClipGrade on one or several clips (only the parameters given; a
// whole grade for Paste and Reset), its refusals, no-op and undo, coalescing a control drag into one
// undo step, and the selection questions (summarizeGrades, gradeTargets).

#include "../Model/ModelFixtures.h"

#include "../../Engine/Edit/GradeEdits.h"
#include "../../Engine/Edit/UndoStack.h"

#include <limits>

using namespace vetest;

namespace {

// V1: three clips with different exposures and one temperature; A1: the first clip's sound.
struct GradedClips : Fixture {
    ClipId a, b, c, sound;
    GradedClips() {
        std::tie(a, sound) = addLinkedPair(0, 30, 0);
        b = addClip(v1, av30, 30, 30, 60);
        c = addClip(v2, still, 0, 90);
        sequence().findClip(a)->grade[GradeParameter::Exposure] = 1.0;
        sequence().findClip(b)->grade[GradeParameter::Exposure] = -0.5;
        sequence().findClip(b)->grade[GradeParameter::Temperature] = 30.0;
        sequence().findClip(b)->grade.foreign = R"({"lift":[0.1,0.0,0.0]})";
        requireValid();
    }
    const ClipGrade &grade(ClipId id) const {
        return clip(id).grade;
    }
};

} // namespace

TEST_CASE("Grade edits: SetClipGrade sets only the parameters given") {
    GradedClips fx;
    SUBCASE("one parameter on one clip") {
        SetClipGrade command(fx.seq, {fx.a}, GradeChange::of(GradeParameter::Contrast, 1.3));
        CHECK(command.name() == "Change Contrast");
        applyReversible(fx.project, command);
        CHECK(fx.grade(fx.a)[GradeParameter::Contrast] == 1.3);
        CHECK(fx.grade(fx.a)[GradeParameter::Exposure] == 1.0); // kept
        CHECK(fx.grade(fx.b)[GradeParameter::Contrast] == 1.0); // another clip untouched
    }
    SUBCASE("one parameter on several clips keeps what differs between them") {
        SetClipGrade command(fx.seq, {fx.a, fx.b, fx.c}, GradeChange::of(GradeParameter::Saturation, 0.25));
        applyReversible(fx.project, command);
        for (const ClipId id : {fx.a, fx.b, fx.c}) {
            CHECK(fx.grade(id)[GradeParameter::Saturation] == 0.25);
        }
        CHECK(fx.grade(fx.a)[GradeParameter::Exposure] == 1.0);
        CHECK(fx.grade(fx.b)[GradeParameter::Exposure] == -0.5);
        CHECK(fx.grade(fx.b)[GradeParameter::Temperature] == 30.0);
        CHECK(fx.grade(fx.c)[GradeParameter::Exposure] == 0.0);
        CHECK(fx.grade(fx.b).foreign == R"({"lift":[0.1,0.0,0.0]})"); // a newer version's entries stay
    }
    SUBCASE("several parameters at once") {
        GradeChange change;
        change[GradeParameter::Tint] = -40.0;
        change[GradeParameter::Exposure] = 0.0;
        SetClipGrade command(fx.seq, {fx.b}, change);
        CHECK(command.name() == "Change Grade");
        applyReversible(fx.project, command);
        CHECK(fx.grade(fx.b)[GradeParameter::Tint] == -40.0);
        CHECK(fx.grade(fx.b)[GradeParameter::Exposure] == 0.0);
        CHECK(fx.grade(fx.b)[GradeParameter::Temperature] == 30.0);
    }
    SUBCASE("a whole grade replaces every value and the foreign entries (Paste Grade)") {
        const ClipGrade copied = fx.grade(fx.b);
        SetClipGrade command(fx.seq, {fx.a, fx.c}, GradeChange::whole(copied), "Paste Grade");
        CHECK(command.name() == "Paste Grade");
        applyReversible(fx.project, command);
        CHECK(fx.grade(fx.a) == copied);
        CHECK(fx.grade(fx.c) == copied);
    }
    SUBCASE("the neutral grade removes the grade (Reset Grade)") {
        SetClipGrade command(fx.seq, {fx.a, fx.b}, GradeChange::whole(ClipGrade{}), "Reset Grade");
        applyReversible(fx.project, command);
        CHECK(fx.grade(fx.a).isEmpty());
        CHECK(fx.grade(fx.b).isEmpty()); // the foreign entries go too
    }
}

TEST_CASE("Grade edits: SetClipGrade refuses as a whole, changing nothing") {
    GradedClips fx;
    const double nan = std::numeric_limits<double>::quiet_NaN();
    SUBCASE("no clips") {
        SetClipGrade command(fx.seq, {}, GradeChange::of(GradeParameter::Tint, 1.0));
        CHECK(applyRefused(fx.project, command, EditError::InvalidArgument).message == "No clips to grade.");
    }
    SUBCASE("no values") {
        SetClipGrade command(fx.seq, {fx.a}, GradeChange{});
        CHECK(applyRefused(fx.project, command, EditError::InvalidArgument).message == "No grade values to set.");
    }
    SUBCASE("a value outside its range, NaN or infinite") {
        for (const double value : {2.5, -0.1, nan, std::numeric_limits<double>::infinity()}) {
            CAPTURE(value);
            SetClipGrade command(fx.seq, {fx.a}, GradeChange::of(GradeParameter::Saturation, value));
            const EditResult r = applyRefused(fx.project, command, EditError::InvalidArgument);
            CHECK(r.message.rfind("Saturation must be a number from 0 to 2 (not ", 0) == 0);
        }
    }
    SUBCASE("a clip on an audio track") {
        SetClipGrade command(fx.seq, {fx.a, fx.sound}, GradeChange::of(GradeParameter::Exposure, 2.0));
        const EditResult r = applyRefused(fx.project, command, EditError::TrackKindMismatch);
        CHECK(r.message.find("a grade applies to pictures") != std::string::npos);
    }
    SUBCASE("a clip on a locked track") {
        fx.track(fx.v2).locked = true;
        SetClipGrade command(fx.seq, {fx.a, fx.c}, GradeChange::of(GradeParameter::Exposure, 2.0));
        applyRefused(fx.project, command, EditError::TrackLocked);
    }
    SUBCASE("a missing clip, or one listed twice") {
        SetClipGrade missing(fx.seq, {fx.a, ClipId{999}}, GradeChange::of(GradeParameter::Exposure, 2.0));
        applyRefused(fx.project, missing, EditError::ClipNotFound);
        SetClipGrade twice(fx.seq, {fx.a, fx.a}, GradeChange::of(GradeParameter::Exposure, 2.0));
        applyRefused(fx.project, twice, EditError::InvalidArgument);
    }
}

TEST_CASE("Grade edits: a change that changes nothing records no undo step") {
    GradedClips fx;
    UndoStack stack;
    const auto result = stack.push(fx.project, std::make_unique<SetClipGrade>(
                                                   fx.seq, std::vector<ClipId>{fx.a, fx.c},
                                                   GradeChange::of(GradeParameter::Contrast, 1.0)));
    CHECK(result.ok());
    CHECK_FALSE(stack.canUndo());
    // Resetting clips without a grade: nothing either.
    CHECK(stack.push(fx.project, std::make_unique<SetClipGrade>(fx.seq, std::vector<ClipId>{fx.c},
                                                                GradeChange::whole(ClipGrade{}), "Reset Grade"))
              .ok());
    CHECK_FALSE(stack.canUndo());
}

TEST_CASE("Grade edits: a control drag over several clips is one undo step") {
    GradedClips fx;
    const Project start = fx.project;
    const std::vector<ClipId> clips{fx.a, fx.b};
    auto step = [&](double value) {
        return std::make_unique<SetClipGrade>(fx.seq, clips, GradeChange::of(GradeParameter::Exposure, value));
    };
    for (const CoalesceMode mode : {CoalesceMode::ReplacePrevious, CoalesceMode::Accumulate}) {
        CAPTURE(mode == CoalesceMode::Accumulate);
        UndoStack stack;
        stack.beginCoalescing("exposure drag", mode);
        for (const double value : {0.25, 0.5, 1.5, 2.0}) {
            auto command = step(value);
            command->setCoalescingKey("exposure drag");
            REQUIRE(stack.push(fx.project, std::move(command)).ok());
            CHECK(fx.grade(fx.a)[GradeParameter::Exposure] == value);
            CHECK(fx.grade(fx.b)[GradeParameter::Exposure] == value);
        }
        stack.endCoalescing();
        CHECK(stack.undoCount() == 1);
        CHECK(stack.undoName() == "Change Exposure");
        CHECK(fx.grade(fx.b)[GradeParameter::Temperature] == 30.0);
        REQUIRE(stack.undo(fx.project));
        CHECK(fx.project == start);
        REQUIRE(stack.redo(fx.project));
        CHECK(fx.grade(fx.a)[GradeParameter::Exposure] == 2.0);
        CHECK(fx.grade(fx.b)[GradeParameter::Exposure] == 2.0);
        REQUIRE(stack.undo(fx.project));
        CHECK(fx.project == start);
    }
}

TEST_CASE("Grade edits: a selection's values agree or are mixed") {
    GradedClips fx;
    SUBCASE("one clip") {
        const GradeSummary summary = summarizeGrades(fx.sequence(), {fx.a});
        CHECK(summary.clips == std::vector<ClipId>{fx.a});
        CHECK(summary.anyGraded);
        CHECK(summary.valueOf(GradeParameter::Exposure) == 1.0);
        for (const GradeParameter parameter : kGradeParameters) {
            CHECK_FALSE(summary.isMixed(parameter));
        }
    }
    SUBCASE("several clips: their sound and unknown ids are left out") {
        const GradeSummary summary = summarizeGrades(fx.sequence(), {fx.sound, fx.a, ClipId{999}, fx.b, fx.c, fx.a});
        CHECK(summary.clips == std::vector<ClipId>{fx.a, fx.b, fx.c});
        CHECK(summary.isMixed(GradeParameter::Exposure));
        CHECK_FALSE(summary.valueOf(GradeParameter::Exposure).has_value());
        CHECK(summary.isMixed(GradeParameter::Temperature));
        CHECK_FALSE(summary.isMixed(GradeParameter::Contrast));
        CHECK(summary.valueOf(GradeParameter::Contrast) == 1.0);
        CHECK(summary.valueOf(GradeParameter::Saturation) == 1.0);
        CHECK(summary.anyGraded);
    }
    SUBCASE("ungraded clips agree on the neutral values") {
        const GradeSummary summary = summarizeGrades(fx.sequence(), {fx.c});
        CHECK_FALSE(summary.anyGraded);
        for (const GradeParameter parameter : kGradeParameters) {
            CHECK(summary.valueOf(parameter) == neutralValue(parameter));
        }
    }
    SUBCASE("no clip that can have a grade") {
        const GradeSummary summary = summarizeGrades(fx.sequence(), {fx.sound});
        CHECK(summary.clips.empty());
        CHECK_FALSE(summary.anyGraded);
        for (const GradeParameter parameter : kGradeParameters) {
            CHECK_FALSE(summary.valueOf(parameter).has_value());
            CHECK_FALSE(summary.isMixed(parameter));
        }
    }
    CHECK(gradeTargets(fx.sequence(), {fx.c, fx.sound, fx.c, fx.a}) == std::vector<ClipId>{fx.c, fx.a});
}
