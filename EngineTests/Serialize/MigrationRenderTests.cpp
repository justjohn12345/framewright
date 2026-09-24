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
