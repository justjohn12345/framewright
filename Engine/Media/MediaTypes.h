// Value types shared by every media backend: probe results, colour tags, codec identifiers,
// decode and encode settings. Plain C++ over CoreMedia/CoreVideo C types.
#pragma once

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace ve::media {

// MARK: - Codecs

/// Codec identifiers are CoreMedia four-character codes (CMVideoCodecType / AudioFormatID).
/// Every backend reports codecs in this space so the router and UI can compare them: the
/// FFmpeg backend maps AVCodecID to the equivalent code (AV_CODEC_ID_H264 -> 'avc1',
/// AV_CODEC_ID_HEVC -> 'hvc1', AV_CODEC_ID_PRORES -> the profile's 'apcn'/'apch'/...,
/// AV_CODEC_ID_AV1 -> 'av01', AV_CODEC_ID_VP9 -> 'vp09', AV_CODEC_ID_AAC -> 'aac ', PCM -> 'lpcm')
/// and invents a code only for codecs CoreMedia has none for (e.g. 'Opus' exists, 'fLaC' exists).
namespace fourcc {
constexpr uint32_t make(const char (&s)[5]) {
    return (uint32_t(uint8_t(s[0])) << 24) | (uint32_t(uint8_t(s[1])) << 16) | (uint32_t(uint8_t(s[2])) << 8) |
           uint32_t(uint8_t(s[3]));
}
constexpr uint32_t H264 = make("avc1");
constexpr uint32_t HEVC = make("hvc1");
constexpr uint32_t HEVCAlt = make("hev1");
constexpr uint32_t ProRes422 = make("apcn");
constexpr uint32_t ProRes422HQ = make("apch");
constexpr uint32_t ProRes422LT = make("apcs");
constexpr uint32_t ProRes422Proxy = make("apco");
constexpr uint32_t ProRes4444 = make("ap4h");
constexpr uint32_t ProRes4444XQ = make("ap4x");
constexpr uint32_t AV1 = make("av01");
constexpr uint32_t VP9 = make("vp09");
constexpr uint32_t AAC = make("aac ");
constexpr uint32_t LinearPCM = make("lpcm");
constexpr uint32_t PNG = make("png ");
constexpr uint32_t JPEG = make("jpeg");
constexpr uint32_t HEIC = make("heic");
} // namespace fourcc

/// "avc1" for 'avc1'; non-printable bytes are rendered as '.'.
std::string fourCCToString(uint32_t code);
/// Human-readable codec name ("H.264", "HEVC", "Apple ProRes 422", "AAC", ...), or the four-cc.
std::string codecDisplayName(uint32_t code);
/// Maps aliases to one canonical code ('hev1' -> 'hvc1', 'avc3' -> 'avc1'); others unchanged.
uint32_t canonicalCodec(uint32_t code);
bool isProRes(uint32_t code);

struct CodecInfo {
    uint32_t fourCC = 0; ///< CoreMedia codec type (see namespace fourcc).
    std::string name;    ///< Human-readable name, e.g. "H.264".
    std::string fourCCString() const { return fourCCToString(fourCC); }
};

// MARK: - Colour

enum class ColorPrimaries { Unknown, BT709, BT601_525, BT601_625, BT2020, P3_D65, DCI_P3 };
enum class TransferFunction { Unknown, BT709, SRGB, Linear, PQ, HLG, SMPTE240M };
enum class YCbCrMatrix { Unknown, BT709, BT601, BT2020, SMPTE240M };

/// Colour tags as carried by the container/bitstream. Unknown means "not tagged"; consumers
/// assume BT.709 for HD video and sRGB for stills.
struct ColorInfo {
    ColorPrimaries primaries = ColorPrimaries::Unknown;
    TransferFunction transfer = TransferFunction::Unknown;
    YCbCrMatrix matrix = YCbCrMatrix::Unknown;
    bool fullRange = false; ///< YCbCr full (0-255) vs video (16-235) range. Irrelevant for RGB.

    bool operator==(const ColorInfo &) const = default;
    static ColorInfo bt709() { return {ColorPrimaries::BT709, TransferFunction::BT709, YCbCrMatrix::BT709, false}; }
};

const char *toString(ColorPrimaries);
const char *toString(TransferFunction);
const char *toString(YCbCrMatrix);

enum class ChromaSubsampling { Unknown, C420, C422, C444 };

// MARK: - Probe results

enum class TrackKind {
    Video, ///< Timed video frames.
    Audio, ///< Timed audio samples.
    Still, ///< A single image (PNG, JPEG, HEIC...). Has a size but no duration or frame rate.
};
const char *toString(TrackKind);

struct TrackInfo {
    /// Backend-defined track identifier, passed back to IVideoDecoder/IAudioDecoder::open of the
    /// SAME backend. Not portable between backends (Apple: index into AVAsset.tracks; FFmpeg:
    /// AVStream index). Only video, audio and still tracks are reported.
    int index = -1;
    TrackKind kind = TrackKind::Video;
    CodecInfo codec;

    // Video and still.
    int width = 0;  ///< Encoded (storage) width in pixels, before rotation.
    int height = 0; ///< Encoded (storage) height in pixels, before rotation.
    int rotationDegrees = 0; ///< Clockwise display rotation from the container (0, 90, 180, 270).
    /// Constant frame duration for CFR video, the minimum frame duration for VFR video, invalid
    /// for stills and audio. Exact container rational (e.g. 1001/30000), never a rounded float.
    CMTime frameDuration = kCMTimeInvalid;
    double nominalFps = 0; ///< Container's nominal (average) frame rate; 0 if unknown.
    /// True when frame durations vary: nominal rate and minimum frame duration disagree by more
    /// than 1 %.
    bool isVFR = false;
    ColorInfo color;
    int bitDepth = 0; ///< Luma bit depth (8, 10, 12), 0 if unknown.
    ChromaSubsampling chroma = ChromaSubsampling::Unknown;

    // Audio.
    double sampleRate = 0;
    int channels = 0;

    /// Presentation start of the track in the container timeline (usually 0).
    CMTime startTime = kCMTimeZero;
    /// Track duration; kCMTimeIndefinite for stills.
    CMTime duration = kCMTimeInvalid;
};

struct MediaInfo {
    std::string path;
    /// Short lowercase container token derived from the file content where possible:
    /// "mov", "mp4", "m4a", "m4v", "wav", "aiff", "caf", "mp3", "mkv", "webm", "avi", "mpegts",
    /// "png", "jpeg", "heic", "tiff", "gif". The FFmpeg backend maps its demuxer (and for the
    /// ISO-BMFF family the ftyp major brand) onto the same tokens.
    std::string container;
    /// Longest track duration; kCMTimeIndefinite for stills.
    CMTime duration = kCMTimeInvalid;
    std::vector<TrackInfo> tracks;
    std::string backend; ///< Name of the backend that produced this info ("apple", "ffmpeg").

    const TrackInfo *firstTrack(TrackKind kind) const;
    const TrackInfo *track(int index) const;
    bool isStill() const { return firstTrack(TrackKind::Still) != nullptr; }
    /// Multi-line human-readable summary (for logs and the asset info panel).
    std::string description() const;
};

// MARK: - Decode options

/// Options for IVideoDecoder::open.
struct DecodeOptions {
    /// Output pixel format. 0 = decoder-native biplanar YCbCr matching the source:
    ///   8-bit 4:2:0          -> '420v' / '420f'   (kCVPixelFormatType_420YpCbCr8BiPlanar{Video,Full}Range)
    ///   10+-bit 4:2:0        -> 'x420' / 'xf20'   (kCVPixelFormatType_420YpCbCr10BiPlanar{Video,Full}Range)
    ///   4:2:2 (e.g. ProRes)  -> 'x422' / 'xf22'   (kCVPixelFormatType_422YpCbCr10BiPlanar{Video,Full}Range)
    ///   4:4:4 without alpha  -> 'x444' / 'xf44'   (kCVPixelFormatType_444YpCbCr10BiPlanar{Video,Full}Range)
    ///   ProRes 4444 (alpha)  -> 'BGRA'
    ///   stills               -> 'BGRA'
    /// Video vs full range follows the source. Any other value requests that format and the
    /// backend converts (in the decoder where possible).
    OSType pixelFormat = 0;
    /// If > 0, frames are scaled (preserving aspect ratio, even dimensions) so that neither
    /// side exceeds this many pixels. Intended for thumbnails; 0 = full size.
    int maxDimension = 0;
    /// Allow a hardware decoder. When false the backend must use a software decoder.
    bool allowHardware = true;
};

/// Options for IAudioDecoder::open. Output is always 32-bit float, interleaved, native endian.
struct AudioOptions {
    double sampleRate = 48000;
    int channels = 2; ///< 1..8; up/down-mixing follows the source's channel layout.
};

// MARK: - Encode settings

enum class VideoCodec { H264, HEVC, ProRes422 };
enum class AudioCodec { AAC, LinearPCM };
enum class ContainerFormat { MOV, MP4, M4A, WAV };
const char *toString(VideoCodec);
const char *toString(AudioCodec);
const char *toString(ContainerFormat);
uint32_t codecType(VideoCodec);

struct VideoEncodeSettings {
    VideoCodec codec = VideoCodec::H264;
    int width = 0;
    int height = 0;
    CMTime frameDuration = CMTimeMake(1, 30);
    /// Average bit rate in bits/s. 0 = use `quality` (or the encoder default if quality < 0).
    /// Ignored for ProRes (fixed-rate per profile).
    int64_t averageBitRate = 0;
    /// 0..1 constant-quality target used when averageBitRate is 0; < 0 = encoder default.
    double quality = -1;
    /// Maximum distance between keyframes in frames; 0 = encoder default.
    int maxKeyFrameInterval = 0;
    bool allowFrameReordering = true; ///< B-frames for H.264/HEVC.
    ColorInfo color = ColorInfo::bt709(); ///< Tagged on the output track.
    /// Format of the pixel buffers passed to append (and produced by makePixelBuffer()).
    OSType inputPixelFormat = kCVPixelFormatType_32BGRA;
    /// Fail instead of silently falling back to a software encoder.
    bool requireHardware = false;
};

struct AudioEncodeSettings {
    AudioCodec codec = AudioCodec::AAC;
    double sampleRate = 48000;
    int channels = 2;
    int bitRate = 192000; ///< AAC only.
    int pcmBitDepth = 16; ///< LinearPCM only: 16 or 24 bit integer, or 32 (float).
};

struct EncodeSettings {
    ContainerFormat container = ContainerFormat::MOV;
    std::optional<VideoEncodeSettings> video;
    std::optional<AudioEncodeSettings> audio;
};

} // namespace ve::media
