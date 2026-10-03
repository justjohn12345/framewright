// Paused seeks on variable-frame-rate, long-GOP sources (the report "sometimes clicking to move the
// playhead the program output doesn't update", on a project of macOS screen recordings: frames only
// when the screen changes, gaps of seconds, keyframes up to 11 s apart, clips at 3/5, 3/2, 5/4, 1/10 and
// 1x). Ruler clicks at seeded random places, as the app makes them (scrubTo on mouse down, endScrub on
// mouse up, the monitor redrawn only when the controller asks: SeekRig), each checked within 2 s: the
// monitor must show the clicked frame with the exact picture of every layer. The default run makes 20
// (PausedSeekTests); the 200-click soak and the user's demo project are PausedSeekSoakTests, in the
// opt-in StressTests scheme.
//
// The mix: anywhere; inside a static gap of a source; on a frame showing the same source frame as the
// previous click (the picture does not change, but the monitor must still present the new frame); three
// clicks in quick succession (only the last counts); in a sped-up clip; right after an edit; while the
// stopped lookahead of the previous click is decoding.

#import <XCTest/XCTest.h>

#include "PausedSeekRig.h"

#include "../Stress/StressSupport.h"

#include "../../Engine/Media/AssetImport.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Model/Validation.h"
#include "../../Engine/Render/Scheduler.h"
#include "../../Engine/Serialize/ProjectJSON.h"
#include "../Media/TestMedia.h"

#include <algorithm>
#include <chrono>
#include <fstream>
#include <future>
#include <map>
#include <random>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using namespace ve;
using namespace ve::test;

namespace {

/// The user's demo project (read-only; its media are read in place). FRAMEWRIGHT_DEMO_PROJECT overrides.
std::string demoProjectPath() {
    if (const char *env = std::getenv("FRAMEWRIGHT_DEMO_PROJECT"); env && *env) {
        return env;
    }
    const char *home = std::getenv("HOME");
    return std::string(home ? home : "") + "/Movies/Framewright Demo/demo1.framewright";
}

enum class SeekKind { Anywhere, StaticGap, SameSourceFrame, Rapid, SpedUp, AfterEdit, LookaheadBusy };

const char *nameOf(SeekKind kind) {
    switch (kind) {
    case SeekKind::Anywhere:
        return "anywhere";
    case SeekKind::StaticGap:
        return "static gap";
    case SeekKind::SameSourceFrame:
        return "same source frame";
    case SeekKind::Rapid:
        return "rapid clicks";
    case SeekKind::SpedUp:
        return "sped-up clip";
    case SeekKind::AfterEdit:
        return "after an edit";
    case SeekKind::LookaheadBusy:
        return "lookahead busy";
    }
    return "?";
}

struct SeekReport {
    int seeks = 0;
    std::map<std::string, int> missesByCategory;
    std::map<std::string, int> missesByKind;
    std::vector<double> latencies;
    std::vector<std::string> misses;

    int missCount() const { return static_cast<int>(misses.size()); }
    std::string summary() const {
        std::ostringstream s;
        s << missCount() << " misses out of " << seeks;
        for (const auto &[category, n] : missesByCategory) {
            s << "; " << category << ": " << n;
        }
        for (const auto &[kind, n] : missesByKind) {
            s << "; [" << kind << "] " << n;
        }
        if (!latencies.empty()) {
            std::vector<double> sorted = latencies;
            std::sort(sorted.begin(), sorted.end());
            s.precision(0);
            s << std::fixed << "; latency median " << sorted[sorted.size() / 2] << " ms, p95 "
              << sorted[std::min(sorted.size() - 1, sorted.size() * 95 / 100)] << " ms, max " << sorted.back()
              << " ms";
        }
        return s.str();
    }
};

/// Runs `count` seeded random clicks over `rig`'s sequence (see the file comment).
SeekReport runClicks(SeekRig &rig, int count, uint32_t seed, std::chrono::milliseconds bound) {
    std::mt19937 rng(seed);
    auto uniform = [&](int64_t lo, int64_t hi) { return std::uniform_int_distribution<int64_t>(lo, hi)(rng); };

    const Sequence &sequence = *rig.project.findSequence(rig.sequenceId);
    const CMTime fd = sequence.frameDuration;
    const int64_t lastFrame = frameIndexAt(sequence.duration(), fd, SnapMode::Ceil) - 1;

    // Video clips, the sped-up ones, and sequence frames inside a static gap (> 1 s without a frame).
    std::vector<const Clip *> spedUp;
    std::vector<int64_t> gapFrames;
    for (const Track &track : sequence.videoTracks) {
        for (const Clip &clip : track.clips) {
            if (clip.speed.num > clip.speed.den) {
                spedUp.push_back(&clip);
            }
            auto table = rig.tables.find(clip.assetId);
            if (table == rig.tables.end()) {
                continue;
            }
            const int64_t first = frameIndexAt(clip.timelineStart, fd, SnapMode::Floor);
            const int64_t length = frameIndexAt(clip.duration(), fd, SnapMode::Floor);
            for (int64_t f = first; f < first + length; ++f) {
                const RenderGraph graph = Scheduler::renderGraphAt(sequence, rig.project, timeForFrame(f, fd));
                for (const VideoLayer &layer : graph.layers) {
                    if (layer.clipId != clip.id) {
                        continue;
                    }
                    const CMTime shown = table->second.frameAt(layer.sourceTime);
                    auto next = std::upper_bound(table->second.frames.begin(), table->second.frames.end(), shown,
                                                 [](CMTime a, CMTime b) { return CMTimeCompare(a, b) < 0; });
                    if (next != table->second.frames.end() && CMTimeGetSeconds(*next - shown) >= 1.0) {
                        gapFrames.push_back(f);
                    }
                }
            }
        }
    }
    const std::vector<std::pair<SeekKind, int>> weights = {
        {SeekKind::Anywhere, 30},   {SeekKind::StaticGap, 15}, {SeekKind::SameSourceFrame, 10},
        {SeekKind::Rapid, 10},      {SeekKind::SpedUp, 15},    {SeekKind::AfterEdit, 10},
        {SeekKind::LookaheadBusy, 10},
    };
    int totalWeight = 0;
    for (const auto &w : weights) {
        totalWeight += w.second;
    }
    auto pickKind = [&] {
        int r = static_cast<int>(uniform(0, totalWeight - 1));
        for (const auto &w : weights) {
            if (r < w.second) {
                return w.first;
            }
            r -= w.second;
        }
        return SeekKind::Anywhere;
    };
    // The clip whose gain the "after an edit" clicks toggle (an edit that leaves the picture alone): an
    // audio clip, else a video clip (its gain is unused without linked audio).
    ClipId gainClip;
    for (const auto *tracks : {&sequence.audioTracks, &sequence.videoTracks}) {
        for (const Track &track : *tracks) {
            if (!gainClip.isValid() && !track.clips.empty()) {
                gainClip = track.clips.front().id;
            }
        }
    }

    SeekReport report;
    int64_t previous = lastFrame / 2;
    for (int i = 0; i < count; ++i) {
        SeekKind kind = pickKind();
        if ((kind == SeekKind::StaticGap && gapFrames.empty()) || (kind == SeekKind::SpedUp && spedUp.empty()) ||
            (kind == SeekKind::AfterEdit && !gainClip.isValid())) {
            kind = SeekKind::Anywhere;
        }
        int64_t frame = uniform(0, lastFrame);
        switch (kind) {
        case SeekKind::StaticGap:
            frame = gapFrames[static_cast<size_t>(uniform(0, static_cast<int64_t>(gapFrames.size()) - 1))];
            break;
        case SeekKind::SameSourceFrame: {
            const auto before = rig.expected(previous);
            frame = previous; // at worst the same frame again
            for (int64_t k = 1; k <= 20 && previous + k <= lastFrame; ++k) {
                const auto candidate = rig.expected(previous + k);
                const bool same = candidate.size() == before.size() &&
                                  std::equal(candidate.begin(), candidate.end(), before.begin(), [](auto &a, auto &b) {
                                      return a.clip == b.clip && CMTimeCompare(a.pts, b.pts) == 0;
                                  });
                if (same) {
                    frame = previous + k;
                    break;
                }
            }
            break;
        }
        case SeekKind::SpedUp: {
            const Clip *clip = spedUp[static_cast<size_t>(uniform(0, static_cast<int64_t>(spedUp.size()) - 1))];
            const int64_t first = frameIndexAt(clip->timelineStart, fd, SnapMode::Floor);
            frame = first + uniform(0, frameIndexAt(clip->duration(), fd, SnapMode::Floor) - 1);
            break;
        }
        case SeekKind::AfterEdit:
            if (Clip *clip = rig.project.findSequence(rig.sequenceId)->findClip(gainClip)) {
                clip->audio.gainDb = clip->audio.gainDb == 0.0 ? -0.5 : 0.0;
                rig.publishEdit();
            }
            break;
        case SeekKind::LookaheadBusy:
            // The stopped lookahead starts 100 ms after the playhead stops (PlaybackConfig).
            std::this_thread::sleep_for(std::chrono::milliseconds(uniform(110, 250)));
            break;
        case SeekKind::Rapid:
            for (int k = 0; k < 2; ++k) {
                rig.click(uniform(0, lastFrame), std::chrono::milliseconds(uniform(5, 20)));
                std::this_thread::sleep_for(std::chrono::milliseconds(uniform(10, 40)));
            }
            break;
        case SeekKind::Anywhere:
            break;
        }
        const auto clickedAt = rig.click(frame, std::chrono::milliseconds(uniform(50, 140)));
        const SeekRig::Outcome outcome = rig.check(frame, clickedAt, bound);
        ++report.seeks;
        if (outcome.shown) {
            report.latencies.push_back(outcome.latencyMs);
        } else {
            ++report.missesByCategory[outcome.category];
            ++report.missesByKind[nameOf(kind)];
            report.misses.push_back(std::string("[") + nameOf(kind) + "] " + outcome.category + ": " + outcome.details);
        }
        previous = frame;
        // The user's pause before the next click.
        std::this_thread::sleep_for(std::chrono::milliseconds(uniform(20, 300)));
    }
    return report;
}

/// A clip of the test projects: on V1 (track 0) or V2 (1), from sequence frame `start` (30 fps) for
/// `frames`, from `sourceIn` at `speed`.
struct ClipSpec {
    int track = 0;
    int64_t start = 0;
    int64_t frames = 0;
    CMTime sourceIn = kCMTimeZero;
    Ratio speed{1, 1};
};

/// A 30 fps project with `clips` of the generated media file `file`. `error` says why not.
std::optional<std::pair<Project, SequenceId>> projectOf(const std::string &file, const std::vector<ClipSpec> &clips,
                                                        std::string &error) {
    const std::string path = testMediaPath(file, error);
    if (path.empty()) {
        return std::nullopt;
    }
    auto router = media::BackendRouter::makeDefault();
    (void)router->registerBackend(media::ffmpeg::makeFFmpegBackend());
    auto routed = router->probe(path);
    if (!routed.ok()) {
        error = routed.error().description();
        return std::nullopt;
    }
    Project project;
    project.name = "Paused seeks";
    const SequenceId sequenceId = project.addSequence("Main", CMTimeMake(1, 30), 1920, 1080, 2, 1);
    const AssetId assetId = project.ids.make<AssetId>();
    auto asset = media::makeMediaAsset(*routed, assetId);
    if (!asset.ok()) {
        error = asset.error().description();
        return std::nullopt;
    }
    project.assets.push_back(*asset);
    Sequence &sequence = *project.findSequence(sequenceId);
    for (const ClipSpec &spec : clips) {
        Track &track = sequence.videoTracks.at(static_cast<size_t>(spec.track));
        Clip clip;
        clip.id = project.ids.make<ClipId>();
        clip.assetId = assetId;
        clip.trackId = track.id;
        clip.timelineStart = CMTimeMake(spec.start, 30);
        clip.timelineDuration = CMTimeMake(spec.frames, 30);
        clip.sourceIn = spec.sourceIn;
        clip.speed = spec.speed;
        track.clips.push_back(clip);
        track.sortClips();
    }
    if (auto problem = validateProject(project)) {
        error = *problem;
        return std::nullopt;
    }
    return std::make_pair(std::move(project), sequenceId);
}

/// Like the reported project, over screencast_vfr_h264.mov (a screen recording: bursts of frames
/// between static gaps of up to 5.9 s, keyframes up to 21 s apart): V1 has five clips at 3/5, 1, 3/2,
/// 5/4 and 1 through the recording, V2 a 1/10 clip over the first 280 frames.
std::optional<std::pair<Project, SequenceId>> screencastProject(std::string &error) {
    return projectOf("screencast_vfr_h264.mov",
                     {
                         {0, 0, 300, kCMTimeZero, Ratio{3, 5}},           // source [0, 6)
                         {0, 300, 300, CMTimeMake(6, 1), Ratio{1, 1}},    // [6, 16)
                         {0, 600, 300, CMTimeMake(16, 1), Ratio{3, 2}},   // [16, 31)
                         {0, 900, 300, CMTimeMake(31, 1), Ratio{5, 4}},   // [31, 43.5)
                         {0, 1200, 900, CMTimeMake(87, 2), Ratio{1, 1}},  // [43.5, 73.5)
                         {1, 0, 280, CMTimeMake(1, 2), Ratio{1, 10}},     // [0.5, 1.43)
                     },
                     error);
}

/// The frame cache of the deterministic tests: `frames` pictures of h264_1080p30.mp4 (1920x1080 4:2:0)
/// with room for the IOSurface's row padding.
size_t budgetOf1080Frames(size_t frames) {
    return frames * 1920 * 1080 * 3 / 2 + (size_t(1) << 20);
}

/// Clicks at `frame`, waits until the monitor shows it and the stopped lookahead there has settled.
bool clickAndSettle(SeekRig &rig, int64_t frame, std::chrono::milliseconds lookaheadDelay) {
    const auto clickedAt = rig.click(frame, std::chrono::milliseconds(30));
    if (!rig.check(frame, clickedAt, std::chrono::seconds(5)).shown) {
        return false;
    }
    std::this_thread::sleep_for(lookaheadDelay + std::chrono::milliseconds(100));
    return rig.pool->waitUntilIdle(std::chrono::seconds(10));
}

} // namespace

@interface PausedSeekTests : XCTestCase
@end

@implementation PausedSeekTests

/// The reported case on generated media, short enough for the default run: 20 seeded clicks over a
/// project of clips of a screen recording at the reported speeds, with a frame cache that holds about
/// as many of its frames as the default 512 MB holds of the reported 3832x2154 recordings (about 40).
/// Before the paused picture was pinned, a picture the scrub path decoded far from the pool's
/// (previous) focus was evicted as it was put and the monitor kept the previous picture. The 200-click
/// soak of the same mix is PausedSeekSoakTests (StressTests scheme).
- (void)testTwentyClicksOnAScreenRecordingShowTheirFrame {
    std::string error;
    auto built = screencastProject(error);
    XCTAssertTrue(built.has_value(), @"%s", error.c_str());
    if (!built) {
        return;
    }
    SeekRig::Options options;
    // 40 frames of 1280x720 4:2:0 (8 bits) with room for the IOSurface's row padding.
    options.cacheBudgetBytes = size_t(40) * 1280 * 720 * 3 / 2 + (size_t(2) << 20);
    SeekRig rig(built->first, built->second, options);
    XCTAssertTrue(rig.ok(), @"%s", rig.error().c_str());
    if (!rig.ok()) {
        return;
    }
    const SeekReport report = runClicks(rig, 20, 20260929, std::chrono::seconds(2));
    for (const std::string &miss : report.misses) {
        NSLog(@"PAUSED SEEK MISS %s", miss.c_str());
    }
    NSLog(@"PAUSED SEEKS (screen recording, 20 clicks): %s", report.summary().c_str());
    XCTAssertEqual(report.missCount(), 0, @"%s", report.summary().c_str());
}

/// The mechanism of the report, deterministically. The decode pool's focus (what the cache evicts last)
/// is its streams' targets: after a click the stopped lookahead of the previous place, until the new
/// place's lookahead follows (restDelay after a click: at once by default, held off here). A click far
/// before it, with the cache full: the
/// picture the scrub path decodes is behind every focus, the first to go, and was evicted as it was put;
/// the request completed, the redraw found nothing, nothing was in flight any more, and the monitor
/// kept the previous picture for good. Pinned from its insertion, it is presented.
- (void)testAPictureDecodedFarBehindTheLookaheadIsPresented {
    std::string error;
    auto built = projectOf("h264_1080p30.mp4", {{0, 0, 300, kCMTimeZero, Ratio{1, 1}}}, error);
    XCTAssertTrue(built.has_value(), @"%s", error.c_str());
    if (!built) {
        return;
    }
    const auto lookaheadDelay = std::chrono::milliseconds(2000); // outlasts the check below
    SeekRig::Options options;
    options.cacheBudgetBytes = budgetOf1080Frames(5);
    options.adjust = [&](playback::PlaybackConfig &config) {
        config.idleLookaheadDelay = lookaheadDelay;
        config.restDelay = lookaheadDelay; // a click's end too: the lookahead stays at the previous place
    };
    SeekRig rig(built->first, built->second, options);
    XCTAssertTrue(rig.ok(), @"%s", rig.error().c_str());
    if (!rig.ok()) {
        return;
    }
    for (int64_t frame : {150, 200, 250}) {
        XCTAssertTrue(clickAndSettle(rig, frame, lookaheadDelay), @"frame %lld", frame);
    }
    XCTAssertGreaterThan(rig.cache->stats().evictions, 0u, @"the cache is full");
    const AssetId asset = built->first.assets.front().id;
    XCTAssertFalse(rig.cache->contains(asset, CMTimeMake(10, 30)), @"frame 10 is decoded by the click");

    const auto clickedAt = rig.click(10, std::chrono::milliseconds(60));
    const SeekRig::Outcome outcome = rig.check(10, clickedAt, std::chrono::milliseconds(1800));
    XCTAssertTrue(outcome.shown, @"%s: %s", outcome.category.c_str(), outcome.details.c_str());
}

/// The same for a picture that is already decoded when the click comes (no request: the redraw looks it
/// up): it is pinned for the redraw, which may come late (a busy main queue or render thread) while the
/// cache fills up with other frames.
- (void)testAnAlreadyDecodedPictureSurvivesUntilTheRedraw {
    std::string error;
    auto built = projectOf("h264_1080p30.mp4", {{0, 0, 300, kCMTimeZero, Ratio{1, 1}}}, error);
    XCTAssertTrue(built.has_value(), @"%s", error.c_str());
    if (!built) {
        return;
    }
    const auto lookaheadDelay = std::chrono::milliseconds(2000); // outlasts the check below
    SeekRig::Options options;
    options.cacheBudgetBytes = budgetOf1080Frames(5);
    options.adjust = [&](playback::PlaybackConfig &config) {
        config.idleLookaheadDelay = lookaheadDelay;
        config.restDelay = lookaheadDelay; // a click's end too: the lookahead stays at the previous place
    };
    SeekRig rig(built->first, built->second, options);
    XCTAssertTrue(rig.ok(), @"%s", rig.error().c_str());
    if (!rig.ok()) {
        return;
    }
    XCTAssertTrue(clickAndSettle(rig, 250, lookaheadDelay));
    // Frame 20's picture in the cache, unpinned: behind the focus (250), so the first to go.
    const AssetId asset = built->first.assets.front().id;
    const CMTime picture = CMTimeMake(20, 30);
    std::promise<void> decoded;
    rig.pool->requestFrame(asset, picture, [&decoded](media::Result<media::ScrubFrame>) { decoded.set_value(); }, 99);
    XCTAssertEqual(decoded.get_future().wait_for(std::chrono::seconds(10)), std::future_status::ready);
    XCTAssertTrue(rig.cache->contains(asset, picture));
    // The request's pin goes with its result, just after the callback returns.
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (rig.cache->stats().pinnedCount > 1 && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    XCTAssertEqual(rig.cache->stats().pinnedCount, 1u, @"only the picture on screen (250) is pinned");

    rig.holdRedraws();
    const auto clickedAt = rig.click(20, std::chrono::milliseconds(30));
    // Other frames arrive before the redraw: enough to replace the whole cache.
    for (int i = 0; i < 6; ++i) {
        CVPixelBufferRef buffer = nullptr;
        NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080,
                                           kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           (__bridge CFDictionaryRef)attributes, &buffer),
                       kCVReturnSuccess);
        XCTAssertTrue(rig.cache->put(AssetId(9999), media::PixelBuffer::adopt(buffer), CMTimeMake(i, 30),
                                     CMTimeMake(1, 30), CMTimeMake(1, 30)));
    }
    rig.releaseRedraws();
    const SeekRig::Outcome outcome = rig.check(20, clickedAt, std::chrono::milliseconds(1800));
    XCTAssertTrue(outcome.shown, @"%s: %s", outcome.category.c_str(), outcome.details.c_str());
}

@end

/// The long and the machine-dependent paused-seek runs, opt-in (the StressTests scheme, which sets
/// FRAMEWRIGHT_STRESS=1; the other schemes skip this class by name, and without the variable it skips
/// itself): 200 random clicks in real time (about a minute), and the user's demo project in
/// ~/Movies/Framewright Demo (FRAMEWRIGHT_DEMO_PROJECT overrides; skipped where it is absent).
/// PausedSeekTests keeps a 20-click run of the generated case in the default run.
@interface PausedSeekSoakTests : XCTestCase
@end

@implementation PausedSeekSoakTests

/// The reported case on generated media, so it runs everywhere: 200 clicks over a project of clips of a
/// screen recording at the reported speeds, with a frame cache that holds about as many of its frames
/// as the default 512 MB holds of the reported 3832x2154 recordings (about 40). Before the paused
/// picture was pinned, a picture the scrub path decoded far from the pool's (previous) focus was
/// evicted as it was put and the monitor kept the previous picture.
- (void)testClicksOnAScreenRecordingShowTheirFrame {
    VE_REQUIRE_STRESS_TESTS();
    std::string error;
    auto built = screencastProject(error);
    XCTAssertTrue(built.has_value(), @"%s", error.c_str());
    if (!built) {
        return;
    }
    SeekRig::Options options;
    // 40 frames of 1280x720 4:2:0 (8 bits) with room for the IOSurface's row padding.
    options.cacheBudgetBytes = size_t(40) * 1280 * 720 * 3 / 2 + (size_t(2) << 20);
    SeekRig rig(built->first, built->second, options);
    XCTAssertTrue(rig.ok(), @"%s", rig.error().c_str());
    if (!rig.ok()) {
        return;
    }
    const SeekReport report = runClicks(rig, 200, 20260929, std::chrono::seconds(2));
    for (const std::string &miss : report.misses) {
        NSLog(@"PAUSED SEEK MISS %s", miss.c_str());
    }
    NSLog(@"PAUSED SEEKS (screen recording): %s", report.summary().c_str());
    XCTAssertEqual(report.missCount(), 0, @"%s", report.summary().c_str());
    XCTAssertGreaterThan(rig.cache->stats().evictions, 0u, @"the cache was full: the eviction order mattered");
}

/// The reported project itself (skipped where it is not present): 200 clicks, none may leave the
/// monitor on another picture for 2 s.
- (void)testClicksOnTheDemoProjectShowTheirFrame {
    VE_REQUIRE_STRESS_TESTS();
    const std::string path = demoProjectPath();
    std::ifstream file(path);
    if (!file) {
        XCTSkip(@"the demo project is not on this machine (%s)", path.c_str());
    }
    std::stringstream text;
    text << file.rdbuf();
    ProjectLoadResult loaded = parseProject(text.str());
    XCTAssertTrue(loaded.ok(), @"%s", loaded.error.c_str());
    if (!loaded.ok()) {
        return;
    }
    for (const MediaAsset &asset : loaded.project->assets) {
        const std::string media = playback::mediaPathForURL(asset.url);
        if (!std::ifstream(media)) {
            XCTSkip(@"the demo project's media is not on this machine (%s)", media.c_str());
        }
    }
    SeekRig rig(*loaded.project, loaded.project->activeSequenceId, SeekRig::Options{});
    XCTAssertTrue(rig.ok(), @"%s", rig.error().c_str());
    if (!rig.ok()) {
        return;
    }
    const SeekReport report = runClicks(rig, 200, 20260929, std::chrono::seconds(2));
    for (const std::string &miss : report.misses) {
        NSLog(@"PAUSED SEEK MISS %s", miss.c_str());
    }
    NSLog(@"PAUSED SEEKS (demo project): %s", report.summary().c_str());
    XCTAssertEqual(report.missCount(), 0, @"%s", report.summary().c_str());
}

@end
