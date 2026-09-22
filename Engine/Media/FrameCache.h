// FrameCache: byte-bounded LRU of decoded frames keyed by (asset, source frame index).
//
// Keys. A frame is stored under the index of the source frame grid (frame n covers
// [n * frameDuration, (n + 1) * frameDuration), frameDuration = the asset's nominal
// MediaAsset::frameDuration) nearest to its pts (TimeUtil frameIndexAt, SnapMode::Round, so
// container timestamps that are a tick off the grid still land on the right slot). Each entry
// also records how many grid slots it covers (`span`, from the frame's own duration), and
// lookups return the entry covering the requested slot: a variable-frame-rate frame lasting
// three nominal frames answers all three indices. Stills use index 0 (frameIndex() returns 0
// for an invalid frame duration).
//
// Budget. bytes = the frame's real allocation (IOSurfaceGetAllocSize for IOSurface-backed
// buffers, else CVPixelBufferGetDataSize, else the sum of plane sizes). Inserting evicts least
// recently used entries until the total is within the budget (default 512 MB).
//
// Pinning (why, and why not a generation counter). PixelBuffer is ref-counted, so eviction can
// never free a buffer someone is still using: correctness does not need pins. What eviction
// CAN do to a frame that is being presented is (a) drop it from the cache while the render
// thread will ask for the same slot again on the next vsync (paused or slow playback, a
// still), turning a hit into a synchronous miss and a flicker to the previous frame, and
// (b) under-count memory: the evicted IOSurface stays resident because the presenter retains
// it, so the cache would believe it freed bytes it did not and let the working set exceed the
// budget. acquire() returns a PinnedFrame (RAII); while any pin on an entry is alive, the entry
// is skipped by eviction, trimTo() and memory pressure (it still counts toward bytes, so the
// cache may temporarily exceed its budget by the pinned bytes, reported in Stats). A
// generation counter ("do not evict entries used in the current or previous generation") was
// rejected: it needs a per-frame tick from the render thread, pins every frame touched in a
// generation rather than the one on screen, and cannot express holders with longer lifetimes
// (an export frame, a thumbnail in flight). Pins are exact and free when unused.
// purge()/purgeAll() remove pinned entries from the index too (their asset is gone or stale);
// the PinnedFrame keeps its buffer alive and releasing it later is a no-op.
//
// Threading: all methods are thread-safe (one internal mutex, held only for map/list updates:
// no I/O, no callbacks, no Objective-C messaging under it). PinnedFrame may be destroyed on any
// thread and may outlive the FrameCache.
#pragma once

#include "../Model/Ids.h"
#include "Interfaces.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <vector>

namespace ve::media {

enum class MemoryPressure {
    Normal,   ///< No action.
    Warning,  ///< Trim to half the budget.
    Critical, ///< Drop everything that is not pinned.
};

class FrameCache {
  public:
    static constexpr size_t kDefaultBudgetBytes = size_t(512) << 20;

    struct Frame {
        PixelBuffer image;
        int64_t index = 0; ///< First grid slot covered.
        int64_t span = 1;  ///< Grid slots covered (>= 1).
        CMTime pts = kCMTimeInvalid;
        CMTime duration = kCMTimeInvalid;
        size_t bytes = 0;
    };

    struct Stats {
        uint64_t hits = 0;
        uint64_t misses = 0;
        uint64_t insertions = 0;
        uint64_t evictions = 0; ///< Entries removed to honour the budget (not purges).
        size_t bytes = 0;
        size_t count = 0;
        size_t pinnedBytes = 0;
        size_t pinnedCount = 0;
        size_t budgetBytes = 0;
    };

    class PinnedFrame;

    explicit FrameCache(size_t budgetBytes = kDefaultBudgetBytes);
    ~FrameCache();
    FrameCache(const FrameCache &) = delete;
    FrameCache &operator=(const FrameCache &) = delete;

    // MARK: Keys

    /// Grid slot nearest to `t` (SnapMode::Round); 0 when frameDuration is not positive
    /// (stills) or t is not numeric.
    static int64_t frameIndex(CMTime t, CMTime frameDuration);
    /// Grid slots covered by a frame of `duration` (rounded, at least 1; 1 for non-numeric or
    /// infinite durations and for stills).
    static int64_t frameSpan(CMTime duration, CMTime frameDuration);
    /// Memory held by a pixel buffer (see header comment).
    static size_t bufferBytes(CVPixelBufferRef buffer);

    // MARK: Insert and look up

    /// Inserts (or refreshes) the frame for slot `index`. A different buffer under the same
    /// slot replaces the old entry unless that entry is pinned (then the pinned entry is kept
    /// and only marked recently used). Returns false if the frame was not retained: an empty
    /// image, span < 1, or a frame larger than the whole budget.
    bool put(AssetId asset, int64_t index, PixelBuffer image, int64_t span = 1, CMTime pts = kCMTimeInvalid,
             CMTime duration = kCMTimeInvalid);
    /// Inserts a decoded frame, deriving index and span from its pts/duration.
    bool put(AssetId asset, const VideoFrame &frame, CMTime frameDuration);

    /// The entry covering slot `index` (marked most recently used; counted as hit or miss).
    std::optional<Frame> get(AssetId asset, int64_t index);
    std::optional<Frame> get(AssetId asset, CMTime t, CMTime frameDuration) {
        return get(asset, frameIndex(t, frameDuration));
    }
    /// Like get() but pins the entry (see header comment). An empty PinnedFrame on a miss.
    PinnedFrame acquire(AssetId asset, int64_t index);

    /// Whether an entry covers slot `index`. Does not touch LRU order or statistics.
    bool contains(AssetId asset, int64_t index) const;
    /// First slots of every entry of `asset`, ascending (diagnostics and tests).
    std::vector<int64_t> indices(AssetId asset) const;

    // MARK: Removal and budget

    /// Removes every entry of `asset` (pinned ones included; see header comment).
    void purge(AssetId asset);
    void purgeAll();
    /// Evicts least recently used unpinned entries until bytes <= `bytes`.
    void trimTo(size_t bytes);
    /// Changes the budget and trims to it.
    void setBudget(size_t bytes);
    size_t budget() const;
    /// Hook for the facade's DISPATCH_SOURCE_TYPE_MEMORYPRESSURE handler.
    void handleMemoryPressure(MemoryPressure level);

    Stats stats() const;
    void resetStats();

    struct State;

  private:
    std::shared_ptr<State> state_;
};

/// Keeps one cache entry from being evicted while alive, and holds its frame. Move-only.
class FrameCache::PinnedFrame {
  public:
    PinnedFrame() = default;
    ~PinnedFrame();
    PinnedFrame(PinnedFrame &&other) noexcept;
    PinnedFrame &operator=(PinnedFrame &&other) noexcept;
    PinnedFrame(const PinnedFrame &) = delete;
    PinnedFrame &operator=(const PinnedFrame &) = delete;

    explicit operator bool() const noexcept { return static_cast<bool>(frame_.image); }
    const Frame &frame() const noexcept { return frame_; }
    const PixelBuffer &image() const noexcept { return frame_.image; }
    /// Unpins now (the destructor does it otherwise). Keeps the frame data.
    void release() noexcept;

  private:
    friend class FrameCache;
    std::weak_ptr<State> state_;
    AssetId asset_;
    uint64_t serial_ = 0;
    Frame frame_;
};

} // namespace ve::media
