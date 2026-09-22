// Runs the backend conformance suite against FFmpegBackend (on the generated ISO-BMFF media
// and on Matroska remuxes of it), plus FFmpeg-specific checks: software vs VideoToolbox decode,
// damaged input, 10-bit output formats, Matroska writing and memory stability.

#import "MediaBackendConformanceTests.h"

#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../../Engine/Media/ColorTags.h"
#include "../../Engine/Media/FFmpeg/FFAudioEncoder.h"
#include "../../Engine/Media/FFmpeg/FFMuxer.h"
#include "../../Engine/Media/FFmpeg/FFVideoDecoder.h"
#include "../../Engine/Media/FFmpeg/FFVideoEncoder.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Media/HardwareCaps.h"
#include "BurnIn.h"
#include "FFmpegTestMedia.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <fstream>
#include <random>
#include <vector>

using namespace ve::media;
using namespace ve::test;

namespace {

NSString *describe(const MediaError &e) {
    return @(e.description().c_str());
}

std::vector<char> readFile(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    return std::vector<char>((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
}

void writeFile(const std::string &path, const std::vector<char> &bytes, size_t count) {
    std::ofstream(path, std::ios::binary).write(bytes.data(), static_cast<std::streamsize>(count));
}

/// Byte-exact comparison of the visible pixels of two BGRA or biplanar YCbCr buffers.
bool samePixels(CVPixelBufferRef a, CVPixelBufferRef b) {
    const OSType format = CVPixelBufferGetPixelFormatType(a);
    if (format != CVPixelBufferGetPixelFormatType(b) || CVPixelBufferGetWidth(a) != CVPixelBufferGetWidth(b) ||
        CVPixelBufferGetHeight(a) != CVPixelBufferGetHeight(b)) {
        return false;
    }
    PixelBufferLock la(a, true);
    PixelBufferLock lb(b, true);
    struct Plane {
        const uint8_t *base;
        size_t stride;
        size_t rows;
        size_t rowBytes;
    };
    auto planes = [](CVPixelBufferRef pb) {
        std::vector<Plane> out;
        if (!CVPixelBufferIsPlanar(pb)) {
            out.push_back({static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(pb)),
                           CVPixelBufferGetBytesPerRow(pb), CVPixelBufferGetHeight(pb), CVPixelBufferGetWidth(pb) * 4});
            return out;
        }
        const OSType f = CVPixelBufferGetPixelFormatType(pb);
        const size_t sample = (f == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                               f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
                                  ? 1
                                  : 2;
        for (size_t p = 0; p < CVPixelBufferGetPlaneCount(pb); ++p) {
            out.push_back({static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pb, p)),
                           CVPixelBufferGetBytesPerRowOfPlane(pb, p), CVPixelBufferGetHeightOfPlane(pb, p),
                           CVPixelBufferGetWidthOfPlane(pb, p) * sample * (p == 0 ? 1 : 2)});
        }
        return out;
    };
    const std::vector<Plane> pa = planes(a);
    const std::vector<Plane> pb = planes(b);
    for (size_t p = 0; p < pa.size(); ++p) {
        for (size_t y = 0; y < pa[p].rows; ++y) {
            if (std::memcmp(pa[p].base + y * pa[p].stride, pb[p].base + y * pb[p].stride, pa[p].rowBytes) != 0) {
                return false;
            }
        }
    }
    return true;
}

/// Writes a 64x32 image with four differently coloured quadrants (the top-right one half
/// transparent) as `type` with the given EXIF orientation.
bool writeQuadrantImage(const std::string &path, CFStringRef type, int orientation) {
    constexpr size_t w = 64;
    constexpr size_t h = 32;
    std::vector<uint8_t> rgba(w * h * 4);
    for (size_t y = 0; y < h; ++y) {
        for (size_t x = 0; x < w; ++x) {
            const int q = (y < h / 2 ? 0 : 2) + (x < w / 2 ? 0 : 1);
            static const uint8_t colors[4][4] = {{220, 40, 40, 255}, {40, 200, 40, 128}, {40, 40, 220, 255},
                                                 {230, 210, 30, 255}};
            uint8_t *p = &rgba[(y * w + x) * 4];
            const uint8_t a = colors[q][3];
            for (int c = 0; c < 3; ++c) {
                p[c] = static_cast<uint8_t>(colors[q][c] * a / 255); // Premultiplied for CoreGraphics.
            }
            p[3] = a;
        }
    }
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate(rgba.data(), w, h, 8, w * 4, space,
                                             static_cast<uint32_t>(kCGImageAlphaPremultipliedLast));
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    NSURL *url = [NSURL fileURLWithPath:@(path.c_str())];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, type, 1, nullptr);
    NSDictionary *props = @{
        (__bridge NSString *)kCGImagePropertyOrientation : @(orientation),
        (__bridge NSString *)kCGImageDestinationLossyCompressionQuality : @1.0,
    };
    CGImageDestinationAddImage(dest, image, (__bridge CFDictionaryRef)props);
    const bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(image);
    CGContextRelease(ctx);
    CGColorSpaceRelease(space);
    return ok;
}

/// Mean absolute difference per BGRA channel between two same-sized BGRA buffers.
double meanDifference(CVPixelBufferRef a, CVPixelBufferRef b) {
    PixelBufferLock la(a, true);
    PixelBufferLock lb(b, true);
    const size_t w = CVPixelBufferGetWidth(a);
    const size_t h = CVPixelBufferGetHeight(a);
    double sum = 0;
    const auto *baseA = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(a));
    const auto *baseB = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(b));
    for (size_t y = 0; y < h; ++y) {
        const uint8_t *ra = baseA + y * CVPixelBufferGetBytesPerRow(a);
        const uint8_t *rb = baseB + y * CVPixelBufferGetBytesPerRow(b);
        for (size_t i = 0; i < w * 4; ++i) {
            sum += std::abs(static_cast<int>(ra[i]) - static_cast<int>(rb[i]));
        }
    }
    return sum / static_cast<double>(w * h * 4);
}

} // namespace

// MARK: - Conformance on the generated media

@interface FFmpegBackendConformanceTests : MediaBackendConformanceTests
@end

@implementation FFmpegBackendConformanceTests

+ (std::shared_ptr<IMediaBackend>)backend {
    return ffmpeg::makeFFmpegBackend();
}

- (std::vector<TestClip>)clips {
    // HEIC is not decodable by this LGPL FFmpeg build (no libheif; libavformat only exposes the
    // HEVC tiles), so the backend reports it unsupported and the router uses the Apple backend.
    // testHeicIsReportedUnsupported checks exactly that.
    std::vector<TestClip> clips;
    for (const TestClip &c : testClips()) {
        if (c.container != "heic") {
            clips.push_back(c);
        }
    }
    return clips;
}

- (void)testBackendIdentity {
    auto backend = self.backendUnderTest;
    XCTAssertEqual(backend->name(), "ffmpeg");
    XCTAssertNotEqual(backend->makeVideoEncoder(), nullptr);
    XCTAssertNotEqual(backend->makeAudioEncoder(), nullptr);
    XCTAssertNotEqual(backend->makeMuxer(), nullptr);
}

- (void)testHeicIsReportedUnsupported {
    const std::string path = [self pathForFile:"still.heic"];
    if (path.empty()) {
        return;
    }
    auto info = self.backendUnderTest->makeProber()->probe(path);
    XCTAssertFalse(info.ok());
    if (!info.ok()) {
        XCTAssertEqual(info.error().code, MediaErrorCode::UnsupportedFormat, @"%@", describe(info.error()));
    }
    auto decoder = self.backendUnderTest->makeVideoDecoder();
    XCTAssertFalse(decoder->open(path, -1, {}).ok());

    MediaInfo heic; // As the Apple prober describes it.
    heic.container = "heic";
    TrackInfo still;
    still.kind = TrackKind::Still;
    still.codec = {fourcc::HEIC, "HEIC"};
    heic.tracks = {still};
    XCTAssertFalse(self.backendUnderTest->canHandle(heic));
}

- (void)testCanHandle {
    auto backend = self.backendUnderTest;
    auto prober = backend->makeProber();
    for (const TestClip &clip : [self clips]) {
        auto info = prober->probe([self pathForFile:clip.file]);
        XCTAssertTrue(info.ok(), @"%s", clip.file.c_str());
        if (info.ok()) {
            XCTAssertTrue(backend->canHandle(info.value()), @"%s", clip.file.c_str());
        }
    }
    auto make = [](const char *container, std::vector<std::pair<TrackKind, uint32_t>> tracks) {
        MediaInfo info;
        info.container = container;
        for (auto [kind, code] : tracks) {
            TrackInfo t;
            t.kind = kind;
            t.codec = {code, codecDisplayName(code)};
            info.tracks.push_back(t);
        }
        return info;
    };
    XCTAssertTrue(backend->canHandle(make("mkv", {{TrackKind::Video, fourcc::H264}, {TrackKind::Audio, fourcc::AAC}})));
    XCTAssertTrue(backend->canHandle(make("mkv", {{TrackKind::Video, fourcc::HEVCAlt}})));
    XCTAssertTrue(backend->canHandle(
        make("webm", {{TrackKind::Video, fourcc::VP9}, {TrackKind::Audio, fourcc::make("opus")}})));
    XCTAssertTrue(backend->canHandle(make("mkv", {{TrackKind::Audio, fourcc::make("fLaC")}})));
    XCTAssertTrue(backend->canHandle(make("ogg", {{TrackKind::Audio, fourcc::make("vorb")}})));
    XCTAssertTrue(backend->canHandle(make("mov", {{TrackKind::Video, fourcc::ProRes4444}})));
    XCTAssertTrue(backend->canHandle(make("jpeg", {{TrackKind::Still, fourcc::JPEG}})));
    XCTAssertFalse(backend->canHandle(make("mkv", {{TrackKind::Video, fourcc::AV1}})), @"no AV1 decoder");
    XCTAssertFalse(backend->canHandle(make("avif", {{TrackKind::Still, fourcc::AV1}})));
    XCTAssertFalse(backend->canHandle(make("mp4", {{TrackKind::Video, fourcc::make("zzzz")}})));
    XCTAssertFalse(backend->canHandle(make("mp4", {{TrackKind::Still, fourcc::PNG}})), @"still in a movie container");
    XCTAssertFalse(backend->canHandle(make("mkv", {})));
}

- (void)testCanWrite {
    auto backend = self.backendUnderTest;
    EncodeSettings s;
    s.container = ContainerFormat::MOV;
    VideoEncodeSettings v;
    v.width = 640;
    v.height = 360;
    s.video = v;
    s.audio = AudioEncodeSettings{};
    XCTAssertTrue(backend->canWrite(s));
    s.container = ContainerFormat::WAV;
    XCTAssertFalse(backend->canWrite(s), @"video in WAV");
    s.video.reset();
    XCTAssertFalse(backend->canWrite(s), @"AAC in WAV");
    s.audio->codec = AudioCodec::LinearPCM;
    XCTAssertTrue(backend->canWrite(s));
    s.audio->pcmBitDepth = 20;
    XCTAssertFalse(backend->canWrite(s));
    s.container = ContainerFormat::M4A;
    s.audio->pcmBitDepth = 16;
    s.audio->codec = AudioCodec::AAC;
    XCTAssertTrue(backend->canWrite(s));
}

- (void)testEncoderSelection {
    const HardwareCaps &caps = HardwareCaps::get();
    for (VideoCodec codec : {VideoCodec::H264, VideoCodec::HEVC, VideoCodec::ProRes422}) {
        ffmpeg::FFVideoEncoder encoder;
        VideoEncodeSettings v;
        v.codec = codec;
        v.width = 640;
        v.height = 360;
        Status s = encoder.open(v);
        XCTAssertTrue(s.ok(), @"%s: %@", toString(codec), s.ok() ? @"" : describe(s.error()));
        NSLog(@"video %s -> %s (hardware %d)", toString(codec), encoder.encoderName().c_str(), encoder.usesHardware());
        XCTAssertEqual(encoder.usesHardware(), caps.hardwareEncode(codecType(codec)), @"%s", toString(codec));
        XCTAssertNotEqual(encoder.encoderName().find("videotoolbox"), std::string::npos, @"%s", toString(codec));
        auto format = encoder.outputFormat();
        XCTAssertTrue(format.ok() && format->codec == codecType(codec));
        if (codec != VideoCodec::ProRes422) {
            XCTAssertTrue(format.ok() && !format->extradata.empty(), @"%s: parameter sets", toString(codec));
        }
    }
    ffmpeg::FFAudioEncoder aac;
    XCTAssertTrue(aac.open(AudioEncodeSettings{}).ok());
    NSLog(@"audio aac -> %s (encoder delay %d)", aac.encoderName().c_str(), aac.initialPadding());
    XCTAssertEqual(aac.encoderName(), std::string("aac_at"), @"AudioToolbox AAC is preferred");
    XCTAssertGreaterThan(aac.initialPadding(), 0);
    for (int bits : {16, 24, 32}) {
        ffmpeg::FFAudioEncoder pcm;
        AudioEncodeSettings a;
        a.codec = AudioCodec::LinearPCM;
        a.pcmBitDepth = bits;
        XCTAssertTrue(pcm.open(a).ok());
        const std::string expected = bits == 16 ? "pcm_s16le" : bits == 24 ? "pcm_s24le" : "pcm_f32le";
        XCTAssertEqual(pcm.encoderName(), expected);
        XCTAssertEqual(pcm.outputFormat()->bitRate, 48000 * 2 * bits);
    }
    VideoEncodeSettings impossible;
    impossible.width = 640;
    impossible.height = 360;
    impossible.inputPixelFormat = kCVPixelFormatType_422YpCbCr16; // No FFmpeg equivalent.
    ffmpeg::FFVideoEncoder rejected;
    XCTAssertFalse(rejected.open(impossible).ok());
}

- (void)testStillsMatchTheAppleBackend {
    // EXIF orientation and alpha handling must match ImageIO's, so the router may send a still
    // to either backend.
    auto apple = apple::makeAppleBackend();
    const std::string dir = scratchDirectory();
    struct Case {
        CFStringRef type;
        const char *extension;
        int orientation;
    };
    for (const Case &c : {Case{CFSTR("public.png"), "png", 1},
                          Case{CFSTR("public.jpeg"), "jpg", 1},
                          Case{CFSTR("public.jpeg"), "jpg", 3},
                          Case{CFSTR("public.jpeg"), "jpg", 5},
                          Case{CFSTR("public.jpeg"), "jpg", 6},
                          Case{CFSTR("public.jpeg"), "jpg", 8}}) {
        const std::string path = dir + "/quad" + std::to_string(c.orientation) + "." + c.extension;
        XCTAssertTrue(writeQuadrantImage(path, c.type, c.orientation));
        auto info = self.backendUnderTest->makeProber()->probe(path);
        auto appleInfo = apple->makeProber()->probe(path);
        XCTAssertTrue(info.ok() && appleInfo.ok(), @"%s", path.c_str());
        if (!info.ok() || !appleInfo.ok()) {
            continue;
        }
        XCTAssertEqual(info->container, appleInfo->container);
        XCTAssertEqual(info->tracks.at(0).width, appleInfo->tracks.at(0).width, @"%s", path.c_str());
        XCTAssertEqual(info->tracks.at(0).height, appleInfo->tracks.at(0).height, @"%s", path.c_str());
        XCTAssertEqual(info->tracks.at(0).codec.fourCC, appleInfo->tracks.at(0).codec.fourCC);
        auto ours = self.backendUnderTest->makeVideoDecoder();
        auto theirs = apple->makeVideoDecoder();
        XCTAssertTrue(ours->open(path, -1, {}).ok() && theirs->open(path, -1, {}).ok());
        auto a = ours->next();
        auto b = theirs->next();
        XCTAssertTrue(a.ok() && a.value() && b.ok() && b.value());
        if (!a.ok() || !a.value() || !b.ok() || !b.value()) {
            continue;
        }
        XCTAssertEqual(a.value()->image.width(), b.value()->image.width(), @"%s", path.c_str());
        XCTAssertEqual(a.value()->image.height(), b.value()->image.height(), @"%s", path.c_str());
        if (a.value()->image.width() == b.value()->image.width() &&
            a.value()->image.height() == b.value()->image.height()) {
            const double diff = meanDifference(a.value()->image.get(), b.value()->image.get());
            XCTAssertLessThan(diff, 3.0, @"%s: mean BGRA difference %.2f", path.c_str(), diff);
        }
    }
}

// MARK: Hardware vs software decode

/// Decodes `count` frames from `start` (after a seek unless start is 0) and returns them.
- (std::vector<VideoFrame>)decode:(const TestClip &)clip
                         hardware:(bool)hardware
                             from:(int)start
                            count:(int)count
                          decoder:(std::unique_ptr<IVideoDecoder> *)keep {
    std::vector<VideoFrame> frames;
    auto decoder = self.backendUnderTest->makeVideoDecoder();
    DecodeOptions options;
    options.allowHardware = hardware;
    Status s = decoder->open([self pathForFile:clip.file], -1, options);
    XCTAssertTrue(s.ok(), @"%s: %@", clip.file.c_str(), s.ok() ? @"" : describe(s.error()));
    if (!s.ok()) {
        return frames;
    }
    if (start > 0) {
        XCTAssertTrue(decoder->seek(CMTimeMultiply(clip.frameDuration, start)).ok());
    }
    for (int i = 0; i < count; ++i) {
        auto f = decoder->next();
        XCTAssertTrue(f.ok() && f.value(), @"%s frame %d", clip.file.c_str(), start + i);
        if (!f.ok() || !f.value()) {
            break;
        }
        frames.push_back(std::move(*f.value()));
    }
    if (keep != nullptr) {
        *keep = std::move(decoder);
    }
    return frames;
}

- (void)testSoftwareAndHardwareDecodeAgree {
    for (const char *file : {"h264_1080p30.mp4", "hevc_720p2997.mov", "prores_540p25.mov"}) {
        const TestClip &clip = testClip(file);
        const bool hwExpected = HardwareCaps::get().hardwareDecode(clip.videoCodec);
        for (int start : {0, clip.frames / 2 + 1}) {
            std::unique_ptr<IVideoDecoder> hwDecoder;
            std::unique_ptr<IVideoDecoder> swDecoder;
            const int count = std::min(40, clip.frames - start);
            const auto hw = [self decode:clip hardware:true from:start count:count decoder:&hwDecoder];
            const auto sw = [self decode:clip hardware:false from:start count:count decoder:&swDecoder];
            XCTAssertEqual(hw.size(), sw.size(), @"%s", file);
            if (!hwDecoder || !swDecoder) {
                continue;
            }
            XCTAssertEqual(hwDecoder->usedHardware(), hwExpected, @"%s", file);
            XCTAssertFalse(swDecoder->usedHardware(), @"%s", file);
            XCTAssertEqual(hwDecoder->outputPixelFormat(), swDecoder->outputPixelFormat(), @"%s", file);
            int exact = 0;
            for (size_t i = 0; i < std::min(hw.size(), sw.size()); ++i) {
                const int index = start + static_cast<int>(i);
                XCTAssertEqual(hw[i].wasHardwareDecoded, hwExpected, @"%s", file);
                XCTAssertFalse(sw[i].wasHardwareDecoded, @"%s", file);
                XCTAssertEqual(readBurnIn(hw[i].image.get()), std::optional<int>(index), @"%s hw %d", file, index);
                XCTAssertEqual(readBurnIn(sw[i].image.get()), std::optional<int>(index), @"%s sw %d", file, index);
                XCTAssertEqual(CMTimeCompare(hw[i].pts, sw[i].pts), 0, @"%s frame %d", file, index);
                XCTAssertEqual(CMTimeCompare(hw[i].duration, sw[i].duration), 0, @"%s frame %d", file, index);
                XCTAssertEqual(hw[i].image.pixelFormat(), sw[i].image.pixelFormat(), @"%s", file);
                XCTAssertTrue(hw[i].image.isIOSurfaceBacked() && sw[i].image.isIOSurfaceBacked(), @"%s", file);
                exact += samePixels(hw[i].image.get(), sw[i].image.get()) ? 1 : 0;
            }
            // Both are conforming decoders; ProRes decoders are allowed to differ in rounding.
            NSLog(@"%s from %d: %d of %zu frames bit-identical between VideoToolbox and libavcodec", file, start,
                  exact, hw.size());
            if (!isProRes(clip.videoCodec)) {
                XCTAssertEqual(static_cast<size_t>(exact), hw.size(), @"%s: software and hardware pixels differ", file);
            }
        }
    }
}

- (void)testOutputBuffersAreTaggedAndIOSurfaceBacked {
    const TestClip &clip = testClip("hevc_720p2997.mov");
    for (bool hardware : {true, false}) {
        const auto frames = [self decode:clip hardware:hardware from:0 count:1 decoder:nullptr];
        if (frames.empty()) {
            continue;
        }
        CVPixelBufferRef pb = frames[0].image.get();
        XCTAssertTrue(frames[0].image.isIOSurfaceBacked());
        CFTypeRef matrix = CVBufferCopyAttachment(pb, kCVImageBufferYCbCrMatrixKey, nullptr);
        CFTypeRef primaries = CVBufferCopyAttachment(pb, kCVImageBufferColorPrimariesKey, nullptr);
        XCTAssertTrue(matrix && CFEqual(matrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2), @"hw %d", hardware);
        XCTAssertTrue(primaries && CFEqual(primaries, kCVImageBufferColorPrimaries_ITU_R_709_2), @"hw %d", hardware);
        if (matrix) {
            CFRelease(matrix);
        }
        if (primaries) {
            CFRelease(primaries);
        }
    }
}

- (void)testCloseAheadSeeksDoNotSeekTheDemuxer {
    const TestClip &clip = testClip("h264_1080p30.mp4");
    ffmpeg::FFVideoDecoder decoder;
    XCTAssertTrue(decoder.open([self pathForFile:clip.file], -1, {}).ok());
    for (int i = 0; i < 10; ++i) {
        (void)decoder.next();
    }
    XCTAssertTrue(decoder.seek(CMTimeMake(40, 30)).ok()); // 1 s ahead.
    auto f = decoder.next();
    XCTAssertTrue(f.ok() && f.value() && readBurnIn(f.value()->image.get()) == 40);
    XCTAssertEqual(decoder.demuxerSeekCount(), 0);
    XCTAssertTrue(decoder.seek(CMTimeMake(200, 30)).ok()); // Far ahead: keyframe seek.
    f = decoder.next();
    XCTAssertTrue(f.ok() && f.value() && readBurnIn(f.value()->image.get()) == 200);
    XCTAssertGreaterThanOrEqual(decoder.demuxerSeekCount(), 1);
}

// MARK: Damaged input

- (void)testTruncatedAndCorruptFilesFailCleanly {
    const std::string dir = scratchDirectory();
    for (const char *file : {"h264_1080p30.mp4", "hevc_720p2997.mov"}) {
        const std::string source = [self pathForFile:file];
        if (source.empty()) {
            return;
        }
        const std::vector<char> bytes = readFile(source);
        std::vector<std::pair<std::string, std::vector<char>>> variants;
        for (int percent : {5, 50, 90, 99}) {
            variants.emplace_back("cut" + std::to_string(percent),
                                  std::vector<char>(bytes.begin(), bytes.begin() + static_cast<ptrdiff_t>(
                                                                                       bytes.size() * percent / 100)));
        }
        // Random bytes over a stretch of media data (both files keep their index intact).
        std::mt19937 rng(99);
        for (double where : {0.3, 0.6}) {
            std::vector<char> damaged = bytes;
            const size_t at = static_cast<size_t>(static_cast<double>(bytes.size()) * where);
            for (size_t i = at; i < std::min(bytes.size(), at + 16384); ++i) {
                damaged[i] = static_cast<char>(rng() & 0xFF);
            }
            variants.emplace_back("noise" + std::to_string(static_cast<int>(where * 100)), std::move(damaged));
        }
        for (const auto &[name, data] : variants) {
            const std::string path = dir + "/" + name + "_" + file;
            writeFile(path, data, data.size());
            auto info = self.backendUnderTest->makeProber()->probe(path);
            auto video = self.backendUnderTest->makeVideoDecoder();
            const Status opened = video->open(path, -1, {});
            NSLog(@"%s %s: probe %@, open %@", file, name.c_str(), info.ok() ? @"ok" : describe(info.error()),
                  opened.ok() ? @"ok" : describe(opened.error()));
            if (!opened.ok()) {
                XCTAssertFalse(video->next().ok());
                continue;
            }
            int frames = 0;
            int errors = 0;
            for (int i = 0; i < 400 && errors < 3; ++i) {
                auto f = video->next();
                if (!f.ok()) {
                    ++errors;
                    continue;
                }
                if (!f.value()) {
                    break;
                }
                ++frames;
            }
            NSLog(@"%s %s: %d frames, %d errors", file, name.c_str(), frames, errors);
            // Whatever happened, the decoder can still be positioned on intact data.
            XCTAssertTrue(video->seek(kCMTimeZero).ok(), @"%s %s", file, name.c_str());
            auto first = video->next();
            if (name != "cut5") {
                XCTAssertTrue(first.ok() && first.value() && readBurnIn(first.value()->image.get()) == 0,
                              @"%s %s: frame 0 after damage", file, name.c_str());
            }
            auto audio = self.backendUnderTest->makeAudioDecoder();
            if (audio->open(path, -1, {}).ok()) {
                std::vector<float> chunk(8192);
                for (int i = 0; i < 200; ++i) {
                    auto n = audio->read(chunk.data(), 4096);
                    if (!n.ok() || n.value() == 0) {
                        break;
                    }
                }
                XCTAssertTrue(audio->seek(CMTimeMake(1, 2)).ok());
            }
        }
    }
}

- (void)testCallsBeforeOpenAreErrors {
    auto backend = self.backendUnderTest;
    auto video = backend->makeVideoDecoder();
    XCTAssertEqual(video->next().error().code, MediaErrorCode::InvalidState);
    XCTAssertEqual(video->seek(kCMTimeZero).error().code, MediaErrorCode::InvalidState);
    auto audio = backend->makeAudioDecoder();
    float buffer[4];
    XCTAssertEqual(audio->read(buffer, 2).error().code, MediaErrorCode::InvalidState);
    auto muxer = backend->makeMuxer();
    XCTAssertFalse(muxer->begin().ok());
    XCTAssertFalse(muxer->finish().ok());
    auto videoDecoder = backend->makeVideoDecoder();
    const TestClip &clip = testClip("h264_1080p30.mp4");
    XCTAssertEqual(videoDecoder->open([self pathForFile:clip.file], 5, {}).error().code, MediaErrorCode::NoSuchTrack);
    auto audioDecoder = backend->makeAudioDecoder();
    XCTAssertEqual(audioDecoder->open([self pathForFile:clip.file], 0, {}).error().code, MediaErrorCode::NoSuchTrack,
                   @"track 0 is video");
}

// MARK: 10-bit

- (void)testTenBitHEVCRoundTripKeepsX420 {
    const auto &caps = HardwareCaps::get();
    if (!caps.hevc.hardwareEncode && !caps.hevc.softwareEncode) {
        NSLog(@"no HEVC encoder in VideoToolbox; 10-bit test skipped");
        return;
    }
    constexpr int kFrames = 20;
    const std::string path = scratchDirectory() + "/hevc10.mov";
    EncodeSettings settings;
    settings.container = ContainerFormat::MOV;
    VideoEncodeSettings v;
    v.codec = VideoCodec::HEVC;
    v.width = 640;
    v.height = 360;
    v.frameDuration = CMTimeMake(1, 25);
    v.averageBitRate = 6'000'000;
    v.maxKeyFrameInterval = 10;
    v.inputPixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    settings.video = v;
    auto writer = self.backendUnderTest->makeWriter();
    Status opened = writer->open(path, settings);
    XCTAssertTrue(opened.ok(), @"%@", opened.ok() ? @"" : describe(opened.error()));
    if (!opened.ok()) {
        return;
    }
    // Burn-ins are drawn in BGRA and converted to 10-bit 4:2:0 with VideoToolbox.
    auto bgraPool = PixelBufferPool::create(kCVPixelFormatType_32BGRA, 640, 360);
    VTPixelTransferSessionRef transfer = nullptr;
    XCTAssertEqual(VTPixelTransferSessionCreate(kCFAllocatorDefault, &transfer), noErr);
    for (int i = 0; i < kFrames; ++i) {
        auto bgra = bgraPool->makeBuffer();
        auto out = writer->makePixelBuffer();
        XCTAssertTrue(bgra.ok() && out.ok());
        if (!bgra.ok() || !out.ok()) {
            break;
        }
        XCTAssertEqual(out->pixelFormat(), (OSType)kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
        drawBurnIn(bgra->get(), i);
        attachColorInfo(out->get(), ColorInfo::bt709());
        XCTAssertEqual(VTPixelTransferSessionTransferImage(transfer, bgra->get(), out->get()), noErr);
        Status s = writer->appendVideo(out.value(), CMTimeMake(i, 25));
        XCTAssertTrue(s.ok(), @"%@", s.ok() ? @"" : describe(s.error()));
    }
    VTPixelTransferSessionInvalidate(transfer);
    CFRelease(transfer);
    Status finished = writer->finish();
    XCTAssertTrue(finished.ok(), @"%@", finished.ok() ? @"" : describe(finished.error()));
    if (!finished.ok()) {
        return;
    }

    auto info = self.backendUnderTest->makeProber()->probe(path);
    XCTAssertTrue(info.ok());
    if (info.ok()) {
        const TrackInfo *t = info->firstTrack(TrackKind::Video);
        XCTAssertTrue(t != nullptr);
        if (t) {
            XCTAssertEqual(t->bitDepth, 10);
            XCTAssertEqual(t->chroma, ChromaSubsampling::C420);
            XCTAssertEqual(canonicalCodec(t->codec.fourCC), fourcc::HEVC);
        }
    }
    TestClip clip;
    clip.file = path;
    clip.frameDuration = CMTimeMake(1, 25);
    clip.frames = kFrames;
    for (bool hardware : {true, false}) {
        auto decoder = self.backendUnderTest->makeVideoDecoder();
        DecodeOptions options;
        options.allowHardware = hardware;
        XCTAssertTrue(decoder->open(path, -1, options).ok());
        XCTAssertEqual(decoder->outputPixelFormat(), (OSType)kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                       @"hw %d", hardware);
        for (int i = 0; i < kFrames; ++i) {
            auto f = decoder->next();
            XCTAssertTrue(f.ok() && f.value(), @"hw %d frame %d", hardware, i);
            if (!f.ok() || !f.value()) {
                break;
            }
            XCTAssertEqual(f.value()->image.pixelFormat(), (OSType)kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange);
            XCTAssertEqual(readBurnIn(f.value()->image.get()), std::optional<int>(i), @"hw %d", hardware);
            if (hardware) {
                XCTAssertEqual(f.value()->wasHardwareDecoded, HardwareCaps::get().hevc.hardwareDecode);
            }
        }
    }
}

// MARK: Matroska output

- (void)testMatroskaWriterRoundTrip {
    const std::string path = scratchDirectory() + "/rt.mkv";
    constexpr int kFrames = 45;
    const CMTime fd = CMTimeMake(1001, 30000);
    VideoEncodeSettings v;
    v.codec = VideoCodec::H264;
    v.width = 640;
    v.height = 360;
    v.frameDuration = fd;
    v.averageBitRate = 3'000'000;
    v.maxKeyFrameInterval = 15;
    AudioEncodeSettings a;
    auto videoEncoder = std::make_unique<ffmpeg::FFVideoEncoder>();
    auto audioEncoder = std::make_unique<ffmpeg::FFAudioEncoder>();
    auto muxer = std::make_unique<ffmpeg::FFMuxer>();
    XCTAssertTrue(videoEncoder->open(v).ok());
    XCTAssertTrue(audioEncoder->open(a).ok());
    XCTAssertTrue(muxer->openFormat(path, "matroska").ok());
    auto vf = videoEncoder->outputFormat();
    auto af = audioEncoder->outputFormat();
    XCTAssertTrue(vf.ok() && af.ok());
    if (!vf.ok() || !af.ok()) {
        return;
    }
    XCTAssertFalse(vf->extradata.empty(), @"parameter sets");
    XCTAssertFalse(af->extradata.empty(), @"AudioSpecificConfig");
    const int vs = muxer->addStream(vf.value()).value();
    const int as = muxer->addStream(af.value()).value();
    XCTAssertTrue(muxer->begin().ok());
    auto sink = [&](int stream) {
        return [&muxer, stream](EncodedPacket &&p) -> Status {
            p.streamIndex = stream;
            return muxer->writePacket(std::move(p));
        };
    };
    const double seconds = kFrames * CMTimeGetSeconds(fd);
    const auto audioFrames = static_cast<int64_t>(std::llround(seconds * 48000));
    const std::vector<float> pcm = makeToneWithBeep(500, 48000, 2, audioFrames, 1.0);
    auto pool = PixelBufferPool::create(kCVPixelFormatType_32BGRA, 640, 360);
    int64_t written = 0;
    for (int i = 0; i < kFrames; ++i) {
        const auto until = std::min<int64_t>(audioFrames, std::llround((i + 1) * CMTimeGetSeconds(fd) * 48000));
        if (until > written) {
            XCTAssertTrue(audioEncoder->encode(pcm.data() + written * 2, static_cast<int>(until - written), sink(as))
                              .ok());
            written = until;
        }
        auto buffer = pool->makeBuffer();
        drawBurnIn(buffer->get(), i);
        XCTAssertTrue(videoEncoder->encode(buffer.value(), CMTimeMultiply(fd, i), sink(vs)).ok());
    }
    XCTAssertTrue(videoEncoder->flush(sink(vs)).ok());
    XCTAssertTrue(audioEncoder->flush(sink(as)).ok());
    Status finished = muxer->finish();
    XCTAssertTrue(finished.ok(), @"%@", finished.ok() ? @"" : describe(finished.error()));

    auto info = self.backendUnderTest->makeProber()->probe(path);
    XCTAssertTrue(info.ok(), @"%@", info.ok() ? @"" : describe(info.error()));
    if (!info.ok()) {
        return;
    }
    XCTAssertEqual(info->container, "mkv");
    const TrackInfo *t = info->firstTrack(TrackKind::Video);
    XCTAssertTrue(t && CMTimeCompare(t->frameDuration, fd) == 0);
    auto decoder = self.backendUnderTest->makeVideoDecoder();
    XCTAssertTrue(decoder->open(path, -1, {}).ok());
    for (int i = 0; i < kFrames; ++i) {
        auto f = decoder->next();
        XCTAssertTrue(f.ok() && f.value(), @"frame %d", i);
        if (!f.ok() || !f.value()) {
            break;
        }
        XCTAssertEqual(readBurnIn(f.value()->image.get()), std::optional<int>(i));
        XCTAssertEqual(CMTimeCompare(f.value()->pts, CMTimeMultiply(fd, i)), 0, @"frame %d pts %lld/%d", i,
                       f.value()->pts.value, f.value()->pts.timescale);
    }
    auto audio = self.backendUnderTest->makeAudioDecoder();
    XCTAssertTrue(audio->open(path, -1, {}).ok());
    std::vector<float> all;
    std::vector<float> chunk(8192);
    while (true) {
        auto n = audio->read(chunk.data(), 4096);
        if (!n.ok() || n.value() == 0) {
            break;
        }
        all.insert(all.end(), chunk.begin(), chunk.begin() + n.value() * 2);
    }
    auto onset = findBeepOnset(all.data(), static_cast<int64_t>(all.size() / 2), 2, 48000, 24000);
    XCTAssertTrue(onset.has_value());
    if (onset) {
        XCTAssertEqualWithAccuracy(*onset, 1.0, 0.001, @"beep at %.5f", *onset);
    }
}

// MARK: Memory

- (void)testMemoryIsStableAcrossLongDecodesAndSeeks {
    for (bool hardware : {true, false}) {
        const TestClip &clip = testClip("hevc_720p2997.mov");
        auto decoder = self.backendUnderTest->makeVideoDecoder();
        DecodeOptions options;
        options.allowHardware = hardware;
        XCTAssertTrue(decoder->open([self pathForFile:clip.file], -1, options).ok());
        auto audio = self.backendUnderTest->makeAudioDecoder();
        XCTAssertTrue(audio->open([self pathForFile:clip.file], -1, {}).ok());
        std::vector<float> pcm(4096 * 2);
        std::mt19937 rng(3);
        auto round = [&] {
            int frames = 0;
            XCTAssertTrue(decoder->seek(kCMTimeZero).ok());
            for (int i = 0; i < clip.frames; ++i) {
                auto f = decoder->next();
                frames += (f.ok() && f.value()) ? 1 : 0;
            }
            for (int i = 0; i < 20; ++i) {
                (void)decoder->seek(CMTimeMultiply(clip.frameDuration, static_cast<int32_t>(rng() % 290)));
                for (int k = 0; k < 5; ++k) {
                    auto f = decoder->next();
                    frames += (f.ok() && f.value()) ? 1 : 0;
                }
                (void)audio->seek(CMTimeMake(static_cast<int64_t>(rng() % 9000), 1000));
                (void)audio->read(pcm.data(), 4096);
            }
            return frames;
        };
        @autoreleasepool {
            (void)round(); // Warm up pools and caches.
        }
        const uint64_t before = physicalFootprint();
        int frames = 0;
        for (int r = 0; r < 3; ++r) {
            @autoreleasepool {
                frames += round();
            }
        }
        const uint64_t after = physicalFootprint();
        const double growthMB = (static_cast<double>(after) - static_cast<double>(before)) / (1024.0 * 1024.0);
        NSLog(@"hw %d: %d frames, footprint %.1f MB -> %.1f MB (%+.1f MB)", hardware, frames, before / 1048576.0,
              after / 1048576.0, growthMB);
        XCTAssertGreaterThanOrEqual(frames, 3 * 400);
        XCTAssertLessThan(growthMB, 24.0, @"hw %d: footprint grew by %.1f MB", hardware, growthMB);
    }
}

@end

// MARK: - Conformance on Matroska remuxes

/// The same suite over h264_1080p30 and hevc_720p2997 stream-copied into Matroska: millisecond
/// timestamps (snapped back to the frame grid), CodecDelay for the AAC priming, Cues-based
/// seeking.
@interface FFmpegMatroskaConformanceTests : MediaBackendConformanceTests
@end

@implementation FFmpegMatroskaConformanceTests

+ (std::shared_ptr<IMediaBackend>)backend {
    return ffmpeg::makeFFmpegBackend();
}

- (std::vector<TestClip>)clips {
    return mkvTestClips();
}

- (std::string)pathForFile:(const std::string &)file {
    if (file.size() < 4 || file.compare(file.size() - 4, 4, ".mkv") != 0) {
        return [super pathForFile:file];
    }
    std::string error;
    const std::string dir = mkvTestMediaDirectory(error);
    if (dir.empty()) {
        XCTFail(@"Matroska test media unavailable: %s", error.c_str());
        return {};
    }
    return dir + "/" + file;
}

@end
