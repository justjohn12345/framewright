#include "FFmpegSupport.h"

extern "C" {
#include <libavutil/avstring.h>
#include <libavutil/display.h>
#include <libavutil/pixdesc.h>
}

#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <mutex>

namespace ve::media::ffmpeg {

// MARK: - RAII

void FormatOutputDeleter::operator()(AVFormatContext *ctx) const noexcept {
    if (ctx == nullptr) {
        return;
    }
    if (ctx->oformat != nullptr && !(ctx->oformat->flags & AVFMT_NOFILE) && ctx->pb != nullptr) {
        avio_closep(&ctx->pb);
    }
    avformat_free_context(ctx);
}

Result<FramePtr> allocFrame() {
    FramePtr frame(av_frame_alloc());
    if (!frame) {
        return makeError(MediaErrorCode::Internal, "av_frame_alloc failed", "FFmpeg", AVERROR(ENOMEM));
    }
    return frame;
}

Result<PacketPtr> allocPacket() {
    PacketPtr packet(av_packet_alloc());
    if (!packet) {
        return makeError(MediaErrorCode::Internal, "av_packet_alloc failed", "FFmpeg", AVERROR(ENOMEM));
    }
    return packet;
}

// MARK: - Errors

std::string avErrorString(int err) {
    char buffer[AV_ERROR_MAX_STRING_SIZE] = {};
    if (av_strerror(err, buffer, sizeof buffer) < 0) {
        snprintf(buffer, sizeof buffer, "AVERROR %d", err);
    }
    return buffer;
}

MediaError ffError(int err, MediaErrorCode code, const std::string &context) {
    if (err == AVERROR(ENOENT)) {
        code = MediaErrorCode::FileNotFound;
    } else if (err == AVERROR(EACCES) || err == AVERROR(EPERM)) {
        code = MediaErrorCode::PermissionDenied;
    } else if (err == AVERROR_INVALIDDATA &&
               (code == MediaErrorCode::Internal || code == MediaErrorCode::DecodeFailed)) {
        code = MediaErrorCode::CorruptData;
    } else if (err == AVERROR_DECODER_NOT_FOUND || err == AVERROR_ENCODER_NOT_FOUND) {
        code = MediaErrorCode::UnsupportedCodec;
    } else if (err == AVERROR_DEMUXER_NOT_FOUND || err == AVERROR_MUXER_NOT_FOUND) {
        code = MediaErrorCode::UnsupportedFormat;
    }
    return makeError(code, context + ": " + avErrorString(err), "FFmpeg", err);
}

Status checkReadableFile(const std::string &path) {
    if (path.empty()) {
        return makeError(MediaErrorCode::InvalidArgument, "empty path");
    }
    struct stat st {};
    if (::stat(path.c_str(), &st) != 0) {
        const int e = errno;
        if (e == EACCES) {
            return makeError(MediaErrorCode::PermissionDenied, "not accessible: " + path, "POSIX", e);
        }
        return makeError(MediaErrorCode::FileNotFound, "no such file: " + path, "POSIX", e);
    }
    if (S_ISDIR(st.st_mode)) {
        return makeError(MediaErrorCode::UnsupportedFormat, "is a directory: " + path);
    }
    if (::access(path.c_str(), R_OK) != 0) {
        return makeError(MediaErrorCode::PermissionDenied, "not readable: " + path, "POSIX", errno);
    }
    if (st.st_size == 0) {
        return makeError(MediaErrorCode::UnsupportedFormat, "empty file: " + path);
    }
    return okStatus();
}

void initializeFFmpegOnce() {
    static std::once_flag once;
    std::call_once(once, [] { av_log_set_level(AV_LOG_ERROR); });
}

// MARK: - Input

namespace {

/// Demuxers this backend opens. Restricting probing keeps random or truncated data from being
/// "recognised" by one of FFmpeg's hundreds of exotic demuxers, and keeps raw elementary
/// streams (no timestamps) and the network/device demuxers out.
constexpr const char *kDemuxerWhitelist = "mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi,mpegts,flv,ogg,wav,w64,"
                                          "aiff,caf,mp3,flac,aac,mxf,png_pipe,jpeg_pipe,bmp_pipe,tiff_pipe,"
                                          "webp_pipe,gif_pipe";

bool nameHas(const AVFormatContext *ctx, const char *token) {
    return ctx != nullptr && ctx->iformat != nullptr && av_match_name(token, ctx->iformat->name) > 0;
}

std::string majorBrand(const AVFormatContext *ctx) {
    return metadataValue(ctx->metadata, "major_brand").value_or("");
}

bool fileHeaderContains(const std::string &path, const char *needle, size_t bytes) {
    std::ifstream in(path, std::ios::binary);
    std::string head(bytes, '\0');
    in.read(head.data(), static_cast<std::streamsize>(bytes));
    head.resize(static_cast<size_t>(std::max<std::streamsize>(in.gcount(), 0)));
    return head.find(needle) != std::string::npos;
}

} // namespace

Result<FormatInputPtr> openInput(const std::string &path) {
    initializeFFmpegOnce();
    VE_MEDIA_TRY(checkReadableFile(path));
    AVDictionary *options = nullptr;
    av_dict_set(&options, "format_whitelist", kDemuxerWhitelist, 0);
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    AVFormatContext *raw = nullptr;
    const int rc = avformat_open_input(&raw, path.c_str(), nullptr, &options);
    av_dict_free(&options);
    if (rc < 0) {
        // avformat_open_input frees the context on failure. Unrecognised content (INVALIDDATA)
        // and demuxers outside the whitelist (EINVAL) are both "not a format we handle".
        return ffError(rc, MediaErrorCode::UnsupportedFormat, "avformat_open_input(" + path + ")");
    }
    FormatInputPtr ctx(raw);
    const int info = avformat_find_stream_info(ctx.get(), nullptr);
    if (info < 0) {
        return ffError(info, MediaErrorCode::CorruptData, "avformat_find_stream_info(" + path + ")");
    }
    return ctx;
}

bool isQuickTimeFamily(const AVFormatContext *ctx) {
    return nameHas(ctx, "mov");
}

bool isImageDemuxer(const AVFormatContext *ctx) {
    if (ctx == nullptr || ctx->iformat == nullptr) {
        return false;
    }
    const std::string name = ctx->iformat->name;
    return name == "image2" || (name.size() > 5 && name.compare(name.size() - 5, 5, "_pipe") == 0);
}

bool isHeifFamily(const AVFormatContext *ctx) {
    if (!nameHas(ctx, "mov")) {
        return false;
    }
    const std::string brand = majorBrand(ctx);
    for (const char *b : {"heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1", "avif", "avis"}) {
        if (brand == b) {
            return true;
        }
    }
    return false;
}

std::string containerToken(const AVFormatContext *ctx, const std::string &path) {
    if (ctx == nullptr || ctx->iformat == nullptr) {
        return {};
    }
    const std::string name = ctx->iformat->name;
    if (nameHas(ctx, "mov")) {
        const std::string brand = majorBrand(ctx);
        if (brand.empty() || brand == "qt  ") {
            return "mov";
        }
        if (brand == "M4A " || brand == "M4B " || brand == "M4P ") {
            return "m4a";
        }
        if (brand.compare(0, 3, "M4V") == 0) {
            return "m4v";
        }
        if (brand == "avif" || brand == "avis") {
            return "avif";
        }
        if (isHeifFamily(ctx)) {
            return "heic";
        }
        return "mp4";
    }
    if (nameHas(ctx, "matroska")) {
        // One demuxer serves both; the EBML DocType in the first bytes tells them apart.
        return fileHeaderContains(path, "webm", 64) ? "webm" : "mkv";
    }
    struct Map {
        const char *demuxer;
        const char *token;
    };
    static const Map map[] = {
        {"wav", "wav"},         {"w64", "w64"},         {"aiff", "aiff"},       {"caf", "caf"},
        {"mp3", "mp3"},         {"avi", "avi"},         {"mpegts", "mpegts"},   {"flv", "flv"},
        {"ogg", "ogg"},         {"flac", "flac"},       {"aac", "aac"},         {"mxf", "mxf"},
        {"png_pipe", "png"},    {"jpeg_pipe", "jpeg"},  {"bmp_pipe", "bmp"},    {"tiff_pipe", "tiff"},
        {"webp_pipe", "webp"},  {"gif_pipe", "gif"},
    };
    for (const Map &m : map) {
        if (nameHas(ctx, m.demuxer)) {
            return m.token;
        }
    }
    return name.substr(0, name.find(','));
}

// MARK: - Time

CMTime toCMTime(int64_t value, AVRational timeBase) {
    if (value == AV_NOPTS_VALUE || timeBase.num <= 0 || timeBase.den <= 0) {
        return kCMTimeInvalid;
    }
    if (timeBase.num == 1) {
        return CMTimeMake(value, timeBase.den);
    }
    const int64_t limit = INT64_MAX / timeBase.num;
    if (value <= limit && value >= -limit) {
        return CMTimeMake(value * timeBase.num, timeBase.den);
    }
    return CMTimeMakeWithSeconds(static_cast<double>(value) * av_q2d(timeBase), 1000000000);
}

int64_t fromCMTime(CMTime time, AVRational timeBase, AVRounding rounding) {
    if (!CMTIME_IS_NUMERIC(time)) {
        return AV_NOPTS_VALUE;
    }
    const AVRational source{1, time.timescale};
    return av_rescale_q_rnd(time.value, source, timeBase,
                            static_cast<AVRounding>(rounding | AV_ROUND_PASS_MINMAX));
}

CMTime frameDurationFromRate(AVRational rate) {
    if (rate.num <= 0 || rate.den <= 0) {
        return kCMTimeInvalid;
    }
    return CMTimeMake(rate.den, rate.num);
}

// MARK: - Codecs

namespace {

struct CodecEntry {
    AVCodecID id;
    uint32_t fourCC;
};

constexpr uint32_t fcc(const char (&s)[5]) {
    return fourcc::make(s);
}

// Primary four-cc per codec (first match wins when mapping AVCodecID -> four-cc).
const CodecEntry kCodecs[] = {
    {AV_CODEC_ID_H264, fourcc::H264},
    {AV_CODEC_ID_HEVC, fourcc::HEVC},
    {AV_CODEC_ID_PRORES, fourcc::ProRes422},
    {AV_CODEC_ID_AV1, fourcc::AV1},
    {AV_CODEC_ID_VP9, fourcc::VP9},
    {AV_CODEC_ID_VP8, fcc("vp08")},
    {AV_CODEC_ID_MPEG4, fcc("mp4v")},
    {AV_CODEC_ID_MPEG2VIDEO, fcc("mp2v")},
    {AV_CODEC_ID_MJPEG, fourcc::JPEG},
    {AV_CODEC_ID_PNG, fourcc::PNG},
    {AV_CODEC_ID_TIFF, fcc("tiff")},
    {AV_CODEC_ID_GIF, fcc("gif ")},
    {AV_CODEC_ID_BMP, fcc("BMPf")},
    {AV_CODEC_ID_WEBP, fcc("webp")},
    {AV_CODEC_ID_DNXHD, fcc("AVdn")},
    {AV_CODEC_ID_THEORA, fcc("theo")},
    {AV_CODEC_ID_AAC, fourcc::AAC},
    {AV_CODEC_ID_MP3, fcc(".mp3")},
    {AV_CODEC_ID_OPUS, fcc("opus")},
    {AV_CODEC_ID_VORBIS, fcc("vorb")},
    {AV_CODEC_ID_FLAC, fcc("fLaC")},
    {AV_CODEC_ID_ALAC, fcc("alac")},
    {AV_CODEC_ID_AC3, fcc("ac-3")},
    {AV_CODEC_ID_EAC3, fcc("ec-3")},
    {AV_CODEC_ID_PCM_MULAW, fcc("ulaw")},
    {AV_CODEC_ID_PCM_ALAW, fcc("alaw")},
};

bool isLinearPCM(AVCodecID id) {
    switch (id) {
    case AV_CODEC_ID_PCM_S16LE:
    case AV_CODEC_ID_PCM_S16BE:
    case AV_CODEC_ID_PCM_U8:
    case AV_CODEC_ID_PCM_S8:
    case AV_CODEC_ID_PCM_S24LE:
    case AV_CODEC_ID_PCM_S24BE:
    case AV_CODEC_ID_PCM_S32LE:
    case AV_CODEC_ID_PCM_S32BE:
    case AV_CODEC_ID_PCM_F32LE:
    case AV_CODEC_ID_PCM_F32BE:
    case AV_CODEC_ID_PCM_F64LE:
    case AV_CODEC_ID_PCM_F64BE:
    case AV_CODEC_ID_PCM_S16LE_PLANAR:
    case AV_CODEC_ID_PCM_S24LE_PLANAR:
    case AV_CODEC_ID_PCM_S32LE_PLANAR:
        return true;
    default:
        return false;
    }
}

uint32_t proResFourCC(const AVCodecParameters *par) {
    const uint32_t tag = par->codec_tag;
    // codec_tag is little-endian MKTAG('a','p','c','n'); four-ccs are big-endian.
    const uint32_t fromTag = ((tag & 0xFF) << 24) | ((tag & 0xFF00) << 8) | ((tag >> 8) & 0xFF00) | (tag >> 24);
    if (isProRes(fromTag)) {
        return fromTag;
    }
    switch (par->profile) {
    case AV_PROFILE_PRORES_PROXY:
        return fourcc::ProRes422Proxy;
    case AV_PROFILE_PRORES_LT:
        return fourcc::ProRes422LT;
    case AV_PROFILE_PRORES_HQ:
        return fourcc::ProRes422HQ;
    case AV_PROFILE_PRORES_4444:
        return fourcc::ProRes4444;
    case AV_PROFILE_PRORES_XQ:
        return fourcc::ProRes4444XQ;
    default:
        return fourcc::ProRes422;
    }
}

} // namespace

uint32_t fourCCForStream(const AVCodecParameters *par) {
    if (par == nullptr) {
        return 0;
    }
    const uint32_t tag = par->codec_tag;
    const uint32_t tagBE = ((tag & 0xFF) << 24) | ((tag & 0xFF00) << 8) | ((tag >> 8) & 0xFF00) | (tag >> 24);
    switch (par->codec_id) {
    case AV_CODEC_ID_H264:
        return tagBE == fcc("avc3") ? fcc("avc3") : fourcc::H264;
    case AV_CODEC_ID_HEVC:
        return tagBE == fourcc::HEVCAlt ? fourcc::HEVCAlt : fourcc::HEVC;
    case AV_CODEC_ID_PRORES:
        return proResFourCC(par);
    case AV_CODEC_ID_AAC:
        if (par->profile == AV_PROFILE_AAC_HE) {
            return fcc("aach");
        }
        if (par->profile == AV_PROFILE_AAC_HE_V2) {
            return fcc("aacp");
        }
        return fourcc::AAC;
    default:
        break;
    }
    if (isLinearPCM(par->codec_id)) {
        return fourcc::LinearPCM;
    }
    for (const CodecEntry &e : kCodecs) {
        if (e.id == par->codec_id) {
            return e.fourCC;
        }
    }
    return 0;
}

AVCodecID codecIdForFourCC(uint32_t code) {
    const uint32_t c = canonicalCodec(code);
    if (isProRes(c)) {
        return AV_CODEC_ID_PRORES;
    }
    if (c == fourcc::LinearPCM) {
        return AV_CODEC_ID_PCM_S16LE; // Representative: every PCM layout has a decoder.
    }
    if (c == fcc("aach") || c == fcc("aacp")) {
        return AV_CODEC_ID_AAC;
    }
    for (const CodecEntry &e : kCodecs) {
        if (e.fourCC == c) {
            return e.id;
        }
    }
    return AV_CODEC_ID_NONE;
}

std::string codecName(uint32_t code, AVCodecID id) {
    if (code != 0) {
        const std::string display = codecDisplayName(code);
        if (display != fourCCToString(code)) {
            return display;
        }
    }
    if (const AVCodecDescriptor *d = avcodec_descriptor_get(id)) {
        return d->long_name ? d->long_name : d->name;
    }
    return code != 0 ? fourCCToString(code) : "unknown";
}

bool canDecode(AVCodecID id) {
    if (id == AV_CODEC_ID_NONE || id == AV_CODEC_ID_AV1) {
        return false;
    }
    return avcodec_find_decoder(id) != nullptr;
}

// MARK: - Colour

ColorPrimaries colorPrimaries(AVColorPrimaries v) {
    switch (v) {
    case AVCOL_PRI_BT709:
        return ColorPrimaries::BT709;
    case AVCOL_PRI_SMPTE170M:
    case AVCOL_PRI_SMPTE240M:
        return ColorPrimaries::BT601_525;
    case AVCOL_PRI_BT470BG:
        return ColorPrimaries::BT601_625;
    case AVCOL_PRI_BT2020:
        return ColorPrimaries::BT2020;
    case AVCOL_PRI_SMPTE432:
        return ColorPrimaries::P3_D65;
    case AVCOL_PRI_SMPTE431:
        return ColorPrimaries::DCI_P3;
    default:
        return ColorPrimaries::Unknown;
    }
}

TransferFunction transferFunction(AVColorTransferCharacteristic v) {
    switch (v) {
    case AVCOL_TRC_BT709:
    case AVCOL_TRC_SMPTE170M:
    case AVCOL_TRC_BT2020_10:
    case AVCOL_TRC_BT2020_12:
        return TransferFunction::BT709; // Same curve (CoreVideo tags all of them ITU_R_709_2).
    case AVCOL_TRC_IEC61966_2_1:
        return TransferFunction::SRGB;
    case AVCOL_TRC_LINEAR:
        return TransferFunction::Linear;
    case AVCOL_TRC_SMPTE2084:
        return TransferFunction::PQ;
    case AVCOL_TRC_ARIB_STD_B67:
        return TransferFunction::HLG;
    case AVCOL_TRC_SMPTE240M:
        return TransferFunction::SMPTE240M;
    default:
        return TransferFunction::Unknown;
    }
}

YCbCrMatrix yCbCrMatrix(AVColorSpace v) {
    switch (v) {
    case AVCOL_SPC_BT709:
        return YCbCrMatrix::BT709;
    case AVCOL_SPC_BT470BG:
    case AVCOL_SPC_SMPTE170M:
        return YCbCrMatrix::BT601;
    case AVCOL_SPC_BT2020_NCL:
    case AVCOL_SPC_BT2020_CL:
        return YCbCrMatrix::BT2020;
    case AVCOL_SPC_SMPTE240M:
        return YCbCrMatrix::SMPTE240M;
    default:
        return YCbCrMatrix::Unknown;
    }
}

AVColorPrimaries avColorPrimaries(ColorPrimaries v) {
    switch (v) {
    case ColorPrimaries::BT709:
        return AVCOL_PRI_BT709;
    case ColorPrimaries::BT601_525:
        return AVCOL_PRI_SMPTE170M;
    case ColorPrimaries::BT601_625:
        return AVCOL_PRI_BT470BG;
    case ColorPrimaries::BT2020:
        return AVCOL_PRI_BT2020;
    case ColorPrimaries::P3_D65:
        return AVCOL_PRI_SMPTE432;
    case ColorPrimaries::DCI_P3:
        return AVCOL_PRI_SMPTE431;
    case ColorPrimaries::Unknown:
        break;
    }
    return AVCOL_PRI_UNSPECIFIED;
}

AVColorTransferCharacteristic avTransfer(TransferFunction v) {
    switch (v) {
    case TransferFunction::BT709:
        return AVCOL_TRC_BT709;
    case TransferFunction::SRGB:
        return AVCOL_TRC_IEC61966_2_1;
    case TransferFunction::Linear:
        return AVCOL_TRC_LINEAR;
    case TransferFunction::PQ:
        return AVCOL_TRC_SMPTE2084;
    case TransferFunction::HLG:
        return AVCOL_TRC_ARIB_STD_B67;
    case TransferFunction::SMPTE240M:
        return AVCOL_TRC_SMPTE240M;
    case TransferFunction::Unknown:
        break;
    }
    return AVCOL_TRC_UNSPECIFIED;
}

AVColorSpace avColorSpace(YCbCrMatrix v) {
    switch (v) {
    case YCbCrMatrix::BT709:
        return AVCOL_SPC_BT709;
    case YCbCrMatrix::BT601:
        return AVCOL_SPC_SMPTE170M;
    case YCbCrMatrix::BT2020:
        return AVCOL_SPC_BT2020_NCL;
    case YCbCrMatrix::SMPTE240M:
        return AVCOL_SPC_SMPTE240M;
    case YCbCrMatrix::Unknown:
        break;
    }
    return AVCOL_SPC_UNSPECIFIED;
}

ColorInfo colorInfo(const AVCodecParameters *par) {
    ColorInfo c;
    c.primaries = colorPrimaries(par->color_primaries);
    c.transfer = transferFunction(par->color_trc);
    c.matrix = yCbCrMatrix(par->color_space);
    const auto format = static_cast<AVPixelFormat>(par->format);
    c.fullRange = par->color_range == AVCOL_RANGE_JPEG || format == AV_PIX_FMT_YUVJ420P ||
                  format == AV_PIX_FMT_YUVJ422P || format == AV_PIX_FMT_YUVJ444P;
    return c;
}

// MARK: - Misc

int rotationDegrees(const AVStream *stream) {
    const AVCodecParameters *par = stream->codecpar;
    const AVPacketSideData *sd =
        av_packet_side_data_get(par->coded_side_data, par->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (sd == nullptr || sd->size < 9 * sizeof(int32_t)) {
        return 0;
    }
    const double counterClockwise = av_display_rotation_get(reinterpret_cast<const int32_t *>(sd->data));
    if (std::isnan(counterClockwise)) {
        return 0;
    }
    int r = static_cast<int>(std::lround(-counterClockwise / 90.0)) * 90;
    return ((r % 360) + 360) % 360;
}

std::optional<std::string> metadataValue(const AVDictionary *dict, const char *key) {
    const AVDictionaryEntry *e = av_dict_get(dict, key, nullptr, 0);
    if (e == nullptr || e->value == nullptr) {
        return std::nullopt;
    }
    return std::string(e->value);
}

void fitDimensions(int maxDimension, int &width, int &height) {
    if (maxDimension <= 0 || width <= 0 || height <= 0 || (width <= maxDimension && height <= maxDimension)) {
        return;
    }
    const double scale = static_cast<double>(maxDimension) / std::max(width, height);
    width = std::max(2, static_cast<int>(std::lround(width * scale / 2.0)) * 2);
    height = std::max(2, static_cast<int>(std::lround(height * scale / 2.0)) * 2);
}

std::optional<ITunesGapless> iTunesGapless(const AVFormatContext *ctx) {
    const auto value = metadataValue(ctx->metadata, "iTunSMPB");
    if (!value) {
        return std::nullopt;
    }
    unsigned priming = 0;
    unsigned remainder = 0;
    unsigned long long samples = 0;
    if (sscanf(value->c_str(), "%*X %X %X %llX", &priming, &remainder, &samples) != 3) {
        return std::nullopt;
    }
    ITunesGapless g;
    g.priming = priming;
    g.samples = static_cast<int64_t>(samples);
    return g;
}

int64_t audioTimelineShift(const AVFormatContext *ctx, const AVStream *stream) {
    const AVCodecParameters *par = stream->codecpar;
    if (!nameHas(ctx, "mov") || par->codec_id != AV_CODEC_ID_AAC || par->sample_rate <= 0 ||
        stream->start_time == AV_NOPTS_VALUE) {
        return 0;
    }
    const auto gapless = iTunesGapless(ctx);
    if (!gapless || gapless->priming <= 0) {
        return 0;
    }
    // With an edit list, libavformat shifts the priming to negative timestamps and start_time is
    // 0; only an unshifted track starts exactly at the priming length.
    const int64_t startSamples = av_rescale_q(stream->start_time, stream->time_base, AVRational{1, par->sample_rate});
    if (std::llabs(startSamples - gapless->priming) > 1) {
        return 0;
    }
    return stream->start_time;
}

} // namespace ve::media::ffmpeg
