#include "Interfaces.h"
#include "MediaTypes.h"
#include "Result.h"

#include <cmath>
#include <cstdio>
#include <sstream>

namespace ve::media {

const char *toString(MediaErrorCode code) noexcept {
    switch (code) {
    case MediaErrorCode::InvalidArgument:
        return "InvalidArgument";
    case MediaErrorCode::InvalidState:
        return "InvalidState";
    case MediaErrorCode::FileNotFound:
        return "FileNotFound";
    case MediaErrorCode::PermissionDenied:
        return "PermissionDenied";
    case MediaErrorCode::UnsupportedFormat:
        return "UnsupportedFormat";
    case MediaErrorCode::UnsupportedCodec:
        return "UnsupportedCodec";
    case MediaErrorCode::NoSuchTrack:
        return "NoSuchTrack";
    case MediaErrorCode::CorruptData:
        return "CorruptData";
    case MediaErrorCode::DecodeFailed:
        return "DecodeFailed";
    case MediaErrorCode::EncodeFailed:
        return "EncodeFailed";
    case MediaErrorCode::WriteFailed:
        return "WriteFailed";
    case MediaErrorCode::Timeout:
        return "Timeout";
    case MediaErrorCode::Cancelled:
        return "Cancelled";
    case MediaErrorCode::Internal:
        return "Internal";
    }
    return "Unknown";
}

std::string MediaError::description() const {
    std::string s = std::string(toString(code)) + ": " + message;
    if (!domain.empty() || underlying != 0) {
        s += " [" + domain + " " + std::to_string(underlying) + "]";
    }
    return s;
}

std::string fourCCToString(uint32_t code) {
    std::string s(4, '.');
    for (int i = 0; i < 4; ++i) {
        const char c = static_cast<char>((code >> (24 - 8 * i)) & 0xFF);
        s[static_cast<size_t>(i)] = (c >= 0x20 && c < 0x7F) ? c : '.';
    }
    return s;
}

uint32_t canonicalCodec(uint32_t code) {
    if (code == fourcc::HEVCAlt) {
        return fourcc::HEVC;
    }
    if (code == fourcc::make("avc3")) {
        return fourcc::H264;
    }
    if (code == fourcc::make("fLaC")) {
        return fourcc::FLAC; // ISO-BMFF sample entry -> CoreAudio kAudioFormatFLAC.
    }
    return code;
}

bool isProRes(uint32_t code) {
    return code == fourcc::ProRes422 || code == fourcc::ProRes422HQ || code == fourcc::ProRes422LT ||
           code == fourcc::ProRes422Proxy || code == fourcc::ProRes4444 || code == fourcc::ProRes4444XQ ||
           code == fourcc::make("aprn") || code == fourcc::make("aprh");
}

std::string codecDisplayName(uint32_t code) {
    struct Entry {
        uint32_t code;
        const char *name;
    };
    static const Entry entries[] = {
        {fourcc::H264, "H.264"},
        {fourcc::make("avc3"), "H.264"},
        {fourcc::HEVC, "HEVC"},
        {fourcc::HEVCAlt, "HEVC"},
        {fourcc::ProRes422, "Apple ProRes 422"},
        {fourcc::ProRes422HQ, "Apple ProRes 422 HQ"},
        {fourcc::ProRes422LT, "Apple ProRes 422 LT"},
        {fourcc::ProRes422Proxy, "Apple ProRes 422 Proxy"},
        {fourcc::ProRes4444, "Apple ProRes 4444"},
        {fourcc::ProRes4444XQ, "Apple ProRes 4444 XQ"},
        {fourcc::make("aprn"), "Apple ProRes RAW"},
        {fourcc::make("aprh"), "Apple ProRes RAW HQ"},
        {fourcc::AV1, "AV1"},
        {fourcc::VP9, "VP9"},
        {fourcc::make("vp08"), "VP8"},
        {fourcc::make("mp4v"), "MPEG-4 Part 2"},
        {fourcc::make("mp2v"), "MPEG-2"},
        {fourcc::JPEG, "JPEG"},
        {fourcc::PNG, "PNG"},
        {fourcc::HEIC, "HEIC"},
        {fourcc::make("tiff"), "TIFF"},
        {fourcc::make("gif "), "GIF"},
        {fourcc::AAC, "AAC"},
        {fourcc::make("aach"), "HE-AAC"},
        {fourcc::make("alac"), "Apple Lossless"},
        {fourcc::LinearPCM, "Linear PCM"},
        {fourcc::make(".mp3"), "MP3"},
        {fourcc::make("ac-3"), "AC-3"},
        {fourcc::make("ec-3"), "E-AC-3"},
        {fourcc::make("opus"), "Opus"},
        {fourcc::FLAC, "FLAC"},
        {fourcc::make("fLaC"), "FLAC"},
    };
    for (const Entry &e : entries) {
        if (e.code == code) {
            return e.name;
        }
    }
    return fourCCToString(code);
}

const char *toString(ColorPrimaries p) {
    switch (p) {
    case ColorPrimaries::Unknown:
        return "unknown";
    case ColorPrimaries::BT709:
        return "bt709";
    case ColorPrimaries::BT601_525:
        return "bt601-525";
    case ColorPrimaries::BT601_625:
        return "bt601-625";
    case ColorPrimaries::BT2020:
        return "bt2020";
    case ColorPrimaries::P3_D65:
        return "p3-d65";
    case ColorPrimaries::DCI_P3:
        return "dci-p3";
    }
    return "unknown";
}

const char *toString(TransferFunction t) {
    switch (t) {
    case TransferFunction::Unknown:
        return "unknown";
    case TransferFunction::BT709:
        return "bt709";
    case TransferFunction::SRGB:
        return "srgb";
    case TransferFunction::Linear:
        return "linear";
    case TransferFunction::PQ:
        return "pq";
    case TransferFunction::HLG:
        return "hlg";
    case TransferFunction::SMPTE240M:
        return "smpte240m";
    }
    return "unknown";
}

const char *toString(YCbCrMatrix m) {
    switch (m) {
    case YCbCrMatrix::Unknown:
        return "unknown";
    case YCbCrMatrix::BT709:
        return "bt709";
    case YCbCrMatrix::BT601:
        return "bt601";
    case YCbCrMatrix::BT2020:
        return "bt2020";
    case YCbCrMatrix::SMPTE240M:
        return "smpte240m";
    }
    return "unknown";
}

const char *toString(TrackKind kind) {
    switch (kind) {
    case TrackKind::Video:
        return "video";
    case TrackKind::Audio:
        return "audio";
    case TrackKind::Still:
        return "still";
    }
    return "unknown";
}

const char *toString(VideoCodec codec) {
    switch (codec) {
    case VideoCodec::H264:
        return "h264";
    case VideoCodec::HEVC:
        return "hevc";
    case VideoCodec::ProRes422:
        return "prores422";
    }
    return "unknown";
}

const char *toString(AudioCodec codec) {
    switch (codec) {
    case AudioCodec::AAC:
        return "aac";
    case AudioCodec::LinearPCM:
        return "pcm";
    }
    return "unknown";
}

const char *toString(ContainerFormat container) {
    switch (container) {
    case ContainerFormat::MOV:
        return "mov";
    case ContainerFormat::MP4:
        return "mp4";
    case ContainerFormat::M4A:
        return "m4a";
    case ContainerFormat::WAV:
        return "wav";
    }
    return "unknown";
}

uint32_t codecType(VideoCodec codec) {
    switch (codec) {
    case VideoCodec::H264:
        return fourcc::H264;
    case VideoCodec::HEVC:
        return fourcc::HEVC;
    case VideoCodec::ProRes422:
        return fourcc::ProRes422;
    }
    return 0;
}

const TrackInfo *MediaInfo::firstTrack(TrackKind kind) const {
    for (const TrackInfo &t : tracks) {
        if (t.kind == kind) {
            return &t;
        }
    }
    return nullptr;
}

const TrackInfo *MediaInfo::track(int index) const {
    for (const TrackInfo &t : tracks) {
        if (t.index == index) {
            return &t;
        }
    }
    return nullptr;
}

namespace {
std::string timeString(CMTime t) {
    if (CMTIME_IS_INDEFINITE(t)) {
        return "indefinite";
    }
    if (!CMTIME_IS_NUMERIC(t)) {
        return "invalid";
    }
    char buf[64];
    snprintf(buf, sizeof buf, "%.6fs (%lld/%d)", CMTimeGetSeconds(t), t.value, t.timescale);
    return buf;
}
} // namespace

std::string MediaInfo::description() const {
    std::ostringstream s;
    s << path << " [" << container << ", " << backend << "] duration " << timeString(duration) << "\n";
    for (const TrackInfo &t : tracks) {
        s << "  #" << t.index << " " << toString(t.kind) << " " << t.codec.name << " (" << t.codec.fourCCString()
          << ")";
        if (t.kind != TrackKind::Audio) {
            s << " " << t.width << "x" << t.height;
            if (t.rotationDegrees != 0) {
                s << " rot" << t.rotationDegrees;
            }
        }
        if (t.kind == TrackKind::Video) {
            s << " fd " << timeString(t.frameDuration) << " fps " << t.nominalFps << (t.isVFR ? " VFR" : " CFR")
              << " depth " << t.bitDepth << " color " << toString(t.color.primaries) << "/"
              << toString(t.color.transfer) << "/" << toString(t.color.matrix)
              << (t.color.fullRange ? " full" : " video");
        }
        if (t.kind == TrackKind::Audio) {
            s << " " << t.sampleRate << " Hz " << t.channels << " ch";
        }
        s << " duration " << timeString(t.duration) << "\n";
    }
    return s.str();
}

bool alphaIsPremultiplied(CVPixelBufferRef buffer, bool untaggedDefault) {
    if (buffer == nullptr) {
        return true;
    }
    CFTypeRef mode = CVBufferCopyAttachment(buffer, kCVImageBufferAlphaChannelModeKey, nullptr);
    if (mode != nullptr) {
        const bool straight = CFGetTypeID(mode) == CFStringGetTypeID() &&
                              CFEqual(mode, kCVImageBufferAlphaChannelMode_StraightAlpha);
        CFRelease(mode);
        return !straight;
    }
    return pixelFormatHasAlpha(CVPixelBufferGetPixelFormatType(buffer)) ? untaggedDefault : true;
}

bool pixelFormatHasAlpha(OSType format) {
    switch (format) {
    case kCVPixelFormatType_32BGRA:
    case kCVPixelFormatType_32ARGB:
    case kCVPixelFormatType_32RGBA:
    case kCVPixelFormatType_32ABGR:
    case kCVPixelFormatType_64ARGB:
    case kCVPixelFormatType_64RGBAHalf:
    case kCVPixelFormatType_128RGBAFloat:
    case kCVPixelFormatType_4444YpCbCrA8:
    case kCVPixelFormatType_4444YpCbCrA8R:
    case kCVPixelFormatType_4444AYpCbCr8:
    case kCVPixelFormatType_4444AYpCbCr16:
    case kCVPixelFormatType_420YpCbCr8VideoRange_8A_TriPlanar:
        return true;
    default:
        return false;
    }
}

void setAlphaMode(CVPixelBufferRef buffer, bool premultiplied) {
    if (buffer == nullptr) {
        return;
    }
    CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelModeKey,
                          premultiplied ? kCVImageBufferAlphaChannelMode_PremultipliedAlpha
                                        : kCVImageBufferAlphaChannelMode_StraightAlpha,
                          kCVAttachmentMode_ShouldPropagate);
}

bool VideoFrame::contains(CMTime t) const {
    if (!CMTIME_IS_NUMERIC(pts) || !CMTIME_IS_NUMERIC(t) || CMTimeCompare(t, pts) < 0) {
        return false;
    }
    if (CMTIME_IS_POSITIVE_INFINITY(duration)) {
        return true;
    }
    return CMTIME_IS_NUMERIC(duration) && CMTimeCompare(t, CMTimeAdd(pts, duration)) < 0;
}

} // namespace ve::media
