// The frozen migration steps against the version 9 golden fixtures (`golden/v9/`, added with the 8 -> 9 step;
// the version 7 and 8 goldens are unchanged). Every checked-in older project file, migrated to version 9, must
// give exactly the document and the warnings recorded in its `v9/<name>.migrated.json`. The 8 -> 9 step
// converts nothing (version 9 added the project's "luts" and a grade's "inputLut", "lookLut" and
// "lookStrength"), so each version 9 golden is its version 8 golden with version 9 written and the warnings
// naming version 9 as the version the project is saved as; the test checks that too. `v9/project-v8-adjusted.json`
// is a version 8 file that already holds LUTs: the step keeps them and warns, and loading then limits, keeps or
// drops them by the version 9 rules. `v9/project-v9.json` is the current writer's output, byte for byte.

#include "../../Engine/Model/Validation.h"
#include "../../Engine/Serialize/ProjectJSON.h"

#include <doctest.h>

#include <filesystem>
#include <fstream>
#include <set>
#include <sstream>
#include <string>
#include <vector>

using namespace ve;
using nlohmann::json;

namespace {

constexpr int kVersion9 = 9;

std::string goldenDirectory() {
    const std::string here = __FILE__;
    return here.substr(0, here.find_last_of('/')) + "/golden/";
}

json readJson(const std::string &relativePath) {
    const std::string path = goldenDirectory() + relativePath;
    std::ifstream in(path, std::ios::binary);
    REQUIRE_MESSAGE(in.good(), doctest::String(("cannot open " + path).c_str()));
    std::ostringstream text;
    text << in.rdbuf();
    return json::parse(text.str());
}

struct Fixture {
    const char *input; // relative to golden/
    const char *name;  // its golden is v9/<name>.migrated.json
    int version;
};

constexpr Fixture kFixtures[] = {
    {"project-v1.json", "project-v1", 1},
    {"project-v1-adjusted.json", "project-v1-adjusted", 1},
    {"project-v2.json", "project-v2", 2},
    {"project-v3.json", "project-v3", 3},
    {"project-v4.json", "project-v4", 4},
    {"project-v4-adjusted.json", "project-v4-adjusted", 4},
    {"project-v4-render.json", "project-v4-render", 4},
    {"project-v5.json", "project-v5", 5},
    {"project-v5-adjusted.json", "project-v5-adjusted", 5},
    {"project-v6.json", "project-v6", 6},
    {"project-v7.json", "project-v7", 7},
    {"v8/project-v7-adjusted.json", "project-v7-adjusted", 7},
    {"v8/project-v8.json", "project-v8", 8},
    {"v9/project-v8-adjusted.json", "project-v8-adjusted", 8},
};

json goldenOf(const Fixture &fixture) {
    return readJson(std::string("v9/") + fixture.name + ".migrated.json");
}

std::vector<std::string> warningsOf(const json &golden) {
    return golden.at("warnings").get<std::vector<std::string>>();
}

std::string differences(const json &actual, const json &expected) {
    const json patch = json::diff(expected, actual);
    json shown = json::array();
    for (std::size_t i = 0; i < patch.size() && i < 8; ++i) {
        shown.push_back(patch[i]);
    }
    return shown.dump(1) + (patch.size() > 8 ? "\n... " + std::to_string(patch.size() - 8) + " more" : "");
}

// `warnings` with "saved as version <from>" naming version <to> instead.
std::vector<std::string> savedAs(std::vector<std::string> warnings, int from, int to) {
    const std::string old = "saved as version " + std::to_string(from);
    for (std::string &warning : warnings) {
        if (const auto at = warning.find(old); at != std::string::npos) {
            warning.replace(at, old.size(), "saved as version " + std::to_string(to));
        }
    }
    return warnings;
}

} // namespace

TEST_CASE("Migration goldens v9: every older version migrates to its version 9 document and warnings") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        json document = readJson(fixture.input);
        REQUIRE(document.at("schemaVersion") == fixture.version);
        const json golden = goldenOf(fixture);
        REQUIRE(golden.at("migratedTo") == kVersion9);
        std::vector<std::string> warnings;
        const auto error = migrateProjectJson(document, fixture.version, kVersion9, warnings);
        REQUIRE_MESSAGE(!error.has_value(), doctest::String(error.value_or("").c_str()));
        CHECK(document.at("schemaVersion") == kVersion9);
        CHECK_MESSAGE(document == golden.at("document"),
                      doctest::String(differences(document, golden.at("document")).c_str()));
        CHECK(warnings == warningsOf(golden));
    }
}

TEST_CASE("Migration goldens v9: the 8 -> 9 step changes only the version") {
    // Each version 9 golden of a file with a version 8 golden is that golden with version 9 and the version
    // saved as in its warnings; the step, run on each version 8 golden document, gives the version 9 one with
    // no warning of its own.
    for (const Fixture &fixture : kFixtures) {
        if (fixture.version == 8) {
            continue; // no version 8 golden
        }
        CAPTURE(fixture.name);
        const json golden8 = readJson(std::string("v8/") + fixture.name + ".migrated.json");
        const json golden9 = goldenOf(fixture);
        json expected = golden8.at("document");
        expected["schemaVersion"] = kVersion9;
        CHECK(golden9.at("document") == expected);
        CHECK(warningsOf(golden9) == savedAs(warningsOf(golden8), 8, kVersion9));
        json document = golden8.at("document");
        std::vector<std::string> warnings;
        REQUIRE_FALSE(migrateProjectJson(document, 8, kVersion9, warnings).has_value());
        CHECK(document == expected);
        CHECK(warnings.empty());
    }
    // The checked-in version 8 project: only its version changes.
    json document = readJson("v8/project-v8.json");
    json expected = document;
    expected["schemaVersion"] = kVersion9;
    std::vector<std::string> warnings;
    REQUIRE_FALSE(migrateProjectJson(document, 8, kVersion9, warnings).has_value());
    CHECK(document == expected);
    CHECK(warnings.empty());
}

TEST_CASE("Migration goldens v9: a version 8 file holding LUTs keeps them, by the version 9 rules") {
    const Fixture &fixture = kFixtures[std::size(kFixtures) - 1];
    REQUIRE(std::string(fixture.name) == "project-v8-adjusted");
    const std::vector<std::string> stepWarnings = warningsOf(goldenOf(fixture));
    REQUIRE(stepWarnings.size() == 6);
    CHECK(stepWarnings[0] == "luts: is a version 9 feature in a project of an earlier version: kept, and the project is "
                             "saved as version 9");
    const ProjectLoadResult loaded = projectFromJson(readJson(fixture.input));
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    // The step's warnings, then the parser's: the strength limited, the unknown look dropped with its strength.
    std::vector<std::string> expected = stepWarnings;
    expected.push_back("sequences[0].videoTracks[0].clips[1].grade.lookStrength: the look strength 2.0 is outside its "
                       "range [0, 1]; limited to 1.0");
    expected.push_back("clip 15: its grade's LUT 00000000deadbeef is not in the project's \"luts\"; dropped");
    expected.push_back("clip 15: a look strength without a look; dropped");
    CHECK(loaded.warnings == expected);
    const Project &project = *loaded.project;
    REQUIRE(project.luts.size() == 1);
    const std::string id = project.luts.begin()->first;
    CHECK(id == "1abcbe7cd9e8a779");
    const CubeLut &lut = *project.luts.begin()->second;
    CHECK(lut.kind == CubeKind::ThreeD);
    CHECK(lut.size == 2);
    CHECK(lut.title == "Identity");
    CHECK(lut.fileName == "identity.cube");
    CHECK(lut.entry(1, 0, 1) == std::array<float, 3>{1.0f, 0.0f, 1.0f});
    const Sequence &sequence = project.sequences[0];
    CHECK(sequence.findClip(ClipId{11})->grade.inputLut == id);
    CHECK(sequence.findClip(ClipId{13})->grade.lookLut == id);
    CHECK(sequence.findClip(ClipId{13})->grade.lookStrength == 1.0);
    CHECK(sequence.findClip(ClipId{15})->grade.lookLut.empty());
    CHECK(sequence.findClip(ClipId{15})->grade.lookStrength == 1.0);
    // Saved: version 9 with the one LUT the clips use, which loads back exactly.
    const json saved = projectToJson(project);
    CHECK(saved.at("schemaVersion") == kVersion9);
    REQUIRE(saved.at("luts").size() == 1);
    CHECK(saved.at("luts")[0].at("data") == readJson(fixture.input).at("luts")[0].at("data"));
    const ProjectLoadResult again = projectFromJson(saved);
    REQUIRE(again.ok());
    CHECK(again.warnings.empty());
    CHECK(*again.project == project);
}

TEST_CASE("Migration goldens v9: a golden document loads as the project its older file loads as") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        const json golden = goldenOf(fixture);
        const ProjectLoadResult fromOlder = projectFromJson(readJson(fixture.input));
        const ProjectLoadResult fromGolden = projectFromJson(golden.at("document"));
        REQUIRE_MESSAGE(fromOlder.ok(), doctest::String(fromOlder.error.c_str()));
        REQUIRE_MESSAGE(fromGolden.ok(), doctest::String(fromGolden.error.c_str()));
        CHECK(*fromOlder.project == *fromGolden.project);
        std::vector<std::string> expected = savedAs(warningsOf(golden), kVersion9, kProjectSchemaVersion);
        expected.insert(expected.end(), fromGolden.warnings.begin(), fromGolden.warnings.end());
        CHECK(fromOlder.warnings == expected);
    }
}

TEST_CASE("Migration goldens v9: migrating in parts gives the same result as at once") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        const json original = readJson(fixture.input);
        const json golden = goldenOf(fixture);
        for (int middle = fixture.version; middle <= kVersion9; ++middle) {
            CAPTURE(middle);
            json document = original;
            std::vector<std::string> first;
            REQUIRE_FALSE(migrateProjectJson(document, fixture.version, middle, first).has_value());
            std::vector<std::string> second;
            REQUIRE_FALSE(migrateProjectJson(document, middle, kVersion9, second).has_value());
            CHECK(document == golden.at("document"));
            std::vector<std::string> warnings = savedAs(first, middle, kVersion9);
            warnings.insert(warnings.end(), second.begin(), second.end());
            CHECK(warnings == warningsOf(golden));
        }
    }
}

TEST_CASE("Migration goldens v9: every checked-in older project file has a version 9 golden") {
    std::set<std::string> listed;
    std::set<int> versions;
    for (const Fixture &fixture : kFixtures) {
        listed.insert(fixture.input);
        versions.insert(fixture.version);
    }
    for (int version = 1; version < kVersion9; ++version) {
        CHECK(versions.count(version) == 1);
    }
    std::set<std::string> inputs;
    for (const char *directory : {"", "v8/", "v9/"}) {
        for (const auto &entry : std::filesystem::directory_iterator(goldenDirectory() + directory)) {
            const std::string file = entry.path().filename().string();
            const bool project = file.rfind("project-v", 0) == 0 && entry.path().extension() == ".json";
            const bool derived =
                file.find(".migrated.") != std::string::npos || file.find(".expected.") != std::string::npos;
            if (project && !derived && file != "project-v9.json") {
                inputs.insert(std::string(directory) + file);
            }
        }
    }
    CHECK(inputs == listed);
    std::set<std::string> goldens;
    for (const auto &entry : std::filesystem::directory_iterator(goldenDirectory() + "v9/")) {
        const std::string file = entry.path().filename().string();
        if (file.find(".migrated.json") != std::string::npos) {
            goldens.insert(file.substr(0, file.find(".migrated.json")));
        }
    }
    std::set<std::string> names;
    for (const Fixture &fixture : kFixtures) {
        names.insert(fixture.name);
    }
    CHECK(goldens == names);
}

namespace {

// The checked-in version 8 project with what version 9 added: wheels and curves (schema 8 keys a version 9
// file writes too), a 1D input LUT on one clip, and a 3D look at strength 0.6 on another.
Project richProjectV9() {
    const ProjectLoadResult base = projectFromJson(readJson("v8/project-v8.json"));
    REQUIRE(base.ok());
    Project project = *base.project;
    CubeLut shaper;
    shaper.kind = CubeKind::OneD;
    shaper.size = 4;
    shaper.title = "Shaper";
    shaper.fileName = "shaper.cube";
    shaper.sourcePath = "/LUTs/shaper.cube";
    shaper.domainMin = {-0.125f, -0.125f, -0.125f};
    shaper.domainMax = {1.25f, 1.25f, 1.25f};
    shaper.table = {0.0f, 0.0f, 0.0f, 0.25f, 0.3f, 0.2f, 0.6f, 0.65f, 0.55f, 1.0f, 1.0f, 1.0f};
    CubeLut look;
    look.kind = CubeKind::ThreeD;
    look.size = 2;
    look.fileName = "warm.cube";
    for (int b = 0; b < 2; ++b) {
        for (int g = 0; g < 2; ++g) {
            for (int r = 0; r < 2; ++r) {
                look.table.insert(look.table.end(), {0.05f + 0.95f * float(r), 0.02f + 0.9f * float(g), 0.85f * float(b)});
            }
        }
    }
    const std::string shaperId = project.addLut(shaper);
    const std::string lookId = project.addLut(look);
    Sequence &sequence = project.sequences[0];
    ClipGrade &first = sequence.findClip(ClipId{11})->grade;
    first[GradeWheel::Lift] = WheelValue{0.125, -0.25, 0.5};
    first[GradeCurve::Luma] = CurvePoints{{0.0, 0.0}, {0.25, 0.1875}, {1.0, 1.0}};
    first.inputLut = shaperId;
    ClipGrade &second = sequence.findClip(ClipId{15})->grade;
    second.lookLut = lookId;
    second.lookStrength = 0.625;
    REQUIRE_FALSE(validateProject(project).has_value());
    return project;
}

} // namespace

TEST_CASE("Migration goldens v9: the checked-in version 9 project matches the current writer byte for byte") {
    const Project expected = richProjectV9();
    const std::string written = serializeProject(expected) + "\n";
    std::ifstream in(goldenDirectory() + "v9/project-v9.json", std::ios::binary);
    REQUIRE_MESSAGE(in.good(), "the version 9 golden is checked in (never written by the test)");
    std::ostringstream text;
    text << in.rdbuf();
    CHECK(text.str() == written);
    const ProjectLoadResult loaded = parseProject(text.str());
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == expected);
    // Only the LUTs a clip uses are written: an imported but unused one is not.
    Project unused = expected;
    CubeLut extra;
    extra.kind = CubeKind::OneD;
    extra.size = 2;
    extra.table = {0, 0, 0, 1, 1, 1};
    unused.addLut(extra);
    CHECK(serializeProject(unused) + "\n" == written);
}
