#pragma once

#include "../Interfaces.h"
#include "FFmpegSupport.h"

namespace ve::media::ffmpeg {

/// IMediaProber over libavformat (avformat_open_input + avformat_find_stream_info).
///
/// TrackInfo::index is the AVStream index. Only audio and video streams are reported
/// (attached pictures, subtitles and data streams are skipped). Timing:
/// - frameDuration: 1 / avg_frame_rate for constant-rate video; for variable-rate video (when
///   r_frame_rate, libavformat's "smallest frame duration" estimate, and avg_frame_rate
///   disagree by more than 1 %) 1 / r_frame_rate, the minimum frame duration. nominalFps is
///   avg_frame_rate.
/// - startTime/duration: AVStream start_time/duration; for Matroska (no per-stream duration)
///   the track's DURATION tag, else the container duration. ISO-BMFF AAC with iTunSMPB gapless
///   info (and no edit list) is placed with its first real sample at 0 and the iTunSMPB length,
///   as AVFoundation does (see audioTimelineShift).
/// - MediaInfo::duration: the latest track end.
/// Stills (image demuxers) are decoded once to learn their EXIF-oriented size. HEIF/AVIF files
/// are reported as UnsupportedFormat.
///
/// Thread-safe (stateless).
class FFProber final : public IMediaProber {
  public:
    Result<MediaInfo> probe(const std::string &path) override;
};

/// Describes one audio or video stream of an opened input (the prober's TrackInfo).
TrackInfo describeStream(const AVFormatContext *ctx, const AVStream *stream);

} // namespace ve::media::ffmpeg
