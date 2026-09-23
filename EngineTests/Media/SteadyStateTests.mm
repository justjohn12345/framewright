// Steady state: repeating the same decode-pool, frame-cache, scrub and thumbnail workload must
// not grow the process. The per-round growth budget is far below one decoded frame, so a leak of
// one pixel buffer (or decoder) per round shows up; `leaks --atExit` over this suite checks for
// unreachable allocations separately (see the phase report).

#import <XCTest/XCTest.h>

#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../../Engine/Media/BackendRouter.h"
#include "../../Engine/Media/DecodePool.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Thumbs/ThumbnailService.h"
#include "RouterTestSupport.h"
#include "TestMedia.h"

using namespace ve;
using namespace ve::media;
using namespace ve::test;
using namespace ve::thumbs;

@interface SteadyStateTests : XCTestCase
@end

@implementation SteadyStateTests

- (void)testRepeatedWorkloadDoesNotGrow {
    std::string error;
    const std::string h264 = testMediaPath("h264_1080p30.mp4", error);
    const std::string hevc = testMediaPath("hevc_720p2997.mov", error);
    XCTAssertFalse(h264.empty() || hevc.empty(), @"%s", error.c_str());
    if (h264.empty() || hevc.empty()) {
        return;
    }
    auto router = std::make_shared<BackendRouter>();
    XCTAssertTrue(router->registerBackend(apple::makeAppleBackend()).ok());
    XCTAssertTrue(router->registerBackend(ffmpeg::makeFFmpegBackend()).ok());
    auto fake = std::make_shared<FakeBehavior>();
    fake->name = "fake";
    fake->probe = [](const std::string &p) { return Result<MediaInfo>(makeFakeInfo(p, "mov", fourcc::H264)); };
    auto fakeRouter = std::make_shared<BackendRouter>();
    XCTAssertTrue(fakeRouter->registerBackend(std::make_shared<FakeBackend>(fake)).ok());

    auto cache = std::make_shared<FrameCache>(size_t(96) << 20);
    ThumbnailService::Config thumbConfig;
    thumbConfig.memoryBudgetBytes = size_t(2) << 20;
    ThumbnailService thumbs(router, thumbConfig);
    dispatch_queue_t queue = dispatch_queue_create("ve.test.steady", DISPATCH_QUEUE_SERIAL);

    auto round = [&](int r) {
        @autoreleasepool {
            DecodePool pool(router, cache);
            DecodePool fakePool(fakeRouter, cache);
            for (int step = 0; step < 4; ++step) {
                const CMTime t = CMTimeMake(30 * ((r + step) % 8), 30);
                pool.setTargets({DecodeTarget{AssetId(1), h264, -1, t}, DecodeTarget{AssetId(2), hevc, -1, t}});
                fakePool.setTargets({DecodeTarget{AssetId(3), "/fake/a.mov", -1, t}});
                XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(30)));
                XCTAssertTrue(fakePool.waitUntilIdle(std::chrono::seconds(30)));
            }
            Latch scrubbed(2);
            pool.requestFrame(AssetId(1), CMTimeMake(7 * r % 300, 30), [&](Result<ScrubFrame>) { scrubbed.countDown(); });
            pool.requestFrame(AssetId(2), CMTimeMake(11 * r % 300, 30), [&](Result<ScrubFrame>) { scrubbed.countDown(); });
            XCTAssertTrue(scrubbed.wait(std::chrono::seconds(30)));
            Latch thumbed(3);
            for (int k = 0; k < 3; ++k) {
                thumbs.request(ThumbnailRequest{AssetId(1), h264, CMTimeMake(r * 3 + k, 1), 160}, queue,
                               [&](Result<ThumbnailImage>) { thumbed.countDown(); });
            }
            XCTAssertTrue(thumbed.wait(std::chrono::seconds(30)));
            thumbs.purge(AssetId(1));
            cache->purgeAll();
        }
    };
    for (int r = 0; r < 4; ++r) {
        round(r); // Warm-up: pools, codec state, caches reach their steady size.
    }
    const uint64_t before = physicalFootprint();
    constexpr int kRounds = 12;
    for (int r = 0; r < kRounds; ++r) {
        round(r);
    }
    const uint64_t after = physicalFootprint();
    const double growthMB = (static_cast<double>(after) - static_cast<double>(before)) / (1024.0 * 1024.0);
    NSLog(@"steady state: footprint %.1f MB -> %.1f MB over %d rounds (%+.2f MB)", before / 1048576.0,
          after / 1048576.0, kRounds, growthMB);
    // One 1080p 4:2:0 frame is ~3 MB; 12 rounds leaking one frame each would be ~36 MB.
    XCTAssertLessThan(growthMB, 6.0, @"the repeated workload grew the process by %.1f MB", growthMB);
    XCTAssertEqual(fake->liveDecoders.load(), 0, @"every decoder was destroyed");
    XCTAssertEqual(cache->stats().bytes, size_t(0));
}

@end
