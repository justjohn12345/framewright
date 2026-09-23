#pragma once

#include "../Interfaces.h"

#include <memory>

namespace ve::media::ffmpeg {

/// IAudioDecoder over libavformat + libavcodec + libswresample. Not thread-safe (see
/// Interfaces.h).
///
/// Placement: every decoded AVFrame is placed on the timeline by its timestamp (converted to
/// source samples), so codec priming and delay are handled by the container metadata that
/// libavformat exposes: edit lists and iTunSMPB in ISO-BMFF (skip_samples side data, applied by
/// libavcodec), CodecDelay in Matroska (negative timestamps), Opus pre-skip. Samples before
/// time 0 are dropped; leading gaps are silence. Consecutive frames are treated as contiguous
/// when their timestamps agree within the time base's resolution; real gaps are filled with
/// silence (up to 1 s; a larger jump restarts the pipeline at the new timestamp and reads the gap
/// as silence without buffering it) and overlaps trimmed. For containers whose time base is
/// coarser than a sample (Matroska stores milliseconds), frames of fixed-frame-size codecs (AAC,
/// AC-3, MP3) are snapped to the codec frame grid, which keeps seeking sample-accurate there too;
/// for variable-frame-size codecs in such containers (Opus, Vorbis in Matroska/WebM) the first
/// packet after a seek is placed from its rounded timestamp, so seeks are accurate to one
/// time-base tick (seekTolerance(): 1 ms + 1 sample); sequential reads stay sample-exact
/// (consecutive packets are treated as contiguous unless their timestamps disagree with the
/// samples decoded by more than a tick).
///
/// Length: ISO-BMFF tracks (edit list / media duration, or iTunSMPB) end exactly at the declared
/// length; other containers end where the decoded data ends.
///
/// Conversion: libswresample to float32 interleaved at the requested rate and channel count
/// (standard downmix/upmix matrices from the source channel layout). With resampling, the
/// first sample fed after a (re)start is aligned to a source sample index whose output index is
/// an integer, so output sample n always corresponds to source time n / outputRate exactly.
///
/// Seeking: seek(t) positions at floor(t * rate). Forward seeks of at most kSkipAheadSeconds
/// decode through. Otherwise the demuxer seeks to at least kPrerollSeconds (or the codec's
/// seek pre-roll, if larger) before the target, the decoder and resampler are flushed, and
/// samples before the target are discarded, so the first sample read after seek() is exactly
/// the one a sequential read would return at that position. If the demuxer lands after the
/// pre-roll point the seek is retried further back.
class FFAudioDecoder final : public IAudioDecoder {
  public:
    static constexpr double kPrerollSeconds = 0.2;
    static constexpr double kSkipAheadSeconds = 1.0;

    FFAudioDecoder();
    ~FFAudioDecoder() override;
    FFAudioDecoder(const FFAudioDecoder &) = delete;
    FFAudioDecoder &operator=(const FFAudioDecoder &) = delete;

    Status open(const std::string &path, int trackIndex, const AudioOptions &options) override;
    Status seek(CMTime t) override;
    Result<int> read(float *interleaved, int frames) override;
    int64_t position() const override;
    CMTime positionTime() const override;
    double sampleRate() const override;
    int channels() const override;
    int64_t lengthFrames() const override;
    CMTime seekTolerance() const override;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace ve::media::ffmpeg
