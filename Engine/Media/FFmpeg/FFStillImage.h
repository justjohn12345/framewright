// Still images (PNG, JPEG, BMP, TIFF, WebP, GIF first frame) through libavformat's image pipe
// demuxers and libavcodec. HEIF/AVIF are not handled (see FFmpegBackend.h).
#pragma once

#include "../MediaTypes.h"
#include "../PixelBuffer.h"
#include "../Result.h"
#include "FFmpegSupport.h"

#include <string>

namespace ve::media::ffmpeg {

struct DecodedStill {
    FramePtr frame;      ///< Decoded image as stored (before orientation).
    int orientation = 1; ///< EXIF orientation 1...8 (1 = as stored).
    int width = 0;       ///< Display width (after orientation).
    int height = 0;      ///< Display height (after orientation).
    uint32_t codec = 0;  ///< Four-cc ('png ', 'jpeg', ...).
};

/// Decodes the single image of an input opened by openInput() whose demuxer is an image
/// demuxer (isImageDemuxer()).
Result<DecodedStill> decodeStill(AVFormatContext *input);

/// The still track description (index 0, display size, sRGB tags) matching AppleProber's.
TrackInfo stillTrackInfo(const DecodedStill &still);

/// Renders a decoded still, EXIF orientation applied and scaled to fit maxDimension (0 = full
/// size, but never more than kMaxImageDimension per side), into an IOSurface-backed 32BGRA
/// buffer with premultiplied alpha (tagged kCVImageBufferAlphaChannelMode_PremultipliedAlpha),
/// tagged BT.709 primaries / sRGB transfer: the same output as AppleVideoDecoder for stills.
/// With `highPrecision` (DecodeOptions::highPrecision), a picture deeper than 8 bits or in a
/// wide-gamut space (its embedded ICC profile, else its cICP tags: Display P3, BT.2020) is converted
/// to 16-bit RGBA instead, handed to CoreGraphics in that space (sRGB without one) and stored as the
/// Apple decoder stores such a still ('RGhA' for wide gamut, else 'l64r'; StillDrawing.h): the profile
/// is honoured.
Result<PixelBuffer> renderStill(const DecodedStill &still, int maxDimension, bool highPrecision);

} // namespace ve::media::ffmpeg
