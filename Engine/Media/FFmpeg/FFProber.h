#pragma once

#include "../Interfaces.h"
#include "FFmpegSupport.h"

namespace ve::media::ffmpeg {

/// IMediaProber over libavformat (avformat_open_input + avformat_find_stream_info).
///
/// TrackInfo::index is the AVStream index. Only audio and video streams are reported
/// (attached pictures, subtitles and data streams are skipped). Timing:
/// - isVFR: the declared rates disagree (r_frame_rate vs avg_frame_rate by more than 1 %), or
///   the packet timestamps of the first seconds show intervals that differ by more than a
///   time-base tick and 1 % (scanFrameTiming): containers may declare a constant rate for
///   variable-rate video (a Matroska DefaultDuration), so the timestamps are the evidence.
/// - frameDuration: 1 / avg_frame_rate for constant-rate video; for variable-rate video the
///   shortest observed interval (else 1 / r_frame_rate). nominalFps is avg_frame_rate.
/// - startTime/duration: AVStream start_time/duration; for Matroska (no per-stream duration)
///   the track's DURATION tag, else the container duration. ISO-BMFF AAC with iTunSMPB gapless
///   info (and no edit list) is placed with its first real sample at 0 and the iTunSMPB length,
///   as AVFoundation does (see audioTimelineShift).
/// - MediaInfo::duration: the latest track end.
/// A stream without a stated duration (a recording that was never finalised: "live" Matroska
/// has neither a segment Duration nor DURATION tags) gets one measured from its packets (a
/// packet-only pass over the file, no decoding). A track whose duration still cannot be
/// determined is left out (logged) rather than failing the probe; the probe fails
/// (CorruptData) only when no track is left.
/// Capability: decodable = libavcodec has a decoder for the codec and, for video, opening a
/// decoder produced the first frame; hardwareDecode = that first frame came out of VideoToolbox
/// (AV_PIX_FMT_VIDEOTOOLBOX), i.e. measured with the decoder the backend will use.
/// Stills (image demuxers) are decoded once to learn their EXIF-oriented size. HEIF/AVIF files
/// are reported as UnsupportedFormat.
///
/// Thread-safe (stateless).
class FFProber final : public IMediaProber {
  public:
    Result<MediaInfo> probe(const std::string &path) override;
};

/// Describes one audio or video stream of an opened input (the prober's TrackInfo, without the
/// capability fields). `timing` (from scanFrameTiming) refines isVFR and frameDuration.
TrackInfo describeStream(const AVFormatContext *ctx, const AVStream *stream, const FrameTiming *timing = nullptr);

} // namespace ve::media::ffmpeg
