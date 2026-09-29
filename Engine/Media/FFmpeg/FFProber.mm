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
#include <limits>
#include <map>
#include <optional>
#include <vector>

namespace ve::media::ffmpeg {

namespace {

os_log_t proberLog() {
    static os_log_t log = os_log_create("ve.media.ffmpeg", "probe");
    return log;
}

/// Matroska's per-track "DURATION" tag ("HH:MM:SS.nnnnnnnnn") in whole nanoseconds, read exactly
/// (digits past the ninth are dropped); nullopt when there is none or it is malformed.
std::optional<int64_t> durationTagNanoseconds(const AVStream *stream) {
    const auto value = metadataValue(stream->metadata, "DURATION");
    if (!value) {
        return std::nullopt;
    }
    unsigned hours = 0;
    unsigned minutes = 0;
    unsigned seconds = 0;
    int consumed = 0;
    if (sscanf(value->c_str(), "%u:%u:%u%n", &hours, &minutes, &seconds, &consumed) != 3 || minutes >= 60 ||
        seconds >= 60 || hours > 1000000) {
        return std::nullopt;
    }
    int64_t fraction = 0;
    const char *rest = value->c_str() + consumed;
    if (*rest == '.') {
        int digits = 0;
        for (++rest; *rest >= '0' && *rest <= '9'; ++rest) {
            if (digits < 9) {
                fraction = fraction * 10 + (*rest - '0');
                ++digits;
            }
        }
        for (; digits < 9; ++digits) {
            fraction *= 10;
        }
    }
    if (*rest != '\0') {
        return std::nullopt;
    }
    return (int64_t(hours) * 3600 + int64_t(minutes) * 60 + int64_t(seconds)) * 1000000000 + fraction;
}

/// A track's length from its DURATION tag, put on the track's own grid. The tag is the length
/// rounded to the nanosecond, a timescale on which few clip ends combine exactly (a third of a
/// second is not a whole number of nanoseconds), so a clip on such media could not be reversed
/// (its mirrored in point, the media's end less the clip's out point, had no CMTime form; post-lanes
/// review L1). The true length lies on the track's grid, within the container's timestamp
/// resolution (`timeBase`, 1 ms in Matroska): an audio track's is a whole number of samples (the
/// nearest one to the tag); a constant-rate video track's a whole number of frames when the tag is
/// within that resolution of one, else it is rounded up to the resolution (nothing of the last
/// frame is cut; the decoders hold the last frame past the pictures' end).
CMTime tagDurationOnGrid(int64_t nanoseconds, const TrackInfo &info, AVRational timeBase) {
    constexpr int64_t kNano = 1000000000;
    if (info.kind == TrackKind::Audio && info.sampleRate >= 1 && info.sampleRate <= INT32_MAX &&
        info.sampleRate == std::floor(info.sampleRate)) {
        const auto rate = static_cast<int64_t>(info.sampleRate);
        const __int128 samples = (static_cast<__int128>(nanoseconds) * rate + kNano / 2) / kNano;
        return CMTimeMake(static_cast<int64_t>(samples), static_cast<int32_t>(rate));
    }
    const __int128 resolution =
        timeBase.num > 0 && timeBase.den > 0
            ? std::max<__int128>(1, static_cast<__int128>(timeBase.num) * kNano / timeBase.den)
            : 1;
    if (info.kind == TrackKind::Video && !info.isVFR && CMTIME_IS_NUMERIC(info.frameDuration) &&
        info.frameDuration.value > 0 && info.frameDuration.timescale > 0) {
        const __int128 unit = static_cast<__int128>(info.frameDuration.value) * kNano; // one frame, x timescale
        const __int128 scaled = static_cast<__int128>(nanoseconds) * info.frameDuration.timescale;
        const __int128 frames = (scaled + unit / 2) / unit;
        const __int128 off = frames * unit - scaled; // (candidate - tag) x timescale, in nanoseconds
        if (frames > 0 && (off < 0 ? -off : off) <= resolution * info.frameDuration.timescale &&
            frames * info.frameDuration.value <= std::numeric_limits<int64_t>::max()) {
            return CMTimeMake(static_cast<int64_t>(frames * info.frameDuration.value), info.frameDuration.timescale);
        }
    }
    if (timeBase.num > 0 && timeBase.den > 0 && timeBase.den <= INT32_MAX) {
        const __int128 tickNanos = static_cast<__int128>(timeBase.num) * kNano; // one tick, x den
        const __int128 scaled = static_cast<__int128>(nanoseconds) * timeBase.den;
        const __int128 ticks = (scaled + tickNanos - 1) / tickNanos;
        const __int128 value = ticks * timeBase.num;
        if (value <= std::numeric_limits<int64_t>::max()) {
            return CMTimeMake(static_cast<int64_t>(value), timeBase.den);
        }
    }
    return CMTimeMake(nanoseconds, static_cast<int32_t>(kNano));
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
        if (const auto nanoseconds = durationTagNanoseconds(stream); nanoseconds && *nanoseconds > 0) {
            duration = tagDurationOnGrid(*nanoseconds, info, stream->time_base);
        }
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
