// A luma waveform of a composited frame: for every column of the frame and every luma level, how many
// of its pixels have that luma. Computed on the GPU from the monitor's RGBA16Float working texture
// (grading decision, section 4: scopes read what the monitors and the export blend), so it shows the
// graded picture as the program monitor shows it, before the output pass.
//
// Two passes, encoded into the caller's command buffer:
//   - encodeAccumulate: clears the counts and runs `ve_waveform_accumulate` over the frame's whole
//     width and `sampleRows` evenly spaced rows (at most `maxSampleRows`): each pixel's luma (BT.709
//     weights on its R'G'B', limited to [0, 1]) is counted in its column (the frame's width scaled to
//     `columns`, or fewer chosen per frame) at its level (rounded to `levels` steps: level 0 is black, 0 IRE;
//     the top level is white, 100 IRE). A column therefore counts width / columns pixel columns times
//     sampleRows pixels. The sampled pixels also go into the frame's clipping counters (ScopeStats.h) when
//     given a slot.
//   - encodeDisplay: draws the counts over a render target (`ve_waveform_fragment`): column across,
//     level up, the trace's brightness 1 - exp(-count * gain) with gain 48 / (samples per column), over
//     a graticule every 10 IRE.
// The counts stay in one shared-storage buffer (tests read it after the command buffer completed); frames
// on one command queue run in order, so the next frame's clear never overtakes this frame's display.
//
// Threading: one thread at a time (the program monitor's render thread); create on any thread.

#pragma once

#include "../Media/Result.h"
#include "Compositor.h"
#include "ScopeStats.h"

#import <Metal/Metal.h>

#include <cstdint>
#include <memory>
#include <utility>
#include <vector>

namespace ve::render {

struct WaveformSettings {
    std::uint32_t columns = 512;      // waveform columns across the frame (at most, when chosen per frame)
    std::uint32_t levels = 256;       // luma levels from 0 to 100 IRE
    std::uint32_t maxSampleRows = 360; // rows of the frame sampled at most
};

class LumaWaveform {
  public:
    // Loads the engine's shaders on `device`. Fails (with the reason) when a pipeline or the buffer
    // cannot be made, or a setting is 0 (or above 4096).
    static media::Result<std::unique_ptr<LumaWaveform>> create(id<MTLDevice> device, WaveformSettings settings = {});

    ~LumaWaveform();
    LumaWaveform(const LumaWaveform &) = delete;
    LumaWaveform &operator=(const LumaWaveform &) = delete;

    // Clears the counts and counts the pixels of `frame` (texels of `working`, clipped to it) into them.
    // Returns false, encoding nothing, for an empty frame or a texture of another device.
    bool encodeAccumulate(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> working, const PixelRect &frame);
    // The same in `columns` columns across the frame (1 to settings().columns; 0 means settings().columns),
    // and the sampled pixels into `stats`'s clipping counters when given (ScopeStatsRing::begin with the
    // frame's width times sampleRowsFor(frame) samples). A scope view sizes its columns to its own width,
    // so each of its pixel columns shows one waveform column.
    bool encodeAccumulate(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> working, const PixelRect &frame,
                          std::uint32_t columns, const ScopeStatsSlot *stats);
    // The rows an accumulate of `frame` (clipped to a width x height texture) samples.
    std::uint32_t sampleRowsFor(const PixelRect &frame, std::int32_t width, std::int32_t height) const;

    // Draws the counts over the whole of `target` (a render target; any colour-renderable format).
    // Returns false when nothing was accumulated yet or the pipeline for the format cannot be made.
    bool encodeDisplay(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> target);

    id<MTLDevice> device() const;
    const WaveformSettings &settings() const;
    // The counts, `levels` rows of columns() (row L holds level L) at the start of the buffer, as of the last
    // completed frame (the buffer holds settings().columns x levels counters; with fewer columns its tail is
    // unused).
    std::vector<std::uint32_t> countsSnapshot() const;
    // The columns the last accumulate counted in (settings().columns before the first).
    std::uint32_t columns() const;
    // Pixels each column counted in the last accumulate (0 before the first).
    std::uint64_t samplesPerColumn() const;
    // Rows the last accumulate sampled.
    std::uint32_t sampleRows() const;

  private:
    struct Impl;
    explicit LumaWaveform(std::unique_ptr<Impl> impl);
    std::unique_ptr<Impl> impl_;
};

} // namespace ve::render
