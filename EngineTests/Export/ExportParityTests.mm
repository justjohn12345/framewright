// An export shows and sounds exactly like the program monitor (phase 7 review test gaps 1 and 2).
// - Pictures: frames of a sequence with a rotated clip coming in through a dissolve, a still with
//   alpha over both, and letterboxing (the 16:9 sequence exported at 4:3) are taken from the
//   PlaybackController's frame source (what VEPreviewView composites) and composited into a 32BGRA
//   buffer the way the view renders; the same frames are exported (ProRes 422, near lossless) and
//   decoded to 32BGRA. 16x16-block means may differ only by the codec's error (ProRes 422 halves
//   the chroma horizontally, which moves the mean of an 8-pixel block beside a saturated red/blue
//   edge by up to about 20 codes; over 16 pixels, about 11: the bound is 14); another frame differs
//   far more, which shows the measure tells frames apart.
// - Sound: the playback mixer's output (captured from a real-time NullAudioOutput) and the offline
//   renderer's mix are compared sample by sample over a sequence with speed 3/2, a fade in, a 70/30
//   constant-power crossfade (7 frames before the cut, 3 after), a fade out, two tracks summed, a
//   Gain span ramping one clip down and a +12 dB clip that drives the sum into clipping.
// - Effect spans on two lanes (effect lanes, open finding 8 before them): a clip whose position,
//   scale, rotation and opacity are animated by Motion spans on two lanes and an Opacity span on a
//   third (ease in and out, linear, hold; composed onto a static offset), under a still whose scale
//   a Motion span steps (hold), exports the pictures the program monitor shows frame by frame; the
//   monitor's layers carry the composed values at each frame (so the comparison is over moving
//   pictures).
// - Fades from and to black: a clip with a lane-0 fade at each end exports the monitor's pictures,
//   and the pictures go from black and back to it.
// - Variable frame rate (UX round review, test gap 1): a VFR clip through each backend exports the
//   same source frames the monitor shows, and both are the frames containing the exact source time.

#import <XCTest/XCTest.h>

#include "../../Engine/Audio/OfflineAudioRenderer.h"
#include "../../Engine/Export/ExportJob.h"
#include "../../Engine/Media/AssetImport.h"
#include "../../Engine/Render/Compositor.h"
#include "../Media/BurnIn.h"
#include "../Media/FFmpegTestMedia.h"
#include "../Media/TestMedia.h"
#include "../Playback/PlaybackTestSupport.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include <algorithm>
#include <cmath>
#include <mutex>
#include <string>
#include <vector>

using namespace ve;
using namespace ve::test;
using ve::playback::PresentedLayer;
namespace ex = ve::exporting;

namespace {

constexpr int kOutWidth = 640;
constexpr int kOutHeight = 480;

/// A 320x180 PNG: the left half red at alpha 128 (straight colour), the right half opaque blue.
bool writeAlphaPNG(const std::string &path) {
    const size_t w = 320, h = 180;
    std::vector<uint8_t> rgba(w * h * 4);
    for (size_t y = 0; y < h; ++y) {
        for (size_t x = 0; x < w; ++x) {
            uint8_t *p = &rgba[(y * w + x) * 4];
            const bool left = x < w / 2;
            const uint8_t alpha = left ? 128 : 255;
            // Premultiplied storage for CoreGraphics (the PNG it writes is straight).
            p[0] = left ? uint8_t(255 * alpha / 255) : 0;
            p[1] = 0;
            p[2] = left ? 0 : 255;
            p[3] = alpha;
        }
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(rgba.data(), w, h, 8, w * 4, space,
                                                 static_cast<uint32_t>(kCGImageAlphaPremultipliedLast) |
                                                     static_cast<uint32_t>(kCGBitmapByteOrder32Big));
    CGImageRef image = context ? CGBitmapContextCreateImage(context) : nullptr;
    bool ok = false;
    if (image) {
        NSURL *url = [NSURL fileURLWithPath:@(path.c_str())];
        CGImageDestinationRef dest =
            CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, nullptr);
        if (dest) {
            CGImageDestinationAddImage(dest, image, nullptr);
            ok = CGImageDestinationFinalize(dest);
            CFRelease(dest);
        }
        CGImageRelease(image);
    }
    if (context) {
        CGContextRelease(context);
    }
    CGColorSpaceRelease(space);
    return ok;
}

constexpr size_t kBlock = 16;

/// kBlock x kBlock block means (B, G, R per block) of a 32BGRA buffer.
std::vector<double> blockMeans(CVPixelBufferRef buffer) {
    const size_t w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer);
    std::vector<double> out((w / kBlock) * (h / kBlock) * 3, 0.0);
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(buffer));
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    for (size_t by = 0; by < h / kBlock; ++by) {
        for (size_t bx = 0; bx < w / kBlock; ++bx) {
            double sum[3] = {0, 0, 0};
            for (size_t y = by * kBlock; y < by * kBlock + kBlock; ++y) {
                for (size_t x = bx * kBlock; x < bx * kBlock + kBlock; ++x) {
                    const uint8_t *p = base + y * stride + x * 4;
                    for (int c = 0; c < 3; ++c) {
                        sum[c] += p[c];
                    }
                }
            }
            for (int c = 0; c < 3; ++c) {
                out[(by * (w / kBlock) + bx) * 3 + size_t(c)] = sum[c] / double(kBlock * kBlock);
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return out;
}

struct Difference {
    double maxBlock = 0;
    double meanBlock = 0;
    size_t worstBlock = 0; ///< Index of the block (row-major, kOutWidth / kBlock per row) with maxBlock.
    int worstChannel = 0;  ///< 0 B, 1 G, 2 R.
    double worstA = 0, worstB = 0;
};

Difference compare(const std::vector<double> &a, const std::vector<double> &b) {
    Difference d;
    const size_t n = std::min(a.size(), b.size());
    for (size_t i = 0; i < n; ++i) {
        const double diff = std::fabs(a[i] - b[i]);
        if (diff > d.maxBlock) {
            d.maxBlock = diff;
            d.worstBlock = i / 3;
            d.worstChannel = int(i % 3);
            d.worstA = a[i];
            d.worstB = b[i];
        }
        d.meanBlock += diff;
    }
    d.meanBlock = n > 0 ? d.meanBlock / double(n) : 0;
    return d;
}

std::map<AssetId, media::RoutedMediaInfo> routingOf(const Project &project, const media::BackendRouter &router) {
    std::map<AssetId, media::RoutedMediaInfo> routing;
    for (const MediaAsset &asset : project.assets) {
        if (auto routed = router.probe(asset.url); routed.ok()) {
            routing[asset.id] = std::move(routed).value();
        }
    }
    return routing;
}

/// Runs an export to completion on a private cache; nullopt when refused (error set) or timed out.
std::optional<media::Result<ex::ExportSummary>> runExport(ex::ExportRequest request, ex::ExportServices services,
                                                          std::string &error) {
    auto result = std::make_shared<std::optional<media::Result<ex::ExportSummary>>>();
    auto m = std::make_shared<std::mutex>();
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_queue_t queue = dispatch_queue_create("com.justjohn12345.framewright.tests.parity", DISPATCH_QUEUE_SERIAL);
    auto started = ex::ExportJob::start(std::move(request), std::move(services), {}, queue, {},
                                        [result, m, done](media::Result<ex::ExportSummary> r) {
                                            std::lock_guard<std::mutex> l(*m);
                                            *result = std::move(r);
                                            dispatch_semaphore_signal(done);
                                        });
    if (!started.ok()) {
        error = started.error().description();
        return std::nullopt;
    }
    started.value().reset();
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, int64_t(120) * NSEC_PER_SEC));
    std::lock_guard<std::mutex> l(*m);
    return *result;
}

} // namespace

@interface ExportParityTests : XCTestCase
@end

@implementation ExportParityTests {
    std::string _dir;
}

- (void)setUp {
    _dir = ve::test::scratchDirectory();
}

- (void)testExportedPicturesMatchTheProgramMonitor {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    h.sequence().width = 640;
    h.sequence().height = 360;
    const AssetId movie = h.importAsset("h264_1080p30.mp4");
    const AssetId rotated = h.importAsset("rotated90_h264.mp4"); // displayed 360x640: pillarboxed
    const std::string alphaPath = _dir + "/alpha.png";
    XCTAssertTrue(writeAlphaPNG(alphaPath));
    const AssetId still = h.importAssetAtPath(alphaPath);
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    XCTAssertEqual(h.project.findAsset(rotated)->rotationDegrees, 90);
    // V1: the movie from 1 s, then the rotated clip from its frame 10 through a 10-frame dissolve
    // (frames 25...34). V2: the half-transparent still at half size, off centre, over [20, 45).
    const ClipId a = h.addClip(h.v1, movie, 0, 30, CMTimeMake(1, 1));
    const ClipId b = h.addClip(h.v1, rotated, 30, 20, CMTimeMake(10, 30));
    h.addTransition(h.v1, a, b, 10);
    const ClipId s = h.addClip(h.v2, still, 20, 25, kCMTimeZero);
    Clip &overlay = *h.sequence().findClip(s);
    overlay.isStill = true;
    overlay.video.scale = 0.5;
    overlay.video.x = 120;
    overlay.video.y = -60;
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();

    // The export: ProRes 422 at 640x480 (the 16:9 sequence letterboxed), on its own cache.
    ex::ExportRequest request;
    request.project = std::make_shared<const Project>(h.project);
    request.sequenceId = h.sequenceId;
    request.encode.container = media::ContainerFormat::MOV;
    media::VideoEncodeSettings v;
    v.codec = media::VideoCodec::ProRes422;
    v.width = kOutWidth;
    v.height = kOutHeight;
    request.encode.video = v;
    request.outputPath = _dir + "/parity.mov";
    ex::ExportServices services;
    services.router = h.router;
    services.cache = std::make_shared<media::FrameCache>();
    services.routing = routingOf(h.project, *h.router);
    std::string error;
    auto result = runExport(request, services, error);
    XCTAssertTrue(result.has_value(), @"%s", error.c_str());
    if (!result || !result->ok()) {
        XCTFail(@"export: %s", result ? result->error().description().c_str() : error.c_str());
        return;
    }

    auto created = render::Compositor::create(h.device(), {MTLPixelFormatRGBA16Float});
    XCTAssertTrue(created.ok());
    auto pool = media::PixelBufferPool::create(kCVPixelFormatType_32BGRA, kOutWidth, kOutHeight);
    XCTAssertTrue(created.ok() && pool.ok());
    if (!created.ok() || !pool.ok()) {
        return;
    }
    render::Compositor &compositor = *created.value();
    auto routed = h.router->probe(request.outputPath);
    XCTAssertTrue(routed.ok());
    if (!routed.ok()) {
        return;
    }
    media::DecodeOptions bgra;
    bgra.pixelFormat = kCVPixelFormatType_32BGRA;
    auto decoder = h.router->makeVideoDecoder(*routed, -1, bgra);
    XCTAssertTrue(decoder.ok());
    if (!decoder.ok()) {
        return;
    }

    std::map<int64_t, std::vector<double>> monitor, exported;
    for (int64_t f : {0, 12, 21, 26, 29, 30, 33, 40, 44, 49}) {
        h.controller->seek(frames30(f));
        const PlaybackHarness::Sample sample = h.presentExact();
        XCTAssertEqual(sample.presented.frameIndex, f);
        for (const playback::PresentedLayer &layer : sample.presented.layers) {
            XCTAssertTrue(layer.exact, @"frame %lld: clip %llu has its picture", f, layer.clip.value());
        }
        const render::PreviewFrame &frame = h.frame();
        auto buffer = pool->makeBuffer();
        XCTAssertTrue(buffer.ok());
        if (!buffer.ok()) {
            continue;
        }
        auto lookup = [&](const VideoLayer &, std::size_t index, render::TextureSet &out) {
            if (index >= frame.textures.size() || !frame.textures[index]) {
                return false;
            }
            out = frame.textures[index];
            return true;
        };
        auto rendered = compositor.renderAndWait(frame.graph, lookup, render::PixelBufferTarget{buffer.value()});
        XCTAssertTrue(rendered.ok() && rendered->status.ok() && rendered->skippedLayers.empty(), @"frame %lld", f);
        monitor[f] = blockMeans(buffer.value().get());

        XCTAssertTrue(decoder->decoder->seek(CMTimeMake(f, 30)).ok());
        auto decoded = decoder->decoder->next();
        XCTAssertTrue(decoded.ok() && decoded.value(), @"exported frame %lld", f);
        if (decoded.ok() && decoded.value()) {
            exported[f] = blockMeans(decoded.value()->image.get());
        }
    }
    double worst = 0;
    for (const auto &[f, pixels] : monitor) {
        if (!exported.count(f)) {
            continue;
        }
        const Difference d = compare(pixels, exported[f]);
        worst = std::max(worst, d.maxBlock);
        NSLog(@"PARITY frame %lld: %zux%zu blocks differ by at most %.2f (block x %zu y %zu, channel %d: monitor %.1f, "
              @"export %.1f), on average %.3f",
              f, kBlock, kBlock, d.maxBlock, (d.worstBlock % (kOutWidth / kBlock)) * kBlock,
              (d.worstBlock / (kOutWidth / kBlock)) * kBlock, d.worstChannel, d.worstA, d.worstB, d.meanBlock);
        XCTAssertLessThan(d.maxBlock, 14.0, @"frame %lld: the export differs from the monitor", f);
        XCTAssertLessThan(d.meanBlock, 1.0, @"frame %lld", f);
    }
    // The measure tells other frames apart: the same clip 12 frames on (only the burn-in and its
    // palette colour change), and the rotated clip one frame on.
    for (const auto &[shown, written] : {std::pair<int64_t, int64_t>{0, 12}, std::pair<int64_t, int64_t>{44, 49}}) {
        if (monitor.count(shown) && exported.count(written)) {
            const Difference other = compare(monitor[shown], exported[written]);
            NSLog(@"PARITY monitor frame %lld vs exported frame %lld: %.1f", shown, written, other.maxBlock);
            XCTAssertGreaterThan(other.maxBlock, 40.0, @"frames %lld and %lld", shown, written);
        }
    }
    NSLog(@"PARITY worst block difference %.2f over %zu frames", worst, monitor.size());
}

/// V1: vfr_h264.mp4 (the Apple backend) for sequence frames [0, 45) from 67/600 s, then its Matroska
/// remux vfr_h264_blockdur.mkv (FFmpeg) for [45, 90) from 1407/600 s (in points off the nominal frame
/// grid, so some source times lie just after a frame boundary their nominal slot starts before).
/// Every frame of the export (ProRes 422, so the burn-in reads back exactly) shows the source frame
/// the program monitor shows for it, and that is the frame containing the layer's exact source time
/// (within a millisecond of a frame boundary for Matroska's millisecond timestamps), not the frame
/// under its nominal slot's start.
- (void)testAVariableFrameRateSourceExportsTheMonitorsPictures {
    std::string derivedError;
    const std::string mkv = derivedMediaPath("vfr_h264_blockdur.mkv", derivedError);
    XCTAssertFalse(mkv.empty(), @"%s", derivedError.c_str());
    if (mkv.empty()) {
        return;
    }
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    h.sequence().width = 640;
    h.sequence().height = 360;
    const AssetId mp4 = h.importAsset("vfr_h264.mp4");
    const AssetId remux = h.importAssetAtPath(mkv);
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    XCTAssertTrue(h.project.findAsset(mp4)->isVFR && h.project.findAsset(remux)->isVFR);
    constexpr int64_t kSplit = 45, kFrames = 90;
    const CMTime firstIn = CMTimeMake(67, 600);
    const CMTime secondIn = CMTimeMake(1407, 600);
    h.addClip(h.v1, mp4, 0, kSplit, firstIn);
    h.addClip(h.v1, remux, kSplit, kFrames - kSplit, secondIn);
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();

    ex::ExportRequest request;
    request.project = std::make_shared<const Project>(h.project);
    request.sequenceId = h.sequenceId;
    request.encode.container = media::ContainerFormat::MOV;
    media::VideoEncodeSettings v;
    v.codec = media::VideoCodec::ProRes422;
    v.width = 640;
    v.height = 360;
    request.encode.video = v;
    request.outputPath = _dir + "/vfr-parity.mov";
    ex::ExportServices services;
    services.router = h.router;
    services.cache = std::make_shared<media::FrameCache>();
    services.routing = routingOf(h.project, *h.router);
    std::string error;
    auto result = runExport(request, services, error);
    XCTAssertTrue(result.has_value(), @"%s", error.c_str());
    if (!result || !result->ok()) {
        XCTFail(@"export: %s", result ? result->error().description().c_str() : error.c_str());
        return;
    }
    XCTAssertEqual(result->value().frames, kFrames);
    auto routed = h.router->probe(request.outputPath);
    XCTAssertTrue(routed.ok());
    if (!routed.ok()) {
        return;
    }
    media::DecodeOptions bgra;
    bgra.pixelFormat = kCVPixelFormatType_32BGRA;
    auto decoder = h.router->makeVideoDecoder(*routed, -1, bgra);
    XCTAssertTrue(decoder.ok());
    if (!decoder.ok()) {
        return;
    }

    int slotBiased[2] = {0, 0}; // per clip
    for (int64_t f = 0; f < kFrames; ++f) {
        const bool first = f < kSplit;
        const CMTime source = first ? firstIn + frames30(f) : secondIn + frames30(f - kSplit);
        const int64_t toleranceMs = first ? 0 : 1;
        const int early = vfrFrameAt(source - CMTimeMake(toleranceMs, 1000));
        const int late = vfrFrameAt(source + CMTimeMake(toleranceMs, 1000));

        h.controller->seek(frames30(f));
        const PlaybackHarness::Sample sample = h.presentExact();
        XCTAssertEqual(sample.presented.frameIndex, f);
        XCTAssertTrue(sample.presented.layers.size() == 1 && sample.presented.layers[0].exact, @"frame %lld", f);
        const int monitor = sample.burnIns.empty() ? -1 : sample.burnIns[0].value_or(-1);

        XCTAssertTrue(decoder->decoder->seek(frames30(f)).ok());
        auto decoded = decoder->decoder->next();
        XCTAssertTrue(decoded.ok() && decoded.value(), @"exported frame %lld", f);
        const int exported =
            decoded.ok() && decoded.value() ? readBurnIn(decoded.value()->image.get()).value_or(-1) : -1;

        XCTAssertEqual(exported, monitor, @"frame %lld: the export shows what the monitor shows", f);
        XCTAssertTrue(monitor == early || monitor == late,
                      @"frame %lld (source %.4f s): shows %d, the frame containing the source time is %d", f,
                      CMTimeGetSeconds(source), monitor, early);
        const MediaAsset &asset = *h.project.findAsset(first ? mp4 : remux);
        const CMTime slotStart = timeForFrame(media::FrameCache::frameIndex(source, asset.frameDuration),
                                              asset.frameDuration);
        const int underSlot = vfrFrameAt(slotStart - CMTimeMake(toleranceMs, 1000));
        if (early == late && underSlot == vfrFrameAt(slotStart + CMTimeMake(toleranceMs, 1000)) && underSlot != early) {
            ++slotBiased[first ? 0 : 1];
        }
    }
    NSLog(@"PARITY VFR: %lld frames compared; the nominal slot's start is an earlier frame for %d (apple) and %d "
          @"(ffmpeg) of them",
          kFrames, slotBiased[0], slotBiased[1]);
    XCTAssertGreaterThanOrEqual(slotBiased[0], 5, @"the Apple clip exercises the frames the slot lookup got wrong");
    XCTAssertGreaterThanOrEqual(slotBiased[1], 5, @"the FFmpeg clip exercises the frames the slot lookup got wrong");
}

- (void)testExportedAudioMatchesThePlaybackMixSampleForSample {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 6.0);
    const AssetId movie = h.importAsset("h264_1080p30.mp4");
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    Track a2;
    a2.id = h.project.ids.make<TrackId>();
    a2.kind = TrackKind::Audio;
    a2.name = "A2";
    h.sequence().audioTracks.push_back(a2);
    // A1: X at speed 3/2 (4.5 s of source from 0.5 s) with a fade in, then Y from 5 s with a fade out,
    // joined by a 70/30 constant-power crossfade (7 frames before the cut, 3 after). A2: the movie
    // from 1 s at +12 dB: its beep (at 2 s, so at 1 s on the timeline) and the tone on top of the A1
    // clips, ramped down 18 dB by a Gain span over its last two seconds (an ease in).
    const ClipId x = h.addClip(h.a1, movie, 0, 90, CMTimeMake(1, 2));
    Clip &xc = *h.sequence().findClip(x);
    xc.speed = Ratio{3, 2};
    h.addFade(x, ClipEdge::Head, 15);
    const ClipId y = h.addClip(h.a1, movie, 90, 60, CMTimeMake(5, 1));
    h.addTailTransition(x, 7, 3);
    h.addFade(y, ClipEdge::Tail, 20);
    const ClipId loud = h.addClip(a2.id, movie, 0, 120, CMTimeMake(1, 1));
    h.sequence().findClip(loud)->audio.gainDb = 12.0;
    SpanTracks duck;
    Keyframe level;
    level.time = kCMTimeZero;
    level.value = 0;
    level.interpolation = KeyframeInterpolation::EaseIn;
    Keyframe ducked;
    ducked.time = CMTimeMake(2, 1);
    ducked.value = -18;
    duck.gain = {level, ducked};
    h.addSpan(loud, SpanKind::Gain, 1, CMTimeMake(3, 1), CMTimeMake(5, 1), duck);
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();

    h.controller->seek(kCMTimeZero);
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    XCTAssertTrue(h.waitForState(playback::PlaybackState::Stopped, std::chrono::seconds(15)), @"played to the end");
    const audio::NullAudioOutput::Capture capture = h.output->capture();
    const playback::PlaybackStats stats = h.controller->stats();
    XCTAssertEqual(stats.audioUnderruns, 0u, @"the playback mix is complete");
    XCTAssertEqual(capture.channels, 2);

    audio::OfflineAudioRenderer offline(h.router, std::make_shared<const Project>(h.project), h.sequenceId,
                                        routingOf(h.project, *h.router), audio::OfflineAudioRenderer::Config{});
    std::vector<float> mixed;
    std::vector<float> block(1024 * 2);
    for (;;) {
        auto n = offline.render(block.data(), 1024, [] { return false; });
        XCTAssertTrue(n.ok(), @"%s", n.ok() ? "" : n.error().description().c_str());
        if (!n.ok() || n.value() == 0) {
            break;
        }
        mixed.insert(mixed.end(), block.begin(), block.begin() + n.value() * 2);
    }
    XCTAssertEqual(int64_t(mixed.size() / 2), int64_t(5 * 48000));
    XCTAssertGreaterThanOrEqual(capture.firstSequenceSample, 0);
    const int64_t from = std::max<int64_t>(0, capture.firstSequenceSample);
    const int64_t captured = int64_t(capture.samples.size() / 2);
    const int64_t count = std::min<int64_t>(captured, int64_t(mixed.size() / 2) - from);
    XCTAssertGreaterThan(count, 4 * 48000, @"most of the sequence was captured");
    double worst = 0;
    int64_t worstAt = -1;
    int64_t clipped = 0;
    for (int64_t i = 0; i < count * 2; ++i) {
        const double o = mixed[size_t(from * 2 + i)];
        const double d = std::fabs(double(capture.samples[size_t(i)]) - o);
        if (d > worst) {
            worst = d;
            worstAt = from + i / 2;
        }
        clipped += std::fabs(o) >= 0.999 ? 1 : 0;
    }
    NSLog(@"PARITY audio: %lld frames from %lld compared, max |playback - export| %.3g at sample %lld; %lld samples "
          @"at full scale",
          count, from, worst, worstAt, clipped);
    XCTAssertLessThan(worst, 1e-5, @"the export's mix differs from playback at sample %lld", worstAt);
    XCTAssertGreaterThan(clipped, 100, @"the +12 dB beep drove the sum into clipping");
    // The fade out ends in silence: over Y's last 10 ms (only Y plays then) the level is below 1/25
    // of what it is before the fade.
    auto peak = [&](int64_t first, int64_t last) {
        double p = 0;
        for (int64_t i = first; i < last; ++i) {
            p = std::max(p, double(std::fabs(mixed[size_t(i * 2)])));
        }
        return p;
    };
    const double before = peak(4 * 48000 - 9600, 4 * 48000 + 16000); // Y at full level, [3.8, 4.33) s
    const double end = peak(5 * 48000 - 480, 5 * 48000);
    NSLog(@"PARITY audio: Y peaks at %.4f before its fade out, %.5f in its last 10 ms", before, end);
    XCTAssertGreaterThan(before, 0.05);
    XCTAssertLessThan(end, before / 25);
}

- (void)testAnAnimatedClipExportsTheMonitorsPictures {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    h.sequence().width = 640;
    h.sequence().height = 360;
    const AssetId movie = h.importAsset("h264_1080p30.mp4");
    const std::string alphaPath = _dir + "/alpha-animated.png";
    XCTAssertTrue(writeAlphaPNG(alphaPath));
    const AssetId still = h.importAssetAtPath(alphaPath);
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    auto key = [](CMTime time, double value, KeyframeInterpolation interpolation) {
        Keyframe k;
        k.time = time;
        k.value = value;
        k.interpolation = interpolation;
        return k;
    };
    // V1: the movie from 1 s for 40 frames, offset right by a static 30 points. Lane 1: a Ken
    // Burns-like push in over the whole clip (source [30, 70) frames) with a turn from its frame 10.
    // Lane 2: a Motion span over source [45, 60) that grows it a further 20% (scale multiplies) and
    // turns it 10 degrees more (rotation adds). Lane 3: an Opacity span over source [30, 60) holding
    // full opacity, then fading to 0.6.
    const ClipId clip = h.addClip(h.v1, movie, 0, 40, CMTimeMake(1, 1));
    h.sequence().findClip(clip)->video.x = 30;
    SpanTracks push;
    push.scale = {key(frames30(0), 1, KeyframeInterpolation::EaseInOut), key(frames30(39), 2.2, KeyframeInterpolation::Linear)};
    push.x = {key(frames30(0), 0, KeyframeInterpolation::EaseInOut), key(frames30(39), -150, KeyframeInterpolation::Linear)};
    push.y = {key(frames30(0), 0, KeyframeInterpolation::Linear), key(frames30(39), 60, KeyframeInterpolation::Linear)};
    push.rotation = {key(frames30(10), 0, KeyframeInterpolation::Linear), key(frames30(30), 25, KeyframeInterpolation::Linear)};
    h.addSpan(clip, SpanKind::Motion, 1, frames30(30), frames30(70), push);
    SpanTracks grow;
    grow.scale = {key(frames30(0), 1, KeyframeInterpolation::Linear), key(frames30(15), 1.2, KeyframeInterpolation::Linear)};
    grow.rotation = {key(frames30(0), 0, KeyframeInterpolation::Linear), key(frames30(15), 10, KeyframeInterpolation::Linear)};
    const SpanId growId = h.addSpan(clip, SpanKind::Motion, 2, frames30(45), frames30(60), grow);
    SpanTracks fade;
    fade.opacity = {key(frames30(0), 1, KeyframeInterpolation::Hold), key(frames30(20), 0.6, KeyframeInterpolation::Linear)};
    h.addSpan(clip, SpanKind::Opacity, 3, frames30(30), frames30(60), fade);
    // V2: the half-transparent still over it, growing in steps (hold) by a Motion span over the
    // still's first 30 frames (a still's span times are its own timeline offsets).
    const ClipId overlay = h.addClip(h.v2, still, 5, 30, kCMTimeZero);
    Clip &overlayClip = *h.sequence().findClip(overlay);
    overlayClip.isStill = true;
    overlayClip.video.x = 150;
    SpanTracks steps;
    steps.scale = {key(frames30(0), 0.2, KeyframeInterpolation::Hold), key(frames30(10), 0.35, KeyframeInterpolation::Hold),
                   key(frames30(20), 0.5, KeyframeInterpolation::Linear)};
    h.addSpan(overlay, SpanKind::Motion, 1, kCMTimeZero, frames30(30), steps);
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();
    ex::ExportRequest request;
    request.project = std::make_shared<const Project>(h.project);
    request.sequenceId = h.sequenceId;
    request.encode.container = media::ContainerFormat::MOV;
    media::VideoEncodeSettings v;
    v.codec = media::VideoCodec::ProRes422;
    v.width = 640;
    v.height = 360;
    request.encode.video = v;
    request.outputPath = _dir + "/animated-parity.mov";
    ex::ExportServices services;
    services.router = h.router;
    services.cache = std::make_shared<media::FrameCache>();
    services.routing = routingOf(h.project, *h.router);
    std::string error;
    auto result = runExport(request, services, error);
    XCTAssertTrue(result.has_value(), @"%s", error.c_str());
    if (!result || !result->ok()) {
        XCTFail(@"export: %s", result ? result->error().description().c_str() : error.c_str());
        return;
    }
    auto created = render::Compositor::create(h.device(), {MTLPixelFormatRGBA16Float});
    auto pool = media::PixelBufferPool::create(kCVPixelFormatType_32BGRA, 640, 360);
    auto routed = h.router->probe(request.outputPath);
    XCTAssertTrue(created.ok() && pool.ok() && routed.ok());
    if (!created.ok() || !pool.ok() || !routed.ok()) {
        return;
    }
    media::DecodeOptions bgra;
    bgra.pixelFormat = kCVPixelFormatType_32BGRA;
    auto decoder = h.router->makeVideoDecoder(*routed, -1, bgra);
    XCTAssertTrue(decoder.ok());
    if (!decoder.ok()) {
        return;
    }
    const Clip &animated = *h.sequence().findClip(clip);
    const Clip &overlayed = *h.sequence().findClip(overlay);
    int64_t movingFramesChecked = 0;
    for (int64_t f : {0, 4, 9, 14, 19, 24, 29, 34, 39}) {
        h.controller->seek(frames30(f));
        const PlaybackHarness::Sample sample = h.presentExact();
        XCTAssertEqual(sample.presented.frameIndex, f);
        const render::PreviewFrame &frame = h.frame();
        // The monitor's layers show the Motion the spans compose for this frame (found by clip, not
        // by position in the graph).
        const VideoParams expected = motionValuesAt(animated, frames30(f));
        std::optional<std::size_t> v1Layer;
        std::optional<std::size_t> v2Layer;
        for (std::size_t i = 0; i < frame.graph.layers.size(); ++i) {
            if (frame.graph.layers[i].clipId == clip) v1Layer = i;
            if (frame.graph.layers[i].clipId == overlay) v2Layer = i;
        }
        XCTAssertTrue(v1Layer.has_value(), @"frame %lld", f);
        if (!v1Layer) {
            continue;
        }
        const VideoParams &shown = frame.graph.layers[*v1Layer].transform;
        XCTAssertEqualWithAccuracy(shown.scale, expected.scale, 1e-12, @"frame %lld", f);
        XCTAssertEqualWithAccuracy(shown.x, expected.x, 1e-12, @"frame %lld", f);
        XCTAssertEqualWithAccuracy(shown.y, expected.y, 1e-12, @"frame %lld", f);
        XCTAssertEqualWithAccuracy(shown.rotationDegrees, expected.rotationDegrees, 1e-12, @"frame %lld", f);
        XCTAssertEqualWithAccuracy(frame.graph.layers[*v1Layer].opacity, expected.opacity, 1e-12, @"frame %lld", f);
        // Composition, checked against the lanes one at a time: without the lane-2 span the scale
        // is lane 1's alone and the rotation 10 degrees times its progress less.
        const auto at = spanEvaluationTime(animated, frames30(f));
        XCTAssertTrue(at.has_value());
        if (at) {
            const VideoParams withoutGrow = composeMotion(animated, *at, growId);
            const EffectSpan &growSpan = *animated.findSpan(growId);
            const bool growing = spanActiveAt(animated, growSpan, *at);
            XCTAssertEqual(growing, f >= 15 && f < 30, @"frame %lld", f);
            const double factor = growing ? spanValueAt(growSpan, SpanParameter::Scale, *at) : 1.0;
            const double turn = growing ? spanValueAt(growSpan, SpanParameter::Rotation, *at) : 0.0;
            XCTAssertEqualWithAccuracy(shown.scale, withoutGrow.scale * factor, 1e-12, @"frame %lld", f);
            XCTAssertEqualWithAccuracy(shown.rotationDegrees, withoutGrow.rotationDegrees + turn, 1e-12, @"frame %lld", f);
            if (growing) {
                // Frame f shows source frame 30 + f, lane 2's frame f - 15 of its 15.
                XCTAssertEqualWithAccuracy(factor, 1.0 + 0.2 * double(f - 15) / 15.0, 1e-12, @"frame %lld", f);
            }
            XCTAssertEqualWithAccuracy(shown.x, withoutGrow.x, 1e-12, @"frame %lld: lane 2 moves nothing", f);
            XCTAssertGreaterThanOrEqual(shown.x, -120.0 - 1e-9, @"frame %lld: the static offset still applies", f);
        }
        // The V2 still's scale holds each keyframe's value until the next (clip-relative times: the
        // still starts at frame 5), then grows linearly after the last hold.
        XCTAssertEqual(v2Layer.has_value(), f >= 5 && f < 35, @"frame %lld", f);
        if (v2Layer) {
            const double overlayScale = frame.graph.layers[*v2Layer].transform.scale;
            const double held = f < 15 ? 0.2 : f < 25 ? 0.35 : 0.5;
            XCTAssertEqual(overlayScale, held, @"frame %lld: a hold keeps the keyframe's exact value", f);
            XCTAssertEqual(overlayScale, motionValuesAt(overlayed, frames30(f)).scale);
        }
        auto render = [&](const auto &graph) -> std::vector<double> {
            auto buffer = pool->makeBuffer();
            XCTAssertTrue(buffer.ok());
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
            auto rendered = created.value()->renderAndWait(graph, lookup, render::PixelBufferTarget{buffer.value()});
            XCTAssertTrue(rendered.ok() && rendered->status.ok() && rendered->skippedLayers.empty(), @"frame %lld", f);
            return blockMeans(buffer.value().get());
        };
        const std::vector<double> monitor = render(frame.graph);
        // The same frame with V1's animation taken away (its static values; V2 as it is): what the
        // picture would be without the spans, from the same decoded pictures.
        auto unanimated = frame.graph;
        unanimated.layers[*v1Layer].transform = animated.video;
        unanimated.layers[*v1Layer].opacity = animated.video.opacity;
        const double animationEffect = compare(render(unanimated), monitor).maxBlock;
        if (f == 0) {
            // The spans start at the identity at full opacity: the control, nothing to see.
            XCTAssertLessThan(animationEffect, 1.0, @"frame 0 shows the unanimated picture");
        } else if (expected.scale >= 1.2) {
            XCTAssertGreaterThan(animationEffect, 40.0, @"frame %lld: the spans move the picture visibly", f);
            ++movingFramesChecked;
        }
        XCTAssertTrue(decoder->decoder->seek(frames30(f)).ok());
        auto decoded = decoder->decoder->next();
        XCTAssertTrue(decoded.ok() && decoded.value(), @"exported frame %lld", f);
        if (!decoded.ok() || !decoded.value()) {
            continue;
        }
        const Difference d = compare(monitor, blockMeans(decoded.value()->image.get()));
        NSLog(@"PARITY animated frame %lld: blocks differ by at most %.2f, on average %.3f; the animation changes "
              @"blocks by up to %.2f",
              f, d.maxBlock, d.meanBlock, animationEffect);
        XCTAssertLessThan(d.maxBlock, 14.0, @"frame %lld: the export differs from the monitor", f);
        XCTAssertLessThan(d.meanBlock, 1.0, @"frame %lld", f);
    }
    XCTAssertGreaterThanOrEqual(movingFramesChecked, 5, @"the comparison covered frames the spans move");
}

- (void)testFadesFromAndToBlackExportTheMonitorsPictures {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    h.sequence().width = 640;
    h.sequence().height = 360;
    const AssetId movie = h.importAsset("h264_1080p30.mp4");
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    // V1: the movie from 1 s for 30 frames, fading in from black over its first 10 frames and out to
    // black over its last 10.
    const ClipId clip = h.addClip(h.v1, movie, 0, 30, CMTimeMake(1, 1));
    const SpanId in = h.addFade(clip, ClipEdge::Head, 10);
    const SpanId out = h.addFade(clip, ClipEdge::Tail, 10);
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();

    ex::ExportRequest request;
    request.project = std::make_shared<const Project>(h.project);
    request.sequenceId = h.sequenceId;
    request.encode.container = media::ContainerFormat::MOV;
    media::VideoEncodeSettings v;
    v.codec = media::VideoCodec::ProRes422;
    v.width = 640;
    v.height = 360;
    request.encode.video = v;
    request.outputPath = _dir + "/fades-parity.mov";
    ex::ExportServices services;
    services.router = h.router;
    services.cache = std::make_shared<media::FrameCache>();
    services.routing = routingOf(h.project, *h.router);
    std::string error;
    auto result = runExport(request, services, error);
    XCTAssertTrue(result.has_value(), @"%s", error.c_str());
    if (!result || !result->ok()) {
        XCTFail(@"export: %s", result ? result->error().description().c_str() : error.c_str());
        return;
    }
    auto created = render::Compositor::create(h.device(), {MTLPixelFormatRGBA16Float});
    auto pool = media::PixelBufferPool::create(kCVPixelFormatType_32BGRA, 640, 360);
    auto routed = h.router->probe(request.outputPath);
    XCTAssertTrue(created.ok() && pool.ok() && routed.ok());
    if (!created.ok() || !pool.ok() || !routed.ok()) {
        return;
    }
    media::DecodeOptions bgra;
    bgra.pixelFormat = kCVPixelFormatType_32BGRA;
    auto decoder = h.router->makeVideoDecoder(*routed, -1, bgra);
    XCTAssertTrue(decoder.ok());
    if (!decoder.ok()) {
        return;
    }
    auto meanOf = [](const std::vector<double> &blocks) {
        double sum = 0;
        for (const double b : blocks) {
            sum += b;
        }
        return blocks.empty() ? 0.0 : sum / double(blocks.size());
    };
    std::map<int64_t, double> brightness;
    for (int64_t f : {0, 4, 9, 10, 15, 19, 20, 25, 29}) {
        h.controller->seek(frames30(f));
        const PlaybackHarness::Sample sample = h.presentExact();
        XCTAssertEqual(sample.presented.frameIndex, f);
        const render::PreviewFrame &frame = h.frame();
        XCTAssertEqual(frame.graph.layers.size(), 1u, @"frame %lld", f);
        if (frame.graph.layers.size() != 1) {
            continue;
        }
        // The layer carries the fade the frame is in, with the linear progress at the frame's centre
        // (frame k of a 10-frame fade: (k + 0.5) / 10).
        const std::optional<LayerTransition> &fade = frame.graph.layers[0].transition;
        if (f < 10) {
            XCTAssertTrue(fade && fade->role == TransitionRole::FadeIn && fade->transitionId == in && fade->isIncoming,
                          @"frame %lld", f);
            XCTAssertEqualWithAccuracy(fade ? fade->weight() : -1, (double(f) + 0.5) / 10.0, 1e-12, @"frame %lld", f);
        } else if (f >= 20) {
            XCTAssertTrue(fade && fade->role == TransitionRole::FadeOut && fade->transitionId == out && !fade->isIncoming,
                          @"frame %lld", f);
            XCTAssertEqualWithAccuracy(fade ? fade->weight() : -1, 1.0 - (double(f - 20) + 0.5) / 10.0, 1e-12,
                                       @"frame %lld", f);
        } else {
            XCTAssertFalse(fade.has_value(), @"frame %lld is between the fades", f);
        }
        auto buffer = pool->makeBuffer();
        XCTAssertTrue(buffer.ok());
        if (!buffer.ok()) {
            continue;
        }
        auto lookup = [&](const VideoLayer &, std::size_t index, render::TextureSet &texture) {
            if (index >= frame.textures.size() || !frame.textures[index]) {
                return false;
            }
            texture = frame.textures[index];
            return true;
        };
        auto rendered = created.value()->renderAndWait(frame.graph, lookup, render::PixelBufferTarget{buffer.value()});
        XCTAssertTrue(rendered.ok() && rendered->status.ok() && rendered->skippedLayers.empty(), @"frame %lld", f);
        const std::vector<double> monitor = blockMeans(buffer.value().get());
        brightness[f] = meanOf(monitor);

        XCTAssertTrue(decoder->decoder->seek(frames30(f)).ok());
        auto decoded = decoder->decoder->next();
        XCTAssertTrue(decoded.ok() && decoded.value(), @"exported frame %lld", f);
        if (!decoded.ok() || !decoded.value()) {
            continue;
        }
        const Difference d = compare(monitor, blockMeans(decoded.value()->image.get()));
        NSLog(@"PARITY fade frame %lld: mean level %.2f; blocks differ by at most %.2f, on average %.3f", f,
              brightness[f], d.maxBlock, d.meanBlock);
        XCTAssertLessThan(d.maxBlock, 14.0, @"frame %lld: the export differs from the monitor", f);
        XCTAssertLessThan(d.meanBlock, 1.0, @"frame %lld", f);
    }
    // From black and back to it: the picture brightens through the fade in and darkens through the
    // fade out, starting and ending far darker than between the fades.
    XCTAssertLessThan(brightness[0], brightness[4]);
    XCTAssertLessThan(brightness[4], brightness[9]);
    XCTAssertGreaterThan(brightness[20], brightness[25]);
    XCTAssertGreaterThan(brightness[25], brightness[29]);
    XCTAssertLessThan(brightness[0], brightness[15] / 2);
    XCTAssertLessThan(brightness[29], brightness[15] / 2);
}

@end
