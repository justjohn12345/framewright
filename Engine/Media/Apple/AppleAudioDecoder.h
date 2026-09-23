#pragma once

#include "../Interfaces.h"

#include <memory>

namespace ve::media::apple {

/// IAudioDecoder over AVAssetReader + AVAssetReaderTrackOutput with linear PCM float32
/// interleaved output settings: AVAssetReader decodes and remixes channels (5.1/7.1 in the
/// WAVE order of AudioOptions). Sample-rate conversion, when the source rate differs from the
/// requested one, is done by an AVAudioConverter (normal priming, mastering quality) rather than
/// by AVAssetReader, whose converter is not sample-aligned (44.1 -> 48 kHz lands 2 samples late
/// and drops the last 17); the converter is always started at a source sample whose output
/// index is an integer, so output sample n is source time n / rate exactly, also after seeks.
///
/// Seeking re-creates the reader with a time range that starts kPrerollSeconds before the
/// target (so codecs with overlapping frames such as AAC are fully primed) and drops the
/// samples before the target, which makes the first sample after seek() exactly the requested
/// one. Forward seeks of at most kSkipAheadSeconds just discard decoded samples instead.
/// Sample buffer timestamps are rounded to the output rate; jitter of one sample between
/// consecutive buffers is absorbed, gaps up to 1 s are filled with silence and larger ones are
/// read as silence without being buffered.
/// Not thread-safe (see Interfaces.h).
class AppleAudioDecoder final : public IAudioDecoder {
  public:
    static constexpr double kPrerollSeconds = 0.1;
    static constexpr double kSkipAheadSeconds = 1.0;

    explicit AppleAudioDecoder(double loadTimeoutSeconds);
    ~AppleAudioDecoder() override;
    AppleAudioDecoder(const AppleAudioDecoder &) = delete;
    AppleAudioDecoder &operator=(const AppleAudioDecoder &) = delete;

    Status open(const std::string &path, int trackIndex, const AudioOptions &options) override;
    Status seek(CMTime t) override;
    Result<int> read(float *interleaved, int frames) override;
    int64_t position() const override;
    CMTime positionTime() const override;
    double sampleRate() const override;
    int channels() const override;
    int64_t lengthFrames() const override;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace ve::media::apple
