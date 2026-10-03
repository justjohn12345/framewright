// Generated pictures through the decode pool (titles design, sections 2 and 12; slice 1, item 2), proved with a
// numbered checkerboard before any text exists: the adapter behaves as a still (or frame-grid) decoder; a
// stream and the scrub path render a source once and put its picture under its own key only; a key change
// reopens the stream and never publishes a picture under another key; a newer scrub request interrupts the
// render in flight; a picture rendered for an earlier media epoch is dropped; the eviction order puts stale
// keys before focused ones; and the canvas geometry reaches the TextureSet.

#import <XCTest/XCTest.h>

#include "../../Engine/Media/DecodePool.h"
#include "../../Engine/Model/TimeUtil.h"
#include "../../Engine/Render/TextureCache.h"
#include "GeneratedTestSource.h"
#include "RouterTestSupport.h"

#import <Metal/Metal.h>

#include <condition_variable>
#include <map>
#include <mutex>

using namespace ve;
using namespace ve::media;
using namespace ve::test;

namespace {

std::shared_ptr<CheckerboardSource> checkerboard(std::uint64_t number, std::chrono::milliseconds renderTime = {},
                                                 bool ignoresInterrupt = false) {
    CheckerboardSource::Config config;
    config.number = number;
    config.renderTime = renderTime;
    config.ignoresInterrupt = ignoresInterrupt;
    return std::make_shared<CheckerboardSource>(config);
}

DecodeTarget generatedTarget(AssetId asset, uint64_t lane, std::shared_ptr<const GeneratedPictureSource> source) {
    DecodeTarget target;
    target.asset = asset;
    target.sourceTime = kCMTimeZero;
    target.lane = lane;
    target.generated = std::move(source);
    return target;
}

/// Scrub results by request id.
struct Results {
    std::mutex mutex;
    std::condition_variable cv;
    std::map<int, Result<ScrubFrame>> byId;

    ScrubCallback callback(int id) {
        return [this, id](Result<ScrubFrame> r) {
            std::lock_guard<std::mutex> lock(mutex);
            byId.emplace(id, std::move(r));
            cv.notify_all();
        };
    }
    bool waitFor(size_t count, std::chrono::milliseconds timeout) {
        std::unique_lock<std::mutex> lock(mutex);
        return cv.wait_for(lock, timeout, [&] { return byId.size() >= count; });
    }
};

} // namespace

@interface GeneratedSourceTests : XCTestCase
@end

@implementation GeneratedSourceTests {
    std::shared_ptr<BackendRouter> _router;
    std::shared_ptr<FrameCache> _cache;
}

- (void)setUp {
    // The pool never asks the router for a generated picture: an empty router would fail any probe.
    _router = std::make_shared<BackendRouter>();
    _cache = std::make_shared<FrameCache>();
}

- (void)testTheAdapterBehavesAsAStillDecoderForAStaticSource {
    auto source = checkerboard(7);
    GeneratedVideoDecoder decoder(source);
    XCTAssertTrue(decoder.open({}, -1, DecodeOptions{}).ok());
    XCTAssertFalse(decoder.open({}, -1, DecodeOptions{}).ok(), @"open() once");
    XCTAssertTrue(decoder.supportsRandomAccess());
    XCTAssertFalse(decoder.usedHardware());
    XCTAssertTrue(CMTIME_IS_INVALID(decoder.frameDuration()));
    XCTAssertEqual(decoder.outputPixelFormat(), kCVPixelFormatType_32BGRA);
    auto first = decoder.next();
    XCTAssertTrue(first.ok() && first.value());
    if (!first.ok() || !first.value()) {
        return;
    }
    XCTAssertTrue(CMTimeCompare(first.value()->pts, kCMTimeZero) == 0);
    XCTAssertTrue(CMTIME_IS_POSITIVE_INFINITY(first.value()->duration));
    XCTAssertTrue(first.value()->alphaIsPremultiplied);
    XCTAssertEqual(checkerboardNumber(first.value()->image.get()), std::optional<std::uint64_t>(7));
    const auto geometry = canvasGeometryOf(first.value()->image.get());
    XCTAssertTrue(geometry.has_value());
    if (geometry) {
        XCTAssertTrue(*geometry == (CanvasGeometry{1920, 1080, 100, 900, 64, 32}));
    }
    // One frame per seek, as a still decoder; the picture is rendered once.
    auto after = decoder.next();
    XCTAssertTrue(after.ok() && !after.value());
    XCTAssertTrue(decoder.seek(CMTimeMake(5, 1)).ok());
    auto again = decoder.next();
    XCTAssertTrue(again.ok() && again.value());
    if (again.ok() && again.value()) {
        XCTAssertTrue(again.value()->image == first.value()->image);
    }
    XCTAssertEqual(source->renders(), 1);
}

- (void)testANonStaticSourceRendersItsFrameGrid {
    CheckerboardSource::Config config;
    config.number = 10;
    config.isStatic = false;
    config.frameDuration = CMTimeMake(1, 30);
    auto source = std::make_shared<CheckerboardSource>(config);
    GeneratedVideoDecoder decoder(source);
    XCTAssertTrue(decoder.open({}, -1, DecodeOptions{}).ok());
    XCTAssertTrue(CMTimeCompare(decoder.frameDuration(), CMTimeMake(1, 30)) == 0);
    XCTAssertTrue(decoder.seek(CMTimeMake(1, 10)).ok()); // frame 3
    for (int64_t n : {3, 4, 5}) {
        auto frame = decoder.next();
        XCTAssertTrue(frame.ok() && frame.value());
        if (!frame.ok() || !frame.value()) {
            return;
        }
        XCTAssertTrue(CMTimeCompare(frame.value()->pts, CMTimeMake(n, 30)) == 0);
        XCTAssertTrue(CMTimeCompare(frame.value()->duration, CMTimeMake(1, 30)) == 0);
        XCTAssertEqual(checkerboardNumber(frame.value()->image.get()), std::optional<std::uint64_t>(10 + n));
    }
    // A source that changes over time needs a frame grid.
    config.frameDuration = kCMTimeInvalid;
    GeneratedVideoDecoder broken(std::make_shared<CheckerboardSource>(config));
    XCTAssertFalse(broken.open({}, -1, DecodeOptions{}).ok());
}

- (void)testAStreamPutsTheSourcesPictureUnderItsKeyOnly {
    const AssetId titles(5);
    auto source = checkerboard(3);
    DecodePool pool(_router, _cache);
    pool.setTargets({generatedTarget(titles, 11, source)});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    const FrameKey key = pool.frameKey(titles, source->key());
    auto found = _cache->get(key, CMTimeMake(42, 1)); // a static picture answers every time
    XCTAssertTrue(found.has_value());
    if (found) {
        XCTAssertEqual(checkerboardNumber(found->image.get()), std::optional<std::uint64_t>(3));
    }
    XCTAssertFalse(_cache->contains(pool.frameKey(titles), kCMTimeZero), @"not under the asset's decoded frames");
    XCTAssertFalse(_cache->contains(pool.frameKey(titles, checkerboard(4)->key()), kCMTimeZero));
    const DecodePool::Stats stats = pool.stats();
    XCTAssertEqual(stats.streams.size(), size_t(1));
    XCTAssertEqual(stats.streams[0].backend, "generated");
    XCTAssertFalse(stats.streams[0].failed);
    XCTAssertTrue(stats.streams[0].eof == false && stats.streams[0].idle);
    // The same target again (a retarget each tick of playback), or a new source object with the same key,
    // renders nothing.
    pool.setTargets({generatedTarget(titles, 11, source)});
    pool.setTargets({generatedTarget(titles, 11, checkerboard(3))});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertEqual(source->renders(), 1);
    // Evicted while idle (memory pressure): refresh() renders it again under the same key.
    _cache->purgeAll();
    pool.refresh();
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertTrue(_cache->contains(key, kCMTimeZero));
}

- (void)testTwoClipsOfOneGeneratorAssetKeepTheirOwnPictures {
    const AssetId titles(5);
    auto first = checkerboard(21);
    auto second = checkerboard(22);
    DecodePool pool(_router, _cache);
    pool.setTargets({generatedTarget(titles, 1, first), generatedTarget(titles, 2, second)});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    for (const auto &source : {first, second}) {
        auto found = _cache->get(pool.frameKey(titles, source->key()), kCMTimeZero);
        XCTAssertTrue(found.has_value());
        if (found) {
            XCTAssertEqual(checkerboardNumber(found->image.get()), std::optional<std::uint64_t>(source->key().contentHigh));
        }
        XCTAssertEqual(source->renders(), 1);
    }
    // Two clips with identical content share one picture (content-addressed keys).
    auto twin = checkerboard(21);
    pool.setTargets({generatedTarget(titles, 1, first), generatedTarget(titles, 3, twin)});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertTrue(_cache->contains(pool.frameKey(titles, twin->key()), kCMTimeZero));
}

- (void)testAKeyChangeReopensTheStreamAndNeverPublishesUnderAnotherKey {
    const AssetId titles(5);
    // The old text renders slowly and ignores the interrupt: it finishes after the retarget, so the
    // test sees where its picture goes.
    auto old = checkerboard(30, std::chrono::milliseconds(300), true);
    auto typed = checkerboard(31);
    DecodePool pool(_router, _cache);
    pool.setTargets({generatedTarget(titles, 7, old)});
    XCTAssertTrue(old->waitForRender(std::chrono::seconds(5)));
    pool.setTargets({generatedTarget(titles, 7, typed)});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    auto now = _cache->get(pool.frameKey(titles, typed->key()), kCMTimeZero);
    XCTAssertTrue(now.has_value());
    if (now) {
        XCTAssertEqual(checkerboardNumber(now->image.get()), std::optional<std::uint64_t>(31));
    }
    // The old picture lands under its own key (a valid answer for it), never under the new one.
    if (auto earlier = _cache->get(pool.frameKey(titles, old->key()), kCMTimeZero)) {
        XCTAssertEqual(checkerboardNumber(earlier->image.get()), std::optional<std::uint64_t>(30));
    }
    XCTAssertEqual(old->finished(), 1);
    XCTAssertEqual(typed->renders(), 1);

    // A render that honours the interrupt is abandoned when the key changes.
    auto slow = checkerboard(40, std::chrono::seconds(5));
    auto next = checkerboard(41);
    pool.setTargets({generatedTarget(titles, 8, slow)});
    XCTAssertTrue(slow->waitForRender(std::chrono::seconds(5)));
    const auto retarget = std::chrono::steady_clock::now();
    pool.setTargets({generatedTarget(titles, 8, next)});
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    const double ms =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - retarget).count();
    XCTAssertLessThan(ms, 1000.0, @"the slow render was interrupted, not waited for");
    XCTAssertEqual(slow->interrupted(), 1);
    XCTAssertFalse(_cache->contains(pool.frameKey(titles, slow->key()), kCMTimeZero));
    XCTAssertTrue(_cache->contains(pool.frameKey(titles, next->key()), kCMTimeZero));
}

- (void)testTheScrubPathRendersOnceAndThenFindsTheCachedPicture {
    const AssetId titles(9);
    auto source = checkerboard(12);
    DecodePool pool(_router, _cache);
    Results results;
    pool.requestFrame(titles, CMTimeMake(3, 1), results.callback(1), 4, source);
    XCTAssertTrue(results.waitFor(1, std::chrono::seconds(10)));
    {
        std::lock_guard<std::mutex> lock(results.mutex);
        Result<ScrubFrame> &r = results.byId.at(1);
        XCTAssertTrue(r.ok());
        if (r.ok()) {
            XCTAssertFalse(r.value().fromCache);
            XCTAssertTrue(static_cast<bool>(r.value().pin), @"delivered pinned");
            XCTAssertTrue(CMTimeCompare(r.value().pts, kCMTimeZero) == 0);
            XCTAssertEqual(checkerboardNumber(r.value().image.get()), std::optional<std::uint64_t>(12));
        }
    }
    XCTAssertTrue(_cache->contains(pool.frameKey(titles, source->key()), kCMTimeZero));
    pool.requestFrame(titles, kCMTimeZero, results.callback(2), 4, source);
    XCTAssertTrue(results.waitFor(2, std::chrono::seconds(10)));
    {
        std::lock_guard<std::mutex> lock(results.mutex);
        Result<ScrubFrame> &r = results.byId.at(2);
        XCTAssertTrue(r.ok() && r.value().fromCache);
    }
    XCTAssertEqual(source->renders(), 1);
}

- (void)testANewerScrubRequestInterruptsTheRenderInFlight {
    const AssetId titles(9);
    auto typing = checkerboard(50, std::chrono::seconds(5));
    auto latest = checkerboard(51);
    DecodePool pool(_router, _cache);
    Results results;
    pool.requestFrame(titles, kCMTimeZero, results.callback(1), 0, typing);
    XCTAssertTrue(typing->waitForRender(std::chrono::seconds(5)));
    const auto newer = std::chrono::steady_clock::now();
    pool.requestFrame(titles, kCMTimeZero, results.callback(2), 0, latest);
    XCTAssertTrue(results.waitFor(2, std::chrono::seconds(10)));
    const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - newer).count();
    XCTAssertLessThan(ms, 1000.0);
    std::lock_guard<std::mutex> lock(results.mutex);
    XCTAssertFalse(results.byId.at(1).ok());
    if (!results.byId.at(1).ok()) {
        XCTAssertEqual(results.byId.at(1).error().code, MediaErrorCode::Cancelled);
    }
    XCTAssertTrue(results.byId.at(2).ok());
    if (results.byId.at(2).ok()) {
        XCTAssertEqual(checkerboardNumber(results.byId.at(2).value().image.get()), std::optional<std::uint64_t>(51));
    }
    XCTAssertEqual(typing->interrupted(), 1);
    XCTAssertFalse(_cache->contains(pool.frameKey(titles, typing->key()), kCMTimeZero));
}

- (void)testAPictureRenderedForAnEarlierEpochIsNotPublished {
    const AssetId titles(9);
    // Ignores the interrupt, so it finishes after the epoch changed: only the publication check can stop it.
    auto stale = checkerboard(60, std::chrono::milliseconds(200), true);
    DecodePool pool(_router, _cache);
    Results results;
    pool.requestFrame(titles, kCMTimeZero, results.callback(1), 0, stale);
    XCTAssertTrue(stale->waitForRender(std::chrono::seconds(5)));
    pool.beginEpoch(_cache->beginEpoch());
    XCTAssertTrue(results.waitFor(1, std::chrono::seconds(10)));
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    {
        std::lock_guard<std::mutex> lock(results.mutex);
        XCTAssertFalse(results.byId.at(1).ok());
        if (!results.byId.at(1).ok()) {
            XCTAssertEqual(results.byId.at(1).error().code, MediaErrorCode::Cancelled);
        }
    }
    XCTAssertEqual(stale->finished(), 1);
    XCTAssertFalse(_cache->contains(pool.frameKey(titles, stale->key()), kCMTimeZero));
    XCTAssertEqual(_cache->stats().count, size_t(0));

    // The same through a stream: a target's render finishing after the epoch changed is dropped too.
    auto streamed = checkerboard(61, std::chrono::milliseconds(200), true);
    pool.setTargets({generatedTarget(titles, 3, streamed)});
    XCTAssertTrue(streamed->waitForRender(std::chrono::seconds(5)));
    pool.beginEpoch(_cache->beginEpoch());
    XCTAssertTrue(pool.waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertEqual(streamed->finished(), 1);
    XCTAssertEqual(_cache->stats().count, size_t(0));
}

- (void)testStalePicturesOfAGeneratorAssetAreEvictedBeforeFocusedOnes {
    // Pictures of earlier text (keys nothing focuses) go before the frames ahead of a playhead and before
    // the title on screen, however recently they were made.
    auto picture = [](std::uint64_t number) {
        auto frame = checkerboard(number)->render(kCMTimeZero, DecodeOptions{});
        return std::move(frame).value();
    };
    VideoFrame sample = picture(1);
    const size_t bytes = FrameCache::bufferBytes(sample.image.get());
    FrameCache cache(bytes * 4);
    const AssetId video(1), titles(2);
    const CMTime fd = CMTimeMake(1, 30);
    const GeneratedKey shown = checkerboard(70)->key();
    cache.setFocus({FrameCache::Focus{video, kCMTimeZero, true}, FrameCache::Focus{titles, kCMTimeZero, true, shown}});
    // Two frames of the video just ahead of its playhead (same size as the pictures, for the budget's sake).
    for (int64_t i = 0; i < 2; ++i) {
        VideoFrame f = picture(uint64_t(100 + i));
        f.pts = timeForFrame(i, fd);
        f.duration = fd;
        XCTAssertTrue(cache.put(FrameKey{video}, f, fd));
    }
    VideoFrame onScreen = picture(70);
    onScreen.pts = kCMTimeZero;
    onScreen.duration = kCMTimePositiveInfinity;
    XCTAssertTrue(cache.put(FrameKey{titles, {}, shown}, onScreen, kCMTimeInvalid));
    // Typing: three newer pictures of other text, nothing focusing them.
    for (std::uint64_t typed : {71, 72, 73}) {
        VideoFrame f = picture(typed);
        f.pts = kCMTimeZero;
        f.duration = kCMTimePositiveInfinity;
        XCTAssertTrue(cache.put(FrameKey{titles, {}, checkerboard(typed)->key()}, f, kCMTimeInvalid));
    }
    XCTAssertTrue(cache.contains(FrameKey{titles, {}, shown}, kCMTimeZero), @"the focused title stays");
    XCTAssertTrue(cache.contains(FrameKey{video}, int64_t(0)));
    XCTAssertTrue(cache.contains(FrameKey{video}, int64_t(1)), @"the frames ahead of the playhead stay");
    XCTAssertTrue(cache.contains(FrameKey{titles, {}, checkerboard(73)->key()}, kCMTimeZero),
                  @"the newest unfocused picture is the last of them to go (least recently used order)");
    XCTAssertFalse(cache.contains(FrameKey{titles, {}, checkerboard(71)->key()}, kCMTimeZero));
    XCTAssertFalse(cache.contains(FrameKey{titles, {}, checkerboard(72)->key()}, kCMTimeZero));
}

- (void)testTheCanvasGeometryReachesTheTextureSet {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) {
        XCTFail(@"no Metal device");
        return;
    }
    auto cache = render::TextureCache::create(device);
    XCTAssertTrue(cache.ok());
    if (!cache.ok()) {
        return;
    }
    auto frame = checkerboard(5)->render(kCMTimeZero, DecodeOptions{});
    XCTAssertTrue(frame.ok());
    if (!frame.ok()) {
        return;
    }
    auto tagged = cache->textures(frame->image);
    XCTAssertTrue(tagged.ok());
    if (tagged.ok()) {
        XCTAssertTrue(tagged->canvas().has_value());
        if (tagged->canvas()) {
            XCTAssertTrue(*tagged->canvas() == (CanvasGeometry{1920, 1080, 100, 900, 64, 32}));
        }
        XCTAssertEqual(tagged->alphaMode(), render::AlphaMode::Premultiplied);
    }
    // A decoded picture has none; a tag that is not a geometry is ignored.
    auto plain = PixelBufferPool::create(kCVPixelFormatType_32BGRA, 16, 16)->makeBuffer();
    XCTAssertTrue(plain.ok());
    if (plain.ok()) {
        auto untagged = cache->textures(plain.value());
        XCTAssertTrue(untagged.ok() && !untagged->canvas().has_value());
        setCanvasGeometry(plain->get(), CanvasGeometry{1920, 1080, 0, 0, 0, 10});
        XCTAssertFalse(canvasGeometryOf(plain->get()).has_value(), @"an empty rectangle is not a geometry");
    }
}

- (void)testRasterScalesAreQuantisedUpToSixtyFourths {
    XCTAssertEqual(rasterScale64(1.0), 64u);
    XCTAssertEqual(rasterScale64(1.0 + 1e-9), 64u, @"floating-point error is not a step");
    XCTAssertEqual(rasterScale64(1.01), 65u, @"never coarser than asked");
    XCTAssertEqual(rasterScale64(1.5), 96u);
    XCTAssertEqual(rasterScale64(2.0), 128u);
    XCTAssertEqual(rasterScale64(0.001), 1u);
    XCTAssertEqual(rasterScale64(std::nan("")), 64u);
    XCTAssertEqual(rasterScale64(-3), 64u);
    XCTAssertEqual((GeneratedKey{1, 2, 96}).scale(), 1.5);
    XCTAssertTrue((GeneratedKey{}).isEmpty());
    XCTAssertFalse((GeneratedKey{0, 0, 64}).isEmpty());
}

@end
