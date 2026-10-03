#include "GeneratedTestSource.h"

#include "../../Engine/Media/PictureDrawing.h"
#include "../../Engine/Model/TimeUtil.h"

#include <thread>

namespace ve::test {

using namespace ve::media;

CheckerboardSource::CheckerboardSource(Config config) : config_(config) {}

GeneratedKey CheckerboardSource::key() const {
    return GeneratedKey{config_.number, 0xC0FFEE, config_.scale64};
}

std::string CheckerboardSource::description() const {
    return "the checkerboard " + std::to_string(config_.number);
}

bool CheckerboardSource::waitForRender(std::chrono::milliseconds timeout) const {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    while (counters_->started.load() == 0) {
        if (std::chrono::steady_clock::now() >= deadline) {
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return true;
}

Result<VideoFrame> CheckerboardSource::render(CMTime t, const DecodeOptions &options) const {
    ++counters_->started;
    for (auto waited = std::chrono::milliseconds(0); waited < config_.renderTime; waited += std::chrono::milliseconds(5)) {
        if (!config_.ignoresInterrupt && options.interrupt && options.interrupt->requested()) {
            ++counters_->interrupted;
            return makeError(MediaErrorCode::Cancelled, "interrupted");
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (!config_.ignoresInterrupt && options.interrupt && options.interrupt->requested()) {
        ++counters_->interrupted;
        return makeError(MediaErrorCode::Cancelled, "interrupted");
    }
    std::uint64_t number = config_.number;
    if (!config_.isStatic) {
        number += std::uint64_t(std::max<int64_t>(0, frameIndexAt(t, config_.frameDuration, SnapMode::Floor)));
    }
    const int squares = 8;
    auto picture = drawPicture(kCVPixelFormatType_32BGRA, size_t(config_.width), size_t(config_.height),
                               [&](CGContextRef ctx) {
                                   CGContextClearRect(ctx, CGRectMake(0, 0, config_.width, config_.height));
                                   // Squares alternate the number's colour (opaque) with transparency;
                                   // the top-left square (CoreGraphics: origin bottom left) is coloured.
                                   const double side = double(config_.width) / squares;
                                   CGContextSetRGBFillColor(ctx, 0.8, double((number >> 8) & 0xFF) / 255.0,
                                                            double(number & 0xFF) / 255.0, 1.0);
                                   for (int row = 0; row * side < config_.height; ++row) {
                                       for (int column = 0; column < squares; ++column) {
                                           if ((row + column) % 2 == 0) {
                                               CGContextFillRect(ctx, CGRectMake(column * side,
                                                                                 config_.height - (row + 1) * side,
                                                                                 side, side));
                                           }
                                       }
                                   }
                               });
    if (!picture.ok()) {
        return std::move(picture).error();
    }
    setCanvasGeometry(picture->get(), config_.geometry);
    VideoFrame frame;
    frame.image = std::move(picture).value();
    ++counters_->finished;
    return frame;
}

std::optional<std::uint64_t> checkerboardNumber(CVPixelBufferRef buffer) {
    if (buffer == nullptr || CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA) {
        return std::nullopt;
    }
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const auto *p = static_cast<const std::uint8_t *>(CVPixelBufferGetBaseAddress(buffer));
    std::optional<std::uint64_t> number;
    if (p != nullptr && p[3] == 255 && p[2] == 204) { // B, G, R, A: the coloured top-left square
        number = std::uint64_t(p[0]) | (std::uint64_t(p[1]) << 8);
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return number;
}

} // namespace ve::test
