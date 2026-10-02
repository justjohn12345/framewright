#include "StillDrawing.h"

#include "CFRef.h"
#include "ColorTags.h"
#include "Interfaces.h"

namespace ve::media {

namespace {

// How a format is drawn: the colour space CoreGraphics matches into and the bitmap layout.
struct StillLayout {
    CFStringRef colorSpace = kCGColorSpaceSRGB;
    size_t bitsPerComponent = 8;
    uint32_t bitmapInfo = static_cast<uint32_t>(kCGImageAlphaPremultipliedFirst) |
                          static_cast<uint32_t>(kCGBitmapByteOrder32Little);
};

StillLayout layoutOf(OSType format) {
    StillLayout layout;
    if (format == kExtendedRGBAFormat) {
        layout.colorSpace = kCGColorSpaceExtendedSRGB;
        layout.bitsPerComponent = 16;
        layout.bitmapInfo = static_cast<uint32_t>(kCGImageAlphaPremultipliedLast) |
                            static_cast<uint32_t>(kCGBitmapByteOrder16Little) |
                            static_cast<uint32_t>(kCGBitmapFloatComponents);
    } else if (format == kHighPrecisionRGBAFormat) {
        layout.bitsPerComponent = 16;
        layout.bitmapInfo = static_cast<uint32_t>(kCGImageAlphaPremultipliedLast) |
                            static_cast<uint32_t>(kCGBitmapByteOrder16Little);
    }
    return layout;
}

} // namespace

OSType stillFormatFor(CGImageRef image, bool highPrecision) {
    if (!highPrecision || image == nullptr) {
        return kCVPixelFormatType_32BGRA;
    }
    CGColorSpaceRef space = CGImageGetColorSpace(image);
    if (space != nullptr && CGColorSpaceIsWideGamutRGB(space)) {
        return kExtendedRGBAFormat;
    }
    return CGImageGetBitsPerComponent(image) > 8 ? kHighPrecisionRGBAFormat : kCVPixelFormatType_32BGRA;
}

Result<PixelBuffer> drawStillImage(CGImageRef image, bool highPrecision) {
    if (image == nullptr) {
        return makeError(MediaErrorCode::InvalidArgument, "drawStillImage: no image");
    }
    const OSType format = stillFormatFor(image, highPrecision);
    const StillLayout layout = layoutOf(format);
    const size_t width = CGImageGetWidth(image);
    const size_t height = CGImageGetHeight(image);
    auto pool = PixelBufferPool::create(format, width, height);
    if (!pool.ok()) {
        return std::move(pool).error();
    }
    auto buffer = pool->makeBuffer();
    if (!buffer.ok()) {
        return std::move(buffer).error();
    }
    CVPixelBufferRef pb = buffer->get();
    {
        PixelBufferLock lock(pb, false);
        if (!lock.locked()) {
            return makeError(MediaErrorCode::Internal, "CVPixelBufferLockBaseAddress failed");
        }
        CFRef<CGColorSpaceRef> space = CFRef<CGColorSpaceRef>::adopt(CGColorSpaceCreateWithName(layout.colorSpace));
        CFRef<CGContextRef> ctx = CFRef<CGContextRef>::adopt(
            CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), width, height, layout.bitsPerComponent,
                                  CVPixelBufferGetBytesPerRow(pb), space.get(), layout.bitmapInfo));
        if (!ctx) {
            return makeError(MediaErrorCode::Internal, "CGBitmapContextCreate failed");
        }
        CGContextSetBlendMode(ctx.get(), kCGBlendModeCopy);
        CGContextDrawImage(ctx.get(), CGRectMake(0, 0, double(width), double(height)), image);
        CFRef<CFDataRef> icc = CFRef<CFDataRef>::adopt(CGColorSpaceCopyICCData(space.get()));
        if (icc) {
            CVBufferSetAttachment(pb, kCVImageBufferICCProfileKey, icc.get(), kCVAttachmentMode_ShouldPropagate);
        }
    }
    attachColorInfo(pb, {ColorPrimaries::BT709, TransferFunction::SRGB, YCbCrMatrix::Unknown, true});
    setAlphaMode(pb, true); // CoreGraphics drew premultiplied.
    return std::move(buffer).value();
}

} // namespace ve::media
