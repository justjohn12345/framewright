#include "FFAudioDecoder.h"

#include "FFProber.h"
#include "FFmpegSupport.h"

extern "C" {
#include <libavutil/channel_layout.h>
#include <libavutil/samplefmt.h>
}

#include <algorithm>
#include <cmath>
#include <cstring>
#include <numeric>
#include <vector>

namespace ve::media::ffmpeg {

namespace {

constexpr int kMaxConsecutiveErrors = 16;
constexpr int kMaxSeekRetries = 5;
constexpr int kSilenceChunk = 4096;

int64_t floorMod(int64_t a, int64_t m) {
    const int64_t r = a % m;
    return r < 0 ? r + m : r;
}

/// Codecs whose frames all have the same number of samples (the last one may be shorter).
bool hasFixedFrameSize(AVCodecID id) {
    switch (id) {
    case AV_CODEC_ID_AAC:
    case AV_CODEC_ID_AC3:
    case AV_CODEC_ID_EAC3:
    case AV_CODEC_ID_MP2:
    case AV_CODEC_ID_MP3:
        return true;
    default:
        return false;
    }
}

/// RAII for AVChannelLayout (which may own a custom map).
struct ChannelLayout {
    AVChannelLayout layout{};
    ChannelLayout() = default;
    ~ChannelLayout() { av_channel_layout_uninit(&layout); }
    ChannelLayout(const ChannelLayout &) = delete;
    ChannelLayout &operator=(const ChannelLayout &) = delete;
    int copyFrom(const AVChannelLayout &src) {
        av_channel_layout_uninit(&layout);
        if (src.order == AV_CHANNEL_ORDER_UNSPEC || av_channel_layout_check(&src) == 0) {
            av_channel_layout_default(&layout, std::max(1, src.nb_channels));
            return 0;
        }
        return av_channel_layout_copy(&layout, &src);
    }
};

} // namespace

struct FFAudioDecoder::Impl {
    bool opened = false;
    std::string path;
    double rate = 48000;
    int32_t timescale = 48000;
    int outChannels = 2;
    int64_t length = 0;
    bool lengthExact = false; ///< length is a sample-exact count (gapless metadata): cap output there.

    FormatInputPtr input;
    AVStream *stream = nullptr;
    int streamIndex = -1;
    CodecContextPtr codec;
    PacketPtr packet;
    FramePtr frame;
    int64_t shift = 0; ///< Stream time base; see audioTimelineShift().

    // Resampler.
    SwrPtr swr;
    int swrRate = 0;
    AVSampleFormat swrFormat = AV_SAMPLE_FMT_NONE;
    ChannelLayout swrLayout;
    ChannelLayout outLayout;
    std::vector<float> converted;
    std::vector<uint8_t> silence;

    // Placement.
    bool coarse = false;      ///< One time-base tick spans more than one source sample.
    int64_t tickSamples = 1;  ///< Source samples per time-base tick (rounded up).
    bool fixedFrames = false;
    int64_t gridOrigin = 0;   ///< Source sample index of the first codec frame (for snapping).
    int64_t firstIndexTs = AV_NOPTS_VALUE;

    // Pipeline state.
    bool running = false;
    bool demuxEof = false;
    bool finished = false;
    std::optional<MediaError> pendingReadError;
    int64_t nextSrc = AV_NOPTS_VALUE; ///< Source sample expected next, NOPTS right after a (re)start.
    int srcRate = 0;                  ///< Rate the source sample indices refer to.
    int64_t nextOut = 0;              ///< Output index of the next sample the resampler emits.
    std::vector<float> staged;        ///< Output samples starting at stagedStart.
    int64_t stagedStart = 0;
    int64_t position = 0;
    int consecutiveErrors = 0;
    bool codecNeedsReset = false; ///< Recreate the codec context after an error (see FFVideoDecoder).

    // Seek verification.
    bool verifySeek = false;
    int64_t seekSrcTarget = 0;
    int64_t seekTs = 0;
    int retries = 0;
    bool fromStart = false;

    int64_t stagedFrames() const { return static_cast<int64_t>(staged.size()) / outChannels; }

    int codecRate() const { return codec->sample_rate > 0 ? codec->sample_rate : stream->codecpar->sample_rate; }

    int64_t minPreroll() const {
        const int frameSize = codec->frame_size > 0 ? codec->frame_size : 1024;
        return std::max<int64_t>(frameSize, 1024) + (coarse ? tickSamples : 0);
    }

    // MARK: Resampler

    Status configureResampler(const AVFrame *f) {
        ChannelLayout inLayout;
        int rc = inLayout.copyFrom(f->ch_layout);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::Internal, "av_channel_layout_copy");
        }
        const auto format = static_cast<AVSampleFormat>(f->format);
        if (swr && swrRate == f->sample_rate && swrFormat == format &&
            av_channel_layout_compare(&swrLayout.layout, &inLayout.layout) == 0) {
            return okStatus();
        }
        if (swr) {
            VE_MEDIA_TRY(drainResampler()); // Format change mid-stream: emit what is buffered.
        }
        SwrContext *raw = nullptr;
        rc = swr_alloc_set_opts2(&raw, &outLayout.layout, AV_SAMPLE_FMT_FLT, static_cast<int>(rate),
                                 &inLayout.layout, format, f->sample_rate, 0, nullptr);
        swr.reset(raw);
        if (rc < 0 || !swr) {
            return ffError(rc < 0 ? rc : AVERROR(ENOMEM), MediaErrorCode::Internal, "swr_alloc_set_opts2");
        }
        rc = swr_init(swr.get());
        if (rc < 0) {
            swr.reset();
            return ffError(rc, MediaErrorCode::UnsupportedFormat, "swr_init");
        }
        swrRate = f->sample_rate;
        swrFormat = format;
        rc = swrLayout.copyFrom(inLayout.layout);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::Internal, "av_channel_layout_copy");
        }
        return okStatus();
    }

    void resetResampler() {
        if (swr) {
            swr_close(swr.get());
            if (swr_init(swr.get()) < 0) {
                swr.reset(); // Re-created from the next frame.
            }
        }
    }

    /// Converts `count` input frames (planes in `in`) and appends the output at nextOut.
    Status convert(const uint8_t *const *in, int count) {
        const int capacity = swr_get_out_samples(swr.get(), count);
        if (capacity < 0) {
            return ffError(capacity, MediaErrorCode::Internal, "swr_get_out_samples");
        }
        converted.resize(static_cast<size_t>(std::max(capacity, 1)) * static_cast<size_t>(outChannels));
        uint8_t *out = reinterpret_cast<uint8_t *>(converted.data());
        const int produced = swr_convert(swr.get(), &out, capacity, in, count);
        if (produced < 0) {
            return ffError(produced, MediaErrorCode::DecodeFailed, "swr_convert");
        }
        append(converted.data(), produced);
        return okStatus();
    }

    Status drainResampler() {
        if (!swr) {
            return okStatus();
        }
        while (true) {
            const int capacity = std::max(swr_get_out_samples(swr.get(), 0), 0) + 16;
            converted.resize(static_cast<size_t>(capacity) * static_cast<size_t>(outChannels));
            uint8_t *out = reinterpret_cast<uint8_t *>(converted.data());
            const int produced = swr_convert(swr.get(), &out, capacity, nullptr, 0);
            if (produced < 0) {
                return ffError(produced, MediaErrorCode::DecodeFailed, "swr_convert(flush)");
            }
            if (produced == 0) {
                return okStatus();
            }
            append(converted.data(), produced);
        }
    }

    void append(const float *samples, int count) {
        if (count <= 0) {
            return;
        }
        if (staged.empty()) {
            stagedStart = nextOut;
        }
        staged.insert(staged.end(), samples, samples + static_cast<ptrdiff_t>(count) * outChannels);
        nextOut += count;
        trimConsumed();
    }

    /// Drops staged samples before the read position (keeps memory bounded during pre-roll).
    void trimConsumed() {
        const int64_t consumed = std::clamp<int64_t>(position - stagedStart, 0, stagedFrames());
        if (consumed > 0) {
            staged.erase(staged.begin(), staged.begin() + static_cast<ptrdiff_t>(consumed * outChannels));
            stagedStart += consumed;
        }
    }

    /// Feeds `count` frames of silence in the resampler's input format.
    Status feedSilence(int64_t count) {
        const int channels = swrLayout.layout.nb_channels;
        const bool planar = av_sample_fmt_is_planar(swrFormat);
        const int size = av_samples_get_buffer_size(nullptr, channels, kSilenceChunk, swrFormat, 1);
        if (size < 0) {
            return ffError(size, MediaErrorCode::Internal, "av_samples_get_buffer_size");
        }
        silence.resize(static_cast<size_t>(size));
        std::vector<uint8_t *> extended(static_cast<size_t>(planar ? channels : 1));
        const int filled = av_samples_fill_arrays(extended.data(), nullptr, silence.data(), channels, kSilenceChunk,
                                                  swrFormat, 1);
        if (filled < 0) {
            return ffError(filled, MediaErrorCode::Internal, "av_samples_fill_arrays");
        }
        av_samples_set_silence(extended.data(), 0, kSilenceChunk, channels, swrFormat);
        while (count > 0) {
            const int n = static_cast<int>(std::min<int64_t>(count, kSilenceChunk));
            VE_MEDIA_TRY(convert(extended.data(), n));
            count -= n;
        }
        return okStatus();
    }

    // MARK: Placement

    /// Places one decoded frame. Returns true if the seek had to be retried (frame dropped).
    Result<bool> place(AVFrame *f) {
        if (f->nb_samples <= 0) {
            return false;
        }
        VE_MEDIA_TRY(configureResampler(f));
        const int rateNow = f->sample_rate;
        if (srcRate != rateNow && nextSrc != AV_NOPTS_VALUE) {
            // Rate change: keep the output contiguous, re-derive source indices from here.
            nextSrc = av_rescale(nextSrc, rateNow, srcRate);
        }
        srcRate = rateNow;

        int64_t ts = f->best_effort_timestamp != AV_NOPTS_VALUE ? f->best_effort_timestamp : f->pts;
        int64_t src = nextSrc;
        if (ts != AV_NOPTS_VALUE) {
            src = av_rescale_q_rnd(ts - shift, stream->time_base, AVRational{1, rateNow}, AV_ROUND_NEAR_INF);
            if (coarse && fixedFrames && codec->frame_size > 0) {
                const int64_t fs = codec->frame_size;
                src = gridOrigin + static_cast<int64_t>(std::llround(static_cast<double>(src - gridOrigin) /
                                                                     static_cast<double>(fs))) *
                                       fs;
            }
        }
        if (src == AV_NOPTS_VALUE) {
            src = 0;
        }

        int skip = 0;
        if (nextSrc == AV_NOPTS_VALUE) {
            // First frame after a (re)start.
            if (verifySeek) {
                verifySeek = false;
                if (!fromStart && src > seekSrcTarget - minPreroll()) {
                    VE_MEDIA_TRY(retrySeek());
                    return true;
                }
            }
            // Align so that the output index src * outRate / srcRate is an integer.
            const int64_t outRate = static_cast<int64_t>(rate);
            const int64_t step = rateNow / std::gcd<int64_t>(rateNow, outRate);
            const int64_t align = floorMod(step - floorMod(src, step), step);
            if (align >= f->nb_samples) {
                return false; // The next frame starts the stream.
            }
            skip = static_cast<int>(align);
            src += align;
            nextOut = src * outRate / rateNow;
            staged.clear();
            stagedStart = nextOut;
        } else {
            const int64_t diff = src - nextSrc;
            const int64_t tolerance = coarse ? tickSamples / 2 + 1 : 1;
            if (std::llabs(diff) <= tolerance) {
                src = nextSrc; // Timestamp rounding, not a discontinuity.
            } else if (diff > 0) {
                VE_MEDIA_TRY(feedSilence(diff));
            } else {
                if (-diff >= f->nb_samples) {
                    return false; // Entirely overlapping data.
                }
                skip = static_cast<int>(-diff);
                src = nextSrc;
            }
        }

        const int count = f->nb_samples - skip;
        const int channels = f->ch_layout.nb_channels;
        const auto format = static_cast<AVSampleFormat>(f->format);
        const int bytes = av_get_bytes_per_sample(format);
        std::vector<const uint8_t *> in;
        if (av_sample_fmt_is_planar(format)) {
            in.resize(static_cast<size_t>(channels));
            for (int c = 0; c < channels; ++c) {
                in[static_cast<size_t>(c)] = f->extended_data[c] + static_cast<ptrdiff_t>(skip) * bytes;
            }
        } else {
            in.push_back(f->extended_data[0] + static_cast<ptrdiff_t>(skip) * bytes * channels);
        }
        VE_MEDIA_TRY(convert(in.data(), count));
        nextSrc = src + count;
        return false;
    }

    // MARK: Demux positioning

    Status reopenInput() {
        auto reopened = openInput(path);
        if (!reopened.ok()) {
            return std::move(reopened).error();
        }
        if (static_cast<unsigned>(streamIndex) >= reopened.value()->nb_streams) {
            return makeError(MediaErrorCode::CorruptData, "stream disappeared on reopen");
        }
        input = std::move(reopened).value();
        stream = input->streams[streamIndex];
        for (unsigned i = 0; i < input->nb_streams; ++i) {
            input->streams[i]->discard = static_cast<int>(i) == streamIndex ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
        }
        return okStatus();
    }

    Status rewind() {
        fromStart = true;
        const int64_t first = firstIndexTs != AV_NOPTS_VALUE ? firstIndexTs
                              : stream->start_time != AV_NOPTS_VALUE ? stream->start_time
                                                                      : 0;
        if (av_seek_frame(input.get(), streamIndex, first, AVSEEK_FLAG_BACKWARD) >= 0) {
            return okStatus();
        }
        return reopenInput();
    }

    void resetPipeline() {
        avcodec_flush_buffers(codec.get());
        resetResampler();
        demuxEof = false;
        finished = false;
        pendingReadError.reset();
        nextSrc = AV_NOPTS_VALUE;
        staged.clear();
        consecutiveErrors = 0;
    }

    Status demuxSeek() {
        const int64_t firstUseful = firstIndexTs != AV_NOPTS_VALUE ? firstIndexTs : stream->start_time;
        if (firstUseful != AV_NOPTS_VALUE && seekTs <= firstUseful) {
            return rewind();
        }
        int rc = avformat_seek_file(input.get(), streamIndex, INT64_MIN, seekTs, seekTs, 0);
        if (rc < 0) {
            rc = av_seek_frame(input.get(), streamIndex, seekTs, AVSEEK_FLAG_BACKWARD);
        }
        if (rc < 0) {
            return rewind();
        }
        return okStatus();
    }

    Status retrySeek() {
        resetPipeline();
        verifySeek = true;
        if (++retries > kMaxSeekRetries) {
            return rewind();
        }
        const int64_t back =
            av_rescale_q(static_cast<int64_t>(1) << (retries - 1), AVRational{1, 2}, stream->time_base);
        seekTs -= std::max<int64_t>(back, 1);
        return demuxSeek();
    }

    /// Positions the pipeline so that decoding reaches output sample `target` with pre-roll.
    Status openCodec() {
        const AVCodecParameters *par = stream->codecpar;
        const AVCodec *decoder = avcodec_find_decoder(par->codec_id);
        if (decoder == nullptr) {
            return makeError(MediaErrorCode::UnsupportedCodec,
                             std::string("no decoder for ") + avcodec_get_name(par->codec_id) + " in this build");
        }
        codec.reset(avcodec_alloc_context3(decoder));
        if (!codec) {
            return makeError(MediaErrorCode::Internal, "avcodec_alloc_context3 failed");
        }
        int rc = avcodec_parameters_to_context(codec.get(), par);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::Internal, "avcodec_parameters_to_context");
        }
        codec->pkt_timebase = stream->time_base;
        codec->thread_count = 1;
        rc = avcodec_open2(codec.get(), decoder, nullptr);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::UnsupportedCodec, "avcodec_open2");
        }
        return okStatus();
    }

    Status restart(int64_t target) {
        if (codecNeedsReset) {
            VE_MEDIA_TRY(openCodec());
            codecNeedsReset = false;
        }
        resetPipeline();
        const int rateNow = codecRate();
        srcRate = rateNow;
        const int64_t srcTarget = av_rescale(target, rateNow, static_cast<int64_t>(rate));
        const int64_t preroll = std::max<int64_t>(static_cast<int64_t>(kPrerollSeconds * rateNow),
                                                  stream->codecpar->seek_preroll + minPreroll());
        seekSrcTarget = srcTarget;
        seekTs = av_rescale_q(srcTarget - preroll, AVRational{1, rateNow}, stream->time_base) + shift;
        retries = 0;
        fromStart = false;
        verifySeek = true;
        running = true;
        Status s = demuxSeek();
        if (!s.ok()) {
            running = false;
        }
        return s;
    }

    // MARK: Decoding

    Status feed() {
        AVPacket *pkt = packet.get();
        while (true) {
            const int rc = av_read_frame(input.get(), pkt);
            if (rc < 0) {
                if (rc != AVERROR_EOF) {
                    pendingReadError = ffError(rc, MediaErrorCode::CorruptData, "av_read_frame");
                }
                demuxEof = true;
                const int drain = avcodec_send_packet(codec.get(), nullptr);
                if (drain < 0 && drain != AVERROR_EOF) {
                    return ffError(drain, MediaErrorCode::DecodeFailed, "avcodec_send_packet(flush)");
                }
                return okStatus();
            }
            if (pkt->stream_index != streamIndex) {
                av_packet_unref(pkt);
                continue;
            }
            const int sent = avcodec_send_packet(codec.get(), pkt);
            av_packet_unref(pkt);
            if (sent == AVERROR_INVALIDDATA) {
                if (++consecutiveErrors > kMaxConsecutiveErrors) {
                    return ffError(sent, MediaErrorCode::CorruptData, "avcodec_send_packet");
                }
                continue;
            }
            if (sent < 0 && sent != AVERROR(EAGAIN)) {
                return ffError(sent, MediaErrorCode::DecodeFailed, "avcodec_send_packet");
            }
            return okStatus();
        }
    }

    /// Decodes until at least one more output sample is staged or the stream ends.
    Status pump() {
        AVFrame *f = frame.get();
        const int64_t before = nextOut;
        const size_t stagedBefore = staged.size();
        while (!finished) {
            const int rc = avcodec_receive_frame(codec.get(), f);
            if (rc == 0) {
                consecutiveErrors = 0;
                auto placed = place(f);
                av_frame_unref(f);
                if (!placed.ok()) {
                    return std::move(placed).error();
                }
                if (nextOut != before || staged.size() != stagedBefore) {
                    return okStatus();
                }
                continue;
            }
            if (rc == AVERROR(EAGAIN)) {
                if (demuxEof) {
                    return makeError(MediaErrorCode::Internal, "decoder wants input after end of stream");
                }
                VE_MEDIA_TRY(feed());
                continue;
            }
            if (rc == AVERROR_EOF) {
                VE_MEDIA_TRY(drainResampler());
                finished = true;
                if (pendingReadError) {
                    MediaError e = std::move(*pendingReadError);
                    pendingReadError.reset();
                    return e;
                }
                return okStatus();
            }
            if (rc == AVERROR_INVALIDDATA && ++consecutiveErrors <= kMaxConsecutiveErrors) {
                continue;
            }
            return ffError(rc, MediaErrorCode::DecodeFailed, "avcodec_receive_frame");
        }
        return okStatus();
    }
};

FFAudioDecoder::FFAudioDecoder() : impl_(std::make_unique<Impl>()) {}

FFAudioDecoder::~FFAudioDecoder() = default;

Status FFAudioDecoder::open(const std::string &path, int trackIndex, const AudioOptions &options) {
    Impl &d = *impl_;
    if (d.opened) {
        return makeError(MediaErrorCode::InvalidState, "open() called twice");
    }
    if (!(options.sampleRate >= 8000 && options.sampleRate <= 384000) ||
        std::floor(options.sampleRate) != options.sampleRate) {
        return makeError(MediaErrorCode::InvalidArgument, "sample rate must be an integer in 8000...384000");
    }
    if (options.channels < 1 || options.channels > 8) {
        return makeError(MediaErrorCode::InvalidArgument, "channels must be 1...8");
    }
    d.path = path;
    auto input = openInput(path);
    if (!input.ok()) {
        return std::move(input).error();
    }
    d.input = std::move(input).value();
    AVFormatContext *ctx = d.input.get();
    if (isImageDemuxer(ctx) || isHeifFamily(ctx)) {
        return makeError(MediaErrorCode::NoSuchTrack, "images have no audio track");
    }
    if (trackIndex < 0) {
        for (unsigned i = 0; i < ctx->nb_streams; ++i) {
            if (ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
                d.streamIndex = static_cast<int>(i);
                break;
            }
        }
        if (d.streamIndex < 0) {
            return makeError(MediaErrorCode::NoSuchTrack, "no audio track in " + path);
        }
    } else {
        if (static_cast<unsigned>(trackIndex) >= ctx->nb_streams) {
            return makeError(MediaErrorCode::NoSuchTrack,
                             "track index " + std::to_string(trackIndex) + " out of range");
        }
        if (ctx->streams[trackIndex]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
            return makeError(MediaErrorCode::NoSuchTrack, "track " + std::to_string(trackIndex) +
                                                              " is not an audio track");
        }
        d.streamIndex = trackIndex;
    }
    d.stream = ctx->streams[d.streamIndex];
    for (unsigned i = 0; i < ctx->nb_streams; ++i) {
        ctx->streams[i]->discard = static_cast<int>(i) == d.streamIndex ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
    }
    const AVCodecParameters *par = d.stream->codecpar;
    if (!canDecode(par->codec_id) || par->sample_rate <= 0) {
        return makeError(MediaErrorCode::UnsupportedCodec,
                         std::string("no decoder for ") + avcodec_get_name(par->codec_id) + " in this build");
    }
    VE_MEDIA_TRY(d.openCodec());

    d.rate = options.sampleRate;
    d.timescale = static_cast<int32_t>(options.sampleRate);
    d.outChannels = options.channels;
    av_channel_layout_default(&d.outLayout.layout, options.channels);

    const TrackInfo info = describeStream(ctx, d.stream);
    d.shift = audioTimelineShift(ctx, d.stream);
    if (CMTIME_IS_NUMERIC(info.duration)) {
        const CMTime end = CMTimeAdd(info.startTime, info.duration);
        d.length = CMTimeConvertScale(end, d.timescale, kCMTimeRoundingMethod_RoundHalfAwayFromZero).value;
        // Exact when it comes from iTunSMPB or an ISO-BMFF track duration (edit list or media
        // duration): output is capped there, which also drops the encoder's end padding that
        // libavformat does not trim.
        d.lengthExact = d.shift != 0 || (isQuickTimeFamily(ctx) && d.stream->duration != AV_NOPTS_VALUE);
    }

    const int srcRate = par->sample_rate;
    const double samplesPerTick = av_q2d(d.stream->time_base) * srcRate;
    d.coarse = samplesPerTick > 1.5;
    d.tickSamples = static_cast<int64_t>(std::ceil(samplesPerTick));
    d.fixedFrames = hasFixedFrameSize(par->codec_id);
    if (par->initial_padding > 0) {
        d.gridOrigin = -par->initial_padding;
    } else if (d.stream->start_time != AV_NOPTS_VALUE) {
        d.gridOrigin = av_rescale_q(d.stream->start_time - d.shift, d.stream->time_base, AVRational{1, srcRate});
    }
    if (avformat_index_get_entries_count(d.stream) > 0) {
        d.firstIndexTs = avformat_index_get_entry(d.stream, 0)->timestamp;
    }

    auto packet = allocPacket();
    if (!packet.ok()) {
        return std::move(packet).error();
    }
    auto frame = allocFrame();
    if (!frame.ok()) {
        return std::move(frame).error();
    }
    d.packet = std::move(packet).value();
    d.frame = std::move(frame).value();

    // A freshly opened demuxer is at the start of the stream.
    d.srcRate = srcRate;
    d.position = 0;
    d.running = true;
    d.fromStart = true;
    d.opened = true;
    return okStatus();
}

Status FFAudioDecoder::seek(CMTime t) {
    Impl &d = *impl_;
    if (!d.opened) {
        return makeError(MediaErrorCode::InvalidState, "seek() before open()");
    }
    if (!CMTIME_IS_NUMERIC(t)) {
        return makeError(MediaErrorCode::InvalidArgument, "seek() needs a numeric time");
    }
    const int64_t target =
        std::max<int64_t>(0, CMTimeConvertScale(t, d.timescale, kCMTimeRoundingMethod_RoundTowardNegativeInfinity)
                                 .value);
    // Close ahead of what is decoded (or staged): decode through.
    const int64_t decodedFrom = d.staged.empty() ? d.nextOut : d.stagedStart;
    if (d.running && target >= d.position && target >= decodedFrom &&
        target - d.position <= static_cast<int64_t>(kSkipAheadSeconds * d.rate) && d.nextSrc != AV_NOPTS_VALUE) {
        d.position = target;
        d.trimConsumed();
        return okStatus();
    }
    d.position = target;
    Status s = d.restart(target);
    if (!s.ok()) {
        d.running = false;
    }
    return s;
}

Result<int> FFAudioDecoder::read(float *interleaved, int frames) {
    Impl &d = *impl_;
    if (!d.opened) {
        return makeError(MediaErrorCode::InvalidState, "read() before open()");
    }
    if (frames < 0 || (frames > 0 && interleaved == nullptr)) {
        return makeError(MediaErrorCode::InvalidArgument, "read() needs a buffer");
    }
    if (!d.running) {
        VE_MEDIA_TRY(d.restart(d.position));
    }
    const int ch = d.outChannels;
    int produced = 0;
    while (produced < frames) {
        if (d.lengthExact && d.position >= d.length) {
            break;
        }
        int64_t want = frames - produced;
        if (d.lengthExact) {
            want = std::min<int64_t>(want, d.length - d.position);
        }
        const int64_t stagedEnd = d.stagedStart + d.stagedFrames();
        if (d.stagedFrames() > 0 && d.position < stagedEnd) {
            if (d.position < d.stagedStart) {
                const int64_t n = std::min<int64_t>(d.stagedStart - d.position, want);
                std::fill_n(interleaved + static_cast<ptrdiff_t>(produced) * ch, n * ch, 0.0f);
                produced += static_cast<int>(n);
                d.position += n;
                continue;
            }
            const int64_t offset = d.position - d.stagedStart;
            const int64_t n = std::min<int64_t>(stagedEnd - d.position, want);
            std::memcpy(interleaved + static_cast<ptrdiff_t>(produced) * ch, d.staged.data() + offset * ch,
                        static_cast<size_t>(n * ch) * sizeof(float));
            produced += static_cast<int>(n);
            d.position += n;
            d.trimConsumed();
            continue;
        }
        if (d.finished) {
            break;
        }
        Status s = d.pump();
        if (!s.ok()) {
            d.running = false; // The next read() re-seeks to the current position ...
            d.codecNeedsReset = true; // ... with a fresh codec context.
            return std::move(s).error();
        }
    }
    return produced;
}

int64_t FFAudioDecoder::position() const {
    return impl_->position;
}

CMTime FFAudioDecoder::positionTime() const {
    return CMTimeMake(impl_->position, impl_->timescale);
}

double FFAudioDecoder::sampleRate() const {
    return impl_->rate;
}

int FFAudioDecoder::channels() const {
    return impl_->outChannels;
}

int64_t FFAudioDecoder::lengthFrames() const {
    return impl_->length;
}

} // namespace ve::media::ffmpeg
