#pragma once

#include "../Interfaces.h"

#include <memory>

namespace ve::media::apple {

/// IVideoDecoder over AVFoundation + VideoToolbox. Not thread-safe (see Interfaces.h).
///
/// Two internal paths behind one object:
/// - Sequential: AVAssetReader + AVAssetReaderTrackOutput, the efficient pipelined path for
///   playback and export. Used from open(), for forward seeks of at most kCloseAheadSeconds
///   (the reader decodes forward and frames before the target are dropped), and resumed after
///   random access at the next sync sample.
/// - Random access: AVSampleCursor + AVSampleBufferGenerator feeding a VTDecompressionSession
///   (hardware requested). seek() to a time behind the current position or more than
///   kCloseAheadSeconds ahead steps back from the target sample to the preceding full sync
///   sample (plus any samplesRequiredForDecoderRefresh), decodes forward (frames before the
///   target are decoded with kVTDecodeFrame_DoNotOutputFrame) and emits frames in presentation
///   order using a second cursor that walks presentation order, so reordered (B-frame) streams
///   come out correctly. After emitting, when the next sample in decode order is a full sync
///   sample, it hands over to a new AVAssetReader started at the next frame's time.
///
/// Random access needs AVAssetTrack.canProvideSampleCursors and a track whose edit list is a
/// single rate-1 media segment (optionally after an empty edit); otherwise seek() re-creates
/// the AVAssetReader at the target and supportsRandomAccess() is false.
///
/// Timestamps: both paths return container timestamps in the track timeline (cursor/media
/// timestamps are mapped through the edit list), so pts is exact on either path. Durations are
/// display intervals: AVAssetReader's decoded buffers carry none, so the sequential path reads
/// one frame ahead and uses the next pts; the random-access path uses the next sample in
/// presentation order. The last frame lasts until the track end.
///
/// Hardware: the random-access path reports what its VTDecompressionSession says
/// (kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder). AVAssetReader does not
/// expose its decoder, so open() creates a VTDecompressionSession for the track's format
/// description (same decoder specification) and reports that session's answer for the
/// sequential path: measured by VideoToolbox, not predicted from HardwareCaps. A format
/// VideoToolbox refuses fails open() with UnsupportedCodec. DecodeOptions::allowHardware =
/// false forces the random-access path for everything (with hardware disabled in the decoder
/// specification) and fails in open() for files without sample cursors.
///
/// open() decodes the first frame (kept for the first next()), so streams that fail only when
/// decoding also fail in open(), where the router can fall back. DecodeOptions::interrupt is
/// polled per sample buffer / decoded sample.
///
/// Stills decode once in open() through ImageIO into a 32BGRA buffer (see AppleStillImage.h);
/// next() returns that frame (pts 0, duration +infinity) once after open() and once per seek().
class AppleVideoDecoder final : public IVideoDecoder {
  public:
    /// Forward seeks up to this distance decode through instead of seeking. Rationale: common
    /// GOP lengths are 0.5-2 s, so a longer jump almost certainly crosses a sync sample and a
    /// random-access seek decodes fewer frames; a jump of at most 2 s costs at most ~60 frames
    /// at 30 fps (under ~60 ms of hardware 1080p decode), about the cost of setting up a
    /// random-access decode from the preceding sync sample, and keeps the pipelined reader.
    static constexpr double kCloseAheadSeconds = 2.0;

    explicit AppleVideoDecoder(double loadTimeoutSeconds);
    ~AppleVideoDecoder() override;
    AppleVideoDecoder(const AppleVideoDecoder &) = delete;
    AppleVideoDecoder &operator=(const AppleVideoDecoder &) = delete;

    Status open(const std::string &path, int trackIndex, const DecodeOptions &options) override;
    Status seek(CMTime t) override;
    Result<std::optional<VideoFrame>> next() override;
    CMTime frameDuration() const override;
    bool supportsRandomAccess() const override;
    bool usedHardware() const override;
    OSType outputPixelFormat() const override;

    /// Test hook: true while frames come from the random-access (cursor + VT session) path.
    bool isOnRandomAccessPath() const;

  private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace ve::media::apple
