// The clipping counters of a scope's frame: how many of the samples a scope's accumulate kernel read have a
// channel at or above white, and how many a channel at or below black (within kVEScopeClipTolerance,
// ShaderTypes.h), as a photo app's clipping warning counts them. Every scope counts them on the samples it
// reads anyway (countClipping in Shaders.metal), so the clipping indicator costs no read of its own.
//
// The counters of one frame live in a slot of a small shared ring: `begin` takes the next slot, encodes its
// clearing into the frame's command buffer and returns it for the scope's kernel; `read` reads it back on
// the CPU once that command buffer has completed. A slot is reused kSlots frames later; the read is a
// sequence-lock read (the slot's generation before and after the copy), so a read that a later frame's reuse
// overtook reports nothing instead of the later frame's counts. A program view has at most three frames in
// flight (the compositor's slots), far below kSlots.
//
// Threading: `begin` on one thread at a time (the render thread); `read` on any thread.

#pragma once

#include "../Media/Result.h"
#include "Compositor.h"

#import <Metal/Metal.h>

#include <array>
#include <atomic>
#include <cstdint>
#include <memory>
#include <optional>

namespace ve::render {

/// A frame's clipping counts.
struct ClipStats {
    std::uint64_t samples = 0; // samples the scope read
    std::uint64_t white = 0;   // of which with a channel at or above white
    std::uint64_t black = 0;   // of which with a channel at or below black

    double whiteFraction() const { return samples == 0 ? 0.0 : double(white) / double(samples); }
    double blackFraction() const { return samples == 0 ? 0.0 : double(black) / double(samples); }
    friend bool operator==(const ClipStats &, const ClipStats &) = default;
};

/// Where a frame's counters are: bind `buffer` at `offset` as the kernel's VEBufferIndexScopeStats.
struct ScopeStatsSlot {
    id<MTLBuffer> buffer = nil;
    NSUInteger offset = 0;
    std::uint64_t generation = 0; // the frame's number in the ring (from 1)
    std::uint64_t samples = 0;
    std::size_t index = 0;
};

class ScopeStatsRing {
  public:
    static constexpr std::size_t kSlots = 8;
    /// Bytes between slots (the counters are two uints; offsets stay aligned for any binding).
    static constexpr NSUInteger kSlotStride = 256;

    static media::Result<std::unique_ptr<ScopeStatsRing>> create(id<MTLDevice> device);

    ScopeStatsRing(const ScopeStatsRing &) = delete;
    ScopeStatsRing &operator=(const ScopeStatsRing &) = delete;

    /// The next slot, for a frame that reads `samples` samples: its counters' clearing is encoded into
    /// `commandBuffer` (a blit), before whatever the caller encodes next.
    ScopeStatsSlot begin(id<MTLCommandBuffer> commandBuffer, std::uint64_t samples);

    /// The counts of `slot`'s frame, once its command buffer has completed; nullopt when the slot has been
    /// reused by a later frame since (the counts are gone).
    std::optional<ClipStats> read(const ScopeStatsSlot &slot) const;

  private:
    explicit ScopeStatsRing(id<MTLBuffer> buffer);
    id<MTLBuffer> buffer_;
    std::uint64_t nextGeneration_ = 1; // begin's thread only
    std::array<std::atomic<std::uint64_t>, kSlots> generations_{};
};

/// The part of a scope's frame `r` inside its width x height working texture (empty when none of it is):
/// what every scope counts.
PixelRect clipToTexture(const PixelRect &r, std::int32_t width, std::int32_t height);

} // namespace ve::render
