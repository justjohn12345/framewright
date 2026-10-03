#include "PictureDrawing.h"

#include "CFRef.h"
#include "ColorTags.h"
#include "Interfaces.h"

namespace ve::media {

DrawingLayout drawingLayoutOf(OSType format) {
    DrawingLayout layout;
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

Result<PixelBuffer> drawPicture(OSType format, size_t width, size_t height,
                                const std::function<void(CGContextRef)> &draw) {
    const DrawingLayout layout = drawingLayoutOf(format);
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
        draw(ctx.get());
        CFRef<CFDataRef> icc = CFRef<CFDataRef>::adopt(CGColorSpaceCopyICCData(space.get()));
        if (icc) {
            CVBufferSetAttachment(pb, kCVImageBufferICCProfileKey, icc.get(), kCVAttachmentMode_ShouldPropagate);
        }
    }
    attachColorInfo(pb, {ColorPrimaries::BT709, TransferFunction::SRGB, YCbCrMatrix::Unknown, true});
    setAlphaMode(pb, true); // CoreGraphics draws premultiplied.
    return std::move(buffer).value();
}

} // namespace ve::media
