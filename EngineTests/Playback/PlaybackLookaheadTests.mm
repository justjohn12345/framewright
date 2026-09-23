// Play-start latency and the lookahead a stopped transport keeps (open finding 3): while the
// playhead is still, the program's decode pool fills a short window from it and the audio
// sources are primed there, so play() finds its first frames and audio and the first clock-driven
// frame is presented within about one display frame.

#import <XCTest/XCTest.h>

#include "PlaybackTestSupport.h"

#include "../Media/BurnIn.h"
#include "../Media/FFmpegTestMedia.h"
#include "../Media/TestMedia.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <thread>

using namespace ve;
using namespace ve::playback;
using namespace ve::test;

namespace {

using SteadyClock = std::chrono::steady_clock;

double msSince(SteadyClock::time_point t0) {
    return std::chrono::duration<double, std::milli>(SteadyClock::now() - t0).count();
}

/// V1: h264 [0, 4 s) from source 0 and hevc [4 s, 9 s) from source 1 s; their audio on A1
/// (linked), no transitions, so every frame has exactly one picture.
struct Rig {
    AssetId h264, hevc;
    ClipId a, b, aa, ba;
};

Rig buildRig(PlaybackHarness &h) {
    Rig r;
    r.h264 = h.importAsset("h264_1080p30.mp4");
    r.hevc = h.importAsset("hevc_720p2997.mov");
    if (!h.ok()) {
        return r;
    }
    r.a = h.addClip(h.v1, r.h264, 0, 120, kCMTimeZero);
    r.b = h.addClip(h.v1, r.hevc, 120, 150, CMTimeMake(1, 1));
    r.aa = h.addClip(h.a1, r.h264, 0, 120, kCMTimeZero);
    r.ba = h.addClip(h.a1, r.hevc, 120, 150, CMTimeMake(1, 1));
    h.link(r.a, r.aa);
    h.link(r.b, r.ba);
    return r;
}

/// play(), then calls the frame source every half millisecond (a display link far faster than
/// any screen, so the measurement is the controller's, not the vsync's) until it presents a new
/// clock-driven frame. The paused frame is already on screen when play() is called, so the first
/// new frame is a later one; the start latency is when that frame was presented minus the
/// playing time it stands for: (T - t0) - (index - start) * frame duration. That is how late the
/// picture runs against a start at the instant of play(). Returns (latency ms, raw ms to the
/// first new frame, its index); -1 when nothing played within 5 s.
struct PlayStart {
    double latencyMs = -1;
    double rawMs = -1;
    int64_t frame = -1;
};

PlayStart measurePlayStart(PlaybackHarness &h, int64_t startFrame) {
    const auto t0 = SteadyClock::now();
    h.controller->play();
    while (msSince(t0) < 5000) {
        const PlaybackHarness::Sample s = h.present();
        if (s.changed && s.presented.clockDriven) {
            PlayStart result;
            result.rawMs = msSince(t0);
            result.frame = s.presented.frameIndex;
            result.latencyMs = result.rawMs - double(result.frame - startFrame) * 1000.0 / 30.0;
            return result;
        }
        std::this_thread::sleep_for(std::chrono::microseconds(500));
    }
    return {};
}

/// The pool stream of `clip` (lane = clip id), if any.
std::optional<media::DecodePool::StreamStats> streamOf(PlaybackHarness &h, ClipId clip) {
    for (const auto &stream : h.pool->stats().streams) {
        if (stream.lane == clip.value()) {
            return stream;
        }
    }
    return std::nullopt;
}

double secondsOf(CMTime t) {
    return CMTimeGetSeconds(t);
}

} // namespace

@interface PlaybackLookaheadTests : XCTestCase
@end

@implementation PlaybackLookaheadTests

/// Press-to-first-presented-frame: with the playhead still long enough for the lookahead and the
/// audio to be ready ("cached"), and right after a jump into media nothing has decoded ("cold").
- (void)testPlayStartsWithinAFrameFromAStillPlayhead {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
    buildRig(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return h.output->isRunning(); }), @"the output warms up");

    // Cached: the paused picture is up and the playhead has been still for a while.
    std::vector<double> cached;
    for (int64_t frame : {45, 75, 160, 200}) {
        h.controller->seek(frames30(frame));
        h.presentExact();
        std::this_thread::sleep_for(std::chrono::milliseconds(400));
        const PlayStart start = measurePlayStart(h, frame);
        XCTAssertGreaterThanOrEqual(start.rawMs, 0.0, @"playback started from frame %lld", frame);
        XCTAssertTrue(start.frame == frame + 1 || start.frame == frame + 2,
                      @"the picture moves on from the paused frame (%lld after %lld)", start.frame, frame);
        cached.push_back(start.latencyMs);
        h.controller->pause();
    }

    // Cold: frames purged, then a jump to media nothing decoded and play at once.
    h.cache->handleMemoryPressure(media::MemoryPressure::Critical);
    h.controller->seek(frames30(230));
    const PlayStart cold = measurePlayStart(h, 230);
    XCTAssertGreaterThanOrEqual(cold.rawMs, 0.0);
    h.controller->pause();

    std::sort(cached.begin(), cached.end());
    NSLog(@"PLAY START LATENCY (controller, null output): cached %.1f / %.1f / %.1f / %.1f ms, cold %.1f ms "
          @"(first new frame %lld after %.1f ms)",
          cached[0], cached[1], cached[2], cached[3], cold.latencyMs, cold.frame, cold.rawMs);
    XCTAssertLessThan(cached.back(), 50.0, @"cached media starts within the 50 ms target");
}

/// A still playhead gets a short forward lookahead (about 0.5 s of video, within the pool's
/// budget share) and primed audio (the sources decode about a second or more ahead).
- (void)testAStillPlayheadGetsAShortLookaheadAndPrimedAudio {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
    const Rig r = buildRig(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.controller->seek(frames30(45));
    h.presentExact();
    const CMTime at = frames30(45);
    XCTAssertTrue(PlaybackHarness::waitUntil([&] {
        const auto stream = streamOf(h, r.a);
        return stream && CMTimeCompare(stream->target, at) == 0;
    }),
                  @"the pool follows the still playhead");
    XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)));
    const auto stream = streamOf(h, r.a);
    XCTAssertTrue(stream.has_value());
    if (stream) {
        const double window = secondsOf(stream->window);
        XCTAssertGreaterThan(window, 0.4);
        XCTAssertLessThanOrEqual(window, 0.5 + 1e-6, @"the stopped window is short");
        XCTAssertGreaterThanOrEqual(secondsOf(stream->rangeEnd), 1.5 + window - 1.0 / 30 - 1e-6,
                                    @"decoded through the window");
    }
    for (int64_t f = 45; f < 45 + 14; ++f) {
        XCTAssertTrue(h.cache->contains(r.h264, f), @"frame %lld is cached", f);
    }
    XCTAssertEqual(h.pool->stats().streams.size(), 1u, @"only the clip the window reaches");
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return h.controller->mixer().isPrimed(at); }), @"audio primed");
    XCTAssertTrue(PlaybackHarness::waitUntil([&] {
        for (const auto &source : h.controller->mixer().stats().sources) {
            if (source.asset == r.h264 && source.bufferedFrames >= 48000) {
                return true;
            }
        }
        return false;
    }),
                  @"the source under the playhead holds at least a second of audio");

    // A window near the next clip reaches it.
    h.controller->seek(frames30(110));
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return streamOf(h, r.b).has_value(); }),
                  @"the clip starting within the window gets a stream too");

    // Within the budget share: a small cache shortens the window instead of evicting the playhead.
    h.cache->setBudget(24u << 20);
    h.controller->seek(frames30(20));
    h.presentExact();
    XCTAssertTrue(PlaybackHarness::waitUntil([&] {
        const auto s = streamOf(h, r.a);
        return s && CMTimeCompare(s->target, frames30(20)) == 0;
    }));
    XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)));
    if (const auto small = streamOf(h, r.a); small && small->frameBytes > 0) {
        const double windowFrames = secondsOf(small->window) * 30;
        XCTAssertLessThanOrEqual(windowFrames * double(small->frameBytes), 0.75 * double(24u << 20) + small->frameBytes,
                                 @"the window fits the pool's share of the budget");
        XCTAssertLessThan(secondsOf(small->window), 0.5);
    }
    XCTAssertTrue(h.cache->contains(r.h264, 20), @"the frame under the playhead stays cached");
}

/// A playhead that keeps moving (stepping faster than the delay) never retargets the pool; once
/// it is still, the pool follows once.
- (void)testAMovingPlayheadLeavesThePoolAlone {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
    const Rig r = buildRig(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.controller->seek(frames30(30));
    XCTAssertTrue(PlaybackHarness::waitUntil([&] {
        const auto s = streamOf(h, r.a);
        return s && CMTimeCompare(s->target, frames30(30)) == 0;
    }));
    XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)));
    const uint64_t seeksBefore = streamOf(h, r.a)->seeks;
    for (int i = 1; i <= 15; ++i) {
        h.controller->stepFrames(i % 2 == 0 ? 1 : 2); // arrow-key repeat, faster than the delay
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        const auto s = streamOf(h, r.a);
        XCTAssertTrue(s && CMTimeCompare(s->target, frames30(30)) == 0, @"step %d: the pool is not retargeted", i);
    }
    const auto moving = streamOf(h, r.a);
    XCTAssertEqual(moving ? moving->seeks : 0, seeksBefore, @"no seeks while the playhead moves");
    const CMTime still = h.controller->currentTime();
    XCTAssertEqual(frameIndexAt(still, CMTimeMake(1, 30), SnapMode::Floor), 30 + 7 * 1 + 8 * 2);
    XCTAssertTrue(PlaybackHarness::waitUntil([&] {
        const auto s = streamOf(h, r.a);
        return s && CMTimeCompare(s->target, still) == 0;
    }),
                  @"still again: the pool follows");
    const PlaybackHarness::Sample sample = h.presentExact();
    XCTAssertEqual(sample.presented.frameIndex, 53);
    XCTAssertEqual(sample.burnIns.front().value_or(-1), 53);
}

/// setIdleLookahead(false) (an export running) clears the pool's targets while stopped; the
/// paused picture still arrives through the scrub path; enabling it again restores the window.
- (void)testTheStoppedLookaheadCanBeTurnedOff {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
    const Rig r = buildRig(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return streamOf(h, r.a).has_value(); }));
    h.controller->setIdleLookahead(false);
    XCTAssertFalse(h.controller->idleLookahead());
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return h.pool->stats().streams.empty(); }),
                  @"the targets are cleared at once");
    h.controller->seek(frames30(140));
    const PlaybackHarness::Sample sample = h.presentExact();
    XCTAssertEqual(sample.presented.frameIndex, 140);
    XCTAssertEqual(sample.burnIns.front().value_or(-1), h.expectedSlot(r.b, 140), @"the paused picture still shows");
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    XCTAssertTrue(h.pool->stats().streams.empty(), @"no lookahead while turned off");
    // Playing still works (the pre-roll targets the pool), and pausing clears them again.
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    XCTAssertFalse(h.pool->stats().streams.empty());
    h.controller->pause();
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return h.pool->stats().streams.empty(); }));
    h.controller->setIdleLookahead(true);
    // B plays hevc (29.97 fps) from 1 s at 4 s: its target is the start of the source frame slot
    // under the paused frame.
    const double source = secondsOf(h.controller->currentTime()) - 4.0 + 1.0;
    XCTAssertTrue(PlaybackHarness::waitUntil([&] {
        const auto s = streamOf(h, r.b);
        return s && secondsOf(s->target) <= source + 1e-6 && secondsOf(s->target) > source - 1001.0 / 30000;
    }),
                  @"turned on again: the window follows the paused frame (source %.3f s)", source);
}

/// A second frame source (a mirror, like a second display) shows the same frames without
/// adding to the counters, and nothing is decoded twice.
- (void)testAMirrorSourceShowsTheSameFramesWithoutCountingThem {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
    buildRig(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.controller->seek(frames30(40));
    h.presentExact();
    auto created = render::TextureCache::create(h.device());
    XCTAssertTrue(created.ok());
    if (!created.ok()) {
        return;
    }
    render::TextureCache mirrorTextures = std::move(created).value();
    render::PreviewFrameSource mirror = h.controller->frameSource(PlaybackController::SourceRole::Mirror);
    render::PreviewFrame mirrorFrame;
    render::PreviewFrameRequest request;
    request.textureCache = &mirrorTextures;
    const playback::PlaybackStats before = h.controller->stats();
    const PresentedFrame presentedBefore = h.controller->lastPresented();
    XCTAssertTrue(mirror(request, mirrorFrame), @"the mirror presents its first frame");
    XCTAssertEqual(mirrorFrame.graph.layers.size(), 1u);
    XCTAssertEqual(mirrorFrame.textures.size(), 1u);
    XCTAssertTrue(mirrorFrame.textures.front());
    XCTAssertEqual(readBurnIn(mirrorFrame.textures.front().pixelBuffer().get()).value_or(-1), 40);
    XCTAssertFalse(mirror(request, mirrorFrame), @"unchanged on the next call");
    const playback::PlaybackStats after = h.controller->stats();
    XCTAssertEqual(after.presentedFrames, before.presentedFrames, @"the mirror does not count presentations");
    XCTAssertEqual(after.cacheHits, before.cacheHits);
    XCTAssertEqual(h.controller->lastPresented().serial, presentedBefore.serial, @"nor replace lastPresented");
    // The same frame: one decode (the cache entry both map).
    XCTAssertEqual(mirrorFrame.textures.front().pixelBuffer().get(), h.frame().textures.front().pixelBuffer().get());
    // Stepping: both follow.
    h.controller->stepFrames(3);
    const PlaybackHarness::Sample primary = h.presentExact();
    bool mirrored = false;
    for (int i = 0; i < 2000 && !mirrored; ++i) {
        mirror(request, mirrorFrame);
        mirrored = !mirrorFrame.textures.empty() && mirrorFrame.textures.front() &&
                   readBurnIn(mirrorFrame.textures.front().pixelBuffer().get()).value_or(-1) == 43;
        if (!mirrored) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }
    XCTAssertTrue(mirrored);
    XCTAssertEqual(primary.burnIns.front().value_or(-1), 43);
}

/// The iPhone case of open finding 3: a variable-frame-rate clip. The monitor looks a layer's
/// picture up by its nominal frame slot, whose start can lie in the frame before the one under
/// the layer's source time (a short frame after a long one); the pool and the paused picture's
/// request must decode that frame, or play() waits for it until the pre-roll timeout (a second).
- (void)testPlayStartsPromptlyOnAVariableFrameRateSource {
    std::string error;
    const std::string path = derivedMediaPath("vfr_h264_blockdur.mkv", error);
    XCTAssertFalse(path.empty(), @"%s", error.c_str());
    if (path.empty()) {
        return;
    }
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
    const AssetId vfr = h.importAssetAtPath(path);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.addClip(h.v1, vfr, 0, 180, kCMTimeZero);
    h.load();
    const MediaAsset &asset = *h.project.findAsset(vfr);
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return h.output->isRunning(); }));
    // Sequence frames whose slot starts in an earlier source frame than their source time (clear of
    // the container's millisecond rounding at frame boundaries).
    auto frameAt = [](CMTime t, int64_t offsetMs) { return vfrFrameAt(t + CMTimeMake(offsetMs, 1000)); };
    std::vector<int64_t> offGrid;
    for (int64_t frame = 10; frame < 170 && offGrid.size() < 10; ++frame) {
        const CMTime source = frames30(frame);
        const CMTime slotStart = timeForFrame(media::FrameCache::frameIndex(source, asset.frameDuration),
                                              asset.frameDuration);
        const int slotFrame = frameAt(slotStart, 0);
        if (slotFrame == frameAt(slotStart, -2) && slotFrame == frameAt(slotStart, 2) &&
            frameAt(source, -2) == frameAt(source, 2) && slotFrame != frameAt(source, 0)) {
            offGrid.push_back(frame);
        }
    }
    XCTAssertGreaterThanOrEqual(offGrid.size(), 3u, @"the source has slots starting in the previous frame");
    std::vector<double> latencies;
    for (int64_t frame : offGrid) {
        const CMTime source = frames30(frame);
        const CMTime slotStart = timeForFrame(media::FrameCache::frameIndex(source, asset.frameDuration),
                                              asset.frameDuration);
        h.controller->seek(source);
        const PlaybackHarness::Sample paused = h.presentExact();
        XCTAssertEqual(paused.presented.frameIndex, frame);
        XCTAssertEqual(paused.burnIns.front().value_or(-1), vfrFrameAt(slotStart), @"frame %lld shows its slot's picture",
                       frame);
        std::this_thread::sleep_for(std::chrono::milliseconds(300));
        const PlayStart start = measurePlayStart(h, frame);
        XCTAssertGreaterThanOrEqual(start.rawMs, 0.0);
        latencies.push_back(start.latencyMs);
        h.controller->pause();
    }
    if (latencies.empty()) {
        return;
    }
    std::sort(latencies.begin(), latencies.end());
    NSLog(@"PLAY START LATENCY (controller, VFR source): median %.1f ms, worst %.1f ms over %zu off-grid starts",
          latencies[latencies.size() / 2], latencies.back(), latencies.size());
    XCTAssertLessThan(latencies.back(), 50.0, @"no start waits for the pre-roll timeout");
}

@end
