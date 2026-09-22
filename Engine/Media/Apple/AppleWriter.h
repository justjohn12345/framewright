#pragma once

#include "../Interfaces.h"

#include <memory>

namespace ve::media::apple {

/// IMediaWriter over AVAssetWriter (VideoToolbox encoders + the QuickTime/MPEG-4/WAVE muxers,
/// which AVFoundation does not expose separately).
///
/// - Video: AVAssetWriterInput + AVAssetWriterInputPixelBufferAdaptor, H.264 (High, auto
///   level), HEVC (Main, auto level) or ProRes 422, expectsMediaDataInRealTime = NO, colour
///   tags from VideoEncodeSettings::color (AVVideoColorPropertiesKey), hardware encoder
///   enabled (and required when VideoEncodeSettings::requireHardware) through
///   AVVideoEncoderSpecificationKey. Media timescale: the frame duration's timescale scaled up
///   to at least 600.
/// - Audio: float32 interleaved input converted by the writer to AAC or linear PCM.
/// - Push mode waits for readyForMoreMediaData through KVO (with a 10 s stall timeout);
///   endStream() is markAsFinished. Pull mode maps onto requestMediaDataWhenReadyOnQueue with
///   one private serial queue per input, so AVAssetWriter itself decides how far audio runs
///   ahead of video.
///
/// Hardware reporting limitation: AVAssetWriter does not expose its VTCompressionSession, so
/// kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder cannot be queried.
/// usesHardwareVideoEncoder() is exact when requireHardware is set (the writer fails rather
/// than fall back to software); otherwise it reports HardwareCaps (a hardware encoder exists
/// for the codec, and VideoToolbox always prefers it when it is enabled).
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

    /// Static validation shared with AppleBackend::canWrite.
    static Status validate(const EncodeSettings &settings);

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace ve::media::apple
