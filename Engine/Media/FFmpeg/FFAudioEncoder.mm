#include "FFAudioEncoder.h"

#include "FFmpegSupport.h"

extern "C" {
#include <libavutil/audio_fifo.h>
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
}

#include <cmath>
#include <string>
#include <vector>

namespace ve::media::ffmpeg {

namespace {

struct FifoDeleter {
    void operator()(AVAudioFifo *fifo) const noexcept { av_audio_fifo_free(fifo); }
};
using FifoPtr = std::unique_ptr<AVAudioFifo, FifoDeleter>;

/// Picks the encoder's sample format, preferring float (no quantisation before the codec).
AVSampleFormat chooseSampleFormat(const AVCodecContext *ctx, const AVCodec *codec) {
    const void *configs = nullptr;
    int count = 0;
    if (avcodec_get_supported_config(ctx, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, &configs, &count) < 0 ||
        configs == nullptr || count <= 0) {
        return AV_SAMPLE_FMT_FLTP;
    }
    const auto *formats = static_cast<const AVSampleFormat *>(configs);
    for (AVSampleFormat preferred : {AV_SAMPLE_FMT_FLT, AV_SAMPLE_FMT_FLTP, AV_SAMPLE_FMT_S32, AV_SAMPLE_FMT_S32P,
                                     AV_SAMPLE_FMT_S16, AV_SAMPLE_FMT_S16P}) {
        for (int i = 0; i < count; ++i) {
            if (formats[i] == preferred) {
                return preferred;
            }
        }
    }
    return formats[0];
}

const char *pcmEncoderName(int bits) {
    switch (bits) {
    case 16:
        return "pcm_s16le";
    case 24:
        return "pcm_s24le";
    case 32:
        return "pcm_f32le";
    default:
        return nullptr;
    }
}

constexpr int kPcmFrameSize = 1024;

} // namespace

struct FFAudioEncoder::Impl {
    bool opened = false;
    bool flushed = false;
    AudioEncodeSettings settings;
    CodecContextPtr codec;
    std::string name;
    SwrPtr swr;
    FifoPtr fifo;
    PacketPtr packet;
    AVChannelLayout layout{};
    int frameSize = kPcmFrameSize;
    int64_t samplesSent = 0;
    std::vector<uint8_t> convertBuffer;

    ~Impl() { av_channel_layout_uninit(&layout); }

    Status tryOpen(const char *encoderName) {
        const AVCodec *encoder = avcodec_find_encoder_by_name(encoderName);
        if (encoder == nullptr) {
            return makeError(MediaErrorCode::UnsupportedCodec, std::string("encoder ") + encoderName +
                                                                   " is not in this FFmpeg build");
        }
        CodecContextPtr ctx(avcodec_alloc_context3(encoder));
        if (!ctx) {
            return makeError(MediaErrorCode::Internal, "avcodec_alloc_context3 failed");
        }
        const int rate = static_cast<int>(settings.sampleRate);
        ctx->sample_rate = rate;
        int rc = av_channel_layout_copy(&ctx->ch_layout, &layout);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::Internal, "av_channel_layout_copy");
        }
        ctx->time_base = AVRational{1, rate};
        ctx->sample_fmt = chooseSampleFormat(ctx.get(), encoder);
        ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        if (settings.codec == AudioCodec::AAC) {
            ctx->bit_rate = settings.bitRate;
        }
        rc = avcodec_open2(ctx.get(), encoder, nullptr);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::UnsupportedCodec, std::string("avcodec_open2(") + encoderName + ")");
        }
        codec = std::move(ctx);
        name = encoderName;
        return okStatus();
    }

    Status sendFrame(int count, const PacketSink &sink) {
        auto f = allocFrame();
        if (!f.ok()) {
            return std::move(f).error();
        }
        AVFrame *frame = f->get();
        frame->nb_samples = count;
        frame->format = codec->sample_fmt;
        frame->sample_rate = codec->sample_rate;
        int rc = av_channel_layout_copy(&frame->ch_layout, &codec->ch_layout);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::Internal, "av_channel_layout_copy");
        }
        rc = av_frame_get_buffer(frame, 0);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::Internal, "av_frame_get_buffer");
        }
        const int available = std::min(count, av_audio_fifo_size(fifo.get()));
        if (available > 0 &&
            av_audio_fifo_read(fifo.get(), reinterpret_cast<void **>(frame->extended_data), available) != available) {
            return makeError(MediaErrorCode::Internal, "av_audio_fifo_read short read");
        }
        if (available < count) {
            av_samples_set_silence(frame->extended_data, available, count - available, codec->ch_layout.nb_channels,
                                   codec->sample_fmt);
        }
        frame->pts = samplesSent;
        samplesSent += count;
        rc = avcodec_send_frame(codec.get(), frame);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::EncodeFailed, "avcodec_send_frame");
        }
        return drain(sink, false);
    }

    Status drain(const PacketSink &sink, bool untilEof) {
        AVPacket *pkt = packet.get();
        const AVRational tb = codec->time_base;
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
            out.pts = toCMTime(pkt->pts, tb);
            out.dts = toCMTime(pkt->dts != AV_NOPTS_VALUE ? pkt->dts : pkt->pts, tb);
            out.duration = toCMTime(pkt->duration > 0 ? pkt->duration : frameSize, tb);
            out.isKeyframe = true;
            out.data.assign(pkt->data, pkt->data + pkt->size);
            av_packet_unref(pkt);
            VE_MEDIA_TRY(sink(std::move(out)));
        }
    }
};

FFAudioEncoder::FFAudioEncoder() : impl_(std::make_unique<Impl>()) {}

FFAudioEncoder::~FFAudioEncoder() = default;

Status FFAudioEncoder::validate(const AudioEncodeSettings &a) {
    if (a.channels < 1 || a.channels > 8 || !(a.sampleRate >= 8000 && a.sampleRate <= 192000) ||
        std::floor(a.sampleRate) != a.sampleRate) {
        return makeError(MediaErrorCode::InvalidArgument, "audio needs 1...8 channels and an integral rate");
    }
    if (a.codec == AudioCodec::LinearPCM && pcmEncoderName(a.pcmBitDepth) == nullptr) {
        return makeError(MediaErrorCode::InvalidArgument, "PCM bit depth must be 16, 24 or 32");
    }
    if (a.codec == AudioCodec::AAC && a.bitRate <= 0) {
        return makeError(MediaErrorCode::InvalidArgument, "AAC needs a positive bit rate");
    }
    return okStatus();
}

Status FFAudioEncoder::open(const AudioEncodeSettings &settings) {
    Impl &d = *impl_;
    if (d.opened) {
        return makeError(MediaErrorCode::InvalidState, "open() called twice");
    }
    initializeFFmpegOnce();
    VE_MEDIA_TRY(validate(settings));
    d.settings = settings;
    av_channel_layout_default(&d.layout, settings.channels);
    if (settings.codec == AudioCodec::AAC) {
        Status s = d.tryOpen("aac_at");
        if (!s.ok()) {
            s = d.tryOpen("aac");
        }
        VE_MEDIA_TRY(s);
    } else {
        VE_MEDIA_TRY(d.tryOpen(pcmEncoderName(settings.pcmBitDepth)));
    }
    d.frameSize = d.codec->frame_size > 0 ? d.codec->frame_size : kPcmFrameSize;

    SwrContext *raw = nullptr;
    const int rate = static_cast<int>(settings.sampleRate);
    int rc = swr_alloc_set_opts2(&raw, &d.layout, d.codec->sample_fmt, rate, &d.layout, AV_SAMPLE_FMT_FLT, rate, 0,
                                 nullptr);
    d.swr.reset(raw);
    if (rc < 0 || !d.swr) {
        return ffError(rc < 0 ? rc : AVERROR(ENOMEM), MediaErrorCode::Internal, "swr_alloc_set_opts2");
    }
    rc = swr_init(d.swr.get());
    if (rc < 0) {
        return ffError(rc, MediaErrorCode::Internal, "swr_init");
    }
    d.fifo.reset(av_audio_fifo_alloc(d.codec->sample_fmt, settings.channels, d.frameSize * 4));
    if (!d.fifo) {
        return makeError(MediaErrorCode::Internal, "av_audio_fifo_alloc failed");
    }
    auto packet = allocPacket();
    if (!packet.ok()) {
        return std::move(packet).error();
    }
    d.packet = std::move(packet).value();
    d.opened = true;
    return okStatus();
}

Result<EncodedStreamFormat> FFAudioEncoder::outputFormat() const {
    const Impl &d = *impl_;
    if (!d.opened) {
        return makeError(MediaErrorCode::InvalidState, "outputFormat() before open()");
    }
    EncodedStreamFormat f;
    f.kind = TrackKind::Audio;
    f.codec = d.settings.codec == AudioCodec::AAC ? fourcc::AAC : fourcc::LinearPCM;
    f.sampleRate = d.settings.sampleRate;
    f.channels = d.settings.channels;
    f.bitRate = d.settings.codec == AudioCodec::AAC
                    ? d.settings.bitRate
                    : static_cast<int64_t>(d.settings.sampleRate) * d.settings.channels * d.settings.pcmBitDepth;
    f.timescale = static_cast<int32_t>(d.settings.sampleRate);
    if (d.codec->extradata != nullptr && d.codec->extradata_size > 0) {
        f.extradata.assign(d.codec->extradata, d.codec->extradata + d.codec->extradata_size);
    }
    return f;
}

Status FFAudioEncoder::encode(const float *interleaved, int frames, const PacketSink &sink) {
    Impl &d = *impl_;
    if (!d.opened || d.flushed) {
        return makeError(MediaErrorCode::InvalidState, "encode() needs an open, unflushed encoder");
    }
    if (frames < 0 || (frames > 0 && interleaved == nullptr)) {
        return makeError(MediaErrorCode::InvalidArgument, "encode() needs samples");
    }
    if (frames == 0) {
        return okStatus();
    }
    const int channels = d.settings.channels;
    const int size = av_samples_get_buffer_size(nullptr, channels, frames, d.codec->sample_fmt, 1);
    if (size < 0) {
        return ffError(size, MediaErrorCode::Internal, "av_samples_get_buffer_size");
    }
    d.convertBuffer.resize(static_cast<size_t>(size));
    const bool planar = av_sample_fmt_is_planar(d.codec->sample_fmt);
    std::vector<uint8_t *> planes(static_cast<size_t>(planar ? channels : 1));
    int rc = av_samples_fill_arrays(planes.data(), nullptr, d.convertBuffer.data(), channels, frames,
                                    d.codec->sample_fmt, 1);
    if (rc < 0) {
        return ffError(rc, MediaErrorCode::Internal, "av_samples_fill_arrays");
    }
    const uint8_t *in[1] = {reinterpret_cast<const uint8_t *>(interleaved)};
    const int converted = swr_convert(d.swr.get(), planes.data(), frames, in, frames);
    if (converted < 0) {
        return ffError(converted, MediaErrorCode::EncodeFailed, "swr_convert");
    }
    if (av_audio_fifo_write(d.fifo.get(), reinterpret_cast<void **>(planes.data()), converted) != converted) {
        return makeError(MediaErrorCode::Internal, "av_audio_fifo_write failed");
    }
    while (av_audio_fifo_size(d.fifo.get()) >= d.frameSize) {
        VE_MEDIA_TRY(d.sendFrame(d.frameSize, sink));
    }
    return okStatus();
}

Status FFAudioEncoder::flush(const PacketSink &sink) {
    Impl &d = *impl_;
    if (!d.opened || d.flushed) {
        return makeError(MediaErrorCode::InvalidState, "flush() needs an open, unflushed encoder");
    }
    d.flushed = true;
    const int remaining = av_audio_fifo_size(d.fifo.get());
    if (remaining > 0) {
        const bool shortLastFrame =
            d.codec->codec->capabilities & (AV_CODEC_CAP_SMALL_LAST_FRAME | AV_CODEC_CAP_VARIABLE_FRAME_SIZE);
        VE_MEDIA_TRY(d.sendFrame(shortLastFrame ? remaining : d.frameSize, sink));
    }
    const int rc = avcodec_send_frame(d.codec.get(), nullptr);
    if (rc < 0) {
        return ffError(rc, MediaErrorCode::EncodeFailed, "avcodec_send_frame(flush)");
    }
    return d.drain(sink, true);
}

std::string FFAudioEncoder::encoderName() const {
    return impl_->name;
}

int FFAudioEncoder::initialPadding() const {
    return impl_->codec ? impl_->codec->initial_padding : 0;
}

} // namespace ve::media::ffmpeg
