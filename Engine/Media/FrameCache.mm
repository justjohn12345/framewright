#include "FrameCache.h"

#include "../Model/TimeUtil.h"

#include <IOSurface/IOSurfaceRef.h>

#include <limits>
#include <list>
#include <map>
#include <mutex>
#include <utility>

namespace ve::media {

namespace {

struct Key {
    AssetId asset;
    int64_t index = 0;
    friend auto operator<=>(const Key &, const Key &) = default;
};

} // namespace

namespace {

/// Holds the cache mutex; on destruction hands the removed buffers to `dead` (declared by the
/// caller before this object, so they are released after the mutex is unlocked).
class Locked {
  public:
    Locked(FrameCache::State &state, std::vector<PixelBuffer> &dead);
    ~Locked();

  private:
    FrameCache::State &state_;
    std::vector<PixelBuffer> &dead_;
    std::unique_lock<std::mutex> lock_;
};

} // namespace

struct FrameCache::State {
    struct Entry {
        Frame frame;
        uint64_t serial = 0;
        int pins = 0;
        std::list<Key>::iterator lru; ///< Position in `lru` (front = most recently used).
    };

    mutable std::mutex mutex;
    std::map<Key, Entry> entries;
    std::list<Key> lru;
    size_t budget = kDefaultBudgetBytes;
    uint64_t nextSerial = 1;
    Stats stats;
    /// Buffers of removed entries, released after the mutex is dropped (destroying an
    /// IOSurface is a kernel call; keep it out of the critical section the render thread uses).
    std::vector<PixelBuffer> graveyard;

    // All below: mutex held.

    std::map<Key, Entry>::iterator covering(AssetId asset, int64_t index) {
        auto it = entries.upper_bound(Key{asset, index});
        if (it == entries.begin()) {
            return entries.end();
        }
        --it;
        if (it->first.asset != asset) {
            return entries.end();
        }
        const Frame &f = it->second.frame;
        // index - f.index < span, written to avoid overflow for huge spans.
        if (index - f.index >= f.span) {
            return entries.end();
        }
        return it;
    }

    void touch(Entry &e) { lru.splice(lru.begin(), lru, e.lru); }

    void erase(std::map<Key, Entry>::iterator it) {
        Entry &e = it->second;
        stats.bytes -= e.frame.bytes;
        --stats.count;
        if (e.pins > 0) {
            stats.pinnedBytes -= e.frame.bytes;
            --stats.pinnedCount;
        }
        graveyard.push_back(std::move(e.frame.image));
        lru.erase(e.lru);
        entries.erase(it);
    }

    void evictTo(size_t limit) {
        auto pos = lru.end();
        while (stats.bytes > limit && pos != lru.begin()) {
            --pos;
            auto it = entries.find(*pos);
            if (it->second.pins > 0) {
                continue;
            }
            auto next = std::next(pos); // erase() invalidates `pos` only.
            erase(it);
            ++stats.evictions;
            pos = next;
        }
    }

    void unpin(AssetId asset, int64_t index, uint64_t serial) {
        auto it = entries.find(Key{asset, index});
        if (it == entries.end() || it->second.serial != serial || it->second.pins == 0) {
            return; // Purged or replaced meanwhile.
        }
        if (--it->second.pins == 0) {
            stats.pinnedBytes -= it->second.frame.bytes;
            --stats.pinnedCount;
            evictTo(budget);
        }
    }
};

namespace {

Locked::Locked(FrameCache::State &state, std::vector<PixelBuffer> &dead)
    : state_(state), dead_(dead), lock_(state.mutex) {}

Locked::~Locked() {
    dead_.swap(state_.graveyard);
}

} // namespace

FrameCache::FrameCache(size_t budgetBytes) : state_(std::make_shared<State>()) {
    state_->budget = budgetBytes;
    state_->stats.budgetBytes = budgetBytes;
}

FrameCache::~FrameCache() = default;

// MARK: - Keys

int64_t FrameCache::frameIndex(CMTime t, CMTime frameDuration) {
    if (!isPositive(frameDuration) || !isNumeric(t)) {
        return 0;
    }
    return frameIndexAt(t, frameDuration, SnapMode::Round);
}

int64_t FrameCache::frameSpan(CMTime duration, CMTime frameDuration) {
    if (!isPositive(frameDuration) || !isNumeric(duration) || duration <= kCMTimeZero) {
        return 1;
    }
    const int64_t n = frameIndexAt(duration, frameDuration, SnapMode::Round);
    return n < 1 ? 1 : n;
}

size_t FrameCache::bufferBytes(CVPixelBufferRef buffer) {
    if (buffer == nullptr) {
        return 0;
    }
    if (IOSurfaceRef surface = CVPixelBufferGetIOSurface(buffer)) {
        const size_t alloc = IOSurfaceGetAllocSize(surface);
        if (alloc > 0) {
            return alloc;
        }
    }
    const size_t dataSize = CVPixelBufferGetDataSize(buffer);
    if (dataSize > 0) {
        return dataSize;
    }
    size_t sum = 0;
    const size_t planes = CVPixelBufferGetPlaneCount(buffer);
    if (planes == 0) {
        sum = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer);
    }
    for (size_t p = 0; p < planes; ++p) {
        sum += CVPixelBufferGetBytesPerRowOfPlane(buffer, p) * CVPixelBufferGetHeightOfPlane(buffer, p);
    }
    return sum;
}

// MARK: - Insert and look up

bool FrameCache::put(AssetId asset, int64_t index, PixelBuffer image, int64_t span, CMTime pts, CMTime duration) {
    if (!image || span < 1) {
        return false;
    }
    const size_t bytes = bufferBytes(image.get());
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    if (bytes > s.budget) {
        return false;
    }
    const Key key{asset, index};
    auto it = s.entries.find(key);
    if (it != s.entries.end()) {
        if (it->second.pins > 0 || it->second.frame.image == image) {
            s.touch(it->second);
            return true;
        }
        s.erase(it);
    }
    State::Entry entry;
    entry.frame.image = std::move(image);
    entry.frame.index = index;
    entry.frame.span = span;
    entry.frame.pts = pts;
    entry.frame.duration = duration;
    entry.frame.bytes = bytes;
    entry.serial = s.nextSerial++;
    s.lru.push_front(key);
    entry.lru = s.lru.begin();
    s.entries.emplace(key, std::move(entry));
    s.stats.bytes += bytes;
    ++s.stats.count;
    ++s.stats.insertions;
    s.evictTo(s.budget);
    return true;
}

bool FrameCache::put(AssetId asset, const VideoFrame &frame, CMTime frameDuration) {
    return put(asset, frameIndex(frame.pts, frameDuration), frame.image, frameSpan(frame.duration, frameDuration),
               frame.pts, frame.duration);
}

std::optional<FrameCache::Frame> FrameCache::get(AssetId asset, int64_t index) {
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    auto it = s.covering(asset, index);
    if (it == s.entries.end()) {
        ++s.stats.misses;
        return std::nullopt;
    }
    ++s.stats.hits;
    s.touch(it->second);
    return it->second.frame;
}

FrameCache::PinnedFrame FrameCache::acquire(AssetId asset, int64_t index) {
    PinnedFrame pinned;
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    auto it = s.covering(asset, index);
    if (it == s.entries.end()) {
        ++s.stats.misses;
        return pinned;
    }
    ++s.stats.hits;
    State::Entry &e = it->second;
    s.touch(e);
    if (e.pins++ == 0) {
        s.stats.pinnedBytes += e.frame.bytes;
        ++s.stats.pinnedCount;
    }
    pinned.state_ = state_;
    pinned.asset_ = asset;
    pinned.serial_ = e.serial;
    pinned.frame_ = e.frame;
    return pinned;
}

bool FrameCache::contains(AssetId asset, int64_t index) const {
    State &s = *state_;
    std::lock_guard<std::mutex> lock(s.mutex);
    return s.covering(asset, index) != s.entries.end();
}

std::vector<int64_t> FrameCache::indices(AssetId asset) const {
    State &s = *state_;
    std::lock_guard<std::mutex> lock(s.mutex);
    std::vector<int64_t> out;
    for (auto it = s.entries.lower_bound(Key{asset, std::numeric_limits<int64_t>::min()});
         it != s.entries.end() && it->first.asset == asset; ++it) {
        out.push_back(it->first.index);
    }
    return out;
}

// MARK: - Removal and budget

void FrameCache::purge(AssetId asset) {
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    auto it = s.entries.lower_bound(Key{asset, std::numeric_limits<int64_t>::min()});
    while (it != s.entries.end() && it->first.asset == asset) {
        auto next = std::next(it);
        s.erase(it);
        it = next;
    }
}

void FrameCache::purgeAll() {
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    for (auto &[key, entry] : s.entries) {
        s.graveyard.push_back(std::move(entry.frame.image));
    }
    s.entries.clear();
    s.lru.clear();
    s.stats.bytes = 0;
    s.stats.count = 0;
    s.stats.pinnedBytes = 0;
    s.stats.pinnedCount = 0;
}

void FrameCache::trimTo(size_t bytes) {
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    s.evictTo(bytes);
}

void FrameCache::setBudget(size_t bytes) {
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    s.budget = bytes;
    s.stats.budgetBytes = bytes;
    s.evictTo(bytes);
}

size_t FrameCache::budget() const {
    std::lock_guard<std::mutex> lock(state_->mutex);
    return state_->budget;
}

void FrameCache::handleMemoryPressure(MemoryPressure level) {
    switch (level) {
    case MemoryPressure::Normal:
        return;
    case MemoryPressure::Warning:
        trimTo(budget() / 2);
        return;
    case MemoryPressure::Critical:
        trimTo(0);
        return;
    }
}

FrameCache::Stats FrameCache::stats() const {
    std::lock_guard<std::mutex> lock(state_->mutex);
    return state_->stats;
}

void FrameCache::resetStats() {
    std::lock_guard<std::mutex> lock(state_->mutex);
    Stats &st = state_->stats;
    st.hits = 0;
    st.misses = 0;
    st.insertions = 0;
    st.evictions = 0;
}

// MARK: - PinnedFrame

FrameCache::PinnedFrame::~PinnedFrame() {
    release();
}

FrameCache::PinnedFrame::PinnedFrame(PinnedFrame &&other) noexcept
    : state_(std::move(other.state_)), asset_(other.asset_), serial_(std::exchange(other.serial_, 0)),
      frame_(std::move(other.frame_)) {
    other.state_.reset();
}

FrameCache::PinnedFrame &FrameCache::PinnedFrame::operator=(PinnedFrame &&other) noexcept {
    if (this != &other) {
        release();
        state_ = std::move(other.state_);
        other.state_.reset();
        asset_ = other.asset_;
        serial_ = std::exchange(other.serial_, 0);
        frame_ = std::move(other.frame_);
    }
    return *this;
}

void FrameCache::PinnedFrame::release() noexcept {
    if (serial_ == 0) {
        return;
    }
    if (auto state = state_.lock()) {
        std::vector<PixelBuffer> dead;
        Locked lock(*state, dead);
        state->unpin(asset_, frame_.index, serial_);
    }
    state_.reset();
    serial_ = 0;
}

} // namespace ve::media
