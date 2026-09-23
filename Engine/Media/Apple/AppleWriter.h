#pragma once

#include "../Interfaces.h"

#include <memory>

namespace ve::media::apple {

/// IMediaWriter over AVAssetWriter (VideoToolbox encoders + the QuickTime/MPEG-4/WAVE muxers,
/// which AVFoundation does not expose separately).
///
/// - Video: AVAssetWriterInput + AVAssetWriterInputPixelBufferAdaptor, H.264 (High, auto
///   level), HEVC (Main, or Main10 from 10-bit input such as 'x420'; auto level) or ProRes 422, expectsMediaDataInRealTime = NO, colour
///   tags from VideoEncodeSettings::color (AVVideoColorPropertiesKey). Media timescale: the
///   frame duration's timescale scaled up to at least 600.
/// - Audio: float32 interleaved input converted by the writer to AAC or linear PCM.
/// - Push mode waits for readyForMoreMediaData through KVO (with a 10 s stall timeout);
///   endStream() is markAsFinished. Pull mode maps onto requestMediaDataWhenReadyOnQueue with
///   one private serial queue per input, so AVAssetWriter itself decides how far audio runs
///   ahead of video.
///
/// - finish() ends the session where the longer stream ends, so audio running past the last
///   video frame is kept; the video track still ends one frame duration after its last frame.
///
/// Hardware: AVAssetWriter does not expose its VTCompressionSession, so the encoder is never
/// left to chance: open() first creates the writer with the hardware encoder REQUIRED
/// (AVVideoEncoderSpecificationKey), which fails at startWriting when VideoToolbox has no
/// hardware encoder for the settings (e.g. H.264 larger than the hardware's limit); unless
/// VideoEncodeSettings::requireHardware is set it then creates it again with hardware
/// DISABLED. usesHardwareVideoEncoder() reports which of the two succeeded, so it is exact.
///
/// Not thread-safe (see Interfaces.h).
class AppleWriter final : public IMediaWriter {
  public:
    static constexpr double kStallTimeoutSeconds = 10.0;
    static constexpr double kFinishTimeoutSeconds = 300.0;

    AppleWriter();
    ~AppleWriter() override;
    AppleWriter(const AppleWriter &) = delete;
    AppleWriter &operator=(const AppleWriter &) = delete;

    Status open(const std::string &path, const EncodeSettings &settings) override;
    Result<PixelBuffer> makePixelBuffer() override;
    Status appendVideo(const PixelBuffer &image, CMTime pts) override;
    Status appendAudio(const float *interleaved, int frames) override;
    Status endStream(TrackKind kind) override;
    Status runPull(const VideoPullFn &video, const AudioPullFn &audio) override;
    Status finish() override;
    void cancel() override;
    bool usesHardwareVideoEncoder() const override;
    /// "VideoToolbox HEVC Main10 (hardware)" etc.
    std::string videoEncoderName() const override;

    /// Static validation shared with AppleBackend::canWrite.
    static Status validate(const EncodeSettings &settings);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace ve::media::apple
