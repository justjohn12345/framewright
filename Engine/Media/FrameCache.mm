#include "FrameCache.h"

#include "../Model/TimeUtil.h"

#include <IOSurface/IOSurfaceRef.h>

#include <atomic>
#include <limits>
#include <map>
#include <mutex>
#include <utility>

namespace ve::media {

namespace {

/// Orders entries of one asset by exact presentation time (any timescale).
struct TimeKey {
    CMTime time;
    friend bool operator<(const TimeKey &a, const TimeKey &b) { return CMTimeCompare(a.time, b.time) < 0; }
};

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

double seconds(CMTime t) {
    return CMTimeGetSeconds(t);
}

} // namespace

struct FrameCache::State {
    struct Entry {
        Frame frame;
        CMTime end = kCMTimeInvalid; ///< pts + duration (+infinity for stills).
        uint64_t serial = 0;
        int pins = 0;
        uint64_t lastUse = 0;
    };
    using Entries = std::map<TimeKey, Entry>;
    struct Asset {
        CMTime frameDuration = kCMTimeInvalid; ///< Of the most recent put: defines the slots.
        Entries entries;
    };

    mutable std::mutex mutex;
    std::map<AssetId, Asset> assets;
    size_t budget = kDefaultBudgetBytes;
    uint64_t nextSerial = 1;
    uint64_t useTick = 0;
    Stats stats;
    Epoch epoch = 1;
    std::map<FocusClient, std::vector<Focus>> focusByClient;
    std::vector<Focus> focus; ///< Union of focusByClient (what rank() uses).
    /// Buffers of removed entries, released after the mutex is dropped (destroying an
    /// IOSurface is a kernel call; keep it out of the critical section the render thread uses).
    std::vector<PixelBuffer> graveyard;

    // All below: mutex held.

    /// The entry showing at `t` in `a`: the last one starting at or before t if t is inside
    /// it, else the next one if it covers a gap containing t.
    Entry *find(Asset &a, CMTime t) {
        if (!CMTIME_IS_NUMERIC(t)) {
            return nullptr;
        }
        auto it = a.entries.upper_bound(TimeKey{t});
        if (it != a.entries.begin()) {
            Entry &prev = std::prev(it)->second;
            if (CMTimeCompare(t, prev.end) < 0) {
                return &prev;
            }
        }
        if (it != a.entries.end() && CMTimeCompare(it->second.frame.coverFrom, t) <= 0) {
            return &it->second;
        }
        return nullptr;
    }

    Entry *find(AssetId asset, CMTime t) {
        auto it = assets.find(asset);
        return it == assets.end() ? nullptr : find(it->second, t);
    }

    /// Start time of slot `index` of `asset` (0 for stills or before any frame was put).
    CMTime slotStart(AssetId asset, int64_t index) const {
        auto it = assets.find(asset);
        if (it == assets.end() || !isPositive(it->second.frameDuration)) {
            return kCMTimeZero;
        }
        return timeForFrame(index, it->second.frameDuration);
    }

    Entry *findSlot(AssetId asset, int64_t index) { return find(asset, slotStart(asset, index)); }

    void touch(Entry &e) { e.lastUse = ++useTick; }

    void erase(AssetId asset, Entries::iterator it) {
        Entry &e = it->second;
        stats.bytes -= e.frame.bytes;
        --stats.count;
        if (e.pins > 0) {
            stats.pinnedBytes -= e.frame.bytes;
            --stats.pinnedCount;
        }
        graveyard.push_back(std::move(e.frame.image));
        auto a = assets.find(asset);
        a->second.entries.erase(it);
        if (a->second.entries.empty()) {
            assets.erase(a);
        }
    }

    /// Eviction rank of an entry (see the header comment): lower tier goes first; within a
    /// tier, the larger key goes first.
    struct Rank {
        int tier = 1;
        double key = 0;
        bool before(const Rank &o) const { return tier != o.tier ? tier < o.tier : key > o.key; }
    };

    Rank rank(AssetId asset, const Entry &e) const {
        bool focused = false;
        bool ahead = false;
        double aheadDistance = std::numeric_limits<double>::infinity();
        double behindDistance = std::numeric_limits<double>::infinity();
        const double start = seconds(e.frame.coverFrom);
        const double end = CMTIME_IS_POSITIVE_INFINITY(e.end) ? std::numeric_limits<double>::infinity() : seconds(e.end);
        for (const Focus &f : focus) {
            if (f.asset != asset || !CMTIME_IS_NUMERIC(f.time)) {
                continue;
            }
            focused = true;
            const double t = seconds(f.time);
            if (f.forward) {
                if (end <= t) {
                    behindDistance = std::min(behindDistance, t - end);
                } else {
                    ahead = true;
                    aheadDistance = std::min(aheadDistance, std::max(0.0, start - t));
                }
            } else {
                if (start > t) {
                    behindDistance = std::min(behindDistance, start - t);
                } else {
                    ahead = true;
                    aheadDistance = std::min(aheadDistance, std::max(0.0, t - end));
                }
            }
        }
        if (!focused) {
            return Rank{1, -static_cast<double>(e.lastUse)}; // Least recently used first.
        }
        if (ahead) {
            return Rank{2, aheadDistance}; // Farthest ahead first; the playhead frame last.
        }
        return Rank{0, behindDistance}; // Farthest behind first.
    }

    void evictTo(size_t limit) {
        while (stats.bytes > limit) {
            AssetId victimAsset;
            Entries::iterator victim;
            Rank best;
            bool found = false;
            for (auto &[asset, a] : assets) {
                for (auto it = a.entries.begin(); it != a.entries.end(); ++it) {
                    if (it->second.pins > 0) {
                        continue;
                    }
                    const Rank r = rank(asset, it->second);
                    if (!found || r.before(best)) {
                        found = true;
                        best = r;
                        victimAsset = asset;
                        victim = it;
                    }
                }
            }
            if (!found) {
                return; // Everything left is pinned.
            }
            erase(victimAsset, victim);
            ++stats.evictions;
        }
    }

    void unpin(AssetId asset, CMTime pts, uint64_t serial) {
        auto a = assets.find(asset);
        if (a == assets.end()) {
            return;
        }
        auto it = a->second.entries.find(TimeKey{pts});
        if (it == a->second.entries.end() || it->second.serial != serial || it->second.pins == 0) {
            return; // Purged or replaced meanwhile.
        }
        if (--it->second.pins == 0) {
            stats.pinnedBytes -= it->second.frame.bytes;
            --stats.pinnedCount;
            evictTo(budget);
        }
    }

    PinnedFrame pin(const std::shared_ptr<State> &self, AssetId asset, Entry *e) {
        PinnedFrame pinned;
        if (e == nullptr) {
            ++stats.misses;
            return pinned;
        }
        ++stats.hits;
        touch(*e);
        if (e->pins++ == 0) {
            stats.pinnedBytes += e->frame.bytes;
            ++stats.pinnedCount;
        }
        pinned.state_ = self;
        pinned.asset_ = asset;
        pinned.serial_ = e->serial;
        pinned.frame_ = e->frame;
        return pinned;
    }

    std::optional<Frame> lookup(Entry *e) {
        if (e == nullptr) {
            ++stats.misses;
            return std::nullopt;
        }
        ++stats.hits;
        touch(*e);
        return e->frame;
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

// MARK: - Slots

int64_t FrameCache::frameIndex(CMTime t, CMTime frameDuration) {
    if (!isPositive(frameDuration) || !isNumeric(t)) {
        return 0;
    }
    return frameIndexAt(t, frameDuration, SnapMode::Floor);
}

int64_t FrameCache::frameSpan(CMTime pts, CMTime duration, CMTime frameDuration) {
    if (!isPositive(frameDuration) || !isNumeric(pts) || !isNumeric(duration) || duration <= kCMTimeZero) {
        return 1;
    }
    return frameIndex(pts + duration, frameDuration) - frameIndex(pts, frameDuration);
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

// MARK: - Epochs and focus clients

FrameCache::FocusClient FrameCache::makeFocusClient() {
    static std::atomic<FocusClient> next{1};
    return next.fetch_add(1, std::memory_order_relaxed);
}

FrameCache::Epoch FrameCache::epoch() const {
    std::lock_guard<std::mutex> lock(state_->mutex);
    return state_->epoch;
}

FrameCache::Epoch FrameCache::beginEpoch() {
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    for (auto &[asset, a] : s.assets) {
        for (auto &[key, entry] : a.entries) {
            s.graveyard.push_back(std::move(entry.frame.image));
        }
    }
    s.assets.clear();
    s.stats.bytes = 0;
    s.stats.count = 0;
    s.stats.pinnedBytes = 0;
    s.stats.pinnedCount = 0;
    s.focusByClient.clear();
    s.focus.clear();
    return ++s.epoch;
}

// MARK: - Insert and look up

bool FrameCache::put(AssetId asset, const VideoFrame &frame, CMTime frameDuration, CMTime coverFrom) {
    return insert(std::nullopt, asset, frame.image, frame.pts, frame.duration, frameDuration, coverFrom);
}

bool FrameCache::put(AssetId asset, PixelBuffer image, CMTime pts, CMTime duration, CMTime frameDuration,
                     CMTime coverFrom) {
    return insert(std::nullopt, asset, std::move(image), pts, duration, frameDuration, coverFrom);
}

bool FrameCache::put(Epoch epoch, AssetId asset, const VideoFrame &frame, CMTime frameDuration, CMTime coverFrom) {
    return insert(epoch, asset, frame.image, frame.pts, frame.duration, frameDuration, coverFrom);
}

bool FrameCache::insert(std::optional<Epoch> epoch, AssetId asset, PixelBuffer image, CMTime pts, CMTime duration,
                        CMTime frameDuration, CMTime coverFrom) {
    if (!image || !isNumeric(pts)) {
        return false;
    }
    CMTime end;
    if (CMTIME_IS_POSITIVE_INFINITY(duration)) {
        end = kCMTimePositiveInfinity;
    } else if (isNumeric(duration) && duration > kCMTimeZero) {
        end = pts + duration;
    } else if (isPositive(frameDuration)) {
        duration = frameDuration;
        end = pts + frameDuration;
    } else {
        duration = kCMTimePositiveInfinity; // A still.
        end = kCMTimePositiveInfinity;
    }
    const CMTime cover = isNumeric(coverFrom) && coverFrom < pts ? coverFrom : pts;
    const size_t bytes = bufferBytes(image.get());
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    if ((epoch && *epoch != s.epoch) || bytes > s.budget) {
        return false; // decoded for media ids of an earlier epoch, or larger than the whole budget
    }
    State::Asset &a = s.assets[asset];
    a.frameDuration = frameDuration;
    if (auto it = a.entries.find(TimeKey{pts}); it != a.entries.end()) {
        State::Entry &existing = it->second;
        if (existing.pins > 0 || existing.frame.image == image) {
            s.touch(existing);
            if (existing.frame.image == image && CMTimeCompare(cover, existing.frame.coverFrom) < 0) {
                existing.frame.coverFrom = cover; // Learned about a gap before it.
            }
            return true;
        }
        s.erase(asset, it);
    }
    State::Asset &target = s.assets[asset]; // erase() may have removed an emptied asset.
    target.frameDuration = frameDuration;
    State::Entry entry;
    entry.frame.image = std::move(image);
    entry.frame.pts = pts;
    entry.frame.duration = duration;
    entry.frame.coverFrom = cover;
    entry.frame.index = frameIndex(pts, frameDuration);
    entry.frame.span = frameSpan(pts, duration, frameDuration);
    entry.frame.bytes = bytes;
    entry.end = end;
    entry.serial = s.nextSerial++;
    entry.lastUse = ++s.useTick;
    target.entries.emplace(TimeKey{pts}, std::move(entry));
    s.stats.bytes += bytes;
    ++s.stats.count;
    ++s.stats.insertions;
    s.evictTo(s.budget);
    return true;
}

std::optional<FrameCache::Frame> FrameCache::get(AssetId asset, CMTime t) {
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    return s.lookup(s.find(asset, t));
}

std::optional<FrameCache::Frame> FrameCache::get(AssetId asset, int64_t index) {
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    return s.lookup(s.findSlot(asset, index));
}

FrameCache::PinnedFrame FrameCache::acquire(AssetId asset, CMTime t) {
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    return s.pin(state_, asset, s.find(asset, t));
}

FrameCache::PinnedFrame FrameCache::acquire(AssetId asset, int64_t index) {
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    return s.pin(state_, asset, s.findSlot(asset, index));
}

bool FrameCache::contains(AssetId asset, CMTime t) const {
    State &s = *state_;
    std::lock_guard<std::mutex> lock(s.mutex);
    return s.find(asset, t) != nullptr;
}

bool FrameCache::contains(AssetId asset, int64_t index) const {
    State &s = *state_;
    std::lock_guard<std::mutex> lock(s.mutex);
    return s.findSlot(asset, index) != nullptr;
}

std::vector<int64_t> FrameCache::indices(AssetId asset) const {
    State &s = *state_;
    std::lock_guard<std::mutex> lock(s.mutex);
    std::vector<int64_t> out;
    if (auto it = s.assets.find(asset); it != s.assets.end()) {
        for (const auto &[key, entry] : it->second.entries) {
            out.push_back(entry.frame.index);
        }
    }
    return out;
}

std::vector<CMTime> FrameCache::presentationTimes(AssetId asset) const {
    State &s = *state_;
    std::lock_guard<std::mutex> lock(s.mutex);
    std::vector<CMTime> out;
    if (auto it = s.assets.find(asset); it != s.assets.end()) {
        for (const auto &[key, entry] : it->second.entries) {
            out.push_back(key.time);
        }
    }
    return out;
}

// MARK: - Eviction order, removal and budget

void FrameCache::setFocus(FocusClient client, std::vector<Focus> focus) {
    State &s = *state_;
    std::lock_guard<std::mutex> lock(s.mutex);
    if (focus.empty()) {
        s.focusByClient.erase(client);
    } else {
        s.focusByClient[client] = std::move(focus);
    }
    s.focus.clear();
    for (const auto &[id, list] : s.focusByClient) {
        s.focus.insert(s.focus.end(), list.begin(), list.end());
    }
}

void FrameCache::setFocus(std::vector<Focus> focus) {
    setFocus(FocusClient{0}, std::move(focus));
}

void FrameCache::purge(AssetId asset) {
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    auto a = s.assets.find(asset);
    if (a == s.assets.end()) {
        return;
    }
    for (auto &[key, entry] : a->second.entries) {
        s.stats.bytes -= entry.frame.bytes;
        --s.stats.count;
        if (entry.pins > 0) {
            s.stats.pinnedBytes -= entry.frame.bytes;
            --s.stats.pinnedCount;
        }
        s.graveyard.push_back(std::move(entry.frame.image));
    }
    s.assets.erase(a);
}

void FrameCache::purgeAll() {
    State &s = *state_;
    std::vector<PixelBuffer> dead;
    Locked lock(s, dead);
    for (auto &[asset, a] : s.assets) {
        for (auto &[key, entry] : a.entries) {
            s.graveyard.push_back(std::move(entry.frame.image));
        }
    }
    s.assets.clear();
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
        state->unpin(asset_, frame_.pts, serial_);
    }
    state_.reset();
    serial_ = 0;
}

} // namespace ve::media
