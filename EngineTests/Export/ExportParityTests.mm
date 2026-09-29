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
//   Gain span ramping one clip down and holding the lower level after its end, and a +12 dB clip
//   that drives the sum into clipping.
// - Held Gain (effect lanes round 1b): the offline renderer's mix of a clip whose Gain spans duck,
//   hold, swell from the held level and hold again is, sample for sample, the unspanned mix at the
//   level the model composes (gainDbAt), so the hold reaches the export's sound.
// - Effect spans on two lanes (effect lanes, open finding 8 before them): a clip whose position,
//   scale, rotation and opacity are animated by Motion spans on two lanes and an Opacity span on a
//   third (ease in and out, linear, hold; composed onto a static offset), under a still whose scale
//   a Motion span steps (hold), exports the pictures the program monitor shows frame by frame; the
//   monitor's layers carry the composed values at each frame (so the comparison is over moving
//   pictures), each span holding its end values after its end.
// - The hold-after reference case: a 30 s clip with a 5 s Ken Burns move from 5 s to 10 s shows its
//   own framing for 0-5 s, the move over 5-10 s and the end framing, exactly, for 10-30 s, on the
//   monitor and in the export alike.
// - Fades from and to black: a clip with a lane-0 fade at each end exports the monitor's pictures,
//   and the pictures go from black and back to it.
// - Variable frame rate (UX round review, test gap 1): a VFR clip through each backend exports the
//   same source frames the monitor shows, and both are the frames containing the exact source time.

#import <XCTest/XCTest.h>

#include "../../Engine/Audio/OfflineAudioRenderer.h"
#include "../../Engine/Edit/EditOps.h"
#include "../../Engine/Export/ExportJob.h"
#include "../../Engine/Media/AssetImport.h"
#include "../../Engine/Render/Compositor.h"
#include "../../Engine/Render/Scheduler.h"
#include "../Media/BurnIn.h"
#include "../Media/FFmpegTestMedia.h"
#include "../Media/TestMedia.h"
#include "../Media/TextCard.h"
#include "../Playback/PlaybackTestSupport.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

#include <algorithm>
#include <cmath>
#include <cstring>
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

/// kBlock x kBlock block means of the luma plane of a biplanar 8-bit YCbCr buffer (the codes as stored).
std::vector<double> lumaBlockMeans(CVPixelBufferRef buffer) {
    const size_t w = CVPixelBufferGetWidthOfPlane(buffer, 0), h = CVPixelBufferGetHeightOfPlane(buffer, 0);
    std::vector<double> out((w / kBlock) * (h / kBlock), 0.0);
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
    const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
    for (size_t by = 0; by < h / kBlock; ++by) {
        for (size_t bx = 0; bx < w / kBlock; ++bx) {
            double sum = 0;
            for (size_t y = by * kBlock; y < by * kBlock + kBlock; ++y) {
                for (size_t x = bx * kBlock; x < bx * kBlock + kBlock; ++x) {
                    sum += base[y * stride + x];
                }
            }
            out[by * (w / kBlock) + bx] = sum / double(kBlock * kBlock);
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return out;
}

/// Renders the harness's current frame (the program monitor's graph and textures) into a 32BGRA buffer of
/// the pool's size, as the preview view composites it; false when a layer has no picture.
bool renderMonitorFrame(PlaybackHarness &h, render::Compositor &compositor, media::PixelBufferPool &pool,
                        media::PixelBuffer &out, render::RenderResult *resultOut = nullptr) {
    const render::PreviewFrame &frame = h.frame();
    auto buffer = pool.makeBuffer();
    if (!buffer.ok()) {
        return false;
    }
    auto lookup = [&](const VideoLayer &, std::size_t index, render::TextureSet &texture) {
        if (index >= frame.textures.size() || !frame.textures[index]) {
            return false;
        }
        texture = frame.textures[index];
        return true;
    };
    auto rendered = compositor.renderAndWait(frame.graph, lookup, render::PixelBufferTarget{buffer.value()});
    if (!rendered.ok() || !rendered->status.ok() || !rendered->skippedLayers.empty()) {
        return false;
    }
    if (resultOut != nullptr) {
        *resultOut = rendered.value();
    }
    out = std::move(buffer).value();
    return true;
}

/// Frames `frames` of the movie at `path` decoded to `pixelFormat` (32BGRA by default), keyed by frame
/// index (at `fps`).
std::map<int64_t, media::PixelBuffer> decodeFrames(const media::BackendRouter &router, const std::string &path,
                                                   const std::vector<int64_t> &frames, int32_t fps,
                                                   OSType pixelFormat = kCVPixelFormatType_32BGRA) {
    std::map<int64_t, media::PixelBuffer> decoded;
    auto routed = router.probe(path);
    if (!routed.ok()) {
        return decoded;
    }
    media::DecodeOptions options;
    options.pixelFormat = pixelFormat;
    auto decoder = router.makeVideoDecoder(*routed, -1, options);
    if (!decoder.ok()) {
        return decoded;
    }
    for (int64_t f : frames) {
        if (!decoder->decoder->seek(CMTimeMake(f, fps)).ok()) {
            continue;
        }
        auto next = decoder->decoder->next();
        if (next.ok() && next.value()) {
            decoded[f] = next.value()->image;
        }
    }
    return decoded;
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

/// A 4K sequence made the way a new project makes it (the settings adopted from its first video clip, a
/// 3840x2160 screen recording with small text) exported at its own size, 3840x2160 (ProRes 422), shows
/// the program monitor's pictures: 16x16 block means within the codec's error on every frame compared,
/// and another frame (the text cursor moved) is told apart.
- (void)testA4KSequenceExportsTheMonitorsPicturesAtItsOwnSize {
    const std::string moviePath = _dir + "/text4k.mov";
    const std::string written = writeTextCardMovie(moviePath, 3840, 2160, 12, 30, 60'000'000, 22, false, 4);
    XCTAssertTrue(written.empty(), @"%s", written.c_str());
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    const AssetId movie = h.importAssetAtPath(moviePath);
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    // The settings a new project's sequence takes from it: 3840x2160 at 30 fps.
    SequenceFormat unconfigured = h.sequence().format();
    unconfigured.configured = false;
    h.sequence().setFormat(unconfigured);
    const auto adopted = formatAdoptedFrom(*h.project.findAsset(movie), unconfigured);
    XCTAssertTrue(adopted.has_value());
    if (!adopted) {
        return;
    }
    SetSequenceFormat adopt(h.sequenceId, *adopted);
    XCTAssertTrue(adopt.apply(h.project).ok());
    XCTAssertEqual(h.sequence().width, 3840);
    XCTAssertEqual(h.sequence().height, 2160);
    h.addClip(h.v1, movie, 0, 12, kCMTimeZero);
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();

    const int width = h.sequence().width, height = h.sequence().height;
    ex::ExportRequest request;
    request.project = std::make_shared<const Project>(h.project);
    request.sequenceId = h.sequenceId;
    request.encode.container = media::ContainerFormat::MOV;
    media::VideoEncodeSettings v;
    v.codec = media::VideoCodec::ProRes422;
    v.width = width;
    v.height = height;
    request.encode.video = v;
    request.outputPath = _dir + "/parity4k.mov";
    ex::ExportServices services;
    services.router = h.router;
    services.cache = std::make_shared<media::FrameCache>();
    services.routing = routingOf(h.project, *h.router);
    std::string error;
    auto result = runExport(request, services, error);
    if (!result || !result->ok()) {
        XCTFail(@"export: %s", result ? result->error().description().c_str() : error.c_str());
        return;
    }
    XCTAssertEqual(result->value().width, 3840);
    XCTAssertEqual(result->value().height, 2160);

    auto created = render::Compositor::create(h.device(), {MTLPixelFormatRGBA16Float});
    auto pool = media::PixelBufferPool::create(kCVPixelFormatType_32BGRA, size_t(width), size_t(height));
    XCTAssertTrue(created.ok() && pool.ok());
    if (!created.ok() || !pool.ok()) {
        return;
    }
    const std::vector<int64_t> frames{0, 3, 4, 8, 11};
    std::map<int64_t, std::vector<double>> monitor;
    for (int64_t f : frames) {
        h.controller->seek(frames30(f));
        h.presentExact();
        media::PixelBuffer picture;
        XCTAssertTrue(renderMonitorFrame(h, *created.value(), *pool, picture), @"frame %lld", f);
        if (picture) {
            monitor[f] = blockMeans(picture.get());
        }
    }
    const auto exported = decodeFrames(*h.router, request.outputPath, frames, 30);
    XCTAssertEqual(exported.size(), frames.size());
    for (const auto &[f, buffer] : exported) {
        XCTAssertEqual(CVPixelBufferGetWidth(buffer.get()), 3840u);
        if (!monitor.count(f)) {
            continue;
        }
        const Difference d = compare(monitor[f], blockMeans(buffer.get()));
        NSLog(@"PARITY 4K frame %lld: blocks differ by at most %.2f, on average %.3f", f, d.maxBlock, d.meanBlock);
        XCTAssertLessThan(d.maxBlock, 14.0, @"frame %lld", f);
        XCTAssertLessThan(d.meanBlock, 1.0, @"frame %lld", f);
    }
    // Frame 3 and frame 4 differ only by the cursor and a word: the measure still tells them apart.
    if (monitor.count(3) && exported.count(4)) {
        const Difference other = compare(monitor[3], blockMeans(exported.at(4).get()));
        NSLog(@"PARITY 4K monitor frame 3 vs exported frame 4: %.1f", other.maxBlock);
        XCTAssertGreaterThan(other.maxBlock, 40.0);
    }
}

/// A 3840x2160 screen recording with small text in a 1920x1080 sequence (the picture drawn at half its
/// size: Lanczos pre-scaled and, with "Sharpen scaled-down sources" on, sharpened): the export (ProRes 422)
/// shows the monitor's sharpened pictures, and it is sharper than the same export with the setting off
/// (the edge measure of its text), so the sharpening reached it. Both sides are compared as luma codes:
/// the monitor's frame composited into a '420v' buffer by the compositor's own conversion, the export
/// decoded to '420v'. (Decoded to 32BGRA the export's mid-greys come out about 3 codes darker than the
/// monitor's composite, sharpened or not: the decoder's own YCbCr-to-RGB conversion, which this picture
/// of anti-aliased grey text shows far more than the other parity tests' pictures do.)
- (void)testAMinifiedSharpenedSourceExportsTheMonitorsPictures {
    const std::string moviePath = _dir + "/text4k-in-hd.mov";
    const std::string written = writeTextCardMovie(moviePath, 3840, 2160, 10, 30, 60'000'000, 22, false, 4);
    XCTAssertTrue(written.empty(), @"%s", written.c_str());
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    const AssetId movie = h.importAssetAtPath(moviePath);
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    XCTAssertEqual(h.sequence().width, 1920);
    XCTAssertTrue(h.project.sharpenScaledDownSources);
    h.addClip(h.v1, movie, 0, 10, kCMTimeZero);
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();

    auto exportTo = [&](const std::string &path, bool sharpen) -> bool {
        Project project = h.project;
        project.sharpenScaledDownSources = sharpen;
        ex::ExportRequest request;
        request.project = std::make_shared<const Project>(project);
        request.sequenceId = h.sequenceId;
        request.encode.container = media::ContainerFormat::MOV;
        media::VideoEncodeSettings v;
        v.codec = media::VideoCodec::ProRes422;
        v.width = 1920;
        v.height = 1080;
        request.encode.video = v;
        request.outputPath = path;
        ex::ExportServices services;
        services.router = h.router;
        services.cache = std::make_shared<media::FrameCache>();
        services.routing = routingOf(project, *h.router);
        std::string error;
        auto result = runExport(request, services, error);
        if (!result || !result->ok()) {
            XCTFail(@"export: %s", result ? result->error().description().c_str() : error.c_str());
            return false;
        }
        return true;
    };
    const std::string sharpened = _dir + "/sharpened.mov", plain = _dir + "/plain.mov";
    if (!exportTo(sharpened, true) || !exportTo(plain, false)) {
        return;
    }
    auto created = render::Compositor::create(h.device(), {MTLPixelFormatRGBA16Float});
    auto pool = media::PixelBufferPool::create(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 1920, 1080);
    XCTAssertTrue(created.ok() && pool.ok());
    if (!created.ok() || !pool.ok()) {
        return;
    }
    const std::vector<int64_t> frames{0, 4, 9};
    // The monitor's pictures with the setting on, then off (the same edit published to the controller).
    auto monitorFrames = [&](bool sharpen) {
        h.project.sharpenScaledDownSources = sharpen;
        h.publishEdit();
        std::map<int64_t, std::vector<double>> means;
        for (int64_t f : frames) {
            h.controller->seek(frames30(f));
            h.presentExact();
            media::PixelBuffer picture;
            render::RenderResult rendered;
            XCTAssertTrue(renderMonitorFrame(h, *created.value(), *pool, picture, &rendered), @"frame %lld", f);
            XCTAssertEqual(rendered.prescaledPlanes, 1u);
            XCTAssertEqual(rendered.sharpenedPlanes, sharpen ? 1u : 0u, @"the monitor sharpens the luma plane");
            if (picture) {
                means[f] = lumaBlockMeans(picture.get());
            }
        }
        return means;
    };
    const auto monitorSharp = monitorFrames(true);
    const auto monitorPlain = monitorFrames(false);
    const auto exported = decodeFrames(*h.router, sharpened, frames, 30, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    const auto unsharpened = decodeFrames(*h.router, plain, frames, 30, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    const auto exportedRGB = decodeFrames(*h.router, sharpened, frames, 30);
    const auto unsharpenedRGB = decodeFrames(*h.router, plain, frames, 30);
    XCTAssertEqual(exported.size(), frames.size());
    XCTAssertEqual(unsharpened.size(), frames.size());
    for (int64_t f : frames) {
        if (!exported.count(f) || !unsharpened.count(f) || !monitorSharp.count(f) || !monitorPlain.count(f)) {
            continue;
        }
        const Difference d = compare(monitorSharp.at(f), lumaBlockMeans(exported.at(f).get()));
        const Difference plainPair = compare(monitorPlain.at(f), lumaBlockMeans(unsharpened.at(f).get()));
        const Difference crossed = compare(monitorSharp.at(f), lumaBlockMeans(unsharpened.at(f).get()));
        NSLog(@"PARITY sharpened frame %lld: luma blocks differ by at most %.2f, on average %.3f (unsharpened pair "
              @"%.2f, %.3f; the sharpened monitor against the unsharpened export %.2f, %.3f)",
              f, d.maxBlock, d.meanBlock, plainPair.maxBlock, plainPair.meanBlock, crossed.maxBlock, crossed.meanBlock);
        XCTAssertLessThan(d.maxBlock, 14.0, @"frame %lld", f);
        XCTAssertLessThan(d.meanBlock, 1.0, @"frame %lld", f);
        XCTAssertLessThan(plainPair.meanBlock, 1.0, @"frame %lld", f);
        XCTAssertGreaterThan(crossed.meanBlock, d.meanBlock * 2, @"frame %lld: the measure sees the sharpening", f);
        if (exportedRGB.count(f) && unsharpenedRGB.count(f)) {
            const double sharp = edgeMeasure(grayOf(exportedRGB.at(f).get()), 100, 100, 1700, 880);
            const double soft = edgeMeasure(grayOf(unsharpenedRGB.at(f).get()), 100, 100, 1700, 880);
            NSLog(@"PARITY sharpened frame %lld: edge measure %.4f, %.4f without sharpening", f, sharp, soft);
            XCTAssertGreaterThan(sharp, soft * 1.1, @"frame %lld: the export is sharpened", f);
        }
    }
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
    // clips, ramped down 18 dB by a Gain span over [1.5 s, 3 s) of the timeline (an ease in) and
    // held there for its last second.
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
    ducked.time = CMTimeMake(3, 2);
    ducked.value = -18;
    duck.gain = {level, ducked};
    h.addSpan(loud, SpanKind::Gain, 1, CMTimeMake(5, 2), CMTimeMake(4, 1), duck);
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
            const bool acting = spanActsAt(growSpan, *at);
            XCTAssertEqual(acting, f >= 15, @"frame %lld: from its start on, holding after its end", f);
            const double factor = spanContributionAt(growSpan, SpanParameter::Scale, *at);
            const double turn = spanContributionAt(growSpan, SpanParameter::Rotation, *at);
            XCTAssertEqualWithAccuracy(shown.scale, withoutGrow.scale * factor, 1e-12, @"frame %lld", f);
            XCTAssertEqualWithAccuracy(shown.rotationDegrees, withoutGrow.rotationDegrees + turn, 1e-12, @"frame %lld", f);
            // Frame f shows source frame 30 + f: lane 2's frame f - 15 of its 15, then its end
            // values held (a 20% growth and 10 degrees).
            const double wantFactor = f < 15 ? 1.0 : f < 30 ? 1.0 + 0.2 * double(f - 15) / 15.0 : 1.2;
            XCTAssertEqualWithAccuracy(factor, wantFactor, 1e-12, @"frame %lld", f);
            if (f >= 30) {
                XCTAssertEqual(factor, 1.2, @"frame %lld: the end value, held exactly", f);
                XCTAssertEqual(turn, 10.0, @"frame %lld", f);
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

/// Shaped transitions (wipes and the iris): V1 is the movie from 1 s for 30 frames, starting with a
/// 10-frame Wipe Right fade in from black, a Wipe Left over the 10 frames around the cut (5 before, 5
/// after) into the movie from 5 s, which ends in a 10-frame Iris fade out to black at the free end (a
/// closing iris). Every sampled frame of the export shows the monitor's picture; the fade in's first frame
/// and the iris's last are black; mid-wipe the right of the frame shows the incoming picture and the left
/// does not, and mid-iris the picture stays inside a disc at the centre while black has come in at the
/// corners.
- (void)testAWipeAndAnIrisExportTheMonitorsPictures {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    h.sequence().width = 640;
    h.sequence().height = 360;
    const AssetId movie = h.importAsset("h264_1080p30.mp4");
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    const ClipId a = h.addClip(h.v1, movie, 0, 30, CMTimeMake(1, 1));
    const ClipId b = h.addClip(h.v1, movie, 30, 30, CMTimeMake(5, 1));
    const SpanId fadeIn = h.addFade(a, ClipEdge::Head, 10);
    const SpanId wipe = h.addTailTransition(a, 5, 5);
    const SpanId iris = h.addFade(b, ClipEdge::Tail, 10);
    h.sequence().findSpan(fadeIn)->transition = TransitionKind::WipeRight;
    h.sequence().findSpan(wipe)->transition = TransitionKind::WipeLeft;
    h.sequence().findSpan(iris)->transition = TransitionKind::Iris;
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
    request.outputPath = _dir + "/shapes-parity.mov";
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
    // The monitor's picture of `graph` (the frame the controller presents) as 16x16 block means.
    auto monitorBlocks = [&](const render::PreviewFrame &frame) -> std::optional<std::vector<double>> {
        auto buffer = pool->makeBuffer();
        if (!buffer.ok()) {
            return std::nullopt;
        }
        auto lookup = [&](const VideoLayer &, std::size_t index, render::TextureSet &texture) {
            if (index >= frame.textures.size() || !frame.textures[index]) {
                return false;
            }
            texture = frame.textures[index];
            return true;
        };
        auto rendered = created.value()->renderAndWait(frame.graph, lookup, render::PixelBufferTarget{buffer.value()});
        if (!rendered.ok() || !rendered->status.ok() || !rendered->skippedLayers.empty()) {
            return std::nullopt;
        }
        return blockMeans(buffer.value().get());
    };
    std::map<int64_t, std::vector<double>> exported;
    std::map<int64_t, std::vector<double>> monitor;
    for (int64_t f : {0, 4, 9, 20, 25, 27, 29, 30, 32, 34, 35, 45, 50, 52, 55, 57, 59}) {
        h.controller->seek(frames30(f));
        const PlaybackHarness::Sample sample = h.presentExact();
        XCTAssertEqual(sample.presented.frameIndex, f);
        const render::PreviewFrame &frame = h.frame();
        const bool inFadeIn = f < 10;
        const bool inWipe = f >= 25 && f < 35;
        const bool inIris = f >= 50;
        XCTAssertEqual(frame.graph.layers.size(), inWipe ? 2u : 1u, @"frame %lld", f);
        for (const VideoLayer &layer : frame.graph.layers) {
            if (inFadeIn) {
                XCTAssertTrue(layer.transition && layer.transition->kind == TransitionKind::WipeRight &&
                                  layer.transition->role == TransitionRole::FadeIn,
                              @"frame %lld", f);
            } else if (inWipe) {
                XCTAssertTrue(layer.transition && layer.transition->kind == TransitionKind::WipeLeft &&
                                  layer.transition->transitionId == wipe,
                              @"frame %lld", f);
            } else if (inIris) {
                XCTAssertTrue(layer.transition && layer.transition->kind == TransitionKind::Iris &&
                                  layer.transition->role == TransitionRole::FadeOut,
                              @"frame %lld", f);
            } else {
                XCTAssertFalse(layer.transition.has_value(), @"frame %lld", f);
            }
        }
        const auto blocks = monitorBlocks(frame);
        XCTAssertTrue(blocks.has_value(), @"frame %lld", f);
        if (!blocks) {
            continue;
        }
        monitor[f] = *blocks;
        XCTAssertTrue(decoder->decoder->seek(frames30(f)).ok());
        auto decoded = decoder->decoder->next();
        XCTAssertTrue(decoded.ok() && decoded.value(), @"exported frame %lld", f);
        if (!decoded.ok() || !decoded.value()) {
            continue;
        }
        exported[f] = blockMeans(decoded.value()->image.get());
        const Difference d = compare(monitor[f], exported[f]);
        NSLog(@"PARITY shape frame %lld: blocks differ by at most %.2f, on average %.3f", f, d.maxBlock, d.meanBlock);
        XCTAssertLessThan(d.maxBlock, 14.0, @"frame %lld: the export differs from the monitor", f);
        XCTAssertLessThan(d.meanBlock, 1.0, @"frame %lld", f);
    }
    // Mid-wipe (frame 30, progress 0.55: the edge about 288 px from the right): the right column of
    // blocks is the incoming clip's picture exactly, the left one is not (it is the outgoing clip's
    // handle, which no frame inside that clip shows, so it is compared with the incoming picture).
    const size_t columns = 640 / kBlock;
    auto column = [&](const std::vector<double> &blocks, size_t x) {
        std::vector<double> c;
        for (size_t row = 0; row < 360 / kBlock; ++row) {
            for (int ch = 0; ch < 3; ++ch) {
                c.push_back(blocks[(row * columns + x) * 3 + size_t(ch)]);
            }
        }
        return c;
    };
    // `clip`'s picture alone at frame `f` (the solo preview, identity placement as the clip has).
    auto alone = [&](ClipId clip, int64_t f) -> std::optional<std::vector<double>> {
        h.controller->setPreviewSolo(playback::PlaybackController::PreviewSolo{clip, true});
        h.controller->seek(frames30(f));
        (void)h.presentExact();
        auto blocks = monitorBlocks(h.frame());
        h.controller->setPreviewSolo(std::nullopt);
        return blocks;
    };
    if (monitor.count(30)) {
        const auto bAlone = alone(b, 30);
        XCTAssertTrue(bAlone.has_value());
        if (bAlone) {
            const Difference right = compare(column(monitor[30], columns - 1), column(*bAlone, columns - 1));
            const Difference left = compare(column(monitor[30], 0), column(*bAlone, 0));
            NSLog(@"PARITY mid-wipe: right column vs B alone %.2f, left column vs B alone %.2f", right.maxBlock,
                  left.maxBlock);
            XCTAssertLessThan(right.maxBlock, 1.0, @"the right of the frame shows the incoming picture");
            XCTAssertGreaterThan(left.maxBlock, 20.0, @"the left of the frame still shows the outgoing picture");
        }
    }
    if (monitor.count(55)) {
        // Mid-iris (frame 55 of the closing iris, exposed over [0.6, 0.7] of the fade out): the picture
        // stays inside the shrinking disc, a radius of 0.3 to 0.4 of the half diagonal, so the centre keeps
        // the picture and the corners are black.
        const auto bAlone = alone(b, 55);
        XCTAssertTrue(bAlone.has_value());
        if (bAlone) {
            const size_t rows = 360 / kBlock;
            const size_t centre = (rows / 2) * columns + columns / 2;
            const size_t corner = 0;
            for (int ch = 0; ch < 3; ++ch) {
                XCTAssertEqualWithAccuracy(monitor[55][centre * 3 + size_t(ch)], (*bAlone)[centre * 3 + size_t(ch)], 1.0,
                                           @"the centre shows the picture");
                XCTAssertLessThan(monitor[55][corner * 3 + size_t(ch)], 1.0, @"the corner is black");
                if (exported.count(55)) {
                    XCTAssertLessThan(exported[55][corner * 3 + size_t(ch)], 1.0, @"the exported corner is black");
                }
            }
        }
    }
    // The fade in's first frame and the closing iris's last frame are wholly black, on the monitor and in
    // the export.
    for (const int64_t f : {int64_t(0), int64_t(59)}) {
        XCTAssertTrue(monitor.count(f) && exported.count(f), @"frame %lld", f);
        if (!monitor.count(f) || !exported.count(f)) {
            continue;
        }
        const double brightestMonitor = *std::max_element(monitor[f].begin(), monitor[f].end());
        const double brightestExport = *std::max_element(exported[f].begin(), exported[f].end());
        XCTAssertEqual(brightestMonitor, 0.0, @"frame %lld: the monitor's picture is black", f);
        XCTAssertLessThan(brightestExport, 1.0, @"frame %lld: the exported picture is black", f);
    }
}

/// Exports `h`'s sequence as ProRes 422 at `width` x `height` to `path` and decodes every frame to
/// 32BGRA; empty on failure (reported).
- (std::vector<media::PixelBuffer>)exportAndDecode:(PlaybackHarness &)h
                                              path:(const std::string &)path
                                            frames:(int64_t)frames {
    ex::ExportRequest request;
    request.project = std::make_shared<const Project>(h.project);
    request.sequenceId = h.sequenceId;
    request.encode.container = media::ContainerFormat::MOV;
    media::VideoEncodeSettings v;
    v.codec = media::VideoCodec::ProRes422;
    v.width = 640;
    v.height = 360;
    request.encode.video = v;
    request.outputPath = path;
    ex::ExportServices services;
    services.router = h.router;
    services.cache = std::make_shared<media::FrameCache>();
    services.routing = routingOf(h.project, *h.router);
    std::string error;
    auto result = runExport(request, services, error);
    if (!result || !result->ok()) {
        XCTFail(@"export: %s", result ? result->error().description().c_str() : error.c_str());
        return {};
    }
    auto routed = h.router->probe(path);
    XCTAssertTrue(routed.ok());
    if (!routed.ok()) {
        return {};
    }
    media::DecodeOptions bgra;
    bgra.pixelFormat = kCVPixelFormatType_32BGRA;
    auto decoder = h.router->makeVideoDecoder(*routed, -1, bgra);
    XCTAssertTrue(decoder.ok());
    if (!decoder.ok()) {
        return {};
    }
    std::vector<media::PixelBuffer> decoded;
    XCTAssertTrue(decoder->decoder->seek(kCMTimeZero).ok());
    for (int64_t f = 0; f < frames; ++f) {
        auto next = decoder->decoder->next();
        XCTAssertTrue(next.ok() && next.value(), @"exported frame %lld", f);
        if (!next.ok() || !next.value()) {
            return {};
        }
        decoded.push_back(next.value()->image);
    }
    return decoded;
}

/// A reversed clip (Clip.h "Reverse"): V1 is the movie from 1 s for 30 frames with its sound on A1,
/// linked. Exported forward and then reversed (SetClipReversed on the same project): frame k of the
/// reversed export is frame n - 1 - k of the forward export, pixel for pixel (and by the burn-in, the
/// same source frame); every reversed frame shows the monitor's picture; the reversed export's sound
/// is the forward export's sound sample-reversed over the clip, within 1e-6 (speed 1 here, and a
/// second clip at 3/2 resampled after the mirror), and the playback mixer plays what the export
/// writes.
- (void)testAReversedClipExportsTheForwardExportBackwards {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    h.sequence().width = 640;
    h.sequence().height = 360;
    const AssetId movie = h.importAsset("h264_1080p30.mp4");
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    const ClipId clip = h.addClip(h.v1, movie, 0, 30, CMTimeMake(1, 1));
    const ClipId sound = h.addClip(h.a1, movie, 0, 30, CMTimeMake(1, 1));
    h.link(clip, sound);
    // A 3/2 clip after it on A1 (sound only): 45 frames of source from 4 s over 30 timeline frames.
    const ClipId fast = h.addClip(h.a1, movie, 40, 30, CMTimeMake(4, 1));
    h.sequence().findClip(fast)->speed = Ratio{3, 2};
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();
    const Project forwardProject = h.project;
    const int64_t n = 30;
    const std::vector<media::PixelBuffer> forward = [self exportAndDecode:h path:_dir + "/forward.mov" frames:n];

    for (const ClipId id : {clip, fast}) {
        SetClipReversed reverse(h.sequenceId, id, true);
        const EditResult r = reverse.apply(h.project);
        XCTAssertTrue(r.ok(), @"%s", r.message.c_str());
    }
    XCTAssertTrue(h.sequence().findClip(sound)->reversed);
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();
    const std::vector<media::PixelBuffer> backward = [self exportAndDecode:h path:_dir + "/reversed.mov" frames:n];
    XCTAssertEqual(forward.size(), size_t(n));
    XCTAssertEqual(backward.size(), size_t(n));
    if (forward.size() != size_t(n) || backward.size() != size_t(n)) {
        return;
    }
    auto samePixels = [](CVPixelBufferRef a, CVPixelBufferRef b) {
        CVPixelBufferLockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferLockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
        bool same = CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b) &&
                    CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b);
        const auto *pa = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(a));
        const auto *pb = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(b));
        for (size_t y = 0; same && y < CVPixelBufferGetHeight(a); ++y) {
            same = std::memcmp(pa + y * CVPixelBufferGetBytesPerRow(a), pb + y * CVPixelBufferGetBytesPerRow(b),
                               CVPixelBufferGetWidth(a) * 4) == 0;
        }
        CVPixelBufferUnlockBaseAddress(b, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferUnlockBaseAddress(a, kCVPixelBufferLock_ReadOnly);
        return same;
    };
    for (int64_t k = 0; k < n; ++k) {
        const media::PixelBuffer &mine = backward[size_t(k)];
        const media::PixelBuffer &theirs = forward[size_t(n - 1 - k)];
        XCTAssertTrue(samePixels(mine.get(), theirs.get()), @"reversed frame %lld == forward frame %lld", k, n - 1 - k);
        const auto a = readBurnIn(mine.get());
        const auto b = readBurnIn(theirs.get());
        XCTAssertTrue(a.has_value() && b.has_value() && *a == *b && *a == 30 + (n - 1 - k),
                      @"frame %lld shows source frame %d (forward frame %lld: %d)", k, a.value_or(-1), n - 1 - k,
                      b.value_or(-1));
    }
    // The monitor shows what the reversed export wrote.
    auto created = render::Compositor::create(h.device(), {MTLPixelFormatRGBA16Float});
    auto pool = media::PixelBufferPool::create(kCVPixelFormatType_32BGRA, 640, 360);
    XCTAssertTrue(created.ok() && pool.ok());
    if (!created.ok() || !pool.ok()) {
        return;
    }
    for (int64_t f : {0, 7, 15, 29}) {
        h.controller->seek(frames30(f));
        const PlaybackHarness::Sample sample = h.presentExact();
        XCTAssertEqual(sample.presented.frameIndex, f);
        XCTAssertEqual(sample.burnIns.front().value_or(-1), 30 + (n - 1 - f), @"monitor frame %lld", f);
        const render::PreviewFrame &frame = h.frame();
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
        const Difference d = compare(blockMeans(buffer.value().get()), blockMeans(backward[size_t(f)].get()));
        XCTAssertLessThan(d.maxBlock, 14.0, @"frame %lld: the export differs from the monitor", f);
        XCTAssertLessThan(d.meanBlock, 1.0, @"frame %lld", f);
    }

    // Sound: the offline mixes (what an export writes) of both projects.
    auto mixOf = [&](const Project &project) {
        audio::OfflineAudioRenderer offline(h.router, std::make_shared<const Project>(project), h.sequenceId,
                                            routingOf(project, *h.router), audio::OfflineAudioRenderer::Config{});
        std::vector<float> mixed;
        std::vector<float> block(1024 * 2);
        for (;;) {
            auto rendered = offline.render(block.data(), 1024, [] { return false; });
            XCTAssertTrue(rendered.ok(), @"%s", rendered.ok() ? "" : rendered.error().description().c_str());
            if (!rendered.ok() || rendered.value() == 0) {
                break;
            }
            mixed.insert(mixed.end(), block.begin(), block.begin() + rendered.value() * 2);
        }
        return mixed;
    };
    const std::vector<float> forwardMix = mixOf(forwardProject);
    const std::vector<float> reversedMix = mixOf(h.project);
    XCTAssertEqual(forwardMix.size(), reversedMix.size());
    for (const auto &[first, last] : {std::pair<int64_t, int64_t>{0, 30}, std::pair<int64_t, int64_t>{40, 70}}) {
        const int64_t n0 = first * 1600;
        const int64_t n1 = last * 1600;
        double worst = 0;
        double energy = 0;
        for (int64_t i = n0; i < n1 && size_t(n1 * 2) <= forwardMix.size(); ++i) {
            for (int ch = 0; ch < 2; ++ch) {
                const double a = reversedMix[size_t(i * 2 + ch)];
                const double b = forwardMix[size_t((n0 + n1 - 1 - i) * 2 + ch)];
                worst = std::max(worst, std::fabs(a - b));
                energy += b * b;
            }
        }
        NSLog(@"PARITY reversed audio over frames [%lld, %lld): max |reversed - forward backwards| %.3g", first, last,
              worst);
        XCTAssertGreaterThan(energy, 1.0, @"frames [%lld, %lld) have sound", first, last);
        XCTAssertLessThan(worst, 1e-6, @"frames [%lld, %lld): the reversed sound is the forward sound backwards",
                          first, last);
    }

}

/// The playback mixer plays a reversed clip's sound as the export writes it: A1 holds the movie from
/// 1 s reversed at speed 1 for 2 s, then from 4 s reversed at 3/2 for 1.5 s; played in real time and
/// captured, it equals the offline mix sample for sample (1e-5, as the forward parity test).
- (void)testAReversedClipPlaysTheSoundTheExportWrites {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 5.0);
    const AssetId movie = h.importAsset("h264_1080p30.mp4");
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    const ClipId plain = h.addClip(h.a1, movie, 0, 60, CMTimeMake(1, 1));
    const ClipId fast = h.addClip(h.a1, movie, 60, 45, CMTimeMake(4, 1));
    h.sequence().findClip(fast)->speed = Ratio{3, 2};
    for (const ClipId id : {plain, fast}) {
        SetClipReversed reverse(h.sequenceId, id, true);
        const EditResult r = reverse.apply(h.project);
        XCTAssertTrue(r.ok(), @"%s", r.message.c_str());
    }
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();
    h.controller->seek(kCMTimeZero);
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    XCTAssertTrue(h.waitForState(playback::PlaybackState::Stopped, std::chrono::seconds(15)), @"played to the end");
    const audio::NullAudioOutput::Capture capture = h.output->capture();
    XCTAssertEqual(h.controller->stats().audioUnderruns, 0u, @"the reversed sources kept up");

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
    XCTAssertEqual(int64_t(mixed.size() / 2), int64_t(3.5 * 48000));
    const int64_t from = std::max<int64_t>(0, capture.firstSequenceSample);
    const int64_t count = std::min<int64_t>(int64_t(capture.samples.size() / 2), int64_t(mixed.size() / 2) - from);
    XCTAssertGreaterThan(count, 3 * 48000, @"most of the sequence was captured");
    double worst = 0;
    int64_t worstAt = -1;
    for (int64_t i = 0; i < count * 2; ++i) {
        const double d = std::fabs(double(capture.samples[size_t(i)]) - mixed[size_t(from * 2 + i)]);
        if (d > worst) {
            worst = d;
            worstAt = from + i / 2;
        }
    }
    NSLog(@"PARITY reversed playback: %lld frames compared, max |playback - export| %.3g at sample %lld", count, worst,
          worstAt);
    XCTAssertLessThan(worst, 1e-5, @"the export's reversed mix differs from playback at sample %lld", worstAt);
}

/// The reference case of the hold-after rule: V1 is a 30 s clip (the 10 s movie at 1/4 speed, so
/// source [0, 7.5 s)) with a 5 s Ken Burns move from 5 s to 10 s on the timeline (source
/// [1.25 s, 2.5 s)), from the clip's own framing to a push in at 160 %, 120 left and 50 down, easing
/// in and out. Every frame's layer shows the clip's framing exactly before the move, the move
/// (growing every frame) over it, and exactly the end framing the move set (spanEdgeMotion) from
/// 10 s to the end; the export shows the monitor's pictures before, during and well after the move.
- (void)testAHeldKenBurnsMoveExportsTheMonitorsPictures {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    h.sequence().width = 320;
    h.sequence().height = 180;
    const AssetId movie = h.importAsset("h264_1080p30.mp4");
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    auto key = [](CMTime time, double value) {
        Keyframe k;
        k.time = time;
        k.value = value;
        k.interpolation = KeyframeInterpolation::EaseInOut;
        return k;
    };
    const ClipId clip = h.addClip(h.v1, movie, 0, 900, kCMTimeZero);
    h.sequence().findClip(clip)->speed = Ratio{1, 4};
    const CMTime length = CMTimeMake(5, 4); // the move's 5 s of timeline in source time
    SpanTracks move;
    move.x = {key(kCMTimeZero, 0), key(length, -120)};
    move.y = {key(kCMTimeZero, 0), key(length, 50)};
    move.scale = {key(kCMTimeZero, 1), key(length, 1.6)};
    const SpanId span = h.addSpan(clip, SpanKind::Motion, 1, CMTimeMake(5, 4), CMTimeMake(5, 2), move);
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();
    const Clip &placed = *h.sequence().findClip(clip);
    const auto endFraming = spanEdgeMotion(placed, *placed.findSpan(span), frames30(1), true);
    const auto startFraming = spanEdgeMotion(placed, *placed.findSpan(span), frames30(1), false);
    XCTAssertTrue(endFraming.has_value() && startFraming.has_value());
    if (!endFraming || !startFraming) {
        return;
    }
    XCTAssertTrue(*endFraming == (VideoParams{-120, 50, 1.6, 0, 1}));
    XCTAssertTrue(*startFraming == VideoParams{});

    // Every frame of the sequence, as the Scheduler gives it to the monitor and the export.
    double previousScale = 0;
    for (int64_t f = 0; f < 900; ++f) {
        const RenderGraph graph = Scheduler::renderGraphAt(h.sequence(), h.project, frames30(f));
        XCTAssertEqual(graph.layers.size(), 1u, @"frame %lld", f);
        if (graph.layers.size() != 1) {
            continue;
        }
        const VideoParams &shown = graph.layers[0].transform;
        if (f < 150) {
            XCTAssertTrue(shown == VideoParams{}, @"frame %lld: the clip's own framing before the move", f);
        } else if (f < 300) {
            XCTAssertGreaterThan(shown.scale, f == 150 ? 0.0 : previousScale, @"frame %lld: the move pushes in", f);
            XCTAssertLessThan(shown.scale, 1.6, @"frame %lld: short of the end framing inside the move", f);
        } else {
            XCTAssertTrue(shown == *endFraming, @"frame %lld: the end framing, held exactly", f);
            XCTAssertEqual(graph.layers[0].opacity, 1.0, @"frame %lld", f);
        }
        previousScale = shown.scale;
    }

    ex::ExportRequest request;
    request.project = std::make_shared<const Project>(h.project);
    request.sequenceId = h.sequenceId;
    request.encode.container = media::ContainerFormat::MOV;
    media::VideoEncodeSettings v;
    v.codec = media::VideoCodec::ProRes422;
    v.width = 320;
    v.height = 180;
    request.encode.video = v;
    request.outputPath = _dir + "/held-parity.mov";
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
    XCTAssertEqual(result->value().frames, 900);
    auto created = render::Compositor::create(h.device(), {MTLPixelFormatRGBA16Float});
    auto pool = media::PixelBufferPool::create(kCVPixelFormatType_32BGRA, 320, 180);
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
    int64_t heldFramesChecked = 0;
    for (int64_t f : {0, 90, 149, 150, 200, 250, 299, 300, 450, 600, 750, 899}) {
        h.controller->seek(frames30(f));
        const PlaybackHarness::Sample sample = h.presentExact();
        XCTAssertEqual(sample.presented.frameIndex, f);
        const render::PreviewFrame &frame = h.frame();
        XCTAssertEqual(frame.graph.layers.size(), 1u, @"frame %lld", f);
        if (frame.graph.layers.size() != 1) {
            continue;
        }
        const VideoParams &shown = frame.graph.layers[0].transform;
        XCTAssertTrue(shown == motionValuesAt(placed, frames30(f)), @"frame %lld: the monitor's layer", f);
        auto render = [&](const RenderGraph &graph) -> std::vector<double> {
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
        // What the same picture would look like in the clip's own framing: the move's effect.
        RenderGraph own = frame.graph;
        own.layers[0].transform = VideoParams{};
        const double framingEffect = compare(render(own), monitor).maxBlock;
        if (f < 150) {
            XCTAssertLessThan(framingEffect, 1.0, @"frame %lld: before the move, the clip's own framing", f);
        } else if (f >= 300) {
            XCTAssertTrue(shown == *endFraming, @"frame %lld: the end framing, held exactly", f);
            XCTAssertGreaterThan(framingEffect, 40.0, @"frame %lld: the held push in is visible", f);
            ++heldFramesChecked;
        }
        XCTAssertTrue(decoder->decoder->seek(frames30(f)).ok());
        auto decoded = decoder->decoder->next();
        XCTAssertTrue(decoded.ok() && decoded.value(), @"exported frame %lld", f);
        if (!decoded.ok() || !decoded.value()) {
            continue;
        }
        const Difference d = compare(monitor, blockMeans(decoded.value()->image.get()));
        NSLog(@"PARITY held frame %lld: scale %.4f; blocks differ by at most %.2f, on average %.3f; the framing "
              @"changes blocks by up to %.2f",
              f, shown.scale, d.maxBlock, d.meanBlock, framingEffect);
        XCTAssertLessThan(d.maxBlock, 14.0, @"frame %lld: the export differs from the monitor", f);
        XCTAssertLessThan(d.meanBlock, 1.0, @"frame %lld", f);
    }
    XCTAssertEqual(heldFramesChecked, 5);
}

/// A1: the movie's 440 Hz tone for 5 s at 0 dB with two Gain spans on lane 1: a linear duck to
/// -12 dB over [1 s, 2 s), held, then from the held level a swell of +6 dB over [3 s, 3.5 s)
/// easing in and out, held to the end. The offline renderer's mix divided by the same clip's
/// unspanned mix is the level the model composes (gainDbAt) at every sample where the tone is
/// away from its zero crossings: exact (float precision) over the ramps and holds that are linear
/// in dB, within 0.01 dB over the eased swell (followed in 5 ms steps).
- (void)testAHeldGainRendersOfflineAtTheComposedLevel {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    const AssetId movie = h.importAsset("h264_1080p30.mp4");
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    const ClipId tone = h.addClip(h.a1, movie, 0, 150, CMTimeMake(3, 1));
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    Project plain = h.project; // the same clip without spans
    auto ramp = [](double to, CMTime length, KeyframeInterpolation interpolation) {
        Keyframe a;
        a.time = kCMTimeZero;
        a.value = 0;
        a.interpolation = interpolation;
        Keyframe b;
        b.time = length;
        b.value = to;
        b.interpolation = interpolation;
        return KeyframeTrack{a, b};
    };
    SpanTracks duck;
    duck.gain = ramp(-12, CMTimeMake(1, 1), KeyframeInterpolation::Linear);
    h.addSpan(tone, SpanKind::Gain, 1, CMTimeMake(4, 1), CMTimeMake(5, 1), duck); // source = timeline + 3 s
    SpanTracks swell;
    swell.gain = ramp(6, CMTimeMake(1, 2), KeyframeInterpolation::EaseInOut);
    h.addSpan(tone, SpanKind::Gain, 1, CMTimeMake(6, 1), CMTimeMake(13, 2), swell);
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());

    auto renderAll = [&](const Project &project) {
        audio::OfflineAudioRenderer offline(h.router, std::make_shared<const Project>(project), h.sequenceId,
                                            routingOf(project, *h.router), audio::OfflineAudioRenderer::Config{});
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
        return mixed;
    };
    const std::vector<float> spanned = renderAll(h.project);
    const std::vector<float> unspanned = renderAll(plain);
    XCTAssertEqual(spanned.size(), size_t(5 * 48000 * 2));
    XCTAssertEqual(unspanned.size(), spanned.size());
    const Clip &clip = *h.sequence().findClip(tone);
    double worstLinear = 0;
    double worstEased = 0;
    int64_t compared = 0;
    int64_t held = 0;
    for (size_t i = 0; i < std::min(spanned.size(), unspanned.size()); i += 2) {
        const double reference = unspanned[i];
        if (std::fabs(reference) < 0.05 || std::fabs(reference) > 0.99) {
            continue;
        }
        const int64_t sample = int64_t(i / 2);
        const double seconds = double(sample) / 48000.0;
        const double want = gainDbAt(clip, CMTimeMake(sample, 48000));
        const double got = 20 * std::log10(double(spanned[i]) / reference);
        const double error = std::fabs(got - want);
        const bool easedPart = seconds >= 3.0 && seconds < 3.5;
        double &worst = easedPart ? worstEased : worstLinear;
        worst = std::max(worst, error);
        ++compared;
        if ((seconds >= 2.0 && seconds < 3.0) || seconds >= 3.5) {
            ++held;
            XCTAssertEqualWithAccuracy(want, seconds < 3.0 ? -12.0 : -6.0, 1e-12, @"sample %lld", sample);
        }
    }
    NSLog(@"PARITY held gain: %lld samples compared (%lld held); worst %.2g dB on the linear parts and holds, "
          @"%.2g dB on the eased swell",
          compared, held, worstLinear, worstEased);
    XCTAssertGreaterThan(compared, 5 * 48000 / 2);
    XCTAssertGreaterThan(held, 48000);
    XCTAssertLessThan(worstLinear, 1e-4);
    XCTAssertLessThan(worstEased, 0.01);
}

@end
