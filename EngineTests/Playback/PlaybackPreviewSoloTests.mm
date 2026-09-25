// The program monitor's solo preview (PlaybackController::setPreviewSolo, the Ken Burns editor's
// picture): while it is set the primary frame source shows one clip alone at identity Motion, and
// its picture composites exactly like a sequence holding only that clip at identity; the clip is
// held on its last frame past its end (decoded through the paused picture's requests, although the
// program there does not show it); scrubbing and playback keep showing it; a mirror source (the
// output window) keeps showing the program; clearing it, removing the clip and a new sequence give
// the program back, and a clip that is not a video clip of the sequence is refused.

#import <XCTest/XCTest.h>

#include "PlaybackTestSupport.h"

#include "../../Engine/Render/Compositor.h"
#include "../../Engine/Render/TextureCache.h"
#include "../Media/BurnIn.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <thread>
#include <vector>

using namespace ve;
using namespace ve::playback;
using namespace ve::test;

namespace {

constexpr size_t kWidth = 480;
constexpr size_t kHeight = 270;
constexpr size_t kBlock = 16;

/// V1: A = h264 [0, 120) from source 0; V2: B = h264 [30, 90) from source 2 s, placed as a small,
/// turned, half transparent picture in picture; A's sound on A1.
struct Rig {
    AssetId h264;
    ClipId a, b, sound;
};

Rig buildRig(PlaybackHarness &h) {
    Rig r;
    r.h264 = h.importAsset("h264_1080p30.mp4");
    if (!h.ok()) {
        return r;
    }
    r.a = h.addClip(h.v1, r.h264, 0, 120, kCMTimeZero);
    r.b = h.addClip(h.v2, r.h264, 30, 60, CMTimeMake(2, 1));
    r.sound = h.addClip(h.a1, r.h264, 0, 120, kCMTimeZero);
    h.link(r.a, r.sound);
    h.sequence().findClip(r.b)->video = VideoParams{480, 270, 0.5, 15, 0.6};
    return r;
}

/// Means of every 16x16 block of a 32BGRA buffer (B, G, R per block).
std::vector<double> blockMeans(CVPixelBufferRef buffer) {
    std::vector<double> means;
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(buffer));
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    for (size_t by = 0; by + kBlock <= height; by += kBlock) {
        for (size_t bx = 0; bx + kBlock <= width; bx += kBlock) {
            double sum[3] = {0, 0, 0};
            for (size_t y = by; y < by + kBlock; ++y) {
                const uint8_t *row = base + y * stride;
                for (size_t x = bx; x < bx + kBlock; ++x) {
                    for (int c = 0; c < 3; ++c) {
                        sum[c] += row[x * 4 + c];
                    }
                }
            }
            for (double s : sum) {
                means.push_back(s / double(kBlock * kBlock));
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return means;
}

double maxDifference(const std::vector<double> &a, const std::vector<double> &b) {
    if (a.size() != b.size() || a.empty()) {
        return 1e9;
    }
    double worst = 0;
    for (size_t i = 0; i < a.size(); ++i) {
        worst = std::max(worst, std::fabs(a[i] - b[i]));
    }
    return worst;
}

/// Composites what the harness's frame source produced last (what the program view draws) into a
/// 480x270 32BGRA buffer and returns its block means (empty on failure).
std::vector<double> composite(PlaybackHarness &h, render::Compositor &compositor, const media::PixelBufferPool &pool) {
    const render::PreviewFrame &frame = h.frame();
    auto buffer = pool.makeBuffer();
    if (!buffer.ok()) {
        return {};
    }
    auto lookup = [&](const VideoLayer &, std::size_t index, render::TextureSet &out) {
        if (index >= frame.textures.size() || !frame.textures[index]) {
            return false;
        }
        out = frame.textures[index];
        return true;
    };
    auto rendered = compositor.renderAndWait(frame.graph, lookup, render::PixelBufferTarget{buffer.value()});
    if (!rendered.ok() || !rendered->status.ok() || !rendered->skippedLayers.empty()) {
        return {};
    }
    return blockMeans(buffer.value().get());
}

bool allExact(const PlaybackHarness::Sample &sample) {
    return !sample.presented.layers.empty() &&
           std::all_of(sample.presented.layers.begin(), sample.presented.layers.end(),
                       [](const PresentedLayer &layer) { return layer.exact; });
}

} // namespace

@interface PlaybackPreviewSoloTests : XCTestCase
@end

@implementation PlaybackPreviewSoloTests

/// The solo clip's picture is the clip alone at identity: the same pixels as a sequence that holds
/// only that clip, unplaced; the program (and a mirror) show both clips as placed.
- (void)testTheSoloPictureIsTheClipAloneAtIdentityAndTheMirrorKeepsTheProgram {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
    const Rig r = buildRig(h);
    // The reference: a sequence with B's clip alone, at identity, at the same place.
    PlaybackHarness alone(PlaybackHarness::Mode::Realtime, 1.0);
    const AssetId h264 = alone.importAsset("h264_1080p30.mp4");
    if (!h.ok() || !alone.ok()) {
        XCTFail(@"%s %s", h.error().c_str(), alone.error().c_str());
        return;
    }
    alone.addClip(alone.v1, h264, 30, 60, CMTimeMake(2, 1));
    h.load();
    alone.load();

    auto created = render::Compositor::create(h.device(), {MTLPixelFormatRGBA16Float});
    auto pool = media::PixelBufferPool::create(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    XCTAssertTrue(created.ok() && pool.ok());
    if (!created.ok() || !pool.ok()) {
        return;
    }
    render::Compositor &compositor = *created.value();

    // The program at frame 45: A with B placed over it.
    h.controller->seek(frames30(45));
    PlaybackHarness::Sample program = h.presentExact();
    XCTAssertTrue(allExact(program));
    XCTAssertTrue((program.clips == std::vector<ClipId>{r.a, r.b}));
    const std::vector<double> programPixels = composite(h, compositor, pool.value());
    XCTAssertFalse(programPixels.empty());

    // Solo B at identity: one layer, B, unplaced.
    h.controller->setPreviewSolo(PlaybackController::PreviewSolo{r.b, true});
    XCTAssertTrue(h.controller->previewSolo().has_value());
    const PlaybackHarness::Sample solo = h.presentExact();
    XCTAssertTrue(allExact(solo));
    XCTAssertTrue((solo.clips == std::vector<ClipId>{r.b}));
    XCTAssertEqual(solo.burnIns.size(), 1u);
    XCTAssertEqual(solo.burnIns.empty() ? -1 : solo.burnIns[0].value_or(-1), 75, @"B's frame 15 from source 60");
    XCTAssertTrue(h.frame().graph.layers.size() == 1 && h.frame().graph.layers[0].transform == VideoParams{});
    XCTAssertEqual(h.frame().graph.layers.empty() ? -1.0 : h.frame().graph.layers[0].opacity, 1.0);
    const std::vector<double> soloPixels = composite(h, compositor, pool.value());

    alone.controller->seek(frames30(45));
    const PlaybackHarness::Sample reference = alone.presentExact();
    XCTAssertTrue(allExact(reference));
    const std::vector<double> referencePixels = composite(alone, compositor, pool.value());
    const double same = maxDifference(soloPixels, referencePixels);
    NSLog(@"SOLO: the solo picture differs from the clip alone by at most %.3f per block", same);
    XCTAssertLessThan(same, 0.5, @"the solo picture is the clip alone at identity");
    XCTAssertGreaterThan(maxDifference(soloPixels, programPixels), 40.0, @"and not the program");

    // A mirror (the output window) shows the program meanwhile, B placed as it is.
    auto mirrorTextures = render::TextureCache::create(h.device());
    XCTAssertTrue(mirrorTextures.ok());
    if (!mirrorTextures.ok()) {
        return;
    }
    render::TextureCache textures = std::move(mirrorTextures).value();
    render::PreviewFrameSource mirror = h.controller->frameSource(PlaybackController::SourceRole::Mirror);
    render::PreviewFrameRequest request;
    request.textureCache = &textures;
    render::PreviewFrame mirrored;
    XCTAssertTrue(mirror(request, mirrored));
    XCTAssertEqual(mirrored.graph.layers.size(), 2u);
    if (mirrored.graph.layers.size() == 2) {
        XCTAssertEqual(mirrored.graph.layers[1].clipId, r.b);
        XCTAssertTrue(mirrored.graph.layers[1].transform == (VideoParams{480, 270, 0.5, 15, 0.6}));
    }

    // Cleared: the program again.
    h.controller->setPreviewSolo(std::nullopt);
    XCTAssertFalse(h.controller->previewSolo().has_value());
    program = h.presentExact();
    XCTAssertTrue((program.clips == std::vector<ClipId>{r.a, r.b}));
    XCTAssertLessThan(maxDifference(composite(h, compositor, pool.value()), programPixels), 0.5);
}

/// Past the clip's end the solo picture holds its last frame (a picture the program does not show
/// there, decoded through the paused picture's requests); scrubbing and playback show the clip
/// alone frame by frame; the clip's removal, a new sequence and a clip that is not a video clip of
/// the sequence give the program back.
- (void)testTheSoloClipIsHeldScrubbedAndPlayedAndGoesAwayWithTheClip {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
    const Rig r = buildRig(h);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    h.load();
    h.controller->setPreviewSolo(PlaybackController::PreviewSolo{r.b, true});

    // Past B's end (frame 100: only A in the program): B's last frame, source frame 60 + 59.
    h.controller->seek(frames30(100));
    PlaybackHarness::Sample held = h.presentExact();
    XCTAssertTrue(allExact(held), @"the held picture is decoded");
    XCTAssertEqual(held.presented.frameIndex, 100);
    XCTAssertTrue((held.clips == std::vector<ClipId>{r.b}));
    XCTAssertEqual(held.burnIns.empty() ? -1 : held.burnIns[0].value_or(-1), 119);
    // Before it (frame 10): its first frame.
    h.controller->seek(frames30(10));
    held = h.presentExact();
    XCTAssertEqual(held.burnIns.empty() ? -1 : held.burnIns[0].value_or(-1), 60);

    // Scrubbing inside it.
    h.controller->scrubTo(frames30(50));
    const PlaybackHarness::Sample scrubbed = h.presentExact();
    XCTAssertTrue((scrubbed.clips == std::vector<ClipId>{r.b}));
    XCTAssertEqual(scrubbed.burnIns.empty() ? -1 : scrubbed.burnIns[0].value_or(-1), 80);
    h.controller->endScrub();

    // Playing from frame 40: clock-driven frames of B alone, each B's own frame.
    h.controller->seek(frames30(40));
    h.presentExact();
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    int playedFrames = 0;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (playedFrames < 5 && std::chrono::steady_clock::now() < deadline) {
        const PlaybackHarness::Sample s = h.present();
        if (s.changed && s.presented.clockDriven && s.presented.frameIndex < 88 && allExact(s)) {
            XCTAssertTrue((s.clips == std::vector<ClipId>{r.b}), @"frame %lld", s.presented.frameIndex);
            XCTAssertEqual(s.burnIns.empty() ? -1 : s.burnIns[0].value_or(-1), 30 + s.presented.frameIndex,
                           @"frame %lld", s.presented.frameIndex);
            ++playedFrames;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    XCTAssertEqual(playedFrames, 5, @"B alone while playing");
    h.controller->pause();
    XCTAssertTrue(h.waitForState(PlaybackState::Stopped));

    // Not a video clip of the sequence: refused (the program).
    h.controller->setPreviewSolo(PlaybackController::PreviewSolo{r.sound, true});
    XCTAssertFalse(h.controller->previewSolo().has_value(), @"an audio clip");
    h.controller->setPreviewSolo(PlaybackController::PreviewSolo{ClipId(424242), true});
    XCTAssertFalse(h.controller->previewSolo().has_value(), @"no such clip");

    // B removed: the program again.
    h.controller->setPreviewSolo(PlaybackController::PreviewSolo{r.b, false});
    XCTAssertTrue(h.controller->previewSolo().has_value());
    h.controller->seek(frames30(45));
    const PlaybackHarness::Sample placed = h.presentExact();
    XCTAssertTrue((placed.clips == std::vector<ClipId>{r.b}));
    XCTAssertTrue(h.frame().graph.layers.size() == 1 &&
                      h.frame().graph.layers[0].transform == (VideoParams{480, 270, 0.5, 15, 0.6}),
                  @"without identity: its own Motion, alone");
    Track &v2 = *h.sequence().findTrack(h.v2);
    v2.clips.clear();
    h.publishEdit();
    XCTAssertFalse(h.controller->previewSolo().has_value(), @"the clip went away");
    const PlaybackHarness::Sample after = h.presentExact();
    XCTAssertTrue((after.clips == std::vector<ClipId>{r.a}));

    // A new sequence (New/Open) clears it.
    h.controller->setPreviewSolo(PlaybackController::PreviewSolo{r.a, true});
    XCTAssertTrue(h.controller->previewSolo().has_value());
    h.load();
    XCTAssertFalse(h.controller->previewSolo().has_value());
}

@end
