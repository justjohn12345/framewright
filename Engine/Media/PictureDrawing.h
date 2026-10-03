// Drawing a picture with CoreGraphics into a new IOSurface-backed buffer the compositor samples: the
// buffer formats CoreGraphics can draw into, the bitmap context over a buffer's memory, and the tags
// every such picture carries (premultiplied alpha, BT.709 primaries with the sRGB transfer, the ICC
// profile of the colour space it was drawn in). Shared by StillDrawing (a decoded still) and the
// generated pictures (titles and colour mattes, drawn in memory), so both store a picture alike.

#pragma once

#include "PixelBuffer.h"
#include "Result.h"

#import <CoreGraphics/CoreGraphics.h>

#include <cstddef>
#include <cstdint>
#include <functional>

namespace ve::media {

/// How a buffer format is drawn: the colour space CoreGraphics matches into and the bitmap layout.
struct DrawingLayout {
    CFStringRef colorSpace = kCGColorSpaceSRGB;
    size_t bitsPerComponent = 8;
    uint32_t bitmapInfo = static_cast<uint32_t>(kCGImageAlphaPremultipliedFirst) |
                          static_cast<uint32_t>(kCGBitmapByteOrder32Little);
};

/// The layout of `format`: '32BGRA' (8-bit sRGB, premultiplied, the default), 'RGhA'
/// (kExtendedRGBAFormat: half float in extended-range sRGB, premultiplied) or 'l64r'
/// (kHighPrecisionRGBAFormat: 16-bit sRGB, premultiplied).
DrawingLayout drawingLayoutOf(OSType format);

/// A new `width` x `height` buffer of `format` (one of drawingLayoutOf's), its memory drawn by `draw`
/// through a CGBitmapContext in the format's layout (CoreGraphics' coordinates: origin bottom left, one
/// unit a pixel; the memory starts as the pool gives it, so `draw` covers every pixel), then tagged:
/// premultiplied, BT.709 primaries / sRGB transfer, and the ICC profile of the layout's colour space.
Result<PixelBuffer> drawPicture(OSType format, size_t width, size_t height, const std::function<void(CGContextRef)> &draw);

} // namespace ve::media
