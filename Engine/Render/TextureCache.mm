#include "TextureCache.h"

#include "../Media/ColorTags.h"
#include "ColorMath.h"

#include <mach/mach_time.h>

#include <utility>

namespace ve::render {

using media::CFRef;
using media::makeError;
using media::MediaErrorCode;
using media::PixelBuffer;
using media::Result;

namespace {

struct FormatLayout {
    SourceClass sourceClass;
    MTLPixelFormat plane0;
    MTLPixelFormat plane1; // MTLPixelFormatInvalid for single-plane formats
    int bitDepth;
    bool fullRange;
};

bool layoutFor(OSType format, FormatLayout &out) {
    switch (format) {
    case kCVPixelFormatType_32BGRA:
        out = {SourceClass::RGBA, MTLPixelFormatBGRA8Unorm, MTLPixelFormatInvalid, 8, true};
        return true;
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
        out = {SourceClass::YCbCrBiPlanar, MTLPixelFormatR8Unorm, MTLPixelFormatRG8Unorm, 8,
               media::isFullRangeYCbCr(format)};
        return true;
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
        out = {SourceClass::YCbCrBiPlanar, MTLPixelFormatR16Unorm, MTLPixelFormatRG16Unorm, 10,
               media::isFullRangeYCbCr(format)};
        return true;
    default:
        return false;
    }
}

media::YCbCrMatrix matrixOf(CVPixelBufferRef buffer) {
    CFRef<CFTypeRef> value =
        CFRef<CFTypeRef>::adopt(CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nullptr));
    media::YCbCrMatrix matrix = media::YCbCrMatrix::Unknown;
    if (value && CFGetTypeID(value.get()) == CFStringGetTypeID()) {
        matrix = media::yCbCrMatrixFromCV(static_cast<CFStringRef>(value.get()));
    }
    if (matrix == media::YCbCrMatrix::Unknown) {
        matrix = CVPixelBufferGetHeight(buffer) >= 720 ? media::YCbCrMatrix::BT709 : media::YCbCrMatrix::BT601;
    }
    return matrix;
}

double secondsFromMachTicks(std::uint64_t ticks) {
    static const double scale = [] {
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);
        return static_cast<double>(info.numer) / static_cast<double>(info.denom) * 1e-9;
    }();
    return static_cast<double>(ticks) * scale;
}

} // namespace

std::string fourCCString(OSType code) {
    std::string s;
    for (int shift = 24; shift >= 0; shift -= 8) {
        const char c = static_cast<char>((code >> shift) & 0xFF);
        s += (c >= 32 && c < 127) ? c : '?';
    }
    return s;
}

bool TextureCache::supportsPixelFormat(OSType pixelFormat) {
    FormatLayout layout;
    return layoutFor(pixelFormat, layout);
}

Result<TextureCache> TextureCache::create(id<MTLDevice> device) {
    if (device == nil) {
        return makeError(MediaErrorCode::InvalidArgument, "TextureCache: no Metal device");
    }
    TextureCache cache;
    const CVReturn rc = CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device, nullptr, cache.cache_.outPtr());
    if (rc != kCVReturnSuccess || !cache.cache_) {
        return makeError(MediaErrorCode::Internal, "CVMetalTextureCacheCreate failed", "CVReturn", rc);
    }
    cache.device_ = device;
    cache.lastFlush_.store(mach_absolute_time(), std::memory_order_relaxed);
    return cache;
}

TextureCache::TextureCache(TextureCache &&other) noexcept
    : device_(other.device_), cache_(std::move(other.cache_)),
      lastFlush_(other.lastFlush_.load(std::memory_order_relaxed)) {
    other.device_ = nil;
}

TextureCache &TextureCache::operator=(TextureCache &&other) noexcept {
    if (this != &other) {
        device_ = other.device_;
        other.device_ = nil;
        cache_ = std::move(other.cache_);
        lastFlush_.store(other.lastFlush_.load(std::memory_order_relaxed), std::memory_order_relaxed);
    }
    return *this;
}

void TextureCache::flush() const {
    if (cache_) {
        CVMetalTextureCacheFlush(cache_.get(), 0);
        lastFlush_.store(mach_absolute_time(), std::memory_order_relaxed);
    }
}

Result<TextureSet> TextureCache::textures(const PixelBuffer &buffer, TextureAccess access) const {
    if (!cache_) {
        return makeError(MediaErrorCode::InvalidState, "TextureCache: not created");
    }
    if (!buffer) {
        return makeError(MediaErrorCode::InvalidArgument, "TextureCache: empty pixel buffer");
    }
    const OSType format = buffer.pixelFormat();
    FormatLayout layout;
    if (!layoutFor(format, layout)) {
        return makeError(MediaErrorCode::UnsupportedFormat,
                         "TextureCache: unsupported pixel format '" + fourCCString(format) + "'");
    }
    if (!buffer.isIOSurfaceBacked()) {
        return makeError(MediaErrorCode::InvalidArgument,
                         "TextureCache: pixel buffer is not IOSurface backed (cannot map to Metal without a copy)");
    }

    const std::uint64_t now = mach_absolute_time();
    const std::uint64_t last = lastFlush_.load(std::memory_order_relaxed);
    if (secondsFromMachTicks(now - last) >= kFlushInterval) {
        std::uint64_t expected = last;
        if (lastFlush_.compare_exchange_strong(expected, now, std::memory_order_relaxed)) {
            CVMetalTextureCacheFlush(cache_.get(), 0);
        }
    }

    CVPixelBufferRef pb = buffer.get();
    const bool planar = layout.plane1 != MTLPixelFormatInvalid;
    if (planar != (CVPixelBufferIsPlanar(pb) && CVPixelBufferGetPlaneCount(pb) == 2)) {
        return makeError(MediaErrorCode::InvalidArgument, "TextureCache: plane count does not match format '" +
                                                              fourCCString(format) + "'");
    }

    static NSDictionary *const writableAttributes = @{
        (__bridge NSString *)kCVMetalTextureUsage : @(MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite)
    };
    NSDictionary *attributes = access == TextureAccess::ReadWrite ? writableAttributes : nil;

    TextureSet set;
    set.buffer_ = buffer;
    set.sourceClass_ = layout.sourceClass;
    set.pixelFormat_ = format;
    set.width_ = buffer.width();
    set.height_ = buffer.height();
    const std::size_t planeCount = planar ? 2 : 1;
    for (std::size_t i = 0; i < planeCount; ++i) {
        const size_t w = planar ? CVPixelBufferGetWidthOfPlane(pb, i) : CVPixelBufferGetWidth(pb);
        const size_t h = planar ? CVPixelBufferGetHeightOfPlane(pb, i) : CVPixelBufferGetHeight(pb);
        const MTLPixelFormat mtlFormat = i == 0 ? layout.plane0 : layout.plane1;
        const CVReturn rc = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache_.get(), pb, (__bridge CFDictionaryRef)attributes, mtlFormat, w, h, i,
            set.refs_[i].outPtr());
        if (rc != kCVReturnSuccess || !set.refs_[i]) {
            return makeError(MediaErrorCode::Internal,
                             "CVMetalTextureCacheCreateTextureFromImage failed for plane " + std::to_string(i) +
                                 " of '" + fourCCString(format) + "'",
                             "CVReturn", rc);
        }
        set.planes_[i] = CVMetalTextureGetTexture(set.refs_[i].get());
        if (set.planes_[i] == nil) {
            return makeError(MediaErrorCode::Internal, "CVMetalTextureGetTexture returned nil");
        }
    }

    if (layout.sourceClass == SourceClass::YCbCrBiPlanar) {
        YCbCrEncoding encoding;
        encoding.matrix = matrixOf(pb);
        encoding.bitDepth = layout.bitDepth;
        encoding.fullRange = layout.fullRange;
        encoding.msbPacked16 = layout.bitDepth > 8;
        set.colorMatrix_ = yCbCrToRGBMatrix(encoding);
    }
    return set;
}

} // namespace ve::render
