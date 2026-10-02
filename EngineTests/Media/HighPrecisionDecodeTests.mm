// High-precision decode (DecodeOptions::highPrecision; grading decision sections 4 and 6, review media #2):
//   - a 12-bit ProRes 4444 with alpha decodes to 'l64r' on both backends and keeps far more than 256 levels
//     through the compositor (the monitors' working texture and a 10-bit export);
//   - a 16-bit PNG decodes to 'l64r' on both backends, likewise;
//   - a Display P3 still decodes to 'RGhA' (extended-range sRGB) on both backends, its out-of-sRGB colours
//     kept as values outside [0, 1], and renders as the 8-bit decode does (the compositor limits them);
//   - 8-bit sources give the same format and the same bytes with or without it, and render identically;
//   - the frame cache keeps frames of different decode formats apart, and a decode pool puts and finds its
//     frames under its own format;
//   - a minified straight-alpha 'l64r' picture is premultiplied and pre-scaled at 16-bit precision;
//   - the texture cache maps 'l64r' and 'RGhA' as RGBA (rgba16Unorm, rgba16Float).

#import <XCTest/XCTest.h>

#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../../Engine/Media/BackendRouter.h"
#include "../../Engine/Media/DecodePool.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Media/FrameCache.h"
#include "../../Engine/Render/Compositor.h"
#include "../Render/CompositorTestSupport.h"
#include "RouterTestSupport.h"
#include "TestMedia.h"

#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <set>
#include <string>
#include <vector>

using namespace ve;
using namespace ve::media;
using namespace ve::render;
using namespace ve::rtest;
using namespace ve::test;

namespace {

constexpr size_t kWidth = 1024;
constexpr size_t kHeight = 64;

std::vector<std::shared_ptr<IMediaBackend>> bothBackends() {
    return {apple::makeAppleBackend(), ffmpeg::makeFFmpegBackend()};
}

float halfToFloat(uint16_t h) {
    _Float16 value;
    std::memcpy(&value, &h, sizeof value);
    return float(value);
}

// A 12-bit ProRes 4444 with alpha, written from 16-bit RGBA: a grey ramp over the whole range across
// the picture (1024 levels in 16 bits), opaque, its bottom quarter at alpha 0.5. 3 frames at 25 fps.
std::string writeProRes4444Ramp(const std::string &path) {
    NSError *error = nil;
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:[NSURL fileURLWithPath:@(path.c_str())]
                                                     fileType:AVFileTypeQuickTimeMovie
                                                        error:&error];
    if (writer == nil) {
        return "";
    }
    AVAssetWriterInput *input = [AVAssetWriterInput
        assetWriterInputWithMediaType:AVMediaTypeVideo
                       outputSettings:@{
                           AVVideoCodecKey : AVVideoCodecTypeAppleProRes4444,
                           AVVideoWidthKey : @(kWidth),
                           AVVideoHeightKey : @(kHeight)
                       }];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor
        assetWriterInputPixelBufferAdaptorWithAssetWriterInput:input
                                   sourcePixelBufferAttributes:@{
                                       (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_64RGBALE),
                                       (id)kCVPixelBufferWidthKey : @(kWidth),
                                       (id)kCVPixelBufferHeightKey : @(kHeight)
                                   }];
    [writer addInput:input];
    if (![writer startWriting]) {
        return "";
    }
    [writer startSessionAtSourceTime:kCMTimeZero];
    for (int frame = 0; frame < 3; ++frame) {
        while (!input.readyForMoreMediaData) {
            [NSThread sleepForTimeInterval:0.001];
        }
        CVPixelBufferRef pb = nullptr;
        if (CVPixelBufferPoolCreatePixelBuffer(nullptr, adaptor.pixelBufferPool, &pb) != kCVReturnSuccess) {
            return "";
        }
        CVPixelBufferLockBaseAddress(pb, 0);
        auto *base = static_cast<uint16_t *>(CVPixelBufferGetBaseAddress(pb));
        const size_t stride = CVPixelBufferGetBytesPerRow(pb) / 2;
        for (size_t y = 0; y < kHeight; ++y) {
            for (size_t x = 0; x < kWidth; ++x) {
                uint16_t *p = base + y * stride + x * 4;
                const auto v = static_cast<uint16_t>(x * 64);
                p[0] = v;
                p[1] = v;
                p[2] = v;
                p[3] = y >= kHeight * 3 / 4 ? 32768 : 65535;
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, 0);
        [adaptor appendPixelBuffer:pb withPresentationTime:CMTimeMake(frame, 25)];
        CVPixelBufferRelease(pb);
    }
    [input markAsFinished];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return writer.status == AVAssetWriterStatusCompleted ? path : "";
}

// A PNG through ImageIO: a 16-bit sRGB grey ramp over the whole range (`deep`), or an 8-bit picture in
// `wideSpace` (Display P3: ImageIO writes an ICC profile and cICP tags; Adobe RGB: an ICC profile only) of
// its pure red on the left half and a grey ramp on the right.
std::string writePNG(const std::string &path, bool deep, CFStringRef wideSpace = kCGColorSpaceDisplayP3,
                     CFStringRef type = CFSTR("public.png")) {
    CGColorSpaceRef space = CGColorSpaceCreateWithName(deep ? kCGColorSpaceSRGB : wideSpace);
    const size_t bpc = deep ? 16 : 8;
    const uint32_t info = deep ? (static_cast<uint32_t>(kCGImageAlphaNoneSkipLast) |
                                  static_cast<uint32_t>(kCGBitmapByteOrder16Little))
                               : static_cast<uint32_t>(kCGImageAlphaNoneSkipLast);
    CGContextRef ctx = CGBitmapContextCreate(nullptr, kWidth, kHeight, bpc, 0, space, info);
    CGColorSpaceRelease(space);
    if (ctx == nullptr) {
        return "";
    }
    auto *data = static_cast<uint8_t *>(CGBitmapContextGetData(ctx));
    const size_t stride = CGBitmapContextGetBytesPerRow(ctx);
    for (size_t y = 0; y < kHeight; ++y) {
        for (size_t x = 0; x < kWidth; ++x) {
            if (deep) {
                uint16_t *p = reinterpret_cast<uint16_t *>(data + y * stride) + x * 4;
                const auto v = static_cast<uint16_t>(x * 64);
                p[0] = v;
                p[1] = v;
                p[2] = v;
                p[3] = 65535;
            } else {
                uint8_t *p = data + y * stride + x * 4;
                const bool red = x < kWidth / 2;
                p[0] = red ? 255 : uint8_t(x / 4);
                p[1] = red ? 0 : uint8_t(x / 4);
                p[2] = red ? 0 : uint8_t(x / 4);
                p[3] = 255;
            }
        }
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)[NSURL fileURLWithPath:@(path.c_str())], type, 1, nullptr);
    CGImageDestinationAddImage(dest, image, nullptr);
    const bool ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    CGImageRelease(image);
    return ok ? path : "";
}

// Distinct values of channel 0 along row `y` of an RGBA buffer of 'l64r', 'RGhA' or 'BGRA' (red).
std::set<double> distinctRed(const PixelBuffer &buffer, size_t y) {
    std::set<double> values;
    CVPixelBufferRef pb = buffer.get();
    PixelBufferLock lock(pb, true);
    const auto *row = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(pb)) + y * CVPixelBufferGetBytesPerRow(pb);
    for (size_t x = 0; x < CVPixelBufferGetWidth(pb); ++x) {
        switch (CVPixelBufferGetPixelFormatType(pb)) {
        case kCVPixelFormatType_64RGBALE:
            values.insert(reinterpret_cast<const uint16_t *>(row)[x * 4] / 65535.0);
            break;
        case kCVPixelFormatType_64RGBAHalf:
            values.insert(halfToFloat(reinterpret_cast<const uint16_t *>(row)[x * 4]));
            break;
        default:
            values.insert(row[x * 4 + 2] / 255.0);
            break;
        }
    }
    return values;
}

// R, G, B, A of pixel (x, y) of an 'RGhA' buffer.
std::array<float, 4> halfPixel(const PixelBuffer &buffer, size_t x, size_t y) {
    CVPixelBufferRef pb = buffer.get();
    PixelBufferLock lock(pb, true);
    const auto *row = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(pb)) + y * CVPixelBufferGetBytesPerRow(pb);
    const auto *p = reinterpret_cast<const uint16_t *>(row) + x * 4;
    return {halfToFloat(p[0]), halfToFloat(p[1]), halfToFloat(p[2]), halfToFloat(p[3])};
}

// The picture bytes of every row of a buffer (each plane, padding excluded), for exact comparisons.
std::vector<uint8_t> bytesOf(const PixelBuffer &buffer) {
    std::vector<uint8_t> out;
    CVPixelBufferRef pb = buffer.get();
    const OSType format = CVPixelBufferGetPixelFormatType(pb);
    // Bytes per sample of plane 0 (and of the interleaved CbCr plane 1, twice that).
    const size_t sample = format == kCVPixelFormatType_32BGRA              ? 4
                          : format == kCVPixelFormatType_64RGBALE ||
                                    format == kCVPixelFormatType_64RGBAHalf ? 8
                          : isTenBitPixelFormat(format)                     ? 2
                                                                            : 1;
    PixelBufferLock lock(pb, true);
    const bool planar = CVPixelBufferIsPlanar(pb);
    const size_t planes = planar ? CVPixelBufferGetPlaneCount(pb) : 1;
    for (size_t p = 0; p < planes; ++p) {
        const auto *base = static_cast<const uint8_t *>(planar ? CVPixelBufferGetBaseAddressOfPlane(pb, p)
                                                               : CVPixelBufferGetBaseAddress(pb));
        const size_t stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(pb, p) : CVPixelBufferGetBytesPerRow(pb);
        const size_t rows = planar ? CVPixelBufferGetHeightOfPlane(pb, p) : CVPixelBufferGetHeight(pb);
        const size_t width = planar ? CVPixelBufferGetWidthOfPlane(pb, p) : CVPixelBufferGetWidth(pb);
        const size_t rowBytes = width * sample * (p == 1 ? 2 : 1);
        for (size_t y = 0; y < rows; ++y) {
            out.insert(out.end(), base + y * stride, base + y * stride + rowBytes);
        }
    }
    return out;
}

std::optional<VideoFrame> firstFrame(IMediaBackend &backend, const std::string &path, bool highPrecision,
                                     OSType *format = nullptr) {
    auto decoder = backend.makeVideoDecoder();
    DecodeOptions options;
    options.highPrecision = highPrecision;
    if (!decoder->open(path, -1, options).ok()) {
        return std::nullopt;
    }
    if (format != nullptr) {
        *format = decoder->outputPixelFormat();
    }
    auto frame = decoder->next();
    if (!frame.ok() || !frame.value()) {
        return std::nullopt;
    }
    return std::move(*frame.value());
}

} // namespace

@interface HighPrecisionDecodeTests : XCTestCase
@end

@implementation HighPrecisionDecodeTests {
    std::unique_ptr<Compositor> _compositor;
}

- (void)setUp {
    auto compositor = Compositor::create(device(), {MTLPixelFormatBGR10A2Unorm, MTLPixelFormatRGBA16Float});
    XCTAssertTrue(compositor.ok());
    if (compositor.ok()) {
        _compositor = std::move(compositor).value();
    }
}

/// Distinct red values along row `y` of what the monitor composites (its working texture, read as a scope
/// would) for `picture` shown at 1:1 in a picture-sized sequence.
- (std::set<float>)monitorLevelsOf:(const PixelBuffer &)picture still:(bool)still row:(size_t)y {
    RenderGraph graph = makeGraph(int32_t(picture.width()), int32_t(picture.height()));
    VideoLayer layer = makeLayer(1);
    layer.isStill = still;
    graph.layers.push_back(layer);
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGR10A2Unorm
                                                                                    width:picture.width()
                                                                                   height:picture.height()
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModePrivate;
    TextureTarget target([device() newTextureWithDescriptor:desc]);
    id<MTLTexture> copy = nil;
    id<MTLTexture> __strong *copyRef = &copy;
    target.workingFrameReader = [copyRef](id<MTLCommandBuffer> commandBuffer, id<MTLTexture> working, const PixelRect &) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:working.pixelFormat
                                                                                     width:working.width
                                                                                    height:working.height
                                                                                 mipmapped:NO];
        d.storageMode = MTLStorageModeShared;
        *copyRef = [device() newTextureWithDescriptor:d];
        id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
        [blit copyFromTexture:working toTexture:*copyRef];
        [blit endEncoding];
    };
    auto rendered = renderLayers(*_compositor, graph, {texturesFor(*_compositor, picture)}, target);
    XCTAssertTrue(rendered.ok() && rendered->status.ok() && rendered->skippedLayers.empty());
    std::set<float> levels;
    if (copy == nil) {
        return levels;
    }
    std::vector<uint16_t> row(picture.width() * 4);
    [copy getBytes:row.data()
        bytesPerRow:picture.width() * 8
         fromRegion:MTLRegionMake2D(0, y, picture.width(), 1)
        mipmapLevel:0];
    for (size_t x = 0; x < picture.width(); ++x) {
        levels.insert(halfToFloat(row[x * 4]));
    }
    return levels;
}

/// Distinct luma codes along row `y` of a 10-bit 'x420' export of `picture` at 1:1.
- (std::set<int>)exportLumaLevelsOf:(const PixelBuffer &)picture still:(bool)still row:(size_t)y {
    RenderGraph graph = makeGraph(int32_t(picture.width()), int32_t(picture.height()));
    VideoLayer layer = makeLayer(1);
    layer.isStill = still;
    graph.layers.push_back(layer);
    PixelBuffer out = makeBuffer(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, picture.width(), picture.height());
    auto rendered = renderLayers(*_compositor, graph, {texturesFor(*_compositor, picture)}, PixelBufferTarget{out});
    XCTAssertTrue(rendered.ok() && rendered->status.ok());
    std::set<int> levels;
    PixelBufferLock lock(out.get(), true);
    const auto *luma = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(out.get(), 0)) +
                       y * CVPixelBufferGetBytesPerRowOfPlane(out.get(), 0);
    for (size_t x = 0; x < picture.width(); ++x) {
        levels.insert(reinterpret_cast<const uint16_t *>(luma)[x] >> 6);
    }
    return levels;
}

- (void)testTwelveBitProRes4444KeepsItsPrecisionThroughTheCompositor {
    const std::string path = writeProRes4444Ramp(scratchDirectory() + "/ramp4444.mov");
    XCTAssertFalse(path.empty(), @"cannot write the ProRes 4444 ramp");
    if (path.empty()) {
        return;
    }
    for (const auto &backend : bothBackends()) {
        NSString *label = @(backend->name().c_str());
        OSType format = 0;
        auto deep = firstFrame(*backend, path, true, &format);
        auto shallow = firstFrame(*backend, path, false);
        XCTAssertTrue(deep && shallow, @"%@", label);
        if (!deep || !shallow) {
            continue;
        }
        XCTAssertEqual(format, kHighPrecisionRGBAFormat, @"%@", label);
        XCTAssertEqual(deep->image.pixelFormat(), kHighPrecisionRGBAFormat, @"%@", label);
        XCTAssertEqual(shallow->image.pixelFormat(), (OSType)kCVPixelFormatType_32BGRA, @"%@", label);
        XCTAssertFalse(deep->alphaIsPremultiplied, @"%@: straight alpha, as the BGRA output", label);
        const size_t decoded = distinctRed(deep->image, 8).size();
        const size_t decoded8 = distinctRed(shallow->image, 8).size();
        const size_t monitor = [self monitorLevelsOf:deep->image still:false row:8].size();
        const size_t monitor8 = [self monitorLevelsOf:shallow->image still:false row:8].size();
        const size_t exported = [self exportLumaLevelsOf:deep->image still:false row:8].size();
        const size_t exported8 = [self exportLumaLevelsOf:shallow->image still:false row:8].size();
        NSLog(@"%@ ProRes 4444 ramp, distinct levels in a row: decoded %zu (8-bit %zu), monitor working texture %zu "
              @"(8-bit %zu), 10-bit export luma %zu (8-bit %zu)",
              label, decoded, decoded8, monitor, monitor8, exported, exported8);
        XCTAssertGreaterThan(decoded, 512u, @"%@", label);
        XCTAssertLessThanOrEqual(decoded8, 256u, @"%@", label);
        XCTAssertGreaterThan(monitor, 512u, @"%@", label);
        XCTAssertLessThanOrEqual(monitor8, 256u, @"%@", label);
        XCTAssertGreaterThan(exported, 512u, @"%@", label);
        XCTAssertGreaterThan(exported, exported8, @"%@", label);
        // Straight alpha: the half-transparent rows keep their colour (not premultiplied) in the buffer.
        CVPixelBufferRef pb = deep->image.get();
        PixelBufferLock lock(pb, true);
        const auto *row = reinterpret_cast<const uint16_t *>(static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(pb)) +
                                                             (kHeight - 2) * CVPixelBufferGetBytesPerRow(pb));
        XCTAssertLessThanOrEqual(std::abs(int(row[800 * 4 + 3]) - 32768), 300, @"%@: alpha", label);
        XCTAssertLessThanOrEqual(std::abs(int(row[800 * 4]) - 800 * 64), 400, @"%@: colour not premultiplied", label);
    }
}

- (void)testSixteenBitPNGKeepsItsPrecisionOnBothBackends {
    const std::string path = writePNG(scratchDirectory() + "/ramp16.png", true);
    XCTAssertFalse(path.empty());
    if (path.empty()) {
        return;
    }
    for (const auto &backend : bothBackends()) {
        NSString *label = @(backend->name().c_str());
        auto deep = firstFrame(*backend, path, true);
        auto shallow = firstFrame(*backend, path, false);
        XCTAssertTrue(deep && shallow, @"%@", label);
        if (!deep || !shallow) {
            continue;
        }
        XCTAssertEqual(deep->image.pixelFormat(), kHighPrecisionRGBAFormat, @"%@", label);
        XCTAssertEqual(shallow->image.pixelFormat(), (OSType)kCVPixelFormatType_32BGRA, @"%@", label);
        XCTAssertTrue(deep->alphaIsPremultiplied, @"%@", label);
        const size_t decoded = distinctRed(deep->image, 8).size();
        const size_t monitor = [self monitorLevelsOf:deep->image still:true row:8].size();
        const size_t exported = [self exportLumaLevelsOf:deep->image still:true row:8].size();
        NSLog(@"%@ 16-bit PNG ramp, distinct levels in a row: decoded %zu (8-bit %zu), monitor %zu, 10-bit export "
              @"luma %zu",
              label, decoded, distinctRed(shallow->image, 8).size(), monitor, exported);
        XCTAssertGreaterThan(decoded, 1000u, @"%@", label);
        XCTAssertGreaterThan(monitor, 512u, @"%@", label);
        XCTAssertGreaterThan(exported, 512u, @"%@", label);
        // The same picture: within an 8-bit step of the 8-bit decode everywhere.
        const std::set<double> deepRow = distinctRed(deep->image, 8);
        XCTAssertLessThanOrEqual(std::fabs(*deepRow.begin() - 0.0), 1.0 / 255.0, @"%@", label);
        XCTAssertLessThanOrEqual(std::fabs(*deepRow.rbegin() - 1023.0 * 64.0 / 65535.0), 1.0 / 255.0, @"%@", label);
    }
}

- (void)testADisplayP3StillKeepsItsGamutAndRendersAsTheEightBitDecode {
    const std::string path = writePNG(scratchDirectory() + "/p3.png", false);
    XCTAssertFalse(path.empty());
    if (path.empty()) {
        return;
    }
    std::optional<std::array<float, 4>> appleRed;
    for (const auto &backend : bothBackends()) {
        NSString *label = @(backend->name().c_str());
        auto wide = firstFrame(*backend, path, true);
        XCTAssertTrue(wide.has_value(), @"%@", label);
        if (!wide) {
            continue;
        }
        XCTAssertEqual(wide->image.pixelFormat(), kExtendedRGBAFormat, @"%@", label);
        const std::array<float, 4> red = halfPixel(wide->image, 10, 10);
        NSLog(@"%@ Display P3 red in extended sRGB: %.4f %.4f %.4f %.4f", label, red[0], red[1], red[2], red[3]);
        // P3's red lies outside sRGB: above 1 in red, below 0 in green and blue.
        XCTAssertGreaterThan(red[0], 1.05f, @"%@", label);
        XCTAssertLessThan(red[1], -0.1f, @"%@", label);
        XCTAssertLessThan(red[2], -0.05f, @"%@", label);
        XCTAssertEqual(red[3], 1.0f, @"%@", label);
        if (!appleRed) {
            appleRed = red;
        } else {
            for (size_t c = 0; c < 3; ++c) {
                XCTAssertEqualWithAccuracy(red[c], (*appleRed)[c], 0.01, @"%@ matches the Apple decode", label);
            }
        }
    }
    // A Display P3 HEIC (an iPhone photo's colour space) through ImageIO likewise.
    const std::string heic = writePNG(scratchDirectory() + "/p3.heic", false, kCGColorSpaceDisplayP3, CFSTR("public.heic"));
    if (!heic.empty()) {
        auto photo = firstFrame(*apple::makeAppleBackend(), heic, true);
        XCTAssertTrue(photo.has_value());
        if (photo) {
            XCTAssertEqual(photo->image.pixelFormat(), kExtendedRGBAFormat);
            const std::array<float, 4> red = halfPixel(photo->image, 10, 10);
            XCTAssertGreaterThan(red[0], 1.05f);
            XCTAssertLessThan(red[1], -0.1f);
        }
    }
    // Rendered, it shows as the 8-bit decode does (the sampling limits it to [0, 1], as the decode to
    // 8-bit sRGB clipped it): the program monitor's pixels agree within one 10-bit code.
    auto apple = apple::makeAppleBackend();
    auto wide = firstFrame(*apple, path, true);
    auto narrow = firstFrame(*apple, path, false);
    XCTAssertTrue(wide && narrow);
    if (!wide || !narrow) {
        return;
    }
    XCTAssertEqual(narrow->image.pixelFormat(), (OSType)kCVPixelFormatType_32BGRA);
    auto render = [&](const PixelBuffer &picture) {
        RenderGraph graph = makeGraph(int32_t(kWidth), int32_t(kHeight));
        VideoLayer layer = makeLayer(1);
        layer.isStill = true;
        graph.layers.push_back(layer);
        id<MTLTexture> texture = makeTargetTexture(kWidth, kHeight);
        auto rendered = renderLayers(*_compositor, graph, {texturesFor(*_compositor, picture)}, TextureTarget(texture));
        XCTAssertTrue(rendered.ok() && rendered->status.ok());
        return texture;
    };
    id<MTLTexture> a = render(wide->image);
    id<MTLTexture> b = render(narrow->image);
    int largest = 0;
    for (size_t x = 0; x < kWidth; x += 7) {
        const RGBA8 p = texturePixel(a, x, 20);
        const RGBA8 q = texturePixel(b, x, 20);
        largest = std::max({largest, std::abs(p.r - q.r), std::abs(p.g - q.g), std::abs(p.b - q.b)});
    }
    NSLog(@"Display P3 still rendered from 'RGhA' and from 8-bit 'BGRA': largest difference %d (8-bit)", largest);
    XCTAssertLessThanOrEqual(largest, 1);
}

- (void)testAnAdobeRGBStillIsColourMatchedThroughItsICCProfileOnBothBackends {
    // Adobe RGB has no cICP code: the FFmpeg decoder finds the space in the ICC profile alone.
    const std::string path = writePNG(scratchDirectory() + "/adobe.png", false, kCGColorSpaceAdobeRGB1998);
    XCTAssertFalse(path.empty());
    if (path.empty()) {
        return;
    }
    std::optional<std::array<float, 4>> appleRed;
    for (const auto &backend : bothBackends()) {
        NSString *label = @(backend->name().c_str());
        auto wide = firstFrame(*backend, path, true);
        XCTAssertTrue(wide.has_value(), @"%@", label);
        if (!wide) {
            continue;
        }
        XCTAssertEqual(wide->image.pixelFormat(), kExtendedRGBAFormat, @"%@", label);
        const std::array<float, 4> red = halfPixel(wide->image, 10, 10);
        NSLog(@"%@ Adobe RGB red in extended sRGB: %.4f %.4f %.4f", label, red[0], red[1], red[2]);
        XCTAssertGreaterThan(red[0], 1.0f, @"%@: outside sRGB", label);
        if (!appleRed) {
            appleRed = red;
        } else {
            for (size_t c = 0; c < 3; ++c) {
                XCTAssertEqualWithAccuracy(red[c], (*appleRed)[c], 0.01, @"%@ matches the Apple decode", label);
            }
        }
    }
}

- (void)testEightBitSourcesAreUnchangedByHighPrecision {
    std::string error;
    const std::string still = testMediaPath("still.png", error);
    const std::string video = testMediaPath("gop5s_h264_1080p30.mp4", error);
    XCTAssertFalse(still.empty() || video.empty(), @"%s", error.c_str());
    if (still.empty() || video.empty()) {
        return;
    }
    for (const auto &backend : bothBackends()) {
        NSString *label = @(backend->name().c_str());
        for (const std::string &path : {still, video}) {
            OSType deepFormat = 0;
            OSType plainFormat = 0;
            auto deep = firstFrame(*backend, path, true, &deepFormat);
            auto plain = firstFrame(*backend, path, false, &plainFormat);
            XCTAssertTrue(deep && plain, @"%@ %s", label, path.c_str());
            if (!deep || !plain) {
                continue;
            }
            XCTAssertEqual(deepFormat, plainFormat, @"%@ %s", label, path.c_str());
            XCTAssertEqual(deep->image.pixelFormat(), plain->image.pixelFormat(), @"%@ %s", label, path.c_str());
            XCTAssertTrue(bytesOf(deep->image) == bytesOf(plain->image), @"%@ %s: the same bytes", label, path.c_str());
        }
    }
}

- (void)testTheTextureCacheMapsTheDeepFormatsAsRGBA {
    struct Case {
        OSType format;
        MTLPixelFormat expected;
    };
    for (const Case &c : {Case{kHighPrecisionRGBAFormat, MTLPixelFormatRGBA16Unorm},
                          Case{kExtendedRGBAFormat, MTLPixelFormatRGBA16Float}}) {
        XCTAssertTrue(TextureCache::supportsPixelFormat(c.format));
        PixelBuffer buffer = makeBuffer(c.format, 8, 4);
        const TextureSet set = texturesFor(*_compositor, buffer);
        XCTAssertTrue(static_cast<bool>(set));
        if (!set) {
            continue;
        }
        XCTAssertEqual(set.sourceClass(), SourceClass::RGBA);
        XCTAssertEqual(set.planeCount(), 1u);
        XCTAssertEqual(set.plane(0).pixelFormat, c.expected);
    }
}

- (void)testTheFrameCacheKeepsDecodeFormatsApart {
    FrameCache cache;
    const AssetId asset{7};
    const DecodeFormat deep{0, 0, true};
    PixelBuffer a = makeBuffer(kCVPixelFormatType_32BGRA, 16, 16);
    PixelBuffer b = makeBuffer(kHighPrecisionRGBAFormat, 16, 16);
    XCTAssertTrue(cache.put(asset, a, kCMTimeZero, CMTimeMake(1, 25), CMTimeMake(1, 25)));
    XCTAssertTrue(cache.put(FrameKey{asset, deep}, b, kCMTimeZero, CMTimeMake(1, 25), CMTimeMake(1, 25)));
    auto plain = cache.get(asset, kCMTimeZero);
    auto precise = cache.get(FrameKey{asset, deep}, kCMTimeZero);
    XCTAssertTrue(plain && precise);
    if (plain && precise) {
        XCTAssertEqual(plain->image.pixelFormat(), (OSType)kCVPixelFormatType_32BGRA);
        XCTAssertEqual(precise->image.pixelFormat(), kHighPrecisionRGBAFormat);
    }
    XCTAssertFalse(cache.contains(FrameKey{asset, DecodeFormat{0, 320, false}}, kCMTimeZero),
                   @"a thumbnail-sized format has nothing");
    XCTAssertEqual(cache.stats().count, 2u);
    cache.purge(asset); // every format of the asset
    XCTAssertEqual(cache.stats().count, 0u);
    XCTAssertFalse(cache.contains(FrameKey{asset, deep}, kCMTimeZero));
}

- (void)testADecodePoolPutsAndFindsItsFramesUnderItsOwnFormat {
    const std::string path = writePNG(scratchDirectory() + "/pool16.png", true);
    XCTAssertFalse(path.empty());
    if (path.empty()) {
        return;
    }
    auto router = std::make_shared<BackendRouter>();
    XCTAssertTrue(router->registerBackend(apple::makeAppleBackend()).ok());
    auto cache = std::make_shared<FrameCache>();
    DecodePool::Config config;
    config.decodeOptions.highPrecision = true;
    DecodePool pool(router, cache, config);
    XCTAssertTrue(pool.decodeFormat() == (DecodeFormat{0, 0, true}));
    const AssetId asset{3};
    pool.registerAsset(asset, path);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    auto delivered = std::make_shared<std::atomic<bool>>(false);
    pool.requestFrame(asset, kCMTimeZero, [delivered, done](Result<ScrubFrame> frame) {
        delivered->store(frame.ok());
        dispatch_semaphore_signal(done);
    });
    XCTAssertEqual(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)), 0);
    XCTAssertTrue(delivered->load());
    XCTAssertTrue(cache->contains(pool.frameKey(asset), kCMTimeZero));
    XCTAssertFalse(cache->contains(asset, kCMTimeZero), @"not under the default format");
    auto pinned = cache->acquire(pool.frameKey(asset), kCMTimeZero);
    XCTAssertTrue(static_cast<bool>(pinned));
    if (pinned) {
        XCTAssertEqual(pinned.image().pixelFormat(), kHighPrecisionRGBAFormat);
    }
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(5)));
}

- (void)testAMinifiedStraightAlphaDeepPictureIsPrescaledAtSixteenBitPrecision {
    const std::string path = writeProRes4444Ramp(scratchDirectory() + "/ramp4444-minified.mov");
    XCTAssertFalse(path.empty());
    if (path.empty()) {
        return;
    }
    auto apple = apple::makeAppleBackend();
    auto deep = firstFrame(*apple, path, true);
    XCTAssertTrue(deep.has_value());
    if (!deep) {
        return;
    }
    // The 1024-wide picture shown at 512 columns: Lanczos pre-scaled (premultiplied first), one level per
    // output column of 512 rather than the 256 an 8-bit pre-scale could hold.
    RenderGraph graph = makeGraph(512, 32);
    graph.sharpenMinified = false;
    graph.layers.push_back(makeLayer(1));
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                    width:512
                                                                                   height:32
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device() newTextureWithDescriptor:desc];
    TextureTarget target(texture);
    target.compositeDirectlyForTesting = true; // read the composite itself
    auto rendered = renderLayers(*_compositor, graph, {texturesFor(*_compositor, deep->image)}, target);
    XCTAssertTrue(rendered.ok() && rendered->status.ok());
    if (!rendered.ok()) {
        return;
    }
    XCTAssertEqual(rendered->prescaledPlanes, 1u);
    std::vector<uint16_t> row(512 * 4);
    [texture getBytes:row.data() bytesPerRow:512 * 8 fromRegion:MTLRegionMake2D(0, 4, 512, 1) mipmapLevel:0];
    std::set<float> levels;
    for (size_t x = 0; x < 512; ++x) {
        levels.insert(halfToFloat(row[x * 4]));
    }
    NSLog(@"Minified 'l64r' ramp: %zu distinct levels in 512 columns", levels.size());
    XCTAssertGreaterThan(levels.size(), 400u);
}

@end
