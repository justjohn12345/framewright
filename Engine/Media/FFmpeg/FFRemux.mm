#include "FFRemux.h"

#include "FFmpegSupport.h"

#include <unistd.h>

#include <cerrno>
#include <cstring>
#include <vector>

namespace ve::media::ffmpeg {

namespace {

Status remuxInto(AVFormatContext *in, AVFormatContext *out, const std::string &destination,
                 const std::string &formatName) {
    const bool matroska = formatName == "matroska" || formatName == "webm";
    std::vector<int> map(in->nb_streams, -1);
    for (unsigned i = 0; i < in->nb_streams; ++i) {
        AVStream *src = in->streams[i];
        const AVMediaType type = src->codecpar->codec_type;
        if ((type != AVMEDIA_TYPE_VIDEO && type != AVMEDIA_TYPE_AUDIO) ||
            (src->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            continue;
        }
        AVStream *dst = avformat_new_stream(out, nullptr);
        if (dst == nullptr) {
            return makeError(MediaErrorCode::Internal, "avformat_new_stream failed");
        }
        const int rc = avcodec_parameters_copy(dst->codecpar, src->codecpar);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::Internal, "avcodec_parameters_copy");
        }
        dst->codecpar->codec_tag = 0; // Let the muxer pick its own tag for the codec.
        dst->time_base = src->time_base;
        dst->avg_frame_rate = src->avg_frame_rate;
        dst->r_frame_rate = src->r_frame_rate;
        dst->sample_aspect_ratio = src->sample_aspect_ratio;
        map[i] = dst->index;
    }
    if (out->nb_streams == 0) {
        return makeError(MediaErrorCode::UnsupportedFormat, "no audio or video streams to remux");
    }

    // Packets are read up front until every mapped stream has shown its first packet, because
    // an audio stream's encoder delay (a negative first timestamp) must be in the header for
    // Matroska (CodecDelay).
    PacketPtr packet(av_packet_alloc());
    if (!packet) {
        return makeError(MediaErrorCode::Internal, "av_packet_alloc failed");
    }
    std::vector<PacketPtr> head;
    std::vector<bool> seen(in->nb_streams, false);
    size_t pendingStreams = out->nb_streams;
    bool eof = false;
    while (pendingStreams > 0) {
        const int rc = av_read_frame(in, packet.get());
        if (rc == AVERROR_EOF) {
            eof = true;
            break;
        }
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::CorruptData, "av_read_frame");
        }
        const auto si = static_cast<size_t>(packet->stream_index);
        if (map[si] < 0) {
            av_packet_unref(packet.get());
            continue;
        }
        if (!seen[si]) {
            seen[si] = true;
            --pendingStreams;
            AVStream *src = in->streams[si];
            if (matroska && src->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && packet->pts != AV_NOPTS_VALUE &&
                packet->pts < 0 && src->codecpar->sample_rate > 0) {
                out->streams[map[si]]->codecpar->initial_padding = static_cast<int>(
                    av_rescale_q(-packet->pts, src->time_base, AVRational{1, src->codecpar->sample_rate}));
            }
        }
        head.emplace_back(av_packet_clone(packet.get()));
        av_packet_unref(packet.get());
        if (!head.back()) {
            return makeError(MediaErrorCode::Internal, "av_packet_clone failed");
        }
    }

    int rc = avio_open(&out->pb, destination.c_str(), AVIO_FLAG_WRITE);
    if (rc < 0) {
        return ffError(rc, MediaErrorCode::WriteFailed, "avio_open(" + destination + ")");
    }
    if (matroska) {
        out->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED; // Delay is carried as CodecDelay.
    }
    rc = avformat_write_header(out, nullptr);
    if (rc < 0) {
        return ffError(rc, MediaErrorCode::WriteFailed, "avformat_write_header");
    }
    auto write = [&](AVPacket *p) -> Status {
        const auto si = static_cast<size_t>(p->stream_index);
        const int di = map[si];
        av_packet_rescale_ts(p, in->streams[si]->time_base, out->streams[di]->time_base);
        p->stream_index = di;
        p->pos = -1;
        const int w = av_interleaved_write_frame(out, p);
        if (w < 0) {
            return ffError(w, MediaErrorCode::WriteFailed, "av_interleaved_write_frame");
        }
        return okStatus();
    };
    for (PacketPtr &p : head) {
        VE_MEDIA_TRY(write(p.get()));
    }
    head.clear();
    while (!eof) {
        rc = av_read_frame(in, packet.get());
        if (rc == AVERROR_EOF) {
            break;
        }
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::CorruptData, "av_read_frame");
        }
        if (map[static_cast<size_t>(packet->stream_index)] < 0) {
            av_packet_unref(packet.get());
            continue;
        }
        Status s = write(packet.get());
        av_packet_unref(packet.get());
        VE_MEDIA_TRY(s);
    }
    rc = av_write_trailer(out);
    if (rc < 0) {
        return ffError(rc, MediaErrorCode::WriteFailed, "av_write_trailer");
    }
    rc = avio_closep(&out->pb);
    if (rc < 0) {
        return ffError(rc, MediaErrorCode::WriteFailed, "avio_closep");
    }
    return okStatus();
}

} // namespace

Status remux(const std::string &source, const std::string &destination, const std::string &formatName) {
    auto input = openInput(source);
    if (!input.ok()) {
        return std::move(input).error();
    }
    if (destination.empty()) {
        return makeError(MediaErrorCode::InvalidArgument, "empty output path");
    }
    if (::unlink(destination.c_str()) != 0 && errno != ENOENT) {
        const int e = errno;
        return makeError(MediaErrorCode::PermissionDenied, "cannot replace " + destination + ": " + std::strerror(e),
                         "POSIX", e);
    }
    AVFormatContext *raw = nullptr;
    const int rc = avformat_alloc_output_context2(&raw, nullptr, formatName.c_str(), destination.c_str());
    if (rc < 0 || raw == nullptr) {
        return ffError(rc < 0 ? rc : AVERROR_MUXER_NOT_FOUND, MediaErrorCode::UnsupportedFormat,
                       "avformat_alloc_output_context2(" + formatName + ")");
    }
    FormatOutputPtr output(raw);
    Status s = remuxInto(input->get(), output.get(), destination, formatName);
    output.reset();
    if (!s.ok()) {
        ::unlink(destination.c_str());
    }
    return s;
}

} // namespace ve::media::ffmpeg
