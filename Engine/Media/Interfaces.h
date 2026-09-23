// Media backend interfaces. The engine talks only to these; AppleBackend (AVFoundation +
// VideoToolbox) and FFmpegBackend (libavformat/libavcodec) implement them, and
// MediaBackendConformanceTests runs the same suite against both.
//
// Conventions
// - Time is CMTime throughout, in the container's presentation timeline. Timestamps returned
//   by decoders are the exact container timestamps (no float round trips).
// - No exceptions cross these interfaces; every fallible call returns Result<T>/Status.
//   Implementations must also catch Objective-C exceptions thrown by the platform.
// - Paths are absolute POSIX file-system paths in UTF-8.
// - Nothing here calls back on the main thread, and nothing requires a run loop, so every
//   call may be made from any thread (including worker threads without an autorelease pool;
//   implementations drain their own pools).
//
// Threading contract (applies to every interface unless stated otherwise)
// - IMediaBackend and IMediaProber are thread-safe: any number of threads may call them
//   concurrently on the same instance.
// - IVideoDecoder, IAudioDecoder, IVideoEncoder, IAudioEncoder, IMuxer and IMediaWriter
//   instances are NOT thread-safe. Each instance must be used by one thread at a time
//   (external synchronisation); it may migrate between threads between calls. Distinct
//   instances are fully independent and may run concurrently, even on the same file.
// - PixelBuffer handles may be passed between threads freely (see PixelBuffer.h).
// - Blocking: open/seek/next/read/append/finish may block the calling thread on I/O and
//   decode; do not call them on the main thread or the audio render thread.
#pragma once

#include "MediaTypes.h"
#include "PixelBuffer.h"
#include "Result.h"

#include <atomic>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace ve::media {

// MARK: - Probe

class IMediaProber {
  public:
    virtual ~IMediaProber() = default;

    /// Reads container and track metadata. Blocks until done (or the backend's load timeout,
    /// reported as MediaErrorCode::Timeout). Returns FileNotFound / PermissionDenied /
    /// UnsupportedFormat / CorruptData for unusable files; never crashes on bad input.
    virtual Result<MediaInfo> probe(const std::string &path) = 0;
};

// MARK: - Video decode

struct VideoFrame {
    /// Presentation timestamp, exactly as stored in the container (track timeline).
    CMTime pts = kCMTimeInvalid;
    /// Display interval of this frame: the time until the next frame's pts in presentation order
    /// (decoders read one frame ahead where the container does not store it, as for B-frame MP4
    /// or Matroska without BlockDurations), and for the last frame the time to the track's end.
    /// Consecutive frames therefore tile the track without gaps or overlaps. For stills:
    /// kCMTimePositiveInfinity (with pts = 0).
    CMTime duration = kCMTimeInvalid;
    /// Decoded image, IOSurface backed. Treat as read-only; it may be shared with the decoder's
    /// pool and other holders.
    PixelBuffer image;
    bool wasHardwareDecoded = false;
    /// Alpha contract. For pixel formats with an alpha channel (32BGRA from stills, ProRes 4444,
    /// software-decoded formats with alpha): true when the colour channels are premultiplied by
    /// alpha, false for straight (unassociated) alpha. Every decoder also tags the buffer itself
    /// with kCVImageBufferAlphaChannelModeKey (kCVImageBufferAlphaChannelMode_PremultipliedAlpha /
    /// _StraightAlpha) with the same value; the tag is the authoritative carrier once the buffer
    /// travels without its VideoFrame (FrameCache, TextureCache). Producers: stills are
    /// premultiplied (ImageIO/CoreGraphics convention); video with alpha is straight (ProRes 4444
    /// via VideoToolbox, libswscale BGRA output). Opaque formats report true (nothing to undo).
    bool alphaIsPremultiplied = true;

    bool contains(CMTime t) const;
};

/// Reads the alpha contract of a decoded buffer: kCVImageBufferAlphaChannelModeKey when present;
/// untagged buffers without an alpha channel count as premultiplied (opaque), untagged buffers
/// with one as `untaggedDefault`.
bool alphaIsPremultiplied(CVPixelBufferRef buffer, bool untaggedDefault);
/// Tags `buffer` with kCVImageBufferAlphaChannelModeKey (propagated attachment).
void setAlphaMode(CVPixelBufferRef buffer, bool premultiplied);
/// Whether CoreVideo pixel format `format` has an alpha channel.
bool pixelFormatHasAlpha(OSType format);

/// Cooperative cancellation for a decoder's long-running calls. The decode pool (or any owner)
/// shares one instance with a decoder through DecodeOptions::interrupt and may call request()
/// from any thread while another thread is inside the decoder's open/seek/next. Decoders poll
/// it between units of work (demuxed packets, decoded frames, preroll frames dropped before a
/// seek target), so a request takes effect within one frame decode, never a whole GOP. The
/// interrupted call returns MediaErrorCode::Cancelled; the decoder stays usable and keeps the
/// position it was asked for (the next next() resumes the interrupted seek unless seek() is
/// called first). The owner clears the flag before it issues the next call.
class DecodeInterrupt {
  public:
    void request() noexcept { flag_.store(true, std::memory_order_release); }
    void clear() noexcept { flag_.store(false, std::memory_order_release); }
    bool requested() const noexcept { return flag_.load(std::memory_order_acquire); }

  private:
    std::atomic<bool> flag_{false};
};

class IVideoDecoder {
  public:
    virtual ~IVideoDecoder() = default;

    /// Opens `trackIndex` (a TrackInfo::index from this backend's prober, or -1 for the first
    /// video/still track) and positions at the start: the first next() returns the first
    /// frame. Must be called exactly once, before anything else.
    virtual Status open(const std::string &path, int trackIndex, const DecodeOptions &options) = 0;

    /// Positions the decoder so that the next call to next() returns the frame containing `t`
    /// (the frame with pts <= t < pts + duration). Times before the first frame select the
    /// first frame; times at or after the end of the track make next() return end of stream.
    /// If `t` falls in a gap between frames, the first frame after `t` is returned.
    /// Subsequent next() calls continue in presentation order from there.
    /// Stills: every seek re-arms the single frame (see next()).
    virtual Status seek(CMTime t) = 0;

    /// Returns the next frame in presentation order, std::nullopt at end of stream, or an error
    /// (the decoder may be seeked again after an error). Stills return their single frame once
    /// after open() and once after each seek(), then std::nullopt. MediaErrorCode::Cancelled
    /// when DecodeOptions::interrupt was requested during the call (see DecodeInterrupt).
    virtual Result<std::optional<VideoFrame>> next() = 0;

    /// Nominal frame duration of the track (TrackInfo::frameDuration); invalid for stills.
    virtual CMTime frameDuration() const = 0;
    /// True when seek() to an arbitrary time is efficient (decodes at most from the preceding
    /// sync sample instead of re-reading from the start or re-creating the demuxer).
    virtual bool supportsRandomAccess() const = 0;
    /// Whether the most recently returned frame was decoded in hardware; before the first
    /// frame, whether hardware decode is expected for this track.
    virtual bool usedHardware() const = 0;
    /// Pixel format of returned frames (resolved when DecodeOptions::pixelFormat was 0).
    virtual OSType outputPixelFormat() const = 0;
    /// Name of the backend currently decoding, for decoders that can switch backends at run time
    /// (the router's fallback decoder); empty for plain backend decoders.
    virtual std::string activeBackend() const { return {}; }
};

// MARK: - Audio decode

class IAudioDecoder {
  public:
    virtual ~IAudioDecoder() = default;

    /// Opens `trackIndex` (or -1 for the first audio track). Output is float32 interleaved at
    /// options.sampleRate / options.channels regardless of the source format. Position starts at
    /// sample 0 = time 0 of the container timeline (leading gaps are delivered as silence).
    virtual Status open(const std::string &path, int trackIndex, const AudioOptions &options) = 0;

    /// Sets the read position to sample floor(t * sampleRate) (clamped at 0). The next read()
    /// returns that sample: sample-accurate, including decoder pre-roll handling, with one
    /// exception reported by seekTolerance(): codecs with variable frame sizes (Opus, Vorbis) in
    /// containers whose timestamps are coarser than a sample (Matroska/WebM store milliseconds)
    /// place the first packet after a seek from its rounded timestamp, so the audio read after
    /// such a seek may be offset by up to one container tick (1 ms = 48 samples at 48 kHz).
    /// Sequential reads are always sample-exact.
    virtual Status seek(CMTime t) = 0;

    /// Reads up to `frames` sample frames (frames * channels floats) into `interleaved`.
    /// Returns the number of frames read: less than `frames` only at end of stream, 0 at end.
    /// Gaps inside the track are filled with silence.
    virtual Result<int> read(float *interleaved, int frames) = 0;

    /// Index (at the output rate) of the next sample frame read() will return.
    virtual int64_t position() const = 0;
    /// position() as a CMTime with timescale = output sample rate (when integral).
    virtual CMTime positionTime() const = 0;
    virtual double sampleRate() const = 0;
    virtual int channels() const = 0;
    /// Track length in output sample frames (from the container duration; the exact count
    /// delivered by read() may differ by a codec frame).
    virtual int64_t lengthFrames() const = 0;
    /// Maximum error of the position after seek() (see seek()); kCMTimeZero when seeks are
    /// sample-exact.
    virtual CMTime seekTolerance() const { return kCMTimeZero; }
    /// See IVideoDecoder::activeBackend().
    virtual std::string activeBackend() const { return {}; }
};

// MARK: - Encode and mux (separable pipeline, used by backends that have discrete components)

/// One compressed access unit.
struct EncodedPacket {
    int streamIndex = -1; ///< Muxer stream index (set by whoever routes packets to the muxer).
    CMTime pts = kCMTimeInvalid;
    CMTime dts = kCMTimeInvalid;
    CMTime duration = kCMTimeInvalid;
    bool isKeyframe = false;
    /// Audio: samples at the end of this packet's decoded output that are encoder padding, not
    /// stream content (the last packet of a stream whose length is not a whole number of codec
    /// frames). Muxers that can say so store it (Matroska DiscardPadding); ISO-BMFF ends the edit
    /// list at the shortened `duration` instead.
    int64_t trailingDiscard = 0;
    std::vector<uint8_t> data;
};

/// Everything a muxer needs to declare a stream for an encoder's output.
struct EncodedStreamFormat {
    TrackKind kind = TrackKind::Video;
    uint32_t codec = 0; ///< CoreMedia four-cc of the bitstream.
    int width = 0;
    int height = 0;
    CMTime frameDuration = kCMTimeInvalid;
    ColorInfo color;
    double sampleRate = 0;
    int channels = 0;
    int64_t bitRate = 0;
    /// Timescale the encoder uses for packet timestamps (e.g. 30000 or the sample rate).
    int32_t timescale = 0;
    /// Codec configuration record (avcC/hvcC/esds AudioSpecificConfig), empty if in-band.
    std::vector<uint8_t> extradata;
};

/// Receives packets from an encoder. Returning an error aborts the encode call.
using PacketSink = std::function<Status(EncodedPacket &&)>;

class IVideoEncoder {
  public:
    virtual ~IVideoEncoder() = default;
    virtual Status open(const VideoEncodeSettings &settings) = 0;
    /// Valid after open(): the stream to declare on the muxer.
    virtual Result<EncodedStreamFormat> outputFormat() const = 0;
    /// Encodes one frame. Zero or more packets (in decode order) are delivered to `sink`
    /// before the call returns. Frames must be submitted in presentation order.
    virtual Status encode(const PixelBuffer &frame, CMTime pts, const PacketSink &sink) = 0;
    /// Drains delayed frames to `sink`. No encode() afterwards.
    virtual Status flush(const PacketSink &sink) = 0;
    virtual bool usesHardware() const = 0;
    /// Name of the encoder in use after open() ("hevc_videotoolbox", "libsvtav1", ...); empty
    /// before.
    virtual std::string name() const { return {}; }
};

class IAudioEncoder {
  public:
    virtual ~IAudioEncoder() = default;
    virtual Status open(const AudioEncodeSettings &settings) = 0;
    virtual Result<EncodedStreamFormat> outputFormat() const = 0;
    /// Encodes `frames` float32 interleaved sample frames that follow the previous call
    /// contiguously (the first call starts at time 0). The encoder buffers into codec frames.
    virtual Status encode(const float *interleaved, int frames, const PacketSink &sink) = 0;
    virtual Status flush(const PacketSink &sink) = 0;
};

class IMuxer {
  public:
    virtual ~IMuxer() = default;
    /// Creates the output file. `path` must not exist (InvalidArgument otherwise): a muxer never
    /// deletes or truncates a file it did not create. To replace a file, write a new one (e.g. in
    /// a temporary directory on the same volume) and move it into place when it is complete.
    virtual Status open(const std::string &path, ContainerFormat container) = 0;
    /// Declares a stream; returns its index for EncodedPacket::streamIndex. Before begin().
    virtual Result<int> addStream(const EncodedStreamFormat &format) = 0;
    /// Writes the header. After all addStream calls, before the first packet.
    virtual Status begin() = 0;
    /// Packets of one stream arrive in decode order; streams are interleaved by the caller in
    /// roughly increasing dts (the muxer may buffer to perfect interleaving).
    virtual Status writePacket(EncodedPacket &&packet) = 0;
    /// Writes the trailer and closes the file.
    virtual Status finish() = 0;
    /// Abandons the output and deletes the partial file (the file open() created).
    virtual void cancel() = 0;
};

// MARK: - Writer (what export uses)

struct VideoInput {
    PixelBuffer image;
    CMTime pts = kCMTimeInvalid;
};
/// Pull callback for video: return the next frame, std::nullopt when done, or an error to
/// abort the write.
using VideoPullFn = std::function<Result<std::optional<VideoInput>>()>;
/// Pull callback for audio: fill up to `maxFrames` float32 interleaved sample frames into
/// `dst` and return the count; 0 means done; an error aborts the write.
using AudioPullFn = std::function<Result<int>(float *dst, int maxFrames)>;

/// Encoder(s) plus muxer as one object. AppleBackend implements this directly over
/// AVAssetWriter (whose encoders and muxer cannot be separated); backends with discrete
/// components get it for free from ComposedMediaWriter (ComposedMediaWriter.h).
///
/// Two ways to feed it, pick one per writer:
/// - Pull (recommended with audio + video): runPull() drives both callbacks until they report
///   done, pulling from whichever stream the muxer needs next. It blocks the calling thread. A
///   stream whose callback reports done is ended at once (as endStream() would), so the other
///   stream may run on alone. A callback that returns an error (e.g. Cancelled) aborts the write:
///   runPull() returns that error and the partial output is deleted.
///   The video and audio callbacks are invoked on writer-internal threads, each one serially,
///   but the two may run concurrently with each other.
/// - Push: appendVideo()/appendAudio() block while that stream's encoder is not ready. A
///   muxer may refuse video until the audio has run ahead (AVAssetWriter wants audio up to
///   about 1 s ahead of video), so with both streams keep the audio between 0 and 2 s ahead of
///   the video and call endStream() for a stream that ends before the other. A push that
///   cannot make progress for 10 s fails with Timeout instead of deadlocking.
/// Then finish() once. Timing: the session starts at time 0; audio samples are placed
/// contiguously from time 0.
class IMediaWriter {
  public:
    virtual ~IMediaWriter() = default;
    /// Validates the settings and creates the output file. `path` must not exist
    /// (InvalidArgument otherwise): a writer never deletes or truncates a file it did not create,
    /// so a cancelled or failed write cannot destroy the file being replaced. To replace a file,
    /// write a new one (e.g. in NSItemReplacementDirectory for the destination) and move it into
    /// place once finish() succeeded (ExportJob does).
    virtual Status open(const std::string &path, const EncodeSettings &settings) = 0;
    /// A buffer of the video input format and size, from the writer's pool (preferred source
    /// of frames: it is already in the layout the encoder wants). After open().
    virtual Result<PixelBuffer> makePixelBuffer() = 0;
    /// Push mode. Frames in increasing pts order.
    virtual Status appendVideo(const PixelBuffer &image, CMTime pts) = 0;
    virtual Status appendAudio(const float *interleaved, int frames) = 0;
    /// Push mode: no more samples of `kind` (Video or Audio) follow. Optional; finish() ends
    /// every stream. Needed when one stream ends well before the other.
    virtual Status endStream(TrackKind kind) = 0;
    /// Pull mode. Either callback may be empty if that stream is not configured.
    virtual Status runPull(const VideoPullFn &video, const AudioPullFn &audio) = 0;
    /// Flushes encoders, writes the trailer, waits for completion and reports any error.
    virtual Status finish() = 0;
    /// Makes finish() cancellable: while finish() flushes the encoders, writes the trailer and
    /// waits for the file to be completed (an MP4 rewrite with the index up front can take a
    /// while), it polls `check` (between packets, and at least every 20 ms while it waits on
    /// AVAssetWriter); once `check` returns true it abandons the output as cancel() does
    /// (deleting the partial file) and returns Cancelled. Set before finish(); `check` must be
    /// thread-safe. Empty (the default): finish() runs to completion.
    virtual void setFinishCancellation(std::function<bool()> check) = 0;
    /// Abandons the output and deletes the partial file (the file open() created). Safe to call
    /// at any time.
    virtual void cancel() = 0;
    /// Whether the video encoder runs in hardware. See the backend for how this is determined.
    virtual bool usesHardwareVideoEncoder() const = 0;
    /// Human-readable name of the video encoder in use after open() (e.g. "VideoToolbox HEVC
    /// (hardware)", "libsvtav1"); empty before open() or without video.
    virtual std::string videoEncoderName() const { return {}; }
};

// MARK: - Backend factory

class IMediaBackend {
  public:
    virtual ~IMediaBackend() = default;
    /// Stable identifier: "apple", "ffmpeg".
    virtual std::string name() const = 0;
    virtual std::unique_ptr<IMediaProber> makeProber() = 0;
    virtual std::unique_ptr<IVideoDecoder> makeVideoDecoder() = 0;
    virtual std::unique_ptr<IAudioDecoder> makeAudioDecoder() = 0;
    virtual std::unique_ptr<IMediaWriter> makeWriter() = 0;
    /// Discrete encoders and muxer. May return nullptr when the backend only provides them
    /// fused inside makeWriter() (AppleBackend does).
    virtual std::unique_ptr<IVideoEncoder> makeVideoEncoder() { return nullptr; }
    virtual std::unique_ptr<IAudioEncoder> makeAudioEncoder() { return nullptr; }
    virtual std::unique_ptr<IMuxer> makeMuxer() { return nullptr; }
    /// Whether this backend can decode every video/audio/still track of `info` (which may
    /// come from another backend's prober: compare codec four-ccs and the container token).
    virtual bool canHandle(const MediaInfo &info) const = 0;
    /// Whether this backend can write `settings`.
    virtual bool canWrite(const EncodeSettings &settings) const = 0;
};

} // namespace ve::media
