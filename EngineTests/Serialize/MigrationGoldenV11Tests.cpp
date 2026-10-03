// The frozen migration steps against the version 11 golden fixtures (`golden/v11/`, added with the 10 -> 11 step;
// the version 7 to 10 goldens are unchanged), and the version 11 file's point text and vertical anchor. Every
// checked-in older project file, migrated to version 11, must give exactly the document and the warnings recorded in
// its `v11/<name>.migrated.json`. The 10 -> 11 step converts nothing (version 11 added a title's "pointText" and
// "anchor"; without them a title is area text anchored at its centre, as version 10 draws it), so each version 11
// golden is its version 10 golden with version 11 written and the warnings naming version 11 as the version the
// project is saved as (the checked-in version 10 project's golden is that file with version 11); the test checks
// that too. `v11/project-v10-adjusted.json` is a version 10 file whose titles already hold the version 11 keys (one
// anchor this version does not know): the step keeps them and warns, and loading then reads them by the version 11
// rules. `v11/project-v11.json` is the current writer's output, byte for byte: the version 10 project with a caption
// (point text anchored at its top) and an area title anchored at its bottom.

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

constexpr int kVersion11 = 11;

std::string goldenDirectory() {
    const std::string here = __FILE__;
    return here.substr(0, here.find_last_of('/')) + "/golden/";
}

std::string readText(const std::string &relativePath) {
    const std::string path = goldenDirectory() + relativePath;
    std::ifstream in(path, std::ios::binary);
    REQUIRE_MESSAGE(in.good(), doctest::String(("cannot open " + path).c_str()));
    std::ostringstream text;
    text << in.rdbuf();
    return text.str();
}

json readJson(const std::string &relativePath) {
    return json::parse(readText(relativePath));
}

struct Fixture {
    const char *input; // relative to golden/
    const char *name;  // its golden is v11/<name>.migrated.json
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
    {"v9/project-v9.json", "project-v9", 9},
    {"v10/project-v9-adjusted.json", "project-v9-adjusted", 9},
    {"v10/project-v10.json", "project-v10", 10},
    {"v11/project-v10-adjusted.json", "project-v10-adjusted", 10},
};

json goldenOf(const Fixture &fixture) {
    return readJson(std::string("v11/") + fixture.name + ".migrated.json");
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

bool hasNoVersion10Golden(const Fixture &fixture) {
    return fixture.version == 10; // the version 10 inputs: their golden is the file itself with version 11
}

} // namespace

TEST_CASE("Migration goldens v11: every older version migrates to its version 11 document and warnings") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        json document = readJson(fixture.input);
        REQUIRE(document.at("schemaVersion") == fixture.version);
        const json golden = goldenOf(fixture);
        REQUIRE(golden.at("migratedTo") == kVersion11);
        std::vector<std::string> warnings;
        const auto error = migrateProjectJson(document, fixture.version, kVersion11, warnings);
        REQUIRE_MESSAGE(!error.has_value(), doctest::String(error.value_or("").c_str()));
        CHECK(document.at("schemaVersion") == kVersion11);
        CHECK_MESSAGE(document == golden.at("document"),
                      doctest::String(differences(document, golden.at("document")).c_str()));
        CHECK(warnings == warningsOf(golden));
    }
}

TEST_CASE("Migration goldens v11: the 10 -> 11 step changes only the version") {
    // Each version 11 golden of a file with a version 10 golden is that golden with version 11 and the version
    // saved as in its warnings; the step, run on each version 10 golden document, gives the version 11 one with no
    // warning of its own.
    for (const Fixture &fixture : kFixtures) {
        if (hasNoVersion10Golden(fixture)) {
            continue;
        }
        CAPTURE(fixture.name);
        const json golden10 = readJson(std::string("v10/") + fixture.name + ".migrated.json");
        const json golden11 = goldenOf(fixture);
        json expected = golden10.at("document");
        expected["schemaVersion"] = kVersion11;
        CHECK(golden11.at("document") == expected);
        CHECK(warningsOf(golden11) == savedAs(warningsOf(golden10), 10, kVersion11));
        json document = golden10.at("document");
        std::vector<std::string> warnings;
        REQUIRE_FALSE(migrateProjectJson(document, 10, kVersion11, warnings).has_value());
        CHECK(document == expected);
        CHECK(warnings.empty());
    }
    // The checked-in version 10 project: only its version changes, and its golden says so.
    json document = readJson("v10/project-v10.json");
    json expected = document;
    expected["schemaVersion"] = kVersion11;
    std::vector<std::string> warnings;
    REQUIRE_FALSE(migrateProjectJson(document, 10, kVersion11, warnings).has_value());
    CHECK(document == expected);
    CHECK(warnings.empty());
    const json golden = readJson("v11/project-v10.migrated.json");
    CHECK(golden.at("document") == expected);
    CHECK(warningsOf(golden).empty());
}

TEST_CASE("Migration goldens v11: a version 10 file holding point text and anchors keeps them, by the version 11 "
          "rules") {
    const Fixture &fixture = kFixtures[std::size(kFixtures) - 1];
    REQUIRE(std::string(fixture.name) == "project-v10-adjusted");
    const std::vector<std::string> stepWarnings = warningsOf(goldenOf(fixture));
    // One per version 11 key of a title.
    REQUIRE(stepWarnings.size() == 3);
    CHECK(stepWarnings[0] == "sequences[0].videoTracks[2].clips[0].generated.pointText: is a version 11 feature in a "
                             "project of an earlier version: kept, and the project is saved as version 11");
    const ProjectLoadResult loaded = projectFromJson(readJson(fixture.input));
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    // The step's warnings, then the parser's: the anchor it does not know read as centre.
    std::vector<std::string> expected = savedAs(stepWarnings, kVersion11, kProjectSchemaVersion);
    expected.push_back("sequences[0].videoTracks[2].clips[1].generated.anchor: unknown anchor \"sideways\" (from a "
                       "newer version of Framewright?); using centre");
    CHECK(loaded.warnings == expected);
    const Sequence &sequence = loaded.project->sequences[0];
    const Clip *first = sequence.findClip(ClipId{32});
    REQUIRE(first != nullptr);
    REQUIRE(first->generated);
    CHECK(first->generated->title().pointText);
    CHECK(first->generated->title().anchor == TitleAnchor::Top);
    CHECK(first->generated->foreign().empty()); // read, not kept as foreign
    const Clip *second = sequence.findClip(ClipId{33});
    REQUIRE(second != nullptr);
    CHECK_FALSE(second->generated->title().pointText);
    CHECK(second->generated->title().anchor == TitleAnchor::Centre);
    // Saved in the current version, and loads back without a warning.
    const json saved = projectToJson(*loaded.project);
    CHECK(saved.at("schemaVersion") == kProjectSchemaVersion);
    const json &title = saved.at("sequences")[0].at("videoTracks")[2].at("clips")[0].at("generated");
    CHECK(title.at("pointText") == true);
    CHECK(title.at("anchor") == "top");
    const ProjectLoadResult again = projectFromJson(saved);
    REQUIRE(again.ok());
    CHECK(again.warnings.empty());
    CHECK(*again.project == *loaded.project);
}

TEST_CASE("Migration goldens v11: a golden document loads as the project its older file loads as") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        const json golden = goldenOf(fixture);
        const ProjectLoadResult fromOlder = projectFromJson(readJson(fixture.input));
        const ProjectLoadResult fromGolden = projectFromJson(golden.at("document"));
        REQUIRE_MESSAGE(fromOlder.ok(), doctest::String(fromOlder.error.c_str()));
        REQUIRE_MESSAGE(fromGolden.ok(), doctest::String(fromGolden.error.c_str()));
        CHECK(*fromOlder.project == *fromGolden.project);
        std::vector<std::string> expected = savedAs(warningsOf(golden), kVersion11, kProjectSchemaVersion);
        expected.insert(expected.end(), fromGolden.warnings.begin(), fromGolden.warnings.end());
        CHECK(fromOlder.warnings == expected);
    }
}

TEST_CASE("Migration goldens v11: migrating in parts gives the same result as at once") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        const json original = readJson(fixture.input);
        const json golden = goldenOf(fixture);
        for (int middle = fixture.version; middle <= kVersion11; ++middle) {
            CAPTURE(middle);
            json document = original;
            std::vector<std::string> first;
            REQUIRE_FALSE(migrateProjectJson(document, fixture.version, middle, first).has_value());
            std::vector<std::string> second;
            REQUIRE_FALSE(migrateProjectJson(document, middle, kVersion11, second).has_value());
            CHECK(document == golden.at("document"));
            std::vector<std::string> warnings = savedAs(first, middle, kVersion11);
            warnings.insert(warnings.end(), second.begin(), second.end());
            CHECK(warnings == warningsOf(golden));
        }
    }
}

TEST_CASE("Migration goldens v11: every checked-in older project file has a version 11 golden") {
    std::set<std::string> listed;
    std::set<int> versions;
    for (const Fixture &fixture : kFixtures) {
        listed.insert(fixture.input);
        versions.insert(fixture.version);
    }
    for (int version = 1; version < kVersion11; ++version) {
        CHECK(versions.count(version) >= 1);
    }
    std::set<std::string> inputs;
    for (const char *directory : {"", "v8/", "v9/", "v10/", "v11/"}) {
        for (const auto &entry : std::filesystem::directory_iterator(goldenDirectory() + directory)) {
            const std::string file = entry.path().filename().string();
            const bool project = file.rfind("project-v", 0) == 0 && entry.path().extension() == ".json";
            const bool derived =
                file.find(".migrated.") != std::string::npos || file.find(".expected.") != std::string::npos;
            if (project && !derived && file != "project-v11.json") {
                inputs.insert(std::string(directory) + file);
            }
        }
    }
    CHECK(inputs == listed);
    std::set<std::string> goldens;
    for (const auto &entry : std::filesystem::directory_iterator(goldenDirectory() + "v11/")) {
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

// The checked-in version 10 project with what version 11 added, on a new video track V4: a caption (point text,
// left-aligned, anchored at its top: it grows down and to the right from its top-left corner) and a two-line area
// title anchored at its bottom (it grows up).
Project richProjectV11() {
    const ProjectLoadResult base = projectFromJson(readJson("v10/project-v10.json"));
    REQUIRE(base.ok());
    Project project = *base.project;
    const MediaAsset *titles = project.findGeneratorAsset(GeneratorKind::Title);
    REQUIRE(titles != nullptr);
    const AssetId titleAsset = titles->id;
    Sequence &sequence = project.sequences[0];
    Track v4;
    v4.id = project.ids.make<TrackId>();
    v4.kind = TrackKind::Video;
    v4.name = "V4";
    sequence.videoTracks.push_back(v4);
    auto add = [&](std::int64_t start, std::int64_t frames, TitleContent content) {
        Clip clip;
        clip.id = project.ids.make<ClipId>();
        clip.assetId = titleAsset;
        clip.trackId = v4.id;
        clip.timelineStart = CMTimeMake(start, 30);
        clip.timelineDuration = CMTimeMake(frames, 30);
        clip.isStill = true;
        clip.generated = GeneratedContent::makeTitle(std::move(content));
        Track &t = *sequence.findTrack(v4.id);
        t.clips.push_back(std::move(clip));
        t.sortClips();
    };
    TitleContent caption;
    caption.text = "A caption that grows\nfrom its corner";
    caption.size = 0.04;
    caption.alignment = TitleAlignment::Left;
    caption.pointText = true;
    caption.anchor = TitleAnchor::Top;
    caption.x = 0.055;
    caption.y = 0.055;
    add(0, 60, caption);
    TitleContent rising;
    rising.text = "Lines added\ngrow upwards";
    rising.anchor = TitleAnchor::Bottom;
    rising.y = 0.85;
    rising.width = 0.6;
    add(90, 60, rising);
    const auto problem = validateProject(project);
    REQUIRE_MESSAGE(!problem, doctest::String(problem.value_or("").c_str()));
    return project;
}

} // namespace

TEST_CASE("Migration goldens v11: the checked-in version 11 project matches the current writer byte for byte") {
    const Project expected = richProjectV11();
    const std::string written = serializeProject(expected) + "\n";
    const std::string text = readText("v11/project-v11.json"); // checked in, never written by the test
    CHECK(text == written);
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == expected);
    // Every title writes both version 11 keys, the slice 1 titles their defaults.
    const json document = json::parse(text);
    const json &v3 = document.at("sequences")[0].at("videoTracks")[2];
    CHECK(v3.at("clips")[0].at("generated").at("pointText") == false);
    CHECK(v3.at("clips")[0].at("generated").at("anchor") == "centre");
    const json &v4 = document.at("sequences")[0].at("videoTracks")[3];
    CHECK(v4.at("clips")[0].at("generated").at("pointText") == true);
    CHECK(v4.at("clips")[0].at("generated").at("anchor") == "top");
    CHECK(v4.at("clips")[1].at("generated").at("pointText") == false);
    CHECK(v4.at("clips")[1].at("generated").at("anchor") == "bottom");
}
