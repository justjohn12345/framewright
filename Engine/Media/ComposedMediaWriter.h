// IMediaWriter assembled from discrete encoders and a muxer. Backends whose encoders and
// muxer are separable (FFmpeg) implement IVideoEncoder / IAudioEncoder / IMuxer and return a
// ComposedMediaWriter from IMediaBackend::makeWriter().
#pragma once

#include "Interfaces.h"

#include <functional>
#include <memory>

namespace ve::media {

/// Packets from each encoder are routed to the muxer as they come out, tagged with the stream
/// index the muxer assigned in open(). In pull mode the two sources are interleaved by media
/// time (whichever stream is behind is pulled next) on the calling thread, so the callbacks
/// run on the thread that called runPull(); a stream whose callback reports done is ended
/// (its encoder flushed) at once. Push mode never blocks beyond the encode itself.
/// Not thread-safe (see Interfaces.h).
class ComposedMediaWriter final : public IMediaWriter {
  public:
    static constexpr int kPullAudioChunkFrames = 1024;

    /// Either encoder may be null if the corresponding stream is never configured.
    ComposedMediaWriter(std::unique_ptr<IVideoEncoder> videoEncoder, std::unique_ptr<IAudioEncoder> audioEncoder,
                        std::unique_ptr<IMuxer> muxer);
    ~ComposedMediaWriter() override;

    Status open(const std::string &path, const EncodeSettings &settings) override;
    Result<PixelBuffer> makePixelBuffer() override;
    Status appendVideo(const PixelBuffer &image, CMTime pts) override;
    Status appendAudio(const float *interleaved, int frames) override;
    Status endStream(TrackKind kind) override;
    Status runPull(const VideoPullFn &video, const AudioPullFn &audio) override;
    Status finish() override;
    /// Checked before each packet the encoder flushes produce and before the trailer.
    void setFinishCancellation(std::function<bool()> check) override;
    void cancel() override;
    bool usesHardwareVideoEncoder() const override;
    /// The video encoder's name() ("hevc_videotoolbox", "libsvtav1", ...).
    std::string videoEncoderName() const override;

  private:
    enum class State { Idle, Writing, Finished, Failed };
    Status fail(MediaError error);
    PacketSink sinkFor(int streamIndex);

    std::unique_ptr<IVideoEncoder> videoEncoder_;
    std::unique_ptr<IAudioEncoder> audioEncoder_;
    std::unique_ptr<IMuxer> muxer_;
    EncodeSettings settings_;
    PixelBufferPool pool_;
    State state_ = State::Idle;
    int videoStream_ = -1;
    int audioStream_ = -1;
    CMTime lastVideoPts_ = kCMTimeInvalid;
    int64_t audioFrames_ = 0;
    bool videoEnded_ = false;
    bool audioEnded_ = false;
    bool finishing_ = false; ///< Inside finish(): the sink checks finishCancelled_.
    std::function<bool()> finishCancelled_;
};

} // namespace ve::media
