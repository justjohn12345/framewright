// Play start where the playhead was put down (a scrub's end, a ruler click, a seek): the audio sources get ready
// there while stopped, even after earlier places, so the pre-roll finds them primed; the lookahead follows at once,
// continuing from the decoder that decoded the picture shown (the hand-off: the GOP is decoded once), so Space needs
// no decode from a keyframe; a scrub suspends the lookahead, so a burst of scrubs leaves one preparation, for the
// last place. PlayStartMeasurementTests (the Measurements scheme) times it.

#import <XCTest/XCTest.h>

#include "../Audio/AudioTestSupport.h"
#include "PlaybackTestSupport.h"

#include <algorithm>
#include <chrono>
#include <optional>
#include <thread>

using namespace ve;
using namespace ve::playback;
using namespace ve::test;

namespace {

int64_t sampleAt(CMTime t) {
    return static_cast<int64_t>(std::llround(CMTimeGetSeconds(t) * 48000.0));
}

/// The long-GOP clip (a keyframe every 150 frames: 0 and 5 s) on V1, the whole of it from frame 0. The delays after
/// a moving playhead are long, so whatever follows a scrub or a seek at once is the rest rule's doing.
struct LongGop {
    PlaybackHarness h{PlaybackHarness::Mode::Realtime, 1.0, [](PlaybackConfig &config) {
                          config.idleLookaheadDelay = std::chrono::seconds(10);
                          config.audioWarmDelay = std::chrono::seconds(10);
                      }};
    AssetId asset;
    ClipId clip;

    LongGop() {
        asset = h.importAsset("gop5s_h264_1080p30.mp4");
        if (h.ok()) {
            clip = h.addClip(h.v1, asset, 0, 300, kCMTimeZero);
            h.load();
        }
    }

    std::optional<media::DecodePool::StreamStats> stream() const {
        for (const auto &s : h.pool->stats().streams) {
            if (s.lane == clip.value()) {
                return s;
            }
        }
        return std::nullopt;
    }

    /// The clip's stream targets sequence frame `frame` (the picture there) and has covered its window.
    bool settledAt(int64_t frame) {
        const bool targeted = PlaybackHarness::waitUntil([&] {
            const auto s = stream();
            return s && CMTimeCompare(s->target, frames30(frame)) == 0;
        });
        return targeted && h.pool->waitUntilIdle(std::chrono::seconds(10));
    }

    /// A scrub from `from` to `frame` in `steps` moves `stepMs` apart, released there.
    void scrub(int64_t from, int64_t frame, int steps, int stepMs) {
        for (int k = 1; k <= steps; ++k) {
            h.controller->scrubTo(frames30(from + (frame - from) * k / steps));
            std::this_thread::sleep_for(std::chrono::milliseconds(stepMs));
        }
        h.controller->endScrub();
    }
};

} // namespace

@interface PlayStartAfterRestTests : XCTestCase
@end

@implementation PlayStartAfterRestTests

/// A source's ring keeps the audio it decoded for the place it played from until its consumer (the render thread)
/// skips it, and a stopped mixer reads nothing: after playing, the first place the playhead was put down filled what
/// the ring had left, and the second found it full, so its audio was never decoded while stopped and the next play
/// waited for the pre-roll timeout (a second) before starting without it. The stopped render callbacks now take up
/// the newest place, so each place gets ready while stopped.
- (void)testTheAudioGetsReadyAtEveryPlaceThePlayheadIsPutDownWhileStopped {
    ToneRig rig(1);
    rig.load();
    rig.startPump();
    XCTAssertTrue(rig.waitForState(PlaybackState::Stopped));
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return rig.out->isRunning(); }), @"the output runs");

    // Play long enough for the source to have decoded its whole lookahead ahead of the playhead, then pause.
    rig.controller->play();
    XCTAssertTrue(rig.waitForState(PlaybackState::Playing));
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return CMTimeGetSeconds(rig.controller->currentTime()) >= 1.5; }));
    rig.controller->pause();
    XCTAssertTrue(rig.waitForState(PlaybackState::Stopped));

    // Put down at one place, then at others, each time waiting while stopped.
    for (CMTime at : {CMTimeMake(4, 1), CMTimeMake(7, 1), CMTimeMake(2, 1), CMTimeMake(8, 1)}) {
        rig.controller->seek(at);
        XCTAssertTrue(PlaybackHarness::waitUntil([&] { return rig.controller->mixer().isPrimed(at); },
                                                 std::chrono::seconds(5)),
                      @"the audio at %.0f s is decoded while stopped (%s)", CMTimeGetSeconds(at),
                      [&] {
                          const auto stats = rig.controller->mixer().stats();
                          return stats.sources.empty() ? std::string("no source")
                                                       : "buffered " + std::to_string(stats.sources[0].bufferedFrames);
                      }()
                          .c_str());
    }
    // Space then starts on the primed audio: the clock runs from the playhead at once and nothing underruns.
    const uint64_t underruns = rig.controller->mixer().stats().underruns;
    rig.controller->play();
    XCTAssertTrue(rig.waitForState(PlaybackState::Playing, std::chrono::milliseconds(500)),
                  @"the pre-roll does not wait for its timeout");
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return rig.controller->mixer().stats().position > sampleAt(CMTimeMake(81, 10)); }),
                  @"the audio plays from 8 s");
    XCTAssertEqual(rig.controller->mixer().stats().underruns, underruns, @"no underrun at the start");
    rig.controller->pause();
}

/// Once a scrub is released the lookahead follows at once (not after the moving playhead's delay, ten seconds
/// here), from the decoder that decoded the picture shown: it takes that decoder over instead of seeking to the
/// keyframe and decoding the GOP a second time, and the frames after the picture are ready before Space.
- (void)testTheLookaheadFollowsAScrubAtOnceFromThePicturesDecoder {
    LongGop rig;
    if (!rig.h.ok()) {
        XCTFail(@"%s", rig.h.error().c_str());
        return;
    }
    rig.h.controller->seek(frames30(20)); // an exact seek: put down, the lookahead follows at once
    rig.h.presentExact();
    XCTAssertTrue(rig.settledAt(20), @"the lookahead follows a seek at once");
    const auto before = *rig.stream();

    rig.scrub(20, 135, 10, 15);
    XCTAssertTrue(rig.settledAt(135), @"the lookahead follows the scrub's end at once");
    const auto after = *rig.stream();
    XCTAssertEqual(after.seeks, before.seeks, @"no seek: the GOP up to frame 135 was decoded once");
    XCTAssertEqual(after.handoffs, before.handoffs + 1, @"the stream took the picture's decoder over");
    for (int64_t frame = 135; frame < 150; ++frame) {
        XCTAssertTrue(rig.h.cache->contains(rig.asset, frame), @"frame %lld is ready before Space", frame);
    }
    const PlaybackHarness::Sample shown = rig.h.presentExact();
    XCTAssertEqual(shown.burnIns.front().value_or(-1), 135);
}

/// Space right after a scrub's release: the pre-roll's lookahead takes the picture's decoder over (or waits for it)
/// instead of seeking, so no GOP is decoded on the press path, and every frame played is the right one.
- (void)testSpaceRightAfterAScrubSeeksNothing {
    LongGop rig;
    if (!rig.h.ok()) {
        XCTFail(@"%s", rig.h.error().c_str());
        return;
    }
    rig.h.controller->seek(frames30(20));
    rig.h.presentExact();
    XCTAssertTrue(rig.settledAt(20));
    const auto before = *rig.stream();
    rig.scrub(20, 230, 8, 15);
    rig.h.controller->play(); // at once: the picture may still be decoding
    XCTAssertTrue(rig.h.waitForState(PlaybackState::Playing));
    int checked = 0;
    const auto t0 = std::chrono::steady_clock::now();
    while (std::chrono::steady_clock::now() - t0 < std::chrono::milliseconds(400)) {
        const PlaybackHarness::Sample s = rig.h.present();
        if (s.changed && s.presented.clockDriven && !s.presented.layers.empty() && s.presented.layers[0].exact) {
            XCTAssertEqual(s.burnIns.front().value_or(-1), s.presented.frameIndex, @"the frame played is its own");
            ++checked;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    rig.h.controller->pause();
    XCTAssertGreaterThan(checked, 3);
    const auto after = *rig.stream();
    XCTAssertEqual(after.seeks, before.seeks, @"no seek on the press path");
    XCTAssertGreaterThanOrEqual(after.handoffs, before.handoffs + 1);
}

/// Two layers: Space right after a scrub released inside a cross dissolve of two long-GOP clips. The scrub thread
/// decodes the two pictures one after the other; the second layer's stream does not wait behind the first's request
/// (it decodes its picture itself, DecodePoolTests covers the order), and every frame played shows both layers' own
/// pictures, no stream seeking more than once. Review fix round, finding 2.
- (void)testSpaceRightAfterAScrubIntoADissolvePlaysBothLayers {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0, [](PlaybackConfig &config) {
        config.idleLookaheadDelay = std::chrono::seconds(10);
        config.audioWarmDelay = std::chrono::seconds(10);
    });
    const AssetId first = h.importAsset("gop5s_h264_1080p30.mp4");
    const AssetId second = h.importAsset("gop5s_h264_1080p30.mp4");
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    const ClipId a = h.addClip(h.v1, first, 0, 150, kCMTimeZero);
    const ClipId b = h.addClip(h.v1, second, 150, 140, CMTimeMake(2, 1));
    h.addTransition(h.v1, a, b, 60);
    XCTAssertFalse(h.problem().has_value());
    h.load();
    h.controller->seek(frames30(20));
    h.presentExact();
    XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)));
    auto streamOf = [&](ClipId clip) -> std::optional<media::DecodePool::StreamStats> {
        for (const auto &s : h.pool->stats().streams) {
            if (s.lane == clip.value()) {
                return s;
            }
        }
        return std::nullopt;
    };
    const uint64_t seeksA = streamOf(a) ? streamOf(a)->seeks : 0;
    for (int k = 1; k <= 8; ++k) {
        h.controller->scrubTo(frames30(20 + (160 - 20) * k / 8));
        std::this_thread::sleep_for(std::chrono::milliseconds(15));
    }
    h.controller->endScrub();
    h.controller->play();
    XCTAssertTrue(h.waitForState(PlaybackState::Playing));
    int checked = 0;
    const auto t0 = std::chrono::steady_clock::now();
    while (std::chrono::steady_clock::now() - t0 < std::chrono::milliseconds(400)) {
        const PlaybackHarness::Sample s = h.present();
        const bool exact = std::all_of(s.presented.layers.begin(), s.presented.layers.end(),
                                       [](const PresentedLayer &l) { return l.exact; });
        if (s.changed && s.presented.clockDriven && s.presented.layers.size() == 2 && exact) {
            for (size_t i = 0; i < 2; ++i) {
                XCTAssertEqual(int64_t(s.burnIns[i].value_or(-1)), h.expectedSlot(s.clips[i], s.presented.frameIndex),
                               @"frame %lld layer %zu", s.presented.frameIndex, i);
            }
            ++checked;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    h.controller->pause();
    XCTAssertGreaterThan(checked, 3, @"frames of the dissolve played");
    const auto afterA = streamOf(a);
    const auto afterB = streamOf(b);
    XCTAssertTrue(afterA && afterB);
    if (afterA && afterB) {
        XCTAssertLessThanOrEqual(afterA->seeks - seeksA, 1u, @"layer A's GOP decoded at most once by the lookahead");
        XCTAssertLessThanOrEqual(afterB->seeks, 1u, @"layer B's too");
        XCTAssertGreaterThanOrEqual(afterA->handoffs + afterB->handoffs, 1u, @"at least one layer took a decoder over");
    }
}

/// A burst of ruler clicks: each click's scrub suspends the lookahead (it never decodes while the scrub path does),
/// every release replaces the previous preparation, and what is left is one stream at the last place, continued
/// from that click's picture without a seek; every earlier picture request ended (none is left queued).
- (void)testABurstOfClicksLeavesOnePreparationForTheLastPlace {
    LongGop rig;
    if (!rig.h.ok()) {
        XCTFail(@"%s", rig.h.error().c_str());
        return;
    }
    rig.h.controller->seek(frames30(20));
    rig.h.presentExact();
    XCTAssertTrue(rig.settledAt(20));
    const auto before = *rig.stream();
    for (int64_t frame : {40, 85, 130, 175, 220, 265}) {
        rig.h.controller->scrubTo(frames30(frame));
        XCTAssertTrue(rig.h.pool->stats().suspended, @"the lookahead yields to the click at %lld", frame);
        std::this_thread::sleep_for(std::chrono::milliseconds(15));
        rig.h.controller->endScrub();
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    XCTAssertTrue(rig.settledAt(265));
    const auto stats = rig.h.pool->stats();
    XCTAssertEqual(stats.streams.size(), 1u, @"one preparation");
    XCTAssertFalse(stats.suspended);
    XCTAssertEqual(stats.scrubRequests, stats.scrubServiced + stats.scrubCancelled + stats.scrubFailed,
                   @"no picture request is left");
    const auto after = *rig.stream();
    XCTAssertEqual(after.seeks, before.seeks, @"no preparation sought: each took its click's decoder or was replaced");
    XCTAssertGreaterThanOrEqual(after.handoffs, before.handoffs + 1);
    for (int64_t frame = 265; frame < 280; ++frame) {
        XCTAssertTrue(rig.h.cache->contains(rig.asset, frame), @"frame %lld is ready", frame);
    }
}

@end
