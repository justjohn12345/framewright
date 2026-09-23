#include "FFVideoEncoder.h"

#include "../HardwareCaps.h"
#include "FFFrameConverter.h"
#include "FFmpegSupport.h"

extern "C" {
#include <libavutil/pixdesc.h>
}

#include <CoreFoundation/CoreFoundation.h>

#include <string>
#include <vector>

namespace ve::media::ffmpeg {

namespace {

const char *videoToolboxEncoderName(VideoCodec codec) {
    switch (codec) {
    case VideoCodec::H264:
        return "h264_videotoolbox";
    case VideoCodec::HEVC:
        return "hevc_videotoolbox";
    case VideoCodec::ProRes422:
        return "prores_videotoolbox";
    }
    return "";
}

/// av_buffer free callback releasing the CVPixelBuffer an AVFrame wraps.
void releasePixelBuffer(void * /*opaque*/, uint8_t *data) {
    CFRelease(reinterpret_cast<CVPixelBufferRef>(data));
}

} // namespace

struct FFVideoEncoder::Impl {
    bool opened = false;
    bool flushed = false;
    VideoEncodeSettings settings;
    CodecContextPtr codec;
    std::string name;
    bool hardware = false;
    bool videoToolbox = false;
    AVPixelFormat inputFormat = AV_PIX_FMT_NONE;
    AVRational timeBase{1, 30};
    PacketPtr packet;
    SwsPtr sws;

    // Decode-timestamp repair. FFmpeg's VideoToolbox wrapper derives dts from VideoToolbox's decode
    // timestamps minus a reorder delay it assumes (one frame for H.264), but VideoToolbox can
    // reorder deeper (B-frame pyramids), leaving dts > pts. The first kReorderWindow packets are
    // held back to measure the largest dts - pts, and every dts is shifted down by that much.
    static constexpr size_t kReorderWindow = 16;
    std::vector<EncodedPacket> held;
    bool shiftKnown = false;
    CMTime dtsShift = kCMTimeZero;

    Status tryOpen(const char *encoderName, bool allowSoftware) {
        const AVCodec *encoder = avcodec_find_encoder_by_name(encoderName);
        if (encoder == nullptr) {
            return makeError(MediaErrorCode::UnsupportedCodec, std::string("encoder ") + encoderName +
                                                                   " is not in this FFmpeg build");
        }
        CodecContextPtr ctx(avcodec_alloc_context3(encoder));
        if (!ctx) {
            return makeError(MediaErrorCode::Internal, "avcodec_alloc_context3 failed");
        }
        const bool vt = std::string(encoderName).find("videotoolbox") != std::string::npos;
        ctx->width = settings.width;
        ctx->height = settings.height;
        ctx->time_base = timeBase;
        ctx->framerate = AVRational{settings.frameDuration.timescale, static_cast<int>(settings.frameDuration.value)};
        ctx->sample_aspect_ratio = AVRational{1, 1};
        ctx->color_primaries = avColorPrimaries(settings.color.primaries);
        ctx->color_trc = avTransfer(settings.color.transfer);
        ctx->colorspace = avColorSpace(settings.color.matrix);
        ctx->color_range = settings.color.fullRange ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG;
        ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        if (settings.maxKeyFrameInterval > 0) {
            ctx->gop_size = settings.maxKeyFrameInterval;
        }
        if (settings.codec != VideoCodec::ProRes422) {
            ctx->max_b_frames = settings.allowFrameReordering ? 2 : 0;
            if (settings.averageBitRate > 0) {
                ctx->bit_rate = settings.averageBitRate;
            } else if (settings.quality >= 0) {
                ctx->flags |= AV_CODEC_FLAG_QSCALE;
                ctx->global_quality = static_cast<int>(std::min(settings.quality, 1.0) * 100.0 * FF_QP2LAMBDA);
            }
        }
        AVDictionary *options = nullptr;
        if (vt) {
            ctx->pix_fmt = AV_PIX_FMT_VIDEOTOOLBOX;
            ctx->sw_pix_fmt = inputFormat;
            // Hardware required, or software required: never "either", so usesHardware() is a
            // fact rather than a guess about which encoder VideoToolbox picked.
            av_dict_set(&options, "allow_sw", allowSoftware ? "1" : "0", 0);
            av_dict_set(&options, "require_sw", allowSoftware ? "1" : "0", 0);
            if (settings.codec == VideoCodec::ProRes422) {
                av_dict_set(&options, "profile", "standard", 0);
            }
        } else {
            ctx->pix_fmt = AV_PIX_FMT_YUV422P10LE;
            av_dict_set(&options, "profile", "standard", 0);
        }
        const int rc = avcodec_open2(ctx.get(), encoder, &options);
        av_dict_free(&options);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::UnsupportedCodec, std::string("avcodec_open2(") + encoderName + ")");
        }
        codec = std::move(ctx);
        name = encoderName;
        videoToolbox = vt;
        hardware = vt && !allowSoftware;
        return okStatus();
    }

    Result<FramePtr> wrap(const PixelBuffer &image, int64_t pts) {
        auto f = allocFrame();
        if (!f.ok()) {
            return std::move(f).error();
        }
        AVFrame *out = f->get();
        out->width = settings.width;
        out->height = settings.height;
        out->pts = pts;
        out->color_primaries = codec->color_primaries;
        out->color_trc = codec->color_trc;
        out->colorspace = codec->colorspace;
        out->color_range = codec->color_range;
        if (videoToolbox) {
            CVPixelBufferRef pb = image.get();
            CFRetain(pb);
            out->buf[0] = av_buffer_create(reinterpret_cast<uint8_t *>(pb), 1, releasePixelBuffer, nullptr,
                                           AV_BUFFER_FLAG_READONLY);
            if (out->buf[0] == nullptr) {
                CFRelease(pb);
                return makeError(MediaErrorCode::Internal, "av_buffer_create failed");
            }
            out->format = AV_PIX_FMT_VIDEOTOOLBOX;
            out->data[3] = reinterpret_cast<uint8_t *>(pb);
            return std::move(f).value();
        }
        // Software encoder: convert on the CPU.
        out->format = codec->pix_fmt;
        int rc = av_frame_get_buffer(out, 0);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::Internal, "av_frame_get_buffer");
        }
        CVPixelBufferRef pb = image.get();
        PixelBufferLock lock(pb, true);
        if (!lock.locked()) {
            return makeError(MediaErrorCode::Internal, "CVPixelBufferLockBaseAddress failed");
        }
        SwsContext *ctx = sws_getCachedContext(sws.release(), settings.width, settings.height, inputFormat,
                                               settings.width, settings.height, codec->pix_fmt,
                                               SWS_POINT | SWS_ACCURATE_RND | SWS_FULL_CHR_H_INP, nullptr, nullptr,
                                               nullptr);
        sws.reset(ctx);
        if (!sws) {
            return makeError(MediaErrorCode::UnsupportedFormat, "sws_getCachedContext failed for encoder input");
        }
        const int *table = sws_getCoefficients(settings.color.matrix == YCbCrMatrix::BT601 ? SWS_CS_ITU601
                                                                                           : SWS_CS_ITU709);
        const bool srcFull = isFullRangeInput();
        sws_setColorspaceDetails(sws.get(), table, srcFull ? 1 : 0, table, settings.color.fullRange ? 1 : 0, 0,
                                 1 << 16, 1 << 16);
        const uint8_t *src[4] = {};
        int srcStride[4] = {};
        const size_t planes = CVPixelBufferGetPlaneCount(pb);
        if (planes == 0) {
            src[0] = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(pb));
            srcStride[0] = static_cast<int>(CVPixelBufferGetBytesPerRow(pb));
        } else {
            for (size_t p = 0; p < std::min<size_t>(planes, 4); ++p) {
                src[p] = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pb, p));
                srcStride[p] = static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(pb, p));
            }
        }
        rc = sws_scale(sws.get(), src, srcStride, 0, settings.height, out->data, out->linesize);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::Internal, "sws_scale (encoder input)");
        }
        return std::move(f).value();
    }

    bool isFullRangeInput() const {
        const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(inputFormat);
        if (d != nullptr && (d->flags & AV_PIX_FMT_FLAG_RGB)) {
            return true;
        }
        switch (settings.inputPixelFormat) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
        case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
        case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
            return true;
        default:
            return false;
        }
    }

    Status drain(const PacketSink &sink, bool untilEof) {
        AVPacket *pkt = packet.get();
        while (true) {
            const int rc = avcodec_receive_packet(codec.get(), pkt);
            if (rc == AVERROR(EAGAIN) && !untilEof) {
                return okStatus();
            }
            if (rc == AVERROR_EOF) {
                return okStatus();
            }
            if (rc < 0) {
                return ffError(rc, MediaErrorCode::EncodeFailed, "avcodec_receive_packet");
            }
            EncodedPacket out;
            out.pts = toCMTime(pkt->pts, timeBase);
            out.dts = pkt->dts != AV_NOPTS_VALUE ? toCMTime(pkt->dts, timeBase) : out.pts;
            out.duration = pkt->duration > 0 ? toCMTime(pkt->duration, timeBase) : settings.frameDuration;
            out.isKeyframe = (pkt->flags & AV_PKT_FLAG_KEY) != 0;
            out.data.assign(pkt->data, pkt->data + pkt->size);
            av_packet_unref(pkt);
            VE_MEDIA_TRY(deliver(std::move(out), sink));
        }
    }

    Status deliver(EncodedPacket &&encoded, const PacketSink &sink) {
        if (!shiftKnown) {
            held.push_back(std::move(encoded));
            return held.size() >= kReorderWindow ? releaseHeld(sink) : okStatus();
        }
        return emit(std::move(encoded), sink);
    }

    Status releaseHeld(const PacketSink &sink) {
        if (shiftKnown) {
            return okStatus();
        }
        for (const EncodedPacket &p : held) {
            const CMTime excess = CMTimeSubtract(p.dts, p.pts);
            if (CMTimeCompare(excess, dtsShift) > 0) {
                dtsShift = excess;
            }
        }
        shiftKnown = true;
        std::vector<EncodedPacket> packets = std::move(held);
        held.clear();
        for (EncodedPacket &p : packets) {
            VE_MEDIA_TRY(emit(std::move(p), sink));
        }
        return okStatus();
    }

    Status emit(EncodedPacket &&encoded, const PacketSink &sink) {
        encoded.dts = CMTimeSubtract(encoded.dts, dtsShift);
        if (CMTimeCompare(encoded.dts, encoded.pts) > 0) {
            return makeError(MediaErrorCode::EncodeFailed,
                             "encoder reordered frames deeper than its first " + std::to_string(kReorderWindow) +
                                 " packets showed");
        }
        return sink(std::move(encoded));
    }
};

FFVideoEncoder::FFVideoEncoder() : impl_(std::make_unique<Impl>()) {}

FFVideoEncoder::~FFVideoEncoder() = default;

Status FFVideoEncoder::validate(const VideoEncodeSettings &v) {
    if (v.width <= 0 || v.height <= 0 || v.width > 16384 || v.height > 16384 || ((v.width | v.height) & 1)) {
        return makeError(MediaErrorCode::InvalidArgument, "video size must be positive, even and <= 16384");
    }
    if (!CMTIME_IS_NUMERIC(v.frameDuration) || v.frameDuration.value <= 0 || v.frameDuration.value > INT32_MAX) {
        return makeError(MediaErrorCode::InvalidArgument, "frame duration must be positive");
    }
    if (avPixelFormatForCV(v.inputPixelFormat) == AV_PIX_FMT_NONE) {
        return makeError(MediaErrorCode::UnsupportedFormat,
                         "unsupported input pixel format " + fourCCToString(v.inputPixelFormat));
    }
    if (v.requireHardware && !HardwareCaps::get().hardwareEncode(codecType(v.codec))) {
        return makeError(MediaErrorCode::UnsupportedCodec,
                         std::string("no hardware ") + toString(v.codec) + " encoder on this machine");
    }
    return okStatus();
}

Status FFVideoEncoder::open(const VideoEncodeSettings &settings) {
    Impl &d = *impl_;
    if (d.opened) {
        return makeError(MediaErrorCode::InvalidState, "open() called twice");
    }
    initializeFFmpegOnce();
    VE_MEDIA_TRY(validate(settings));
    d.settings = settings;
    d.inputFormat = avPixelFormatForCV(settings.inputPixelFormat);
    d.timeBase = AVRational{1, settings.frameDuration.timescale};

    const bool hardwareAvailable = HardwareCaps::get().hardwareEncode(codecType(settings.codec));
    const char *vt = videoToolboxEncoderName(settings.codec);
    Status s = makeError(MediaErrorCode::UnsupportedCodec, "no encoder attempted");
    if (hardwareAvailable) {
        s = d.tryOpen(vt, false);
    }
    if (!s.ok() && !settings.requireHardware) {
        s = d.tryOpen(vt, true);
        if (!s.ok() && settings.codec == VideoCodec::ProRes422) {
            s = d.tryOpen("prores_ks", true);
        }
    }
    VE_MEDIA_TRY(s);

    auto packet = allocPacket();
    if (!packet.ok()) {
        return std::move(packet).error();
    }
    d.packet = std::move(packet).value();
    d.opened = true;
    return okStatus();
}

Result<EncodedStreamFormat> FFVideoEncoder::outputFormat() const {
    const Impl &d = *impl_;
    if (!d.opened) {
        return makeError(MediaErrorCode::InvalidState, "outputFormat() before open()");
    }
    EncodedStreamFormat f;
    f.kind = TrackKind::Video;
    f.codec = codecType(d.settings.codec);
    f.width = d.settings.width;
    f.height = d.settings.height;
    f.frameDuration = d.settings.frameDuration;
    f.color = d.settings.color;
    f.bitRate = d.codec->bit_rate;
    f.timescale = d.timeBase.den;
    if (d.codec->extradata != nullptr && d.codec->extradata_size > 0) {
        f.extradata.assign(d.codec->extradata, d.codec->extradata + d.codec->extradata_size);
    }
    return f;
}

Status FFVideoEncoder::encode(const PixelBuffer &image, CMTime pts, const PacketSink &sink) {
    Impl &d = *impl_;
    if (!d.opened || d.flushed) {
        return makeError(MediaErrorCode::InvalidState, "encode() needs an open, unflushed encoder");
    }
    if (!image || !CMTIME_IS_NUMERIC(pts)) {
        return makeError(MediaErrorCode::InvalidArgument, "encode() needs an image and a numeric pts");
    }
    if (static_cast<int>(image.width()) != d.settings.width || static_cast<int>(image.height()) != d.settings.height ||
        image.pixelFormat() != d.settings.inputPixelFormat) {
        return makeError(MediaErrorCode::InvalidArgument,
                         "frame is " + std::to_string(image.width()) + "x" + std::to_string(image.height()) + " " +
                             fourCCToString(image.pixelFormat()) + ", encoder expects " +
                             std::to_string(d.settings.width) + "x" + std::to_string(d.settings.height) + " " +
                             fourCCToString(d.settings.inputPixelFormat));
    }
    auto frame = d.wrap(image, fromCMTime(pts, d.timeBase, AV_ROUND_NEAR_INF));
    if (!frame.ok()) {
        return std::move(frame).error();
    }
    const int rc = avcodec_send_frame(d.codec.get(), frame->get());
    if (rc < 0) {
        return ffError(rc, MediaErrorCode::EncodeFailed, "avcodec_send_frame");
    }
    return d.drain(sink, false);
}

Status FFVideoEncoder::flush(const PacketSink &sink) {
    Impl &d = *impl_;
    if (!d.opened || d.flushed) {
        return makeError(MediaErrorCode::InvalidState, "flush() needs an open, unflushed encoder");
    }
    d.flushed = true;
    const int rc = avcodec_send_frame(d.codec.get(), nullptr);
    if (rc < 0) {
        return ffError(rc, MediaErrorCode::EncodeFailed, "avcodec_send_frame(flush)");
    }
    VE_MEDIA_TRY(d.drain(sink, true));
    return d.releaseHeld(sink);
}

bool FFVideoEncoder::usesHardware() const {
    return impl_->hardware;
}

std::string FFVideoEncoder::encoderName() const {
    return impl_->name;
}

} // namespace ve::media::ffmpeg
