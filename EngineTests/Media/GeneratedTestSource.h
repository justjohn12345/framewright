// A generated picture source for tests (titles design, section 12: "a numbered checkerboard"): its pictures
// encode a number, so a test can tell which source a cached picture came from, and it counts its renders,
// can be made slow (polling the interrupt, or not) and can change over time.
#pragma once

#include "../../Engine/Media/GeneratedSource.h"

#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <optional>

namespace ve::test {

class CheckerboardSource final : public media::GeneratedPictureSource {
  public:
    struct Config {
        /// What the picture encodes (frame n of a non-static source encodes number + n).
        std::uint64_t number = 1;
        /// The key's content id is (number, 0xC0FFEE) and its scale scale64.
        std::uint32_t scale64 = 64;
        /// The raster, in pixels, and where it lies on its canvas.
        int width = 64;
        int height = 32;
        media::CanvasGeometry geometry{1920, 1080, 100, 900, 64, 32};
        bool isStatic = true;
        CMTime frameDuration = CMTimeMake(1, 30);
        /// How long a render takes, in steps of 5 ms between which the interrupt is polled (unless
        /// `ignoresInterrupt`).
        std::chrono::milliseconds renderTime{0};
        bool ignoresInterrupt = false;
    };

    explicit CheckerboardSource(Config config);

    media::GeneratedKey key() const override;
    bool isStatic() const override { return config_.isStatic; }
    CMTime frameDuration() const override { return config_.isStatic ? kCMTimeInvalid : config_.frameDuration; }
    OSType pixelFormat() const override { return kCVPixelFormatType_32BGRA; }
    media::Result<media::VideoFrame> render(CMTime t, const media::DecodeOptions &options) const override;
    std::string description() const override;

    /// Renders started, finished with a picture, and ended by the interrupt (shared by copies of the counters).
    int renders() const { return counters_->started.load(); }
    int finished() const { return counters_->finished.load(); }
    int interrupted() const { return counters_->interrupted.load(); }
    /// Blocks until a render has started (or `timeout`); returns whether one did.
    bool waitForRender(std::chrono::milliseconds timeout) const;

  private:
    struct Counters {
        std::atomic<int> started{0};
        std::atomic<int> finished{0};
        std::atomic<int> interrupted{0};
    };
    Config config_;
    std::shared_ptr<Counters> counters_ = std::make_shared<Counters>();
};

/// The number a CheckerboardSource picture encodes (read from its top-left square: blue the low byte, green
/// the next), or nullopt when the buffer is not one.
std::optional<std::uint64_t> checkerboardNumber(CVPixelBufferRef buffer);

} // namespace ve::test
