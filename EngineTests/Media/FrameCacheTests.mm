// FrameCache: slots and containment, eviction order (LRU and playhead focus), byte accounting,
// purge, pinning, memory pressure, concurrency.

#import <XCTest/XCTest.h>

#include "../../Engine/Media/FrameCache.h"
#include "../../Engine/Model/TimeUtil.h"

#include <random>
#include <thread>

using namespace ve;
using namespace ve::media;

namespace {

const CMTime kFd = CMTimeMake(1, 30);

PixelBuffer makeBuffer(int w = 64, int h = 64, OSType format = kCVPixelFormatType_32BGRA) {
    auto pool = PixelBufferPool::create(format, w, h);
    return pool.ok() ? pool->makeBuffer().value() : PixelBuffer();
}

/// Puts a frame on the 30 fps grid: pts = index / 30, one frame long.
bool putSlot(FrameCache &cache, AssetId asset, int64_t index, PixelBuffer image = makeBuffer(), int64_t frames = 1) {
    return cache.put(asset, std::move(image), timeForFrame(index, kFd), timeForFrame(frames, kFd), kFd);
}

} // namespace

@interface FrameCacheTests : XCTestCase
@end

@implementation FrameCacheTests {
    size_t _unit; // Bytes of one 64x64 BGRA buffer.
}

- (void)setUp {
    _unit = FrameCache::bufferBytes(makeBuffer().get());
}

- (void)testBufferBytes {
    XCTAssertGreaterThanOrEqual(_unit, size_t(64 * 64 * 4));
    PixelBuffer yuv = makeBuffer(1920, 1080, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
    const size_t bytes = FrameCache::bufferBytes(yuv.get());
    XCTAssertGreaterThanOrEqual(bytes, size_t(1920 * 1080 * 3 / 2));
    XCTAssertLessThan(bytes, size_t(1920 * 1080 * 3));
    // A non-IOSurface buffer falls back to its data size.
    CVPixelBufferRef plain = nullptr;
    CVPixelBufferCreate(kCFAllocatorDefault, 32, 16, kCVPixelFormatType_32BGRA, nullptr, &plain);
    XCTAssertGreaterThanOrEqual(FrameCache::bufferBytes(plain), size_t(32 * 16 * 4));
    CVPixelBufferRelease(plain);
    XCTAssertEqual(FrameCache::bufferBytes(nullptr), size_t(0));
}

/// Slots are floor(t / frameDuration): the slot containing t, the rule a decoder uses for
/// "the frame containing t". (The previous Round rule sent t = 9.6 frames to slot 10, whose
/// frame is not on screen yet at that time.)
- (void)testFrameIndexIsTheSlotContainingTheTime {
    const CMTime fd = CMTimeMake(1001, 30000);
    XCTAssertEqual(FrameCache::frameIndex(CMTimeMake(1001 * 10, 30000), fd), 10);
    XCTAssertEqual(FrameCache::frameIndex(CMTimeMake(3003 * 10 + 1, 90000), fd), 10, @"a tick late");
    XCTAssertEqual(FrameCache::frameIndex(CMTimeMake(3003 * 10 - 1, 90000), fd), 9, @"a tick early: still slot 9");
    XCTAssertEqual(FrameCache::frameIndex(CMTimeMake(1001 * 96, 300000), fd), 9, @"9.6 frames");
    XCTAssertEqual(FrameCache::frameIndex(CMTimeMake(5, 1), kCMTimeInvalid), 0, @"stills");
    XCTAssertEqual(FrameCache::frameIndex(kCMTimeInvalid, fd), 0);
    // Span: slots whose start lies in the frame.
    XCTAssertEqual(FrameCache::frameSpan(CMTimeMake(0, 1), CMTimeMake(1001, 30000), fd), 1);
    XCTAssertEqual(FrameCache::frameSpan(CMTimeMake(0, 1), CMTimeMake(3003, 30000), fd), 3);
    XCTAssertEqual(FrameCache::frameSpan(CMTimeMake(1001, 60000), CMTimeMake(1001, 60000), fd), 1,
                   @"half a frame straddling a slot boundary covers that slot's start");
    XCTAssertEqual(FrameCache::frameSpan(CMTimeMake(1001, 90000), CMTimeMake(1001, 90000), fd), 0,
                   @"a short frame inside one slot covers no slot start");
    XCTAssertEqual(FrameCache::frameSpan(kCMTimeZero, kCMTimePositiveInfinity, fd), 1);
}

- (void)testLRUEvictionOrderAndByteAccounting {
    FrameCache cache(3 * _unit);
    const AssetId a(1);
    XCTAssertTrue(putSlot(cache, a, 0));
    XCTAssertTrue(putSlot(cache, a, 1));
    XCTAssertTrue(putSlot(cache, a, 2));
    XCTAssertEqual(cache.stats().bytes, 3 * _unit);
    XCTAssertEqual(cache.stats().count, size_t(3));
    XCTAssertTrue(cache.get(a, int64_t(0))); // 0 becomes most recently used; 1 is now the oldest.
    XCTAssertTrue(putSlot(cache, a, 3));
    XCTAssertFalse(cache.contains(a, int64_t(1)));
    XCTAssertTrue(cache.contains(a, int64_t(0)));
    XCTAssertTrue(cache.contains(a, int64_t(2)));
    XCTAssertTrue(cache.contains(a, int64_t(3)));
    XCTAssertTrue(putSlot(cache, a, 4)); // Evicts 2.
    XCTAssertEqual(cache.indices(a), (std::vector<int64_t>{0, 3, 4}));
    // contains() does not refresh: 0 is still the oldest.
    XCTAssertTrue(cache.contains(a, int64_t(0)));
    XCTAssertTrue(putSlot(cache, a, 5));
    XCTAssertEqual(cache.indices(a), (std::vector<int64_t>{3, 4, 5}));

    const FrameCache::Stats s = cache.stats();
    XCTAssertEqual(s.bytes, 3 * _unit);
    XCTAssertEqual(s.count, size_t(3));
    XCTAssertEqual(s.evictions, uint64_t(3));
    XCTAssertEqual(s.insertions, uint64_t(6));
    XCTAssertEqual(s.hits, uint64_t(1));
    XCTAssertFalse(cache.get(a, int64_t(99)));
    XCTAssertEqual(cache.stats().misses, uint64_t(1));
    cache.resetStats();
    XCTAssertEqual(cache.stats().hits, uint64_t(0));
    XCTAssertEqual(cache.stats().bytes, 3 * _unit, @"reset keeps the accounting");
}

- (void)testReplacementPurgeAndBudget {
    FrameCache cache(10 * _unit);
    const AssetId a(1), b(2);
    PixelBuffer first = makeBuffer();
    XCTAssertTrue(putSlot(cache, a, 0, first));
    XCTAssertTrue(putSlot(cache, a, 0, first)); // Same buffer: refresh only.
    XCTAssertEqual(cache.stats().insertions, uint64_t(1));
    XCTAssertTrue(putSlot(cache, a, 0)); // Different buffer at the same pts: replaced.
    XCTAssertEqual(cache.stats().count, size_t(1));
    XCTAssertEqual(cache.stats().bytes, _unit);
    XCTAssertFalse(cache.get(a, int64_t(0))->image == first);

    for (int i = 1; i < 4; ++i) {
        XCTAssertTrue(putSlot(cache, a, i));
        XCTAssertTrue(putSlot(cache, b, i));
    }
    cache.purge(a);
    XCTAssertTrue(cache.indices(a).empty());
    XCTAssertEqual(cache.indices(b), (std::vector<int64_t>{1, 2, 3}));
    XCTAssertEqual(cache.stats().bytes, 3 * _unit);

    cache.setBudget(2 * _unit);
    XCTAssertEqual(cache.budget(), 2 * _unit);
    XCTAssertEqual(cache.stats().count, size_t(2));
    XCTAssertFalse(putSlot(cache, b, 9, makeBuffer(512, 512)), @"larger than the whole budget");
    XCTAssertFalse(putSlot(cache, b, 9, PixelBuffer()));
    XCTAssertFalse(cache.put(b, makeBuffer(), kCMTimeInvalid, kFd, kFd), @"no pts");

    cache.trimTo(_unit);
    XCTAssertEqual(cache.stats().count, size_t(1));
    cache.purgeAll();
    XCTAssertEqual(cache.stats().count, size_t(0));
    XCTAssertEqual(cache.stats().bytes, size_t(0));
}

- (void)testContainmentForLongFramesStillsAndGaps {
    FrameCache cache(10 * _unit);
    const AssetId a(1);
    // A VFR frame lasting three nominal frames covers slots 10, 11 and 12 and every time inside.
    VideoFrame f;
    f.pts = CMTimeMake(10, 30);
    f.duration = CMTimeMake(3, 30);
    f.image = makeBuffer();
    XCTAssertTrue(cache.put(a, f, kFd));
    XCTAssertFalse(cache.contains(a, int64_t(9)));
    XCTAssertTrue(cache.contains(a, int64_t(10)));
    XCTAssertTrue(cache.contains(a, int64_t(12)));
    XCTAssertFalse(cache.contains(a, int64_t(13)));
    XCTAssertTrue(cache.contains(a, CMTimeMake(129, 300)), @"0.43 s is inside [1/3, 13/30)");
    XCTAssertFalse(cache.contains(a, CMTimeMake(13, 30)), @"the end is exclusive");
    XCTAssertEqual(cache.get(a, CMTimeMake(23, 60))->index, 10);
    XCTAssertEqual(cache.get(a, CMTimeMake(23, 60))->span, 3);
    XCTAssertTrue(identical(cache.get(a, int64_t(11))->pts, f.pts));

    // A frame that starts after a gap (the first frame at 0.5 s, the decoder's answer for any
    // time before it) answers the gap once the pool records where the seek landed.
    VideoFrame late;
    late.pts = CMTimeMake(1, 2);
    late.duration = kFd;
    late.image = makeBuffer();
    const AssetId g(4);
    XCTAssertTrue(cache.put(g, late, kFd));
    XCTAssertFalse(cache.contains(g, CMTimeMake(1, 5)));
    XCTAssertTrue(cache.put(g, late, kFd, kCMTimeZero)); // Same buffer: widens the entry.
    XCTAssertTrue(cache.contains(g, CMTimeMake(1, 5)));
    XCTAssertTrue(cache.contains(g, int64_t(0)));
    XCTAssertEqual(cache.stats().insertions, uint64_t(2), @"widening is not an insertion");

    // A still: +infinity duration, invalid frame duration, always slot 0.
    const AssetId s(2);
    VideoFrame still;
    still.pts = kCMTimeZero;
    still.duration = kCMTimePositiveInfinity;
    still.image = makeBuffer();
    XCTAssertTrue(cache.put(s, still, kCMTimeInvalid));
    XCTAssertTrue(cache.get(s, CMTimeMake(42, 1)));
    XCTAssertTrue(cache.contains(s, int64_t(0)));
    // Assets do not leak into each other.
    XCTAssertFalse(cache.contains(AssetId(3), int64_t(0)));
    XCTAssertFalse(cache.contains(AssetId(3), CMTimeMake(1, 1)));
}

/// Frames of a jittery variable-frame-rate source tile time without gaps; every grid slot in
/// between must be answered, by the frame showing at the slot's start (the frame a decoder
/// returns for seek(slot * frameDuration)).
- (void)testEverySlotIsCoveredOnJitteryVFR {
    FrameCache cache(1000 * _unit);
    const AssetId a(1);
    const CMTime fd = CMTimeMake(1, 30);
    // Millisecond durations around and between 1/30 s (a VFR screen recording in Matroska).
    const int64_t durations[] = {40, 27, 33, 50, 20, 34, 46, 33, 21, 67, 33, 25, 41, 33, 34, 29};
    int64_t t = 0;
    for (int i = 0; i < 64; ++i) {
        const int64_t d = durations[i % 16];
        VideoFrame f;
        f.pts = CMTimeMake(t, 1000);
        f.duration = CMTimeMake(d, 1000);
        f.image = makeBuffer();
        XCTAssertTrue(cache.put(a, f, fd));
        t += d;
    }
    const int64_t lastSlot = static_cast<int64_t>((t - 1) * 30 / 1000);
    int uncovered = 0;
    int wrong = 0;
    for (int64_t n = 0; n <= lastSlot; ++n) {
        const CMTime slotStart = CMTimeMultiply(fd, static_cast<int32_t>(n));
        auto hit = cache.get(a, n);
        if (!hit) {
            ++uncovered;
            continue;
        }
        if (!(CMTimeCompare(hit->pts, slotStart) <= 0 &&
              CMTimeCompare(slotStart, CMTimeAdd(hit->pts, hit->duration)) < 0)) {
            ++wrong;
        }
    }
    XCTAssertEqual(uncovered, 0, @"slots without an entry");
    XCTAssertEqual(wrong, 0, @"slots answered by a frame that does not show at the slot start");
}

/// A source whose frames are offset from the grid (pts = (k + 0.4) * fd): a warm lookup by time
/// must return the same frame as a cold decode (the frame containing the time).
- (void)testColdAndWarmLookupsAgreeOnOffGridSources {
    FrameCache cache(1000 * _unit);
    const AssetId a(1);
    const CMTime fd = CMTimeMake(1, 25);
    for (int k = 0; k < 50; ++k) {
        VideoFrame f;
        f.pts = CMTimeMake(10 * k + 4, 250); // (k + 0.4) / 25 s
        f.duration = fd;
        f.image = makeBuffer();
        XCTAssertTrue(cache.put(a, f, fd));
    }
    int disagreements = 0;
    for (int k = 1; k < 49; ++k) {
        for (int x : {0, 2, 3, 5, 7, 9}) { // t = (k + x/10) / 25 s
            const CMTime t = CMTimeMake(10 * k + x, 250);
            const int cold = x >= 4 ? k : k - 1; // The frame containing t.
            auto warm = cache.get(a, t);
            const int warmIndex = warm ? static_cast<int>((warm->pts.value - 4) / 10) : -1;
            if (warmIndex != cold) {
                ++disagreements;
            }
        }
    }
    XCTAssertEqual(disagreements, 0, @"warm cache answers that differ from a cold decode");
}

/// With a playhead focus, eviction removes frames behind the playhead first (farthest behind
/// first), then unfocused assets' frames (LRU), then the farthest ahead: the frames about to be
/// shown survive even when they are the oldest insertions.
- (void)testFocusedEvictionKeepsThePlayheadAndNearFutureFrames {
    FrameCache cache(6 * _unit);
    const AssetId a(1), other(2);
    cache.setFocus({FrameCache::Focus{a, timeForFrame(10, kFd), true}});
    // Inserted in decode order: 10 (playhead) first, then 11..13 ahead, then 4 and 6 behind.
    for (int64_t i : {10, 11, 12, 13, 4, 6}) {
        XCTAssertTrue(putSlot(cache, a, i));
    }
    XCTAssertTrue(putSlot(cache, other, 50)); // 7th: over budget.
    XCTAssertEqual(cache.indices(a), (std::vector<int64_t>{6, 10, 11, 12, 13}), @"farthest behind (4) went first");
    XCTAssertTrue(putSlot(cache, other, 51));
    XCTAssertEqual(cache.indices(a), (std::vector<int64_t>{10, 11, 12, 13}), @"then the next behind (6)");
    XCTAssertTrue(putSlot(cache, a, 14));
    XCTAssertEqual(cache.indices(other), (std::vector<int64_t>{51}), @"then unfocused assets, LRU first");
    XCTAssertTrue(putSlot(cache, a, 15));
    XCTAssertTrue(putSlot(cache, a, 16));
    XCTAssertTrue(cache.indices(other).empty());
    XCTAssertEqual(cache.indices(a), (std::vector<int64_t>{10, 11, 12, 13, 14, 15}),
                   @"then the farthest ahead: the playhead frame, inserted first, stays");

    // Reverse play: frames at or before the playhead are ahead.
    cache.setFocus({FrameCache::Focus{a, timeForFrame(12, kFd), false}});
    XCTAssertTrue(putSlot(cache, a, 9));
    XCTAssertEqual(cache.indices(a), (std::vector<int64_t>{9, 10, 11, 12, 13, 14}), @"15 was farthest behind");
    // No focus: plain LRU again.
    cache.setFocus({});
    XCTAssertTrue(cache.get(a, int64_t(9)));
    XCTAssertTrue(putSlot(cache, a, 30));
    XCTAssertFalse(cache.contains(a, int64_t(10)), @"10 was the least recently used");
}

- (void)testPinnedFramesSurviveEvictionAndPressure {
    FrameCache cache(2 * _unit);
    const AssetId a(1);
    XCTAssertTrue(putSlot(cache, a, 0));
    FrameCache::PinnedFrame pin = cache.acquire(a, int64_t(0));
    XCTAssertTrue(pin);
    XCTAssertEqual(pin.frame().index, 0);
    XCTAssertEqual(cache.stats().pinnedCount, size_t(1));
    XCTAssertEqual(cache.stats().pinnedBytes, _unit);

    // Filling the cache evicts around the pinned frame.
    for (int i = 1; i <= 5; ++i) {
        XCTAssertTrue(putSlot(cache, a, i));
    }
    XCTAssertTrue(cache.contains(a, int64_t(0)));
    XCTAssertEqual(cache.indices(a), (std::vector<int64_t>{0, 5}));
    // Replacing a pinned slot keeps the pinned buffer.
    PixelBuffer pinnedImage = pin.image();
    XCTAssertTrue(putSlot(cache, a, 0));
    XCTAssertTrue(cache.get(a, int64_t(0))->image == pinnedImage);

    cache.handleMemoryPressure(MemoryPressure::Critical);
    XCTAssertEqual(cache.indices(a), std::vector<int64_t>{0});
    cache.trimTo(0);
    XCTAssertEqual(cache.stats().bytes, _unit, @"pinned bytes still count");

    // Everything pinned: the cache may exceed its budget, and says so.
    XCTAssertTrue(putSlot(cache, a, 7));
    XCTAssertTrue(putSlot(cache, a, 8));
    FrameCache::PinnedFrame pin8 = cache.acquire(a, int64_t(8));
    FrameCache::PinnedFrame pin8b = cache.acquire(a, timeForFrame(8, kFd)); // Pins nest (by time too).
    XCTAssertTrue(putSlot(cache, a, 9));
    XCTAssertEqual(cache.indices(a), (std::vector<int64_t>{0, 8}), @"9 cannot fit, 7 was the LRU");
    XCTAssertEqual(cache.stats().pinnedCount, size_t(2));
    pin8.release();
    XCTAssertEqual(cache.stats().pinnedCount, size_t(2), @"still pinned by pin8b");
    XCTAssertTrue(pin8, @"release keeps the frame data");

    // Unpinning trims back to the budget if it was exceeded.
    cache.setBudget(_unit);
    XCTAssertEqual(cache.stats().bytes, 2 * _unit);
    pin = FrameCache::PinnedFrame(); // Move-assign releases the old pin.
    XCTAssertEqual(cache.stats().bytes, _unit);
    XCTAssertEqual(cache.indices(a), std::vector<int64_t>{8});
    XCTAssertFalse(cache.acquire(a, int64_t(0)));
}

- (void)testPurgeWhilePinnedAndPinsOutlivingTheCache {
    FrameCache::PinnedFrame survivor;
    {
        FrameCache cache(4 * _unit);
        const AssetId a(1);
        XCTAssertTrue(putSlot(cache, a, 3));
        FrameCache::PinnedFrame pin = cache.acquire(a, int64_t(3));
        cache.purge(a);
        XCTAssertFalse(cache.contains(a, int64_t(3)), @"purge removes pinned entries");
        XCTAssertEqual(cache.stats().pinnedCount, size_t(0));
        XCTAssertTrue(pin.image());
        XCTAssertTrue(putSlot(cache, a, 3)); // A new entry at the same pts...
        pin.release();                       // ...is not unpinned by the stale pin.
        XCTAssertEqual(cache.stats().pinnedCount, size_t(0));
        XCTAssertTrue(cache.contains(a, int64_t(3)));
        survivor = cache.acquire(a, int64_t(3));
        FrameCache::PinnedFrame moved = std::move(survivor);
        survivor = std::move(moved);
        XCTAssertEqual(cache.stats().pinnedCount, size_t(1));
    }
    XCTAssertTrue(survivor.image());
    survivor.release(); // The cache is gone: a no-op, not a crash.
}

- (void)testMemoryPressureWarningHalvesTheCache {
    FrameCache cache(8 * _unit);
    for (int i = 0; i < 8; ++i) {
        XCTAssertTrue(putSlot(cache, AssetId(1), i));
    }
    cache.handleMemoryPressure(MemoryPressure::Normal);
    XCTAssertEqual(cache.stats().count, size_t(8));
    cache.handleMemoryPressure(MemoryPressure::Warning);
    XCTAssertEqual(cache.stats().count, size_t(4));
    XCTAssertEqual(cache.indices(AssetId(1)), (std::vector<int64_t>{4, 5, 6, 7}), @"the oldest go first");
}

- (void)testConcurrentAccessFromEightThreads {
    constexpr int kThreads = 8;
    constexpr int kOps = 4000;
    auto cache = std::make_shared<FrameCache>(40 * _unit);
    std::vector<PixelBuffer> buffers;
    for (int i = 0; i < 16; ++i) {
        buffers.push_back(makeBuffer());
    }
    std::vector<std::thread> threads;
    std::atomic<uint64_t> gets{0};
    for (int t = 0; t < kThreads; ++t) {
        threads.emplace_back([&, t] {
            std::mt19937 rng(static_cast<unsigned>(t));
            std::vector<FrameCache::PinnedFrame> pins;
            for (int i = 0; i < kOps; ++i) {
                const AssetId asset(1 + rng() % 4);
                const int64_t index = rng() % 64;
                switch (rng() % 11) {
                case 0:
                case 1:
                case 2:
                case 3:
                    putSlot(*cache, asset, index, buffers[rng() % buffers.size()], 1 + rng() % 2);
                    break;
                case 4:
                case 5:
                    if (auto f = cache->get(asset, index)) {
                        XCTAssertTrue(f->image);
                    }
                    ++gets;
                    break;
                case 6:
                    if (auto f = cache->get(asset, CMTimeMake(index * 10 + rng() % 10, 300))) {
                        XCTAssertTrue(f->image);
                    }
                    ++gets;
                    break;
                case 7:
                    pins.push_back(cache->acquire(asset, index));
                    if (pins.size() > 3) {
                        pins.erase(pins.begin());
                    }
                    break;
                case 8:
                    (void)cache->contains(asset, index);
                    (void)cache->stats();
                    break;
                case 9:
                    cache->setFocus({FrameCache::Focus{asset, timeForFrame(index, kFd), rng() % 2 == 0}});
                    break;
                default:
                    if (rng() % 50 == 0) {
                        cache->purge(asset);
                    } else if (rng() % 50 == 1) {
                        cache->handleMemoryPressure(MemoryPressure::Warning);
                    } else {
                        (void)cache->indices(asset);
                    }
                    break;
                }
            }
        });
    }
    for (auto &th : threads) {
        th.join();
    }
    const FrameCache::Stats s = cache->stats();
    XCTAssertEqual(s.pinnedCount, size_t(0), @"every pin was released");
    XCTAssertEqual(s.pinnedBytes, size_t(0));
    XCTAssertLessThanOrEqual(s.bytes, cache->budget());
    size_t entries = 0;
    for (int a = 1; a <= 4; ++a) {
        entries += cache->indices(AssetId(a)).size();
    }
    XCTAssertEqual(entries, s.count);
    XCTAssertEqual(s.bytes, s.count * _unit, @"byte accounting matches the entries");
    XCTAssertGreaterThanOrEqual(s.hits + s.misses, gets.load(), @"every get was counted (acquires too)");
}

@end
