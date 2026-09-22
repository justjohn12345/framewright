// FrameCache: keys, LRU order, byte accounting, purge, pinning, memory pressure, concurrency.

#import <XCTest/XCTest.h>

#include "../../Engine/Media/FrameCache.h"
#include "../../Engine/Model/TimeUtil.h"

#include <random>
#include <thread>

using namespace ve;
using namespace ve::media;

namespace {

PixelBuffer makeBuffer(int w = 64, int h = 64, OSType format = kCVPixelFormatType_32BGRA) {
    auto pool = PixelBufferPool::create(format, w, h);
    return pool.ok() ? pool->makeBuffer().value() : PixelBuffer();
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

- (void)testFrameIndexRoundsToTheNearestGridSlot {
    const CMTime fd = CMTimeMake(1001, 30000);
    XCTAssertEqual(FrameCache::frameIndex(CMTimeMake(1001 * 10, 30000), fd), 10);
    XCTAssertEqual(FrameCache::frameIndex(CMTimeMake(3003 * 10 + 1, 90000), fd), 10, @"a tick late");
    XCTAssertEqual(FrameCache::frameIndex(CMTimeMake(3003 * 10 - 1, 90000), fd), 10, @"a tick early");
    XCTAssertEqual(FrameCache::frameIndex(CMTimeMake(5, 1), kCMTimeInvalid), 0, @"stills");
    XCTAssertEqual(FrameCache::frameIndex(kCMTimeInvalid, fd), 0);
    XCTAssertEqual(FrameCache::frameSpan(CMTimeMake(1001, 30000), fd), 1);
    XCTAssertEqual(FrameCache::frameSpan(CMTimeMake(3003, 30000), fd), 3);
    XCTAssertEqual(FrameCache::frameSpan(kCMTimePositiveInfinity, fd), 1);
    XCTAssertEqual(FrameCache::frameSpan(CMTimeMake(1, 1000), fd), 1);
}

- (void)testLRUEvictionOrderAndByteAccounting {
    FrameCache cache(3 * _unit);
    const AssetId a(1);
    XCTAssertTrue(cache.put(a, 0, makeBuffer()));
    XCTAssertTrue(cache.put(a, 1, makeBuffer()));
    XCTAssertTrue(cache.put(a, 2, makeBuffer()));
    XCTAssertEqual(cache.stats().bytes, 3 * _unit);
    XCTAssertEqual(cache.stats().count, size_t(3));
    XCTAssertTrue(cache.get(a, 0)); // 0 becomes most recently used; 1 is now the oldest.
    XCTAssertTrue(cache.put(a, 3, makeBuffer()));
    XCTAssertFalse(cache.contains(a, 1));
    XCTAssertTrue(cache.contains(a, 0));
    XCTAssertTrue(cache.contains(a, 2));
    XCTAssertTrue(cache.contains(a, 3));
    XCTAssertTrue(cache.put(a, 4, makeBuffer())); // Evicts 2.
    XCTAssertEqual(cache.indices(a), (std::vector<int64_t>{0, 3, 4}));
    // contains() does not refresh: 0 is still the oldest.
    XCTAssertTrue(cache.contains(a, 0));
    XCTAssertTrue(cache.put(a, 5, makeBuffer()));
    XCTAssertEqual(cache.indices(a), (std::vector<int64_t>{3, 4, 5}));

    const FrameCache::Stats s = cache.stats();
    XCTAssertEqual(s.bytes, 3 * _unit);
    XCTAssertEqual(s.count, size_t(3));
    XCTAssertEqual(s.evictions, uint64_t(3));
    XCTAssertEqual(s.insertions, uint64_t(6));
    XCTAssertEqual(s.hits, uint64_t(1));
    XCTAssertFalse(cache.get(a, 99));
    XCTAssertEqual(cache.stats().misses, uint64_t(1));
    cache.resetStats();
    XCTAssertEqual(cache.stats().hits, uint64_t(0));
    XCTAssertEqual(cache.stats().bytes, 3 * _unit, @"reset keeps the accounting");
}

- (void)testReplacementPurgeAndBudget {
    FrameCache cache(10 * _unit);
    const AssetId a(1), b(2);
    PixelBuffer first = makeBuffer();
    XCTAssertTrue(cache.put(a, 0, first));
    XCTAssertTrue(cache.put(a, 0, first)); // Same buffer: refresh only.
    XCTAssertEqual(cache.stats().insertions, uint64_t(1));
    XCTAssertTrue(cache.put(a, 0, makeBuffer())); // Different buffer: replaced.
    XCTAssertEqual(cache.stats().count, size_t(1));
    XCTAssertEqual(cache.stats().bytes, _unit);
    XCTAssertFalse(cache.get(a, 0)->image == first);

    for (int i = 1; i < 4; ++i) {
        XCTAssertTrue(cache.put(a, i, makeBuffer()));
        XCTAssertTrue(cache.put(b, i, makeBuffer()));
    }
    cache.purge(a);
    XCTAssertTrue(cache.indices(a).empty());
    XCTAssertEqual(cache.indices(b), (std::vector<int64_t>{1, 2, 3}));
    XCTAssertEqual(cache.stats().bytes, 3 * _unit);

    cache.setBudget(2 * _unit);
    XCTAssertEqual(cache.budget(), 2 * _unit);
    XCTAssertEqual(cache.stats().count, size_t(2));
    XCTAssertFalse(cache.put(b, 9, makeBuffer(512, 512)), @"larger than the whole budget");
    XCTAssertFalse(cache.put(b, 9, PixelBuffer()));
    XCTAssertFalse(cache.put(b, 9, makeBuffer(), 0));

    cache.trimTo(_unit);
    XCTAssertEqual(cache.stats().count, size_t(1));
    cache.purgeAll();
    XCTAssertEqual(cache.stats().count, size_t(0));
    XCTAssertEqual(cache.stats().bytes, size_t(0));
}

- (void)testCoveringLookupForSpansAndStills {
    FrameCache cache(10 * _unit);
    const AssetId a(1);
    const CMTime fd = CMTimeMake(1, 30);
    // A VFR frame lasting three nominal frames covers slots 10, 11 and 12.
    VideoFrame f;
    f.pts = CMTimeMake(10, 30);
    f.duration = CMTimeMake(3, 30);
    f.image = makeBuffer();
    XCTAssertTrue(cache.put(a, f, fd));
    XCTAssertFalse(cache.contains(a, 9));
    XCTAssertTrue(cache.contains(a, 10));
    XCTAssertTrue(cache.contains(a, 12));
    XCTAssertFalse(cache.contains(a, 13));
    XCTAssertEqual(cache.get(a, CMTimeMake(23, 60), fd)->index, 10); // 0.383 s rounds to slot 12.
    XCTAssertTrue(identical(cache.get(a, 11)->pts, f.pts));

    // A still: +infinity duration, invalid frame duration, always slot 0.
    const AssetId s(2);
    VideoFrame still;
    still.pts = kCMTimeZero;
    still.duration = kCMTimePositiveInfinity;
    still.image = makeBuffer();
    XCTAssertTrue(cache.put(s, still, kCMTimeInvalid));
    XCTAssertTrue(cache.get(s, CMTimeMake(42, 1), kCMTimeInvalid));
    // Assets do not leak into each other.
    XCTAssertFalse(cache.contains(AssetId(3), 0));
    XCTAssertFalse(cache.contains(s, 1));
}

- (void)testPinnedFramesSurviveEvictionAndPressure {
    FrameCache cache(2 * _unit);
    const AssetId a(1);
    XCTAssertTrue(cache.put(a, 0, makeBuffer()));
    FrameCache::PinnedFrame pin = cache.acquire(a, 0);
    XCTAssertTrue(pin);
    XCTAssertEqual(pin.frame().index, 0);
    XCTAssertEqual(cache.stats().pinnedCount, size_t(1));
    XCTAssertEqual(cache.stats().pinnedBytes, _unit);

    // Filling the cache evicts around the pinned frame.
    for (int i = 1; i <= 5; ++i) {
        XCTAssertTrue(cache.put(a, i, makeBuffer()));
    }
    XCTAssertTrue(cache.contains(a, 0));
    XCTAssertEqual(cache.indices(a), (std::vector<int64_t>{0, 5}));
    // Replacing a pinned slot keeps the pinned buffer.
    PixelBuffer pinnedImage = pin.image();
    XCTAssertTrue(cache.put(a, 0, makeBuffer()));
    XCTAssertTrue(cache.get(a, 0)->image == pinnedImage);

    cache.handleMemoryPressure(MemoryPressure::Critical);
    XCTAssertEqual(cache.indices(a), std::vector<int64_t>{0});
    cache.trimTo(0);
    XCTAssertEqual(cache.stats().bytes, _unit, @"pinned bytes still count");

    // Everything pinned: the cache may exceed its budget, and says so.
    XCTAssertTrue(cache.put(a, 7, makeBuffer()));
    XCTAssertTrue(cache.put(a, 8, makeBuffer()));
    FrameCache::PinnedFrame pin8 = cache.acquire(a, 8);
    FrameCache::PinnedFrame pin8b = cache.acquire(a, 8); // Pins nest.
    XCTAssertTrue(cache.put(a, 9, makeBuffer()));
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
    XCTAssertFalse(cache.acquire(a, 0));
}

- (void)testPurgeWhilePinnedAndPinsOutlivingTheCache {
    FrameCache::PinnedFrame survivor;
    {
        FrameCache cache(4 * _unit);
        const AssetId a(1);
        XCTAssertTrue(cache.put(a, 3, makeBuffer()));
        FrameCache::PinnedFrame pin = cache.acquire(a, 3);
        cache.purge(a);
        XCTAssertFalse(cache.contains(a, 3), @"purge removes pinned entries");
        XCTAssertEqual(cache.stats().pinnedCount, size_t(0));
        XCTAssertTrue(pin.image());
        XCTAssertTrue(cache.put(a, 3, makeBuffer())); // A new entry in the same slot...
        pin.release();                              // ...is not unpinned by the stale pin.
        XCTAssertEqual(cache.stats().pinnedCount, size_t(0));
        XCTAssertTrue(cache.contains(a, 3));
        survivor = cache.acquire(a, 3);
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
        XCTAssertTrue(cache.put(AssetId(1), i, makeBuffer()));
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
                switch (rng() % 10) {
                case 0:
                case 1:
                case 2:
                case 3:
                    cache->put(asset, index, buffers[rng() % buffers.size()], 1 + rng() % 2);
                    break;
                case 4:
                case 5:
                case 6:
                    if (auto f = cache->get(asset, index)) {
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
