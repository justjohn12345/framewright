#include "FFProber.h"

#include "FFStillImage.h"
#include "FFVideoDecoder.h"

extern "C" {
#include <libavutil/pixdesc.h>
}

#include <os/log.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <map>
#include <vector>

namespace ve::media::ffmpeg {

namespace {

os_log_t proberLog() {
    static os_log_t log = os_log_create("ve.media.ffmpeg", "probe");
    return log;
}

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

/// Durations of `streams` measured by reading every packet of the file (no decoding): the end
/// of the last packet minus the stream's start. For files that state no duration anywhere (a
/// crash-truncated or "live" Matroska recording). Streams without timestamps are left out.
std::map<int, CMTime> scanDurations(const std::string &path, const std::vector<int> &streams) {
    std::map<int, CMTime> result;
    auto input = openInput(path);
    if (!input.ok()) {
        return result;
    }
    AVFormatContext *ctx = input->get();
    std::map<int, int64_t> ends;
    for (unsigned i = 0; i < ctx->nb_streams; ++i) {
        const bool wanted = std::find(streams.begin(), streams.end(), static_cast<int>(i)) != streams.end();
        ctx->streams[i]->discard = wanted ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    }
    PacketPtr packet(av_packet_alloc());
    if (!packet) {
        return result;
    }
    while (av_read_frame(ctx, packet.get()) >= 0) {
        const int index = packet->stream_index;
        const int64_t ts = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
        if (ts != AV_NOPTS_VALUE) {
            const int64_t end = ts + std::max<int64_t>(packet->duration, 0);
            auto it = ends.find(index);
            if (it == ends.end() || end > it->second) {
                ends[index] = end;
            }
        }
        av_packet_unref(packet.get());
    }
    for (const auto &[index, end] : ends) {
        const AVStream *stream = ctx->streams[index];
        const int64_t start = stream->start_time != AV_NOPTS_VALUE ? stream->start_time : 0;
        if (end > start) {
            result[index] = toCMTime(end - start, stream->time_base);
        }
    }
    return result;
}

} // namespace

TrackInfo describeStream(const AVFormatContext *ctx, const AVStream *stream, const FrameTiming *timing) {
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
        if (timing != nullptr && timing->intervals >= 2) {
            if (timing->variable) {
                info.isVFR = true;
            }
            if (info.isVFR && CMTIME_IS_NUMERIC(timing->minimum) && CMTimeCompare(timing->minimum, kCMTimeZero) > 0) {
                info.frameDuration = timing->minimum;
            }
            if (!CMTIME_IS_NUMERIC(info.frameDuration) && CMTIME_IS_NUMERIC(timing->typical)) {
                info.frameDuration = timing->typical; // No declared rate at all.
            }
            if (info.nominalFps <= 0 && CMTIME_IS_NUMERIC(timing->typical) &&
                CMTimeCompare(timing->typical, kCMTimeZero) > 0) {
                info.nominalFps = 1.0 / CMTimeGetSeconds(timing->typical);
            }
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

    std::vector<int> media;
    std::vector<int> video;
    for (unsigned i = 0; i < ctx->nb_streams; ++i) {
        const AVStream *stream = ctx->streams[i];
        const AVMediaType type = stream->codecpar->codec_type;
        if ((type != AVMEDIA_TYPE_VIDEO && type != AVMEDIA_TYPE_AUDIO) ||
            (stream->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            continue; // Cover art, subtitles, timecode and data streams are not editable media.
        }
        media.push_back(static_cast<int>(i));
        if (type == AVMEDIA_TYPE_VIDEO) {
            video.push_back(static_cast<int>(i));
        }
    }
    if (media.empty()) {
        return makeError(MediaErrorCode::UnsupportedFormat, "no audio or video streams in " + path);
    }
    const std::map<int, FrameTiming> timing = scanFrameTiming(ctx, video);

    std::vector<TrackInfo> described;
    std::vector<int> undated;
    for (int i : media) {
        auto t = timing.find(i);
        described.push_back(describeStream(ctx, ctx->streams[i], t != timing.end() ? &t->second : nullptr));
        const TrackInfo &track = described.back();
        if (!CMTIME_IS_NUMERIC(track.duration) || CMTimeCompare(track.duration, kCMTimeZero) <= 0) {
            undated.push_back(i);
        }
    }
    if (!undated.empty()) {
        // No stated duration (a recording that was never finalised): measure it from the
        // packets instead of refusing the whole file.
        const std::map<int, CMTime> measured = scanDurations(path, undated);
        for (TrackInfo &track : described) {
            if (auto it = measured.find(track.index); it != measured.end()) {
                track.duration = it->second;
            }
        }
        os_log_info(proberLog(), "%{public}s: %zu stream(s) without a stated duration, %zu measured from packets",
                    path.c_str(), undated.size(), measured.size());
    }

    CMTime end = kCMTimeInvalid;
    std::string skipped;
    for (TrackInfo &track : described) {
        const int i = track.index;
        const AVStream *stream = ctx->streams[i];
        if (!CMTIME_IS_NUMERIC(track.duration) || CMTimeCompare(track.duration, kCMTimeZero) <= 0) {
            skipped += (skipped.empty() ? "" : ", ") + std::to_string(i);
            continue;
        }
        track.decodable = canDecode(codecIdForFourCC(track.codec.fourCC)) ||
                          canDecode(stream->codecpar->codec_id);
        if (track.kind == TrackKind::Video && track.decodable) {
            // Measure: open the decoder this backend uses and decode the first frame.
            FFVideoDecoder decoder;
            DecodeOptions options;
            options.allowHardware = true;
            const Status measured = decoder.openTrack(path, track, options);
            track.decodable = measured.ok();
            track.hardwareDecode = measured.ok() && decoder.usedHardware();
            if (!measured.ok()) {
                os_log_info(proberLog(), "%{public}s stream %d is not decodable: %{public}s", path.c_str(), i,
                            measured.error().description().c_str());
            }
        }
        const CMTime trackEnd = CMTimeAdd(track.startTime, track.duration);
        if (!CMTIME_IS_VALID(end) || CMTimeCompare(trackEnd, end) > 0) {
            end = trackEnd;
        }
        info.tracks.push_back(std::move(track));
    }
    if (!skipped.empty()) {
        os_log_error(proberLog(), "%{public}s: stream(s) %{public}s have no valid duration and are left out",
                     path.c_str(), skipped.c_str());
    }
    if (info.tracks.empty()) {
        return makeError(MediaErrorCode::CorruptData, "no stream has a valid duration in " + path);
    }
    info.duration = end;
    return info;
}

} // namespace ve::media::ffmpeg
