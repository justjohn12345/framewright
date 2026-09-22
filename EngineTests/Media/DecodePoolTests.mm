// DecodePool: lookahead windows, re-targeting latency, scrub coalescing, shutdown.

#import <XCTest/XCTest.h>

#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../../Engine/Media/DecodePool.h"
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

- (void)testRetargetTakesEffectWithinOneFrameDecode {
    constexpr auto kDecode = std::chrono::milliseconds(20);
    _fake->decodeDelay = kDecode;
    Latch reachedNewTarget(1);
    Clock::time_point firstNewFrame{};
    std::mutex m;
    _fake->onDecode = [&](int64_t index) {
        if (index == 150) {
            std::lock_guard<std::mutex> lock(m);
            if (firstNewFrame == Clock::time_point{}) {
                firstNewFrame = Clock::now();
                reachedNewTarget.countDown();
            }
        }
    };
    DecodePool pool(_fakeRouter, _cache);
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, kCMTimeZero}});
    // Let it get going (open + a few frames).
    std::this_thread::sleep_for(std::chrono::milliseconds(120));
    XCTAssertFalse(pool.waitUntilIdle(std::chrono::milliseconds(0)), @"still filling");
    const auto retarget = Clock::now();
    pool.setTargets({DecodeTarget{AssetId(1), "/fake/a.mov", -1, CMTimeMake(5, 1)}});
    XCTAssertTrue(reachedNewTarget.wait(std::chrono::seconds(5)));
    double latency = 0;
    {
        std::lock_guard<std::mutex> lock(m);
        latency = std::chrono::duration<double, std::milli>(firstNewFrame - retarget).count();
    }
    NSLog(@"re-target latency with a 20 ms/frame decoder: %.1f ms (the frame in flight, then the seek)", latency);
    // At most the in-flight decode (20 ms) plus scheduling slack; the new frame's own decode
    // starts after this point.
    XCTAssertLessThan(latency, 20.0 + 40.0);
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(5)));
    XCTAssertTrue(covers(*_cache, AssetId(1), 150, 180));
    XCTAssertFalse(covers(*_cache, AssetId(1), 0, 30), @"the old window was abandoned");
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
    XCTAssertEqual(frameOf(1), std::optional<int>(30));
    XCTAssertEqual(log.results[2].at(0).error().code, MediaErrorCode::Cancelled);
    XCTAssertEqual(log.results[3].at(0).error().code, MediaErrorCode::Cancelled);
    XCTAssertEqual(frameOf(4), std::optional<int>(105));
    XCTAssertEqual(log.results[4].at(0).value().frameIndex, 105);
    XCTAssertEqual(frameOf(5), std::optional<int>(120));
    const auto stats = pool.stats();
    XCTAssertEqual(stats.scrubRequests, uint64_t(5));
    XCTAssertEqual(stats.scrubServiced, uint64_t(3));
    XCTAssertEqual(stats.scrubCancelled, uint64_t(2));
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
        XCTAssertTrue(log.results[1].at(0).ok(), @"the in-flight request completes");
        XCTAssertEqual(log.results[2].at(0).error().code, MediaErrorCode::Cancelled);
    }
    XCTAssertEqual(_fake->liveDecoders.load(), 0, @"every decoder was destroyed");
    opener.join();
}

- (void)testDestructorIsPromptWhileDecoding {
    _fake->decodeDelay = std::chrono::milliseconds(20);
    auto pool = std::make_unique<DecodePool>(_fakeRouter, _cache);
    pool->setTargets({DecodeTarget{AssetId(1), "/fake/a.mov"}, DecodeTarget{AssetId(2), "/fake/b.mov"}});
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    const auto start = Clock::now();
    pool.reset();
    const double ms = msSince(start);
    NSLog(@"DecodePool destructor while decoding (20 ms/frame): %.1f ms", ms);
    XCTAssertLessThan(ms, 20.0 + 50.0);
    XCTAssertEqual(_fake->liveDecoders.load(), 0);
}

@end
