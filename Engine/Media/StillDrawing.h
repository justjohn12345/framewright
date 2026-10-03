// Drawing a decoded still (a CGImage) into the IOSurface-backed buffer the compositor samples, in
// the format DecodeOptions::highPrecision asks for. Shared by the Apple still decoder (ImageIO) and
// the FFmpeg one (which hands its decoded pixels to CoreGraphics when they need colour matching or
// more than 8 bits), so both store a still alike. The bitmap set-up and the tags are PictureDrawing's.

#pragma once

#include "PixelBuffer.h"
#include "Result.h"

#import <CoreGraphics/CoreGraphics.h>

namespace ve::media {

/// The buffer format `image` is stored in: '32BGRA' (8-bit sRGB), unless `highPrecision` and its
/// colour space is wide gamut ('RGhA', kExtendedRGBAFormat: half float in extended-range sRGB, so
/// colours outside sRGB are kept as values below 0 or above 1) or it has more than 8 bits per
/// component ('l64r', kHighPrecisionRGBAFormat: 16-bit sRGB).
OSType stillFormatFor(CGImageRef image, bool highPrecision);

/// `image` drawn (colour matched by CoreGraphics) into a new buffer of stillFormatFor(image,
/// highPrecision) at the image's size: premultiplied (tagged so), tagged BT.709 primaries / sRGB
/// transfer and with the ICC profile of the colour space it was drawn in.
Result<PixelBuffer> drawStillImage(CGImageRef image, bool highPrecision);

} // namespace ve::media
