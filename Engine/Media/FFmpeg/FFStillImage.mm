#include "FFStillImage.h"

#include "../CFRef.h"
#include "../ColorTags.h"

#include <CoreGraphics/CoreGraphics.h>

extern "C" {
#include <libavutil/pixdesc.h>
}

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace ve::media::ffmpeg {

namespace {

constexpr ColorInfo kStillColor{ColorPrimaries::BT709, TransferFunction::SRGB, YCbCrMatrix::Unknown, true};

bool swapsAxes(int orientation) {
    return orientation >= 5 && orientation <= 8;
}

int exifOrientation(const AVFrame *frame) {
    const auto value = metadataValue(frame->metadata, "Orientation");
    if (!value) {
        return 1;
    }
    const int o = std::atoi(value->c_str());
    return (o >= 1 && o <= 8) ? o : 1;
}

/// Source pixel (in the stored image of size w x h) shown at display pixel (x, y).
inline void sourceFor(int orientation, int x, int y, int w, int h, int &sx, int &sy) {
    // EXIF: 2 mirrored horizontally, 3 rotated 180, 4 mirrored vertically, 5 transposed,
    // 6 rotated 90 clockwise for display, 7 transversed, 8 rotated 90 counter-clockwise.
    const bool swap = orientation >= 5 && orientation <= 8;
    const int u = swap ? y : x; // Coordinates in the stored image's axes.
    const int v = swap ? x : y;
    const bool flipU = orientation == 2 || orientation == 3 || orientation == 7 || orientation == 8;
    const bool flipV = orientation == 3 || orientation == 4 || orientation == 6 || orientation == 7;
    sx = flipU ? w - 1 - u : u;
    sy = flipV ? h - 1 - v : v;
}

} // namespace

Result<DecodedStill> decodeStill(AVFormatContext *input) {
    int streamIndex = -1;
    for (unsigned i = 0; i < input->nb_streams; ++i) {
        if (input->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            streamIndex = static_cast<int>(i);
            break;
        }
    }
    if (streamIndex < 0) {
        return makeError(MediaErrorCode::UnsupportedFormat, "image contains no picture");
    }
    const AVCodecParameters *par = input->streams[streamIndex]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (codec == nullptr) {
        return makeError(MediaErrorCode::UnsupportedCodec,
                         std::string("no decoder for image codec ") + avcodec_get_name(par->codec_id));
    }
    CodecContextPtr dec(avcodec_alloc_context3(codec));
    if (!dec) {
        return makeError(MediaErrorCode::Internal, "avcodec_alloc_context3 failed");
    }
    int rc = avcodec_parameters_to_context(dec.get(), par);
    if (rc < 0) {
        return ffError(rc, MediaErrorCode::Internal, "avcodec_parameters_to_context");
    }
    dec->thread_count = 1;
    rc = avcodec_open2(dec.get(), codec, nullptr);
    if (rc < 0) {
        return ffError(rc, MediaErrorCode::UnsupportedCodec, "avcodec_open2 (image)");
    }
    auto packet = allocPacket();
    if (!packet.ok()) {
        return std::move(packet).error();
    }
    auto frame = allocFrame();
    if (!frame.ok()) {
        return std::move(frame).error();
    }
    AVPacket *pkt = packet->get();
    AVFrame *out = frame->get();
    bool flushed = false;
    while (true) {
        rc = avcodec_receive_frame(dec.get(), out);
        if (rc == 0) {
            break;
        }
        if (rc == AVERROR_EOF) {
            return makeError(MediaErrorCode::CorruptData, "image decoder produced no picture");
        }
        if (rc != AVERROR(EAGAIN)) {
            return ffError(rc, MediaErrorCode::CorruptData, "avcodec_receive_frame (image)");
        }
        if (flushed) {
            return makeError(MediaErrorCode::CorruptData, "image decoder produced no picture");
        }
        rc = av_read_frame(input, pkt);
        if (rc == AVERROR_EOF) {
            rc = avcodec_send_packet(dec.get(), nullptr);
            flushed = true;
        } else if (rc < 0) {
            return ffError(rc, MediaErrorCode::CorruptData, "av_read_frame (image)");
        } else {
            if (pkt->stream_index == streamIndex) {
                rc = avcodec_send_packet(dec.get(), pkt);
            }
            av_packet_unref(pkt);
        }
        if (rc < 0 && rc != AVERROR(EAGAIN)) {
            return ffError(rc, MediaErrorCode::CorruptData, "avcodec_send_packet (image)");
        }
    }
    DecodedStill still;
    still.orientation = exifOrientation(out);
    still.width = swapsAxes(still.orientation) ? out->height : out->width;
    still.height = swapsAxes(still.orientation) ? out->width : out->height;
    still.codec = fourCCForStream(par);
    still.frame = std::move(frame).value();
    return still;
}

TrackInfo stillTrackInfo(const DecodedStill &still) {
    TrackInfo track;
    track.index = 0;
    track.kind = TrackKind::Still;
    track.codec = {still.codec, codecName(still.codec, codecIdForFourCC(still.codec))};
    track.width = still.width;
    track.height = still.height;
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(static_cast<AVPixelFormat>(still.frame->format));
    track.bitDepth = d ? d->comp[0].depth : 8;
    track.color = kStillColor;
    track.duration = kCMTimeIndefinite;
    return track;
}

Result<PixelBuffer> renderStill(const DecodedStill &still, int maxDimension) {
    const AVFrame *frame = still.frame.get();
    int dispWidth = still.width;
    int dispHeight = still.height;
    fitDimensions(maxDimension, dispWidth, dispHeight);
    const bool swap = swapsAxes(still.orientation);
    const int scaledWidth = swap ? dispHeight : dispWidth; // Stored-orientation size after scaling.
    const int scaledHeight = swap ? dispWidth : dispHeight;

    const auto srcFormat = static_cast<AVPixelFormat>(frame->format);
    const bool scaling = scaledWidth != frame->width || scaledHeight != frame->height;
    SwsPtr sws(sws_getContext(frame->width, frame->height, srcFormat, scaledWidth, scaledHeight, AV_PIX_FMT_BGRA,
                              (scaling ? SWS_BICUBIC : SWS_POINT) | SWS_ACCURATE_RND | SWS_FULL_CHR_H_INT |
                                  SWS_FULL_CHR_H_INP,
                              nullptr, nullptr, nullptr));
    if (!sws) {
        return makeError(MediaErrorCode::UnsupportedFormat,
                         std::string("cannot convert image format ") + (av_get_pix_fmt_name(srcFormat) ?: "?"));
    }
    {
        // JPEG (JFIF) is full-range BT.601 unless tagged otherwise.
        const int space = frame->colorspace == AVCOL_SPC_BT709 ? SWS_CS_ITU709 : SWS_CS_ITU601;
        const bool srcFull = frame->color_range != AVCOL_RANGE_MPEG;
        const int *table = sws_getCoefficients(space);
        sws_setColorspaceDetails(sws.get(), table, srcFull ? 1 : 0, table, 1, 0, 1 << 16, 1 << 16);
    }

    auto pool = PixelBufferPool::create(kCVPixelFormatType_32BGRA, static_cast<size_t>(dispWidth),
                                        static_cast<size_t>(dispHeight));
    if (!pool.ok()) {
        return std::move(pool).error();
    }
    auto buffer = pool->makeBuffer();
    if (!buffer.ok()) {
        return std::move(buffer).error();
    }
    CVPixelBufferRef pb = buffer->get();
    {
        PixelBufferLock lock(pb, false);
        if (!lock.locked()) {
            return makeError(MediaErrorCode::Internal, "CVPixelBufferLockBaseAddress failed");
        }
        auto *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(pb));
        const size_t stride = CVPixelBufferGetBytesPerRow(pb);

        // Render in stored orientation, straight into the output when no reorientation is needed.
        std::vector<uint8_t> scratch;
        uint8_t *target = base;
        int targetStride = static_cast<int>(stride);
        if (still.orientation != 1) {
            targetStride = scaledWidth * 4;
            scratch.resize(static_cast<size_t>(targetStride) * static_cast<size_t>(scaledHeight));
            target = scratch.data();
        }
        uint8_t *dst[4] = {target, nullptr, nullptr, nullptr};
        int dstStride[4] = {targetStride, 0, 0, 0};
        const int rows = sws_scale(sws.get(), frame->data, frame->linesize, 0, frame->height, dst, dstStride);
        if (rows < 0) {
            return ffError(rows, MediaErrorCode::Internal, "sws_scale (image)");
        }
        if (still.orientation != 1) {
            for (int y = 0; y < dispHeight; ++y) {
                auto *row = reinterpret_cast<uint32_t *>(base + static_cast<size_t>(y) * stride);
                for (int x = 0; x < dispWidth; ++x) {
                    int sx = 0;
                    int sy = 0;
                    sourceFor(still.orientation, x, y, scaledWidth, scaledHeight, sx, sy);
                    std::memcpy(&row[x], scratch.data() + static_cast<size_t>(sy) * static_cast<size_t>(targetStride) +
                                             static_cast<size_t>(sx) * 4,
                                4);
                }
            }
        }
        // Premultiply alpha (CoreGraphics/ImageIO convention) when the source has alpha.
        const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(srcFormat);
        if (d != nullptr && (d->flags & (AV_PIX_FMT_FLAG_ALPHA | AV_PIX_FMT_FLAG_PAL))) {
            for (int y = 0; y < dispHeight; ++y) {
                uint8_t *p = base + static_cast<size_t>(y) * stride;
                for (int x = 0; x < dispWidth; ++x, p += 4) {
                    const unsigned a = p[3];
                    if (a != 255) {
                        p[0] = static_cast<uint8_t>((p[0] * a + 127) / 255);
                        p[1] = static_cast<uint8_t>((p[1] * a + 127) / 255);
                        p[2] = static_cast<uint8_t>((p[2] * a + 127) / 255);
                    }
                }
            }
        }
    }
    // Same tags as ImageIO-decoded stills: sRGB ICC profile plus the CoreVideo colour keys.
    CFRef<CGColorSpaceRef> srgb = CFRef<CGColorSpaceRef>::adopt(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    CFRef<CFDataRef> icc = CFRef<CFDataRef>::adopt(srgb ? CGColorSpaceCopyICCData(srgb.get()) : nullptr);
    if (icc) {
        CVBufferSetAttachment(pb, kCVImageBufferICCProfileKey, icc.get(), kCVAttachmentMode_ShouldPropagate);
    }
    attachColorInfo(pb, kStillColor);
    return std::move(buffer).value();
}

} // namespace ve::media::ffmpeg
