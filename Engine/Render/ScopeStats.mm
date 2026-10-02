#include "ScopeStats.h"

#include <algorithm>
#include <cstring>

namespace ve::render {

media::Result<std::unique_ptr<ScopeStatsRing>> ScopeStatsRing::create(id<MTLDevice> device) {
    if (device == nil) {
        return media::makeError(media::MediaErrorCode::Internal, "ScopeStatsRing: no Metal device");
    }
    id<MTLBuffer> buffer = [device newBufferWithLength:kSlots * kSlotStride options:MTLResourceStorageModeShared];
    if (buffer == nil) {
        return media::makeError(media::MediaErrorCode::Internal, "ScopeStatsRing: cannot allocate the counters");
    }
    buffer.label = @"Framewright scope clipping counters";
    std::memset(buffer.contents, 0, buffer.length);
    return std::unique_ptr<ScopeStatsRing>(new ScopeStatsRing(buffer));
}

ScopeStatsRing::ScopeStatsRing(id<MTLBuffer> buffer) : buffer_(buffer) {}

ScopeStatsSlot ScopeStatsRing::begin(id<MTLCommandBuffer> commandBuffer, std::uint64_t samples) {
    ScopeStatsSlot slot;
    slot.generation = nextGeneration_++;
    slot.index = std::size_t(slot.generation % kSlots);
    slot.offset = NSUInteger(slot.index) * kSlotStride;
    slot.buffer = buffer_;
    slot.samples = samples;
    // Published before the frame is committed, so a reader of the slot's previous frame sees the change
    // before this frame's GPU work can touch the counters.
    generations_[slot.index].store(slot.generation, std::memory_order_seq_cst);
    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    blit.label = @"Framewright scope clipping counters clear";
    [blit fillBuffer:buffer_ range:NSMakeRange(slot.offset, 2 * sizeof(std::uint32_t)) value:0];
    [blit endEncoding];
    return slot;
}

std::optional<ClipStats> ScopeStatsRing::read(const ScopeStatsSlot &slot) const {
    if (slot.buffer != buffer_ || slot.index >= kSlots) {
        return std::nullopt;
    }
    const std::atomic<std::uint64_t> &generation = generations_[slot.index];
    if (generation.load(std::memory_order_seq_cst) != slot.generation) {
        return std::nullopt;
    }
    std::uint32_t counters[2];
    std::memcpy(counters, static_cast<const std::uint8_t *>(buffer_.contents) + slot.offset, sizeof counters);
    std::atomic_thread_fence(std::memory_order_acquire); // the copy above happens before the check below
    if (generation.load(std::memory_order_seq_cst) != slot.generation) {
        return std::nullopt;
    }
    return ClipStats{slot.samples, counters[0], counters[1]};
}

PixelRect clipToTexture(const PixelRect &r, std::int32_t width, std::int32_t height) {
    const std::int64_t x0 = std::max<std::int64_t>(0, r.x);
    const std::int64_t y0 = std::max<std::int64_t>(0, r.y);
    const std::int64_t x1 = std::min<std::int64_t>(width, std::int64_t(r.x) + r.width);
    const std::int64_t y1 = std::min<std::int64_t>(height, std::int64_t(r.y) + r.height);
    if (x1 <= x0 || y1 <= y0) {
        return PixelRect{};
    }
    return PixelRect{std::int32_t(x0), std::int32_t(y0), std::int32_t(x1 - x0), std::int32_t(y1 - y0)};
}

} // namespace ve::render
