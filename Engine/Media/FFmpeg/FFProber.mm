#include "FFProber.h"

#include "FFStillImage.h"

extern "C" {
#include <libavutil/pixdesc.h>
}

#include <cmath>
#include <cstdio>

namespace ve::media::ffmpeg {

namespace {

/// Parses Matroska's per-track "DURATION" tag ("HH:MM:SS.nnnnnnnnn").
CMTime durationTag(const AVStream *stream) {
    const auto value = metadataValue(stream->metadata, "DURATION");
    if (!value) {
        return kCMTimeInvalid;
    }
    unsigned hours = 0;
    unsigned minutes = 0;
    double seconds = 0;
    if (sscanf(value->c_str(), "%u:%u:%lf", &hours, &minutes, &seconds) != 3) {
        return kCMTimeInvalid;
    }
    return CMTimeMakeWithSeconds(hours * 3600.0 + minutes * 60.0 + seconds, 1000000000);
}

ChromaSubsampling chroma(const AVPixFmtDescriptor *d) {
    if (d == nullptr || d->nb_components < 3) {
        return ChromaSubsampling::Unknown;
    }
    if (d->flags & AV_PIX_FMT_FLAG_RGB) {
        return ChromaSubsampling::C444;
    }
    if (d->log2_chroma_w == 1 && d->log2_chroma_h == 1) {
        return ChromaSubsampling::C420;
    }
    if (d->log2_chroma_w == 1 && d->log2_chroma_h == 0) {
        return ChromaSubsampling::C422;
    }
    if (d->log2_chroma_w == 0 && d->log2_chroma_h == 0) {
        return ChromaSubsampling::C444;
    }
    return ChromaSubsampling::Unknown;
}

bool validRate(AVRational r) {
    return r.num > 0 && r.den > 0;
}

} // namespace

TrackInfo describeStream(const AVFormatContext *ctx, const AVStream *stream) {
    const AVCodecParameters *par = stream->codecpar;
    TrackInfo info;
    info.index = stream->index;
    info.codec.fourCC = fourCCForStream(par);
    info.codec.name = codecName(info.codec.fourCC, par->codec_id);

    int64_t shift = 0;
    if (par->codec_type == AVMEDIA_TYPE_VIDEO) {
        info.kind = TrackKind::Video;
        info.width = par->width;
        info.height = par->height;
        info.rotationDegrees = rotationDegrees(stream);
        info.color = colorInfo(par);
        const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(static_cast<AVPixelFormat>(par->format));
        info.bitDepth = d ? d->comp[0].depth : (par->bits_per_raw_sample > 0 ? par->bits_per_raw_sample : 0);
        info.chroma = chroma(d);

        const AVRational avg = stream->avg_frame_rate;
        const AVRational real = stream->r_frame_rate;
        if (validRate(avg)) {
            info.nominalFps = av_q2d(avg);
            info.frameDuration = frameDurationFromRate(avg);
            if (validRate(real)) {
                const double nominal = 1.0 / av_q2d(avg);
                const double minimum = 1.0 / av_q2d(real);
                info.isVFR = std::fabs(minimum - nominal) / nominal > 0.01;
                if (info.isVFR && minimum < nominal) {
                    info.frameDuration = frameDurationFromRate(real);
                }
            }
        } else if (validRate(real)) {
            info.nominalFps = av_q2d(real);
            info.frameDuration = frameDurationFromRate(real);
        }
    } else {
        info.kind = TrackKind::Audio;
        info.sampleRate = par->sample_rate;
        info.channels = par->ch_layout.nb_channels;
        shift = audioTimelineShift(ctx, stream);
    }

    const int64_t start = stream->start_time != AV_NOPTS_VALUE ? stream->start_time - shift : 0;
    info.startTime = toCMTime(start, stream->time_base);

    CMTime duration = kCMTimeInvalid;
    if (shift != 0) {
        if (const auto gapless = iTunesGapless(ctx); gapless && gapless->samples > 0 && par->sample_rate > 0) {
            duration = CMTimeMake(gapless->samples, par->sample_rate);
        }
    }
    if (!CMTIME_IS_VALID(duration) && stream->duration != AV_NOPTS_VALUE && stream->duration > 0) {
        duration = toCMTime(stream->duration, stream->time_base);
    }
    if (!CMTIME_IS_VALID(duration)) {
        duration = durationTag(stream);
    }
    if (!CMTIME_IS_VALID(duration) && ctx->duration != AV_NOPTS_VALUE && ctx->duration > 0) {
        const CMTime total = CMTimeMake(ctx->duration, AV_TIME_BASE);
        const CMTime containerStart =
            ctx->start_time != AV_NOPTS_VALUE ? CMTimeMake(ctx->start_time, AV_TIME_BASE) : kCMTimeZero;
        duration = CMTimeSubtract(CMTimeAdd(containerStart, total), info.startTime);
    }
    // Matroska (and Ogg) express encoder delay as negative timestamps plus a codec delay
    // (initial_padding); the delayed samples are not part of the timeline: the track starts where
    // they end and is that much shorter than its raw timestamps say.
    if (info.kind == TrackKind::Audio && par->initial_padding > 0 && par->sample_rate > 0 &&
        stream->start_time != AV_NOPTS_VALUE && stream->start_time < 0 && CMTIME_IS_NUMERIC(duration)) {
        const CMTime padding = CMTimeMake(par->initial_padding, par->sample_rate);
        info.startTime = CMTimeMaximum(kCMTimeZero, CMTimeAdd(info.startTime, padding));
        duration = CMTimeSubtract(duration, padding);
    }
    info.duration = duration;
    return info;
}

Result<MediaInfo> FFProber::probe(const std::string &path) {
    auto opened = openInput(path);
    if (!opened.ok()) {
        return std::move(opened).error();
    }
    AVFormatContext *ctx = opened->get();
    if (isHeifFamily(ctx)) {
        return makeError(MediaErrorCode::UnsupportedFormat,
                         "HEIF/AVIF images are not decoded by the FFmpeg backend: " + path);
    }
    MediaInfo info;
    info.path = path;
    info.backend = "ffmpeg";
    info.container = containerToken(ctx, path);

    if (isImageDemuxer(ctx)) {
        auto still = decodeStill(ctx);
        if (!still.ok()) {
            return std::move(still).error();
        }
        info.duration = kCMTimeIndefinite;
        info.tracks.push_back(stillTrackInfo(still.value()));
        return info;
    }

    CMTime end = kCMTimeInvalid;
    for (unsigned i = 0; i < ctx->nb_streams; ++i) {
        const AVStream *stream = ctx->streams[i];
        const AVMediaType type = stream->codecpar->codec_type;
        if ((type != AVMEDIA_TYPE_VIDEO && type != AVMEDIA_TYPE_AUDIO) ||
            (stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            continue; // Cover art, subtitles, timecode and data streams are not editable media.
        }
        TrackInfo track = describeStream(ctx, stream);
        if (!CMTIME_IS_NUMERIC(track.duration) || CMTimeCompare(track.duration, kCMTimeZero) <= 0) {
            return makeError(MediaErrorCode::CorruptData,
                             "stream " + std::to_string(i) + " has no valid duration in " + path);
        }
        const CMTime trackEnd = CMTimeAdd(track.startTime, track.duration);
        if (!CMTIME_IS_VALID(end) || CMTimeCompare(trackEnd, end) > 0) {
            end = trackEnd;
        }
        info.tracks.push_back(std::move(track));
    }
    if (info.tracks.empty()) {
        return makeError(MediaErrorCode::UnsupportedFormat, "no audio or video streams in " + path);
    }
    info.duration = end;
    return info;
}

} // namespace ve::media::ffmpeg
