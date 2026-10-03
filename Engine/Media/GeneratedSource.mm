#include "GeneratedSource.h"

#include "../Model/TimeUtil.h"
#include "CFRef.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>

namespace ve::media {

namespace {

// The attachment key of a picture's CanvasGeometry (six float64, native order: canvas width and height,
// then the rectangle's x, y, width and height).
CFStringRef canvasGeometryKey() {
    return CFSTR("FramewrightCanvasGeometry");
}

constexpr std::size_t kGeometryValues = 6;

} // namespace

std::uint32_t rasterScale64(double k) {
    if (!std::isfinite(k) || !(k > 0)) {
        k = 1.0;
    }
    // A hair above a whole 64th (floating-point error) is that 64th.
    const double sixtyFourths = std::ceil(k * 64.0 - 1e-6);
    constexpr double kLargest = double(std::numeric_limits<std::uint32_t>::max());
    return static_cast<std::uint32_t>(std::clamp(sixtyFourths, 1.0, kLargest));
}

bool CanvasGeometry::isValid() const noexcept {
    for (const double v : {canvasWidth, canvasHeight, x, y, width, height}) {
        if (!std::isfinite(v)) {
            return false;
        }
    }
    return canvasWidth > 0 && canvasHeight > 0 && width > 0 && height > 0;
}

void setCanvasGeometry(CVPixelBufferRef buffer, const CanvasGeometry &geometry) {
    if (buffer == nullptr) {
        return;
    }
    const double values[kGeometryValues] = {geometry.canvasWidth, geometry.canvasHeight, geometry.x,
                                            geometry.y,           geometry.width,        geometry.height};
    CFRef<CFDataRef> data = CFRef<CFDataRef>::adopt(
        CFDataCreate(kCFAllocatorDefault, reinterpret_cast<const UInt8 *>(values), sizeof values));
    if (data) {
        CVBufferSetAttachment(buffer, canvasGeometryKey(), data.get(), kCVAttachmentMode_ShouldNotPropagate);
    }
}

std::optional<CanvasGeometry> canvasGeometryOf(CVPixelBufferRef buffer) {
    if (buffer == nullptr) {
        return std::nullopt;
    }
    CFRef<CFTypeRef> value = CFRef<CFTypeRef>::adopt(CVBufferCopyAttachment(buffer, canvasGeometryKey(), nullptr));
    if (!value || CFGetTypeID(value.get()) != CFDataGetTypeID()) {
        return std::nullopt;
    }
    const auto data = static_cast<CFDataRef>(value.get());
    double values[kGeometryValues];
    if (CFDataGetLength(data) != CFIndex(sizeof values)) {
        return std::nullopt;
    }
    std::memcpy(values, CFDataGetBytePtr(data), sizeof values);
    const CanvasGeometry geometry{values[0], values[1], values[2], values[3], values[4], values[5]};
    if (!geometry.isValid()) {
        return std::nullopt;
    }
    return geometry;
}

// MARK: - GeneratedVideoDecoder

GeneratedVideoDecoder::GeneratedVideoDecoder(std::shared_ptr<const GeneratedPictureSource> source)
    : source_(std::move(source)) {}

Status GeneratedVideoDecoder::open(const std::string &, int, const DecodeOptions &options) {
    if (opened_) {
        return makeError(MediaErrorCode::InvalidState, "open() called twice");
    }
    if (!source_) {
        return makeError(MediaErrorCode::InvalidArgument, "no generated picture source");
    }
    if (!source_->isStatic() && !isPositive(source_->frameDuration())) {
        return makeError(MediaErrorCode::InvalidArgument,
                         source_->description() + " has no frame duration although it changes over time");
    }
    options_ = options;
    opened_ = true;
    armed_ = true;
    nextIndex_ = 0;
    return okStatus();
}

Status GeneratedVideoDecoder::seek(CMTime t) {
    if (!opened_) {
        return makeError(MediaErrorCode::InvalidState, "seek() before open()");
    }
    if (!CMTIME_IS_NUMERIC(t)) {
        return makeError(MediaErrorCode::InvalidArgument, "seek to a time that is not numeric");
    }
    armed_ = true;
    if (!source_->isStatic()) {
        // The frame containing t (times before the first frame select it).
        nextIndex_ = std::max<int64_t>(0, frameIndexAt(t, source_->frameDuration(), SnapMode::Floor));
    }
    return okStatus();
}

Result<std::optional<VideoFrame>> GeneratedVideoDecoder::next() {
    if (!opened_) {
        return makeError(MediaErrorCode::InvalidState, "next() before open()");
    }
    if (source_->isStatic()) {
        if (!armed_) {
            return std::optional<VideoFrame>{};
        }
        if (!rendered_) {
            auto picture = source_->render(kCMTimeZero, options_);
            if (!picture.ok()) {
                return std::move(picture).error(); // stays armed: the next next() renders again
            }
            VideoFrame frame = std::move(picture).value();
            frame.pts = kCMTimeZero;
            frame.duration = kCMTimePositiveInfinity;
            frame.wasHardwareDecoded = false;
            frame.alphaIsPremultiplied = true;
            rendered_ = std::move(frame);
        }
        armed_ = false;
        return std::optional<VideoFrame>(*rendered_);
    }
    const CMTime frameDuration = source_->frameDuration();
    const CMTime at = timeForFrame(nextIndex_, frameDuration);
    auto picture = source_->render(at, options_);
    if (!picture.ok()) {
        return std::move(picture).error(); // the position is kept: the next next() renders this frame again
    }
    VideoFrame frame = std::move(picture).value();
    frame.pts = at;
    frame.duration = frameDuration;
    frame.wasHardwareDecoded = false;
    frame.alphaIsPremultiplied = true;
    ++nextIndex_;
    return std::optional<VideoFrame>(std::move(frame));
}

CMTime GeneratedVideoDecoder::frameDuration() const {
    return source_ && !source_->isStatic() ? source_->frameDuration() : kCMTimeInvalid;
}

OSType GeneratedVideoDecoder::outputPixelFormat() const {
    return source_ ? source_->pixelFormat() : 0;
}

} // namespace ve::media
