#include "../Model/ModelFixtures.h"

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
    MediaAsset &av = *fx.project.findAsset(fx.av30);
    av.duration.flags |= kCMTimeFlags_HasBeenRounded;
    av.duration.epoch = 3;

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

} // namespace

TEST_CASE("ProjectJSON: round trip is lossless") {
    const Fixture fx = richFixture();
    const std::string text = serializeProject(fx.project);
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
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
    CHECK(j.at("nextId") == fx.project.ids.nextValue());
    const json &clip = j.at("sequences")[0].at("videoTracks")[0].at("clips")[0];
    CHECK(clip.at("timelineStart") == json{{"value", 0}, {"timescale", 30}});
    CHECK(clip.at("sourceIn") == json{{"value", 30}, {"timescale", 30}});
    CHECK(j.at("assets")[0].at("kind") == "av");
    CHECK(j.at("sequences")[0].at("transitions")[0].at("kind") == "crossDissolve");

    CHECK(timeToJson(kCMTimeInvalid).is_null());
    CHECK(timeToJson(CMTimeMake(1001, 24000)) == json{{"value", 1001}, {"timescale", 24000}});
    CMTime rounded = CMTimeMake(5, 7);
    rounded.flags |= kCMTimeFlags_HasBeenRounded;
    CHECK(timeToJson(rounded).at("flags") == (kCMTimeFlags_Valid | kCMTimeFlags_HasBeenRounded));
    const json infinity = timeToJson(kCMTimePositiveInfinity);
    CHECK(infinity.contains("flags"));
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
    CHECK(contains(loadError(j), "not a VidEdit project"));
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
    SUBCASE("unknown enum value") {
        json j = good;
        j["assets"][0]["kind"] = "hologram";
        CHECK(contains(loadError(j), "assets[0].kind: unknown asset kind \"hologram\""));
        j = good;
        j["sequences"][0]["videoTracks"][1]["kind"] = "smell";
        CHECK(contains(loadError(j), "unknown track kind"));
        j = good;
        j["sequences"][0]["transitions"][0]["kind"] = "wipe";
        CHECK(contains(loadError(j), "unknown transition kind"));
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
    minimal["assets"][4].erase("backendHint");
    minimal["assets"][4].erase("frameDuration");
    const ProjectLoadResult loaded = projectFromJson(minimal);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    const Clip *still = loaded.project->findSequence(fx.seq)->videoTracks[1].clipAt(f30(100));
    REQUIRE(still != nullptr);
    CHECK(still->video == VideoParams{});
    CHECK(still->audio == AudioParams{});
}
