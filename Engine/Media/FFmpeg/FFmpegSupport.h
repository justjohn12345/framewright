// Shared helpers for the FFmpeg backend: RAII owners for the libav* objects, AVERROR ->
// MediaError conversion, timestamp conversion, and the mappings from FFmpeg's identifiers
// (AVCodecID, AVColor*, demuxer names) onto the engine's (CoreMedia four-ccs, ColorInfo,
// container tokens).
//
// Threading: everything here is stateless or operates on objects the caller owns; all
// functions may be called from any thread concurrently.
#pragma once

#include "../MediaTypes.h"
#include "../Result.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/buffer.h>
#include <libavutil/frame.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace ve::media::ffmpeg {

// MARK: - RAII

struct FormatInputDeleter {
    void operator()(AVFormatContext *ctx) const noexcept { avformat_close_input(&ctx); }
};
/// An AVFormatContext opened with avformat_open_input.
using FormatInputPtr = std::unique_ptr<AVFormatContext, FormatInputDeleter>;

struct FormatOutputDeleter {
    void operator()(AVFormatContext *ctx) const noexcept;
};
/// An AVFormatContext from avformat_alloc_output_context2; the deleter also closes its AVIO.
using FormatOutputPtr = std::unique_ptr<AVFormatContext, FormatOutputDeleter>;

struct CodecContextDeleter {
    void operator()(AVCodecContext *ctx) const noexcept { avcodec_free_context(&ctx); }
};
using CodecContextPtr = std::unique_ptr<AVCodecContext, CodecContextDeleter>;

struct FrameDeleter {
    void operator()(AVFrame *frame) const noexcept { av_frame_free(&frame); }
};
using FramePtr = std::unique_ptr<AVFrame, FrameDeleter>;

struct PacketDeleter {
    void operator()(AVPacket *packet) const noexcept { av_packet_free(&packet); }
};
using PacketPtr = std::unique_ptr<AVPacket, PacketDeleter>;

struct SwrDeleter {
    void operator()(SwrContext *ctx) const noexcept { swr_free(&ctx); }
};
using SwrPtr = std::unique_ptr<SwrContext, SwrDeleter>;

struct SwsDeleter {
    void operator()(SwsContext *ctx) const noexcept { sws_freeContext(ctx); }
};
using SwsPtr = std::unique_ptr<SwsContext, SwsDeleter>;

struct BufferRefDeleter {
    void operator()(AVBufferRef *ref) const noexcept { av_buffer_unref(&ref); }
};
using BufferRefPtr = std::unique_ptr<AVBufferRef, BufferRefDeleter>;

/// av_frame_alloc / av_packet_alloc returning an error instead of nullptr.
Result<FramePtr> allocFrame();
Result<PacketPtr> allocPacket();

// MARK: - Errors

/// av_strerror text for an AVERROR code.
std::string avErrorString(int err);
/// A MediaError in domain "FFmpeg" with the AVERROR code as `underlying` and "<context>: <av_strerror>"
/// as message. File-system errors (ENOENT, EACCES) override `code` with FileNotFound /
/// PermissionDenied, AVERROR_INVALIDDATA with CorruptData where `code` is a generic failure.
MediaError ffError(int err, MediaErrorCode code, const std::string &context);

/// FileNotFound / PermissionDenied / UnsupportedFormat (directory) / InvalidArgument (empty path).
Status checkReadableFile(const std::string &path);

/// Sets FFmpeg's global log level once per process (errors only; FFmpeg's warnings about
/// harmless container quirks would otherwise flood stderr). Idempotent and thread-safe.
void initializeFFmpegOnce();

// MARK: - Input

/// Opens `path` with the demuxers this backend accepts (see kDemuxerWhitelist in the .mm),
/// the "file" protocol only, and runs avformat_find_stream_info. Errors: FileNotFound,
/// PermissionDenied, UnsupportedFormat (not a recognised container), CorruptData.
Result<FormatInputPtr> openInput(const std::string &path);

/// Short lowercase container token (see MediaInfo::container) for an opened input.
std::string containerToken(const AVFormatContext *ctx, const std::string &path);
/// True for libavformat's QuickTime/ISO-BMFF demuxer (mov, mp4, m4a, 3gp, ...).
bool isQuickTimeFamily(const AVFormatContext *ctx);
/// True for the demuxers that read single images (image2, *_pipe).
bool isImageDemuxer(const AVFormatContext *ctx);
/// True for HEIF/AVIF image containers (ISO-BMFF with an image brand). FFmpeg exposes their
/// tiles as separate streams; this backend does not decode them (see FFmpegBackend.h).
bool isHeifFamily(const AVFormatContext *ctx);

// MARK: - Time

/// Converts `value` in `timeBase` to a CMTime without rounding (timescale = time base
/// denominator); only values that overflow that representation fall back to nanoseconds.
/// AV_NOPTS_VALUE gives kCMTimeInvalid.
CMTime toCMTime(int64_t value, AVRational timeBase);
/// Converts a CMTime to `timeBase`, rounding per `rounding` (AV_ROUND_*).
int64_t fromCMTime(CMTime time, AVRational timeBase, AVRounding rounding);
/// 1 / rate as a CMTime (e.g. 30000/1001 -> 1001/30000); invalid for a zero or invalid rate.
CMTime frameDurationFromRate(AVRational rate);

// MARK: - Codecs

/// The CoreMedia four-cc for a stream's codec (0 if the codec has none and none is invented).
uint32_t fourCCForStream(const AVCodecParameters *par);
/// The AVCodecID for a CoreMedia four-cc (AV_CODEC_ID_NONE if unknown to this backend).
AVCodecID codecIdForFourCC(uint32_t fourCC);
/// Human-readable codec name: codecDisplayName() for known four-ccs, else FFmpeg's long name.
std::string codecName(uint32_t fourCC, AVCodecID id);
/// The decoder this backend uses for `id`: libdav1d for AV1 (FFmpeg's native "av1" decoder
/// only drives hardware accelerators, and 7.1 has none for AV1 on macOS), otherwise libavcodec's
/// default decoder. nullptr when the build has none.
const AVCodec *findDecoder(AVCodecID id);
/// Whether this FFmpeg build can decode `id` (findDecoder() finds one).
bool canDecode(AVCodecID id);

// MARK: - Colour

ColorPrimaries colorPrimaries(AVColorPrimaries value);
TransferFunction transferFunction(AVColorTransferCharacteristic value);
YCbCrMatrix yCbCrMatrix(AVColorSpace value);
AVColorPrimaries avColorPrimaries(ColorPrimaries value);
AVColorTransferCharacteristic avTransfer(TransferFunction value);
AVColorSpace avColorSpace(YCbCrMatrix value);
/// ColorInfo from codec parameters (fullRange from color_range, or from a yuvj* pixel format).
ColorInfo colorInfo(const AVCodecParameters *par);

// MARK: - Misc

/// Clockwise display rotation in degrees (0, 90, 180, 270) from the stream's display matrix.
int rotationDegrees(const AVStream *stream);

/// Frame timing observed from a stream's packet timestamps (see scanFrameTiming).
struct FrameTiming {
    int intervals = 0;                ///< Consecutive presentation intervals observed.
    CMTime minimum = kCMTimeInvalid;  ///< Shortest interval.
    CMTime typical = kCMTimeInvalid;  ///< Median interval.
    /// Intervals differ from the median by more than one time-base tick and more than 1 %:
    /// real variable frame rate, not timestamp quantisation (Matroska's 33/34 ms for 30 fps).
    bool variable = false;
};

/// Reads packets from the current position of `ctx` (normally right after openInput(), i.e. the
/// start) and derives the presentation intervals of each stream in `streams` from the sorted
/// packet timestamps: up to `maxPackets` packets per stream or `maxSeconds` of media. Needed
/// because containers can declare a constant rate for variable-rate video (a Matroska
/// DefaultDuration). Leaves the read position wherever the scan stopped: the caller seeks back
/// if it wants to read from the start. Results are keyed by stream index; streams without two
/// timestamps get intervals == 0.
std::map<int, FrameTiming> scanFrameTiming(AVFormatContext *ctx, const std::vector<int> &streams,
                                           int maxPackets = 240, double maxSeconds = 8.0);
/// The value of a metadata key, or nullopt.
std::optional<std::string> metadataValue(const AVDictionary *dict, const char *key);
/// Scales (w, h) to fit maxDimension (if > 0), preserving aspect ratio, even dimensions.
void fitDimensions(int maxDimension, int &width, int &height);

/// Gapless-playback information from an iTunes "iTunSMPB" tag (ISO-BMFF audio without an edit
/// list): `priming` samples at the start are encoder delay, `samples` is the real length.
struct ITunesGapless {
    int64_t priming = 0;
    int64_t samples = 0;
};
std::optional<ITunesGapless> iTunesGapless(const AVFormatContext *ctx);

/// Shift (in stream time base units) that maps an audio stream's timestamps onto the container
/// timeline with sample 0 = first real (non-priming) sample. Non-zero only for ISO-BMFF AAC
/// tracks whose priming is described by iTunSMPB instead of an edit list: libavformat then
/// drops the priming samples but leaves the timestamps unshifted (start_time = priming), while
/// AVFoundation, and this engine, place the first real sample at time 0.
int64_t audioTimelineShift(const AVFormatContext *ctx, const AVStream *stream);

} // namespace ve::media::ffmpeg
