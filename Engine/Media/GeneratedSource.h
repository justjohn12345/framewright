// Generated pictures: pictures the engine makes instead of decoding a file (titles and colour mattes;
// later animated text, captions, nested sequences). docs/plans/2026-10-02-titles-design.md, section 2.
//
// - GeneratedPictureSource is what a generated picture is made from: immutable and shared between
//   threads, it renders its picture (blocking) on a decode pool worker or the pool's scrub thread, never
//   on the render or main thread. Its key() is the picture's cache identity, GeneratedKey: a 128-bit id of
//   its content and the raster scale it is drawn at. Keys are content-addressed, so an undo back to
//   earlier text finds that picture if it is still cached, and two clips with identical content share one.
// - GeneratedVideoDecoder adapts a source to IVideoDecoder, so the decode pool's streams, windows,
//   interrupts, epochs, eviction focus and scrub coalescing serve generated pictures unchanged
//   (DecodePool::DecodeTarget::generated, DecodePool::requestFrame's `generated`). A static source (one
//   picture for all times: a title, a matte) behaves exactly as the still decoders do: one frame with
//   pts 0 and an infinite duration after open and after each seek. A non-static source returns a frame per
//   step of its frame grid.
// - The frame cache keys a generated picture by FrameKey{generator asset, decode format, GeneratedKey}
//   (FrameCache.h); the key of a file's frames is empty.
// - CanvasGeometry is where a generated picture lies on the frame-sized transparent canvas it stands for:
//   the picture is only the rectangle that has something in it (a lower third is a strip, not a frame).
//   It is an attachment of the picture's buffer (setCanvasGeometry), so it travels with the picture into
//   the frame cache, a held previous picture and the TextureSet mapped from it (TextureCache.h), and is
//   never recomputed from the layer that shows it.

#pragma once

#include "Interfaces.h"

#include <compare>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>

namespace ve::media {

/// The cache identity of a generated picture (see the header comment). Empty for decoded media.
struct GeneratedKey {
    /// The content id (128 bits; the model's, e.g. TitleContent::contentId), high and low halves.
    std::uint64_t contentHigh = 0;
    std::uint64_t contentLow = 0;
    /// The raster scale k (raster pixels per sequence pixel) in 64ths (rasterScale64).
    std::uint32_t scale64 = 0;

    bool isEmpty() const noexcept { return contentHigh == 0 && contentLow == 0 && scale64 == 0; }
    /// k as a number (scale64 / 64).
    double scale() const noexcept { return double(scale64) / 64.0; }

    friend bool operator==(const GeneratedKey &, const GeneratedKey &) = default;
    friend auto operator<=>(const GeneratedKey &, const GeneratedKey &) = default;
};

/// The raster scale `k` quantised up to the next 1/64 (at least 1/64; titles design, section 3), so the
/// picture is never drawn coarser than asked: ceil(k * 64), with a non-finite or non-positive `k` as 1.
std::uint32_t rasterScale64(double k);

/// Where a generated picture lies on its canvas (see the header comment): the canvas is the sequence frame,
/// `canvasWidth` x `canvasHeight` sequence pixels, and the picture's pixels cover the rectangle (x, y,
/// width, height) of it, in sequence pixels (origin top left, +y down; it may reach outside the canvas).
/// Everything else of the canvas is transparent. The compositor places the canvas as it places a
/// frame-sized still and maps it to the picture through this rectangle (Compositor.mm, placeSource).
struct CanvasGeometry {
    double canvasWidth = 0;
    double canvasHeight = 0;
    double x = 0;
    double y = 0;
    double width = 0;
    double height = 0;

    /// Finite values, a positive canvas and a positive rectangle.
    bool isValid() const noexcept;
    friend bool operator==(const CanvasGeometry &, const CanvasGeometry &) = default;
};

/// Tags `buffer` with `geometry` (an attachment that does not propagate to buffers made from it).
void setCanvasGeometry(CVPixelBufferRef buffer, const CanvasGeometry &geometry);
/// The geometry `buffer` is tagged with; nullopt for an untagged buffer (every decoded picture) or a tag that
/// is not a valid geometry.
std::optional<CanvasGeometry> canvasGeometryOf(CVPixelBufferRef buffer);

/// What a generated picture is made from (see the header comment). Implementations are immutable after
/// construction: every method may be called from any thread, concurrently.
class GeneratedPictureSource {
  public:
    virtual ~GeneratedPictureSource() = default;

    /// The picture's cache identity: its content id and raster scale. The same for every call.
    virtual GeneratedKey key() const = 0;
    /// One picture for all times (a title, a colour matte). Rendered at time 0.
    virtual bool isStatic() const = 0;
    /// The source's frame grid (positive) when it is not static; invalid when static.
    virtual CMTime frameDuration() const = 0;
    /// The pixel format of the pictures it renders (what IVideoDecoder::outputPixelFormat reports).
    virtual OSType pixelFormat() const = 0;
    /// Renders the picture at time `t` (on the frame grid for a non-static source; 0 for a static one):
    /// an IOSurface-backed, premultiplied buffer tagged with its CanvasGeometry, with pts and duration as
    /// GeneratedVideoDecoder hands them out. Blocking; called on a pool worker or the scrub thread. Polls
    /// `options.interrupt` (when set) between units of work and returns MediaErrorCode::Cancelled once it
    /// is requested.
    virtual Result<VideoFrame> render(CMTime t, const DecodeOptions &options) const = 0;
    /// What the picture is, for logs and error messages ("the title “Hello”").
    virtual std::string description() const = 0;
};

/// IVideoDecoder over a GeneratedPictureSource (see the header comment). open() ignores its path and
/// track and keeps the options (their interrupt is passed to every render). A static source renders once:
/// the picture is kept, so a seek (the pool repairing an evicted picture) hands it out again without a
/// second render. A non-static source renders the frame of its grid that contains the seek target, then the
/// following ones, each [n * frameDuration, (n + 1) * frameDuration); it never ends.
class GeneratedVideoDecoder final : public IVideoDecoder {
  public:
    explicit GeneratedVideoDecoder(std::shared_ptr<const GeneratedPictureSource> source);

    Status open(const std::string &path, int trackIndex, const DecodeOptions &options) override;
    Status seek(CMTime t) override;
    Result<std::optional<VideoFrame>> next() override;
    CMTime frameDuration() const override;
    bool supportsRandomAccess() const override { return true; }
    bool usedHardware() const override { return false; }
    OSType outputPixelFormat() const override;
    std::string activeBackend() const override { return "generated"; }

    const std::shared_ptr<const GeneratedPictureSource> &source() const noexcept { return source_; }

  private:
    std::shared_ptr<const GeneratedPictureSource> source_;
    DecodeOptions options_;
    bool opened_ = false;
    bool armed_ = false;       ///< Static: the next next() returns the picture.
    int64_t nextIndex_ = 0;    ///< Non-static: the frame the next next() renders.
    std::optional<VideoFrame> rendered_; ///< Static: the picture, once rendered.
};

} // namespace ve::media
