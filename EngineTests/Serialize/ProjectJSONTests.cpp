#include "../Model/ModelFixtures.h"

#include <fstream>
#include <sstream>

using namespace vetest;
using nlohmann::json;

namespace {

Keyframe custom(CMTime time, double value, TimingCurve curve) {
    Keyframe k = key(time, value, KeyframeInterpolation::Bezier);
    k.curve = curve;
    return k;
}

// A project using every serialized feature: spans of every kind (a 70/30 dissolve, fades on both
// kinds of track, Motion and Opacity spans on two lanes with custom curve parts, a Gain span), a
// still, speeds, flags and a second NTSC sequence.
Fixture richFixture() {
    Fixture fx;
    fx.project.name = "Round trip \xE2\x9C\x93"; // UTF-8
    const auto [v, a] = fx.addLinkedPair(0, 60, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    fx.addTailTransition(v, 8, 4); // 70/30 around the cut
    fx.addClip(fx.v2, fx.video60, 30, 45, 0, 0.5);
    const ClipId still = fx.addClip(fx.v2, fx.still, 100, 150);
    fx.addFade(still, ClipEdge::Head, f30(12));
    fx.addFade(still, ClipEdge::Tail, f30(20));
    SpanTracks turn;
    turn[SpanParameter::Rotation] = {key(kCMTimeZero, 0, KeyframeInterpolation::EaseOut), key(f30(60), 45)};
    fx.addSpan(still, SpanKind::Motion, 3, f30(30), f30(90), turn);
    const ClipId music = fx.addClip(fx.a2, fx.audioOnly, 0, 90, 0, 1.0 / 3.0);
    Clip &m = *fx.sequence().findClip(music);
    m.audio = AudioParams{-4.5};
    fx.addFade(music, ClipEdge::Head, f30(10));
    fx.addFade(music, ClipEdge::Tail, CMTimeMake(7, 48000));
    SpanTracks duck;
    duck[SpanParameter::Gain] = {key(kCMTimeZero, 0, KeyframeInterpolation::EaseIn), key(CMTimeMake(1, 3), -12)};
    fx.addSpan(music, SpanKind::Gain, 1, CMTimeMake(1, 6), CMTimeMake(1, 2), duck);
    Clip &vc = *fx.sequence().findClip(v);
    vc.video = VideoParams{12.25, -8.5, 1.1, 33.3, 0.8};
    SpanTracks move;
    move[SpanParameter::X] = {key(kCMTimeZero, -120.5, KeyframeInterpolation::EaseInOut), key(f30(40), 240)};
    const TrackSplit split = splitTrack(move[SpanParameter::X], 0, f30(15));
    move[SpanParameter::X] = {split.left.front(), split.right.front(), split.right.back()};
    move[SpanParameter::Y] = {key(kCMTimeZero, 10, KeyframeInterpolation::Hold), key(f30(40), -10)};
    fx.addSpan(v, SpanKind::Motion, 1, f30(40), f30(80), move);
    SpanTracks fade;
    fade[SpanParameter::Opacity] = {custom(kCMTimeZero, 0.2, TimingCurve{0.3, 0.1, 0.6, 0.95}), key(f30(30), 1)};
    fx.addSpan(v, SpanKind::Opacity, 2, f30(30), f30(60), fade);
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
    (void)a;
    (void)b;
    return fx;
}

// The rich fixture with what version 6 added: a reversed clip (a 23.976 clip on V2, in clip times) and
// shaped transitions (the 70/30 dissolve a Wipe Left, the still's fades an Iris in and a Wipe Down out).
Fixture richFixtureV6() {
    Fixture fx = richFixture();
    const ClipId reversed = fx.addClip(fx.v2, fx.av24, 300, 30, 48, 0.5);
    fx.sequence().findClip(reversed)->reversed = true;
    Sequence &sequence = fx.sequence();
    sequence.videoTracks[0].clips[0].transitionAt(ClipEdge::Tail)->kind = TransitionKind::WipeLeft;
    Clip &still = sequence.videoTracks[1].clips[1];
    still.transitionAt(ClipEdge::Head)->kind = TransitionKind::Iris;
    still.transitionAt(ClipEdge::Tail)->kind = TransitionKind::WipeDown;
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

// The golden version 1 project's clips as the current model expresses them, before the fades
// (which become spans with ids the migration hands out last). `music` receives the clip with fades.
Fixture goldenBase(ClipId &music) {
    Fixture fx;
    fx.project.name = "Golden v1 \xE2\x9C\x93";
    MediaAsset musicAsset;
    musicAsset.name = "music 44k.m4a";
    musicAsset.url = "/Volumes/Media/music 44k.m4a";
    musicAsset.kind = AssetKind::Audio;
    musicAsset.duration = CMTimeMake(30 * 44100 + 17, 44100);
    musicAsset.audioSampleRate = 44100;
    musicAsset.audioChannels = 2;
    musicAsset.backendHint = "apple";
    const AssetId music44 = fx.project.addAsset(musicAsset);
    const auto [v, a] = fx.addLinkedPair(0, 60, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    fx.addTransition(fx.v1, v, b, 12); // the version 4 transition's id, now its span's
    fx.addClip(fx.v2, fx.video60, 30, 45, 0, 0.5);
    fx.addClip(fx.v2, fx.still, 100, 150);
    music = fx.addClip(fx.a2, fx.audioOnly, 0, 90, 0, 1.0 / 3.0);
    fx.sequence().findClip(music)->audio = AudioParams{-4.5};
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
    for (MediaAsset &asset : fx.project.assets) {
        if (asset.kind == AssetKind::Video || asset.kind == AssetKind::AudioVideo) {
            asset.videoDuration = asset.duration; // what the schema 2 -> 3 migration records
        }
    }
    return fx;
}

// The golden version 1, 2 and 3 projects after migrating to version 5: the music clip's fades
// became lane-0 spans (a fade in at its start, a fade out ending on its cut) with the next ids.
Fixture migratedGoldenFixture() {
    ClipId music;
    Fixture fx = goldenBase(music);
    fx.addFade(music, ClipEdge::Head, f30(10));
    fx.addFade(music, ClipEdge::Tail, CMTimeMake(7, 48000));
    fx.requireValid();
    return fx;
}

// The golden version 4 project (Motion keyframes on the first V1 clip and on the NTSC clip) after
// migrating to version 5, written out independently of the migration: the keyframes re-based to the
// clip's in point (source frame 30) in a Motion span on lane 1 and an Opacity span on lane 2 over
// the clip's source range, the animated static values neutral; the fades; the NTSC clip's single
// scale keyframe a span of its own. Span ids in the order the migration hands them out.
Fixture keyframedGoldenFixture() {
    ClipId music;
    Fixture fx = goldenBase(music);
    const ClipId v = fx.sequence().videoTracks[0].clips[0].id;
    // The version 4 x track: an ease in and out from source frame 30 to 90, split at 50.
    const KeyframeTrack x4{key(f30(30), -120.5, KeyframeInterpolation::EaseInOut), key(f30(90), 240)};
    const TrackSplit split = splitTrack(x4, 0, f30(50));
    SpanTracks motion;
    motion[SpanParameter::X] = {split.left.front(), split.right.front(), split.right.back()};
    motion[SpanParameter::X][0].time = f30(0);
    motion[SpanParameter::X][1].time = f30(20);
    motion[SpanParameter::X][2].time = f30(60);
    motion[SpanParameter::Scale] = {key(f30(0), 1, KeyframeInterpolation::Hold), key(f30(15), 1.25, KeyframeInterpolation::EaseOut),
                    key(f30(30), 2, KeyframeInterpolation::EaseIn)};
    motion[SpanParameter::Rotation] = {key(CMTimeMake(601, 600), 0), key(f30(59), 360)};
    // The span ends on the clip's out point as the exact arithmetic reduces it (3 s).
    fx.addSpan(v, SpanKind::Motion, 1, f30(30), CMTimeMake(3, 1), motion);
    SpanTracks opacity;
    opacity[SpanParameter::Opacity] = {key(f30(0), 0), key(f30(10), 1)};
    fx.addSpan(v, SpanKind::Opacity, 2, f30(30), CMTimeMake(3, 1), opacity);
    fx.sequence().findClip(v)->video = VideoParams{0, -8.5, 1, 0, 1};
    fx.addFade(music, ClipEdge::Head, f30(10));
    fx.addFade(music, ClipEdge::Tail, CMTimeMake(7, 48000));
    Sequence &ntsc = fx.project.sequences.back();
    Clip &n = ntsc.videoTracks[0].clips[0];
    EffectSpan scale;
    scale.id = fx.project.ids.make<SpanId>();
    scale.kind = SpanKind::Motion;
    scale.lane = 1;
    scale.start = n.sourceIn;
    scale.end = *n.exactSourceOut()->toTime();
    scale.tracks[SpanParameter::Scale] = {key(CMTimeMake(0, 24000), 1.5)}; // re-based: 5005/24000 - 5005/24000
    n.spans = {scale};
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

json frames(std::int64_t n) {
    return timeToJson(f30(n));
}

// A version 4 clip on track `track` of asset 1 (60 s, audio and video) at `start` for `length`
// frames from source frame `in`, with `fields` merged over it.
json v4Clip(std::uint64_t id, std::uint64_t track, std::int64_t start, std::int64_t length, std::int64_t in,
            const json &fields = json::object()) {
    json clip = {{"id", id},
                 {"assetId", 1},
                 {"trackId", track},
                 {"timelineStart", frames(start)},
                 {"duration", frames(length)},
                 {"sourceIn", frames(in)},
                 {"speed", {{"num", 1}, {"den", 1}}},
                 {"video", {{"x", 0.0}, {"y", 0.0}, {"scale", 1.0}, {"rotationDegrees", 0.0}, {"opacity", 1.0}}},
                 {"audio", {{"gainDb", 0.0}, {"fadeInDuration", frames(0)}, {"fadeOutDuration", frames(0)}}}};
    for (auto it = fields.begin(); it != fields.end(); ++it) {
        clip[it.key()] = it.value();
    }
    return clip;
}

// A version 4 document with a 30 fps sequence (id 2) holding video track 3 and audio track 4 with
// `videoClips` / `audioClips` and `transitions`; asset 1 is 60 s of 30 fps audio and video.
json v4Document(const json &videoClips, const json &audioClips, const json &transitions = json::array(),
                std::uint64_t nextId = 100) {
    return json{{"schemaVersion", 4},
                {"name", "v4"},
                {"nextId", nextId},
                {"activeSequenceId", 2},
                {"assets", json::array({json{{"id", 1},
                                             {"name", "av.mov"},
                                             {"url", "/av.mov"},
                                             {"kind", "av"},
                                             {"duration", frames(1800)},
                                             {"videoDuration", frames(1800)},
                                             {"frameDuration", frames(1)},
                                             {"width", 1920},
                                             {"height", 1080},
                                             {"audioSampleRate", 48000},
                                             {"audioChannels", 2}}})},
                {"sequences",
                 json::array({json{{"id", 2},
                                   {"name", "S"},
                                   {"frameDuration", frames(1)},
                                   {"width", 1920},
                                   {"height", 1080},
                                   {"videoTracks", json::array({json{{"id", 3}, {"kind", "video"}, {"name", "V1"}, {"clips", videoClips}}})},
                                   {"audioTracks", json::array({json{{"id", 4}, {"kind", "audio"}, {"name", "A1"}, {"clips", audioClips}}})},
                                   {"transitions", transitions}}})}};
}

json v4Transition(std::uint64_t id, std::uint64_t track, std::uint64_t from, std::uint64_t to, std::int64_t length) {
    return json{{"id", id}, {"trackId", track}, {"kind", "crossDissolve"}, {"fromClipId", from}, {"toClipId", to},
                {"duration", frames(length)}};
}

json fades(std::int64_t fadeIn, std::int64_t fadeOut) {
    return json{{"gainDb", 0.0}, {"fadeInDuration", frames(fadeIn)}, {"fadeOutDuration", frames(fadeOut)}};
}

const Clip &onlyClip(const Project &project, TrackKind kind, std::size_t index = 0) {
    return project.sequences[0].tracks(kind)[0].clips[index];
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
    CHECK(kProjectSchemaVersion == 7);
    // Version 7: the sequence's "configured" and the project's "sharpenScaledDownSources", always written.
    CHECK(j.at("sharpenScaledDownSources") == true);
    CHECK(j.at("sequences")[0].at("configured") == true);
    CHECK(j.at("nextId") == fx.project.ids.nextValue());
    const json &clip = j.at("sequences")[0].at("videoTracks")[0].at("clips")[0];
    CHECK(clip.at("timelineStart") == json{{"value", 0}, {"timescale", 30}});
    CHECK(clip.at("duration") == json{{"value", 60}, {"timescale", 30}});
    CHECK(clip.at("sourceIn") == json{{"value", 30}, {"timescale", 30}});
    CHECK(clip.at("speed") == json{{"num", 1}, {"den", 1}});
    CHECK_FALSE(clip.contains("sourceOut")); // derived, never stored
    CHECK_FALSE(clip.contains("reversed"));  // written only when true
    CHECK_FALSE(clip.at("video").contains("keyframes"));
    CHECK(clip.at("audio") == json{{"gainDb", 0.0}});
    // Spans: lane 0 first, then lanes 1-3; a transition has an edge and a kind, an effect span
    // tracks of its parameters only (times relative to its start).
    const json &spans = clip.at("spans");
    REQUIRE(spans.size() == 3);
    CHECK(spans[0].at("lane") == 0);
    CHECK(spans[0].at("kind") == "transition");
    CHECK(spans[0].at("edge") == "tail");
    CHECK(spans[0].at("transition") == "crossDissolve");
    CHECK(spans[0].at("start") == json{{"value", -8}, {"timescale", 30}});
    CHECK(spans[0].at("end") == json{{"value", 4}, {"timescale", 30}});
    CHECK_FALSE(spans[0].contains("tracks"));
    CHECK(spans[1].at("kind") == "motion");
    CHECK(spans[1].at("lane") == 1);
    CHECK_FALSE(spans[1].contains("edge"));
    CHECK(spans[1].at("tracks").at("x")[0].at("interpolation") == "bezier");
    CHECK(spans[1].at("tracks").at("x")[0].at("curve").size() == 4);
    CHECK(spans[1].at("tracks").at("x")[2].at("interpolation") == "linear");
    CHECK_FALSE(spans[1].at("tracks").at("x")[2].contains("curve"));
    CHECK(spans[1].at("tracks").at("y")[0].at("interpolation") == "hold");
    CHECK_FALSE(spans[1].at("tracks").contains("scale")); // parameters without keyframes are left out
    CHECK(spans[2].at("kind") == "opacity");
    CHECK(spans[2].at("lane") == 2);
    const json &music = j.at("sequences")[0].at("audioTracks")[1].at("clips")[0];
    CHECK(music.at("speed") == json{{"num", 1}, {"den", 3}});
    CHECK(music.at("spans")[2].at("kind") == "gain");
    CHECK(music.at("spans")[2].at("tracks").at("gain")[0].at("interpolation") == "easeIn");
    // A clip without spans has no "spans" at all; sequences have no "transitions" any more.
    CHECK_FALSE(j.at("sequences")[0].at("videoTracks")[0].at("clips")[1].contains("spans"));
    CHECK_FALSE(j.at("sequences")[0].contains("transitions"));
    CHECK(j.at("assets")[0].at("kind") == "av");
    CHECK(j.at("assets")[0].at("rotationDegrees") == 90);

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
    json spansOfV = good["sequences"][0]["videoTracks"][0]["clips"][0]["spans"];

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
        j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][1].erase("lane");
        CHECK(contains(loadError(j), "clips[0].spans[1].lane: missing required field"));
        j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][0].erase("edge");
        CHECK(contains(loadError(j), "clips[0].spans[0].edge: missing required field"));
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
        const json epoch = {{"value", 10}, {"timescale", 30}, {"epoch", 1}};
        json j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][1]["timelineStart"] = json{{"value", 60}, {"timescale", 30}, {"flags", 3}};
        CHECK(contains(loadError(j), "has been rounded"));
        j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][1]["timelineStart"] = json{{"value", 60}, {"timescale", 30}, {"epoch", 1}};
        CHECK(contains(loadError(j), "has epoch 1"));
        j = good;
        j["sequences"][0]["audioTracks"][1]["clips"][0]["spans"][0]["end"] = json{{"value", 10}, {"timescale", 30}, {"flags", 3}};
        CHECK(contains(loadError(j), "has been rounded"));
        j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][0]["start"] = json{{"value", -8}, {"timescale", 30}, {"epoch", 1}};
        CHECK(contains(loadError(j), "has epoch 1"));
        j = good;
        j["assets"][0]["duration"] = epoch;
        CHECK(contains(loadError(j), "has epoch 1"));
    }
    SUBCASE("unknown asset and track kinds and clip edges are errors") {
        json j = good;
        j["assets"][0]["kind"] = "hologram";
        CHECK(contains(loadError(j), "assets[0].kind: unknown asset kind \"hologram\""));
        j = good;
        j["sequences"][0]["videoTracks"][1]["kind"] = "smell";
        CHECK(contains(loadError(j), "unknown track kind"));
        j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][0]["edge"] = "middle";
        CHECK(contains(loadError(j), "spans[0].edge: unknown clip edge \"middle\""));
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
        j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][0]["spans"] = json::object();
        CHECK(contains(loadError(j), "spans: expected an array"));
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
    // Since the effect lanes review (M8) loading repairs what has one safe reading, with a warning
    // (see "loading repairs what it safely can"): these were refusals before.
    SUBCASE("repaired: an effect span meeting another on its lane moves to a free lane") {
        json j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][2]["lane"] = 1; // meets the Motion span
        const ProjectLoadResult r = projectFromJson(j);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        CHECK(anyContains(r.warnings, "on lane 1; moved to lane 2"));
    }
    SUBCASE("repaired: a transition longer than the next clip is removed") {
        json j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][0]["end"] = frames(90); // longer than B
        const ProjectLoadResult r = projectFromJson(j);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        CHECK(anyContains(r.warnings, "was removed: "));
        CHECK(anyContains(r.warnings, "longer than clip"));
        CHECK(r.project->sequences[0].videoTracks[0].clips[0].transitionAt(ClipEdge::Tail) == nullptr);
    }
    SUBCASE("repaired: a transition whose cut is gone is removed") {
        json j = good;
        j["sequences"][0]["videoTracks"][0]["clips"][1]["timelineStart"] = frames(61);
        const ProjectLoadResult r = projectFromJson(j);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        CHECK(anyContains(r.warnings, "no clip touches that end"));
    }
}

TEST_CASE("ProjectJSON: unknown kinds and keys of spans warn instead of failing") {
    const Fixture fx = richFixture();
    json j = projectToJson(fx.project);
    json &spans = j["sequences"][0]["videoTracks"][0]["clips"][0]["spans"];
    SUBCASE("an unknown transition kind degrades to a cross dissolve, kept by name") {
        spans[0]["transition"] = "wipe";
        const ProjectLoadResult loaded = projectFromJson(j);
        REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
        Project stripped = *loaded.project;
        TransitionSpan &span = stripped.sequences[0].videoTracks[0].clips[0].transitions[0];
        CHECK(span.kind == TransitionKind::CrossDissolve);
        CHECK(span.unknownKindName == "wipe");
        span.unknownKindName.clear();
        CHECK(stripped == fx.project);
        REQUIRE(loaded.warnings.size() == 1);
        CHECK(contains(loaded.warnings[0], "clips[0].spans[0].transition: unknown transition kind \"wipe\""));
    }
    SUBCASE("a span of an unknown kind (a newer version) is kept as it is (review core #9)") {
        spans[1]["kind"] = "blur";
        const ProjectLoadResult loaded = projectFromJson(j);
        REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
        CHECK(anyContains(loaded.warnings, "spans[1].kind: unknown span kind \"blur\" (from a newer version"));
        REQUIRE(loaded.project->sequences[0].videoTracks[0].clips[0].transitions.size() == 1);
        REQUIRE(loaded.project->sequences[0].videoTracks[0].clips[0].spans.size() == 2);
        CHECK(loaded.project->sequences[0].videoTracks[0].clips[0].spans[0].kind == SpanKind::Unknown);
        CHECK(projectToJson(*loaded.project) == j);
    }
    SUBCASE("a track of an unknown parameter is kept as it is (review core #9)") {
        spans[1]["tracks"]["skew"] = json::array({{{"time", frames(0)}, {"value", 1.0}}});
        const ProjectLoadResult loaded = projectFromJson(j);
        REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
        CHECK(anyContains(loaded.warnings, "spans[1].tracks: unknown span parameter \"skew\" (from a newer version"));
        CHECK(projectToJson(*loaded.project) == j);
        Project stripped = *loaded.project;
        stripped.sequences[0].videoTracks[0].clips[0].spans[0].foreign = ForeignSpanContent{};
        CHECK(stripped == fx.project);
    }
    SUBCASE("a track of another kind's parameter fails validation") {
        spans[1]["tracks"]["gain"] = json::array({{{"time", frames(0)}, {"value", 1.0}}});
        CHECK(contains(loadError(j), "has no Gain keyframes"));
    }
    SUBCASE("a keyframe's unknown interpolation becomes linear") {
        spans[1]["tracks"]["y"][0]["interpolation"] = "springy";
        const ProjectLoadResult r = projectFromJson(j);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        CHECK(anyContains(r.warnings, "tracks.y[0].interpolation: unknown keyframe interpolation"));
        CHECK(r.project->sequences[0].videoTracks[0].clips[0].spans[0].tracks[SpanParameter::Y][0].interpolation ==
              KeyframeInterpolation::Linear);
    }
    SUBCASE("a curve on a keyframe that is not custom is ignored (it round trips equal)") {
        spans[1]["tracks"]["y"][0]["curve"] = json::array({0.1, 0.2, 0.3, 0.4});
        const ProjectLoadResult r = projectFromJson(j);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        CHECK(anyContains(r.warnings, "tracks.y[0]: a timing curve on a hold keyframe was ignored"));
        CHECK(*r.project == fx.project);
    }
    SUBCASE("keyframe errors") {
        json broken = j;
        broken["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][1]["tracks"]["x"][1]["curve"] = json::array({0.1, 0.2});
        CHECK(contains(loadError(broken), "tracks.x[1].curve: expected four numbers"));
        broken = j;
        json &x = broken["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][1]["tracks"]["x"];
        std::swap(x[0], x[1]);
        CHECK(contains(loadError(broken), "times must increase strictly"));
        broken = j;
        broken["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][1]["tracks"]["x"][0].erase("time");
        CHECK(contains(loadError(broken), "tracks.x[0].time: missing required field"));
        broken = j;
        broken["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][1]["tracks"]["x"][1]["curve"] =
            json::array({0.9, 0.0, 0.1, 1.0});
        CHECK(contains(loadError(broken), "invalid timing curve"));
    }
}

// A project as a newer version (with colour grading, say) might write it: a span of a kind this
// version does not know, a parameter it does not know on a known span, and keys it does not know on
// an effect span and a transition. Clip 0 of V1 covers source frames 30-90; lane 3 is free.
json withNewerSpanContent(const Fixture &fx) {
    json j = projectToJson(fx.project);
    const std::uint64_t id = j["nextId"].get<std::uint64_t>();
    j["nextId"] = id + 1;
    json &spans = j["sequences"][0]["videoTracks"][0]["clips"][0]["spans"];
    spans.push_back(json{{"id", id},
                         {"lane", 3},
                         {"kind", "colour"},
                         {"start", frames(35)},
                         {"end", frames(70)},
                         {"tracks",
                          {{"exposure", json::array({{{"time", frames(0)}, {"value", 0.5}, {"interpolation", "linear"}},
                                                     {{"time", frames(35)}, {"value", -0.25}}})},
                           {"temperature", json::array({{{"time", frames(0)}, {"value", 6500}}})}}},
                         {"look", {{"lut", "teal.cube"}, {"amount", 0.75}}}});
    spans[1]["tracks"]["blur"] = json::array({{{"time", frames(0)}, {"value", 2.0}, {"interpolation", "springy"}},
                                              {{"time", frames(40)}, {"value", 0.0}}});
    spans[2]["colorSpace"] = "linear";
    spans[0]["softness"] = json{{"amount", 0.5}};
    return j;
}

TEST_CASE("ProjectJSON: a newer version's span kinds, parameters and keys round trip unchanged (review core #9)") {
    const Fixture fx = richFixture();
    const json written = withNewerSpanContent(fx);
    const ProjectLoadResult loaded = projectFromJson(written);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    // The unknown kind and parameter are reported, as before they were kept.
    REQUIRE(loaded.warnings.size() == 2);
    CHECK(anyContains(loaded.warnings, "spans[3].kind: unknown span kind \"colour\" (from a newer version of "
                                       "Framewright?); kept as it is and saved with the project, but not shown, "
                                       "played or editable"));
    CHECK(anyContains(loaded.warnings, "spans[1].tracks: unknown span parameter \"blur\" (from a newer version of "
                                       "Framewright?); its keyframes are kept as they are and saved with the project"));

    // Saved: the same document (JSON equality: every key and value), and the text is stable.
    const Project &project = *loaded.project;
    CHECK(projectToJson(project) == written);
    const std::string text = serializeProject(project);
    const ProjectLoadResult again = parseProject(text);
    REQUIRE(again.ok());
    CHECK(*again.project == project);
    CHECK(serializeProject(*again.project) == text);

    // On the model: the unknown span has no parameters and keeps its kind's name and content.
    const Clip &clip = project.sequences[0].videoTracks[0].clips[0];
    REQUIRE(clip.transitions.size() == 1);
    REQUIRE(clip.spans.size() == 3);
    const EffectSpan &colour = clip.spans[2];
    CHECK(colour.isUnknownKind());
    CHECK(colour.lane == 3);
    CHECK(colour.foreign.kindName == "colour");
    CHECK(colour.tracks.empty());
    CHECK(parametersOf(colour.kind).empty());
    CHECK(json::parse(colour.foreign.fields) == json{{"tracks", written["sequences"][0]["videoTracks"][0]["clips"][0]
                                                                  ["spans"][3]["tracks"]},
                                                     {"look", {{"lut", "teal.cube"}, {"amount", 0.75}}}});
    CHECK(json::parse(clip.spans[0].foreign.tracks).contains("blur"));
    CHECK(identical(clip.spans[0].foreign.tracksLength, f30(40)));
    CHECK(clip.spans[1].foreign.fields == R"({"colorSpace":"linear"})");
    CHECK(clip.transitions[0].foreignFields == R"({"softness":{"amount":0.5}})");

    // Without what the newer version added, it is the project this version wrote.
    Project stripped = project;
    Clip &strippedClip = stripped.sequences[0].videoTracks[0].clips[0];
    strippedClip.spans.pop_back();
    for (TransitionSpan &span : strippedClip.transitions) {
        span.foreignFields.clear();
    }
    for (EffectSpan &span : strippedClip.spans) {
        span.foreign = ForeignSpanContent{};
    }
    stripped.ids = fx.project.ids;
    CHECK(stripped == fx.project);

    // It changes no frame: the composed Motion values are those of the project without it.
    const Clip &plain = fx.project.sequences[0].videoTracks[0].clips[0];
    for (std::int64_t frame = 0; frame < 60; ++frame) {
        CHECK(motionValuesAt(clip, f30(frame)) == motionValuesAt(plain, f30(frame)));
    }
}

TEST_CASE("ProjectJSON: a span of an unknown kind is kept only where this version allows a span") {
    const Fixture fx = richFixture();
    json j = withNewerSpanContent(fx);
    json &colour = j["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][3];
    SUBCASE("on lane 0 (transitions only here): dropped with a warning") {
        colour["lane"] = 0;
        const ProjectLoadResult r = projectFromJson(j);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        CHECK(anyContains(r.warnings, "spans[3].kind: unknown span kind \"colour\" on lane 0, which holds transitions "
                                      "only here; the span was dropped"));
        CHECK(r.project->sequences[0].videoTracks[0].clips[0].transitions.size() == 1);
        CHECK(r.project->sequences[0].videoTracks[0].clips[0].spans.size() == 2);
    }
    SUBCASE("outside its clip's source range: dropped with a warning") {
        colour["end"] = frames(95);
        const ProjectLoadResult r = projectFromJson(j);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        CHECK(anyContains(r.warnings, "is outside its clip's source range"));
        CHECK(anyContains(r.warnings, "the \"colour\" span from a newer version was dropped"));
        CHECK(r.project->sequences[0].videoTracks[0].clips[0].transitions.size() == 1);
        CHECK(r.project->sequences[0].videoTracks[0].clips[0].spans.size() == 2);
    }
    SUBCASE("overlapping a span of its lane: moved to a free lane, as any effect span") {
        colour["lane"] = 1; // meets the Motion span (frames 40-80)
        const ProjectLoadResult r = projectFromJson(j);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        CHECK(anyContains(r.warnings, "on lane 1; moved to lane 3"));
        CHECK(r.project->sequences[0].videoTracks[0].clips[0].spans.back().isUnknownKind());
    }
    SUBCASE("on an audio track: kept (this version cannot tell its kind's track)") {
        json &music = j["sequences"][0]["audioTracks"][1]["clips"][0]["spans"];
        json moved = colour;
        moved["lane"] = 2;
        moved["start"] = timeToJson(CMTimeMake(1, 6));
        moved["end"] = timeToJson(CMTimeMake(1, 3));
        music.push_back(moved);
        j["sequences"][0]["videoTracks"][0]["clips"][0]["spans"].erase(3);
        const ProjectLoadResult r = projectFromJson(j);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        CHECK(projectToJson(*r.project) == j);
    }
}

TEST_CASE("ProjectJSON: every transition kind round trips on a cut and on a free edge") {
    for (const TransitionKind kind : kTransitionKinds) {
        CAPTURE(nameOf(kind));
        Fixture fx = richFixture();
        Sequence &sequence = fx.sequence();
        Clip &dissolveOwner = sequence.videoTracks[0].clips[0];
        REQUIRE(dissolveOwner.transitionAt(ClipEdge::Tail) != nullptr);
        dissolveOwner.transitionAt(ClipEdge::Tail)->kind = kind; // across the cut
        Clip &still = sequence.videoTracks[1].clips[1];
        REQUIRE(still.isStill);
        still.transitionAt(ClipEdge::Head)->kind = kind; // a fade in
        still.transitionAt(ClipEdge::Tail)->kind = kind; // a fade out
        fx.requireValid();
        const std::string text = serializeProject(fx.project);
        CHECK(contains(text, std::string("\"transition\": \"") + nameOf(kind) + "\""));
        const ProjectLoadResult loaded = parseProject(text);
        REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
        CHECK(loaded.warnings.empty());
        CHECK(*loaded.project == fx.project);
        CHECK(serializeProject(*loaded.project) == text);
        CHECK(transitionKindNamed(nameOf(kind)) == kind);
    }
    CHECK_FALSE(transitionKindNamed("wipe").has_value());
    CHECK_FALSE(transitionKindNamed("").has_value());
}

TEST_CASE("ProjectJSON: an unknown transition kind is named in the warning and a shaped kind on audio is repaired") {
    const Fixture fx = richFixture();
    SUBCASE("unknown: shown as a cross dissolve, the name in the warning, kept by name when saved (review L8)") {
        json j = projectToJson(fx.project);
        j["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][0]["transition"] = "clockWipe";
        const ProjectLoadResult loaded = projectFromJson(j);
        REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
        REQUIRE(loaded.warnings.size() == 1);
        CHECK(contains(loaded.warnings[0], "unknown transition kind \"clockWipe\""));
        CHECK(contains(loaded.warnings[0], "shown as a cross dissolve and saved as \"clockWipe\""));
        const TransitionSpan &span = loaded.project->sequences[0].videoTracks[0].clips[0].transitions[0];
        CHECK(span.kind == TransitionKind::CrossDissolve); // what it renders and edits as
        CHECK(span.unknownKindName == "clockWipe");
        // Everything else is the project as written.
        Project stripped = *loaded.project;
        stripped.sequences[0].videoTracks[0].clips[0].transitions[0].unknownKindName.clear();
        CHECK(stripped == fx.project);
        // Saved and loaded again: the name comes back, not "crossDissolve".
        const json saved = projectToJson(*loaded.project);
        CHECK(saved["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][0]["transition"] == "clockWipe");
        CHECK(saved == j);
        const ProjectLoadResult again = projectFromJson(saved);
        REQUIRE(again.ok());
        CHECK(*again.project == *loaded.project);
        // Choosing a kind replaces it.
        Project edited = *loaded.project;
        SetTransitionKind kind(edited.sequences[0].id, span.id, TransitionKind::WipeUp);
        REQUIRE(kind.apply(edited).ok());
        const TransitionSpan *chosen = edited.sequences[0].findTransition(span.id);
        REQUIRE(chosen != nullptr);
        CHECK(chosen->kind == TransitionKind::WipeUp);
        CHECK(chosen->unknownKindName.empty());
        CHECK(projectToJson(edited)["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][0]["transition"] == "wipeUp");
        kind.revert(edited);
        CHECK(edited.sequences[0].findTransition(span.id)->unknownKindName == "clockWipe");
    }
    SUBCASE("a wipe on an audio track's fade becomes a cross dissolve (audio has no shapes)") {
        json j = projectToJson(fx.project);
        json &music = j["sequences"][0]["audioTracks"][1]["clips"][0];
        REQUIRE(music["spans"][0]["kind"] == "transition");
        music["spans"][0]["transition"] = "iris";
        const ProjectLoadResult loaded = projectFromJson(j);
        REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
        CHECK(*loaded.project == fx.project);
        REQUIRE(loaded.warnings.size() == 1);
        CHECK(contains(loaded.warnings[0], "an audio transition is a crossfade or a fade, not \"iris\"; using a cross dissolve"));
    }
    SUBCASE("validation refuses a shaped kind on an audio track") {
        Fixture edited = richFixture();
        Clip &music = edited.sequence().audioTracks[1].clips[0];
        music.transitionAt(ClipEdge::Head)->kind = TransitionKind::WipeUp;
        const auto problem = validateProject(edited.project);
        REQUIRE(problem.has_value());
        CHECK(contains(*problem, "not a Wipe Up")); // the kind's display name (review L9)
    }
}

TEST_CASE("ProjectJSON: a model keyframe that is not custom cannot carry a curve (it would not round trip)") {
    Fixture fx = richFixture();
    fx.sequence().videoTracks[0].clips[0].spans[0].tracks[SpanParameter::Y][0].curve = TimingCurve{0.1, 0.2, 0.3, 0.4};
    CHECK(contains(problemOf(fx.project), "has a timing curve but is not custom"));
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
    j["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][1]["label"] = "zoom";
    const ProjectLoadResult withExtras = projectFromJson(j);
    REQUIRE_MESSAGE(withExtras.ok(), doctest::String(withExtras.error.c_str()));
    // A span's unknown key is kept for saving (review core #9); everything else is the project.
    Project stripped = *withExtras.project;
    CHECK(stripped.sequences[0].videoTracks[0].clips[0].spans[0].foreign.fields == R"({"label":"zoom"})");
    stripped.sequences[0].videoTracks[0].clips[0].spans[0].foreign = ForeignSpanContent{};
    CHECK(stripped == fx.project);

    // Optional fields may be omitted.
    json minimal = projectToJson(fx.project);
    json &clip = minimal["sequences"][0]["videoTracks"][1]["clips"][0]; // the VFR clip
    clip.erase("video");
    clip.erase("audio");
    clip.erase("linkedClipId");
    minimal["assets"][4].erase("backendHint");
    minimal["assets"][4].erase("frameDuration");
    minimal["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][0].erase("transition");
    const ProjectLoadResult loaded = projectFromJson(minimal);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    const Clip &vfr = loaded.project->findSequence(fx.seq)->videoTracks[1].clips[0];
    CHECK(vfr.video == VideoParams{});
    CHECK(vfr.audio == AudioParams{});
    CHECK(loaded.project->findSequence(fx.seq)->videoTracks[0].clips[0].transitions[0].kind ==
          TransitionKind::CrossDissolve);
}

TEST_CASE("ProjectJSON: the checked-in version 1 project loads through the migrations") {
    const std::string text = readFile(goldenPath("project-v1.json"));
    REQUIRE(json::parse(text).at("schemaVersion") == 1);
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    const Fixture expected = migratedGoldenFixture();
    CHECK(*loaded.project == expected.project);
    // Spot checks of what the migrations derived.
    const Sequence &main = *loaded.project->findSequence(expected.seq);
    const Clip &third = main.audioTracks[1].clips[0]; // 1/3 speed, 90 frames of 30 source frames
    CHECK(third.speed == Ratio{1, 3});
    CHECK(identical(third.timelineDuration, CMTimeMake(90, 30)));
    CHECK(third.sourceOut() == CMTimeMake(1, 1));
    CHECK(clipFadeLength(third, ClipEdge::Head) == f30(10));
    CHECK(identical(clipFadeLength(third, ClipEdge::Tail), CMTimeMake(7, 48000)));
    const Clip &in44 = main.audioTracks[1].clips[1];
    CHECK(identical(in44.sourceIn, CMTimeMake(44101, 44100)));
    CHECK(identical(in44.timelineDuration, CMTimeMake(60, 30)));
}

TEST_CASE("ProjectJSON: the checked-in version 2 project loads through the migrations") {
    const std::string text = readFile(goldenPath("project-v2.json"));
    REQUIRE(json::parse(text).at("schemaVersion") == 2);
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == migratedGoldenFixture().project);
}

TEST_CASE("ProjectJSON: the checked-in version 3 project loads through the migrations") {
    const std::string text = readFile(goldenPath("project-v3.json"));
    REQUIRE(json::parse(text).at("schemaVersion") == 3);
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == migratedGoldenFixture().project);
    // The 3 -> 4 step itself changes nothing but the version.
    json document = json::parse(text);
    json upgraded = document;
    std::vector<std::string> warnings;
    REQUIRE_FALSE(migrateProjectJson(upgraded, 3, warnings).has_value());
    CHECK(warnings.empty());
    CHECK(upgraded.at("schemaVersion") == kProjectSchemaVersion);
    CHECK_FALSE(upgraded.at("sequences")[0].contains("transitions"));
    CHECK(upgraded.at("nextId") == 25); // two fade spans
}

TEST_CASE("ProjectJSON: the checked-in version 4 project (keyframes, fades, a transition) migrates to spans") {
    const std::string text = readFile(goldenPath("project-v4.json"));
    REQUIRE(json::parse(text).at("schemaVersion") == 4);
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    const Fixture expected = keyframedGoldenFixture();
    CHECK(*loaded.project == expected.project);
    CHECK(serializeProject(*loaded.project) == serializeProject(expected.project)); // shows where
    CHECK(loaded.project->ids.nextValue() == 28);
    // The transition kept its id and became a tail span of its outgoing clip, centred (6 + 6).
    const Clip &v = loaded.project->sequences[0].videoTracks[0].clips[0];
    const TransitionSpan *transition = v.transitionAt(ClipEdge::Tail);
    REQUIRE(transition != nullptr);
    CHECK(transition->id == SpanId{15});
    CHECK(transition->start == -f30(6));
    CHECK(transition->end == f30(6));
    // Written back as version 5 and read again: the same project.
    const ProjectLoadResult again = parseProject(serializeProject(*loaded.project));
    REQUIRE(again.ok());
    CHECK(*again.project == *loaded.project);
}

TEST_CASE("ProjectJSON: a version 4 fade out reaching into an incoming crossfade opens (review H1)") {
    // The render golden with audio clip 14 (60 frames, 5 of them under the 10-frame crossfade 16
    // from clip 12) fading out over 57 frames: version 4 played both; version 5 refused to open
    // it ("transition 16: meets the transition at the end of clip 14").
    json document = json::parse(readFile(goldenPath("project-v4-render.json")));
    bool found = false;
    for (json &track : document.at("sequences")[0].at("audioTracks")) {
        for (json &clip : track.at("clips")) {
            if (clip.at("id") == 14) {
                clip.at("audio")["fadeOutDuration"] = json{{"value", 57}, {"timescale", 30}};
                found = true;
            }
        }
    }
    REQUIRE(found);
    const ProjectLoadResult loaded = parseProject(document.dump());
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    const Sequence &sequence = loaded.project->sequences[0];
    const Clip *clip = sequence.findClip(ClipId{14});
    REQUIRE(clip != nullptr);
    CHECK(clipFadeLength(*clip, ClipEdge::Tail) == f30(55)); // 60 - ceil(10 / 2)
    const TransitionSpan *crossfade = sequence.findTransition(SpanId{16});
    REQUIRE(crossfade != nullptr);
    CHECK(crossfade->end == f30(5));
    CHECK(anyContains(loaded.warnings, "the fade out (57/30 "));
    CHECK(anyContains(loaded.warnings, "would meet the crossfade at the clip's start; shortened to 55/30 "));
    CHECK_FALSE(validateProject(*loaded.project).has_value());
}

TEST_CASE("ProjectJSON: a version 4 fade out against an odd-length crossfade keeps duration - ceil(n / 2) (test gap 1)") {
    // As above with an 11-frame crossfade: 6 of its frames are inside clip 14 (the incoming share,
    // ceil(11 / 2)), so the 57-frame fade out is shortened to 54, not 55 (a floor would give 55 and
    // leave the repair to the loader's pruning, with a second warning).
    json document = json::parse(readFile(goldenPath("project-v4-render.json")));
    bool foundTransition = false;
    for (json &transition : document.at("sequences")[0].at("transitions")) {
        if (transition.at("id") == 16) {
            transition.at("duration") = json{{"value", 11}, {"timescale", 30}};
            foundTransition = true;
        }
    }
    bool foundClip = false;
    for (json &track : document.at("sequences")[0].at("audioTracks")) {
        for (json &clip : track.at("clips")) {
            if (clip.at("id") == 14) {
                clip.at("audio")["fadeOutDuration"] = json{{"value", 57}, {"timescale", 30}};
                foundClip = true;
            }
        }
    }
    REQUIRE(foundTransition);
    REQUIRE(foundClip);
    const ProjectLoadResult loaded = parseProject(document.dump());
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    const Sequence &sequence = loaded.project->sequences[0];
    const Clip *clip = sequence.findClip(ClipId{14});
    REQUIRE(clip != nullptr);
    CHECK(clipFadeLength(*clip, ClipEdge::Tail) == f30(54)); // 60 - ceil(11 / 2)
    const TransitionSpan *crossfade = sequence.findTransition(SpanId{16});
    REQUIRE(crossfade != nullptr);
    CHECK(crossfade->end == f30(6));
    CHECK(loaded.warnings.size() == 1); // the migration's own, and nothing left for the loader to prune
    CHECK(anyContains(loaded.warnings, "shortened to 54/30 "));
    CHECK_FALSE(validateProject(*loaded.project).has_value());
}

namespace {

// V1: clip A [0,90) with a Motion span on lane 1 [0,30), an Opacity span on lane 2 [15,60) and a
// Motion span on lane 3 [40,70); clip B [90,150) touching A's end.
struct RepairFixture : Fixture {
    ClipId a, b;
    SpanId motion, opacity, late;
    RepairFixture() {
        a = addClip(v1, av30, 0, 90, 0);
        b = addClip(v1, av30, 90, 60, 300);
        SpanTracks zoom;
        zoom[SpanParameter::Scale] = {key(kCMTimeZero, 1, KeyframeInterpolation::EaseInOut), key(f30(30), 2)};
        motion = addSpan(a, SpanKind::Motion, 1, f30(0), f30(30), zoom);
        SpanTracks fade;
        fade[SpanParameter::Opacity] = {key(kCMTimeZero, 1), key(f30(45), 0.5)};
        opacity = addSpan(a, SpanKind::Opacity, 2, f30(15), f30(60), fade);
        SpanTracks pan;
        pan[SpanParameter::X] = {key(kCMTimeZero, 0), key(f30(30), 100)};
        late = addSpan(a, SpanKind::Motion, 3, f30(40), f30(70), pan);
        requireValid();
    }
    json document() const {
        return projectToJson(project);
    }
    // Clip `index` of V1's spans in `doc`.
    static json &spans(json &doc, std::size_t index) {
        return doc.at("sequences")[0].at("videoTracks")[0].at("clips")[index].at("spans");
    }
};

json &spanWithId(json &list, SpanId id) {
    for (json &span : list) {
        if (span.at("id") == id.value()) {
            return span;
        }
    }
    FAIL("no span " << id.value());
    return list;
}

} // namespace

TEST_CASE("ProjectJSON: loading repairs what it safely can and refuses the rest (review M8)") {
    RepairFixture fx;
    SUBCASE("repaired: spans out of order are sorted, with a warning") {
        json doc = fx.document();
        json &spans = RepairFixture::spans(doc, 0);
        std::reverse(spans.begin(), spans.end());
        const ProjectLoadResult r = projectFromJson(doc);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        CHECK(*r.project == fx.project);
        CHECK(anyContains(r.warnings, "spans were not in lane and time order; sorted"));
    }
    SUBCASE("repaired: a fade in on a clip another clip touches is removed, with a warning") {
        const SpanId fadeIn = fx.addFade(fx.b, ClipEdge::Head, f30(10)); // invalid: A touches B's start
        json doc = fx.document();
        const ProjectLoadResult r = projectFromJson(doc);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        CHECK(r.project->sequences[0].findTransition(fadeIn) == nullptr);
        CHECK(anyContains(r.warnings, "was removed: "));
        CHECK(anyContains(r.warnings, "touches the start of clip " + std::to_string(fx.b.value())));
        CHECK_FALSE(validateProject(*r.project).has_value());
    }
    SUBCASE("repaired: a span on lane 4 moves to the first effect lane with room, with a warning") {
        json doc = fx.document();
        spanWithId(RepairFixture::spans(doc, 0), fx.late)["lane"] = 4;
        const ProjectLoadResult r = projectFromJson(doc);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        const EffectSpan *moved = r.project->sequences[0].findSpan(fx.late);
        REQUIRE(moved != nullptr);
        CHECK(moved->lane == 1); // lane 1 is free after frame 30; the composition does not depend on the lane
        CHECK(anyContains(r.warnings, "lane 4 is not an effect lane (1 to 3); moved to lane 1"));
    }
    SUBCASE("lanes at the 32-bit limits: moved onto the model's lanes with a warning, or refused beyond them") {
        // laneCount (highest lane + 1) overflowed on a lane of INT_MAX; no file brings one into the
        // model: an effect span goes to a free effect lane, a transition to lane 0, and a lane beyond
        // 32 bits is refused by the parser.
        const SpanId fadeOut = fx.addFade(fx.b, ClipEdge::Tail, f30(10));
        for (const std::int64_t lane : {std::int64_t(INT32_MAX), std::int64_t(INT32_MIN), std::int64_t(-1)}) {
            CAPTURE(lane);
            json doc = fx.document();
            spanWithId(RepairFixture::spans(doc, 0), fx.late)["lane"] = lane;
            spanWithId(RepairFixture::spans(doc, 1), fadeOut)["lane"] = lane;
            const ProjectLoadResult r = projectFromJson(doc);
            REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
            CHECK(r.project->sequences[0].findSpan(fx.late)->lane == 1);
            CHECK(r.project->sequences[0].findTransition(fadeOut)->lane == kTransitionLane);
            CHECK(anyContains(r.warnings, "lane " + std::to_string(lane) + " is not an effect lane (1 to 3); moved to lane 1"));
            CHECK(anyContains(r.warnings, "a transition lies on lane 0, found lane " + std::to_string(lane) +
                                              "; moved to lane 0"));
            CHECK(laneCount(r.project->sequences[0].videoTracks[0]) == 3);
            CHECK_FALSE(validateProject(*r.project).has_value());
        }
        for (const std::int64_t lane : {std::int64_t(INT32_MAX) + 1, std::int64_t(INT32_MIN) - 1}) {
            CAPTURE(lane);
            json doc = fx.document();
            spanWithId(RepairFixture::spans(doc, 0), fx.late)["lane"] = lane;
            const ProjectLoadResult r = projectFromJson(doc);
            CHECK_FALSE(r.ok());
            CHECK(r.error.find("integer out of 32-bit range") != std::string::npos);
        }
    }
    SUBCASE("repaired: two spans starting together on one lane: the later one moves to a free lane") {
        json doc = fx.document();
        json &spans = RepairFixture::spans(doc, 0);
        json &late = spanWithId(spans, fx.late);
        late["lane"] = 2;
        late["start"] = timeToJson(f30(15));
        late["end"] = timeToJson(f30(45));
        const ProjectLoadResult r = projectFromJson(doc);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        CHECK(r.project->sequences[0].findSpan(fx.opacity)->lane == 2);
        CHECK(r.project->sequences[0].findSpan(fx.late)->lane == 3);
        CHECK(anyContains(r.warnings, "overlaps span " + std::to_string(fx.opacity.value()) + " on lane 2; moved to lane 3"));
    }
    SUBCASE("refused: overlapping spans with no effect lane free for one of them") {
        json doc = fx.document();
        json &spans = RepairFixture::spans(doc, 0);
        for (const SpanId id : {fx.motion, fx.opacity, fx.late}) {
            json &span = spanWithId(spans, id);
            span["start"] = timeToJson(f30(10));
            span["end"] = timeToJson(f30(40));
        }
        json extra = spanWithId(spans, fx.late);
        extra["id"] = 999;
        extra["lane"] = 1;
        spans.push_back(extra);
        doc["nextId"] = 1000;
        const ProjectLoadResult r = projectFromJson(doc);
        CHECK_FALSE(r.ok());
        CHECK(r.error.find("no effect lane has room") != std::string::npos);
    }
    SUBCASE("refused: a keyframe without a value (nothing to repair it from), naming its path") {
        json doc = fx.document();
        json &span = spanWithId(RepairFixture::spans(doc, 0), fx.motion);
        span.at("tracks").at("scale")[1]["value"] = nullptr;
        const ProjectLoadResult r = projectFromJson(doc);
        CHECK_FALSE(r.ok());
        CHECK(r.error.find("tracks.scale[1].value") != std::string::npos);
    }
}

TEST_CASE("ProjectJSON: the checked-in version 5 project loads with every clip forward") {
    const Fixture expected = richFixture();
    const std::string text = readFile(goldenPath("project-v5.json"));
    REQUIRE(json::parse(text).at("schemaVersion") == 5);
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == expected.project);
    std::size_t clips = 0;
    for (const Sequence &sequence : loaded.project->sequences) {
        for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
            for (const Track &track : sequence.tracks(kind)) {
                for (const Clip &clip : track.clips) {
                    CHECK_FALSE(clip.reversed);
                    ++clips;
                }
            }
        }
    }
    CHECK(clips > 5);
    // The migrations change nothing but the version and add what version 7 writes (configured
    // sequences, sharpening on).
    json document = json::parse(text);
    std::vector<std::string> warnings;
    CHECK_FALSE(migrateProjectJson(document, 5, warnings).has_value());
    CHECK(warnings.empty());
    json expectedDocument = json::parse(text);
    expectedDocument["schemaVersion"] = 7;
    expectedDocument["sharpenScaledDownSources"] = true;
    for (json &sequence : expectedDocument.at("sequences")) {
        sequence["configured"] = true;
    }
    CHECK(document == expectedDocument);
}

TEST_CASE("ProjectJSON: the checked-in version 6 project opens configured, with sharpening on") {
    const Fixture expected = richFixtureV6();
    const std::string text = readFile(goldenPath("project-v6.json"));
    REQUIRE(json::parse(text).at("schemaVersion") == 6);
    CHECK_FALSE(contains(text, "configured"));
    CHECK_FALSE(contains(text, "sharpenScaledDownSources"));
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == expected.project);
    // An existing project's settings are chosen: its sequences never adopt a clip's.
    REQUIRE(loaded.project->sequences.size() == 2);
    for (const Sequence &sequence : loaded.project->sequences) {
        CHECK(sequence.configured);
    }
    CHECK(loaded.project->sharpenScaledDownSources);
    // The 6 -> 7 step adds exactly those two, as true.
    json document = json::parse(text);
    std::vector<std::string> warnings;
    CHECK_FALSE(migrateProjectJson(document, 6, warnings).has_value());
    CHECK(warnings.empty());
    json expectedDocument = json::parse(text);
    expectedDocument["schemaVersion"] = 7;
    expectedDocument["sharpenScaledDownSources"] = true;
    for (json &sequence : expectedDocument.at("sequences")) {
        sequence["configured"] = true;
    }
    CHECK(document == expectedDocument);
}

// The version 6 fixture with what version 7 added set away from its defaults where the golden file
// can show it: sharpening off (the sequence is configured, as every saved sequence with clips is).
Fixture richFixtureV7() {
    Fixture fx = richFixtureV6();
    fx.project.sharpenScaledDownSources = false;
    fx.requireValid();
    return fx;
}

TEST_CASE("ProjectJSON: the checked-in version 7 project matches the current writer byte for byte") {
    const Fixture expected = richFixtureV7();
    const std::string path = goldenPath("project-v7.json");
    const std::string written = serializeProject(expected.project) + "\n";
    // The golden file is checked in and never written by the test: a missing one is a failure
    // (readFile requires it), so a test run cannot bless its own output.
    const std::string text = readFile(path);
    CHECK(text == written);
    const ProjectLoadResult loaded = parseProject(text);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    CHECK(*loaded.project == expected.project);
    CHECK(contains(text, "\"reversed\": true"));
    CHECK(contains(text, "\"transition\": \"wipeLeft\""));
    CHECK(contains(text, "\"configured\": true"));
    CHECK(contains(text, "\"sharpenScaledDownSources\": false"));
}

TEST_CASE("ProjectJSON: the sequence settings' configured flag and the sharpen setting round trip") {
    Fixture fx = richFixtureV7();
    for (const bool configured : {false, true}) {
        for (const bool sharpen : {false, true}) {
            Project project = fx.project;
            project.sequences[0].configured = configured;
            project.sharpenScaledDownSources = sharpen;
            const ProjectLoadResult loaded = parseProject(serializeProject(project));
            REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
            CHECK(loaded.warnings.empty());
            CHECK(*loaded.project == project);
            CHECK(loaded.project->sequences[0].configured == configured);
            CHECK(loaded.project->sharpenScaledDownSources == sharpen);
        }
    }
    // Written by hand without them: both read as true (configured: opening never changes a sequence).
    json j = projectToJson(fx.project);
    j.erase("sharpenScaledDownSources");
    j["sequences"][0].erase("configured");
    const ProjectLoadResult loaded = projectFromJson(j);
    REQUIRE(loaded.ok());
    CHECK(loaded.project->sequences[0].configured);
    CHECK(loaded.project->sharpenScaledDownSources);
    // A value of the wrong type names its path.
    j["sequences"][0]["configured"] = "yes";
    const ProjectLoadResult wrong = projectFromJson(j);
    CHECK_FALSE(wrong.ok());
    CHECK(contains(wrong.error, "configured"));
}

TEST_CASE("ProjectJSON: a reversed clip round trips; an explicit false reads as forward") {
    Fixture fx = richFixtureV6();
    const ProjectLoadResult loaded = parseProject(serializeProject(fx.project));
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(*loaded.project == fx.project);
    const Clip &reversed = loaded.project->sequences[0].videoTracks[1].clips.back();
    CHECK(reversed.reversed);
    json j = projectToJson(fx.project);
    j["sequences"][0]["videoTracks"][1]["clips"][1]["reversed"] = false;
    const ProjectLoadResult explicitFalse = projectFromJson(j);
    REQUIRE(explicitFalse.ok());
    CHECK(*explicitFalse.project == fx.project);
}

TEST_CASE("ProjectJSON: \"reversed\" on a still is cleared with a warning, not refused (review L3)") {
    const Fixture fx = richFixtureV6();
    json j = projectToJson(fx.project);
    json &still = j["sequences"][0]["videoTracks"][1]["clips"][1];
    REQUIRE(still.value("isStill", false));
    still["reversed"] = true;
    const ProjectLoadResult loaded = projectFromJson(j);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(*loaded.project == fx.project); // the flag cleared, nothing else changed
    REQUIRE(loaded.warnings.size() == 1);
    CHECK(contains(loaded.warnings[0], "a still has no direction to reverse; \"reversed\" was cleared"));
    CHECK_FALSE(validateProject(*loaded.project).has_value());
    // The model itself still refuses it (an edit never makes one).
    Project edited = *loaded.project;
    edited.sequences[0].videoTracks[1].clips[1].reversed = true;
    const auto problem = validateProject(edited);
    REQUIRE(problem.has_value());
    CHECK(contains(*problem, "a still cannot be reversed"));
}

TEST_CASE("ProjectJSON: a version 5 file with version 6 content opens with a warning naming it (review L8)") {
    json document = json::parse(readFile(goldenPath("project-v5.json")));
    REQUIRE(document.at("schemaVersion") == 5);
    bool reversedSet = false;
    bool kindSet = false;
    for (json &track : document.at("sequences")[0].at("videoTracks")) {
        for (json &clip : track.at("clips")) {
            if (clip.at("id") == 15) { // a video-only clip on V2
                clip["reversed"] = true;
                reversedSet = true;
            }
            if (clip.contains("spans")) {
                for (json &span : clip.at("spans")) {
                    if (span.at("id") == 14) { // the dissolve between clips 11 and 13
                        span["transition"] = "wipeLeft";
                        kindSet = true;
                    }
                }
            }
        }
    }
    REQUIRE(reversedSet);
    REQUIRE(kindSet);
    const ProjectLoadResult loaded = parseProject(document.dump());
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    for (const std::string &warning : loaded.warnings) {
        MESSAGE(warning);
    }
    REQUIRE(loaded.warnings.size() == 2);
    CHECK(anyContains(loaded.warnings, "\"reversed\" is a version 6 feature in a project of an earlier version: "
                                       "kept, and the project is saved as version 7"));
    CHECK(anyContains(loaded.warnings, "a Wipe Left transition is a version 6 feature in a project of an earlier "
                                       "version: kept, and the project is saved as version 7"));
    const Sequence &sequence = loaded.project->sequences[0];
    CHECK(sequence.findClip(ClipId{15})->reversed);
    CHECK(sequence.findTransition(SpanId{14})->kind == TransitionKind::WipeLeft);
    // Saved in the current version, with both.
    const json saved = projectToJson(*loaded.project);
    CHECK(saved.at("schemaVersion") == kProjectSchemaVersion);
    const ProjectLoadResult again = projectFromJson(saved);
    REQUIRE(again.ok());
    CHECK(again.warnings.empty());
    CHECK(*again.project == *loaded.project);
}

TEST_CASE("ProjectJSON: version 4 to 5 migration rules") {
    auto load = [](const json &document) {
        const ProjectLoadResult r = projectFromJson(document);
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        return r;
    };
    SUBCASE("fades become lane-0 spans; a fade in on a touched start is dropped with a warning") {
        // A1: clip 10 [0, 60) with fades in 5 / out 6, clip 11 [60, 90) touching it with a fade in 7.
        const json doc = v4Document(json::array(), json::array({v4Clip(10, 4, 0, 60, 0, {{"audio", fades(5, 6)}}),
                                                                 v4Clip(11, 4, 60, 30, 100, {{"audio", fades(7, 0)}})}));
        const ProjectLoadResult r = load(doc);
        const Clip &first = onlyClip(*r.project, TrackKind::Audio, 0);
        const Clip &second = onlyClip(*r.project, TrackKind::Audio, 1);
        CHECK(clipFadeLength(first, ClipEdge::Head) == f30(5));
        CHECK(clipFadeLength(first, ClipEdge::Tail) == f30(6)); // a fade out needs nothing past the cut
        CHECK(second.transitions.empty());
        CHECK(second.spans.empty());
        CHECK(anyContains(r.warnings, "clips[1].audio.fadeInDuration: the fade in"));
        CHECK(anyContains(r.warnings, "the cut there belongs to that clip"));
        CHECK(first.transitions[0].id == SpanId{100}); // new ids from "nextId", in order
        CHECK(first.transitions[1].id == SpanId{101});
        CHECK(r.project->ids.nextValue() == 102);
    }
    SUBCASE("fades on an edge with a crossfade were ignored by version 4 and are dropped silently") {
        const json doc = v4Document(json::array(),
                                    json::array({v4Clip(10, 4, 0, 60, 0, {{"audio", fades(5, 6)}}),
                                                 v4Clip(11, 4, 60, 30, 100, {{"audio", fades(7, 8)}})}),
                                    json::array({v4Transition(12, 4, 10, 11, 10)}));
        const ProjectLoadResult r = load(doc);
        CHECK(r.warnings.empty());
        const Clip &first = onlyClip(*r.project, TrackKind::Audio, 0);
        const Clip &second = onlyClip(*r.project, TrackKind::Audio, 1);
        CHECK(clipFadeLength(first, ClipEdge::Head) == f30(5));
        CHECK(first.transitionAt(ClipEdge::Tail)->id == SpanId{12}); // the crossfade, not the fade
        CHECK(clipFadeLength(second, ClipEdge::Head) == kCMTimeZero);
        CHECK(clipFadeLength(second, ClipEdge::Tail) == f30(8));
    }
    SUBCASE("a fade in that would meet the crossfade at the clip's end is shortened, with a warning") {
        const json doc = v4Document(json::array(),
                                    json::array({v4Clip(10, 4, 0, 20, 0, {{"audio", fades(15, 0)}}),
                                                 v4Clip(11, 4, 20, 30, 100)}),
                                    json::array({v4Transition(12, 4, 10, 11, 16)}));
        const ProjectLoadResult r = load(doc);
        CHECK(clipFadeLength(onlyClip(*r.project, TrackKind::Audio), ClipEdge::Head) == f30(12));
        CHECK(anyContains(r.warnings, "would meet the crossfade at the clip's end; shortened to"));
    }
    SUBCASE("a fade out that would meet the incoming crossfade is shortened, with a warning (review H1)") {
        // Version 4 multiplied a fade out with a crossfade into the clip; version 5 keeps the fade
        // out of the crossfade's part inside the clip (ceil(n / 2) frames of a centred crossfade).
        const json doc = v4Document(json::array(),
                                    json::array({v4Clip(10, 4, 0, 60, 0), v4Clip(11, 4, 60, 30, 100, {{"audio", fades(0, 28)}})}),
                                    json::array({v4Transition(12, 4, 10, 11, 11)}));
        const ProjectLoadResult r = load(doc);
        const Clip &second = onlyClip(*r.project, TrackKind::Audio, 1);
        CHECK(clipFadeLength(second, ClipEdge::Tail) == f30(24)); // 30 - ceil(11 / 2)
        CHECK(onlyClip(*r.project, TrackKind::Audio, 0).transitionAt(ClipEdge::Tail)->id == SpanId{12});
        CHECK(anyContains(r.warnings, "clips[1].audio.fadeOutDuration: the fade out (28/30 "));
        CHECK(anyContains(r.warnings, "would meet the crossfade at the clip's start; shortened to 24/30 "));
    }
    SUBCASE("a fade out with no room left beside the incoming crossfade is dropped, with a warning") {
        const json doc = v4Document(json::array(),
                                    json::array({v4Clip(10, 4, 0, 60, 0), v4Clip(11, 4, 60, 5, 100, {{"audio", fades(0, 3)}})}),
                                    json::array({v4Transition(12, 4, 10, 11, 10)}));
        const ProjectLoadResult r = load(doc);
        CHECK(clipFadeLength(onlyClip(*r.project, TrackKind::Audio, 1), ClipEdge::Tail) == kCMTimeZero);
        CHECK(onlyClip(*r.project, TrackKind::Audio, 0).transitionAt(ClipEdge::Tail)->id == SpanId{12});
        CHECK(anyContains(r.warnings, "clips[1].audio.fadeOutDuration: the fade out (3/30 "));
        CHECK(anyContains(r.warnings, "would meet the crossfade at the clip's start; dropped"));
    }
    SUBCASE("fades on video clips never sounded and are dropped") {
        const json doc = v4Document(json::array({v4Clip(10, 3, 0, 60, 0, {{"audio", fades(5, 6)}})}), json::array());
        const ProjectLoadResult r = load(doc);
        CHECK(r.warnings.empty());
        CHECK(onlyClip(*r.project, TrackKind::Video).transitions.empty());
        CHECK(onlyClip(*r.project, TrackKind::Video).spans.empty());
    }
    SUBCASE("keyframes: Motion on lane 1 and Opacity on lane 2 over the clip, cut exactly at its edges") {
        // Source frames [30, 90): x has a keyframe a trim hid before the clip and one after it.
        json video = {{"x", 5.0}, {"y", 7.0}, {"scale", 2.0}, {"rotationDegrees", 3.0}, {"opacity", 0.5}};
        video["keyframes"] = {{"x", json::array({{{"time", frames(0)}, {"value", 0.0}, {"interpolation", "linear"}},
                                                 {{"time", frames(120)}, {"value", 120.0}, {"interpolation", "linear"}}})},
                              {"opacity", json::array({{{"time", frames(40)}, {"value", 0.25}, {"interpolation", "hold"}}})}};
        const json doc = v4Document(json::array({v4Clip(10, 3, 0, 60, 30, {{"video", video}})}), json::array());
        const ProjectLoadResult r = load(doc);
        CHECK(r.warnings.empty());
        const Clip &clip = onlyClip(*r.project, TrackKind::Video);
        CHECK(clip.video == VideoParams{0, 7, 2, 3, 1}); // animated statics neutral, the others kept
        REQUIRE(clip.spans.size() == 2);
        const EffectSpan &motion = clip.spans[0];
        CHECK(motion.kind == SpanKind::Motion);
        CHECK(motion.lane == 1);
        CHECK(motion.start == f30(30));
        CHECK(motion.end == f30(90));
        // Cut at the edges with the values there: 30 and 90 at relative 0 and 60.
        REQUIRE(motion.tracks[SpanParameter::X].size() == 2);
        CHECK(motion.tracks[SpanParameter::X][0].time == kCMTimeZero);
        CHECK(motion.tracks[SpanParameter::X][0].value == doctest::Approx(30));
        CHECK(motion.tracks[SpanParameter::X][1].time == f30(60));
        CHECK(motion.tracks[SpanParameter::X][1].value == doctest::Approx(90));
        const EffectSpan &opacity = clip.spans[1];
        CHECK(opacity.kind == SpanKind::Opacity);
        CHECK(opacity.lane == 2);
        CHECK(opacity.tracks[SpanParameter::Opacity] == KeyframeTrack{key(f30(10), 0.25, KeyframeInterpolation::Hold)});
        CHECK(motionValuesAt(clip, f30(30)).x == doctest::Approx(60)); // source frame 60
    }
    SUBCASE("opacity keyframes alone go to lane 1") {
        json video = {{"x", 0.0}, {"y", 0.0}, {"scale", 1.0}, {"rotationDegrees", 0.0}, {"opacity", 1.0}};
        video["keyframes"] = {{"opacity", json::array({{{"time", frames(0)}, {"value", 0.0}}, {{"time", frames(30)}, {"value", 1.0}}})}};
        const ProjectLoadResult r = load(v4Document(json::array({v4Clip(10, 3, 0, 60, 0, {{"video", video}})}), json::array()));
        const Clip &clip = onlyClip(*r.project, TrackKind::Video);
        REQUIRE(clip.spans.size() == 1);
        CHECK(clip.spans[0].kind == SpanKind::Opacity);
        CHECK(clip.spans[0].lane == 1);
    }
    SUBCASE("an overshooting custom curve cut at the clip's edge is limited, with a warning") {
        json video = {{"x", 0.0}, {"y", 0.0}, {"scale", 1.0}, {"rotationDegrees", 0.0}, {"opacity", 1.0}};
        video["keyframes"] = {{"opacity", json::array({{{"time", frames(0)}, {"value", 0.5}, {"interpolation", "bezier"},
                                                        {"curve", json::array({0.2, 3.0, 0.8, 3.0})}},
                                                       {{"time", frames(60)}, {"value", 1.0}}})}};
        const ProjectLoadResult r = load(v4Document(json::array({v4Clip(10, 3, 0, 30, 30, {{"video", video}})}), json::array()));
        CHECK(anyContains(r.warnings, "a custom curve took Opacity to"));
        const Clip &clip = onlyClip(*r.project, TrackKind::Video);
        CHECK(clip.spans[0].tracks[SpanParameter::Opacity].front().value == 1.0);
    }
    SUBCASE("an unknown Motion parameter in version 4 keyframes is dropped with a warning") {
        json video = {{"x", 0.0}, {"y", 0.0}, {"scale", 1.0}, {"rotationDegrees", 0.0}, {"opacity", 1.0}};
        video["keyframes"] = {{"skew", json::array({{{"time", frames(0)}, {"value", 1.0}}})}};
        const ProjectLoadResult r = load(v4Document(json::array({v4Clip(10, 3, 0, 60, 0, {{"video", video}})}), json::array()));
        CHECK(anyContains(r.warnings, "keyframes: unknown Motion parameter \"skew\"; its keyframes were dropped"));
        CHECK(onlyClip(*r.project, TrackKind::Video).spans.empty());
    }
    SUBCASE("a transition naming a missing outgoing clip is an error") {
        const json doc = v4Document(json::array({v4Clip(10, 3, 0, 60, 0)}), json::array(),
                                    json::array({v4Transition(12, 3, 99, 10, 10)}));
        CHECK(contains(loadError(doc), "its outgoing clip 99 does not exist"));
    }
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
    SUBCASE("overlapping fades are shortened to fit, with a warning, and become spans") {
        const json audio = {{"gainDb", 0.0},
                            {"fadeInDuration", timeToJson(CMTimeMake(20, 30))},
                            {"fadeOutDuration", timeToJson(CMTimeMake(20, 30))}};
        const ProjectLoadResult r = projectFromJson(v1Document(json{{"audio", audio}}));
        REQUIRE_MESSAGE(r.ok(), doctest::String(r.error.c_str()));
        const Clip &clip = r.project->sequences[0].audioTracks[0].clips[0];
        CHECK(clipFadeLength(clip, ClipEdge::Head) == CMTimeMake(20, 30));
        CHECK(clipFadeLength(clip, ClipEdge::Tail) == CMTimeMake(10, 30));
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
