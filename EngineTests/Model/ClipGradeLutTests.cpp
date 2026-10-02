// LUTs in a clip's grade and the project (ClipGrade.h, Project::luts, schema 9): the project's table
// (content ids, one copy of a table imported twice, equality by contents), neutral and validation (a missing
// LUT, a strength outside [0, 1] or without a look); the project file (only the LUTs a clip uses, in id order,
// read back exactly; a malformed entry refused; an id that does not match its table re-keyed with the clips
// following); SetClipGrade with LUTs (names, a missing LUT refused, removing the look resets its strength, a
// clip without a look keeps strength 1) and SetClipGradeWithLuts (adds the LUTs the project lacks, undo removes
// them, a refused or empty change adds none); the selection's agreement.

#include "ModelFixtures.h"

#include "../../Engine/Edit/GradeEdits.h"

#include <cmath>

using namespace vetest;
using nlohmann::json;

namespace {

CubeLut identityLut(std::uint32_t size, float lift = 0.0f) {
    CubeLut lut;
    lut.kind = CubeKind::ThreeD;
    lut.size = size;
    for (std::uint32_t b = 0; b < size; ++b) {
        for (std::uint32_t g = 0; g < size; ++g) {
            for (std::uint32_t r = 0; r < size; ++r) {
                const float last = float(size - 1);
                lut.table.insert(lut.table.end(), {lift + float(r) / last, lift + float(g) / last, lift + float(b) / last});
            }
        }
    }
    return lut;
}

CubeLut curveLut() {
    CubeLut lut;
    lut.kind = CubeKind::OneD;
    lut.size = 3;
    lut.table = {0.0f, 0.0f, 0.0f, 0.4f, 0.5f, 0.6f, 1.0f, 1.0f, 1.0f};
    lut.fileName = "curve.cube";
    return lut;
}

struct LutClips : Fixture {
    ClipId a, b, sound;
    std::string identity, curve;
    LutClips() {
        std::tie(a, sound) = addLinkedPair(0, 30, 0);
        b = addClip(v1, av30, 30, 30, 60);
        identity = project.addLut(identityLut(3));
        curve = project.addLut(curveLut());
        sequence().findClip(a)->grade.inputLut = curve;
        sequence().findClip(b)->grade.lookLut = identity;
        sequence().findClip(b)->grade.lookStrength = 0.5;
        requireValid();
    }
    const ClipGrade &grade(ClipId id) const {
        return clip(id).grade;
    }
};

} // namespace

TEST_CASE("Grade LUTs: the project's table") {
    Project project;
    const std::string id = project.addLut(identityLut(3));
    CHECK(id == cubeContentId(identityLut(3)));
    CubeLut renamed = identityLut(3);
    renamed.fileName = "same table.cube";
    CHECK(project.addLut(renamed) == id);
    REQUIRE(project.luts.size() == 1);
    CHECK(project.findLut(id)->fileName.empty()); // the first copy's names are kept
    CHECK(project.findLut("nope") == nullptr);
    // Equality by contents, not by the shared pointers.
    Project other;
    other.addLut(identityLut(3));
    other.luts.begin()->second = std::make_shared<const CubeLut>(identityLut(3));
    CHECK(project == other);
    other.addLut(identityLut(2));
    CHECK_FALSE(project == other);
}

TEST_CASE("Grade LUTs: neutral and validation") {
    LutClips fx;
    ClipGrade grade;
    grade.inputLut = fx.curve;
    CHECK_FALSE(grade.isNeutral());
    fx.sequence().findClip(fx.a)->grade.inputLut = "0123456789abcdef";
    CHECK(problemOf(fx.project).find("its grade uses LUT 0123456789abcdef, which the project does not hold") !=
          std::string::npos);
    fx.sequence().findClip(fx.a)->grade.inputLut.clear();
    fx.sequence().findClip(fx.b)->grade.lookStrength = 1.5;
    CHECK(problemOf(fx.project).find("grade look strength 1.5 is outside its range [0, 1]") != std::string::npos);
    fx.sequence().findClip(fx.b)->grade.lookStrength = 0.5;
    fx.sequence().findClip(fx.b)->grade.lookLut.clear();
    CHECK(problemOf(fx.project).find("grade look strength 0.5 without a look") != std::string::npos);
    // A table stored under another id.
    LutClips keyed;
    auto lut = keyed.project.luts.at(keyed.identity);
    keyed.project.luts.erase(keyed.identity);
    keyed.project.luts.emplace("ffffffffffffffff", lut);
    keyed.sequence().findClip(keyed.b)->grade.lookLut = "ffffffffffffffff";
    CHECK(problemOf(keyed.project).find("is not stored under its content id") != std::string::npos);
}

TEST_CASE("Grade LUTs: the project file") {
    LutClips fx;
    fx.project.addLut(identityLut(4)); // imported, used by no clip
    const json document = projectToJson(fx.project);
    REQUIRE(document.at("schemaVersion") == 9);
    const json &luts = document.at("luts");
    REQUIRE(luts.size() == 2);
    CHECK(luts[0].at("id").get<std::string>() < luts[1].at("id").get<std::string>());
    for (const json &entry : luts) {
        CHECK((entry.at("id") == fx.identity || entry.at("id") == fx.curve));
    }
    const ProjectLoadResult loaded = parseProject(serializeProject(fx.project));
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(loaded.project->luts.size() == 2);
    CHECK(*loaded.project->findLut(fx.curve) == *fx.project.findLut(fx.curve));
    CHECK(loaded.project->sequences == fx.project.sequences);
    // No LUT used: no "luts" written at all.
    Fixture plain;
    plain.project.addLut(identityLut(2));
    CHECK_FALSE(projectToJson(plain.project).contains("luts"));

    SUBCASE("a malformed entry fails the load with its path") {
        for (const auto &[key, value] : std::vector<std::pair<std::string, json>>{
                 {"kind", "4d"}, {"size", 1}, {"data", "not base64!"}, {"data", "AAAA"}, {"domainMin", json::array({0, 0})}}) {
            json bad = document;
            bad["luts"][0][key] = value;
            const ProjectLoadResult refused = projectFromJson(bad);
            REQUIRE_FALSE(refused.ok());
            CHECK(refused.error.find("luts[0]") != std::string::npos);
        }
    }
    SUBCASE("an id that does not match its table is re-keyed, the clips following") {
        json edited = document;
        const std::string old = edited["luts"][0]["id"];
        edited["luts"][0]["id"] = "0000000000000001";
        for (json &track : edited["sequences"][0]["videoTracks"]) {
            for (json &clip : track["clips"]) {
                if (clip.contains("grade")) {
                    for (const char *key : {"inputLut", "lookLut"}) {
                        if (clip["grade"].contains(key) && clip["grade"][key] == old) {
                            clip["grade"][key] = "0000000000000001";
                        }
                    }
                }
            }
        }
        const ProjectLoadResult rekeyed = projectFromJson(edited);
        REQUIRE_MESSAGE(rekeyed.ok(), doctest::String(rekeyed.error.c_str()));
        REQUIRE(rekeyed.warnings.size() == 1);
        CHECK(rekeyed.warnings[0] == "luts[0]: the LUT's id 0000000000000001 does not match its table; kept as " + old);
        CHECK(rekeyed.project->sequences == fx.project.sequences);
    }
}

TEST_CASE("Grade LUTs: SetClipGrade") {
    LutClips fx;
    SUBCASE("names, and removing the look resets its strength") {
        GradeChange input;
        input.inputLut = fx.identity;
        SetClipGrade setInput(fx.seq, {fx.b}, input);
        CHECK(setInput.name() == "Change Input LUT");
        applyReversible(fx.project, setInput);
        CHECK(fx.grade(fx.b).inputLut == fx.identity);
        GradeChange strength;
        strength.lookStrength = 0.25;
        SetClipGrade setStrength(fx.seq, {fx.a, fx.b}, strength);
        CHECK(setStrength.name() == "Change Look Strength");
        applyReversible(fx.project, setStrength);
        CHECK(fx.grade(fx.b).lookStrength == 0.25);
        CHECK(fx.grade(fx.a).lookStrength == 1.0); // no look: strength 1
        GradeChange removeLook;
        removeLook.lookLut = std::string();
        SetClipGrade remove(fx.seq, {fx.b}, removeLook);
        CHECK(remove.name() == "Change Look");
        applyReversible(fx.project, remove);
        CHECK(fx.grade(fx.b).lookLut.empty());
        CHECK(fx.grade(fx.b).lookStrength == 1.0);
    }
    SUBCASE("refusals") {
        GradeChange missing;
        missing.lookLut = std::string("0123456789abcdef");
        SetClipGrade command(fx.seq, {fx.a}, missing);
        const EditResult r = applyRefused(fx.project, command, EditError::InvalidArgument);
        CHECK(r.message.find("The project holds no LUT 0123456789abcdef") != std::string::npos);
        for (const double bad : {-0.1, 1.5, std::nan("")}) {
            GradeChange strength;
            strength.lookStrength = bad;
            SetClipGrade set(fx.seq, {fx.b}, strength);
            applyRefused(fx.project, set, EditError::InvalidArgument);
        }
    }
    SUBCASE("a whole grade and Reset carry the LUTs") {
        SetClipGrade paste(fx.seq, {fx.a}, GradeChange::whole(fx.grade(fx.b)), "Paste Grade");
        applyReversible(fx.project, paste);
        CHECK(fx.grade(fx.a) == fx.grade(fx.b));
        SetClipGrade reset(fx.seq, {fx.a, fx.b}, GradeChange::whole(ClipGrade{}), "Reset Grade");
        applyReversible(fx.project, reset);
        CHECK(fx.grade(fx.b).isEmpty());
        CHECK(fx.grade(fx.b).lookStrength == 1.0);
    }
}

TEST_CASE("Grade LUTs: SetClipGradeWithLuts adds the LUTs it needs, and undo removes them") {
    LutClips fx;
    const CubeLut fresh = identityLut(2, 0.05f);
    const std::string freshId = cubeContentId(fresh);
    REQUIRE(fx.project.findLut(freshId) == nullptr);
    GradeChange change;
    change.lookLut = freshId;
    SetClipGradeWithLuts command({std::make_shared<const CubeLut>(fresh)},
                                 std::make_unique<SetClipGrade>(fx.seq, std::vector<ClipId>{fx.a}, change));
    CHECK(command.name() == "Change Look");
    applyReversible(fx.project, command); // revert restores the project bit for bit: the LUT goes too
    CHECK(fx.project.findLut(freshId) != nullptr);
    CHECK(fx.grade(fx.a).lookLut == freshId);
    REQUIRE(command.canRevert(fx.project));
    command.revert(fx.project);
    CHECK(fx.project.findLut(freshId) == nullptr);
    // A LUT the project holds is not added again (nor removed by undo).
    GradeChange held;
    held.inputLut = fx.identity;
    SetClipGradeWithLuts again({fx.project.luts.at(fx.identity)},
                               std::make_unique<SetClipGrade>(fx.seq, std::vector<ClipId>{fx.b}, held));
    applyReversible(fx.project, again);
    again.revert(fx.project);
    CHECK(fx.project.findLut(fx.identity) != nullptr);
    // A refused change adds nothing; nor does one that changes nothing.
    GradeChange onSound;
    onSound.lookLut = freshId;
    SetClipGradeWithLuts refused({std::make_shared<const CubeLut>(fresh)},
                                 std::make_unique<SetClipGrade>(fx.seq, std::vector<ClipId>{fx.sound}, onSound));
    applyRefused(fx.project, refused, EditError::TrackKindMismatch);
    CHECK(fx.project.findLut(freshId) == nullptr);
    GradeChange same;
    same.inputLut = fx.curve;
    SetClipGradeWithLuts noop({std::make_shared<const CubeLut>(fresh)},
                              std::make_unique<SetClipGrade>(fx.seq, std::vector<ClipId>{fx.a}, same));
    CHECK(noop.apply(fx.project).ok());
    CHECK(noop.isNoOp());
    CHECK(fx.project.findLut(freshId) == nullptr);
    // An invalid LUT refuses the whole change.
    CubeLut broken = fresh;
    broken.table.pop_back();
    SetClipGradeWithLuts invalid({std::make_shared<const CubeLut>(broken)},
                                 std::make_unique<SetClipGrade>(fx.seq, std::vector<ClipId>{fx.a}, change));
    applyRefused(fx.project, invalid, EditError::InvalidArgument);
}

TEST_CASE("Grade LUTs: the selection's agreement") {
    LutClips fx;
    const GradeSummary both = summarizeGrades(fx.sequence(), {fx.a, fx.sound, fx.b});
    CHECK_FALSE(both.inputLut.has_value());
    CHECK_FALSE(both.lookLut.has_value());
    CHECK_FALSE(both.lookStrength.has_value());
    const GradeSummary one = summarizeGrades(fx.sequence(), {fx.b});
    CHECK(one.lookLut == fx.identity);
    CHECK(one.inputLut == std::string());
    CHECK(one.lookStrength == 0.5);
    fx.sequence().findClip(fx.a)->grade = fx.grade(fx.b);
    CHECK(summarizeGrades(fx.sequence(), {fx.a, fx.b}).identical);
}
