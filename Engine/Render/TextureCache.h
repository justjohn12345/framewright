// Zero-copy mapping of IOSurface-backed CVPixelBuffers to Metal textures (CVMetalTextureCache).
//
// Supported pixel formats (what the media backends produce, plus the compositor's targets):
//   8-bit biplanar YCbCr   '420v' '420f' '422v' '422f' '444v' '444f'   Y r8Unorm,  CbCr rg8Unorm
//   10-bit biplanar YCbCr  'x420' 'xf20' 'x422' 'xf22' 'x444' 'xf44'   Y r16Unorm, CbCr rg16Unorm
//   32BGRA                 'BGRA'                                        bgra8Unorm (see Alpha below)
// Anything else is rejected with MediaErrorCode::UnsupportedFormat.
//
// Colour: a TextureSet carries the YCbCr -> R'G'B' matrix for its buffer, chosen from the
// buffer's kCVImageBufferYCbCrMatrixKey attachment (BT.709, BT.601, BT.2020 non-constant
// luminance, SMPTE 240M) and the pixel format's range and bit depth. Untagged buffers use
// BT.709 when the height is >= 720 and BT.601 below (the usual HD/SD convention).
// Alpha (BGRA only; YCbCr pictures are opaque): the buffer's kCVImageBufferAlphaChannelModeKey
// attachment says whether its colour is premultiplied by alpha (PremultipliedAlpha) or not
// (StraightAlpha); TextureSet::alphaMode() reports it, Unspecified when untagged, and producers
// that know better may override it with setAlphaMode(). The compositor resolves Unspecified
// per layer with alphaIsPremultiplied(isStill): premultiplied for stills (the still decoders
// premultiply, like CGBitmapContext), straight for video (sws_scale output and ProRes 4444
// decode are straight). Straight pictures are premultiplied texel by texel in the shader,
// before filtering, so transparent texels never bleed their colour. The colour matrix is
// unused for BGRA.
//
// Chroma siting: where the subsampled chroma samples sit relative to the luma grid comes from
// the buffer's kCVImageBufferChromaLocationTopFieldKey attachment (Left, Center, TopLeft, Top,
// BottomLeft, Bottom; DV420 is taken as Left). Untagged 4:2:0 and 4:2:2 buffers are Left sited,
// the H.264/HEVC/MPEG-2 default (chroma_sample_loc_type 0). 4:4:4 has no siting. The TextureSet
// carries the resulting luma-uv -> chroma-uv transform, which also accounts for odd sizes
// (a 1919-pixel-wide 4:2:0 picture has 960 chroma columns covering 1920 luma columns).

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

/// Position of a subsampled chroma sample relative to the luma samples it covers (the
/// kCVImageBufferChromaLocation values). For 4:2:0: Left = co-sited with the left luma column,
/// vertically between the two rows; Center = centre of the 2x2 block; Top* / Bottom* = on the
/// top / bottom row. 4:2:2 uses only the horizontal part.
enum class ChromaSiting : std::uint8_t { Left, Center, TopLeft, Top, BottomLeft, Bottom };

/// Whether a BGRA picture's colour is premultiplied by its alpha.
enum class AlphaMode : std::uint8_t {
    Unspecified,   ///< Untagged: resolved per layer (see TextureSet::alphaIsPremultiplied).
    Premultiplied, ///< Colour already multiplied by alpha (also every opaque YCbCr picture).
    Straight,      ///< Colour independent of alpha ("unassociated"/"non-premultiplied").
};

/// Reads a buffer's kCVImageBufferAlphaChannelModeKey attachment (Unspecified when untagged).
AlphaMode alphaModeOf(CVPixelBufferRef buffer);

/// Reads a buffer's chroma location attachment (top field); `fallback` when untagged or unknown.
ChromaSiting chromaSitingOf(CVPixelBufferRef buffer, ChromaSiting fallback = ChromaSiting::Left);

/// The CoreVideo attachment value for a siting.
CFStringRef chromaLocationString(ChromaSiting siting);

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
    /// The picture's alpha convention as tagged (or set); Premultiplied for YCbCr.
    AlphaMode alphaMode() const noexcept { return alphaMode_; }
    /// Overrides the tagged alpha convention (for producers that know it but cannot tag the
    /// buffer). Ignored for YCbCr pictures, which are opaque.
    void setAlphaMode(AlphaMode mode) noexcept {
        if (sourceClass_ == SourceClass::RGBA) {
            alphaMode_ = mode;
        }
    }
    /// Whether the colour is premultiplied: the tag when there is one, else true for stills
    /// (`sourceIsStill`, from VideoLayer::isStill) and false for video frames.
    bool alphaIsPremultiplied(bool sourceIsStill) const noexcept {
        return alphaMode_ == AlphaMode::Premultiplied || (alphaMode_ == AlphaMode::Unspecified && sourceIsStill);
    }
    /// Chroma siting of a YCbCr picture (Center for RGBA and 4:4:4, where it has no effect).
    ChromaSiting chromaSiting() const noexcept { return chromaSiting_; }
    /// Chroma uv = luma uv * xy + zw (see VESourceUniforms.chromaTransform); (1, 1, 0, 0) for
    /// RGBA and 4:4:4.
    simd_float4 chromaTransform() const noexcept { return chromaTransform_; }
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
    AlphaMode alphaMode_ = AlphaMode::Unspecified;
    ChromaSiting chromaSiting_ = ChromaSiting::Center;
    simd_float4 chromaTransform_ = {1.0f, 1.0f, 0.0f, 0.0f};
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
