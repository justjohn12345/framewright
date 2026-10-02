// The frozen migration steps against the version 8 golden fixtures (`golden/v8/`, added with the
// 7 -> 8 step; the version 7 fixtures beside them are unchanged, MigrationGoldenTests.cpp). Every
// checked-in older project file, migrated to version 8, must give exactly the document and the
// warnings recorded in its `v8/<name>.migrated.json`. The 7 -> 8 step converts nothing (version 8 added
// clips' "grade"), so each version 8 golden is its version 7 golden with version 8 written and the
// warnings naming version 8 as the version the project is saved as; the test checks that too, so the
// two sets of goldens cannot drift apart. `v8/project-v7-adjusted.json` is a version 7 file that
// already holds grades (written by hand, or by a build between the two): the step keeps them and warns
// per clip, and loading then limits, keeps or drops them by the version 8 rules.

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

constexpr int kVersion8 = 8;

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
    const char *name;  // its golden is v8/<name>.migrated.json
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
};

json goldenOf(const Fixture &fixture) {
    return readJson(std::string("v8/") + fixture.name + ".migrated.json");
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

TEST_CASE("Migration goldens v8: every older version migrates to its version 8 document and warnings") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        json document = readJson(fixture.input);
        REQUIRE(document.at("schemaVersion") == fixture.version);
        const json golden = goldenOf(fixture);
        REQUIRE(golden.at("migratedTo") == kVersion8);
        std::vector<std::string> warnings;
        const auto error = migrateProjectJson(document, fixture.version, kVersion8, warnings);
        REQUIRE_MESSAGE(!error.has_value(), doctest::String(error.value_or("").c_str()));
        CHECK(document.at("schemaVersion") == kVersion8);
        CHECK_MESSAGE(document == golden.at("document"),
                      doctest::String(differences(document, golden.at("document")).c_str()));
        CHECK(warnings == warningsOf(golden));
    }
}

TEST_CASE("Migration goldens v8: the 7 -> 8 step changes only the version") {
    // Each version 8 golden of a file with a version 7 golden is that golden with version 8 and the
    // version saved as in its warnings; and the step itself, run on each version 7 golden document,
    // gives the version 8 one with no warning of its own.
    for (const Fixture &fixture : kFixtures) {
        if (std::string(fixture.input).rfind("v8/", 0) == 0) {
            continue; // no version 7 golden
        }
        CAPTURE(fixture.name);
        const json golden7 = readJson(std::string(fixture.name) + ".migrated.json");
        const json golden8 = goldenOf(fixture);
        json expected = golden7.at("document");
        expected["schemaVersion"] = kVersion8;
        CHECK(golden8.at("document") == expected);
        CHECK(warningsOf(golden8) == savedAs(warningsOf(golden7), 7, kVersion8));
        json document = golden7.at("document");
        std::vector<std::string> warnings;
        REQUIRE_FALSE(migrateProjectJson(document, 7, kVersion8, warnings).has_value());
        CHECK(document == expected);
        CHECK(warnings.empty());
    }
}

TEST_CASE("Migration goldens v8: a version 7 file holding grades keeps them, by the version 8 rules") {
    const Fixture &fixture = kFixtures[std::size(kFixtures) - 1];
    REQUIRE(std::string(fixture.name) == "project-v7-adjusted");
    const std::vector<std::string> stepWarnings = warningsOf(goldenOf(fixture));
    REQUIRE(stepWarnings.size() == 3);
    for (const std::string &warning : stepWarnings) {
        CHECK(warning.find(": \"grade\" is a version 8 feature in a project of an earlier version: kept, and the "
                           "project is saved as version 8") != std::string::npos);
    }
    const ProjectLoadResult loaded = projectFromJson(readJson(fixture.input));
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    // The step's warnings, then the parser's: the unknown parameter kept, the value limited, the sound
    // clip's grade dropped.
    std::vector<std::string> expected = savedAs(stepWarnings, kVersion8, kProjectSchemaVersion);
    expected.push_back("sequences[0].videoTracks[0].clips[0].grade.lift: unknown grade parameter \"lift\" (from a "
                       "newer version of Framewright?); kept as it is and saved with the project, but not applied or "
                       "editable");
    expected.push_back("sequences[0].videoTracks[1].clips[2].grade.saturation: Saturation 9.0 is outside its range "
                       "[0.0, 2.0]; limited to 2.0");
    expected.push_back("sequences[0].audioTracks[0].clips[0].grade: a clip on an audio track has no grade; dropped");
    CHECK(loaded.warnings == expected);
    const Sequence &sequence = loaded.project->sequences[0];
    const Clip &kept = sequence.videoTracks[0].clips[0];
    CHECK(kept.grade[GradeParameter::Exposure] == 0.5);
    CHECK(kept.grade.foreign == R"({"lift":[0.1,0.0,0.0]})");
    CHECK(sequence.videoTracks[1].clips[2].grade[GradeParameter::Saturation] == 2.0);
    CHECK(sequence.audioTracks[0].clips[0].grade.isEmpty());
    // Saved, the kept grade (the unknown entry included) is written back as it was read.
    const json saved = projectToJson(*loaded.project);
    const json input = readJson(fixture.input);
    CHECK(saved.at("sequences")[0].at("videoTracks")[0].at("clips")[0].at("grade") ==
          input.at("sequences")[0].at("videoTracks")[0].at("clips")[0].at("grade"));
    CHECK(saved.at("schemaVersion") == kProjectSchemaVersion);
}

TEST_CASE("Migration goldens v8: a golden document loads as the project its older file loads as") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        const json golden = goldenOf(fixture);
        const ProjectLoadResult fromOlder = projectFromJson(readJson(fixture.input));
        const ProjectLoadResult fromGolden = projectFromJson(golden.at("document"));
        REQUIRE_MESSAGE(fromOlder.ok(), doctest::String(fromOlder.error.c_str()));
        REQUIRE_MESSAGE(fromGolden.ok(), doctest::String(fromGolden.error.c_str()));
        CHECK(*fromOlder.project == *fromGolden.project);
        std::vector<std::string> expected = savedAs(warningsOf(golden), kVersion8, kProjectSchemaVersion);
        expected.insert(expected.end(), fromGolden.warnings.begin(), fromGolden.warnings.end());
        CHECK(fromOlder.warnings == expected);
    }
}

TEST_CASE("Migration goldens v8: migrating in parts gives the same result as at once") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        const json original = readJson(fixture.input);
        const json golden = goldenOf(fixture);
        for (int middle = fixture.version; middle <= kVersion8; ++middle) {
            CAPTURE(middle);
            json document = original;
            std::vector<std::string> first;
            REQUIRE_FALSE(migrateProjectJson(document, fixture.version, middle, first).has_value());
            std::vector<std::string> second;
            REQUIRE_FALSE(migrateProjectJson(document, middle, kVersion8, second).has_value());
            CHECK(document == golden.at("document"));
            // A warning about newer content names the version its part stops at.
            std::vector<std::string> warnings = savedAs(first, middle, kVersion8);
            warnings.insert(warnings.end(), second.begin(), second.end());
            CHECK(warnings == warningsOf(golden));
        }
    }
}

TEST_CASE("Migration goldens v8: every checked-in older project file has a version 8 golden") {
    std::set<std::string> listed;
    std::set<int> versions;
    for (const Fixture &fixture : kFixtures) {
        listed.insert(fixture.input);
        versions.insert(fixture.version);
    }
    for (int version = 1; version < kVersion8; ++version) {
        CHECK(versions.count(version) == 1);
    }
    std::set<std::string> inputs;
    for (const char *directory : {"", "v8/"}) {
        for (const auto &entry : std::filesystem::directory_iterator(goldenDirectory() + directory)) {
            const std::string file = entry.path().filename().string();
            const bool project = file.rfind("project-v", 0) == 0 && entry.path().extension() == ".json";
            const bool derived =
                file.find(".migrated.") != std::string::npos || file.find(".expected.") != std::string::npos;
            if (project && !derived && file != "project-v8.json") {
                inputs.insert(std::string(directory) + file);
            }
        }
    }
    CHECK(inputs == listed);
    // And every version 8 golden belongs to a listed input.
    std::set<std::string> goldens;
    for (const auto &entry : std::filesystem::directory_iterator(goldenDirectory() + "v8/")) {
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
