// The FFmpeg media backend: libavformat demux/mux, libavcodec decode/encode (with the
// VideoToolbox hwaccel and encoders), libswresample, libswscale. FFmpeg 7.1, LGPL build.
//
// What it handles (canHandle):
// - Containers: everything the demuxer whitelist in FFmpegSupport.mm opens: QuickTime/MP4/M4A,
//   Matroska/WebM, AVI, MPEG-TS, FLV, Ogg, WAV/W64, AIFF, CAF, MP3, FLAC, ADTS AAC, MXF, and the
//   PNG/JPEG/BMP/TIFF/WebP/GIF image pipes (stills).
// - Video codecs with a decoder in this build: H.264, HEVC, ProRes, VP9, VP8, MPEG-4 Part 2,
//   MPEG-2, DNxHD, Theora, MJPEG, and AV1 through libdav1d (software; FFmpeg 7.1 has no
//   VideoToolbox AV1 hwaccel, so AV1 in ISO-BMFF on M3 and later goes to the Apple backend's
//   hardware decoder instead). When the MediaInfo comes from this backend's prober, tracks it
//   measured as undecodable (TrackInfo::decodable) are refused.
// - Audio: AAC (incl. HE-AAC), MP3, Opus, Vorbis, FLAC, ALAC, AC-3, E-AC-3, linear PCM, u-law,
//   a-law.
// - Not HEIF/HEIC/AVIF stills: libavformat exposes their tiles as separate streams and the
//   build has no libheif; the prober reports UnsupportedFormat and canHandle() is false, so the
//   router uses the Apple backend (ImageIO).
// - Variable frame rate is fine (flagged by the prober; timestamps are exact).
// canWrite: MOV/MP4/MKV with H.264/HEVC (VideoToolbox) or ProRes 422 (MOV or MKV; VideoToolbox, else
// prores_ks); AV1 (SVT-AV1, software) in MP4 or MKV; AAC (aac_at, else FFmpeg aac) or linear
// PCM audio (not in MP4); M4A with AAC/PCM; WAV with PCM.
//
// Threading: FFmpegBackend and FFProber are thread-safe; decoders, encoders, muxers and
// writers are single-threaded per instance (Interfaces.h). No global FFmpeg state is touched
// except the log level (initializeFFmpegOnce, once per process).
#pragma once

#include "../Interfaces.h"

#include <memory>

namespace ve::media::ffmpeg {

class FFmpegBackend final : public IMediaBackend {
  public:
    FFmpegBackend();

    std::string name() const override;
    std::unique_ptr<IMediaProber> makeProber() override;
    std::unique_ptr<IVideoDecoder> makeVideoDecoder() override;
    std::unique_ptr<IAudioDecoder> makeAudioDecoder() override;
    /// ComposedMediaWriter over FFVideoEncoder + FFAudioEncoder + FFMuxer.
    std::unique_ptr<IMediaWriter> makeWriter() override;
    std::unique_ptr<IVideoEncoder> makeVideoEncoder() override;
    std::unique_ptr<IAudioEncoder> makeAudioEncoder() override;
    std::unique_ptr<IMuxer> makeMuxer() override;
    bool canHandle(const MediaInfo &info) const override;
    bool canWrite(const EncodeSettings &settings) const override;

    /// Validation behind canWrite(), with the reason.
    static Status validate(const EncodeSettings &settings);
};

std::shared_ptr<IMediaBackend> makeFFmpegBackend();

} // namespace ve::media::ffmpeg
