// FrameCache: byte-bounded cache of decoded frames per asset, answering "which frame shows at
// time t".
//
// Keys and lookups. Entries are stored per asset by their exact pts and cover their display
// interval [pts, pts + duration) (VideoFrame::duration: decoders report real display intervals,
// see Interfaces.h). A lookup by time returns the entry whose interval contains t: the same
// rule IVideoDecoder::seek() follows, so a warm lookup returns the frame a cold decode would
// (also for variable-frame-rate and off-grid sources). An entry may additionally cover a gap
// before it (`coverFrom`): the decoder returns the first frame after t when t lies before the
// first frame, and the decode pool records that so the cache agrees.
//
// Slot lookups. Slot n of an asset is [n * frameDuration, (n + 1) * frameDuration) with
// frameDuration = the asset's nominal MediaAsset::frameDuration, and frameIndex(t) =
// floor(t / frameDuration) is the slot containing t. get/acquire/contains(asset, n) answer with
// the entry containing the slot's start time n * frameDuration: exact for sources on the grid,
// and on any source the frame a decoder returns for seek(n * frameDuration). The frame duration
// used is the one the asset's frames were put with. Stills use slot 0 (frameIndex() returns 0 for
// an invalid frame duration), and their entry (pts 0, infinite duration) answers every time.
// Frame::index / Frame::span are the slots an entry starts in and covers (frameIndex(pts +
// duration) - frameIndex(pts)), for diagnostics. Pictures are not looked up by slot: playback and
// export use the time lookup at playback::pictureTimeFor (on a variable-frame-rate source a slot's
// start can lie in the frame before the one under the source time).
//
// Budget. bytes = the frame's real allocation (IOSurfaceGetAllocSize for IOSurface-backed
// buffers, else CVPixelBufferGetDataSize, else the sum of plane sizes). Inserting evicts until
// the total is within the budget (default 512 MB). Eviction order ("distance from target"):
// the decode pool declares where playback is (setFocus: per asset, the source time under the
// playhead and the play direction). Unpinned entries are evicted
//   1. behind the playhead of every focus on their asset (already shown), farthest behind first;
//   2. of assets without a focus, least recently used first;
//   3. ahead of a playhead, farthest ahead first,
// so the frame under the playhead and the next ones go last. Pure LRU would evict the playhead
// frame first whenever a lookahead window is larger than the budget (frames are inserted in
// playback order). Without any focus (paused, scrubbing) the order is plain LRU.
//
// Focus clients. Several decode pools share one cache (the program monitor's and the source
// monitor's). Each declares its own focus under its own FocusClient id (setFocus(client, ...));
// the eviction order uses the union of every client's focus, so one pool's targets never make
// another pool's playhead look unwatched. setFocus(focus) without a client is client 0.
//
// Media epochs (why ids alone are not enough). Asset ids restart in every project, so after an
// Open or a New the same id can name another file. The cache is keyed by (epoch, asset): its
// owner starts a new epoch whenever ids start naming other media (beginEpoch()), which drops
// every entry and every client's focus, and from then on put(epoch, ...) refuses frames
// decoded for an earlier epoch. Producers (the decode pools) tag every frame with the epoch its
// asset was registered in, so a decode that was in flight when the project changed can never
// publish the previous project's picture under a reused id. Lookups always see the current
// epoch only (entries of earlier epochs no longer exist). put() without an epoch inserts into
// the current epoch (single-project users and tests).
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
// Threading: all methods are thread-safe (one internal mutex, held only for map updates and
// the eviction scan: no I/O, no callbacks, no Objective-C messaging under it). PinnedFrame may
// be destroyed on any thread and may outlive the FrameCache.
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
        int64_t index = 0; ///< Slot containing pts (frameIndex(pts)).
        int64_t span = 1;  ///< Slots whose start lies in the frame: frameIndex(end) - frameIndex(pts).
        CMTime pts = kCMTimeInvalid;
        CMTime duration = kCMTimeInvalid;
        /// Earliest time the entry answers (pts, or earlier when it also covers a gap before it).
        CMTime coverFrom = kCMTimeInvalid;
        size_t bytes = 0;
    };

    /// Where playback of one asset is, for the eviction order (see the header comment).
    struct Focus {
        AssetId asset;
        CMTime time = kCMTimeInvalid; ///< Source time under the playhead.
        bool forward = true;          ///< Play direction.
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

    /// Generation of asset ids the cache holds (see header comment).
    using Epoch = uint64_t;
    /// Identifies one client's focus (see header comment).
    using FocusClient = uint64_t;
    /// A new client id, unique in the process (never 0, the default client).
    static FocusClient makeFocusClient();

    explicit FrameCache(size_t budgetBytes = kDefaultBudgetBytes);
    ~FrameCache();
    FrameCache(const FrameCache &) = delete;
    FrameCache &operator=(const FrameCache &) = delete;

    // MARK: Slots

    /// Slot containing `t`: floor(t / frameDuration); 0 when frameDuration is not positive
    /// (stills) or t is not numeric.
    static int64_t frameIndex(CMTime t, CMTime frameDuration);
    /// Slots whose start lies in [pts, pts + duration): frameIndex(pts + duration) -
    /// frameIndex(pts); 1 for stills, infinite and non-numeric durations.
    static int64_t frameSpan(CMTime pts, CMTime duration, CMTime frameDuration);
    /// Memory held by a pixel buffer (see header comment).
    static size_t bufferBytes(CVPixelBufferRef buffer);

    // MARK: Epochs

    /// The current epoch (starts at 1).
    Epoch epoch() const;
    /// Starts a new epoch: removes every entry (like purgeAll()) and every client's focus, and
    /// refuses puts tagged with an earlier epoch from now on. Returns the new epoch.
    Epoch beginEpoch();

    // MARK: Insert and look up

    /// Inserts a decoded frame of `asset`. `frameDuration` is the asset's nominal frame duration
    /// (invalid for stills) and defines its slots. A frame without a numeric duration lasts one
    /// frameDuration (a still: forever). `coverFrom` (<= pts) extends the entry backwards over a
    /// gap in which no frame is shown (see header comment). A different buffer at the same pts
    /// replaces the old entry unless that entry is pinned (then the pinned entry is kept and only
    /// marked recently used). Putting the frame at an existing entry's pts again with a later end
    /// (e.g. an infinite duration: the last frame held past the end of its stream, DecodePool.h)
    /// extends the kept entry to that end. Returns false if the frame was not retained: an empty
    /// image, a non-numeric pts, or a frame larger than the whole budget.
    bool put(AssetId asset, const VideoFrame &frame, CMTime frameDuration, CMTime coverFrom = kCMTimeInvalid);
    bool put(AssetId asset, PixelBuffer image, CMTime pts, CMTime duration, CMTime frameDuration,
             CMTime coverFrom = kCMTimeInvalid);
    /// Like put(), for a frame decoded for `epoch`: refused (false, nothing changes) unless
    /// `epoch` is the current epoch. The check and the insertion are atomic with beginEpoch().
    bool put(Epoch epoch, AssetId asset, const VideoFrame &frame, CMTime frameDuration,
             CMTime coverFrom = kCMTimeInvalid);

    /// The entry showing at time `t` (marked recently used; counted as hit or miss).
    std::optional<Frame> get(AssetId asset, CMTime t);
    /// The entry showing at the start of slot `index` (see header comment).
    std::optional<Frame> get(AssetId asset, int64_t index);
    /// Like get() but pins the entry (see header comment). An empty PinnedFrame on a miss.
    PinnedFrame acquire(AssetId asset, CMTime t);
    PinnedFrame acquire(AssetId asset, int64_t index);

    /// Whether an entry answers `t` / slot `index`. Does not touch LRU order or statistics.
    bool contains(AssetId asset, CMTime t) const;
    bool contains(AssetId asset, int64_t index) const;
    /// Frame::index of every entry of `asset`, in pts order (diagnostics and tests).
    std::vector<int64_t> indices(AssetId asset) const;
    /// pts of every entry of `asset`, ascending (diagnostics and tests).
    std::vector<CMTime> presentationTimes(AssetId asset) const;

    // MARK: Eviction order, removal and budget

    /// Replaces `client`'s playhead positions (empty: the client has none). The eviction order
    /// uses the union of every client's focus (none at all = plain LRU). Does not evict by itself.
    void setFocus(FocusClient client, std::vector<Focus> focus);
    /// setFocus(0, focus): the default client.
    void setFocus(std::vector<Focus> focus);
    /// Removes every entry of `asset` (pinned ones included; see header comment).
    void purge(AssetId asset);
    void purgeAll();
    /// Evicts unpinned entries (in eviction order) until bytes <= `bytes`.
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
    bool insert(std::optional<Epoch> epoch, AssetId asset, PixelBuffer image, CMTime pts, CMTime duration,
                CMTime frameDuration, CMTime coverFrom);

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
