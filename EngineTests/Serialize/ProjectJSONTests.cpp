#include "../Model/ModelFixtures.h"

#include <fstream>
#include <sstream>

using namespace vetest;
using nlohmann::json;

namespace {

// A project using every serialized feature.
Fixture richFixture() {
    Fixture fx;
    fx.project.name = "Round trip \xE2\x9C\x93"; // UTF-8
    const auto [v, a] = fx.addLinkedPair(0, 60, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    fx.addTransition(fx.v1, v, b, 12);
    fx.addClip(fx.v2, fx.video60, 30, 45, 0, 0.5);
    fx.addClip(fx.v2, fx.still, 100, 150);
    const ClipId music = fx.addClip(fx.a2, fx.audioOnly, 0, 90, 0, 1.0 / 3.0);
    Clip &m = *fx.sequence().findClip(music);
    m.audio = AudioParams{-4.5, f30(10), CMTimeMake(7, 48000)};
    Clip &vc = *fx.sequence().findClip(v);
    vc.video = VideoParams{12.25, -8.5, 1.1, 33.3, 0.8};
    Track &v2 = fx.track(fx.v2);
    v2.muted = true;
    v2.solo = true;
    fx.track(fx.a1).locked = true;
    fx.track(fx.a1).name = "Dialogue \"main\"";

    MediaAsset &vfr = *fx.project.findAsset(fx.video60);
    vfr.isVFR = true;
    fx.project.findAsset(fx.audioOnly)->frameDuration = kCMTimeIndefinite; // non-numeric times survive too
    fx.project.findAsset(fx.av30)->rotationDegrees = 90;

    fx.project.addSequence("Second", CMTimeMake(1001, 30000), 1280, 720, 1, 0);
    fx.requireValid();
    return fx;
}

std::string loadError(const json &document) {
    const ProjectLoadResult result = projectFromJson(document);
    CHECK_FALSE(result.ok());
    return result.error;
}

bool contains(const std::string &haystack, const std::string &needle) {
    return haystack.find(needle) != std::string::npos;
}

bool anyContains(const std::vector<std::string> &list, const std::string &needle) {
    return std::any_of(list.begin(), list.end(), [&](const std::string &s) { return contains(s, needle); });
}

std::string goldenPath(const char *name) {
    const std::string here = __FILE__;
    return here.substr(0, here.find_last_of('/')) + "/golden/" + name;
}

std::string readFile(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    REQUIRE_MESSAGE(in.good(), doctest::String(("cannot open " + path).c_str()));
    std::ostringstream text;
    text << in.rdbuf();
    return text.str();
}

// The golden version 1 project as the current model expresses it.
Fixture goldenFixture() {
    Fixture fx;
    fx.project.name = "Golden v1 \xE2\x9C\x93";
    MediaAsset music;
    music.name = "music 44k.m4a";
    music.url = "/Volumes/Media/music 44k.m4a";
    music.kind = AssetKind::Audio;
    music.duration = CMTimeMake(30 * 44100 + 17, 44100);
    music.audioSampleRate = 44100;
    music.audioChannels = 2;
    music.backendHint = "apple";
    const AssetId music44 = fx.project.addAsset(music);
    const auto [v, a] = fx.addLinkedPair(0, 60, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    fx.addTransition(fx.v1, v, b, 12);
    fx.addClip(fx.v2, fx.video60, 30, 45, 0, 0.5);
    fx.addClip(fx.v2, fx.still, 100, 150);
    const ClipId m = fx.addClip(fx.a2, fx.audioOnly, 0, 90, 0, 1.0 / 3.0);
    fx.sequence().findClip(m)->audio = AudioParams{-4.5, f30(10), CMTimeMake(7, 48000)};
    Clip c;
    c.id = fx.project.ids.make<ClipId>();
    c.assetId = music44;
    c.trackId = fx.a2;
    c.timelineStart = f30(90);
    c.sourceIn = CMTimeMake(44101, 44100);
    c.timelineDuration = f30(60);
    fx.track(fx.a2).clips.push_back(c);
    fx.sequence().findClip(v)->video = VideoParams{12.25, -8.5, 1.1, 33.3, 0.8};
    fx.track(fx.v2).muted = true;
    fx.track(fx.v2).solo = true;
    fx.track(fx.a1).locked = true;
    fx.track(fx.a1).name = "Dialogue \"main\"";
    fx.project.findAsset(fx.video60)->isVFR = true;
    const SequenceId second = fx.project.addSequence("NTSC", CMTimeMake(1001, 30000), 1280, 720, 1, 0);
    Sequence &s2 = *fx.project.findSequence(second);
    Clip n;
    n.id = fx.project.ids.make<ClipId>();
    n.assetId = fx.av24;
    n.trackId = s2.videoTracks[0].id;
    n.timelineStart = CMTimeMake(1001 * 10, 30000);
    n.sourceIn = CMTimeMake(1001 * 5, 24000);
    n.timelineDuration = CMTimeMake(1001 * 48, 30000);
    s2.videoTracks[0].clips.push_back(n);
    fx.requireValid();
    return fx;
}

// The golden project after the schema 2 -> 3 migration: video and A/V assets' video lasts their
// duration (version 2 did not record where the video ends).
Fixture migratedGoldenFixture() {
    Fixture fx = goldenFixture();
    for (MediaAsset &asset : fx.project.assets) {
        if (asset.kind == AssetKind::Video || asset.kind == AssetKind::AudioVideo) {
            asset.videoDuration = asset.duration;
        }
    }
    fx.requireValid();
    return fx;
}

// A minimal version 1 document with one clip on V1 of a 30 fps sequence; `clip` fields are
// merged over the defaults.
json v1Document(const json &clipFields, CMTime frameDuration = CMTimeMake(1, 30)) {
    json clip = {{"id", 4},
                 {"assetId", 1},
                 {"trackId", 3},
                 {"timelineStart", timeToJson(CMTimeMake(0, 30))},
                 {"sourceIn", timeToJson(CMTimeMake(0, 30))},
                 {"sourceOut", timeToJson(CMTimeMake(30, 30))},
                 {"speed", 1.0}};
    for (auto it = clipFields.begin(); it != clipFields.end(); ++it) {
        clip[it.key()] = it.value();
    }
    return json{{"schemaVersion", 1},
                {"name", "v1"},
                {"nextId", 5},
                {"activeSequenceId", 2},
                {"assets", json::array({json{{"id", 1},
                                             {"name", "a.wav"},
                                             {"url", "/a.wav"},
                                             {"kind", "audio"},
                                             {"duration", timeToJson(CMTimeMake(60 * 44100, 44100))},
                                             {"audioSampleRate", 44100},
                                             {"audioChannels", 2}}})},
                {"sequences",
                 json::array({json{{"id", 2},
                                   {"name", "S"},
                                   {"frameDuration", timeToJson(frameDuration)},
                                   {"width", 1920},
                                   {"height", 1080},
                                   {"videoTracks", json::array()},
                                   {"audioTracks", json::array({json{{"id", 3},
                                                                     {"kind", "audio"},
                                                                     {"name", "A1"},
                                                                     {"clips", json::array({clip})}}})},
                                   {"transitions", json::array()}}})}};
}

} // namespace

TEST_CASE("ProjectJSON: round trip is lossless") {
    const Fixture fx = richFixture();
    const std::string text = serializeProject(fx.project);
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == fx.project);
    CHECK(serializeProject(*loaded.project) == text);
    CHECK(projectToJson(*loaded.project) == projectToJson(fx.project));
    CHECK(loaded.project->ids == fx.project.ids);

    // Compact output parses to the same project.
    const ProjectLoadResult compact = parseProject(serializeProject(fx.project, -1));
    REQUIRE(compact.ok());
    CHECK(*compact.project == fx.project);
}

TEST_CASE("ProjectJSON: format details") {
    const Fixture fx = richFixture();
    const json j = projectToJson(fx.project);
    CHECK(j.at("schemaVersion") == kProjectSchemaVersion);
    CHECK(kProjectSchemaVersion == 3);
    CHECK(j.at("nextId") == fx.project.ids.nextValue());
    const json &clip = j.at("sequences")[0].at("videoTracks")[0].at("clips")[0];
    CHECK(clip.at("timelineStart") == json{{"value", 0}, {"timescale", 30}});
    CHECK(clip.at("duration") == json{{"value", 60}, {"timescale", 30}});
    CHECK(clip.at("sourceIn") == json{{"value", 30}, {"timescale", 30}});
    CHECK(clip.at("speed") == json{{"num", 1}, {"den", 1}});
    CHECK_FALSE(clip.contains("sourceOut")); // derived, never stored
    const json &music = j.at("sequences")[0].at("audioTracks")[1].at("clips")[0];
    CHECK(music.at("speed") == json{{"num", 1}, {"den", 3}});
    CHECK(j.at("assets")[0].at("kind") == "av");
    CHECK(j.at("assets")[0].at("rotationDegrees") == 90);
    CHECK(j.at("sequences")[0].at("transitions")[0].at("kind") == "crossDissolve");

    CHECK(timeToJson(kCMTimeInvalid).is_null());
    CHECK(timeToJson(CMTimeMake(1001, 24000)) == json{{"value", 1001}, {"timescale", 24000}});
    CMTime rounded = CMTimeMake(5, 7);
    rounded.flags |= kCMTimeFlags_HasBeenRounded;
    CHECK(timeToJson(rounded).at("flags") == (kCMTimeFlags_Valid | kCMTimeFlags_HasBeenRounded));
    CMTime epoch = CMTimeMake(5, 7);
    epoch.epoch = 3;
    CHECK(timeToJson(epoch).at("epoch") == 3);
    const json infinity = timeToJson(kCMTimePositiveInfinity);
    CHECK(infinity.contains("flags"));
}

TEST_CASE("ProjectJSON: rotation defaults to zero and round trips") {
    Fixture fx = richFixture();
    json j = projectToJson(fx.project);
    j["assets"][0].erase("rotationDegrees");
    const ProjectLoadResult loaded = projectFromJson(j);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.project->assets[0].rotationDegrees == 0);
    CHECK_FALSE(*loaded.project == fx.project); // rotation takes part in equality
    j["assets"][0]["rotationDegrees"] = 45;
    CHECK(contains(loadError(j), "rotation 45"));
}

TEST_CASE("ProjectJSON: schema version checks") {
    const Fixture fx = richFixture();
    json j = projectToJson(fx.project);

    j["schemaVersion"] = kProjectSchemaVersion + 1;
    const std::string newer = loadError(j);
    CHECK(contains(newer, "schemaVersion"));
    CHECK(contains(newer, "newer"));

    j["schemaVersion"] = 0;
    CHECK(contains(loadError(j), "invalid schema version 0"));

    j["schemaVersion"] = "1";
    CHECK(contains(loadError(j), "schemaVersion: expected an integer"));

    j.erase("schemaVersion");
    CHECK(contains(loadError(j), "not a Framewright project"));

    std::vector<std::string> warnings;
    json doc = projectToJson(fx.project);
    CHECK(migrateProjectJson(doc, 0, warnings).has_value());
    CHECK(migrateProjectJson(doc, kProjectSchemaVersion + 1, warnings).has_value());
    CHECK_FALSE(migrateProjectJson(doc, kProjectSchemaVersion, warnings).has_value()); // nothing to do
    CHECK(doc == projectToJson(fx.project));
}

TEST_CASE("ProjectJSON: malformed input yields clear errors, never exceptions") {
    SUBCASE("not JSON") {
        for (const char *text : {"", "{", "{\"schemaVersion\": 1,,}", "nul", "[1, 2"}) {
            const ProjectLoadResult r = parseProject(text);
            CHECK_FALSE(r.ok());
            CHECK(contains(r.error, "malformed JSON"));
        }
    }
    SUBCASE("wrong top-level type") {
        CHECK(contains(parseProject("[1,2,3]").error, "(root): expected an object"));
        CHECK(contains(parseProject("42").error, "(root): expected an object"));
    }

    const Fixture fx = richFixture();
    const json good = projectToJson(fx.project);

    SUBCASE("wrong field type reports the JSON path") {
        json j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][1]["timelineStart"] = "soon";
        const std::string error = loadError(j);
        CHECK(contains(error, "sequences[0].videoTracks[0].clips[1].timelineStart"));
        CHECK(contains(error, "expected a time"));
    }
    SUBCASE("missing required field") {
        json j = good;
        j["sequences"][0]["audioTracks"][0]["clips"][0].erase("assetId");
        CHECK(contains(loadError(j), "sequences[0].audioTracks[0].clips[0].assetId: missing required field"));
        j = good;
        j["sequences"][0]["audioTracks"][0]["clips"][0].erase("duration");
        CHECK(contains(loadError(j), "sequences[0].audioTracks[0].clips[0].duration: missing required field"));
    }
    SUBCASE("bad speed") {
        json j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][0]["speed"] = json{{"num", 1}, {"den", 0}};
        CHECK(contains(loadError(j), "speed.den: speed denominator must be positive"));
        j["sequences"][0]["videoTracks"][0]["clips"][0]["speed"] = json{{"num", 2}, {"den", 4}};
        CHECK(contains(loadError(j), "is not a reduced ratio"));
        j["sequences"][0]["videoTracks"][0]["clips"][0]["speed"] = 1.5;
        CHECK(contains(loadError(j), "speed: expected an object"));
    }
    SUBCASE("time object missing its timescale") {
        json j = good;
        j["assets"][1]["duration"] = json{{"value", 10}};
        CHECK(contains(loadError(j), "assets[1].duration.timescale: missing required field"));
    }
    SUBCASE("non-positive timescale") {
        json j = good;
        j["sequences"][0]["frameDuration"] = json{{"value", 1}, {"timescale", 0}};
        CHECK(contains(loadError(j), "timescale must be positive"));
    }
    SUBCASE("bad time flags") {
        json j = good;
        j["sequences"][0]["frameDuration"] = json{{"value", 1}, {"timescale", 30}, {"flags", 0}};
        CHECK(contains(loadError(j), "invalid time flags"));
    }
    SUBCASE("rounded times and epochs are rejected") {
        const json rounded = {{"value", 10}, {"timescale", 30}, {"flags", 3}};
        const json epoch = {{"value", 10}, {"timescale", 30}, {"epoch", 1}};
        json j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][1]["timelineStart"] = json{{"value", 60}, {"timescale", 30}, {"flags", 3}};
        CHECK(contains(loadError(j), "has been rounded"));
        j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][1]["timelineStart"] = json{{"value", 60}, {"timescale", 30}, {"epoch", 1}};
        CHECK(contains(loadError(j), "has epoch 1"));
        j = good;
        j["sequences"][0]["audioTracks"][1]["clips"][0]["audio"]["fadeInDuration"] = rounded;
        CHECK(contains(loadError(j), "fade-in"));
        j = good;
        j["sequences"][0]["transitions"][0]["duration"] = json{{"value", 12}, {"timescale", 30}, {"epoch", 1}};
        CHECK(contains(loadError(j), "whole number of frames"));
        j = good;
        j["assets"][0]["duration"] = epoch;
        CHECK(contains(loadError(j), "has epoch 1"));
    }
    SUBCASE("unknown asset and track kinds are errors") {
        json j = good;
        j["assets"][0]["kind"] = "hologram";
        CHECK(contains(loadError(j), "assets[0].kind: unknown asset kind \"hologram\""));
        j = good;
        j["sequences"][0]["videoTracks"][1]["kind"] = "smell";
        CHECK(contains(loadError(j), "unknown track kind"));
    }
    SUBCASE("negative or oversized ids") {
        json j = good;
        j["assets"][0]["id"] = -4;
        CHECK(contains(loadError(j), "assets[0].id: expected a non-negative integer"));
        j = good;
        j["sequences"][0]["width"] = 5000000000LL;
        CHECK(contains(loadError(j), "out of 32-bit range"));
    }
    SUBCASE("list that is not an array") {
        json j = good;
        j["assets"] = json::object();
        CHECK(contains(loadError(j), "assets: expected an array"));
    }
    SUBCASE("structurally valid JSON that breaks model invariants") {
        json j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][1]["timelineStart"] = json{{"value", 30}, {"timescale", 30}};
        const std::string error = loadError(j);
        CHECK(contains(error, "invalid project"));
        CHECK(contains(error, "overlaps"));
        j = good;
        j["nextId"] = 1;
        CHECK(contains(loadError(j), "id generator"));
    }
    SUBCASE("a transition referencing a missing clip") {
        json j = good;
        j["sequences"][0]["transitions"][0]["toClipId"] = 999;
        CHECK(contains(loadError(j), "are not both on track"));
    }
}

TEST_CASE("ProjectJSON: an unknown transition kind degrades to a cross dissolve with a warning") {
    const Fixture fx = richFixture();
    json j = projectToJson(fx.project);
    j["sequences"][0]["transitions"][0]["kind"] = "wipe";
    const ProjectLoadResult loaded = projectFromJson(j);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(*loaded.project == fx.project);
    REQUIRE(loaded.warnings.size() == 1);
    CHECK(contains(loaded.warnings[0], "sequences[0].transitions[0].kind: unknown transition kind \"wipe\""));
}

TEST_CASE("ProjectJSON: invalid UTF-8 never throws on save") {
    Fixture fx = richFixture();
    fx.project.name = "bad \xC3\x28 bytes \xFF";
    fx.project.findAsset(fx.av30)->url = "/media/\xE2\x82";
    std::string text;
    CHECK_NOTHROW(text = serializeProject(fx.project));
    CHECK(contains(text, "bad \xEF\xBF\xBD( bytes \xEF\xBF\xBD")); // U+FFFD for each bad sequence
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.project->name == "bad \xEF\xBF\xBD( bytes \xEF\xBF\xBD");
}

TEST_CASE("ProjectJSON: unknown fields are ignored and optional fields default") {
    const Fixture fx = richFixture();
    json j = projectToJson(fx.project);
    j["futureFeature"] = json{{"enabled", true}};
    j["assets"][0]["colorSpace"] = "bt2020";
    j["sequences"][0]["markers"] = json::array({1, 2, 3});
    j["sequences"][0]["videoTracks"][0]["clips"][0]["effects"] = json::array();
    const ProjectLoadResult withExtras = projectFromJson(j);
    REQUIRE_MESSAGE(withExtras.ok(), doctest::String(withExtras.error.c_str()));
    CHECK(*withExtras.project == fx.project);

    // Optional fields may be omitted.
    json minimal = projectToJson(fx.project);
    json &clip = minimal["sequences"][0]["videoTracks"][1]["clips"][1]; // the still
    clip.erase("video");
    clip.erase("audio");
    clip.erase("linkedClipId");
    clip.erase("speed");
    minimal["assets"][4].erase("backendHint");
    minimal["assets"][4].erase("frameDuration");
    const ProjectLoadResult loaded = projectFromJson(minimal);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    const Clip *still = loaded.project->findSequence(fx.seq)->videoTracks[1].clipAt(f30(100));
    REQUIRE(still != nullptr);
    CHECK(still->video == VideoParams{});
    CHECK(still->audio == AudioParams{});
    CHECK(still->speed == Ratio{1, 1});
}

TEST_CASE("ProjectJSON: the checked-in version 1 project loads through the migration") {
    const std::string text = readFile(goldenPath("project-v1.json"));
    REQUIRE(json::parse(text).at("schemaVersion") == 1);
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    const Fixture expected = migratedGoldenFixture();
    CHECK(*loaded.project == expected.project);
    // Spot checks of what the migration derived.
    const Sequence &main = *loaded.project->findSequence(expected.seq);
    const Clip &third = main.audioTracks[1].clips[0]; // 1/3 speed, 90 frames of 30 source frames
    CHECK(third.speed == Ratio{1, 3});
    CHECK(identical(third.timelineDuration, CMTimeMake(90, 30)));
    CHECK(third.sourceOut() == CMTimeMake(1, 1));
    const Clip &in44 = main.audioTracks[1].clips[1];
    CHECK(identical(in44.sourceIn, CMTimeMake(44101, 44100)));
    CHECK(identical(in44.timelineDuration, CMTimeMake(60, 30)));
}

TEST_CASE("ProjectJSON: the checked-in version 2 project loads through the migration") {
    const std::string text = readFile(goldenPath("project-v2.json"));
    REQUIRE(json::parse(text).at("schemaVersion") == 2);
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == migratedGoldenFixture().project);
}

TEST_CASE("ProjectJSON: the checked-in version 3 project matches the current writer byte for byte") {
    const std::string text = readFile(goldenPath("project-v3.json"));
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(*loaded.project == migratedGoldenFixture().project);
    CHECK(serializeProject(*loaded.project) + "\n" == text);
}

TEST_CASE("ProjectJSON: version 1 migration") {
    SUBCASE("speed and source out point become an exact speed and a duration") {
        // 44101/44100 + 30 frames * 999/1000 = 881569/441000 (exact in version 1 too).
        const ProjectLoadResult r = projectFromJson(v1Document(json{{"speed", 0.999},
                                                                  {"sourceIn", timeToJson(CMTimeMake(44101, 44100))},
                                                                  {"sourceOut", timeToJson(CMTimeMake(881569, 441000))}}));
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        const Clip &clip = r.project->sequences[0].audioTracks[0].clips[0];
        CHECK(clip.speed == Ratio{999, 1000});
        CHECK(identical(clip.timelineDuration, CMTimeMake(30, 30)));
        CHECK(r.warnings.empty());
    }
    SUBCASE("a rounded source out point is recovered: the duration snaps back to the grid") {
        CMTime out = CMTimeMake(705600000 + 17, kPreciseTimescale); // 1 s + 24 ns, as v1 rounding left it
        out.flags |= kCMTimeFlags_HasBeenRounded;
        const ProjectLoadResult r = projectFromJson(v1Document(json{{"sourceOut", timeToJson(out)}}));
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        CHECK(identical(r.project->sequences[0].audioTracks[0].clips[0].timelineDuration, CMTimeMake(30, 30)));
        CHECK(anyContains(r.warnings, "snapped to"));
    }
    SUBCASE("rounded or epoch-carrying stored times are adopted as exact, with a warning") {
        CMTime in = CMTimeMake(1, 30);
        in.flags |= kCMTimeFlags_HasBeenRounded;
        CMTime out = CMTimeMake(31, 30);
        CMTime start = CMTimeMake(3, 30);
        start.epoch = 4;
        const ProjectLoadResult r = projectFromJson(v1Document(
            json{{"sourceIn", timeToJson(in)}, {"sourceOut", timeToJson(out)}, {"timelineStart", timeToJson(start)}}));
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        const Clip &clip = r.project->sequences[0].audioTracks[0].clips[0];
        CHECK(identical(clip.sourceIn, CMTimeMake(1, 30)));
        CHECK(identical(clip.timelineStart, CMTimeMake(3, 30)));
        CHECK(anyContains(r.warnings, "clips[0].sourceIn"));
        CHECK(anyContains(r.warnings, "clips[0].timelineStart"));
    }
    SUBCASE("overlapping fades are shortened to fit, with a warning") {
        const json audio = {{"gainDb", 0.0},
                            {"fadeInDuration", timeToJson(CMTimeMake(20, 30))},
                            {"fadeOutDuration", timeToJson(CMTimeMake(20, 30))}};
        const ProjectLoadResult r = projectFromJson(v1Document(json{{"audio", audio}}));
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        const Clip &clip = r.project->sequences[0].audioTracks[0].clips[0];
        CHECK(clip.audio.fadeInDuration == CMTimeMake(20, 30));
        CHECK(clip.audio.fadeOutDuration == CMTimeMake(10, 30));
        CHECK(anyContains(r.warnings, "overlapped"));
    }
    SUBCASE("unconvertible values report their path") {
        CHECK(contains(loadError(v1Document(json{{"speed", 500.0}})), "clips[0].speed: speed 500"));
        json noOut = v1Document(json::object());
        noOut["sequences"][0]["audioTracks"][0]["clips"][0].erase("sourceOut");
        CHECK(contains(loadError(noOut), "clips[0].sourceOut: missing required field"));
        CHECK(contains(loadError(v1Document(json{{"sourceOut", timeToJson(CMTimeMake(31, 60))}})),
                       "not a whole number of frames"));
    }
    SUBCASE("migrateProjectJson upgrades in place") {
        json doc = v1Document(json::object());
        std::vector<std::string> warnings;
        REQUIRE_FALSE(migrateProjectJson(doc, 1, warnings).has_value());
        CHECK(doc.at("schemaVersion") == kProjectSchemaVersion);
        const json &clip = doc["sequences"][0]["audioTracks"][0]["clips"][0];
        CHECK_FALSE(clip.contains("sourceOut"));
        CHECK(clip.at("duration") == json{{"value", 30}, {"timescale", 30}});
        CHECK(clip.at("speed") == json{{"num", 1}, {"den", 1}});
        const ProjectLoadResult r = projectFromJson(doc);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
    }
}
