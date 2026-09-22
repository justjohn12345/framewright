#pragma once

#include "../Interfaces.h"

#include <memory>

namespace ve::media::ffmpeg {

/// IMuxer over libavformat. Not thread-safe (see Interfaces.h).
///
/// Containers: ContainerFormat::MOV / MP4 / M4A / WAV map to FFmpeg's "mov" / "mp4" (with
/// +faststart, like AVAssetWriter's shouldOptimizeForNetworkUse) / "ipod" / "wav" muxers;
/// openFormat() accepts any libavformat muxer name (e.g. "matroska", "webm").
///
/// Streams: EncodedStreamFormat::codec (a CoreMedia four-cc) is mapped back to an AVCodecID;
/// 'lpcm' uses bitRate / (sampleRate * channels) to pick s16le / s24le / f32le. H.264 and HEVC
/// get the 'avc1' / 'hvc1' sample entries in MOV/MP4 (parameter sets out of band, the form
/// Apple players require). Stream time bases are 1/timescale; libavformat may pick a finer
/// track timescale, and timestamps are rescaled on write.
///
/// Header: begin() validates; the header itself is written lazily once every stream has
/// delivered its first packet (or at finish()), because the first audio timestamp is where the
/// encoder delay shows (a negative start). It becomes an edit list in MOV/MP4 and CodecDelay in
/// Matroska (which cannot store negative timestamps). Packets are interleaved with
/// av_interleaved_write_frame.
class FFMuxer final : public IMuxer {
  public:
    FFMuxer();
    ~FFMuxer() override;
    FFMuxer(const FFMuxer &) = delete;
    FFMuxer &operator=(const FFMuxer &) = delete;

    Status open(const std::string &path, ContainerFormat container) override;
    /// Like open() with an explicit libavformat muxer name ("matroska", "mov", "mp4", ...).
    Status openFormat(const std::string &path, const std::string &formatName);
    Result<int> addStream(const EncodedStreamFormat &format) override;
    Status begin() override;
    Status writePacket(EncodedPacket &&packet) override;
    Status finish() override;
    void cancel() override;

    /// libavformat muxer name for a ContainerFormat.
    static const char *formatName(ContainerFormat container);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace ve::media::ffmpeg
