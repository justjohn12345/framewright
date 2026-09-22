#pragma once

#include "../Interfaces.h"

#include <memory>

namespace ve::media::ffmpeg {

/// IAudioEncoder over libavcodec + libswresample. Not thread-safe (see Interfaces.h).
///
/// AAC: aac_at (AudioToolbox, fed 16-bit samples, which is what it accepts) with FFmpeg's native
/// aac encoder as the fallback. Linear PCM: pcm_s16le / pcm_s24le / pcm_f32le for
/// AudioEncodeSettings::pcmBitDepth 16 / 24 / 32.
///
/// Input float32 interleaved samples are converted with libswresample into the encoder's
/// sample format and queued in an AVAudioFifo until a full codec frame is available. Packets
/// carry pts in 1/sampleRate; the first AAC packets start at -initialPadding (the encoder
/// delay, 2112 for AudioToolbox, 1024 for FFmpeg's encoder), which FFMuxer turns into an edit
/// list (MOV/MP4) or CodecDelay (Matroska) so the decoded timeline starts at the first real
/// sample. For PCM, EncodedStreamFormat::bitRate is exactly sampleRate * channels * bits, which
/// is how the muxer recovers the sample layout.
class FFAudioEncoder final : public IAudioEncoder {
  public:
    FFAudioEncoder();
    ~FFAudioEncoder() override;
    FFAudioEncoder(const FFAudioEncoder &) = delete;
    FFAudioEncoder &operator=(const FFAudioEncoder &) = delete;

    Status open(const AudioEncodeSettings &settings) override;
    Result<EncodedStreamFormat> outputFormat() const override;
    Status encode(const float *interleaved, int frames, const PacketSink &sink) override;
    Status flush(const PacketSink &sink) override;

    /// FFmpeg encoder name in use ("aac_at", "aac", "pcm_s16le", ...), empty before open().
    std::string encoderName() const;
    /// Encoder delay in samples (0 for PCM).
    int initialPadding() const;

    static Status validate(const AudioEncodeSettings &settings);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace ve::media::ffmpeg
