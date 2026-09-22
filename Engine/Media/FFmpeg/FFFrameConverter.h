// Turns decoded AVFrames (software or VideoToolbox) into IOSurface-backed CVPixelBuffers in the
// engine's working formats.
//
// Native output format (DecodeOptions::pixelFormat == 0) from the source's AVPixelFormat:
//
//   source (software decoder output)                      CoreVideo output      how
//   ---------------------------------------------------   -------------------   ----------------------------
//   yuv420p, yuvj420p, nv12, nv21, gray                   '420v' / '420f'       plane copy (U/V interleaved)
//   yuv420p10/12/16, p010, p016                           'x420' / 'xf20'       plane copy, MSB-aligned
//   yuv422p, yuvj422p, yuv422p10/12/16, nv16, p210, p216  'x422' / 'xf22'       plane copy, MSB-aligned
//   yuv444p, yuvj444p, yuv444p10/12/16, nv24, p410, p416  'x444' / 'xf44'       plane copy, MSB-aligned
//   formats with alpha (yuva*, rgba, ...) and RGB/palette 'BGRA'                libswscale
//   anything else (big-endian, packed 4:2:2, ...)          by chroma/depth above libswscale
//
//   VideoToolbox hwaccel frames (AV_PIX_FMT_VIDEOTOOLBOX, data[3] = CVPixelBufferRef) arrive as
//   '420v'/'420f' (8-bit 4:2:0), 'x420' (10-bit 4:2:0), 'x422' (10-bit 4:2:2), '422v' (8-bit
//   4:2:2), 'x444'/'444v' (4:4:4) or 'y416' (with alpha). They are passed through untouched
//   (retained, zero copy) when that is the native format above, and otherwise converted on the
//   GPU with VTPixelTransferSession (e.g. '422v' -> 'x422', 'y416' -> 'BGRA').
//
// Video vs full range follows the source (color_range, or the yuvj* formats). An explicit
// DecodeOptions::pixelFormat, and scaling (maxDimension), go through libswscale for software
// frames (writing straight into the CVPixelBuffer's planes) and VTPixelTransferSession for
// hardware frames. Every output buffer is tagged with attachColorInfo().
//
// Not thread-safe: owned by one decoder.
#pragma once

#include "../CFRef.h"
#include "../MediaTypes.h"
#include "../PixelBuffer.h"
#include "../Result.h"
#include "FFmpegSupport.h"

#include <VideoToolbox/VideoToolbox.h>

namespace ve::media::ffmpeg {

/// The native CoreVideo format for frames of `format` (see the table above).
OSType nativePixelFormat(AVPixelFormat format, bool fullRange);
/// The AVPixelFormat whose memory layout equals CoreVideo `format` (for libswscale output), or
/// AV_PIX_FMT_NONE.
AVPixelFormat avPixelFormatForCV(OSType format);

class FrameConverter {
  public:
    FrameConverter() = default;
    ~FrameConverter();
    FrameConverter(const FrameConverter &) = delete;
    FrameConverter &operator=(const FrameConverter &) = delete;

    /// `outputFormat` must be non-zero; `width`/`height` of 0 keep the frame's size.
    Status configure(OSType outputFormat, int width, int height);

    /// Converts (or, for VideoToolbox frames already in the output format, retains) `frame`.
    /// `color` is attached to the result.
    Result<PixelBuffer> convert(const AVFrame *frame, const ColorInfo &color);

  private:
    Result<PixelBuffer> convertHardware(CVPixelBufferRef source, const ColorInfo &color);
    Result<PixelBuffer> convertSoftware(const AVFrame *frame, const ColorInfo &color);
    Status ensurePool(int width, int height);

    OSType format_ = 0;
    int width_ = 0;
    int height_ = 0;
    PixelBufferPool pool_;
    SwsPtr sws_;
    CFRef<VTPixelTransferSessionRef> transfer_;
};

} // namespace ve::media::ffmpeg
