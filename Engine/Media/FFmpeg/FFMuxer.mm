#include "FFMuxer.h"

#include "FFmpegSupport.h"

extern "C" {
#include <libavutil/intreadwrite.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
}

#include <fcntl.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <deque>
#include <string>
#include <vector>

namespace ve::media::ffmpeg {

namespace {

/// Packets buffered while waiting for every stream's first packet before the header is forced.
constexpr size_t kMaxPendingPackets = 1024;

uint32_t mkTag(uint32_t fourCC) {
    return MKTAG((fourCC >> 24) & 0xFF, (fourCC >> 16) & 0xFF, (fourCC >> 8) & 0xFF, fourCC & 0xFF);
}

Result<AVCodecID> pcmCodec(const EncodedStreamFormat &f) {
    const int64_t perSample = static_cast<int64_t>(f.sampleRate) * f.channels;
    const int64_t bits = perSample > 0 ? f.bitRate / perSample : 0;
    switch (bits) {
    case 16:
        return AV_CODEC_ID_PCM_S16LE;
    case 24:
        return AV_CODEC_ID_PCM_S24LE;
    case 32:
        return AV_CODEC_ID_PCM_F32LE;
    default:
        return makeError(MediaErrorCode::InvalidArgument,
                         "linear PCM stream needs bitRate = sampleRate * channels * (16|24|32)");
    }
}

} // namespace

struct FFMuxer::Impl {
    enum class State { Idle, Open, Begun, Finished, Failed };
    State state = State::Idle;
    std::string path;
    std::string format;
    FormatOutputPtr ctx;
    std::vector<EncodedStreamFormat> formats;
    std::vector<std::deque<EncodedPacket>> pending;
    std::vector<bool> seen;
    size_t pendingCount = 0;
    bool headerWritten = false;
    PacketPtr packet;

    bool isMatroska() const { return format == "matroska" || format == "webm"; }
    bool isQuickTime() const { return format == "mov" || format == "mp4" || format == "ipod"; }

    void discardOutput() {
        ctx.reset(); // Closes the AVIO context.
        if (!path.empty()) {
            ::unlink(path.c_str());
        }
        pending.clear();
        pendingCount = 0;
    }

    Status fail(MediaError error) {
        discardOutput();
        state = State::Failed;
        return error;
    }

    Status writeHeader() {
        if (isMatroska()) {
            // Matroska cannot store negative timestamps: express the audio encoder delay as
            // CodecDelay (libavformat then offsets the blocks and the demuxer undoes it).
            for (size_t i = 0; i < pending.size(); ++i) {
                AVStream *st = ctx->streams[i];
                if (st->codecpar->codec_type != AVMEDIA_TYPE_AUDIO || pending[i].empty()) {
                    continue;
                }
                const CMTime first = pending[i].front().pts;
                if (CMTIME_IS_NUMERIC(first) && CMTimeCompare(first, kCMTimeZero) < 0) {
                    st->codecpar->initial_padding = static_cast<int>(
                        CMTimeConvertScale(CMTimeMultiply(first, -1), st->codecpar->sample_rate,
                                           kCMTimeRoundingMethod_RoundHalfAwayFromZero)
                            .value);
                }
            }
            ctx->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
        }
        AVDictionary *options = nullptr;
        if (format == "mp4") {
            av_dict_set(&options, "movflags", "+faststart", 0);
        }
        const int rc = avformat_write_header(ctx.get(), &options);
        av_dict_free(&options);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::WriteFailed, "avformat_write_header");
        }
        headerWritten = true;
        for (auto &queue : pending) {
            while (!queue.empty()) {
                EncodedPacket p = std::move(queue.front());
                queue.pop_front();
                VE_MEDIA_TRY(writeNow(p));
            }
        }
        pendingCount = 0;
        return okStatus();
    }

    Status writeNow(const EncodedPacket &p) {
        AVStream *st = ctx->streams[p.streamIndex];
        AVPacket *pkt = packet.get();
        int rc = av_new_packet(pkt, static_cast<int>(p.data.size()));
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::Internal, "av_new_packet");
        }
        if (!p.data.empty()) {
            std::memcpy(pkt->data, p.data.data(), p.data.size());
        }
        pkt->stream_index = p.streamIndex;
        pkt->pts = fromCMTime(p.pts, st->time_base, AV_ROUND_NEAR_INF);
        pkt->dts = CMTIME_IS_NUMERIC(p.dts) ? fromCMTime(p.dts, st->time_base, AV_ROUND_NEAR_INF) : pkt->pts;
        pkt->duration =
            CMTIME_IS_NUMERIC(p.duration) ? fromCMTime(p.duration, st->time_base, AV_ROUND_NEAR_INF) : 0;
        if (p.isKeyframe) {
            pkt->flags |= AV_PKT_FLAG_KEY;
        }
        if (p.trailingDiscard > 0 && isMatroska() && p.trailingDiscard <= UINT32_MAX) {
            // Matroska DiscardPadding: the demuxer hands it back as skip samples, and the decoder
            // drops the padding at the end of the stream.
            uint8_t *skip = av_packet_new_side_data(pkt, AV_PKT_DATA_SKIP_SAMPLES, 10);
            if (skip == nullptr) {
                av_packet_unref(pkt);
                return makeError(MediaErrorCode::Internal, "av_packet_new_side_data failed");
            }
            AV_WL32(skip, 0);
            AV_WL32(skip + 4, static_cast<uint32_t>(p.trailingDiscard));
            skip[8] = 0;
            skip[9] = 0;
        }
        rc = av_interleaved_write_frame(ctx.get(), pkt); // Takes the packet's reference.
        av_packet_unref(pkt);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::WriteFailed, "av_interleaved_write_frame");
        }
        return okStatus();
    }
};

FFMuxer::FFMuxer() : impl_(std::make_unique<Impl>()) {}

FFMuxer::~FFMuxer() {
    if (impl_->state == Impl::State::Open || impl_->state == Impl::State::Begun) {
        cancel(); // Never leave a half-written file behind.
    }
}

const char *FFMuxer::formatName(ContainerFormat container) {
    switch (container) {
    case ContainerFormat::MOV:
        return "mov";
    case ContainerFormat::MP4:
        return "mp4";
    case ContainerFormat::M4A:
        return "ipod";
    case ContainerFormat::WAV:
        return "wav";
    case ContainerFormat::MKV:
        return "matroska";
    }
    return "mov";
}

Status FFMuxer::open(const std::string &path, ContainerFormat container) {
    return openFormat(path, formatName(container));
}

Status FFMuxer::openFormat(const std::string &path, const std::string &formatName) {
    Impl &d = *impl_;
    if (d.state != Impl::State::Idle) {
        return makeError(MediaErrorCode::InvalidState, "open() called twice");
    }
    if (path.empty()) {
        return makeError(MediaErrorCode::InvalidArgument, "empty output path");
    }
    initializeFFmpegOnce();
    // Never truncate or replace an existing file (Interfaces.h): the file is created exclusively
    // first, so avio_open below only ever truncates the empty file made here.
    const int fd = ::open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0) {
        const int e = errno;
        if (e == EEXIST) {
            return makeError(MediaErrorCode::InvalidArgument,
                             "the output " + path + " already exists; the muxer only creates new files", "POSIX", e);
        }
        return makeError(e == EACCES || e == EPERM ? MediaErrorCode::PermissionDenied : MediaErrorCode::WriteFailed,
                         "cannot create " + path + ": " + std::strerror(e), "POSIX", e);
    }
    ::close(fd);
    auto removeCreated = [&] { ::unlink(path.c_str()); };
    AVFormatContext *raw = nullptr;
    int rc = avformat_alloc_output_context2(&raw, nullptr, formatName.c_str(), path.c_str());
    if (rc < 0 || raw == nullptr) {
        removeCreated();
        return ffError(rc < 0 ? rc : AVERROR_MUXER_NOT_FOUND, MediaErrorCode::UnsupportedFormat,
                       "avformat_alloc_output_context2(" + formatName + ")");
    }
    d.ctx.reset(raw);
    if (!(d.ctx->oformat->flags & AVFMT_NOFILE)) {
        rc = avio_open(&d.ctx->pb, path.c_str(), AVIO_FLAG_WRITE);
        if (rc < 0) {
            d.ctx.reset();
            removeCreated();
            return ffError(rc, MediaErrorCode::WriteFailed, "avio_open(" + path + ")");
        }
    } else {
        removeCreated(); // the muxer writes no file of its own
    }
    auto packet = allocPacket();
    if (!packet.ok()) {
        d.ctx.reset();
        removeCreated();
        return std::move(packet).error();
    }
    d.packet = std::move(packet).value();
    d.path = path;
    d.format = formatName;
    d.state = Impl::State::Open;
    return okStatus();
}

Result<int> FFMuxer::addStream(const EncodedStreamFormat &f) {
    Impl &d = *impl_;
    if (d.state != Impl::State::Open) {
        return makeError(MediaErrorCode::InvalidState, "addStream() must come after open() and before begin()");
    }
    if (f.timescale <= 0) {
        return makeError(MediaErrorCode::InvalidArgument, "stream needs a positive timescale");
    }
    AVCodecID id = codecIdForFourCC(f.codec);
    if (canonicalCodec(f.codec) == fourcc::LinearPCM) {
        auto pcm = pcmCodec(f);
        if (!pcm.ok()) {
            return std::move(pcm).error();
        }
        id = pcm.value();
    }
    if (id == AV_CODEC_ID_NONE) {
        return makeError(MediaErrorCode::UnsupportedCodec, "no FFmpeg codec for " + fourCCToString(f.codec));
    }
    // Same container rules as AppleWriter / FFmpegBackend::validate (stricter than libavformat,
    // which would e.g. put AAC in WAV or ProRes in MP4 that other players reject).
    const bool pcm = canonicalCodec(f.codec) == fourcc::LinearPCM;
    if ((f.kind != TrackKind::Audio && (d.format == "wav" || d.format == "ipod")) ||
        (d.format == "wav" && !pcm) || (d.format == "mp4" && (pcm || id == AV_CODEC_ID_PRORES))) {
        return makeError(MediaErrorCode::UnsupportedCodec, fourCCToString(f.codec) + " cannot be stored in " +
                                                               d.format);
    }
    if (avformat_query_codec(d.ctx->oformat, id, FF_COMPLIANCE_NORMAL) != 1) {
        return makeError(MediaErrorCode::UnsupportedCodec, fourCCToString(f.codec) + " cannot be stored in " +
                                                               d.format);
    }
    AVStream *st = avformat_new_stream(d.ctx.get(), nullptr);
    if (st == nullptr) {
        return makeError(MediaErrorCode::Internal, "avformat_new_stream failed");
    }
    AVCodecParameters *par = st->codecpar;
    par->codec_id = id;
    par->bit_rate = f.bitRate;
    if (f.kind == TrackKind::Audio) {
        par->codec_type = AVMEDIA_TYPE_AUDIO;
        par->sample_rate = static_cast<int>(f.sampleRate);
        av_channel_layout_default(&par->ch_layout, f.channels);
        if (id == AV_CODEC_ID_AAC) {
            par->frame_size = 1024;
        }
        const int bits = av_get_bits_per_sample(id);
        if (bits > 0) {
            par->bits_per_coded_sample = bits;
            par->block_align = bits / 8 * f.channels;
        }
    } else {
        par->codec_type = AVMEDIA_TYPE_VIDEO;
        par->width = f.width;
        par->height = f.height;
        par->sample_aspect_ratio = AVRational{1, 1};
        st->sample_aspect_ratio = par->sample_aspect_ratio;
        par->color_primaries = avColorPrimaries(f.color.primaries);
        par->color_trc = avTransfer(f.color.transfer);
        par->color_space = avColorSpace(f.color.matrix);
        par->color_range = f.color.fullRange ? AVCOL_RANGE_JPEG : AVCOL_RANGE_MPEG;
        if (CMTIME_IS_NUMERIC(f.frameDuration) && f.frameDuration.value > 0 && f.frameDuration.value <= INT32_MAX) {
            st->avg_frame_rate = AVRational{f.frameDuration.timescale, static_cast<int>(f.frameDuration.value)};
        }
        if (d.isQuickTime()) {
            if (id == AV_CODEC_ID_H264) {
                par->codec_tag = mkTag(fourcc::H264);
            } else if (id == AV_CODEC_ID_HEVC) {
                par->codec_tag = mkTag(fourcc::HEVC);
            } else if (id == AV_CODEC_ID_PRORES) {
                par->codec_tag = mkTag(isProRes(f.codec) ? f.codec : fourcc::ProRes422);
            }
        }
    }
    if (!f.extradata.empty()) {
        par->extradata = static_cast<uint8_t *>(av_mallocz(f.extradata.size() + AV_INPUT_BUFFER_PADDING_SIZE));
        if (par->extradata == nullptr) {
            return makeError(MediaErrorCode::Internal, "av_mallocz failed");
        }
        std::memcpy(par->extradata, f.extradata.data(), f.extradata.size());
        par->extradata_size = static_cast<int>(f.extradata.size());
    }
    st->time_base = AVRational{1, f.timescale};
    d.formats.push_back(f);
    d.pending.emplace_back();
    d.seen.push_back(false);
    return st->index;
}

Status FFMuxer::begin() {
    Impl &d = *impl_;
    if (d.state != Impl::State::Open) {
        return makeError(MediaErrorCode::InvalidState, "begin() needs an open muxer");
    }
    if (d.formats.empty()) {
        return makeError(MediaErrorCode::InvalidArgument, "no streams added");
    }
    d.state = Impl::State::Begun;
    return okStatus();
}

Status FFMuxer::writePacket(EncodedPacket &&packet) {
    Impl &d = *impl_;
    if (d.state != Impl::State::Begun) {
        return makeError(MediaErrorCode::InvalidState, "writePacket() needs begin()");
    }
    if (packet.streamIndex < 0 || static_cast<size_t>(packet.streamIndex) >= d.formats.size()) {
        return makeError(MediaErrorCode::InvalidArgument, "packet for unknown stream " +
                                                              std::to_string(packet.streamIndex));
    }
    if (!CMTIME_IS_NUMERIC(packet.pts)) {
        return makeError(MediaErrorCode::InvalidArgument, "packet needs a numeric pts");
    }
    if (d.headerWritten) {
        if (Status s = d.writeNow(packet); !s.ok()) {
            return d.fail(std::move(s).error());
        }
        return okStatus();
    }
    const auto index = static_cast<size_t>(packet.streamIndex);
    d.seen[index] = true;
    d.pending[index].push_back(std::move(packet));
    ++d.pendingCount;
    const bool allSeen = std::find(d.seen.begin(), d.seen.end(), false) == d.seen.end();
    if (allSeen || d.pendingCount > kMaxPendingPackets) {
        if (Status s = d.writeHeader(); !s.ok()) {
            return d.fail(std::move(s).error());
        }
    }
    return okStatus();
}

Status FFMuxer::finish() {
    Impl &d = *impl_;
    if (d.state != Impl::State::Begun) {
        return makeError(MediaErrorCode::InvalidState, "finish() needs begin()");
    }
    if (!d.headerWritten) {
        if (Status s = d.writeHeader(); !s.ok()) {
            return d.fail(std::move(s).error());
        }
    }
    int rc = av_write_trailer(d.ctx.get());
    if (rc < 0) {
        return d.fail(ffError(rc, MediaErrorCode::WriteFailed, "av_write_trailer"));
    }
    if (d.ctx->pb != nullptr && !(d.ctx->oformat->flags & AVFMT_NOFILE)) {
        rc = avio_closep(&d.ctx->pb);
        if (rc < 0) {
            return d.fail(ffError(rc, MediaErrorCode::WriteFailed, "avio_closep"));
        }
    }
    d.ctx.reset();
    d.state = Impl::State::Finished;
    return okStatus();
}

void FFMuxer::cancel() {
    Impl &d = *impl_;
    if (d.state == Impl::State::Open || d.state == Impl::State::Begun) {
        d.discardOutput();
    }
    d.state = Impl::State::Failed;
}

} // namespace ve::media::ffmpeg
