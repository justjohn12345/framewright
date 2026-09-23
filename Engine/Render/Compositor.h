// Metal compositor: draws one RenderGraph (the layers visible at one sequence frame) into a
// Metal texture (the preview drawable) or an IOSurface-backed CVPixelBuffer (export).
//
// Pipeline, per frame:
//   1. Clear the target to opaque black (letterbox bars included).
//   2. For each layer, bottom to top: a quad covering the layer's footprint; the fragment shader
//      inverse-maps each output pixel to source uv, samples bilinearly, converts YCbCr to R'G'B'
//      with the source's matrix/range/bit depth (see TextureCache.h), applies an anti-aliased
//      edge and the layer weight, and blends premultiplied (ONE, ONE_MINUS_SOURCE_ALPHA).
//      The two layers of a cross dissolve are drawn in one pass as mix(A, B, mix) of their
//      premultiplied samples, so a dissolve between (partly) transparent layers never dips.
//   3. Pixel-buffer targets: the frame is composited into an RGBA16Float intermediate, then a
//      compute pass writes the target's planes (BGRA, or 4:2:0 BT.709 YCbCr for 420v/420f with
//      left-sited chroma, tagged as such).
//
// Chroma: YCbCr sources are sampled with their chroma plane offset for the buffer's chroma
// siting (TextureCache.h), so left-sited H.264/HEVC chroma lines up with its luma.
//
// Geometry (all in sequence pixels, origin top left, +y down): the decoded picture (storage
// orientation) is first turned clockwise by VideoLayer::sourceRotationDegrees (the container's
// display rotation, a quarter turn; iPhone portrait video is stored landscape with 90), the
// turned picture is fitted into the sequence frame preserving its aspect ratio
// (letterbox/pillarbox, square pixels), then scaled by VideoParams::scale about its centre,
// rotated by rotationDegrees (positive = clockwise on screen) about its centre, and its centre
// is offset by (x, y) from the frame centre. The sequence frame itself is fitted into the
// target the same way (black bars).
//
// Colour: blending happens on gamma-encoded BT.709 R'G'B' values (display-referred, like
// Premiere's default non-linear compositing), not in linear light. Opacity and dissolves are
// therefore "video" blends; a linear-light path would linearise before and re-encode after
// blending. sRGB-encoded stills are treated as having the BT.709 transfer (the curves differ
// slightly near black). Wide-gamut or HDR sources are not converted (out of scope, see PLAN).
//
// Weights: a layer's weight is its opacity; a layer in a transition drawn without its partner
// (partner missing or malformed) also gets its transition weight (LayerTransition::weight()).
//
// Missing pictures: when the TextureLookup has no texture for a layer it is left out, the rest
// of the frame still renders, and the layer is listed in RenderResult::skippedLayers.
//
// Minification: bilinear sampling reads 2x2 texels, so a picture drawn smaller than about 3/4 of
// its size aliases (1-pixel detail turns into moire and flicker). A source plane drawn at fewer
// than 0.75 target pixels per texel (along either axis, counting the viewport scale; chroma
// planes of subsampled formats have their own ratio) is first resampled with
// MPSImageLanczosScale into a pooled texture of about its drawn size, then sampled bilinearly at
// ~1:1. Straight-alpha RGBA is premultiplied into a pooled RGBA8 texture before resampling.
// Pooled textures are keyed by (format, size), with sizes rounded up to 1/16-1/32 steps so a
// live resize reuses them, and released after 120 frames unused (or releaseScratchMemory()).
// Why this and not the alternatives (measured on this Apple-silicon Mac; standalone numbers are
// GPU time per plane of a 3840x2160 4:2:0 frame resampled to 1920x1080):
//   - MPSImageBilinearScale: 0.13 ms for the luma plane, but it does not widen its kernel when
//     shrinking, so 1-pixel stripes still alias (row min/max 4/251 at 1920 -> 700).
//   - MPSImageLanczosScale (chosen): 0.77 ms luma (r8), 0.22 ms chroma (rg8) standalone; flat
//     grey (126-128) on the stripe test at 700, 533, 960 and 1280 px. In the pipeline a whole
//     4K 4:2:0 frame shown at 1080p (luma pre-scaled, chroma at 1:1 needs none) costs 0.60 ms
//     of GPU time and 0.8 ms end-to-end latency (CompositorTests testPreviewOf4KSourceTiming),
//     against 0.07 ms for a 1080p layer at 1:1.
//   - Mipmaps of an RGB intermediate: the source would first be converted at full size into a
//     mipmapped RGBA16F texture every frame (66 MB + 22 MB of mips for 4K, about three times
//     the bytes the Lanczos pass moves), and a box-filtered mip chain blurs more than Lanczos.
// Pictures drawn at >= 0.75 of their size (including all magnification) take no extra pass.
//
// Resources: one render pipeline per (source A class, has partner, source B class, target
// format), created lazily and cached (those for create()'s prepared formats up front).
// Per-draw uniforms live in a triple-buffered ring of MTLBuffers (kFramesInFlight slots);
// steady-state rendering makes no heap allocations of its own (Metal still creates its
// command buffer and encoders per frame).
//
// Thread-safety: a Compositor is not thread-safe; use it from one thread at a time (e.g. one
// per render thread: the preview view owns one, an export job another). Completion handlers
// run on a Metal-owned thread. Destroying a Compositor waits for its in-flight frames.

#pragma once

#include "../Media/PixelBuffer.h"
#include "../Media/Result.h"
#include "FunctionRef.h"
#include "RenderGraph.h"
#include "TextureCache.h"

#import <Metal/Metal.h>

#include <cstddef>
#include <cstdint>
#include <functional>
#include <initializer_list>
#include <memory>
#include <variant>
#include <vector>

namespace ve::render {

/// Resolves a layer's picture. Returns true and fills `out` when a picture is available, false
/// when it is not (yet), in which case the layer is skipped. Called on the rendering thread,
/// once per layer per render() call.
using TextureLookup = FunctionRef<bool(const VideoLayer &layer, std::size_t layerIndex, TextureSet &out)>;

/// Integer rectangle in target pixels (origin top left).
struct PixelRect {
    std::int32_t x = 0;
    std::int32_t y = 0;
    std::int32_t width = 0;
    std::int32_t height = 0;

    bool isEmpty() const { return width <= 0 || height <= 0; }
    friend bool operator==(const PixelRect &, const PixelRect &) = default;
};

/// Largest rectangle of aspect sourceWidth:sourceHeight centred in the destination, rounded to
/// whole pixels. Empty if any size is not positive.
PixelRect fitRect(double sourceWidth, double sourceHeight, std::int32_t destWidth, std::int32_t destHeight);

/// Render into an existing texture (must have MTLTextureUsageRenderTarget, any
/// colour-renderable pixel format). The sequence frame is drawn into `viewport` (an empty
/// viewport means "fit the sequence aspect into the whole texture"; a viewport reaching outside
/// the texture is clipped to it); the rest of the texture is cleared to black. If `drawable` is
/// set it is presented when the frame completes.
struct TextureTarget {
    id<MTLTexture> texture = nil;
    PixelRect viewport;
    id<MTLDrawable> drawable = nil;
};

/// Render into an IOSurface-backed CVPixelBuffer of format '32BGRA', '420v' or '420f' (BT.709
/// matrix, left-sited chroma; colour and chroma-location attachments are set on the buffer, and
/// removed from BGRA buffers). The frame is fitted into the buffer.
struct PixelBufferTarget {
    media::PixelBuffer buffer;
};

using RenderTarget = std::variant<TextureTarget, PixelBufferTarget>;

struct SkippedLayer {
    std::size_t layerIndex = 0;
    ClipId clipId;
    friend bool operator==(const SkippedLayer &, const SkippedLayer &) = default;
};

struct RenderResult {
    std::uint64_t frameNumber = 0;          ///< Increments per submitted frame (1-based).
    media::Status status;                   ///< GPU execution failure, if any.
    std::vector<SkippedLayer> skippedLayers; ///< Layers left out because their picture was missing.
    std::size_t drawnLayers = 0;            ///< Layers that had a picture (a dissolve pair counts 2).
    std::size_t prescaledPlanes = 0;        ///< Source planes Lanczos pre-scaled for minification.
    double gpuSeconds = 0;                  ///< GPU execution time of the frame's command buffer.
    /// Host times (seconds, CACurrentMediaTime base) the GPU started and finished the frame.
    /// Frames in flight overlap, so GPU load is the union of these intervals, not a sum.
    double gpuStartTime = 0;
    double gpuEndTime = 0;
};

/// Called once per submitted frame on a Metal completion thread after the GPU finished. The
/// result is only valid during the call. Must not call back into the Compositor.
using RenderCompletion = std::function<void(const RenderResult &)>;

struct RenderOptions {
    /// Wait for a free uniform slot when kFramesInFlight frames are already on the GPU. When
    /// false (the display-link path), render() returns Submission::Busy instead of blocking.
    bool waitForFreeSlot = true;
};

enum class Submission {
    Submitted, ///< Encoded and committed; the completion will be called.
    Busy,      ///< Dropped: every slot in flight and waitForFreeSlot was false. No completion.
};

class Compositor {
  public:
    static constexpr std::size_t kFramesInFlight = 3;

    /// Loads the engine's Metal library from the framework bundle and prepares the pipelines
    /// for rendering into `preparedFormats` (pipelines for other target formats are built on
    /// first use, which costs a few milliseconds on that frame). Pixel-buffer targets render
    /// through an RGBA16Float intermediate.
    static media::Result<std::unique_ptr<Compositor>>
    create(id<MTLDevice> device,
           std::initializer_list<MTLPixelFormat> preparedFormats = {MTLPixelFormatBGRA8Unorm, MTLPixelFormatRGBA16Float});

    ~Compositor();
    Compositor(const Compositor &) = delete;
    Compositor &operator=(const Compositor &) = delete;

    /// Encodes and commits one frame. Returns an error, with nothing submitted, when the target
    /// or graph is invalid or a pipeline cannot be built. Never waits for the GPU (it may wait
    /// for a free slot, see RenderOptions).
    media::Result<Submission> render(const RenderGraph &graph, TextureLookup lookup, const RenderTarget &target,
                                     RenderCompletion completion = {}, RenderOptions options = {});

    /// render() and wait until the GPU finished. For export threads and tests; never call it
    /// from a display-link callback. The returned status includes GPU errors.
    media::Result<RenderResult> renderAndWait(const RenderGraph &graph, TextureLookup lookup,
                                              const RenderTarget &target);

    /// Frames that can be submitted right now without waiting (0 ... kFramesInFlight).
    /// Thread-safe.
    std::size_t freeSlotCount() const;

    /// Waits up to `timeoutSeconds` (0: just checks) until a frame can be submitted without
    /// waiting; does not take the slot. As only the thread calling render() takes slots, a
    /// true result means that thread's next render() will not be Busy (unless slots are held
    /// for testing). Thread-safe.
    bool waitForFreeSlot(double timeoutSeconds) const;

    /// Releases memory that is only a cache: pooled pre-scale textures, the export intermediate
    /// and the texture cache's unused entries (frames on the GPU keep what they use). For memory
    /// pressure; the next frames re-create what they need. Same thread as render().
    void releaseScratchMemory();

    struct Stats {
        std::size_t freeSlots = 0;       ///< See freeSlotCount().
        std::size_t scratchTextures = 0; ///< Pooled pre-scale textures.
        std::size_t scratchBytes = 0;    ///< Their allocated size.
    };
    /// Same thread as render().
    Stats stats() const;

    id<MTLDevice> device() const;
    id<MTLCommandQueue> commandQueue() const;
    /// The compositor's texture cache (also used for pixel-buffer targets); callers on the same
    /// device may share it for their sources.
    const TextureCache &textureCache() const;

    // MARK: Testing

    /// Failure points of render() after a slot was taken, for fault-injection tests.
    enum class Fault : std::uint8_t {
        None,
        UniformBuffer, ///< The slot's uniform buffer cannot be (re)allocated.
        CommandBuffer, ///< The queue returns no command buffer.
        RenderEncoder, ///< The command buffer returns no render encoder.
    };
    /// Makes the next render() that reaches `fault` fail there (once). Thread-safe.
    void injectFaultForTesting(Fault fault);
    /// Takes up to `count` free slots (waiting up to `timeoutSeconds` for each), as if frames
    /// were stuck on the GPU; returns how many were taken. Thread-safe.
    std::size_t holdSlotsForTesting(std::size_t count, double timeoutSeconds);
    /// Returns the slots taken by holdSlotsForTesting. Thread-safe.
    void releaseHeldSlotsForTesting();

  private:
    struct Impl;
    explicit Compositor(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

} // namespace ve::render
