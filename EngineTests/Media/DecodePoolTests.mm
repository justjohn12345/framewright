// DecodePool: lookahead windows, re-targeting latency, scrub coalescing, shutdown.

#import <XCTest/XCTest.h>

#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../../Engine/Media/DecodePool.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Model/TimeUtil.h"
#include "BurnIn.h"
#include "RouterTestSupport.h"
#include "TestMedia.h"

#include <thread>

using namespace ve;
using namespace ve::media;
using namespace ve::test;
using Clock = std::chrono::steady_clock;

namespace {

double msSince(Clock::time_point t) {
    return std::chrono::duration<double, std::milli>(Clock::now() - t).count();
}

/// Every slot in [from, to] is cached.
bool covers(FrameCache &cache, AssetId asset, int64_t from, int64_t to) {
    for (int64_t i = from; i <= to; ++i) {
        if (!cache.contains(asset, i)) {
            return false;
        }
    }
    return true;
}

/// Collects scrub results in order of arrival; each callback may be invoked at most once.
struct ScrubLog {
    std::mutex mutex;
    std::condition_variable cv;
    std::map<int, std::vector<Result<ScrubFrame>>> results; ///< request id -> invocations.

    ScrubCallback callback(int id) {
        return [this, id](Result<ScrubFrame> r) {
            std::lock_guard<std::mutex> lock(mutex);
            results[id].push_back(std::move(r));
            cv.notify_all();
        };
    }
    bool waitFor(size_t count, std::chrono::milliseconds timeout) {
        std::unique_lock<std::mutex> lock(mutex);
        return cv.wait_for(lock, timeout, [&] { return results.size() >= count; });
    }
};

} // namespace

@interface DecodePoolTests : XCTestCase
@end

@implementation DecodePoolTests {
    std::shared_ptr<FakeBehavior> _fake;
    std::shared_ptr<BackendRouter> _fakeRouter;
    std::shared_ptr<FrameCache> _cache;
}

- (void)setUp {
    _fake = std::make_shared<FakeBehavior>();
    _fake->name = "fake";
    _fake->probe = [](const std::string &p) { return Result<MediaInfo>(makeFakeInfo(p, "mov", fourcc::H264)); };
    _fakeRouter = std::make_shared<BackendRouter>();
    (void)_fakeRouter->registerBackend(std::make_shared<FakeBackend>(_fake));
    _cache = std::make_shared<FrameCache>();
}

- (std::string)mediaPath:(const std::string &)file {
    std::string error;
    const std::string path = testMediaPath(file, error);
    XCTAssertFalse(path.empty(), @"test media: %s", error.c_str());
    return path;
}

// MARK: - Lookahead with real media

- (void)testFillsTheWindowForTwoAssetsWithCorrectFrames {
    const std::string h264 = [self mediaPath:"h264_1080p30.mp4"];
    const std::string hevc = [self mediaPath:"hevc_720p2997.mov"];
    if (h264.empty() || hevc.empty()) {
        return;
    }
    const AssetId a(1), b(2);
    const CMTime fdA = CMTimeMake(1, 30), fdB = CMTimeMake(1001, 30000);
    DecodePool pool(BackendRouter::makeDefault(), _cache);
    const auto start = Clock::now();
    pool.setTargets({DecodeTarget{a, h264, -1, CMTimeMake(1, 2)}, DecodeTarget{b, hevc, -1, CMTimeMake(3, 1)}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(20)));
    NSLog(@"two 1 s windows (1080p H.264 + 720p HEVC) filled in %.1f ms", msSince(start));

    // Window: [t, t + 1 s] in each asset's own frame grid.
    const int64_t a0 = FrameCache::frameIndex(CMTimeMake(1, 2), fdA);
    const int64_t b0 = FrameCache::frameIndex(CMTimeMake(3, 1), fdB);
    XCTAssertTrue(covers(*_cache, a, a0, a0 + 30));
    XCTAssertTrue(covers(*_cache, b, b0, b0 + 29));
    // Not wildly beyond the window either.
    XCTAssertFalse(_cache->contains(a, a0 + 45));
    XCTAssertFalse(_cache->contains(b, b0 + 45));

    // Burn-in of every cached frame equals its slot.
    for (AssetId asset : {a, b}) {
        const std::vector<int64_t> slots = _cache->indices(asset);
        XCTAssertGreaterThan(slots.size(), size_t(29));
        for (int64_t slot : slots) {
            auto f = _cache->get(asset, slot);
            XCTAssertTrue(f);
            XCTAssertEqual(readBurnIn(f->image.get()), std::optional<int>(static_cast<int>(slot)),
                           @"asset %llu slot %lld", asset.value(), slot);
        }
    }
    const DecodePool::Stats stats = pool.stats();
    XCTAssertEqual(stats.streams.size(), size_t(2));
    XCTAssertEqual(stats.workerThreads, 2, @"min(4, active clips)");
    for (const auto &s : stats.streams) {
        XCTAssertEqual(s.backend, "apple");
        XCTAssertTrue(s.idle);
        XCTAssertFalse(s.error.has_value());
    }

    // Playback advances by half a second: the window slides without a seek.
    const uint64_t seeksBefore = stats.streams[0].seeks;
    pool.setTargets({DecodeTarget{a, h264, -1, CMTimeMake(1, 1)}, DecodeTarget{b, hevc, -1, CMTimeMake(3, 1)}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(20)));
    XCTAssertTrue(covers(*_cache, a, 30, 60));
    XCTAssertEqual(pool.stats().streams[0].seeks, seeksBefore, @"continuation must not seek");

    // A jump re-seeks and fills the new window, with the right frames.
    const auto jump = Clock::now();
    pool.setTargets({DecodeTarget{a, h264, -1, CMTimeMake(8, 1)}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(20)));
    NSLog(@"re-seek to 8 s and fill 1 s of 1080p H.264: %.1f ms", msSince(jump));
    XCTAssertTrue(covers(*_cache, a, 240, 270));
    XCTAssertEqual(readBurnIn(_cache->get(a, 255)->image.get()), std::optional<int>(255));
    XCTAssertEqual(pool.stats().streams.size(), size_t(1), @"asset b's stream was retired");
}

- (void)testReverseWindowWithRealMedia {
    const std::string h264 = [self mediaPath:"h264_1080p30.mp4"];
    if (h264.empty()) {
        return;
    }
    DecodePool pool(BackendRouter::makeDefault(), _cache);
    pool.setTargets({DecodeTarget{AssetId(1), h264, -1, CMTimeMake(6, 1), DecodeDirection::Backward}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(20)));
    XCTAssertTrue(covers(*_cache, AssetId(1), 150, 180));
    XCTAssertEqual(readBurnIn(_cache->get(AssetId(1), 151)->image.get()), std::optional<int>(151));
    // Reverse play moves back: the stream extends its range downward.
    pool.setTargets({DecodeTarget{AssetId(1), h264, -1, CMTimeMake(55, 10), DecodeDirection::Backward}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(20)));
    XCTAssertTrue(covers(*_cache, AssetId(1), 135, 180));
}

// MARK: - Fakes: timing, priorities, lanes, errors

/// Re-targeting costs at most the frame in flight, with a deterministic gate instead of a clock:
/// the worker is held inside the decode of frame 10 while the target jumps to 5 s; once it is
/// released, the next frame it decodes must be the new target's (150), and the frame that was in
/// flight is abandoned (the fake decoder honours DecodeOptions::interrupt like the real ones).
- (void)testRetargetTakesEffectWithinOneFrameDecode {
    Gate release;
    Latch inFrame10(1);
    std::mutex m;
    std::vector<int64_t> decodedAfterRetarget;
    std::atomic<bool> retargeted{false};
    _fake->onDecode = [&](int64_t index) {
        const bool after = retargeted.load(); // Sampled when this frame's decode starts.
        if (index == 10 && !after) {
            inFrame10.countDown();
            release.pass();
        }
        if (after) {
            std::lock_guard<std::mutex> lock(m);
            decodedAfterRetarget.push_back(index);
        }
    };
    DecodePool pool(_fakeRouter, _cache);
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, kCMTimeZero}});
    XCTAssertTrue(inFrame10.wait(std::chrono::seconds(10)), @"the worker is decoding frame 10");
    retargeted = true;
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, CMTimeMake(5, 1)}});
    release.open();
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    {
        std::lock_guard<std::mutex> lock(m);
        XCTAssertFalse(decodedAfterRetarget.empty());
        if (!decodedAfterRetarget.empty()) {
            XCTAssertEqual(decodedAfterRetarget.front(), 150, @"the first frame after the re-target is the new one");
        }
        for (int64_t index : decodedAfterRetarget) {
            XCTAssertGreaterThanOrEqual(index, 150, @"no old-window frame decoded after the re-target");
        }
    }
    XCTAssertGreaterThanOrEqual(_fake->interrupted.load(), 1, @"the frame in flight was abandoned");
    XCTAssertFalse(_cache->contains(AssetId(1), int64_t(10)), @"the abandoned frame never reached the cache");
    XCTAssertGreaterThanOrEqual(pool.stats().streams.at(0).interrupts, uint64_t(1));
    XCTAssertTrue(covers(*_cache, AssetId(1), 150, 180));
    XCTAssertFalse(covers(*_cache, AssetId(1), 0, 30), @"the old window was abandoned");
}

/// The same with a real decoder: a far seek into a 5 s GOP of 1080p H.264, decoded in software
/// (so the preroll is long), then a re-target elsewhere while that preroll runs. The decode in
/// flight must be abandoned, not finished: the old target's frame never reaches the cache, and
/// the new window is covered after at most one frame of the old preroll per poll (compared with
/// the time the full preroll takes in the same run, not with an absolute clock).
- (void)testRetargetAbandonsAFarPrerollWithARealDecoder {
    const std::string path = [self mediaPath:"gop5s_h264_1080p30.mp4"];
    if (path.empty()) {
        return;
    }
    auto router = std::make_shared<BackendRouter>();
    XCTAssertTrue(router->registerBackend(ffmpeg::makeFFmpegBackend()).ok());
    DecodePool::Config config;
    config.decodeOptions.allowHardware = false;
    const CMTime fd = CMTimeMake(1, 30);
    const AssetId asset(1);

    // Reference: how long the full preroll to frame 148 (deep in the first GOP) takes.
    double fullPrerollMs = 0;
    {
        auto cache = std::make_shared<FrameCache>();
        DecodePool pool(router, cache, config);
        pool.setTargets({DecodeTarget{asset, path, -1, CMTimeMake(1, 30)}}); // Open first.
        XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(30)));
        const auto start = Clock::now();
        pool.setTargets({DecodeTarget{asset, path, -1, CMTimeMultiply(fd, 148)}});
        XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(30)));
        fullPrerollMs = msSince(start);
        XCTAssertTrue(cache->contains(asset, int64_t(148)));
    }

    auto cache = std::make_shared<FrameCache>();
    DecodePool pool(router, cache, config);
    pool.setTargets({DecodeTarget{asset, path, -1, CMTimeMake(1, 30)}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(30)));
    if (fullPrerollMs < 60) {
        XCTSkip(@"the full preroll took only %.1f ms: too short to interrupt deterministically", fullPrerollMs);
    }
    pool.setTargets({DecodeTarget{asset, path, -1, CMTimeMultiply(fd, 148)}}); // Far: seek + long preroll.
    // Wait until the worker has seeked and is inside the preroll (well before it can finish).
    const auto deadline = Clock::now() + std::chrono::seconds(10);
    while (pool.stats().streams.at(0).seeks < 1 && Clock::now() < deadline) {
        std::this_thread::yield();
    }
    std::this_thread::sleep_for(std::chrono::duration<double, std::milli>(fullPrerollMs / 6));
    XCTAssertFalse(cache->contains(asset, int64_t(148)), @"re-targeting while the preroll is still running");
    const auto retarget = Clock::now();
    pool.setTargets({DecodeTarget{asset, path, -1, CMTimeMultiply(fd, 250)}}); // Second GOP.
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(30)));
    const double retargetMs = msSince(retarget);
    const auto stats = pool.stats().streams.at(0);
    NSLog(@"real decoder: full preroll %.1f ms; re-target during it to the next GOP and fill: %.1f ms; %llu "
          @"interrupts",
          fullPrerollMs, retargetMs, stats.interrupts);
    XCTAssertGreaterThanOrEqual(stats.interrupts, uint64_t(1), @"the preroll in flight was interrupted");
    XCTAssertFalse(cache->contains(asset, int64_t(148)), @"the abandoned target was never decoded");
    XCTAssertTrue(covers(*cache, asset, 250, 260));
    XCTAssertEqual(readBurnIn(cache->get(asset, int64_t(250))->image.get()), std::optional<int>(250));
}

- (void)testPriorityOrdersStreamsOnASingleThread {
    _fake->decodeDelay = std::chrono::milliseconds(1);
    std::mutex m;
    std::vector<int64_t> order; // Slots, in decode order; asset A decodes from 0, B from 150.
    _fake->onDecode = [&](int64_t index) {
        std::lock_guard<std::mutex> lock(m);
        order.push_back(index);
    };
    DecodePool::Config config;
    config.maxThreads = 1;
    DecodePool pool(_fakeRouter, _cache, config);
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, kCMTimeZero, DecodeDirection::Forward, 0},
                     DecodeTarget{AssetId(2), "/fake/b.mov", -1, CMTimeMake(5, 1), DecodeDirection::Forward, 10}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertEqual(pool.stats().workerThreads, 1);
    std::lock_guard<std::mutex> lock(m);
    XCTAssertGreaterThanOrEqual(order.size(), size_t(62));
    for (size_t i = 0; i < 31 && i < order.size(); ++i) {
        XCTAssertGreaterThanOrEqual(order[i], 150, @"the high-priority stream fills first (position %zu)", i);
    }
    XCTAssertTrue(covers(*_cache, AssetId(1), 0, 30));
    XCTAssertTrue(covers(*_cache, AssetId(2), 150, 180));
}

- (void)testLanesAllowTwoWindowsOnOneAsset {
    DecodePool pool(_fakeRouter, _cache);
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, kCMTimeZero, DecodeDirection::Forward, 0, 1},
                     DecodeTarget{AssetId(1), "/fake/a.mov", -1, CMTimeMake(6, 1), DecodeDirection::Forward, 0, 2}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertTrue(covers(*_cache, AssetId(1), 0, 30));
    XCTAssertTrue(covers(*_cache, AssetId(1), 180, 210));
    XCTAssertEqual(_fake->opens.load(), 2, @"one decoder per lane");
}

- (void)testBackwardWindowAndEndOfStream {
    DecodePool pool(_fakeRouter, _cache);
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, CMTimeMake(5, 1), DecodeDirection::Backward}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertTrue(covers(*_cache, AssetId(1), 120, 150));
    // Near the end the window is clipped by end of stream and the stream settles.
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, CMTimeMake(99, 10)}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertTrue(covers(*_cache, AssetId(1), 297, 299));
    // Past the end: nothing to decode, no error.
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, CMTimeMake(20, 1)}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertFalse(pool.stats().streams.at(0).error.has_value());
}

- (void)testLostFramesAreRestoredAndLookaheadIsAdjustable {
    DecodePool pool(_fakeRouter, _cache);
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, CMTimeMake(1, 1)}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    _cache->purge(AssetId(1)); // e.g. memory pressure
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, CMTimeMake(31, 30)}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertTrue(_cache->contains(AssetId(1), 31), @"the frame under the playhead is re-decoded");

    pool.setLookahead(CMTimeMake(2, 1));
    XCTAssertEqual(CMTimeCompare(pool.lookahead(), CMTimeMake(2, 1)), 0);
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertTrue(covers(*_cache, AssetId(1), 31, 91));
}

/// A dissolve between two 4K 10-bit streams (24.9 MB per frame) with the default 512 MB
/// budget: a 1 s window per stream would need about 1.5 GB. Playback is simulated frame by
/// frame the way the render thread uses the cache (the shown frames stay pinned until the next
/// ones are acquired); the frame under the playhead of both streams must be in the cache every
/// time the pool has settled.
- (void)testNoPlayheadMissesAcrossA4KDissolveWithTheDefaultBudget {
    _fake->width = 3840;
    _fake->height = 2160;
    _fake->pixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    auto cache = std::make_shared<FrameCache>(); // Default budget.
    DecodePool pool(_fakeRouter, cache);
    const CMTime fd = CMTimeMake(1, 30);
    const AssetId a(1), b(2);
    std::vector<FrameCache::PinnedFrame> shown;
    int misses = 0;
    size_t worstUnpinnedBytes = 0;
    for (int k = 0; k < 60; ++k) {
        const CMTime t = CMTimeMultiply(fd, k);
        pool.setTargets({DecodeTarget{a, "/fake/a.mov", -1, t}, DecodeTarget{b, "/fake/b.mov", -1, t}});
        XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(20)));
        std::vector<FrameCache::PinnedFrame> next;
        for (AssetId asset : {a, b}) {
            FrameCache::PinnedFrame pin = cache->acquire(asset, FrameCache::frameIndex(t, fd));
            if (!pin) {
                ++misses;
            }
            next.push_back(std::move(pin));
        }
        shown = std::move(next);
        const FrameCache::Stats st = cache->stats();
        worstUnpinnedBytes = std::max(worstUnpinnedBytes, st.bytes - st.pinnedBytes);
    }
    const auto streams = pool.stats().streams;
    NSLog(@"4K dissolve: %d playhead misses in 60 frames x 2 streams; cache %zu MB (budget %zu MB); window %.3f s "
          @"(%zu bytes per frame)",
          misses, worstUnpinnedBytes >> 20, cache->budget() >> 20,
          streams.empty() ? 0.0 : CMTimeGetSeconds(streams[0].window), streams.empty() ? size_t(0) : streams[0].frameBytes);
    for (const auto &st : streams) {
        // An equal share of 75 % of the budget: floor(0.75 * 512 MB / 2 / frameBytes) frames.
        const auto frames = static_cast<int64_t>(std::floor(0.75 * static_cast<double>(cache->budget()) / 2.0 /
                                                            static_cast<double>(st.frameBytes)));
        XCTAssertEqual(CMTimeCompare(st.window, CMTimeMultiply(fd, static_cast<int32_t>(frames))), 0,
                       @"window %.4f s, wanted %lld frames", CMTimeGetSeconds(st.window), frames);
    }
    XCTAssertEqual(misses, 0, @"playhead frames missing from the cache after the pool settled");
    XCTAssertLessThanOrEqual(worstUnpinnedBytes, cache->budget());
}

- (void)testOpenFailureIsReportedAndDoesNotSpin {
    _fake->failOpen = true;
    DecodePool pool(_fakeRouter, _cache);
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, kCMTimeZero}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    for (int i = 1; i <= 5; ++i) {
        pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, CMTimeMake(i, 30)}});
    }
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    const auto stats = pool.stats();
    XCTAssertTrue(stats.streams.at(0).failed);
    XCTAssertTrue(stats.streams.at(0).error.has_value());
    XCTAssertEqual(stats.streams.at(0).error->code, MediaErrorCode::DecodeFailed);
    XCTAssertEqual(_fake->opens.load(), 1, @"a failed stream stays failed until reopened");
    // Relinking (invalidate) retries.
    _fake->failOpen = false;
    pool.invalidate(AssetId(1));
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertFalse(pool.stats().streams.at(0).failed);
    XCTAssertTrue(_cache->contains(AssetId(1), 5));

    // Unknown path.
    pool.setTargets({DecodeTarget{AssetId(9), "", -1, kCMTimeZero}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertEqual(pool.stats().streams.at(0).error->code, MediaErrorCode::InvalidArgument);
}

/// invalidate() while a failing open is in flight: the stale failure must not stick; the
/// stream reopens (and succeeds, the cause having been fixed).
- (void)testReopenRequestedDuringAFailingOpenWins {
    Gate release;
    Latch inOpen(1);
    std::atomic<int> opens{0};
    _fake->failOpen = true;
    _fake->onOpen = [&] {
        if (opens++ == 0) {
            inOpen.countDown();
            release.pass();
        }
    };
    DecodePool pool(_fakeRouter, _cache);
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, kCMTimeZero}});
    XCTAssertTrue(inOpen.wait(std::chrono::seconds(10)));
    _fake->failOpen = false; // e.g. the user relinked the file...
    pool.invalidate(AssetId(1)); // ...while the old open is still failing.
    release.open();
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    const auto stats = pool.stats().streams.at(0);
    XCTAssertFalse(stats.failed, @"the failure of the superseded open is stale");
    XCTAssertTrue(_cache->contains(AssetId(1), int64_t(0)));
    XCTAssertEqual(opens.load(), 2);
}

/// A transient probe error (a load timeout) is neither cached nor sticky: the next target move
/// probes again and the stream recovers.
- (void)testTransientProbeFailureIsRetried {
    std::atomic<int> calls{0};
    _fake->probe = [&](const std::string &p) -> Result<MediaInfo> {
        if (calls++ == 0) {
            return makeError(MediaErrorCode::Timeout, "loading timed out");
        }
        return makeFakeInfo(p, "mov", fourcc::H264);
    };
    DecodePool pool(_fakeRouter, _cache);
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, kCMTimeZero}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    auto stats = pool.stats().streams.at(0);
    XCTAssertTrue(stats.failed);
    XCTAssertTrue(stats.error && stats.error->code == MediaErrorCode::Timeout);
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, CMTimeMake(1, 30)}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    stats = pool.stats().streams.at(0);
    XCTAssertFalse(stats.failed, @"recovered on the next target move");
    XCTAssertEqual(calls.load(), 2, @"probed again: the timeout was not cached");
    XCTAssertTrue(_cache->contains(AssetId(1), int64_t(1)));
    // A permanent failure still stays failed (and is not re-probed) until invalidated.
    _fake->failOpen = true;
    pool.invalidate(AssetId(1));
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    const int opensBefore = _fake->opens.load();
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, CMTimeMake(2, 1)}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertTrue(pool.stats().streams.at(0).failed);
    XCTAssertEqual(_fake->opens.load(), opensBefore, @"a permanent failure is not retried on target moves");
}

/// The first frame of a clip with a leading empty edit is presented at 0.5 s; the decoder
/// returns it for any earlier time, and the cache must answer the same for the gap (the pool
/// records the seek target the frame answered).
- (void)testLeadingGapIsCoveredByTheFirstFrame {
    const std::string path = [self mediaPath:"leading_gap_h264.mov"];
    if (path.empty()) {
        return;
    }
    DecodePool pool(BackendRouter::makeDefault(), _cache);
    pool.setTargets({DecodeTarget{AssetId(1), path, -1, CMTimeMake(1, 5)}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(20)));
    auto frame = _cache->get(AssetId(1), CMTimeMake(1, 5));
    XCTAssertTrue(frame.has_value(), @"0.2 s, inside the leading gap, is answered");
    if (frame) {
        XCTAssertEqual(readBurnIn(frame->image.get()), std::optional<int>(0));
        XCTAssertEqual(CMTimeCompare(frame->pts, CMTimeMake(1, 2)), 0);
    }
    XCTAssertTrue(_cache->contains(AssetId(1), FrameCache::frameIndex(CMTimeMake(1, 5), CMTimeMake(1, 30))),
                  @"the playback frame source's slot lookup agrees");
}

/// Variable frame rate through the pool and the slot lookups the playback frame source uses:
/// with the asset's frame duration (the shortest frame, 1/60 s), every slot of the playhead's
/// window is answered, by the frame the decoder shows at the slot's start.
- (void)testVariableFrameRateWindowHasNoMisses {
    const std::string path = [self mediaPath:"vfr_h264.mp4"];
    if (path.empty()) {
        return;
    }
    const CMTime fd = CMTimeMake(10, 600); // TrackInfo::frameDuration of the VFR clip.
    DecodePool pool(BackendRouter::makeDefault(), _cache);
    int misses = 0;
    int wrong = 0;
    for (int64_t slot = 0; slot < 240; slot += 7) {
        const CMTime t = timeForFrame(slot, fd);
        pool.setTargets({DecodeTarget{AssetId(1), path, -1, t}});
        XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(20)));
        for (int64_t k = slot; k < slot + 30; ++k) { // The next half second of slots.
            FrameCache::PinnedFrame pin = _cache->acquire(AssetId(1), k);
            if (!pin) {
                ++misses;
                continue;
            }
            if (readBurnIn(pin.image().get()) != std::optional<int>(vfrFrameAt(timeForFrame(k, fd)))) {
                ++wrong;
            }
        }
    }
    XCTAssertEqual(misses, 0, @"slots of the window without a frame");
    XCTAssertEqual(wrong, 0, @"slots answered with a frame not shown at the slot's start");
}

- (void)testRemovedTargetsReleaseTheirDecoders {
    DecodePool pool(_fakeRouter, _cache);
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov"}, DecodeTarget{AssetId(2), "/fake/b.mov"}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertEqual(_fake->liveDecoders.load(), 2);
    pool.setTargets({DecodeTarget{AssetId(2), "/fake/b.mov"}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertEqual(_fake->liveDecoders.load(), 1);
    pool.setTargets({});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertEqual(_fake->liveDecoders.load(), 0);
}

// MARK: - Scrub

/// Lanes keep independent clients apart: a request for the same asset in another lane neither
/// cancels nor interrupts the one being serviced.
- (void)testScrubLanesDoNotSupersedeEachOther {
    Gate firstSeek;
    Latch inFirstSeek(1);
    std::atomic<int> seekCount{0};
    _fake->onSeek = [&](CMTime) {
        if (seekCount++ == 0) {
            inFirstSeek.countDown();
            firstSeek.pass();
        }
    };
    ScrubLog log;
    DecodePool pool(_fakeRouter, _cache);
    pool.registerAsset(AssetId(1), "/fake/a.mov");
    pool.requestFrame(AssetId(1), CMTimeMake(1, 1), log.callback(1), 7);
    XCTAssertTrue(inFirstSeek.wait(std::chrono::seconds(5)));
    pool.requestFrame(AssetId(1), CMTimeMake(4, 1), log.callback(2), 8);
    firstSeek.open();
    XCTAssertTrue(log.waitFor(2, std::chrono::seconds(10)));
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    std::lock_guard<std::mutex> lock(log.mutex);
    XCTAssertTrue(log.results[1].at(0).ok(), @"lane 7 is not superseded by lane 8");
    XCTAssertTrue(log.results[2].at(0).ok());
    if (log.results[1].at(0).ok() && log.results[2].at(0).ok()) {
        XCTAssertEqual(readBurnIn(log.results[1].at(0).value().image.get()), std::optional<int>(30));
        XCTAssertEqual(readBurnIn(log.results[2].at(0).value().image.get()), std::optional<int>(120));
    }
    XCTAssertEqual(pool.stats().scrubCancelled, uint64_t(0));
}

- (void)testScrubCoalescingDropsStaleRequestsAndCallsEachCallbackOnce {
    Gate firstSeek;
    Latch inFirstSeek(1);
    std::atomic<int> seekCount{0};
    _fake->onSeek = [&](CMTime) {
        if (seekCount++ == 0) {
            inFirstSeek.countDown();
            firstSeek.pass();
        }
    };
    ScrubLog log;
    DecodePool pool(_fakeRouter, _cache);
    pool.registerAsset(AssetId(1), "/fake/a.mov");
    pool.registerAsset(AssetId(2), "/fake/b.mov");
    pool.requestFrame(AssetId(1), CMTimeMake(1, 1), log.callback(1));
    XCTAssertTrue(inFirstSeek.wait(std::chrono::seconds(5)), @"request 1 is being serviced");
    // While request 1 is in flight: three more for asset 1 (only the last survives) and one
    // for asset 2.
    pool.requestFrame(AssetId(1), CMTimeMake(2, 1), log.callback(2));
    pool.requestFrame(AssetId(2), CMTimeMake(4, 1), log.callback(5));
    pool.requestFrame(AssetId(1), CMTimeMake(3, 1), log.callback(3));
    pool.requestFrame(AssetId(1), CMTimeMake(7, 2), log.callback(4));
    firstSeek.open();
    XCTAssertTrue(log.waitFor(5, std::chrono::seconds(10)));
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));

    std::lock_guard<std::mutex> lock(log.mutex);
    for (auto &[id, calls] : log.results) {
        XCTAssertEqual(calls.size(), size_t(1), @"callback %d invoked %zu times", id, calls.size());
    }
    auto frameOf = [&](int id) -> std::optional<int> {
        const auto &r = log.results[id].at(0);
        return r.ok() ? readBurnIn(r.value().image.get()) : std::nullopt;
    };
    // Request 1 was being decoded when newer requests for the same asset arrived: its decode is
    // interrupted (a scrub must not wait for a stale preroll) and it completes with Cancelled.
    XCTAssertEqual(log.results[1].at(0).error().code, MediaErrorCode::Cancelled);
    XCTAssertEqual(log.results[2].at(0).error().code, MediaErrorCode::Cancelled);
    XCTAssertEqual(log.results[3].at(0).error().code, MediaErrorCode::Cancelled);
    XCTAssertEqual(frameOf(4), std::optional<int>(105));
    XCTAssertEqual(log.results[4].at(0).value().frameIndex, 105);
    XCTAssertEqual(frameOf(5), std::optional<int>(120));
    const auto stats = pool.stats();
    XCTAssertEqual(stats.scrubRequests, uint64_t(5));
    XCTAssertEqual(stats.scrubServiced, uint64_t(2));
    XCTAssertEqual(stats.scrubCancelled, uint64_t(3));
    XCTAssertTrue(_cache->contains(AssetId(1), 105), @"scrubbed frames land in the cache");
}

- (void)testScrubServesFromCacheAndReportsErrors {
    ScrubLog log;
    DecodePool pool(_fakeRouter, _cache);
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov"}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    const int seeksBefore = _fake->seeks.load();
    pool.requestFrame(AssetId(1), CMTimeMake(1, 3), log.callback(1));
    pool.requestFrame(AssetId(77), CMTimeMake(1, 3), log.callback(2)); // Unknown asset.
    XCTAssertTrue(log.waitFor(2, std::chrono::seconds(10)));
    std::lock_guard<std::mutex> lock(log.mutex);
    XCTAssertTrue(log.results[1].at(0).ok());
    XCTAssertTrue(log.results[1].at(0).value().fromCache);
    XCTAssertEqual(log.results[1].at(0).value().frameIndex, 10);
    XCTAssertEqual(_fake->seeks.load(), seeksBefore, @"a cache hit does not decode");
    XCTAssertEqual(log.results[2].at(0).error().code, MediaErrorCode::InvalidArgument);
    XCTAssertEqual(pool.stats().scrubFailed, uint64_t(1));
}

- (void)testScrubWithRealMediaIncludingPastTheEnd {
    const std::string hevc = [self mediaPath:"hevc_720p2997.mov"];
    if (hevc.empty()) {
        return;
    }
    ScrubLog log;
    DecodePool pool(BackendRouter::makeDefault(), _cache);
    pool.registerAsset(AssetId(1), hevc);
    const CMTime fd = CMTimeMake(1001, 30000);
    const int expected[] = {0, 77, 200, 13, 299};
    int id = 0;
    for (int frame : expected) {
        const auto start = Clock::now();
        pool.requestFrame(AssetId(1), CMTimeAdd(CMTimeMultiply(fd, frame), CMTimeMake(1, 1000)), log.callback(id));
        XCTAssertTrue(log.waitFor(static_cast<size_t>(id + 1), std::chrono::seconds(10)));
        NSLog(@"scrub to frame %d: %.1f ms", frame, msSince(start));
        ++id;
    }
    pool.requestFrame(AssetId(1), CMTimeMake(60, 1), log.callback(id)); // Past the end: last frame.
    XCTAssertTrue(log.waitFor(static_cast<size_t>(id + 1), std::chrono::seconds(10)));
    std::lock_guard<std::mutex> lock(log.mutex);
    for (int i = 0; i < 5; ++i) {
        const auto &r = log.results[i].at(0);
        XCTAssertTrue(r.ok(), @"%d: %s", i, r.ok() ? "" : r.error().description().c_str());
        if (r.ok()) {
            XCTAssertEqual(readBurnIn(r.value().image.get()), std::optional<int>(expected[i]));
            XCTAssertEqual(r.value().frameIndex, expected[i]);
        }
    }
    const auto &last = log.results[id].at(0);
    XCTAssertTrue(last.ok());
    if (last.ok()) {
        XCTAssertEqual(readBurnIn(last.value().image.get()), std::optional<int>(299));
    }
}

// MARK: - Shutdown

- (void)testDestructorJoinsAndCancelsPendingScrubs {
    Gate firstSeek;
    Latch inFirstSeek(1);
    std::atomic<int> seekCount{0};
    _fake->onSeek = [&](CMTime) {
        if (seekCount++ == 0) {
            inFirstSeek.countDown();
            firstSeek.pass();
        }
    };
    _fake->decodeDelay = std::chrono::milliseconds(5);
    ScrubLog log;
    std::thread opener;
    {
        DecodePool pool(_fakeRouter, _cache);
        pool.setTargets({DecodeTarget{AssetId(3), "/fake/c.mov"}, DecodeTarget{AssetId(4), "/fake/d.mov"}});
        pool.registerAsset(AssetId(1), "/fake/a.mov");
        pool.registerAsset(AssetId(2), "/fake/b.mov");
        pool.requestFrame(AssetId(1), CMTimeMake(1, 1), log.callback(1));
        XCTAssertTrue(inFirstSeek.wait(std::chrono::seconds(5)));
        pool.requestFrame(AssetId(2), CMTimeMake(1, 1), log.callback(2));
        // Release the in-flight scrub shortly after destruction has begun.
        opener = std::thread([&] {
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            firstSeek.open();
        });
        // ~DecodePool runs here.
    }
    // Everything completed before the destructor returned: no callback can arrive later.
    {
        std::lock_guard<std::mutex> lock(log.mutex);
        XCTAssertEqual(log.results.size(), size_t(2));
        XCTAssertEqual(log.results[1].size(), size_t(1));
        XCTAssertEqual(log.results[2].size(), size_t(1));
        // Shutdown interrupts the decode in flight: it completes (once) with Cancelled.
        XCTAssertEqual(log.results[1].at(0).error().code, MediaErrorCode::Cancelled);
        XCTAssertEqual(log.results[2].at(0).error().code, MediaErrorCode::Cancelled);
    }
    XCTAssertEqual(_fake->liveDecoders.load(), 0, @"every decoder was destroyed");
    opener.join();
}

/// Destruction abandons decodes in flight: with both workers held inside a frame decode, the
/// destructor (on another thread) cannot finish, and once they are released it finishes without
/// decoding another frame: nothing waits for a window to fill.
- (void)testDestructorIsPromptWhileDecoding {
    Gate release;
    Latch bothDecoding(2);
    std::atomic<int> started{0};
    std::atomic<bool> destroying{false};
    std::atomic<int> decodedWhileDestroying{0};
    _fake->onDecode = [&](int64_t) {
        if (destroying) {
            ++decodedWhileDestroying;
        }
        if (started++ < 2) {
            bothDecoding.countDown();
            release.pass();
        }
    };
    auto pool = std::make_unique<DecodePool>(_fakeRouter, _cache);
    pool->setTargets({DecodeTarget{AssetId(1), "/fake/a.mov"}, DecodeTarget{AssetId(2), "/fake/b.mov"}});
    XCTAssertTrue(bothDecoding.wait(std::chrono::seconds(10)));
    Latch destroyed(1);
    destroying = true;
    std::thread destroyer([&] {
        pool.reset();
        destroyed.countDown();
    });
    XCTAssertFalse(destroyed.wait(std::chrono::milliseconds(50)), @"cannot finish while a decode is blocked");
    release.open();
    XCTAssertTrue(destroyed.wait(std::chrono::seconds(10)));
    destroyer.join();
    XCTAssertEqual(decodedWhileDestroying.load(), 0, @"no frame decode started after destruction began");
    XCTAssertEqual(_fake->liveDecoders.load(), 0);
}

// MARK: - Stale publication (review 2026-09-23, finding 1)

/// A frame whose decode was in flight when its stream was removed (setTargets({}), as when a
/// project closes) must not land in the cache after the cache was purged: with the removal and
/// the purge done, nothing of the old stream may appear.
- (void)testARemovedStreamCannotPublishAfterAPurge {
    _fake->honorInterrupt = false; // a decode that cannot be abandoned mid-frame (VideoToolbox)
    Gate release;
    Latch inDecode(1);
    std::atomic<int> calls{0};
    _fake->onDecode = [&](int64_t) {
        if (calls++ == 0) {
            inDecode.countDown();
            release.pass();
        }
    };
    DecodePool pool(_fakeRouter, _cache);
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov"}});
    XCTAssertTrue(inDecode.wait(std::chrono::seconds(10)), @"the worker is inside the first frame's decode");
    pool.setTargets({});
    _cache->purgeAll();
    release.open();
    // The worker finishes the frame, then destroys the removed stream's decoder.
    const auto deadline = Clock::now() + std::chrono::seconds(10);
    while ((_fake->framesDecoded.load() < 1 || _fake->liveDecoders.load() > 0) && Clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    XCTAssertEqual(_fake->framesDecoded.load(), 1);
    XCTAssertEqual(_fake->liveDecoders.load(), 0);
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertEqual(_cache->stats().count, size_t(0), @"the removed stream published a frame after the purge");
}

/// The same for a relink: frames of the old file decoded while the asset was pointed at another
/// file must not be published under the asset (the cache may only receive frames decoded from
/// the new file).
- (void)testFramesOfTheOldFileAreNotPublishedAfterARelink {
    _fake->honorInterrupt = false;
    Gate release;
    Latch inDecode(1);
    std::atomic<int> calls{0};
    _fake->onDecode = [&](int64_t) {
        if (calls++ == 0) {
            inDecode.countDown();
            release.pass();
        }
    };
    DecodePool pool(_fakeRouter, _cache);
    pool.registerAsset(AssetId(1), "/fake/old.mov");
    pool.setTargets({DecodeTarget{AssetId(1), "", -1, kCMTimeZero}});
    XCTAssertTrue(inDecode.wait(std::chrono::seconds(10)));
    pool.registerAsset(AssetId(1), "/fake/new.mov"); // relink while the old file's frame decodes
    _cache->purge(AssetId(1));
    _cache->resetStats();
    const int decodedBeforeRelink = calls.load();
    release.open();
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    const int decodedFromNewFile = calls.load() - decodedBeforeRelink;
    XCTAssertGreaterThan(decodedFromNewFile, 0, @"the stream reopened on the new file");
    XCTAssertEqual(_cache->stats().insertions, uint64_t(decodedFromNewFile),
                   @"only frames of the new file were published");
}

// MARK: - Two pools on one cache (review 2026-09-23, finding 4)

/// The program and source monitors each have a pool on the shared cache. Each pool's playhead
/// must stay protected from eviction whatever the other pool (or an unfocused client) puts: the
/// cache keeps both pools' focus, and each pool keeps its windows within its share.
- (void)testTwoPoolsOnOneSmallCacheKeepBothPlayheads {
    DecodePool::Config programConfig;
    programConfig.budgetFraction = 0.5;
    DecodePool::Config sourceConfig;
    sourceConfig.budgetFraction = 0.25;
    DecodePool program(_fakeRouter, _cache, programConfig);
    DecodePool source(_fakeRouter, _cache, sourceConfig);

    // Learn the size of one decoded frame, then give the cache room for 20 of them.
    program.setTargets({DecodeTarget{AssetId(1), "/fake/program.mov", -1, kCMTimeZero}});
    XCTAssertTrue(program.waitUntilIdle(std::chrono::seconds(10)));
    const size_t frameBytes = program.stats().streams.at(0).frameBytes;
    XCTAssertGreaterThan(frameBytes, size_t(0));
    _cache->setBudget(20 * frameBytes);

    const CMTime programAt = CMTimeMake(2, 1);
    const CMTime sourceAt = CMTimeMake(3, 1);
    program.setTargets({DecodeTarget{AssetId(1), "/fake/program.mov", -1, programAt}});
    source.setTargets({DecodeTarget{AssetId(2), "/fake/source.mov", -1, sourceAt}});
    XCTAssertTrue(program.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertTrue(source.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertTrue(_cache->contains(AssetId(1), programAt));
    XCTAssertTrue(_cache->contains(AssetId(2), sourceAt));
    XCTAssertLessThanOrEqual(_cache->stats().bytes, size_t(20) * frameBytes);

    // Another client fills the cache with frames nobody is playing (scrubbed frames of a third
    // asset): they are evicted before either playhead.
    for (int i = 0; i < 40; ++i) {
        CVPixelBufferRef buffer = nullptr;
        NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{}};
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, size_t(_fake->width), size_t(_fake->height),
                                           kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attributes, &buffer),
                       kCVReturnSuccess);
        XCTAssertTrue(_cache->put(AssetId(3), PixelBuffer::adopt(buffer), CMTimeMake(i, 30), CMTimeMake(1, 30),
                                  CMTimeMake(1, 30)));
    }
    XCTAssertTrue(_cache->contains(AssetId(1), programAt), @"the program's playhead frame was evicted");
    XCTAssertTrue(_cache->contains(AssetId(2), sourceAt), @"the source monitor's playhead frame was evicted");
    XCTAssertTrue(_cache->contains(AssetId(1), programAt + CMTimeMake(1, 30)));
    XCTAssertTrue(_cache->contains(AssetId(2), sourceAt + CMTimeMake(1, 30)));
}

// MARK: - Media epochs (review 2026-09-23, finding 1)

/// beginEpoch (another project was opened): a stream decode in flight is not published, every
/// stream and decoder is gone, and the asset ids are unknown until registered again.
- (void)testBeginEpochDropsStreamsAndTheirFramesInFlight {
    _fake->honorInterrupt = false;
    Gate release;
    Latch inDecode(1);
    std::atomic<int> calls{0};
    _fake->onDecode = [&](int64_t) {
        if (calls++ == 0) {
            inDecode.countDown();
            release.pass();
        }
    };
    DecodePool pool(_fakeRouter, _cache);
    pool.registerAsset(AssetId(1), "/fake/a.mov");
    pool.setTargets({DecodeTarget{AssetId(1), "", -1, kCMTimeZero}});
    XCTAssertTrue(inDecode.wait(std::chrono::seconds(10)));
    const FrameCache::Epoch epoch = _cache->beginEpoch();
    pool.beginEpoch(epoch);
    release.open();
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)), @"idle covers the removed stream's step");
    XCTAssertEqual(_fake->liveDecoders.load(), 0);
    XCTAssertEqual(_cache->stats().count, size_t(0), @"the previous epoch's frame was published");
    XCTAssertTrue(pool.stats().streams.empty());

    // Asset 1 of the new epoch is unknown until registered: a request fails instead of
    // decoding the previous epoch's file.
    ScrubLog log;
    pool.requestFrame(AssetId(1), kCMTimeZero, log.callback(0));
    XCTAssertTrue(log.waitFor(1, std::chrono::seconds(10)));
    {
        std::lock_guard<std::mutex> lock(log.mutex);
        XCTAssertFalse(log.results[0].at(0).ok());
        XCTAssertEqual(log.results[0].at(0).error().code, MediaErrorCode::InvalidArgument);
    }
    pool.registerAsset(AssetId(1), "/fake/b.mov");
    pool.setTargets({DecodeTarget{AssetId(1), "", -1, kCMTimeZero}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertTrue(_cache->contains(AssetId(1), kCMTimeZero), @"the new epoch's file decodes");
}

/// beginEpoch cancels pending scrub requests, turns the one in flight into Cancelled (its frame
/// is neither cached nor delivered) and destroys the scrub decoders.
- (void)testBeginEpochCancelsScrubRequestsAndDropsScrubDecoders {
    _fake->honorInterrupt = false;
    DecodePool pool(_fakeRouter, _cache);
    pool.registerAsset(AssetId(1), "/fake/a.mov");
    ScrubLog log;
    pool.requestFrame(AssetId(1), CMTimeMake(1, 1), log.callback(0), 1); // opens a scrub decoder
    XCTAssertTrue(log.waitFor(1, std::chrono::seconds(10)));
    XCTAssertEqual(_fake->liveDecoders.load(), 1);

    Gate release;
    Latch inDecode(1);
    std::atomic<int> calls{0};
    _fake->onDecode = [&](int64_t) {
        if (calls++ == 0) {
            inDecode.countDown();
            release.pass();
        }
    };
    pool.requestFrame(AssetId(1), CMTimeMake(5, 1), log.callback(1), 1); // in flight (blocked)
    XCTAssertTrue(inDecode.wait(std::chrono::seconds(10)));
    pool.requestFrame(AssetId(1), CMTimeMake(6, 1), log.callback(2), 2); // pending
    const FrameCache::Epoch epoch = _cache->beginEpoch();
    pool.beginEpoch(epoch);
    release.open();
    XCTAssertTrue(log.waitFor(3, std::chrono::seconds(10)));
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    {
        std::lock_guard<std::mutex> lock(log.mutex);
        XCTAssertTrue(log.results[0].at(0).ok());
        for (int id : {1, 2}) {
            XCTAssertEqual(log.results[id].size(), size_t(1), @"request %d answered once", id);
            XCTAssertFalse(log.results[id].at(0).ok());
            XCTAssertEqual(log.results[id].at(0).error().code, MediaErrorCode::Cancelled, @"request %d", id);
        }
    }
    XCTAssertEqual(_cache->stats().count, size_t(0));
    XCTAssertEqual(_fake->liveDecoders.load(), 0, @"the scrub decoder of the previous epoch was destroyed");
}

// MARK: - End of the video

/// Media whose pictures end (2 s, 60 frames) before the track's duration (10 s): a stream that
/// plays into the end holds the last frame for every later time; one targeted far past the end
/// (its seek finds nothing) searches back for the last frame and holds it; the scrub path does
/// the same. StreamStats says where the video ends.
- (void)testTheLastFrameIsHeldPastTheEndOfTheVideo {
    _fake->frames = 60;
    const AssetId asset(1);
    DecodePool pool(_fakeRouter, _cache);
    pool.setTargets({DecodeTarget{asset, "/fake/short.mov", -1, CMTimeMake(3, 2)}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    DecodePool::StreamStats stream = pool.stats().streams.at(0);
    XCTAssertTrue(stream.eof);
    XCTAssertEqual(CMTimeCompare(stream.videoEnd, CMTimeMake(2, 1)), 0, @"%.4f s", CMTimeGetSeconds(stream.videoEnd));
    XCTAssertFalse(stream.error.has_value());
    for (CMTime t : {CMTimeMake(2, 1), CMTimeMake(5, 2), CMTimeMake(9, 1)}) {
        auto frame = _cache->get(asset, t);
        XCTAssertTrue(frame.has_value(), @"%.2f s", CMTimeGetSeconds(t));
        if (frame) {
            XCTAssertEqual(readBurnIn(frame->image.get()), std::optional<int>(59), @"%.2f s", CMTimeGetSeconds(t));
        }
    }
    XCTAssertTrue(_cache->contains(asset, int64_t(250)), @"slot lookups too (the program monitor, export)");

    // Far past the end with nothing cached: the seek lands after the last frame.
    _cache->purge(asset);
    const int seeksBefore = _fake->seeks.load();
    pool.setTargets({DecodeTarget{asset, "/fake/short.mov", -1, CMTimeMake(8, 1)}});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    auto found = _cache->get(asset, CMTimeMake(8, 1));
    XCTAssertTrue(found.has_value());
    if (found) {
        XCTAssertEqual(readBurnIn(found->image.get()), std::optional<int>(59));
    }
    stream = pool.stats().streams.at(0);
    XCTAssertTrue(stream.eof);
    XCTAssertFalse(stream.error.has_value());
    NSLog(@"end search: %d seeks", _fake->seeks.load() - seeksBefore);
    XCTAssertLessThanOrEqual(_fake->seeks.load() - seeksBefore, 8, @"the search doubles its step");

    // Scrubbing past the end.
    _cache->purge(asset);
    ScrubLog log;
    pool.requestFrame(asset, CMTimeMake(7, 1), log.callback(0));
    XCTAssertTrue(log.waitFor(1, std::chrono::seconds(10)));
    {
        std::lock_guard<std::mutex> lock(log.mutex);
        const auto &r = log.results[0].at(0);
        XCTAssertTrue(r.ok(), @"%s", r.ok() ? "" : r.error().description().c_str());
        if (r.ok()) {
            XCTAssertEqual(readBurnIn(r.value().image.get()), std::optional<int>(59));
        }
    }
    XCTAssertTrue(_cache->contains(asset, CMTimeMake(7, 1)), @"the scrubbed last frame is held too");
}

@end
