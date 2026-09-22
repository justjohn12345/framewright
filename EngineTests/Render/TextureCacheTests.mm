// TextureCache: every supported source format maps to the right plane textures with the
// pixel values the buffer holds; unsupported formats fail clearly.

#import <XCTest/XCTest.h>

#include "../../Engine/Render/TextureCache.h"
#include "CompositorTestSupport.h"

#include <string>

using namespace ve;
using namespace ve::render;
using namespace ve::rtest;

@interface TextureCacheTests : XCTestCase
@end

@implementation TextureCacheTests {
    TextureCache _cache;
}

- (void)setUp {
    auto cache = TextureCache::create(device());
    XCTAssertTrue(cache.ok());
    if (cache.ok()) {
        _cache = std::move(cache).value();
    }
}

struct FormatCase {
    OSType format;
    size_t chromaWidthDivisor;
    size_t chromaHeightDivisor;
    MTLPixelFormat luma;
    MTLPixelFormat chroma;
};

- (void)testEveryBiplanarFormatMapsWithKnownValues {
    const FormatCase cases[] = {
        {kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 2, 2, MTLPixelFormatR8Unorm, MTLPixelFormatRG8Unorm},
        {kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, 2, 2, MTLPixelFormatR8Unorm, MTLPixelFormatRG8Unorm},
        {kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, 2, 1, MTLPixelFormatR8Unorm, MTLPixelFormatRG8Unorm},
        {kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, 1, 1, MTLPixelFormatR8Unorm, MTLPixelFormatRG8Unorm},
        {kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, 2, 2, MTLPixelFormatR16Unorm, MTLPixelFormatRG16Unorm},
        {kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, 2, 2, MTLPixelFormatR16Unorm, MTLPixelFormatRG16Unorm},
        {kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, 2, 1, MTLPixelFormatR16Unorm, MTLPixelFormatRG16Unorm},
        {kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, 2, 1, MTLPixelFormatR16Unorm, MTLPixelFormatRG16Unorm},
        {kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, 1, 1, MTLPixelFormatR16Unorm, MTLPixelFormatRG16Unorm},
        {kCVPixelFormatType_444YpCbCr10BiPlanarFullRange, 1, 1, MTLPixelFormatR16Unorm, MTLPixelFormatRG16Unorm},
    };
    const size_t width = 64;
    const size_t height = 48;
    for (const FormatCase &c : cases) {
        const std::string name = fourCCString(c.format);
        media::PixelBuffer buffer = makeBuffer(c.format, width, height);
        XCTAssertTrue(buffer, @"cannot allocate %s", name.c_str());
        if (!buffer) {
            continue;
        }
        const int depth = bitDepthOf(c.format);
        const int y = depth == 8 ? 81 : 324;
        const int cb = depth == 8 ? 90 : 360;
        const int cr = depth == 8 ? 240 : 960;
        fillYCbCr(buffer, y, cb, cr, media::YCbCrMatrix::BT709);

        auto set = _cache.textures(buffer);
        XCTAssertTrue(set.ok(), @"%s: %s", name.c_str(), set.ok() ? "" : set.error().description().c_str());
        if (!set.ok()) {
            continue;
        }
        XCTAssertEqual(set->sourceClass(), SourceClass::YCbCrBiPlanar, @"%s", name.c_str());
        XCTAssertEqual(set->planeCount(), 2u);
        XCTAssertEqual(set->width(), width);
        XCTAssertEqual(set->height(), height);
        id<MTLTexture> luma = set->plane(0);
        id<MTLTexture> chroma = set->plane(1);
        XCTAssertEqual(luma.pixelFormat, c.luma, @"%s", name.c_str());
        XCTAssertEqual(chroma.pixelFormat, c.chroma, @"%s", name.c_str());
        XCTAssertEqual(luma.width, width);
        XCTAssertEqual(luma.height, height);
        XCTAssertEqual(chroma.width, width / c.chromaWidthDivisor, @"%s", name.c_str());
        XCTAssertEqual(chroma.height, height / c.chromaHeightDivisor, @"%s", name.c_str());

        // Read the texels back through the Metal textures (IOSurface aliasing, no copy).
        if (depth == 8) {
            uint8_t l = 0;
            uint8_t cc[2] = {};
            [luma getBytes:&l bytesPerRow:width fromRegion:MTLRegionMake2D(5, 7, 1, 1) mipmapLevel:0];
            [chroma getBytes:cc bytesPerRow:chroma.width * 2 fromRegion:MTLRegionMake2D(3, 2, 1, 1) mipmapLevel:0];
            XCTAssertEqual(l, y, @"%s", name.c_str());
            XCTAssertEqual(cc[0], cb, @"%s", name.c_str());
            XCTAssertEqual(cc[1], cr, @"%s", name.c_str());
        } else {
            uint16_t l = 0;
            uint16_t cc[2] = {};
            [luma getBytes:&l bytesPerRow:width * 2 fromRegion:MTLRegionMake2D(5, 7, 1, 1) mipmapLevel:0];
            [chroma getBytes:cc bytesPerRow:chroma.width * 4 fromRegion:MTLRegionMake2D(3, 2, 1, 1) mipmapLevel:0];
            XCTAssertEqual(l >> 6, y, @"%s", name.c_str());
            XCTAssertEqual(cc[0] >> 6, cb, @"%s", name.c_str());
            XCTAssertEqual(cc[1] >> 6, cr, @"%s", name.c_str());
        }
    }
}

- (void)testBGRAMapsToOneTexture {
    media::PixelBuffer buffer = makeBuffer(kCVPixelFormatType_32BGRA, 40, 30);
    fillBGRA(buffer, {10, 20, 30, 255});
    auto set = _cache.textures(buffer);
    XCTAssertTrue(set.ok());
    if (!set.ok()) {
        return;
    }
    XCTAssertEqual(set->sourceClass(), SourceClass::RGBA);
    XCTAssertEqual(set->planeCount(), 1u);
    XCTAssertNil(set->plane(1));
    XCTAssertEqual(set->plane(0).pixelFormat, MTLPixelFormatBGRA8Unorm);
    const RGBA8 p = texturePixel(set->plane(0), 12, 9);
    XCTAssertEqual(p.r, 10);
    XCTAssertEqual(p.g, 20);
    XCTAssertEqual(p.b, 30);
}

- (void)testUnsupportedFormatsFailWithTheFormatName {
    for (OSType format : {kCVPixelFormatType_422YpCbCr8, kCVPixelFormatType_32ARGB, kCVPixelFormatType_64RGBAHalf,
                          kCVPixelFormatType_420YpCbCr8Planar}) {
        media::PixelBuffer buffer = makeBuffer(format, 32, 32);
        XCTAssertTrue(buffer, @"cannot allocate %s", fourCCString(format).c_str());
        auto set = _cache.textures(buffer);
        XCTAssertFalse(set.ok());
        if (set.ok()) {
            continue;
        }
        XCTAssertEqual(set.error().code, media::MediaErrorCode::UnsupportedFormat);
        XCTAssertNotEqual(set.error().message.find(fourCCString(format)), std::string::npos,
                          @"%s", set.error().message.c_str());
        XCTAssertFalse(TextureCache::supportsPixelFormat(format));
    }
}

- (void)testNonIOSurfaceBufferIsRejected {
    CVPixelBufferRef raw = nullptr;
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nullptr, &raw),
                   kCVReturnSuccess);
    auto set = _cache.textures(media::PixelBuffer::adopt(raw));
    XCTAssertFalse(set.ok());
    if (!set.ok()) {
        XCTAssertEqual(set.error().code, media::MediaErrorCode::InvalidArgument);
    }
    auto empty = _cache.textures(media::PixelBuffer{});
    XCTAssertFalse(empty.ok());
}

- (void)testTexturesStayValidAcrossFlushWhileReferenced {
    media::PixelBuffer buffer = makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 32, 32);
    fillYCbCr(buffer, 100, 110, 120, media::YCbCrMatrix::BT709);
    TextureSet copy;
    {
        auto set = _cache.textures(buffer);
        XCTAssertTrue(set.ok());
        if (!set.ok()) {
            return;
        }
        copy = set.value();
    }
    buffer.reset(); // the TextureSet keeps the pixel buffer alive
    _cache.flush();
    XCTAssertTrue(copy);
    XCTAssertTrue(copy.pixelBuffer());
    uint8_t l = 0;
    [copy.plane(0) getBytes:&l bytesPerRow:32 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
    XCTAssertEqual(l, 100);
}

- (void)testWritableTexturesForTargets {
    media::PixelBuffer buffer = makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 32, 32);
    auto set = _cache.textures(buffer, TextureAccess::ReadWrite);
    XCTAssertTrue(set.ok());
    if (set.ok()) {
        XCTAssertTrue((set->plane(0).usage & MTLTextureUsageShaderWrite) != 0);
        XCTAssertTrue((set->plane(1).usage & MTLTextureUsageShaderWrite) != 0);
    }
}

@end
