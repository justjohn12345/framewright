// A vectorscope of a composited frame: how many of its pixels have each BT.709 chroma (Cb across, Cr up),
// computed on the GPU from the monitor's RGBA16Float working texture as the waveform and the histogram are, so it
// shows the graded picture the program monitor shows, letterbox bars left out.
//
// Two passes, encoded into the caller's command buffer:
//   - encodeAccumulate: clears the counts and runs `ve_vectorscope_accumulate` over every column of up to
//     `maxSampleRows` evenly spaced rows of the frame: each pixel's chroma, from its R'G'B' limited to [0, 1]
//     (Cb = (B' - Y') / 1.8556, Cr = (R' - Y') / 1.5748, each -0.5 to 0.5), is counted in its bin of a
//     kVEVectorscopeBins square grid; also the frame's clipping counters when given a slot.
//   - encodeDisplay: draws the counts in a square centred in the target (`ve_vectorscope_fragment`) over the
//     graticule: the ring at chroma 0.5, the crosshair, boxes at the 75 % colour bars' chroma and the skin tone
//     line (kSkinToneDegrees from the Cb axis, toward red and yellow: where faces of every complexion fall).
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

class Vectorscope {
  public:
    static constexpr std::uint32_t kBins = kVEVectorscopeBins;
    static constexpr std::uint32_t kMaxSampleRows = 540;
    // The skin tone line's angle from the +Cb axis, counterclockwise (toward +Cr), in degrees: the usual
    // "I line" of a BT.709 vectorscope (between red and yellow).
    static constexpr double kSkinToneDegrees = 123.0;

    static media::Result<std::unique_ptr<Vectorscope>> create(id<MTLDevice> device);

    ~Vectorscope();
    Vectorscope(const Vectorscope &) = delete;
    Vectorscope &operator=(const Vectorscope &) = delete;

    // Clears the counts and counts the sampled pixels of `frame` (texels of `working`, clipped to it), and into
    // `stats`'s counters when given (ScopeStatsRing::begin with frame width x sampleRowsFor(frame) samples).
    // Returns false, encoding nothing, for an empty frame or a texture of another device.
    bool encodeAccumulate(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> working, const PixelRect &frame,
                          const ScopeStatsSlot *stats = nullptr);
    // Draws the counts over the whole of `target`. Returns false when nothing was accumulated yet or the
    // pipeline for the format cannot be made.
    bool encodeDisplay(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> target);

    // The rows an accumulate of `frame` (clipped to a width x height texture) samples.
    static std::uint32_t sampleRowsFor(const PixelRect &frame, std::int32_t width, std::int32_t height);
    // The bin (column, row) of chroma (cb, cr), as the kernel rounds it.
    static std::array<std::uint32_t, 2> binOf(double cb, double cr);
    // The BT.709 chroma (Cb, Cr) of R'G'B' `rgb`.
    static std::array<double, 2> chromaOf(const std::array<double, 3> &rgb);
    // The graticule's targets: the 75 % colour bars' chroma, red, magenta, blue, cyan, green, yellow.
    static std::array<std::array<double, 2>, 6> barTargets();

    id<MTLDevice> device() const;
    // The counts, kBins rows of kBins (row r: Cr bin r from the bottom), as of the last completed frame.
    std::vector<std::uint32_t> countsSnapshot() const;
    // Samples the last accumulate counted.
    std::uint64_t samples() const;

  private:
    struct Impl;
    explicit Vectorscope(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

} // namespace ve::render
