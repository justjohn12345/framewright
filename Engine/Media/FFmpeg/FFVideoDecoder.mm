#include "FFVideoDecoder.h"

#include "../HardwareCaps.h"
#include "FFFrameConverter.h"
#include "FFProber.h"
#include "FFStillImage.h"
#include "FFmpegSupport.h"

extern "C" {
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
}

#include <algorithm>
#include <cmath>
#include <thread>

namespace ve::media::ffmpeg {

namespace {

bool timeLess(CMTime a, CMTime b) {
    return CMTimeCompare(a, b) < 0;
}

bool decoderSupportsVideoToolbox(const AVCodec *codec) {
    for (int i = 0;; ++i) {
        const AVCodecHWConfig *config = avcodec_get_hw_config(codec, i);
        if (config == nullptr) {
            return false;
        }
        if (config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX &&
            (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
            return true;
        }
    }
}

/// Converts a still to another pixel format on the GPU.
Result<PixelBuffer> transferStill(const PixelBuffer &source, OSType format) {
    CFRef<VTPixelTransferSessionRef> session;
    OSStatus st = VTPixelTransferSessionCreate(kCFAllocatorDefault, session.outPtr());
    if (st != noErr) {
        return makeError(MediaErrorCode::Internal, "VTPixelTransferSessionCreate failed", "OSStatus", st);
    }
    auto pool = PixelBufferPool::create(format, source.width(), source.height());
    if (!pool.ok()) {
        return std::move(pool).error();
    }
    auto out = pool->makeBuffer();
    if (!out.ok()) {
        return std::move(out).error();
    }
    st = VTPixelTransferSessionTransferImage(session.get(), source.get(), out->get());
    VTPixelTransferSessionInvalidate(session.get());
    if (st != noErr) {
        return makeError(MediaErrorCode::UnsupportedFormat, "VTPixelTransferSessionTransferImage failed", "OSStatus",
                         st);
    }
    return std::move(out).value();
}

/// Consecutive undecodable packets tolerated (the decoder conceals isolated damage) before
/// next() reports CorruptData.
constexpr int kMaxConsecutiveErrors = 16;
/// Seek retries further back before falling back to the start of the stream.
constexpr int kMaxSeekRetries = 5;

} // namespace

struct FFVideoDecoder::Impl {
    enum class Mode { Idle, Decoding };

    bool opened = false;
    DecodeOptions options;
    std::string path;

    FormatInputPtr input;
    AVStream *stream = nullptr;
    int streamIndex = -1;
    CodecContextPtr codec;
    BufferRefPtr hwDevice;
    bool hardwareRequested = false;
    PacketPtr packet;
    FramePtr frame;

    TrackInfo info;
    OSType outFormat = 0;
    FrameConverter converter;
    CMTime frameDuration = kCMTimeInvalid;
    CMTime fallbackDuration = CMTimeMake(1, 30);
    CMTime trackStart = kCMTimeZero;
    CMTime trackEnd = kCMTimeZero;
    bool snapToGrid = false;
    bool expectHardware = false;
    bool lastHardware = false;
    bool randomAccess = false;

    // Still.
    bool isStill = false;
    PixelBuffer still;
    bool stillPending = false;

    // Position.
    Mode mode = Mode::Idle;
    bool demuxEof = false;
    std::optional<MediaError> pendingReadError;
    bool awaitingKeyframe = true;
    CMTime gate = kCMTimeInvalid;   ///< Frames presented before this (the seek keyframe) are dropped.
    CMTime target = kCMTimeInvalid; ///< Frames ending at or before this are dropped.
    CMTime position = kCMTimeZero;  ///< End of the last delivered frame (or the seek target).
    std::optional<VideoFrame> last;
    bool repeatLast = false;
    bool eos = false;
    int consecutiveErrors = 0;
    int64_t lastPts = AV_NOPTS_VALUE;
    /// Set after a decode error: the codec context is recreated before the next decode, because
    /// avcodec_flush_buffers does not reliably clear a decoder (e.g. hwaccel HEVC) after one.
    bool codecNeedsReset = false;

    // Seek verification.
    bool verifySeek = false;
    int64_t seekTs = 0; ///< Stream time base.
    int seekRetries = 0;
    bool seekedFromStart = false;
    int demuxerSeeks = 0;

    ~Impl() {
        // The codec context references the device; free it first.
        codec.reset();
        hwDevice.reset();
    }

    static AVPixelFormat getFormat(AVCodecContext *ctx, const AVPixelFormat *formats) {
        const auto *self = static_cast<const Impl *>(ctx->opaque);
        if (self != nullptr && self->hardwareRequested) {
            for (const AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; ++p) {
                if (*p == AV_PIX_FMT_VIDEOTOOLBOX) {
                    return *p;
                }
            }
        }
        for (const AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; ++p) {
            const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(*p);
            if (d != nullptr && !(d->flags & AV_PIX_FMT_FLAG_HWACCEL)) {
                return *p;
            }
        }
        return AV_PIX_FMT_NONE;
    }

    // MARK: Time mapping

    CMTime mapTime(int64_t ts) const {
        const CMTime raw = toCMTime(ts, stream->time_base);
        if (!snapToGrid || !CMTIME_IS_NUMERIC(raw)) {
            return raw;
        }
        const double offset = CMTimeGetSeconds(CMTimeSubtract(raw, trackStart));
        const double fd = CMTimeGetSeconds(frameDuration);
        const auto n = static_cast<int64_t>(std::llround(offset / fd));
        const CMTime snapped = CMTimeAdd(trackStart, CMTimeMultiply(frameDuration, static_cast<int32_t>(n)));
        const double tolerance = av_q2d(stream->time_base) / 2 + 1e-9;
        if (std::fabs(CMTimeGetSeconds(CMTimeSubtract(snapped, raw))) <= tolerance) {
            return snapped;
        }
        return raw;
    }

    int64_t toStreamTs(CMTime t) const {
        return fromCMTime(t, stream->time_base, snapToGrid ? AV_ROUND_NEAR_INF : AV_ROUND_DOWN);
    }

    ColorInfo frameColor(const AVFrame *f) const {
        ColorInfo c = info.color;
        if (f->color_primaries != AVCOL_PRI_UNSPECIFIED) {
            c.primaries = colorPrimaries(f->color_primaries);
        }
        if (f->color_trc != AVCOL_TRC_UNSPECIFIED) {
            c.transfer = transferFunction(f->color_trc);
        }
        if (f->colorspace != AVCOL_SPC_UNSPECIFIED) {
            c.matrix = yCbCrMatrix(f->colorspace);
        }
        if (f->color_range != AVCOL_RANGE_UNSPECIFIED) {
            c.fullRange = f->color_range == AVCOL_RANGE_JPEG;
        }
        return c;
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
        discardOtherStreams();
        return okStatus();
    }

    /// Only our stream's packets are needed; the demuxer skips the rest cheaply.
    void discardOtherStreams() {
        for (unsigned i = 0; i < input->nb_streams; ++i) {
            input->streams[i]->discard = static_cast<int>(i) == streamIndex ? AVDISCARD_DEFAULT : AVDISCARD_ALL;
        }
    }

    /// Seeks the demuxer so that the next packet is the last keyframe at or before `ts`.
    Status demuxSeek(int64_t ts) {
        ++demuxerSeeks;
        int rc = avformat_seek_file(input.get(), streamIndex, INT64_MIN, ts, ts, 0);
        if (rc < 0) {
            rc = av_seek_frame(input.get(), streamIndex, ts, AVSEEK_FLAG_BACKWARD);
        }
        if (rc < 0) {
            // Seeking before the first index entry fails on some demuxers: start over.
            return rewind();
        }
        return okStatus();
    }

    Status rewind() {
        seekedFromStart = true;
        int64_t first = stream->start_time != AV_NOPTS_VALUE ? stream->start_time : 0;
        if (avformat_index_get_entries_count(stream) > 0) {
            first = std::min(first, avformat_index_get_entry(stream, 0)->timestamp);
        }
        if (av_seek_frame(input.get(), streamIndex, first, AVSEEK_FLAG_BACKWARD) >= 0) {
            return okStatus();
        }
        return reopenInput();
    }

    void resetDecoder() {
        avcodec_flush_buffers(codec.get());
        demuxEof = false;
        pendingReadError.reset();
        awaitingKeyframe = true;
        gate = kCMTimeInvalid;
        consecutiveErrors = 0;
        lastPts = AV_NOPTS_VALUE;
    }

    Status startAt(CMTime t) {
        if (codecNeedsReset) {
            codec.reset();
            VE_MEDIA_TRY(openCodec());
            codecNeedsReset = false;
        }
        resetDecoder();
        eos = false;
        seekTs = toStreamTs(t);
        seekRetries = 0;
        seekedFromStart = false;
        verifySeek = true;
        target = t;
        position = t;
        mode = Mode::Decoding;
        Status s = demuxSeek(seekTs);
        if (!s.ok()) {
            mode = Mode::Idle;
        }
        return s;
    }

    /// Called with the first keyframe packet after a seek. Returns true if the seek landed too
    /// late and was retried (the packet must then be dropped).
    Result<bool> retrySeekIfPastTarget(const AVPacket *pkt) {
        verifySeek = false;
        const int64_t keyTs = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
        if (seekedFromStart || keyTs == AV_NOPTS_VALUE || !CMTIME_IS_VALID(target) ||
            CMTimeCompare(mapTime(keyTs), target) <= 0) {
            return false;
        }
        // The keyframe is presented after the target: go further back.
        resetDecoder();
        verifySeek = true;
        if (++seekRetries > kMaxSeekRetries) {
            VE_MEDIA_TRY(rewind());
            return true;
        }
        const int64_t back = av_rescale_q(static_cast<int64_t>(1) << (seekRetries - 1), AVRational{1, 2},
                                          stream->time_base); // 0.5 s, 1 s, 2 s, ...
        const int64_t earliest = pkt->dts != AV_NOPTS_VALUE ? std::min(keyTs, pkt->dts) : keyTs;
        seekTs = std::min(seekTs, earliest) - std::max<int64_t>(back, 1);
        VE_MEDIA_TRY(demuxSeek(seekTs));
        return true;
    }

    // MARK: Decoding

    /// Feeds the next packet of our stream to the decoder (or the drain signal at the end).
    Status feed() {
        AVPacket *pkt = packet.get();
        while (true) {
            if (demuxEof) {
                return makeError(MediaErrorCode::Internal, "feed() after end of input");
            }
            const int rc = av_read_frame(input.get(), pkt);
            if (rc < 0) {
                if (rc != AVERROR_EOF) {
                    // Truncated or damaged container: decode what we have, then report it.
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
            if (awaitingKeyframe) {
                if (!(pkt->flags & AV_PKT_FLAG_KEY)) {
                    av_packet_unref(pkt);
                    continue; // Undecodable without the preceding keyframe.
                }
                if (verifySeek) {
                    auto retried = retrySeekIfPastTarget(pkt);
                    if (!retried.ok()) {
                        av_packet_unref(pkt);
                        return std::move(retried).error();
                    }
                    if (retried.value()) {
                        av_packet_unref(pkt);
                        continue;
                    }
                }
                awaitingKeyframe = false;
                const int64_t keyTs = pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts;
                gate = keyTs != AV_NOPTS_VALUE ? mapTime(keyTs) : kCMTimeInvalid;
            }
            const int rc2 = avcodec_send_packet(codec.get(), pkt);
            av_packet_unref(pkt);
            if (rc2 == AVERROR_INVALIDDATA) {
                if (++consecutiveErrors > kMaxConsecutiveErrors) {
                    return ffError(rc2, MediaErrorCode::CorruptData, "avcodec_send_packet");
                }
                continue; // Damaged packet: the decoder conceals, keep going.
            }
            if (rc2 < 0 && rc2 != AVERROR(EAGAIN)) {
                return ffError(rc2, MediaErrorCode::DecodeFailed, "avcodec_send_packet");
            }
            return okStatus();
        }
    }

    /// The next decoded frame in presentation order, nullopt at the end of the track.
    Result<std::optional<VideoFrame>> decode() {
        AVFrame *f = frame.get();
        while (true) {
            const int rc = avcodec_receive_frame(codec.get(), f);
            if (rc == AVERROR(EAGAIN)) {
                VE_MEDIA_TRY(feed());
                continue;
            }
            if (rc == AVERROR_EOF) {
                if (pendingReadError) {
                    MediaError e = std::move(*pendingReadError);
                    pendingReadError.reset();
                    return e;
                }
                return std::optional<VideoFrame>();
            }
            if (rc == AVERROR_INVALIDDATA) {
                if (++consecutiveErrors > kMaxConsecutiveErrors) {
                    return ffError(rc, MediaErrorCode::CorruptData, "avcodec_receive_frame");
                }
                continue;
            }
            if (rc < 0) {
                return ffError(rc, MediaErrorCode::DecodeFailed, "avcodec_receive_frame");
            }
            consecutiveErrors = 0;
            int64_t ts = f->best_effort_timestamp != AV_NOPTS_VALUE ? f->best_effort_timestamp : f->pts;
            if (ts == AV_NOPTS_VALUE) {
                ts = lastPts != AV_NOPTS_VALUE
                         ? lastPts + std::max<int64_t>(1, fromCMTime(fallbackDuration, stream->time_base,
                                                                     AV_ROUND_NEAR_INF))
                         : fromCMTime(trackStart, stream->time_base, AV_ROUND_NEAR_INF);
            }
            lastPts = ts;
            VideoFrame out;
            out.pts = mapTime(ts);
            if (CMTIME_IS_VALID(gate) && timeLess(out.pts, gate)) {
                av_frame_unref(f); // Leading picture of an open GOP: references the previous GOP.
                continue;
            }
            if (CMTimeCompare(out.pts, trackEnd) >= 0) {
                av_frame_unref(f);
                return std::optional<VideoFrame>();
            }
            if (snapToGrid || f->duration <= 0) {
                out.duration = fallbackDuration;
            } else {
                out.duration = toCMTime(f->duration, stream->time_base);
            }
            out.wasHardwareDecoded = f->format == AV_PIX_FMT_VIDEOTOOLBOX;
            auto image = converter.convert(f, frameColor(f));
            av_frame_unref(f);
            if (!image.ok()) {
                return std::move(image).error();
            }
            out.image = std::move(image).value();
            return std::optional<VideoFrame>(std::move(out));
        }
    }

    // MARK: Open

    Status openStill(const DecodeOptions &opts, int trackIndex) {
        if (trackIndex > 0) {
            return makeError(MediaErrorCode::NoSuchTrack, "still images have one track (0)");
        }
        auto decoded = decodeStill(input.get());
        if (!decoded.ok()) {
            return std::move(decoded).error();
        }
        auto image = renderStill(decoded.value(), opts.maxDimension);
        if (!image.ok()) {
            return std::move(image).error();
        }
        PixelBuffer buffer = std::move(image).value();
        if (opts.pixelFormat != 0 && opts.pixelFormat != buffer.pixelFormat()) {
            auto converted = transferStill(buffer, opts.pixelFormat);
            if (!converted.ok()) {
                return std::move(converted).error();
            }
            buffer = std::move(converted).value();
        }
        info = stillTrackInfo(decoded.value());
        isStill = true;
        still = std::move(buffer);
        outFormat = still.pixelFormat();
        stillPending = true;
        input.reset(); // Nothing more to read.
        return okStatus();
    }

    Status selectStream(int trackIndex) {
        if (trackIndex < 0) {
            for (unsigned i = 0; i < input->nb_streams; ++i) {
                const AVStream *s = input->streams[i];
                if (s->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && !(s->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
                    streamIndex = static_cast<int>(i);
                    break;
                }
            }
            if (streamIndex < 0) {
                return makeError(MediaErrorCode::NoSuchTrack, "no video track in " + path);
            }
        } else {
            if (static_cast<unsigned>(trackIndex) >= input->nb_streams) {
                return makeError(MediaErrorCode::NoSuchTrack, "track index " + std::to_string(trackIndex) +
                                                                  " out of range");
            }
            const AVStream *s = input->streams[trackIndex];
            if (s->codecpar->codec_type != AVMEDIA_TYPE_VIDEO || (s->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
                return makeError(MediaErrorCode::NoSuchTrack, "track " + std::to_string(trackIndex) +
                                                                  " is not a video track");
            }
            streamIndex = trackIndex;
        }
        stream = input->streams[streamIndex];
        discardOtherStreams();
        return okStatus();
    }

    Status openCodec() {
        const AVCodecParameters *par = stream->codecpar;
        if (!canDecode(par->codec_id)) {
            return makeError(MediaErrorCode::UnsupportedCodec,
                             std::string("no decoder for ") + avcodec_get_name(par->codec_id) + " in this build");
        }
        const AVCodec *decoder = avcodec_find_decoder(par->codec_id);
        codec.reset(avcodec_alloc_context3(decoder));
        if (!codec) {
            return makeError(MediaErrorCode::Internal, "avcodec_alloc_context3 failed");
        }
        int rc = avcodec_parameters_to_context(codec.get(), par);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::Internal, "avcodec_parameters_to_context");
        }
        codec->pkt_timebase = stream->time_base;
        codec->opaque = this;
        codec->get_format = &Impl::getFormat;

        hardwareRequested = options.allowHardware && HardwareCaps::get().hardwareDecode(info.codec.fourCC) &&
                            decoderSupportsVideoToolbox(decoder);
        if (hardwareRequested) {
            AVBufferRef *device = nullptr;
            rc = av_hwdevice_ctx_create(&device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nullptr, nullptr, 0);
            if (rc < 0) {
                hardwareRequested = false; // No VideoToolbox device: decode in software.
            } else {
                hwDevice.reset(device);
                codec->hw_device_ctx = av_buffer_ref(hwDevice.get());
                if (codec->hw_device_ctx == nullptr) {
                    return makeError(MediaErrorCode::Internal, "av_buffer_ref failed");
                }
            }
        }
        if (hardwareRequested) {
            codec->thread_count = 1;
        } else {
            const unsigned cores = std::max(1u, std::thread::hardware_concurrency());
            codec->thread_count = static_cast<int>(std::min<unsigned>(cores, kMaxSoftwareThreads));
            codec->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;
        }
        rc = avcodec_open2(codec.get(), decoder, nullptr);
        if (rc < 0) {
            return ffError(rc, MediaErrorCode::UnsupportedCodec, "avcodec_open2");
        }
        return okStatus();
    }
};

FFVideoDecoder::FFVideoDecoder() : impl_(std::make_unique<Impl>()) {}

FFVideoDecoder::~FFVideoDecoder() = default;

Status FFVideoDecoder::open(const std::string &path, int trackIndex, const DecodeOptions &options) {
    Impl &d = *impl_;
    if (d.opened) {
        return makeError(MediaErrorCode::InvalidState, "open() called twice");
    }
    if (options.maxDimension < 0) {
        return makeError(MediaErrorCode::InvalidArgument, "maxDimension must be >= 0");
    }
    (void)HardwareCaps::get(); // Registers the supplemental AV1/VP9 decoders before any VT use.
    d.options = options;
    d.path = path;
    auto input = openInput(path);
    if (!input.ok()) {
        return std::move(input).error();
    }
    d.input = std::move(input).value();
    if (isHeifFamily(d.input.get())) {
        d.input.reset();
        return makeError(MediaErrorCode::UnsupportedFormat, "HEIF/AVIF images are not decoded by the FFmpeg backend");
    }
    if (isImageDemuxer(d.input.get())) {
        VE_MEDIA_TRY(d.openStill(options, trackIndex));
        d.opened = true;
        return okStatus();
    }

    VE_MEDIA_TRY(d.selectStream(trackIndex));
    d.info = describeStream(d.input.get(), d.stream);
    VE_MEDIA_TRY(d.openCodec());

    const AVCodecParameters *par = d.stream->codecpar;
    if (options.pixelFormat != 0) {
        if (avPixelFormatForCV(options.pixelFormat) == AV_PIX_FMT_NONE) {
            return makeError(MediaErrorCode::UnsupportedFormat,
                             "unsupported output pixel format " + fourCCToString(options.pixelFormat));
        }
        d.outFormat = options.pixelFormat;
    } else {
        d.outFormat = nativePixelFormat(static_cast<AVPixelFormat>(par->format), d.info.color.fullRange);
    }
    int width = 0;
    int height = 0;
    if (options.maxDimension > 0 && par->width > 0 && par->height > 0) {
        int w = par->width;
        int h = par->height;
        fitDimensions(options.maxDimension, w, h);
        if (w != par->width || h != par->height) {
            width = w;
            height = h;
        }
    }
    VE_MEDIA_TRY(d.converter.configure(d.outFormat, width, height));

    d.frameDuration = d.info.frameDuration;
    if (CMTIME_IS_NUMERIC(d.frameDuration) && CMTimeCompare(d.frameDuration, kCMTimeZero) > 0) {
        d.fallbackDuration = d.frameDuration;
    }
    d.trackStart = d.info.startTime;
    d.trackEnd = CMTimeAdd(d.info.startTime, d.info.duration);
    if (!CMTIME_IS_NUMERIC(d.trackEnd) || CMTimeCompare(d.trackEnd, d.trackStart) <= 0) {
        return makeError(MediaErrorCode::CorruptData, "video track has no duration");
    }
    // Snap to the frame grid only when the time base cannot express the frame duration.
    if (!d.info.isVFR && CMTIME_IS_NUMERIC(d.frameDuration) && d.frameDuration.value > 0) {
        const AVRational tb = d.stream->time_base;
        const int64_t num = d.frameDuration.value * tb.den;
        const int64_t den = static_cast<int64_t>(d.frameDuration.timescale) * tb.num;
        d.snapToGrid = den > 0 && num % den != 0;
    }
    d.randomAccess = d.input->pb != nullptr && (d.input->pb->seekable & AVIO_SEEKABLE_NORMAL) &&
                     !(d.input->iformat->flags & AVFMT_NOTIMESTAMPS);
    d.expectHardware = d.hardwareRequested;
    d.lastHardware = d.expectHardware;

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

    // A freshly opened demuxer is at the start: decode from there without seeking.
    d.mode = Impl::Mode::Decoding;
    d.position = d.trackStart;
    d.target = kCMTimeInvalid;
    d.opened = true;
    return okStatus();
}

Status FFVideoDecoder::seek(CMTime t) {
    Impl &d = *impl_;
    if (!d.opened) {
        return makeError(MediaErrorCode::InvalidState, "seek() before open()");
    }
    if (!CMTIME_IS_NUMERIC(t)) {
        return makeError(MediaErrorCode::InvalidArgument, "seek() needs a numeric time");
    }
    if (d.isStill) {
        d.stillPending = true;
        return okStatus();
    }
    d.repeatLast = false;
    if (timeLess(t, d.trackStart)) {
        t = d.trackStart;
    }
    if (CMTimeCompare(t, d.trackEnd) >= 0) {
        d.eos = true;
        return okStatus();
    }
    d.eos = false;
    if (d.last && d.last->contains(t) && d.mode != Impl::Mode::Idle) {
        // The frame is already in hand and the decoder continues right after it.
        d.repeatLast = true;
        d.target = kCMTimeInvalid;
        return okStatus();
    }
    if (d.mode != Impl::Mode::Idle && CMTimeCompare(t, d.position) >= 0 &&
        CMTimeGetSeconds(CMTimeSubtract(t, d.position)) <= kCloseAheadSeconds) {
        d.target = t;
        d.position = t;
        return okStatus();
    }
    d.last.reset();
    Status s = d.startAt(t);
    if (!s.ok()) {
        d.mode = Impl::Mode::Idle;
        d.target = t;
        d.position = t;
    }
    return s;
}

Result<std::optional<VideoFrame>> FFVideoDecoder::next() {
    Impl &d = *impl_;
    if (!d.opened) {
        return makeError(MediaErrorCode::InvalidState, "next() before open()");
    }
    if (d.isStill) {
        if (!d.stillPending) {
            return std::optional<VideoFrame>();
        }
        d.stillPending = false;
        VideoFrame frame;
        frame.pts = kCMTimeZero;
        frame.duration = kCMTimePositiveInfinity;
        frame.image = d.still;
        frame.wasHardwareDecoded = false;
        d.lastHardware = false;
        return std::optional<VideoFrame>(std::move(frame));
    }
    if (d.eos) {
        return std::optional<VideoFrame>();
    }
    if (d.repeatLast && d.last) {
        d.repeatLast = false;
        return d.last;
    }
    if (d.mode == Impl::Mode::Idle) {
        const CMTime resume = CMTIME_IS_VALID(d.target) ? d.target : d.position;
        VE_MEDIA_TRY(d.startAt(resume));
    }
    while (true) {
        auto r = d.decode();
        if (!r.ok()) {
            d.mode = Impl::Mode::Idle; // The next call re-seeks to where we were ...
            d.codecNeedsReset = true;  // ... with a fresh codec context.
            return std::move(r).error();
        }
        if (!r.value()) {
            d.eos = true;
            return std::optional<VideoFrame>();
        }
        VideoFrame &frame = *r.value();
        if (CMTIME_IS_VALID(d.target) && CMTimeCompare(CMTimeAdd(frame.pts, frame.duration), d.target) <= 0) {
            continue;
        }
        d.target = kCMTimeInvalid;
        d.position = CMTimeAdd(frame.pts, frame.duration);
        d.lastHardware = frame.wasHardwareDecoded;
        d.last = frame;
        return std::move(r).value();
    }
}

CMTime FFVideoDecoder::frameDuration() const {
    return impl_->isStill ? kCMTimeInvalid : impl_->frameDuration;
}

bool FFVideoDecoder::supportsRandomAccess() const {
    return impl_->isStill || impl_->randomAccess;
}

bool FFVideoDecoder::usedHardware() const {
    return impl_->lastHardware;
}

OSType FFVideoDecoder::outputPixelFormat() const {
    return impl_->outFormat;
}

int FFVideoDecoder::demuxerSeekCount() const {
    return impl_->demuxerSeeks;
}

} // namespace ve::media::ffmpeg
