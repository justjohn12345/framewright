// Still images (PNG, JPEG, HEIC, TIFF, ...) through ImageIO.
#pragma once

#include "../MediaTypes.h"
#include "../PixelBuffer.h"
#include "../Result.h"

#include <optional>
#include <string>

namespace ve::media::apple {

/// Returns the still-image description of `path` if ImageIO recognises it as an image, nullopt
/// if it is not an image (so the caller can try AVFoundation), or an error for a recognised but
/// unreadable image.
Result<std::optional<MediaInfo>> probeStillImage(const std::string &path);

/// Decodes the first image of `path` with its EXIF orientation applied, scaled to fit
/// maxDimension (0 = full size), into an IOSurface-backed 32BGRA buffer (premultiplied alpha,
/// sRGB, tagged BT.709 primaries / sRGB transfer).
///
/// Why BGRA rather than 420v: ImageIO decodes to RGB(A). Converting to 4:2:0 YCbCr would
/// discard alpha (PNG overlays), subsample chroma (visible on graphics and text), and force a
/// choice of matrix, all to produce one frame that the Metal compositor can sample directly
/// as BGRA anyway. The cost difference for one frame is irrelevant.
Result<PixelBuffer> decodeStillImage(const std::string &path, int maxDimension);

} // namespace ve::media::apple
