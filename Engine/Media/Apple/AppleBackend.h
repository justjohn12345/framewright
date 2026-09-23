#pragma once

#include "../Interfaces.h"

#include <memory>

namespace ve::media::apple {

/// IMediaBackend for AVFoundation + VideoToolbox + ImageIO. Thread-safe.
class AppleBackend final : public IMediaBackend {
  public:
    struct Options {
        /// Upper bound for blocking on AVFoundation's asynchronous loading (probe/open).
        double loadTimeoutSeconds = 10.0;
    };

    AppleBackend();
    explicit AppleBackend(Options options);

    std::string name() const override;
    std::unique_ptr<IMediaProber> makeProber() override;
    std::unique_ptr<IVideoDecoder> makeVideoDecoder() override;
    std::unique_ptr<IAudioDecoder> makeAudioDecoder() override;
    std::unique_ptr<IMediaWriter> makeWriter() override;
    /// Accepts ISO-BMFF/QuickTime, WAVE/AIFF/CAF/MP3 and ImageIO still containers whose codecs
    /// AVFoundation decodes; AV1 and VP9 only when VideoToolbox decodes them in hardware
    /// (otherwise the FFmpeg backend's software decoders are the better choice). When `info`
    /// comes from this backend's own prober, tracks it found undecodable (TrackInfo::decodable:
    /// AVFoundation's playable/decodable and a VideoToolbox session for the format) are refused.
    bool canHandle(const MediaInfo &info) const override;
    bool canWrite(const EncodeSettings &settings) const override;

  private:
    Options options_;
};

std::shared_ptr<IMediaBackend> makeAppleBackend();

} // namespace ve::media::apple
