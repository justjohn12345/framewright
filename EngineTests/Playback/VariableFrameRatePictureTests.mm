// Pictures of variable-frame-rate sources (UX round review, finding 1 and test gap 1). A layer's
// picture is the source frame whose display interval contains the layer's exact source time
// (playback::pictureTimeFor): the frame a decoder's seek() to that time returns. Looking pictures
// up by nominal frame slot instead showed the frame under the slot's start, which on a
// variable-frame-rate source can be the frame before (a short frame after a long one): one frame
// too long, then a late skip. Checked paused and playing, on both backends: vfr_h264.mp4 (the
// Apple backend, exact 1/600 s timestamps) and its Matroska remux vfr_h264_blockdur.mkv (FFmpeg,
// millisecond timestamps, so a source time within a millisecond of a frame boundary may show
// either neighbour).

#import <XCTest/XCTest.h>

#include "PlaybackTestSupport.h"

#include "../Media/BurnIn.h"
#include "../Media/FFmpegTestMedia.h"
#include "../Media/TestMedia.h"

#include <chrono>
#include <string>
#include <thread>
#include <vector>

using namespace ve;
using namespace ve::playback;
using namespace ve::test;

namespace {

struct Source {
    const char *name;
    std::string path;
    const char *backend; ///< What the router must choose for the video track.
    int64_t toleranceMs; ///< Timestamp precision of the container (0: exact).
};

/// The frames a picture for source time `t` may show: the frame containing t, or (within the
/// container's timestamp precision of a frame boundary) its neighbour on the other side.
std::pair<int, int> acceptableFrames(CMTime t, int64_t toleranceMs) {
    if (toleranceMs == 0) {
        return {vfrFrameAt(t), vfrFrameAt(t)};
    }
    return {vfrFrameAt(t - CMTimeMake(toleranceMs, 1000)), vfrFrameAt(t + CMTimeMake(toleranceMs, 1000))};
}

bool accepts(std::pair<int, int> range, int shown) {
    return shown == range.first || shown == range.second;
}

/// Clip layout of every test: V1 has the source from 67/600 s for sequence frames [0, 60), then
/// from 1407/600 s (2.345 s) for [60, 120). Both in points are off the source's nominal frame grid
/// (10/600 s), so many sequence frames have a source time just after a frame boundary that their
/// nominal slot starts before (from 0 every 30 fps source time would be a slot start).
constexpr int64_t kFirstLength = 60;
constexpr int64_t kSequenceFrames = 120;
const CMTime kFirstIn = CMTimeMake(67, 600);
const CMTime kSecondIn = CMTimeMake(1407, 600);

CMTime sourceTimeAt(int64_t frame) {
    return frame < kFirstLength ? kFirstIn + frames30(frame) : kSecondIn + frames30(frame - kFirstLength);
}

} // namespace

@interface VariableFrameRatePictureTests : XCTestCase
@end

@implementation VariableFrameRatePictureTests

- (std::vector<Source>)sources {
    std::vector<Source> sources;
    std::string error;
    const std::string mp4 = testMediaPath("vfr_h264.mp4", error);
    XCTAssertFalse(mp4.empty(), @"%s", error.c_str());
    if (!mp4.empty()) {
        sources.push_back({"vfr_h264.mp4", mp4, "apple", 0});
    }
    const std::string mkv = derivedMediaPath("vfr_h264_blockdur.mkv", error);
    XCTAssertFalse(mkv.empty(), @"%s", error.c_str());
    if (!mkv.empty()) {
        sources.push_back({"vfr_h264_blockdur.mkv", mkv, "ffmpeg", 1});
    }
    return sources;
}

/// Paused: every sequence frame shows the frame containing its exact source time, on both
/// backends, including the frames whose nominal slot starts in the previous source frame.
- (void)testThePausedPictureIsTheFrameContainingTheExactSourceTime {
    for (const Source &source : [self sources]) {
        PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
        auto routed = h.router->probe(source.path);
        XCTAssertTrue(routed.ok(), @"%s", source.name);
        if (!routed.ok()) {
            continue;
        }
        const media::TrackRoute *route = routed->firstRoute(media::TrackKind::Video);
        XCTAssertTrue(route != nullptr && route->backend == source.backend, @"%s decodes through %s", source.name,
                      source.backend);
        const AssetId vfr = h.importAssetAtPath(source.path);
        XCTAssertTrue(h.ok(), @"%s: %s", source.name, h.error().c_str());
        if (!h.ok()) {
            continue;
        }
        const MediaAsset &asset = *h.project.findAsset(vfr);
        XCTAssertTrue(asset.isVFR, @"%s is flagged VFR", source.name);
        h.addClip(h.v1, vfr, 0, kFirstLength, kFirstIn);
        h.addClip(h.v1, vfr, kFirstLength, kSequenceFrames - kFirstLength, kSecondIn);
        XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
        h.load();

        int checked = 0;
        int slotBiased = 0; // frames where the nominal slot's start lies in an earlier source frame
        for (int64_t frame = 0; frame < kSequenceFrames; ++frame) {
            const CMTime t = sourceTimeAt(frame);
            h.controller->seek(frames30(frame));
            const PlaybackHarness::Sample s = h.presentExact();
            XCTAssertEqual(s.presented.frameIndex, frame, @"%s", source.name);
            XCTAssertEqual(s.presented.layers.size(), 1u);
            XCTAssertEqual(s.burnIns.size(), 1u);
            if (s.presented.layers.size() != 1 || s.burnIns.size() != 1) {
                continue;
            }
            XCTAssertTrue(s.presented.layers[0].exact, @"%s frame %lld has its picture", source.name, frame);
            const int shown = s.burnIns[0].value_or(-1);
            const auto wanted = acceptableFrames(t, source.toleranceMs);
            XCTAssertTrue(accepts(wanted, shown),
                          @"%s frame %lld (source %.4f s): shows %d, the frame containing it is %d", source.name,
                          frame, CMTimeGetSeconds(t), shown, wanted.first);
            ++checked;
            const CMTime slotStart = timeForFrame(media::FrameCache::frameIndex(t, asset.frameDuration),
                                                  asset.frameDuration);
            const auto underSlot = acceptableFrames(slotStart, source.toleranceMs);
            if (wanted.first == wanted.second && underSlot.first == underSlot.second &&
                underSlot.first != wanted.first) {
                ++slotBiased;
                XCTAssertNotEqual(shown, underSlot.first, @"%s frame %lld: not the frame under the slot's start",
                                  source.name, frame);
            }
        }
        NSLog(@"VFR PICTURE (%s, %s): %d paused frames checked, %d where the slot's start is an earlier frame",
              source.name, source.backend, checked, slotBiased);
        XCTAssertEqual(checked, int(kSequenceFrames));
        XCTAssertGreaterThanOrEqual(slotBiased, 10, @"%s: the sequence exercises the slot bias", source.name);
    }
}

/// Playing: every clock-driven frame presented with its picture shows the frame containing the
/// exact source time of the presented sequence frame, on both backends.
- (void)testPlaybackShowsTheFramesContainingTheExactSourceTime {
    for (const Source &source : [self sources]) {
        PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
        const AssetId vfr = h.importAssetAtPath(source.path);
        XCTAssertTrue(h.ok(), @"%s: %s", source.name, h.error().c_str());
        if (!h.ok()) {
            continue;
        }
        h.addClip(h.v1, vfr, 0, kFirstLength, kFirstIn);
        h.addClip(h.v1, vfr, kFirstLength, kSequenceFrames - kFirstLength, kSecondIn);
        h.load();
        XCTAssertTrue(PlaybackHarness::waitUntil([&] { return h.output->isRunning(); }));
        h.controller->seek(kCMTimeZero);
        h.presentExact();
        std::this_thread::sleep_for(std::chrono::milliseconds(200)); // the stopped lookahead
        XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0, @"%s plays", source.name);
        int checked = 0;
        std::vector<std::string> failures;
        const auto start = std::chrono::steady_clock::now();
        while (std::chrono::steady_clock::now() - start < std::chrono::milliseconds(3500) &&
               h.controller->state() != PlaybackState::Stopped) {
            const PlaybackHarness::Sample s = h.present();
            if (s.changed && s.presented.clockDriven && s.presented.layers.size() == 1 && s.burnIns.size() == 1 &&
                s.presented.layers[0].exact) {
                const int64_t frame = s.presented.frameIndex;
                const auto wanted = acceptableFrames(sourceTimeAt(frame), source.toleranceMs);
                const int shown = s.burnIns[0].value_or(-1);
                ++checked;
                if (!accepts(wanted, shown)) {
                    failures.push_back("frame " + std::to_string(frame) + " shows " + std::to_string(shown) +
                                       ", expected " + std::to_string(wanted.first));
                }
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(4));
        }
        h.controller->pause();
        NSLog(@"VFR PICTURE (%s, %s): %d playing frames checked, %zu wrong", source.name, source.backend, checked,
              failures.size());
        XCTAssertGreaterThan(checked, 60, @"%s: most of the 4 s were presented", source.name);
        XCTAssertTrue(failures.empty(), @"%s: %s", source.name, failures.empty() ? "" : failures.front().c_str());
    }
}

@end
