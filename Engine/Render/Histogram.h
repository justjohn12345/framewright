// A histogram of a composited frame: for each of R, G, B and luma, how many of the frame's pixels have each
// level. Computed on the GPU from the monitor's RGBA16Float working texture, as the luma waveform is
// (LumaWaveform.h), so it shows the graded picture the program monitor shows, letterbox bars left out.
//
// Three passes, encoded into the caller's command buffer:
//   - encodeAccumulate: clears the counts and runs `ve_histogram_accumulate` over every pixel of the frame
//     (in tiles of kVEHistogramTileSide pixels, each counted in threadgroup memory first): each channel of
//     the R'G'B' the monitor shows, and its BT.709 luma, limited to [0, 1] and rounded to kVEHistogramBins
//     levels (bin 0 black, the last white); also the frame's clipping counters (ScopeStats.h) when given a
//     slot. Then `ve_histogram_finish` finds the tallest bars (with and without the end bins) for the display.
//   - encodeDisplay: draws the counts over a render target in a HistogramStyle (`ve_histogram_fragment`):
//     level across, samples up, scaled so the tallest bar between the end bins fills the height (a spike of
//     clipped black or white at an end reaches the top without flattening the rest).
// The counts stay in one shared-storage buffer (tests read it after the command buffer completed); frames on
// one command queue run in order, so the next frame's clear never overtakes this frame's display.
//
// Threading: one thread at a time (the program monitor's render thread); create on any thread.

#pragma once

#include "../Media/Result.h"
#include "Compositor.h"
#include "ScopeStats.h"
#include "ShaderTypes.h"

#import <Metal/Metal.h>

#include <array>
#include <cstdint>
#include <memory>
#include <vector>

namespace ve::render {

/// How the histogram is drawn (VEHistogramUniforms::style; the public VEHistogramStyle).
enum class HistogramStyle : std::uint32_t {
    RGBAndLuma = 0, // R, G and B overlaid (overlaps show their mixtures), the luma bars' tops in white
    Luma = 1,       // the luma bars only
    Parade = 2,     // R, G and B side by side
};

/// The channels of a histogram's counts, in their order.
enum class HistogramChannel : std::uint32_t { Red = 0, Green = 1, Blue = 2, Luma = 3 };

class Histogram {
  public:
    static constexpr std::uint32_t kBins = kVEHistogramBins;

    /// Loads the engine's shaders on `device`. Fails (with the reason) when a pipeline or a buffer cannot
    /// be made.
    static media::Result<std::unique_ptr<Histogram>> create(id<MTLDevice> device);

    ~Histogram();
    Histogram(const Histogram &) = delete;
    Histogram &operator=(const Histogram &) = delete;

    /// Clears the counts and counts every pixel of `frame` (texels of `working`, clipped to it), and
    /// into `stats`'s counters when given (ScopeStatsRing::begin with frame width x height samples).
    /// Returns false, encoding nothing, for an empty frame or a texture of another device.
    bool encodeAccumulate(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> working, const PixelRect &frame,
                          const ScopeStatsSlot *stats = nullptr);

    /// Draws the counts over the whole of `target` (a render target; any colour-renderable format) in
    /// `style`. Returns false when nothing was accumulated yet or the pipeline for the format cannot be made.
    bool encodeDisplay(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> target, HistogramStyle style);

    id<MTLDevice> device() const;
    /// The counts of `channel` (kBins values, bin b the samples at level b / (kBins - 1)), as of the last
    /// completed frame.
    std::array<std::uint32_t, kBins> counts(HistogramChannel channel) const;
    /// The tallest red, green or blue bar and the tallest luma bar between the end bins, then over every
    /// bin (the finish kernel's results), as of the last completed frame.
    std::array<std::uint32_t, 4> maxima() const;
    /// Pixels the last accumulate counted (its frame's width times height; 0 before the first).
    std::uint64_t samples() const;
    /// The frame's rectangle the last accumulate counted, clipped to its texture.
    PixelRect countedFrame() const;

  private:
    struct Impl;
    explicit Histogram(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

} // namespace ve::render
