#pragma once

#include "../Interfaces.h"

#include <memory>

namespace ve::media::ffmpeg {

/// IVideoDecoder over libavformat + libavcodec. Not thread-safe (see Interfaces.h): one thread
/// at a time; FFmpeg's own decoder threads (software frame/slice threading) are internal.
///
/// Hardware: when DecodeOptions::allowHardware is set and HardwareCaps reports the codec as
/// hardware-decodable, the codec context gets an AV_HWDEVICE_TYPE_VIDEOTOOLBOX device and a
/// get_format callback that picks AV_PIX_FMT_VIDEOTOOLBOX. Frames then carry their
/// CVPixelBufferRef in data[3]; it is retained into the returned PixelBuffer (the AVFrame's
/// reference is dropped right after), so native-format frames are zero copy. If VideoToolbox
/// refuses the stream, libavcodec asks get_format again and decoding continues in software.
/// VideoFrame::wasHardwareDecoded / usedHardware() report the format of the frame actually
/// delivered, so they are exact.
///
/// Software frames are copied (or, where no plane copy exists, converted with libswscale) into
/// IOSurface-backed buffers from a CVPixelBufferPool; see FFFrameConverter.h for the table.
///
/// Timestamps: AVFrame::best_effort_timestamp in the stream time base, converted to CMTime
/// with the time base as timescale (exact). Containers whose time base cannot represent the
/// frame duration (Matroska/WebM store milliseconds, so 1/30 s becomes 33 or 34 ms) are
/// quantised: for constant-rate tracks, timestamps within half a time-base tick of the nominal
/// frame grid (trackStart + n * frameDuration) are snapped to it, so a 29.97 fps MKV yields the
/// same CMTimes as the same frames in a QuickTime file.
///
/// Seeking: seek(t) ahead of the current position by at most kCloseAheadSeconds decodes
/// forward. Otherwise it seeks the demuxer to the last keyframe at or before t
/// (avformat_seek_file with max_ts = t), flushes the decoder and decodes forward, dropping
/// frames that end at or before t. Packets before the first keyframe after the seek are not
/// decoded, and frames presented before that keyframe (open-GOP leading pictures, e.g. HEVC
/// RASL, which reference the previous GOP) are discarded. If the keyframe the demuxer lands
/// on is presented after t (demuxers that seek by dts, or a target among the leading pictures
/// of an open GOP), the seek is retried further back, and after a few attempts from the start
/// of the stream.
///
/// Stills (image demuxers) decode once in open() into a 32BGRA buffer with the EXIF
/// orientation applied (see FFStillImage.h); next() returns that frame (pts 0, duration
/// +infinity) once after open() and once per seek().
class FFVideoDecoder final : public IVideoDecoder {
  public:
    /// Same trade-off as AppleVideoDecoder::kCloseAheadSeconds.
    static constexpr double kCloseAheadSeconds = 2.0;
    /// Software decoding threads per decoder (the decode pool runs several decoders at once).
    static constexpr int kMaxSoftwareThreads = 4;

    FFVideoDecoder();
    ~FFVideoDecoder() override;
    FFVideoDecoder(const FFVideoDecoder &) = delete;
    FFVideoDecoder &operator=(const FFVideoDecoder &) = delete;

    Status open(const std::string &path, int trackIndex, const DecodeOptions &options) override;
    Status seek(CMTime t) override;
    Result<std::optional<VideoFrame>> next() override;
    CMTime frameDuration() const override;
    bool supportsRandomAccess() const override;
    bool usedHardware() const override;
    OSType outputPixelFormat() const override;

    /// Test hook: demuxer seeks performed so far (close-ahead seeks do not count).
    int demuxerSeekCount() const;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace ve::media::ffmpeg
