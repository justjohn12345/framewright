// The frozen migration steps against the version 10 golden fixtures (`golden/v10/`, added with the 9 -> 10
// step; the version 7, 8 and 9 goldens are unchanged), and the version 10 file's titles and colour mattes.
// Every checked-in older project file, migrated to version 10, must give exactly the document and the warnings
// recorded in its `v10/<name>.migrated.json`. The 9 -> 10 step converts nothing (version 10 added an asset's
// "generator" and a clip's "generated"), so each version 10 golden is its version 9 golden with version 10
// written and the warnings naming version 10 as the version the project is saved as (the checked-in version 9
// project's golden is that file with version 10); the test checks that too. `v10/project-v9-adjusted.json` is a
// version 9 file that already holds titles: the step keeps them and warns, and loading then limits, keeps or
// drops values by the version 10 rules. `v10/project-v10.json` is the current writer's output, byte for byte: a
// title with every style on, a lower third, a colour matte and a title in a font this Mac does not have.

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

constexpr int kVersion10 = 10;

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
    const char *name;  // its golden is v10/<name>.migrated.json
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
};

json goldenOf(const Fixture &fixture) {
    return readJson(std::string("v10/") + fixture.name + ".migrated.json");
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

bool hasNoVersion9Golden(const Fixture &fixture) {
    return fixture.version == 9; // the version 9 inputs: their golden is the file itself with version 10
}

} // namespace

TEST_CASE("Migration goldens v10: every older version migrates to its version 10 document and warnings") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        json document = readJson(fixture.input);
        REQUIRE(document.at("schemaVersion") == fixture.version);
        const json golden = goldenOf(fixture);
        REQUIRE(golden.at("migratedTo") == kVersion10);
        std::vector<std::string> warnings;
        const auto error = migrateProjectJson(document, fixture.version, kVersion10, warnings);
        REQUIRE_MESSAGE(!error.has_value(), doctest::String(error.value_or("").c_str()));
        CHECK(document.at("schemaVersion") == kVersion10);
        CHECK_MESSAGE(document == golden.at("document"),
                      doctest::String(differences(document, golden.at("document")).c_str()));
        CHECK(warnings == warningsOf(golden));
    }
}

TEST_CASE("Migration goldens v10: the 9 -> 10 step changes only the version") {
    // Each version 10 golden of a file with a version 9 golden is that golden with version 10 and the version
    // saved as in its warnings; the step, run on each version 9 golden document, gives the version 10 one with
    // no warning of its own.
    for (const Fixture &fixture : kFixtures) {
        if (hasNoVersion9Golden(fixture)) {
            continue;
        }
        CAPTURE(fixture.name);
        const json golden9 = readJson(std::string("v9/") + fixture.name + ".migrated.json");
        const json golden10 = goldenOf(fixture);
        json expected = golden9.at("document");
        expected["schemaVersion"] = kVersion10;
        CHECK(golden10.at("document") == expected);
        CHECK(warningsOf(golden10) == savedAs(warningsOf(golden9), 9, kVersion10));
        json document = golden9.at("document");
        std::vector<std::string> warnings;
        REQUIRE_FALSE(migrateProjectJson(document, 9, kVersion10, warnings).has_value());
        CHECK(document == expected);
        CHECK(warnings.empty());
    }
    // The checked-in version 9 project: only its version changes, and its golden says so.
    json document = readJson("v9/project-v9.json");
    json expected = document;
    expected["schemaVersion"] = kVersion10;
    std::vector<std::string> warnings;
    REQUIRE_FALSE(migrateProjectJson(document, 9, kVersion10, warnings).has_value());
    CHECK(document == expected);
    CHECK(warnings.empty());
    const json golden = readJson("v10/project-v9.migrated.json");
    CHECK(golden.at("document") == expected);
    CHECK(warningsOf(golden).empty());
}

TEST_CASE("Migration goldens v10: a version 9 file holding titles keeps them, by the version 10 rules") {
    const Fixture &fixture = kFixtures[std::size(kFixtures) - 1];
    REQUIRE(std::string(fixture.name) == "project-v9-adjusted");
    const std::vector<std::string> stepWarnings = warningsOf(goldenOf(fixture));
    // One per generator asset and one per generated clip.
    REQUIRE(stepWarnings.size() == 6);
    CHECK(stepWarnings[0] == "assets[5].generator: is a version 10 feature in a project of an earlier version: kept, "
                             "and the project is saved as version 10");
    const ProjectLoadResult loaded = projectFromJson(readJson(fixture.input));
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    // The step's warnings, then the parser's: the size limited, the colour limited, the unknown key kept, the
    // unknown alignment read as centre, the grade on a title dropped.
    std::vector<std::string> expected = savedAs(stepWarnings, kVersion10, kProjectSchemaVersion);
    expected.push_back("sequences[0].videoTracks[2].clips[0].generated.glow: unknown title parameter \"glow\" (from a "
                       "newer version of Framewright?); kept as it is and saved with the project, but not drawn or "
                       "editable");
    expected.push_back("sequences[0].videoTracks[2].clips[0].generated.size: Size 1.5 is outside its range [0.005, "
                       "1.0]; limited to 1.0");
    expected.push_back("sequences[0].videoTracks[2].clips[1].generated.alignment: unknown alignment \"justified\" "
                       "(from a newer version of Framewright?); using centre");
    expected.push_back("sequences[0].videoTracks[2].clips[1].generated.fillColour: the title's Fill Colour "
                       "[1.0,2.0,0.0] has a component outside [0, 1]; limited to [1.0,1.0,0.0]");
    expected.push_back("clip 32: a Title clip has no grade; dropped");
    CHECK(loaded.warnings == expected);
    const Project &project = *loaded.project;
    const Sequence &sequence = project.sequences[0];
    const Clip *first = sequence.findClip(ClipId{32});
    REQUIRE(first != nullptr);
    REQUIRE(first->generated);
    CHECK(first->generated->title().size == 1.0);
    CHECK(first->generated->foreign() == "{\"glow\":{\"radius\":0.01}}");
    CHECK(first->grade.isEmpty());
    const Clip *second = sequence.findClip(ClipId{33});
    REQUIRE(second != nullptr);
    CHECK(second->generated->title().alignment == TitleAlignment::Centre);
    CHECK(second->generated->title().fillColour == SRGBColour{1.0, 1.0, 0.0});
    // Saved in the current version: the unknown key goes back as it came.
    const json saved = projectToJson(project);
    CHECK(saved.at("schemaVersion") == kProjectSchemaVersion);
    CHECK(saved.at("sequences")[0].at("videoTracks")[2].at("clips")[0].at("generated").at("glow") ==
          json{{"radius", 0.01}});
    const ProjectLoadResult again = projectFromJson(saved);
    REQUIRE(again.ok());
    CHECK(again.warnings == std::vector<std::string>{
                                "sequences[0].videoTracks[2].clips[0].generated.glow: unknown title parameter \"glow\" "
                                "(from a newer version of Framewright?); kept as it is and saved with the project, but "
                                "not drawn or editable"});
    CHECK(*again.project == project);
}

TEST_CASE("Migration goldens v10: a golden document loads as the project its older file loads as") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        const json golden = goldenOf(fixture);
        const ProjectLoadResult fromOlder = projectFromJson(readJson(fixture.input));
        const ProjectLoadResult fromGolden = projectFromJson(golden.at("document"));
        REQUIRE_MESSAGE(fromOlder.ok(), doctest::String(fromOlder.error.c_str()));
        REQUIRE_MESSAGE(fromGolden.ok(), doctest::String(fromGolden.error.c_str()));
        CHECK(*fromOlder.project == *fromGolden.project);
        std::vector<std::string> expected = savedAs(warningsOf(golden), kVersion10, kProjectSchemaVersion);
        expected.insert(expected.end(), fromGolden.warnings.begin(), fromGolden.warnings.end());
        CHECK(fromOlder.warnings == expected);
    }
}

TEST_CASE("Migration goldens v10: migrating in parts gives the same result as at once") {
    for (const Fixture &fixture : kFixtures) {
        CAPTURE(fixture.name);
        const json original = readJson(fixture.input);
        const json golden = goldenOf(fixture);
        for (int middle = fixture.version; middle <= kVersion10; ++middle) {
            CAPTURE(middle);
            json document = original;
            std::vector<std::string> first;
            REQUIRE_FALSE(migrateProjectJson(document, fixture.version, middle, first).has_value());
            std::vector<std::string> second;
            REQUIRE_FALSE(migrateProjectJson(document, middle, kVersion10, second).has_value());
            CHECK(document == golden.at("document"));
            std::vector<std::string> warnings = savedAs(first, middle, kVersion10);
            warnings.insert(warnings.end(), second.begin(), second.end());
            CHECK(warnings == warningsOf(golden));
        }
    }
}

TEST_CASE("Migration goldens v10: every checked-in older project file has a version 10 golden") {
    std::set<std::string> listed;
    std::set<int> versions;
    for (const Fixture &fixture : kFixtures) {
        listed.insert(fixture.input);
        versions.insert(fixture.version);
    }
    for (int version = 1; version < kVersion10; ++version) {
        CHECK(versions.count(version) == 1);
    }
    std::set<std::string> inputs;
    for (const char *directory : {"", "v8/", "v9/", "v10/"}) {
        for (const auto &entry : std::filesystem::directory_iterator(goldenDirectory() + directory)) {
            const std::string file = entry.path().filename().string();
            const bool project = file.rfind("project-v", 0) == 0 && entry.path().extension() == ".json";
            const bool derived =
                file.find(".migrated.") != std::string::npos || file.find(".expected.") != std::string::npos;
            if (project && !derived && file != "project-v10.json") {
                inputs.insert(std::string(directory) + file);
            }
        }
    }
    CHECK(inputs == listed);
    std::set<std::string> goldens;
    for (const auto &entry : std::filesystem::directory_iterator(goldenDirectory() + "v10/")) {
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

// The checked-in version 9 project with what version 10 added, on a new video track V3 (and a matte under
// everything on V1): a title with every style on (an installed font, outline, shadow, box, right-aligned, two
// lines), a lower third in the system font, a title in a font no Mac has, and a colour matte.
Project richProjectV10() {
    const ProjectLoadResult base = projectFromJson(readJson("v9/project-v9.json"));
    REQUIRE(base.ok());
    Project project = *base.project;
    const AssetId titles = project.addAsset(makeGeneratorAsset(GeneratorKind::Title));
    const AssetId mattes = project.addAsset(makeGeneratorAsset(GeneratorKind::ColourMatte));
    Sequence &sequence = project.sequences[0];
    Track v3;
    v3.id = project.ids.make<TrackId>();
    v3.kind = TrackKind::Video;
    v3.name = "V3";
    sequence.videoTracks.push_back(v3);
    auto add = [&](TrackId track, AssetId asset, std::int64_t start, std::int64_t frames,
                   std::shared_ptr<const GeneratedContent> content) {
        Clip clip;
        clip.id = project.ids.make<ClipId>();
        clip.assetId = asset;
        clip.trackId = track;
        clip.timelineStart = CMTimeMake(start, 30);
        clip.timelineDuration = CMTimeMake(frames, 30);
        clip.isStill = true;
        clip.generated = std::move(content);
        Track &t = *sequence.findTrack(track);
        t.clips.push_back(std::move(clip));
        t.sortClips();
        return t.clips.back().id;
    };
    TitleContent every;
    every.text = "Every Style\nSecond line";
    every.font = TitleFont::named("Helvetica-Bold", "Helvetica", "Bold");
    every.size = 0.08;
    every.fillColour = SRGBColour{1.0, 0.85, 0.25};
    every.alignment = TitleAlignment::Right;
    every.lineSpacing = 1.25;
    every.tracking = 50.0;
    every.outline = true;
    every.outlineColour = SRGBColour{0.125, 0.125, 0.375};
    every.outlineWidth = 0.004;
    every.shadow = true;
    every.shadowColour = SRGBColour{0.0, 0.0, 0.25};
    every.shadowOpacity = 0.75;
    every.shadowAngle = 120.0;
    every.shadowDistance = 0.005;
    every.shadowBlur = 0.006;
    every.box = true;
    every.boxColour = SRGBColour{0.25, 0.375, 0.5};
    every.boxOpacity = 0.5;
    every.boxPadding = 0.02;
    every.boxCornerRadius = 0.01;
    every.x = 0.625;
    every.y = 0.25;
    every.width = 0.5;
    add(sequence.videoTracks[2].id, titles, 0, 90, GeneratedContent::makeTitle(every));
    TitleContent lower = titlePreset(GeneratedPreset::LowerThird);
    lower.text = "Jane Doe\nDirector";
    lower.font = TitleFont::system(SystemFontWeight::Bold);
    add(sequence.videoTracks[2].id, titles, 120, 150, GeneratedContent::makeTitle(lower));
    TitleContent missing;
    missing.text = "Missing font";
    missing.font = TitleFont::named("NoSuchFont-Bold", "No Such Font", "Bold");
    add(sequence.videoTracks[2].id, titles, 300, 60, GeneratedContent::makeTitle(missing));
    add(sequence.videoTracks[0].id, mattes, 150, 60, GeneratedContent::makeMatte(SRGBColour{0.125, 0.25, 0.5}));
    const auto problem = validateProject(project);
    REQUIRE_MESSAGE(!problem, doctest::String(problem.value_or("").c_str()));
    return project;
}

} // namespace

TEST_CASE("Migration goldens v10: the checked-in version 10 project matches the current writer byte for byte") {
    const Project expected = richProjectV10();
    const std::string written = serializeProject(expected) + "\n";
    const std::string text = readText("v10/project-v10.json"); // checked in, never written by the test
    CHECK(text == written);
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == expected);
    // The system font is saved as its weight, never by a private name; the missing font by its name.
    const json document = json::parse(text);
    const json &v3 = document.at("sequences")[0].at("videoTracks")[2];
    CHECK(v3.at("clips")[1].at("generated").at("font") == json{{"system", "bold"}});
    CHECK(v3.at("clips")[2].at("generated").at("font") ==
          json{{"name", "NoSuchFont-Bold"}, {"family", "No Such Font"}, {"style", "Bold"}});
    CHECK(text.find(".SFNS") == std::string::npos);
    // An unused generator asset is not written (the next title makes it again).
    Project unused = expected;
    for (Track &track : unused.sequences[0].videoTracks) {
        std::erase_if(track.clips, [&](const Clip &clip) {
            return unused.findAsset(clip.assetId)->generator == GeneratorKind::ColourMatte;
        });
    }
    const json withoutMatte = projectToJson(unused);
    for (const json &asset : withoutMatte.at("assets")) {
        CHECK(asset.value("generator", "") != "colourMatte");
    }
    CHECK(withoutMatte.at("assets").size() == document.at("assets").size() - 1);
    const ProjectLoadResult reopened = projectFromJson(withoutMatte);
    REQUIRE(reopened.ok());
    CHECK(reopened.project->assets.size() == expected.assets.size() - 1);
}
