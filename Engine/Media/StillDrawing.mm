#include "StillDrawing.h"

#include "Interfaces.h"
#include "PictureDrawing.h"

namespace ve::media {

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
    const size_t width = CGImageGetWidth(image);
    const size_t height = CGImageGetHeight(image);
    return drawPicture(stillFormatFor(image, highPrecision), width, height, [&](CGContextRef ctx) {
        CGContextSetBlendMode(ctx, kCGBlendModeCopy);
        CGContextDrawImage(ctx, CGRectMake(0, 0, double(width), double(height)), image);
    });
}

} // namespace ve::media
