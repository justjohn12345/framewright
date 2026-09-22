// Zero-copy mapping of IOSurface-backed CVPixelBuffers to Metal textures (CVMetalTextureCache).
//
// Supported pixel formats (what the media backends produce, plus the compositor's targets):
//   8-bit biplanar YCbCr   '420v' '420f' '422v' '422f' '444v' '444f'   Y r8Unorm,  CbCr rg8Unorm
//   10-bit biplanar YCbCr  'x420' 'xf20' 'x422' 'xf22' 'x444' 'xf44'   Y r16Unorm, CbCr rg16Unorm
//   32BGRA                 'BGRA'                                        bgra8Unorm (premultiplied alpha)
// Anything else is rejected with MediaErrorCode::UnsupportedFormat.
//
// Colour: a TextureSet carries the YCbCr -> R'G'B' matrix for its buffer, chosen from the
// buffer's kCVImageBufferYCbCrMatrixKey attachment (BT.709, BT.601, BT.2020 non-constant
// luminance, SMPTE 240M) and the pixel format's range and bit depth. Untagged buffers use
// BT.709 when the height is >= 720 and BT.601 below (the usual HD/SD convention).
// BGRA buffers are taken as premultiplied alpha (the convention of the still-image decoder and
// of CGBitmapContext); their colour matrix is unused.

#pragma once

#include "../Media/CFRef.h"
#include "../Media/PixelBuffer.h"
#include "../Media/Result.h"

#import <CoreVideo/CVMetalTextureCache.h>
#import <Metal/Metal.h>
#include <simd/simd.h>

#include <atomic>
#include <cstdint>
#include <string>

namespace ve::render {

/// Class of a source picture, which selects the fragment shader variant.
enum class SourceClass : std::uint8_t { YCbCrBiPlanar, RGBA };

/// The Metal textures of one pixel buffer, valid while this object (or a copy) lives: it owns
/// the CVMetalTextureRefs (and so the IOSurface use), not just the id<MTLTexture>s.
///
/// Value type: copying retains, no heap allocation. An empty (default) TextureSet means "no
/// picture". Thread-safety: like PixelBuffer (distinct copies may be used concurrently).
class TextureSet {
  public:
    TextureSet() = default;

    explicit operator bool() const noexcept { return planes_[0] != nil; }
    SourceClass sourceClass() const noexcept { return sourceClass_; }
    /// Plane 0: luma or the BGRA texture. Plane 1: CbCr (nil for BGRA).
    id<MTLTexture> plane(std::size_t index) const noexcept { return index < 2 ? planes_[index] : nil; }
    std::size_t planeCount() const noexcept { return sourceClass_ == SourceClass::RGBA ? 1 : 2; }
    /// Picture size in pixels (luma plane size).
    std::size_t width() const noexcept { return width_; }
    std::size_t height() const noexcept { return height_; }
    OSType pixelFormat() const noexcept { return pixelFormat_; }
    /// See VESourceUniforms.colorMatrix; identity for RGBA.
    const simd_float4x4 &colorMatrix() const noexcept { return colorMatrix_; }
    /// The buffer the textures alias.
    const media::PixelBuffer &pixelBuffer() const noexcept { return buffer_; }

    void reset() noexcept { *this = TextureSet(); }

  private:
    friend class TextureCache;
    media::PixelBuffer buffer_;
    media::CFRef<CVMetalTextureRef> refs_[2];
    id<MTLTexture> planes_[2] = {nil, nil};
    SourceClass sourceClass_ = SourceClass::RGBA;
    std::size_t width_ = 0;
    std::size_t height_ = 0;
    OSType pixelFormat_ = 0;
    simd_float4x4 colorMatrix_ = matrix_identity_float4x4;
};

enum class TextureAccess : std::uint8_t {
    Read,      ///< sampled by shaders
    ReadWrite, ///< also written by compute kernels (export targets)
};

/// Owns one CVMetalTextureCache for one MTLDevice.
///
/// Thread-safety: textures() and flush() may be called from any thread concurrently
/// (CVMetalTextureCache is internally synchronised).
class TextureCache {
  public:
    static media::Result<TextureCache> create(id<MTLDevice> device);

    TextureCache() = default;
    TextureCache(TextureCache &&other) noexcept;
    TextureCache &operator=(TextureCache &&other) noexcept;
    TextureCache(const TextureCache &) = delete;
    TextureCache &operator=(const TextureCache &) = delete;

    id<MTLDevice> device() const noexcept { return device_; }

    /// Maps `buffer` (IOSurface backed, one of the formats above). Also flushes the cache's
    /// unused entries at most every kFlushInterval seconds.
    media::Result<TextureSet> textures(const media::PixelBuffer &buffer,
                                       TextureAccess access = TextureAccess::Read) const;

    /// Releases cache entries no TextureSet references any more.
    void flush() const;

    /// Minimum time between the automatic flushes done by textures().
    static constexpr double kFlushInterval = 1.0;

    /// Whether `pixelFormat` is one of the supported formats.
    static bool supportsPixelFormat(OSType pixelFormat);

  private:
    id<MTLDevice> device_ = nil;
    media::CFRef<CVMetalTextureCacheRef> cache_;
    mutable std::atomic<std::uint64_t> lastFlush_{0}; // mach_absolute_time
};

/// "420v"-style printable form of a pixel format code.
std::string fourCCString(OSType code);

} // namespace ve::render
