#pragma once

#include "../Interfaces.h"

#include <memory>

namespace ve::media::ffmpeg {

/// IVideoEncoder over libavcodec. Not thread-safe (see Interfaces.h).
///
/// Encoder choice:
/// - H.264 / HEVC / ProRes 422: h264_videotoolbox / hevc_videotoolbox / prores_videotoolbox.
///   When HardwareCaps reports a hardware encoder for the codec, VideoToolbox is required to use
///   it (allow_sw=0) and usesHardware() is true. Otherwise (or if the hardware session cannot be
///   created and requireHardware is false) VideoToolbox's software encoder is required
///   (allow_sw=1, require_sw=1) and usesHardware() is false: either way the answer is a fact.
///   requireHardware without a hardware encoder fails with UnsupportedCodec.
/// - ProRes falls back to FFmpeg's prores_ks (software, LGPL) if no VideoToolbox ProRes encoder
///   can be opened. The LGPL build has no software H.264/HEVC encoder.
/// - AV1: libsvtav1 (SVT-AV1, BSD, linked into libavcodec when built with ENABLE_SVTAV1=1),
///   always software (usesHardware() false; requireHardware fails). Preset 8; averageBitRate
///   gives VBR at that rate, otherwise quality maps to a CRF (0.5 -> 35, 1.0 -> 10). 8-bit input
///   is converted to yuv420p, 10-bit input ('x420') to yuv420p10le (10-bit AV1), with
///   libswscale on the CPU.
///
/// Input: the PixelBuffer's CVPixelBuffer is handed to VideoToolbox as an AV_PIX_FMT_VIDEOTOOLBOX
/// frame (no copy; the frame keeps the buffer retained until the encoder releases it), with
/// sw_pix_fmt describing its layout ('BGRA' -> bgra, '420v' -> nv12, 'x420' -> p010 so HEVC
/// picks Main10, ...). For prores_ks the buffer is converted on the CPU with libswscale.
///
/// Output: packets in decode order with pts/dts in 1/frameDuration.timescale (so a 1001/30000
/// frame duration gives timescale 30000). The first 16 packets are held back until the reorder
/// depth is known (FFmpeg's VideoToolbox wrapper assumes one frame of H.264 reordering,
/// VideoToolbox may use two), then every dts is shifted so that dts <= pts; flush() releases what
/// is held.
///
/// Bitstream format: VideoToolbox through FFmpeg emits Annex B H.264/HEVC access units, and
/// EncodedStreamFormat::extradata holds the parameter sets in Annex B form (not an avcC/hvcC
/// record); FFMuxer (libavformat) converts both to avcC/hvcC and length-prefixed samples when
/// writing MP4/MOV/MKV.
class FFVideoEncoder final : public IVideoEncoder {
  public:
    FFVideoEncoder();
    ~FFVideoEncoder() override;
    FFVideoEncoder(const FFVideoEncoder &) = delete;
    FFVideoEncoder &operator=(const FFVideoEncoder &) = delete;

    Status open(const VideoEncodeSettings &settings) override;
    Result<EncodedStreamFormat> outputFormat() const override;
    Status encode(const PixelBuffer &frame, CMTime pts, const PacketSink &sink) override;
    Status flush(const PacketSink &sink) override;
    bool usesHardware() const override;

    /// FFmpeg encoder name in use ("hevc_videotoolbox", "prores_ks", ...), empty before open().
    std::string encoderName() const;
    std::string name() const override;

    /// Whether this FFmpeg build has the encoder for `codec` (libsvtav1 for AV1, the
    /// VideoToolbox wrapper otherwise). Thread-safe.
    static bool isAvailable(VideoCodec codec);

    /// Validates settings without opening anything (shared with FFmpegBackend::canWrite).
    static Status validate(const VideoEncodeSettings &settings);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace ve::media::ffmpeg
