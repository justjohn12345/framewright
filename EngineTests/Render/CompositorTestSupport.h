// Helpers for the compositor, texture cache and preview view tests: synthesized pixel buffers
// in every source format, CPU reference colour conversion, and pixel readback.
#pragma once

#include "../../Engine/Media/MediaTypes.h"
#include "../../Engine/Media/PixelBuffer.h"
#include "../../Engine/Render/Compositor.h"

#import <Metal/Metal.h>

#include <cstdint>
#include <functional>
#include <optional>
#include <utility>
#include <vector>

namespace ve::rtest {

id<MTLDevice> device();

/// IOSurface-backed buffer from a PixelBufferPool; traps the test on failure (returns empty).
media::PixelBuffer makeBuffer(OSType format, size_t width, size_t height);

/// Bit depth of a biplanar YCbCr format (8 or 10), 0 for others.
int bitDepthOf(OSType format);

/// Fills every sample of a biplanar YCbCr buffer with the given integer codes (at the format's
/// bit depth) and tags it with `matrix`.
void fillYCbCr(const media::PixelBuffer &buffer, int y, int cb, int cr, media::YCbCrMatrix matrix);

/// Fills a biplanar YCbCr buffer sample by sample: `luma(x, y)` for every luma sample and
/// `chroma(i, j)` = {Cb, Cr} for every chroma sample, as integer codes at the format's bit depth
/// (rounded). Attachments are left alone (see tagYCbCr).
void fillYCbCrPattern(const media::PixelBuffer &buffer, const std::function<double(size_t x, size_t y)> &luma,
                      const std::function<std::pair<double, double>(size_t i, size_t j)> &chroma);

/// Sets (or, when nullopt, removes) the YCbCr matrix and chroma location attachments.
void tagYCbCr(const media::PixelBuffer &buffer, std::optional<media::YCbCrMatrix> matrix,
              std::optional<render::ChromaSiting> siting);

struct RGBA8 {
    uint8_t r = 0, g = 0, b = 0, a = 255;
};

/// Fills a BGRA buffer (premultiplied values as given).
void fillBGRA(const media::PixelBuffer &buffer, RGBA8 color);
/// Fills [x0,x1) x [y0,y1) of a BGRA buffer.
void fillBGRARect(const media::PixelBuffer &buffer, size_t x0, size_t y0, size_t x1, size_t y1, RGBA8 color);

/// CPU BGRA -> '420v' (BT.709 video range, 2x2 chroma average), tagged BT.709.
media::PixelBuffer convertBGRATo420v(const media::PixelBuffer &bgra);

/// A '420v' burn-in frame (EngineTests/Media/BurnIn.h layout) for `index`.
media::PixelBuffer makeBurnIn420v(int index, size_t width, size_t height);

/// Reads one pixel of a BGRA buffer.
RGBA8 pixelAt(const media::PixelBuffer &bgra, size_t x, size_t y);

/// Reads one pixel of a BGRA8Unorm texture with shared storage.
RGBA8 texturePixel(id<MTLTexture> texture, size_t x, size_t y);

/// A shared-storage BGRA8Unorm render target texture.
id<MTLTexture> makeTargetTexture(size_t width, size_t height);

/// Reference YCbCr codes -> 8-bit-scaled R'G'B' (0...255, unclamped doubles).
struct RGBd {
    double r, g, b;
};
RGBd referenceRGB(double y, double cb, double cr, int bitDepth, bool fullRange, media::YCbCrMatrix matrix);

/// The CPU reference picture of a YCbCr buffer as the compositor should show it at 1:1: every
/// luma sample converted with the chroma bilinearly interpolated at its position for `siting`
/// (edges clamped), 8-bit-scaled R'G'B' clamped to [0, 255].
RGBd referencePixel(const media::PixelBuffer &buffer, size_t x, size_t y, media::YCbCrMatrix matrix,
                    render::ChromaSiting siting);

/// Graph helpers.
RenderGraph makeGraph(int32_t width, int32_t height);
VideoLayer makeLayer(uint64_t clipId, double opacity = 1.0);

/// Renders `graph` with one TextureSet per layer (empty = missing) and waits.
media::Result<render::RenderResult> renderLayers(render::Compositor &compositor, const RenderGraph &graph,
                                                 const std::vector<render::TextureSet> &textures,
                                                 const render::RenderTarget &target);

/// Maps a buffer through the compositor's texture cache (traps on failure: returns empty).
render::TextureSet texturesFor(const render::Compositor &compositor, const media::PixelBuffer &buffer);

/// |a - b| <= tolerance for each channel.
bool near(RGBA8 actual, double r, double g, double b, double tolerance);

} // namespace ve::rtest
