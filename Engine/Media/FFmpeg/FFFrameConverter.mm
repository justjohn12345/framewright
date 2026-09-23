#include "FFFrameConverter.h"

#include "../ColorTags.h"
#include "../Interfaces.h"

extern "C" {
#include <libavutil/hwcontext_videotoolbox.h>
#include <libavutil/pixdesc.h>
}

#include <algorithm>
#include <cstring>
#include <string>

namespace ve::media::ffmpeg {

namespace {

struct Subsampling {
    int log2w = 1;
    int log2h = 1;
};

bool isSubsampling(const AVPixFmtDescriptor *d, int log2w, int log2h) {
    return d->log2_chroma_w == log2w && d->log2_chroma_h == log2h;
}

/// Memory layout of a YCbCr source format the direct plane copy understands.
struct SourceLayout {
    bool supported = false;
    int components = 0;    ///< 1 (gray) or 3.
    bool semiPlanar = false;
    bool swapUV = false;   ///< NV21-style CrCb order.
    int bytes = 1;         ///< Bytes per sample (1 or 2).
    int depth = 8;         ///< Significant bits per sample.
    int shift = 0;         ///< Bits the sample is shifted left inside its storage (6 for P010).
    int log2w = 0;
    int log2h = 0;
};

SourceLayout analyzeSource(AVPixelFormat format) {
    SourceLayout s;
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(format);
    if (d == nullptr ||
        (d->flags & (AV_PIX_FMT_FLAG_BE | AV_PIX_FMT_FLAG_HWACCEL | AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_PAL |
                     AV_PIX_FMT_FLAG_ALPHA | AV_PIX_FMT_FLAG_BITSTREAM | AV_PIX_FMT_FLAG_FLOAT))) {
        return s;
    }
    const AVComponentDescriptor &c0 = d->comp[0];
    s.depth = c0.depth;
    s.shift = c0.shift;
    s.bytes = (c0.depth + c0.shift + 7) / 8;
    if (s.bytes != 1 && s.bytes != 2) {
        return s;
    }
    if (c0.plane != 0 || c0.step != s.bytes || c0.offset != 0) {
        return s;
    }
    if (d->nb_components == 1) {
        s.components = 1;
        s.log2w = 1;
        s.log2h = 1;
        s.supported = true;
        return s;
    }
    if (d->nb_components != 3) {
        return s;
    }
    const AVComponentDescriptor &c1 = d->comp[1];
    const AVComponentDescriptor &c2 = d->comp[2];
    if (c1.depth != c0.depth || c2.depth != c0.depth || c1.shift != c0.shift || c2.shift != c0.shift) {
        return s;
    }
    s.components = 3;
    s.log2w = d->log2_chroma_w;
    s.log2h = d->log2_chroma_h;
    if (c1.plane == 1 && c2.plane == 2 && c1.step == s.bytes && c2.step == s.bytes && c1.offset == 0 &&
        c2.offset == 0) {
        s.supported = true;
    } else if (c1.plane == 1 && c2.plane == 1 && c1.step == 2 * s.bytes && c2.step == 2 * s.bytes) {
        s.semiPlanar = true;
        s.swapUV = c1.offset > c2.offset;
        s.supported = std::min(c1.offset, c2.offset) == 0 && std::max(c1.offset, c2.offset) == s.bytes;
    }
    return s;
}

/// Layout of the biplanar CoreVideo formats the direct copy writes.
struct DestLayout {
    bool supported = false;
    int bytes = 1;
    int log2w = 1;
    int log2h = 1;
};

DestLayout analyzeDest(OSType format) {
    switch (format) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
        return {true, 1, 1, 1};
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
        return {true, 2, 1, 1};
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
        return {true, 2, 1, 0};
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
        return {true, 2, 0, 0};
    default:
        return {};
    }
}

bool canCopyDirectly(const SourceLayout &s, const DestLayout &d) {
    if (!s.supported || !d.supported) {
        return false;
    }
    if (d.bytes == 1 && (s.bytes != 1 || s.depth != 8)) {
        return false; // Never truncate high bit depth into an 8-bit buffer.
    }
    return s.components == 1 || (s.log2w == d.log2w && s.log2h == d.log2h);
}

template <class S, class D> void convertRow(const S *src, D *dst, int count, int rightShift, int leftShift) {
    if constexpr (sizeof(S) == sizeof(D)) {
        if (rightShift == 0 && leftShift == 0) {
            std::memcpy(dst, src, static_cast<size_t>(count) * sizeof(S));
            return;
        }
    }
    for (int i = 0; i < count; ++i) {
        dst[i] = static_cast<D>(static_cast<unsigned>(src[i] >> rightShift) << leftShift);
    }
}

template <class S, class D>
void interleaveRow(const S *u, const S *v, D *dst, int count, int rightShift, int leftShift) {
    for (int i = 0; i < count; ++i) {
        dst[2 * i] = static_cast<D>(static_cast<unsigned>(u[i] >> rightShift) << leftShift);
        dst[2 * i + 1] = static_cast<D>(static_cast<unsigned>(v[i] >> rightShift) << leftShift);
    }
}

template <class S, class D> void swapPairsRow(const S *src, D *dst, int pairs, int rightShift, int leftShift) {
    for (int i = 0; i < pairs; ++i) {
        dst[2 * i] = static_cast<D>(static_cast<unsigned>(src[2 * i + 1] >> rightShift) << leftShift);
        dst[2 * i + 1] = static_cast<D>(static_cast<unsigned>(src[2 * i] >> rightShift) << leftShift);
    }
}

template <class S, class D>
void copyPlanes(const AVFrame *f, const SourceLayout &s, CVPixelBufferRef out, int dstBits) {
    const int rightShift = s.shift;
    const int leftShift = dstBits - s.depth;
    const int width = f->width;
    const int height = f->height;

    auto *yBase = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(out, 0));
    const size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(out, 0);
    for (int y = 0; y < height; ++y) {
        convertRow(reinterpret_cast<const S *>(f->data[0] + static_cast<ptrdiff_t>(y) * f->linesize[0]),
                   reinterpret_cast<D *>(yBase + static_cast<size_t>(y) * yStride), width, rightShift, leftShift);
    }

    auto *cBase = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(out, 1));
    const size_t cStride = CVPixelBufferGetBytesPerRowOfPlane(out, 1);
    const int cWidth = static_cast<int>(CVPixelBufferGetWidthOfPlane(out, 1));
    const int cHeight = static_cast<int>(CVPixelBufferGetHeightOfPlane(out, 1));
    if (s.components == 1) {
        const D mid = static_cast<D>(1u << (dstBits - 1));
        for (int y = 0; y < cHeight; ++y) {
            D *row = reinterpret_cast<D *>(cBase + static_cast<size_t>(y) * cStride);
            std::fill_n(row, 2 * cWidth, mid);
        }
        return;
    }
    for (int y = 0; y < cHeight; ++y) {
        D *row = reinterpret_cast<D *>(cBase + static_cast<size_t>(y) * cStride);
        if (s.semiPlanar) {
            const S *src = reinterpret_cast<const S *>(f->data[1] + static_cast<ptrdiff_t>(y) * f->linesize[1]);
            if (s.swapUV) {
                swapPairsRow(src, row, cWidth, rightShift, leftShift);
            } else {
                convertRow(src, row, 2 * cWidth, rightShift, leftShift);
            }
        } else {
            interleaveRow(reinterpret_cast<const S *>(f->data[1] + static_cast<ptrdiff_t>(y) * f->linesize[1]),
                          reinterpret_cast<const S *>(f->data[2] + static_cast<ptrdiff_t>(y) * f->linesize[2]), row,
                          cWidth, rightShift, leftShift);
        }
    }
}

int swsColorspace(YCbCrMatrix matrix, int height) {
    switch (matrix) {
    case YCbCrMatrix::BT709:
        return SWS_CS_ITU709;
    case YCbCrMatrix::BT601:
        return SWS_CS_ITU601;
    case YCbCrMatrix::BT2020:
        return SWS_CS_BT2020;
    case YCbCrMatrix::SMPTE240M:
        return SWS_CS_SMPTE240M;
    case YCbCrMatrix::Unknown:
        break;
    }
    return height >= 720 ? SWS_CS_ITU709 : SWS_CS_ITU601; // Untagged: HD is BT.709, SD BT.601.
}

bool isRGB(AVPixelFormat format) {
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(format);
    return d != nullptr && (d->flags & (AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_PAL));
}

} // namespace

OSType nativePixelFormat(AVPixelFormat format, bool fullRange) {
    const AVPixFmtDescriptor *d = av_pix_fmt_desc_get(format);
    if (d == nullptr) {
        return fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                         : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    }
    if (format == AV_PIX_FMT_YUVJ420P || format == AV_PIX_FMT_YUVJ422P || format == AV_PIX_FMT_YUVJ444P) {
        fullRange = true;
    }
    if ((d->flags & (AV_PIX_FMT_FLAG_ALPHA | AV_PIX_FMT_FLAG_RGB | AV_PIX_FMT_FLAG_PAL)) || d->nb_components == 2 ||
        d->nb_components == 4) {
        return kCVPixelFormatType_32BGRA;
    }
    if (d->nb_components >= 3 && isSubsampling(d, 1, 0)) {
        return fullRange ? kCVPixelFormatType_422YpCbCr10BiPlanarFullRange
                         : kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange;
    }
    if (d->nb_components >= 3 && isSubsampling(d, 0, 0)) {
        return fullRange ? kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
                         : kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange;
    }
    if (d->comp[0].depth > 8) {
        return fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                         : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    }
    return fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                     : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
}

AVPixelFormat avPixelFormatForCV(OSType format) {
    return av_map_videotoolbox_format_to_pixfmt(format);
}

FrameConverter::~FrameConverter() {
    if (transfer_) {
        VTPixelTransferSessionInvalidate(transfer_.get());
    }
}

Status FrameConverter::configure(OSType outputFormat, int width, int height) {
    if (outputFormat == 0 || width < 0 || height < 0) {
        return makeError(MediaErrorCode::InvalidArgument, "FrameConverter: invalid output configuration");
    }
    format_ = outputFormat;
    width_ = width;
    height_ = height;
    pool_ = PixelBufferPool();
    return okStatus();
}

Status FrameConverter::ensurePool(int width, int height) {
    if (pool_ && pool_.width() == static_cast<size_t>(width) && pool_.height() == static_cast<size_t>(height)) {
        return okStatus();
    }
    auto pool = PixelBufferPool::create(format_, static_cast<size_t>(width), static_cast<size_t>(height));
    if (!pool.ok()) {
        return std::move(pool).error();
    }
    pool_ = std::move(pool).value();
    return okStatus();
}

Result<PixelBuffer> FrameConverter::convert(const AVFrame *frame, const ColorInfo &color) {
    if (format_ == 0) {
        return makeError(MediaErrorCode::InvalidState, "FrameConverter: not configured");
    }
    if (frame == nullptr || frame->width <= 0 || frame->height <= 0) {
        return makeError(MediaErrorCode::DecodeFailed, "decoder returned an empty frame");
    }
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        auto *source = reinterpret_cast<CVPixelBufferRef>(frame->data[3]);
        if (source == nullptr) {
            return makeError(MediaErrorCode::DecodeFailed, "VideoToolbox frame without a pixel buffer");
        }
        return convertHardware(source, color);
    }
    return convertSoftware(frame, color);
}

Result<PixelBuffer> FrameConverter::convertHardware(CVPixelBufferRef source, const ColorInfo &color) {
    // Tag the decoder's buffer first: VTPixelTransferSession reads the matrix from it, and in the
    // pass-through case it is the output.
    attachColorInfo(source, color);
    const int srcWidth = static_cast<int>(CVPixelBufferGetWidth(source));
    const int srcHeight = static_cast<int>(CVPixelBufferGetHeight(source));
    const int width = width_ > 0 ? width_ : srcWidth;
    const int height = height_ > 0 ? height_ : srcHeight;
    if (CVPixelBufferGetPixelFormatType(source) == format_ && width == srcWidth && height == srcHeight) {
        if (pixelFormatHasAlpha(format_)) {
            setAlphaMode(source, false); // ProRes 4444 alpha is straight.
        }
        return PixelBuffer::retain(source); // Zero copy: the decoder's IOSurface-backed buffer.
    }
    if (!transfer_) {
        const OSStatus st = VTPixelTransferSessionCreate(kCFAllocatorDefault, transfer_.outPtr());
        if (st != noErr) {
            return makeError(MediaErrorCode::Internal, "VTPixelTransferSessionCreate failed", "OSStatus", st);
        }
    }
    VE_MEDIA_TRY(ensurePool(width, height));
    auto out = pool_.makeBuffer();
    if (!out.ok()) {
        return std::move(out).error();
    }
    const OSStatus st = VTPixelTransferSessionTransferImage(transfer_.get(), source, out->get());
    if (st != noErr) {
        return makeError(MediaErrorCode::UnsupportedFormat,
                         "VTPixelTransferSessionTransferImage to " + fourCCToString(format_) + " failed", "OSStatus",
                         st);
    }
    attachColorInfo(out->get(), color);
    if (pixelFormatHasAlpha(format_)) {
        setAlphaMode(out->get(), false); // VTPixelTransferSession keeps ProRes 4444's straight alpha.
    }
    return std::move(out).value();
}

Result<PixelBuffer> FrameConverter::convertSoftware(const AVFrame *frame, const ColorInfo &color) {
    const auto srcFormat = static_cast<AVPixelFormat>(frame->format);
    const int width = width_ > 0 ? width_ : frame->width;
    const int height = height_ > 0 ? height_ : frame->height;
    VE_MEDIA_TRY(ensurePool(width, height));
    auto out = pool_.makeBuffer();
    if (!out.ok()) {
        return std::move(out).error();
    }
    CVPixelBufferRef buffer = out->get();
    PixelBufferLock lock(buffer, false);
    if (!lock.locked()) {
        return makeError(MediaErrorCode::Internal, "CVPixelBufferLockBaseAddress failed");
    }

    const SourceLayout source = analyzeSource(srcFormat);
    const DestLayout dest = analyzeDest(format_);
    if (width == frame->width && height == frame->height && canCopyDirectly(source, dest)) {
        const int dstBits = dest.bytes == 1 ? 8 : 16;
        if (source.bytes == 1 && dest.bytes == 1) {
            copyPlanes<uint8_t, uint8_t>(frame, source, buffer, dstBits);
        } else if (source.bytes == 1) {
            copyPlanes<uint8_t, uint16_t>(frame, source, buffer, dstBits);
        } else {
            copyPlanes<uint16_t, uint16_t>(frame, source, buffer, dstBits);
        }
    } else {
        const AVPixelFormat dstFormat = avPixelFormatForCV(format_);
        if (dstFormat == AV_PIX_FMT_NONE || !sws_isSupportedOutput(dstFormat) || !sws_isSupportedInput(srcFormat)) {
            return makeError(MediaErrorCode::UnsupportedFormat,
                             std::string("cannot convert ") + (av_get_pix_fmt_name(srcFormat) ?: "?") + " to " +
                                 fourCCToString(format_));
        }
        const bool scaling = width != frame->width || height != frame->height;
        const int flags = (scaling ? SWS_BICUBIC : SWS_POINT) | SWS_ACCURATE_RND | SWS_FULL_CHR_H_INT |
                          SWS_FULL_CHR_H_INP;
        SwsContext *ctx = sws_getCachedContext(sws_.release(), frame->width, frame->height, srcFormat, width,
                                               height, dstFormat, flags, nullptr, nullptr, nullptr);
        sws_.reset(ctx);
        if (!sws_) {
            return makeError(MediaErrorCode::Internal, "sws_getCachedContext failed");
        }
        const bool srcFull = color.fullRange || srcFormat == AV_PIX_FMT_YUVJ420P ||
                             srcFormat == AV_PIX_FMT_YUVJ422P || srcFormat == AV_PIX_FMT_YUVJ444P ||
                             isRGB(srcFormat);
        const bool dstFull = isFullRangeYCbCr(format_) || isRGB(dstFormat);
        const int *table = sws_getCoefficients(swsColorspace(color.matrix, frame->height));
        sws_setColorspaceDetails(sws_.get(), table, srcFull ? 1 : 0, table, dstFull ? 1 : 0, 0, 1 << 16, 1 << 16);

        uint8_t *dst[4] = {};
        int dstStride[4] = {};
        const size_t planes = CVPixelBufferGetPlaneCount(buffer);
        if (planes == 0) {
            dst[0] = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(buffer));
            dstStride[0] = static_cast<int>(CVPixelBufferGetBytesPerRow(buffer));
        } else {
            for (size_t p = 0; p < std::min<size_t>(planes, 4); ++p) {
                dst[p] = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(buffer, p));
                dstStride[p] = static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(buffer, p));
            }
        }
        const int rows = sws_scale(sws_.get(), frame->data, frame->linesize, 0, frame->height, dst, dstStride);
        if (rows < 0) {
            return ffError(rows, MediaErrorCode::Internal, "sws_scale");
        }
    }
    attachColorInfo(buffer, color);
    if (pixelFormatHasAlpha(format_)) {
        setAlphaMode(buffer, false); // libswscale never premultiplies.
    }
    return std::move(out).value();
}

} // namespace ve::media::ffmpeg
