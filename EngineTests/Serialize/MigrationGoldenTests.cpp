// The frozen migration steps (Engine/Serialize/ProjectMigrations.h) against golden fixtures: every
// checked-in project file of an older schema version, migrated to version 7 (the version current
// when the steps were frozen), must give exactly the document and the warnings recorded in its
// `<name>.migrated.json` ({"migratedTo": 7, "warnings": [...], "document": {...}}). The fixtures
// were recorded with the migration code as it was before the freeze (2026-10-01, ae6283e), so they
// also prove the freeze changed nothing. A later schema version adds a step after version 7: these
// fixtures stay as they are, and a change to an earlier step's output (through the model, the
// current parser or writer, a renamed kind...) fails here.
//
// The `-adjusted` inputs exercise every warning a step can give: version 1's rounded times, epochs,
// a duration off the frame grid and overlapping fades; version 4's unknown Motion parameter,
// interpolation and transition kind, a curve on a linear keyframe, custom curves limited at a
// clip's edge, fades that meet crossfades or a touching clip, a video clip's fades and a version 6
// kind; version 5's version 6 content.

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

constexpr int kFrozenAtVersion = 7;

std::string goldenDirectory() {
    const std::string here = __FILE__;
    return here.substr(0, here.find_last_of('/')) + "/golden/";
}

std::string readFile(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    REQUIRE_MESSAGE(in.good(), doctest::String(("cannot open " + path).c_str()));
    std::ostringstream text;
    text << in.rdbuf();
    return text.str();
}

json readJson(const std::string &name) {
    return json::parse(readFile(goldenDirectory() + name));
}

// The inputs with a golden migration, and the version each is in.
struct Fixture {
    const char *name;
    int version;
};

constexpr Fixture kFixtures[] = {
    {"project-v1", 1},          {"project-v1-adjusted", 1}, {"project-v2", 2},
    {"project-v3", 3},          {"project-v4", 4},          {"project-v4-adjusted", 4},
    {"project-v4-render", 4},   {"project-v5", 5},          {"project-v5-adjusted", 5},
    {"project-v6", 6},          {"project-v7", 7},
};

std::vector<std::string> warningsOf(const json &golden) {
    return golden.at("warnings").get<std::vector<std::string>>();
}

// The first few differences between two documents, as JSON patch operations, for the failure
// message.
std::string differences(const json &actual, const json &expected) {
    const json patch = json::diff(expected, actual);
    json shown = json::array();
    for (std::size_t i = 0; i < patch.size() && i < 8; ++i) {
        shown.push_back(patch[i]);
    }
    return shown.dump(1) + (patch.size() > 8 ? "\n... " + std::to_string(patch.size() - 8) + " more" : "");
}

} // namespace

TEST_CASE("Migration goldens: every older version migrates to its frozen version 7 document and warnings") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        json document = readJson(std::string(fixture.name) + ".json");
        REQUIRE(document.at("schemaVersion") == fixture.version);
        const json golden = readJson(std::string(fixture.name) + ".migrated.json");
        REQUIRE(golden.at("migratedTo") == kFrozenAtVersion);
        std::vector<std::string> warnings;
        const auto error = migrateProjectJson(document, fixture.version, kFrozenAtVersion, warnings);
        REQUIRE_MESSAGE(!error.has_value(), doctest::String(error.value_or("").c_str()));
        CHECK(document.at("schemaVersion") == kFrozenAtVersion);
        CHECK_MESSAGE(document == golden.at("document"), doctest::String(differences(document, golden.at("document")).c_str()));
        CHECK(warnings == warningsOf(golden));
    }
}

TEST_CASE("Migration goldens: the -adjusted fixtures give the warnings they were made for") {
    // Not a second copy of the goldens: a guard that the adjusted inputs still reach every warning
    // path (an input edited by mistake would otherwise just record fewer warnings).
    struct Expectation {
        const char *name;
        std::size_t count;
        std::vector<const char *> phrases;
    };
    const std::vector<Expectation> expected = {
        {"project-v1-adjusted", 7,
         {"adopted as exact", "was stored rounded or with an epoch", "off the frame grid by rounding; snapped to",
          "overlapped; now"}},
        {"project-v4-adjusted", 10,
         {"unknown Motion parameter \"skew\"", "unknown keyframe interpolation \"springy\"",
          "a timing curve on a linear keyframe was ignored", "unknown transition kind \"zoomBlur\"",
          "a custom curve took Scale to", "a custom curve took Opacity to",
          "would meet the crossfade at the clip's end; shortened to",
          "would meet the crossfade at the clip's start; shortened to",
          "was dropped: another clip touches the clip's start", "an Iris transition is a version 6 feature"}},
        {"project-v5-adjusted", 2,
         {"a Wipe Left transition is a version 6 feature", "\"reversed\" is a version 6 feature"}},
    };
    for (const Expectation &expectation : expected) {
        CAPTURE(expectation.name);
        const std::vector<std::string> warnings =
            warningsOf(readJson(std::string(expectation.name) + ".migrated.json"));
        CHECK(warnings.size() == expectation.count);
        for (const char *phrase : expectation.phrases) {
            CAPTURE(phrase);
            bool found = false;
            for (const std::string &warning : warnings) {
                found = found || warning.find(phrase) != std::string::npos;
            }
            CHECK(found);
        }
    }
}

TEST_CASE("Migration goldens: a golden document loads as the project its older file loads as") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        const json golden = readJson(std::string(fixture.name) + ".migrated.json");
        const ProjectLoadResult fromOlder = projectFromJson(readJson(std::string(fixture.name) + ".json"));
        const ProjectLoadResult fromGolden = projectFromJson(golden.at("document"));
        REQUIRE_MESSAGE(fromOlder.ok(), doctest::String(fromOlder.error.c_str()));
        REQUIRE_MESSAGE(fromGolden.ok(), doctest::String(fromGolden.error.c_str()));
        CHECK(*fromOlder.project == *fromGolden.project);
        // The older file's warnings are the migration's, then what loading the result reports. Loading
        // saves as the current version, which a warning about newer content names.
        std::vector<std::string> expected = warningsOf(golden);
        const std::string savedAs = "saved as version " + std::to_string(kFrozenAtVersion);
        for (std::string &warning : expected) {
            if (const auto at = warning.find(savedAs); at != std::string::npos) {
                warning.replace(at, savedAs.size(), "saved as version " + std::to_string(kProjectSchemaVersion));
            }
        }
        expected.insert(expected.end(), fromGolden.warnings.begin(), fromGolden.warnings.end());
        CHECK(fromOlder.warnings == expected);
    }
}

TEST_CASE("Migration goldens: every checked-in older project file has a golden migration") {
    std::set<std::string> listed;
    std::set<int> versions;
    for (const Fixture &fixture : kFixtures) {
        listed.insert(fixture.name);
        versions.insert(fixture.version);
    }
    for (int version = 1; version <= kFrozenAtVersion; ++version) {
        CHECK(versions.count(version) == 1);
    }
    std::set<std::string> inputs;
    for (const auto &entry : std::filesystem::directory_iterator(goldenDirectory())) {
        const std::string file = entry.path().filename().string();
        const bool project = file.rfind("project-v", 0) == 0 && entry.path().extension() == ".json";
        const bool derived = file.find(".migrated.") != std::string::npos || file.find(".expected.") != std::string::npos;
        if (project && !derived) {
            inputs.insert(entry.path().stem().string());
        }
    }
    CHECK(inputs == listed);
}

TEST_CASE("Migration goldens: migrating in parts gives the same result as at once") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        const json original = readJson(std::string(fixture.name) + ".json");
        for (int middle = fixture.version; middle <= kFrozenAtVersion; ++middle) {
            CAPTURE(middle);
            json document = original;
            std::vector<std::string> warnings;
            REQUIRE_FALSE(migrateProjectJson(document, fixture.version, middle, warnings).has_value());
            CHECK(document.at("schemaVersion") == middle);
            REQUIRE_FALSE(migrateProjectJson(document, middle, kFrozenAtVersion, warnings).has_value());
            const json golden = readJson(std::string(fixture.name) + ".migrated.json");
            CHECK(document == golden.at("document"));
            // A warning about newer content names the version the run stops at (the version the
            // project would be saved as), so a first part that ends at `middle` names that one.
            std::vector<std::string> expected = warningsOf(golden);
            const std::string savedAs = "saved as version " + std::to_string(kFrozenAtVersion);
            for (std::string &warning : expected) {
                const auto at = warning.find(savedAs);
                const bool firstPart = warning.find("version 6 feature") != std::string::npos && middle >= 6;
                if (at != std::string::npos && firstPart) {
                    warning.replace(at, savedAs.size(), "saved as version " + std::to_string(middle));
                }
            }
            CHECK(warnings == expected);
        }
    }
}

TEST_CASE("Migration goldens: the target version is checked") {
    json document = readJson("project-v4.json");
    std::vector<std::string> warnings;
    const auto backwards = migrateProjectJson(document, 4, 3, warnings);
    REQUIRE(backwards.has_value());
    CHECK(*backwards == "cannot migrate from schema version 4 to 3");
    const auto beyond = migrateProjectJson(document, 4, kProjectSchemaVersion + 1, warnings);
    REQUIRE(beyond.has_value());
    CHECK(*beyond == "cannot migrate from schema version 4 to " + std::to_string(kProjectSchemaVersion + 1));
    CHECK(document == readJson("project-v4.json"));
    CHECK(warnings.empty());
}

TEST_CASE("Migration goldens: every step reports a malformed list or element as the parser does") {
    // One error policy for all steps (the parser's): the same misshapen track, clip or span fails
    // with the same message whichever version the file is in (version 7 has no step: the parser
    // reports it).
    struct Damage {
        const char *what;
        void (*apply)(json &sequence);
        const char *message;
    };
    const Damage damages[] = {
        {"a track that is not an object", [](json &sequence) { sequence["videoTracks"][0] = "track"; },
         "sequences[0].videoTracks[0]: expected an object, found string"},
        {"clips that are not a list", [](json &sequence) { sequence["videoTracks"][0]["clips"] = json::object(); },
         "sequences[0].videoTracks[0].clips: expected an array, found object"},
        {"a clip that is not an object", [](json &sequence) { sequence["audioTracks"][0]["clips"][0] = 3; },
         "sequences[0].audioTracks[0].clips[0]: expected an object, found number"},
        {"tracks that are not a list", [](json &sequence) { sequence["audioTracks"] = true; },
         "sequences[0].audioTracks: expected an array, found boolean"},
    };
    for (const Damage &damage : damages) {
        CAPTURE(damage.what);
        for (const char *name : {"project-v1", "project-v4", "project-v5", "project-v6", "project-v7"}) {
            CAPTURE(name);
            json document = readJson(std::string(name) + ".json");
            damage.apply(document.at("sequences")[0]);
            const ProjectLoadResult loaded = projectFromJson(document);
            REQUIRE_FALSE(loaded.ok());
            CHECK(loaded.error == damage.message);
        }
    }
    // A span that is not an object, in a version 5 and a version 6 file (spans exist from version 5).
    for (const char *name : {"project-v5", "project-v6", "project-v7"}) {
        CAPTURE(name);
        json document = readJson(std::string(name) + ".json");
        json &clip = document.at("sequences")[0].at("videoTracks")[0].at("clips")[0];
        REQUIRE(clip.at("spans").size() > 1);
        clip.at("spans")[1] = "span";
        const ProjectLoadResult loaded = projectFromJson(document);
        REQUIRE_FALSE(loaded.ok());
        CHECK(loaded.error == "sequences[0].videoTracks[0].clips[0].spans[1]: expected an object, found string");
    }
}
