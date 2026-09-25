// Version 4 projects render exactly as before once migrated to effect spans (schema 5). The
// expectations were recorded with the schema-4 engine (before effect lanes) from two version 4
// files: the golden project-v4.json (Motion keyframes, audio fades, a dissolve, an NTSC sequence)
// and project-v4-render.json (keyframes a trim hid, a 2x clip, a keyframed still over a VFR
// slow-motion clip, audio fades a crossfade overrode, fades touching a neighbour, an odd-length
// NTSC dissolve and crossfade). For every sequence frame the Scheduler's layers must match
// (clip, asset, track, the exact source time; Motion and opacity and a transition's mix within
// 1e-9), and every 1/240 s each sounding clip's linear gain and source time as the mixer applies
// them.

#include "../../Engine/Render/Scheduler.h"
#include "../Model/ModelFixtures.h"
#include "../Model/SpanReference.h"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <map>
#include <sstream>

using namespace vetest;
using nlohmann::json;

namespace {

constexpr double kTolerance = 1e-9;

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

bool near(double a, double b) {
    return std::fabs(a - b) <= kTolerance * std::max(1.0, std::fabs(b));
}

// The linear gain of `segment` at `t` as AudioMixer applies it (RenderGraph.h's law).
double gainAt(const AudioSegment &segment, CMTime t) {
    const double f = fractionThrough(segment.timelineRange, t);
    const double level = segment.level.start + (segment.level.end - segment.level.start) * f;
    const double fade = segment.fade.start + (segment.fade.end - segment.fade.start) * f;
    const double c = segment.crossfade.start + (segment.crossfade.end - segment.crossfade.start) * f;
    const double shape = segment.transitionId ? constantPowerGain(c) : c;
    return decibelsToGain(level) * fade * shape;
}

struct Counts {
    std::int64_t frames = 0;
    std::int64_t layers = 0;
    std::int64_t transitionLayers = 0;
    std::int64_t audioSamples = 0;
    std::int64_t audioContributions = 0;
};

void compareVideo(const Project &project, const Sequence &sequence, const json &expected, Counts &counts) {
    const std::int64_t count = frameIndexAt(sequence.duration(), sequence.frameDuration, SnapMode::Ceil);
    REQUIRE(static_cast<std::int64_t>(expected.size()) == count);
    for (std::int64_t i = 0; i < count; ++i) {
        const RenderGraph graph = Scheduler::renderGraphAt(sequence, project, timeForFrame(i, sequence.frameDuration));
        const json &layers = expected[static_cast<std::size_t>(i)];
        INFO("sequence " << sequence.id.value() << " frame " << i);
        REQUIRE(graph.layers.size() == layers.size());
        ++counts.frames;
        for (std::size_t k = 0; k < layers.size(); ++k) {
            const VideoLayer &layer = graph.layers[k];
            const json &want = layers[k];
            INFO("layer " << k << " (clip " << layer.clipId.value() << ")");
            CHECK(layer.clipId.value() == want.at("clip").get<std::uint64_t>());
            CHECK(layer.assetId.value() == want.at("asset").get<std::uint64_t>());
            CHECK(layer.trackId.value() == want.at("track").get<std::uint64_t>());
            CHECK(layer.sourceTime.value == want.at("sourceTime").at("value").get<std::int64_t>());
            CHECK(layer.sourceTime.timescale == want.at("sourceTime").at("timescale").get<std::int32_t>());
            CHECK(near(layer.transform.x, want.at("x").get<double>()));
            CHECK(near(layer.transform.y, want.at("y").get<double>()));
            CHECK(near(layer.transform.scale, want.at("scale").get<double>()));
            CHECK(near(layer.transform.rotationDegrees, want.at("rotation").get<double>()));
            CHECK(near(layer.opacity, want.at("opacity").get<double>()));
            CHECK(layer.transition.has_value() == want.contains("mix"));
            if (layer.transition && want.contains("mix")) {
                ++counts.transitionLayers;
                CHECK(layer.transition->role == TransitionRole::CrossDissolve);
                CHECK(near(layer.transition->mix, want.at("mix").get<double>()));
                CHECK(layer.transition->isIncoming == want.at("incoming").get<bool>());
                CHECK(layer.transition->partnerClipId.value() == want.at("partner").get<std::uint64_t>());
                CHECK(layer.transition->partnerLayerIndex == want.at("partnerIndex").get<std::size_t>());
            }
            ++counts.layers;
        }
    }
}

void compareAudio(const Project &project, const Sequence &sequence, const json &expected, Counts &counts) {
    const TimeRange whole{kCMTimeZero, sequence.duration()};
    const AudioGraph graph = Scheduler::audioGraphFor(sequence, project, whole);
    const std::int64_t samples = frameIndexAt(sequence.duration(), CMTimeMake(1, 240), SnapMode::Ceil);
    REQUIRE(static_cast<std::int64_t>(expected.size()) == samples);
    for (std::int64_t k = 0; k < samples; ++k) {
        const CMTime t = CMTimeMake(k, 240);
        INFO("sequence " << sequence.id.value() << " at " << k << "/240 s");
        // One segment per sounding clip contains t (a clip's segments are contiguous and half open).
        std::map<std::uint64_t, std::pair<double, double>> sounding; // clip -> gain, source seconds
        for (const AudioSegment &segment : graph.segments) {
            if (!segment.timelineRange.contains(t)) {
                continue;
            }
            const double into = toSeconds(t - segment.timelineRange.start);
            const bool inserted =
                sounding
                    .emplace(segment.clipId.value(),
                             std::make_pair(gainAt(segment, t), toSeconds(segment.sourceRange.start) + into * segment.speed))
                    .second;
            CHECK_MESSAGE(inserted, "clip " << segment.clipId.value() << " has two segments here");
        }
        const json &want = expected[static_cast<std::size_t>(k)];
        REQUIRE(sounding.size() == want.size());
        ++counts.audioSamples;
        for (const json &entry : want) {
            const std::uint64_t clip = entry.at("clip").get<std::uint64_t>();
            INFO("clip " << clip);
            const auto found = sounding.find(clip);
            REQUIRE(found != sounding.end());
            CHECK(near(found->second.first, entry.at("gain").get<double>()));
            CHECK(near(found->second.second, entry.at("source").get<double>()));
            ++counts.audioContributions;
        }
    }
}

Counts compareProject(const char *projectFile, const char *expectedFile) {
    const ProjectLoadResult loaded = parseProject(readFile(goldenPath(projectFile)));
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    REQUIRE(json::parse(readFile(goldenPath(projectFile))).at("schemaVersion") == 4);
    const json expected = json::parse(readFile(goldenPath(expectedFile)));
    const Project &project = *loaded.project;
    REQUIRE(expected.at("sequences").size() == project.sequences.size());
    Counts counts;
    for (std::size_t s = 0; s < project.sequences.size(); ++s) {
        const Sequence &sequence = project.sequences[s];
        const json &recorded = expected.at("sequences")[s];
        REQUIRE(recorded.at("id").get<std::uint64_t>() == sequence.id.value());
        compareVideo(project, sequence, recorded.at("video"), counts);
        compareAudio(project, sequence, recorded.at("audio"), counts);
    }
    return counts;
}

} // namespace

TEST_CASE("Migration render: the golden version 4 project renders as it did before effect spans") {
    const Counts counts = compareProject("project-v4.json", "project-v4.expected.json");
    MESSAGE("project-v4: " << counts.frames << " frames, " << counts.layers << " layers (" << counts.transitionLayers
                           << " in a dissolve), " << counts.audioSamples << " audio instants, "
                           << counts.audioContributions << " clip gains");
    // (Its V2 track is soloed, so V1 and its dissolve are not drawn; the second file covers them.)
    CHECK(counts.frames > 200);
    CHECK(counts.layers > 40);
    CHECK(counts.audioContributions > 1000);
}

TEST_CASE("Migration render: hidden keyframes, speed, stills, VFR, fades and NTSC render as before") {
    const Counts counts = compareProject("project-v4-render.json", "project-v4-render.expected.json");
    MESSAGE("project-v4-render: " << counts.frames << " frames, " << counts.layers << " layers ("
                                  << counts.transitionLayers << " in a dissolve), " << counts.audioSamples
                                  << " audio instants, " << counts.audioContributions << " clip gains");
    CHECK(counts.frames > 150);
    CHECK(counts.transitionLayers > 0);
    CHECK(counts.audioContributions > 1000);
}

TEST_CASE("Migration render: the changes a migration only warns about render as warned (review L11)") {
    // The render golden with three fades version 5 cannot keep as version 4 had them (each warned):
    // audio clip 12 [0,60) fading in over 58 frames under the 10-frame crossfade 16 at its end (5
    // frames inside it): shortened to 55; clip 14 [60,120) fading out over 57 frames with that
    // crossfade coming in (5 frames inside it): shortened to 55 (review H1); clip 22 [150,180)
    // fading in over 6 frames while clip 21 touches its start: dropped.
    json document = json::parse(readFile(goldenPath("project-v4-render.json")));
    std::size_t edited = 0;
    for (json &track : document.at("sequences")[0].at("audioTracks")) {
        for (json &clip : track.at("clips")) {
            json &audio = clip.at("audio");
            const auto id = clip.at("id").get<std::uint64_t>();
            if (id == 12) {
                audio["fadeInDuration"] = json{{"value", 58}, {"timescale", 30}};
            } else if (id == 14) {
                audio["fadeOutDuration"] = json{{"value", 57}, {"timescale", 30}};
            } else if (id == 22) {
                audio["fadeInDuration"] = json{{"value", 6}, {"timescale", 30}};
            } else {
                continue;
            }
            ++edited;
        }
    }
    REQUIRE(edited == 3);
    const ProjectLoadResult loaded = parseProject(document.dump());
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    auto warned = [&](const std::string &needle) {
        return std::any_of(loaded.warnings.begin(), loaded.warnings.end(),
                           [&](const std::string &w) { return w.find(needle) != std::string::npos; });
    };
    CHECK(warned("clips[0].audio.fadeInDuration: the fade in (58/30"));
    CHECK(warned("would meet the crossfade at the clip's end; shortened to 55/30"));
    CHECK(warned("would meet the crossfade at the clip's start; shortened to 55/30"));
    CHECK(warned("clips[2].audio.fadeInDuration: the fade in (6/30"));

    const Project &project = *loaded.project;
    const Sequence &sequence = project.sequences[0];
    const AudioGraph graph = Scheduler::audioGraphFor(sequence, project, TimeRange{kCMTimeZero, sequence.duration()});
    auto gain = [&](std::uint64_t clip, CMTime t) -> std::optional<double> {
        for (const AudioSegment &segment : graph.segments) {
            if (segment.clipId.value() == clip && segment.timelineRange.contains(t)) {
                return gainAt(segment, t);
            }
        }
        return std::nullopt;
    };
    const double level14 = std::pow(10.0, -3.0 / 20); // clip 14's static gain
    for (int k = 0; k < 240 * 6; ++k) {
        const CMTime t = CMTimeMake(k, 240);
        const double frame = k / 8.0; // 30 fps
        INFO("at frame " << frame);
        if (frame < 55) {
            // Clip 12 fades in over 55 frames (not 58), alone.
            const auto g = gain(12, t);
            REQUIRE(g.has_value());
            CHECK(near(*g, frame / 55));
        }
        if (frame >= 65 && frame < 120) {
            // Clip 14 fades out over its last 55 frames (not 57), after the crossfade's part.
            const auto g = gain(14, t);
            REQUIRE(g.has_value());
            CHECK(near(*g, level14 * (120 - frame) / 55));
        }
        if (frame >= 150 && frame < 170) {
            // Clip 22 plays at full level from its first frame: no fade in (clip 21 touches it).
            const auto g = gain(22, t);
            REQUIRE(g.has_value());
            CHECK(near(*g, 1.0));
        }
    }
}

TEST_CASE("Migration render: an opacity-only clip and a custom curve cut at a clip's edge render as version 4") {
    // The review's test gap 3 (the goldens cannot be re-recorded: their tool needed the schema-4
    // engine), checked instead against version 4's rule computed independently: a keyframed
    // parameter follows its keyframes over source time and holds the first and last values
    // outside them. Clip 10 [0, 60) from source 0 has opacity keyframes only (1 at 0.5 s, 0.2 at
    // 1.5 s, linear); clip 11 [60, 120) from source 1 s has x on a custom curve from 0 at 0.5 s to
    // 300 at 2 s, so its in point cuts the curve.
    auto time = [](std::int64_t frames) { return json{{"value", frames}, {"timescale", 30}}; };
    auto key = [&](std::int64_t frames, double value, const char *interpolation) {
        return json{{"time", time(frames)}, {"value", value}, {"interpolation", interpolation}};
    };
    json curved = key(15, 0, "bezier");
    curved["curve"] = json::array({0.3, 0.1, 0.6, 0.95});
    auto clip = [&](std::uint64_t id, std::int64_t start, std::int64_t in, const json &keyframes) {
        return json{{"id", id},
                    {"assetId", 1},
                    {"trackId", 3},
                    {"timelineStart", time(start)},
                    {"duration", time(60)},
                    {"sourceIn", time(in)},
                    {"speed", {{"num", 1}, {"den", 1}}},
                    {"video",
                     {{"x", 0.0}, {"y", 0.0}, {"scale", 1.0}, {"rotationDegrees", 0.0}, {"opacity", 0.5},
                      {"keyframes", keyframes}}},
                    {"audio", {{"gainDb", 0.0}, {"fadeInDuration", time(0)}, {"fadeOutDuration", time(0)}}}};
    };
    const json document{
        {"schemaVersion", 4},
        {"name", "v4"},
        {"nextId", 100},
        {"activeSequenceId", 2},
        {"assets", json::array({json{{"id", 1}, {"name", "av.mov"}, {"url", "/av.mov"}, {"kind", "av"},
                                     {"duration", time(1800)}, {"videoDuration", time(1800)},
                                     {"frameDuration", time(1)}, {"width", 1920}, {"height", 1080},
                                     {"audioSampleRate", 48000}, {"audioChannels", 2}}})},
        {"sequences",
         json::array({json{{"id", 2},
                           {"name", "S"},
                           {"frameDuration", time(1)},
                           {"width", 1920},
                           {"height", 1080},
                           {"videoTracks",
                            json::array({json{{"id", 3},
                                              {"kind", "video"},
                                              {"name", "V1"},
                                              {"clips", json::array({clip(10, 0, 0, {{"opacity", json::array({key(15, 1, "linear"), key(45, 0.2, "linear")})}}),
                                                                     clip(11, 60, 30, {{"x", json::array({curved, key(60, 300, "linear")})}})})}}})},
                           {"audioTracks", json::array({json{{"id", 4}, {"kind", "audio"}, {"name", "A1"}, {"clips", json::array()}}})},
                           {"transitions", json::array()}}})}};
    const ProjectLoadResult loaded = projectFromJson(document);
    REQUIRE_MESSAGE(loaded.ok(), doctest::String(loaded.error.c_str()));
    CHECK(loaded.warnings.empty());
    const Project &project = *loaded.project;
    const Sequence &sequence = project.sequences[0];
    for (std::int64_t f = 0; f < 120; ++f) {
        const RenderGraph graph = Scheduler::renderGraphAt(sequence, project, CMTimeMake(f, 30));
        REQUIRE(graph.layers.size() == 1);
        const VideoLayer &layer = graph.layers[0];
        INFO("frame " << f);
        if (f < 60) {
            const double s = f / 30.0;
            const double opacity = s < 0.5 ? 1.0 : s >= 1.5 ? 0.2 : 1.0 + (0.2 - 1.0) * (s - 0.5);
            CHECK(layer.clipId.value() == 10u);
            CHECK(near(layer.opacity, opacity));
            CHECK(near(layer.transform.x, 0));
        } else {
            const double s = 1.0 + (f - 60) / 30.0;
            const double x = s >= 2 ? 300.0 : 300.0 * referenceCurve(0.3, 0.1, 0.6, 0.95, (s - 0.5) / 1.5);
            CHECK(layer.clipId.value() == 11u);
            CHECK(std::fabs(layer.transform.x - x) < 1e-6);
            CHECK(near(layer.opacity, 0.5)); // not keyframed: the static value (unused where keyframed)
        }
    }
}

