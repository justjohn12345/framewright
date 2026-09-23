// ThumbnailService: size, burn-in legibility, caches, coalescing, cancellation, rotation.

#import <XCTest/XCTest.h>

#include "../../Engine/Thumbs/ThumbnailService.h"
#include "../Media/BurnIn.h"
#include "../Media/RouterTestSupport.h"
#include "../Media/TestMedia.h"

#include <sys/time.h>

#include <filesystem>
#include <fstream>
#include <map>

using namespace ve;
using namespace ve::media;
using namespace ve::test;
using namespace ve::thumbs;

namespace {

constexpr CGBitmapInfo kBGRA =
    static_cast<CGBitmapInfo>(kCGImageAlphaPremultipliedFirst) | static_cast<CGBitmapInfo>(kCGBitmapByteOrder32Little);

/// Draws a CGImage into a new 32BGRA pixel buffer (so BurnIn.h can read it).
PixelBuffer toPixelBuffer(CGImageRef image) {
    const size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    CVPixelBufferRef raw = nullptr;
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nullptr, &raw);
    PixelBuffer buffer = PixelBuffer::adopt(raw);
    PixelBufferLock lock(buffer.get(), false);
    CFRef<CGColorSpaceRef> space = CFRef<CGColorSpaceRef>::adopt(CGColorSpaceCreateWithName(kCGColorSpaceSRGB));
    void *base = CVPixelBufferGetBaseAddress(buffer.get());
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer.get());
    CFRef<CGContextRef> ctx =
        CFRef<CGContextRef>::adopt(CGBitmapContextCreate(base, w, h, 8, stride, space.get(), kBGRA));
    CGContextDrawImage(ctx.get(), CGRectMake(0, 0, w, h), image);
    return buffer;
}

/// BGRA pixel at (x, y) with y measured from the top.
RGB pixelAt(const PixelBuffer &b, size_t x, size_t y) {
    PixelBufferLock lock(b.get(), true);
    const auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(b.get()));
    const uint8_t *p = base + y * CVPixelBufferGetBytesPerRow(b.get()) + x * 4;
    return RGB{p[2], p[1], p[0]};
}

struct Collector {
    std::mutex mutex;
    std::map<int, std::vector<Result<ThumbnailImage>>> results;
    std::atomic<int> offQueue{0};
    Latch *latch = nullptr;

    ThumbnailCallback callback(int id, void *queueKey) {
        return [this, id, queueKey](Result<ThumbnailImage> r) {
            if (dispatch_get_specific(queueKey) == nullptr) {
                ++offQueue;
            }
            {
                std::lock_guard<std::mutex> lock(mutex);
                results[id].push_back(std::move(r));
            }
            if (latch) {
                latch->countDown();
            }
        };
    }
};

} // namespace

@interface ThumbnailServiceTests : XCTestCase
@end

@implementation ThumbnailServiceTests {
    dispatch_queue_t _queue;
    std::string _dir;
}

static char kQueueKey;

- (void)setUp {
    _queue = dispatch_queue_create("ve.test.thumbs", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue, &kQueueKey, &kQueueKey, nullptr);
    _dir = scratchDirectory() + "/thumbs";
}

- (std::string)mediaPath:(const std::string &)file {
    std::string error;
    const std::string path = testMediaPath(file, error);
    XCTAssertFalse(path.empty(), @"test media: %s", error.c_str());
    return path;
}

- (Result<ThumbnailImage>)thumbnailFrom:(ThumbnailService &)service request:(const ThumbnailRequest &)request {
    Latch latch(1);
    Collector c;
    c.latch = &latch;
    service.request(request, _queue, c.callback(0, &kQueueKey));
    XCTAssertTrue(latch.wait(std::chrono::seconds(20)));
    XCTAssertEqual(c.offQueue.load(), 0, @"callbacks run on the requested queue");
    std::lock_guard<std::mutex> lock(c.mutex);
    XCTAssertEqual(c.results[0].size(), size_t(1));
    return c.results[0].at(0);
}

- (void)testVideoThumbnailSizeAndBurnInAt320 {
    const std::string path = [self mediaPath:"h264_1080p30.mp4"];
    if (path.empty()) {
        return;
    }
    ThumbnailService service(BackendRouter::makeDefault(), {_dir});
    for (int frame : {60, 0, 299, 137}) {
        ThumbnailRequest request{AssetId(1), path, CMTimeMake(frame, 30), 320};
        auto image = [self thumbnailFrom:service request:request];
        XCTAssertTrue(image.ok(), @"%s", image.ok() ? "" : image.error().description().c_str());
        if (!image.ok()) {
            continue;
        }
        XCTAssertEqual(CGImageGetWidth(image->get()), size_t(320));
        XCTAssertEqual(CGImageGetHeight(image->get()), size_t(180));
        XCTAssertEqual(readBurnIn(toPixelBuffer(image->get()).get()), std::optional<int>(frame), @"frame %d", frame);
    }
    // Portrait-limited: a 90 px request fits the long side.
    auto small = [self thumbnailFrom:service request:ThumbnailRequest{AssetId(1), path, kCMTimeZero, 90}];
    XCTAssertEqual(CGImageGetWidth(small->get()), size_t(90));
    // 50.6 rounds to 51, or to 50 when the decoder scales to even dimensions (Apple does).
    XCTAssertGreaterThanOrEqual(CGImageGetHeight(small->get()), size_t(50));
    XCTAssertLessThanOrEqual(CGImageGetHeight(small->get()), size_t(51));
    // Past the end: the last frame.
    auto end = [self thumbnailFrom:service request:ThumbnailRequest{AssetId(1), path, CMTimeMake(99, 1), 320}];
    XCTAssertEqual(readBurnIn(toPixelBuffer(end->get()).get()), std::optional<int>(299));
}

- (void)testStillThumbnails {
    for (const char *file : {"still.png", "still.heic"}) {
        const std::string path = [self mediaPath:file];
        if (path.empty()) {
            return;
        }
        const TestClip &clip = testClip(file);
        ThumbnailService service(BackendRouter::makeDefault(), {});
        auto image = [self thumbnailFrom:service request:ThumbnailRequest{AssetId(2), path, CMTimeMake(3, 1), 320}];
        XCTAssertTrue(image.ok(), @"%s", file);
        if (!image.ok()) {
            continue;
        }
        XCTAssertEqual(CGImageGetWidth(image->get()), size_t(320));
        XCTAssertEqual(CGImageGetHeight(image->get()), size_t(320 * clip.height / clip.width));
        XCTAssertEqual(readBurnIn(toPixelBuffer(image->get()).get()), std::optional<int>(clip.stillIndex), @"%s", file);
    }
}

- (void)testMemoryAndDiskCachesAndCoalescing {
    const std::string path = [self mediaPath:"hevc_720p2997.mov"];
    if (path.empty()) {
        return;
    }
    const ThumbnailRequest request{AssetId(3), path, CMTimeMake(1001 * 45, 30000), 160};
    CGImageRef firstImage = nullptr;
    {
        ThumbnailService::Config config{_dir};
        config.threads = 1;
        ThumbnailService service(BackendRouter::makeDefault(), config);
        constexpr int kRequests = 6;
        Latch latch(kRequests);
        Collector c;
        c.latch = &latch;
        for (int i = 0; i < kRequests; ++i) {
            service.request(request, _queue, c.callback(i, &kQueueKey));
        }
        XCTAssertTrue(latch.wait(std::chrono::seconds(20)));
        const auto stats = service.stats();
        XCTAssertEqual(stats.decodes, uint64_t(1), @"identical requests share one decode");
        XCTAssertEqual(stats.coalesced + stats.memoryHits, uint64_t(kRequests - 1));
        std::lock_guard<std::mutex> lock(c.mutex);
        firstImage = c.results[0].at(0).value().get();
        for (int i = 0; i < kRequests; ++i) {
            XCTAssertEqual(c.results[i].size(), size_t(1));
            XCTAssertTrue(c.results[i].at(0).value().get() == firstImage, @"every waiter gets the same image");
        }
        XCTAssertEqual(readBurnIn(toPixelBuffer(firstImage).get()), std::optional<int>(45));
        // Memory hit.
        auto again = [self thumbnailFrom:service request:request];
        XCTAssertTrue(again->get() == firstImage);
        XCTAssertEqual(service.stats().memoryHits, stats.memoryHits + 1);
        XCTAssertEqual(service.stats().memoryCount, size_t(1));
        service.purge(AssetId(3));
        XCTAssertEqual(service.stats().memoryCount, size_t(0));
    }
    const std::string file = _dir + "/" + ThumbnailService::diskFileName(request);
    XCTAssertTrue(std::filesystem::exists(file), @"%s", file.c_str());
    {
        ThumbnailService service(BackendRouter::makeDefault(), {_dir});
        auto fromDisk = [self thumbnailFrom:service request:request];
        XCTAssertTrue(fromDisk.ok());
        XCTAssertEqual(service.stats().diskHits, uint64_t(1));
        XCTAssertEqual(service.stats().decodes, uint64_t(0));
        XCTAssertEqual(CGImageGetWidth(fromDisk->get()), size_t(160));
        XCTAssertEqual(CGImageGetHeight(fromDisk->get()), size_t(90));
        XCTAssertEqual(readBurnIn(toPixelBuffer(fromDisk->get()).get()), std::optional<int>(45));
    }
    // The disk key depends on the time and size.
    ThumbnailRequest other = request;
    other.maxDimension = 161;
    XCTAssertNotEqual(ThumbnailService::diskFileName(other), ThumbnailService::diskFileName(request));
    other = request;
    other.time = CMTimeMake(1, 1);
    XCTAssertNotEqual(ThumbnailService::diskFileName(other), ThumbnailService::diskFileName(request));
}

- (void)testMemoryBudgetIsHonoured {
    auto fake = std::make_shared<FakeBehavior>();
    fake->probe = [](const std::string &p) { return Result<MediaInfo>(makeFakeInfo(p, "mov", fourcc::H264, false)); };
    auto router = std::make_shared<BackendRouter>();
    (void)router->registerBackend(std::make_shared<FakeBackend>(fake));
    ThumbnailService::Config config;
    config.memoryBudgetBytes = 3 * 144 * 81 * 4;
    ThumbnailService service(router, config);
    for (int i = 0; i < 6; ++i) {
        const ThumbnailRequest request{AssetId(1), "/fake.mov", CMTimeMake(i, 1), 144};
        auto image = [self thumbnailFrom:service request:request];
        XCTAssertTrue(image.ok());
        XCTAssertEqual(readBurnIn(toPixelBuffer(image->get()).get()), std::optional<int>(30 * i));
    }
    XCTAssertEqual(service.stats().memoryCount, size_t(3));
    XCTAssertLessThanOrEqual(service.stats().memoryBytes, config.memoryBudgetBytes);
    XCTAssertEqual(fake->opens.load(), 1, @"the decoder is reused across requests");
}

- (void)testCancellationErrorsAndShutdown {
    auto fake = std::make_shared<FakeBehavior>();
    fake->probe = [](const std::string &p) { return Result<MediaInfo>(makeFakeInfo(p, "mov", fourcc::H264, false)); };
    Gate gate;
    Latch decoding(1);
    std::atomic<int> seeks{0};
    fake->onSeek = [&](CMTime) {
        if (seeks++ == 0) {
            decoding.countDown();
            gate.pass();
        }
    };
    auto router = std::make_shared<BackendRouter>();
    (void)router->registerBackend(std::make_shared<FakeBackend>(fake));
    Collector c;
    Latch done(5);
    c.latch = &done;
    {
        ThumbnailService::Config config;
        config.threads = 1;
        ThumbnailService service(router, config);
        service.request(ThumbnailRequest{AssetId(1), "/fake.mov", kCMTimeZero, 64}, _queue, c.callback(1, &kQueueKey));
        XCTAssertTrue(decoding.wait(std::chrono::seconds(5)));
        // Queued behind the gated job.
        service.request(ThumbnailRequest{AssetId(1), "/fake.mov", CMTimeMake(1, 1), 64}, _queue,
                        c.callback(2, &kQueueKey));
        service.request(ThumbnailRequest{AssetId(2), "/fake2.mov", CMTimeMake(1, 1), 64}, _queue,
                        c.callback(3, &kQueueKey));
        service.cancelPending(AssetId(1));
        // Invalid requests fail fast.
        service.request(ThumbnailRequest{AssetId(1), "", kCMTimeZero, 64}, _queue, c.callback(4, &kQueueKey));
        service.request(ThumbnailRequest{AssetId(1), "/fake.mov", kCMTimeZero, 0}, _queue, c.callback(5, &kQueueKey));
        gate.open();
        // Destruction cancels request 3 if it has not started, and waits for request 1.
    }
    XCTAssertTrue(done.wait(std::chrono::seconds(10)));
    std::lock_guard<std::mutex> lock(c.mutex);
    for (auto &[id, calls] : c.results) {
        XCTAssertEqual(calls.size(), size_t(1), @"callback %d", id);
    }
    XCTAssertTrue(c.results[1].at(0).ok());
    XCTAssertEqual(c.results[2].at(0).error().code, MediaErrorCode::Cancelled);
    XCTAssertTrue(c.results[3].at(0).ok() || c.results[3].at(0).error().code == MediaErrorCode::Cancelled);
    XCTAssertEqual(c.results[4].at(0).error().code, MediaErrorCode::InvalidArgument);
    XCTAssertEqual(c.results[5].at(0).error().code, MediaErrorCode::InvalidArgument);
    XCTAssertEqual(c.offQueue.load(), 0);

    // A missing file is reported as such.
    ThumbnailService service(BackendRouter::makeDefault(), {});
    const ThumbnailRequest missingRequest{AssetId(9), "/nonexistent.mov", kCMTimeZero, 64};
    auto missing = [self thumbnailFrom:service request:missingRequest];
    XCTAssertEqual(missing.error().code, MediaErrorCode::FileNotFound);
    XCTAssertEqual(service.stats().failures, uint64_t(1));
}

/// Copies a generated file into a fresh scratch directory under `name` (for tests that modify
/// or rename the source).
- (std::string)copyOf:(const std::string &)file named:(const std::string &)name {
    const std::string source = [self mediaPath:file];
    const std::string dest = scratchDirectory() + "/" + name;
    std::error_code ec;
    std::filesystem::copy_file(source, dest, std::filesystem::copy_options::overwrite_existing, ec);
    XCTAssertFalse(ec, @"copy %s: %s", file.c_str(), ec.message().c_str());
    return dest;
}

/// A cached PNG that is corrupt (truncated write, disk error) is decoded afresh and replaced.
- (void)testCorruptDiskCacheFileIsRegenerated {
    const std::string path = [self mediaPath:"h264_1080p30.mp4"];
    if (path.empty()) {
        return;
    }
    ThumbnailRequest request{AssetId(1), path, CMTimeMake(1, 1), 160};
    ThumbnailService::Config config;
    config.diskCacheDirectory = _dir;
    {
        ThumbnailService service(BackendRouter::makeDefault(), config);
        XCTAssertTrue([self thumbnailFrom:service request:request].ok());
    }
    const std::string png = _dir + "/" + ThumbnailService::diskFileName(request);
    XCTAssertTrue(std::filesystem::exists(png));
    {
        std::ofstream garbage(png, std::ios::binary | std::ios::trunc);
        garbage << "not a PNG at all";
    }
    ThumbnailService service(BackendRouter::makeDefault(), config);
    auto image = [self thumbnailFrom:service request:request];
    XCTAssertTrue(image.ok());
    if (image.ok()) {
        XCTAssertEqual(readBurnIn(toPixelBuffer(image->get()).get()), std::optional<int>(30));
    }
    const auto stats = service.stats();
    XCTAssertEqual(stats.diskHits, uint64_t(0), @"the corrupt file is not used");
    XCTAssertEqual(stats.decodes, uint64_t(1));
    XCTAssertGreaterThan(std::filesystem::file_size(png), uint64_t(100), @"rewritten with a real PNG");
    ThumbnailService again(BackendRouter::makeDefault(), config);
    XCTAssertTrue([self thumbnailFrom:again request:request].ok());
    XCTAssertEqual(again.stats().diskHits, uint64_t(1), @"and used from then on");
}

/// A source file that changed on disk (new modification time) is decoded again: neither the
/// memory cache (keyed by file identity too) nor the disk cache returns the old thumbnail.
- (void)testChangedSourceFileForcesANewDecode {
    const std::string path = [self copyOf:"h264_1080p30.mp4" named:"changing.mp4"];
    ThumbnailService::Config config;
    config.diskCacheDirectory = _dir;
    ThumbnailService service(BackendRouter::makeDefault(), config);
    const ThumbnailRequest request{AssetId(1), path, CMTimeMake(2, 1), 160};
    XCTAssertTrue([self thumbnailFrom:service request:request].ok());
    XCTAssertTrue([self thumbnailFrom:service request:request].ok());
    XCTAssertEqual(service.stats().decodes, uint64_t(1));
    XCTAssertEqual(service.stats().memoryHits, uint64_t(1));
    // Touch the file: same content, new modification time (what an editor or a re-copy does).
    struct timeval times[2];
    gettimeofday(&times[0], nullptr);
    times[0].tv_sec += 10;
    times[1] = times[0];
    XCTAssertEqual(utimes(path.c_str(), times), 0);
    XCTAssertTrue([self thumbnailFrom:service request:request].ok());
    const auto stats = service.stats();
    XCTAssertEqual(stats.decodes, uint64_t(2), @"the changed file was decoded again");
    XCTAssertEqual(stats.memoryHits, uint64_t(1));
    XCTAssertEqual(stats.diskHits, uint64_t(0));
}

/// Non-ASCII paths (accents, CJK, emoji, spaces) work through probing, decoding and the disk cache.
- (void)testUnicodePaths {
    const std::string path = [self copyOf:"h264_1080p30.mp4" named:"Clip \u00fc \u65e5\u672c\u8a9e \U0001F3AC.mp4"];
    ThumbnailService::Config config;
    config.diskCacheDirectory = _dir + "/d\u00e9j\u00e0 vu";
    const ThumbnailRequest request{AssetId(1), path, CMTimeMake(1, 1), 320};
    {
        ThumbnailService service(BackendRouter::makeDefault(), config);
        auto image = [self thumbnailFrom:service request:request];
        XCTAssertTrue(image.ok(), @"%s", image.ok() ? "" : image.error().description().c_str());
        if (image.ok()) {
            XCTAssertEqual(readBurnIn(toPixelBuffer(image->get()).get()), std::optional<int>(30));
        }
    }
    ThumbnailService service(BackendRouter::makeDefault(), config);
    XCTAssertTrue([self thumbnailFrom:service request:request].ok());
    XCTAssertEqual(service.stats().diskHits, uint64_t(1));
}

/// The disk cache stays within Config::diskBudgetBytes (least recently used files deleted), and
/// the routing memo within Config::maxRoutes.
- (void)testDiskCacheAndRoutesAreBounded {
    const std::string h264 = [self mediaPath:"h264_1080p30.mp4"];
    const std::string hevc = [self mediaPath:"hevc_720p2997.mov"];
    const std::string prores = [self mediaPath:"prores_540p25.mov"];
    if (h264.empty() || hevc.empty() || prores.empty()) {
        return;
    }
    ThumbnailService::Config config;
    config.diskCacheDirectory = _dir;
    config.maxRoutes = 2;
    // Measure one thumbnail, then allow about three.
    uint64_t one = 0;
    {
        ThumbnailService probe(BackendRouter::makeDefault(), config);
        const ThumbnailRequest first{AssetId(1), h264, kCMTimeZero, 320};
        XCTAssertTrue([self thumbnailFrom:probe request:first].ok());
        for (const auto &entry : std::filesystem::directory_iterator(_dir)) {
            one = std::max<uint64_t>(one, entry.file_size());
        }
    }
    config.diskBudgetBytes = one * 3 + one / 2;
    ThumbnailService service(BackendRouter::makeDefault(), config);
    int index = 1;
    for (const std::string &file : {h264, hevc, prores}) {
        for (int second = 0; second < 3; ++second) {
            const ThumbnailRequest request{AssetId(index), file, CMTimeMake(second, 1), 320};
            XCTAssertTrue([self thumbnailFrom:service request:request].ok());
        }
        ++index;
    }
    uint64_t total = 0;
    int files = 0;
    for (const auto &entry : std::filesystem::directory_iterator(_dir)) {
        if (entry.path().extension() == ".png") {
            total += entry.file_size();
            ++files;
        }
    }
    NSLog(@"thumbnail disk cache: %d files, %llu bytes, budget %llu", files, total, config.diskBudgetBytes);
    XCTAssertLessThanOrEqual(total, config.diskBudgetBytes);
    XCTAssertGreaterThan(files, 0);
    XCTAssertEqual(service.stats().diskWriteFailures, uint64_t(0));
    XCTAssertLessThanOrEqual(service.stats().routeCount, size_t(2));
}

/// A portrait (90-degree) clip gives a portrait thumbnail.
- (void)testRotatedClipThumbnailIsUpright {
    const std::string path = [self mediaPath:"rotated90_h264.mp4"];
    if (path.empty()) {
        return;
    }
    ThumbnailService service(BackendRouter::makeDefault(), ThumbnailService::Config{});
    auto image = [self thumbnailFrom:service request:ThumbnailRequest{AssetId(1), path, kCMTimeZero, 160}];
    XCTAssertTrue(image.ok());
    if (image.ok()) {
        XCTAssertEqual(CGImageGetWidth(image->get()), size_t(90));
        XCTAssertEqual(CGImageGetHeight(image->get()), size_t(160));
    }
}

- (void)testRenderThumbnailScalesConvertsAndRotates {
    // A 288x162 BGRA frame: red top-left quadrant, blue elsewhere.
    auto pool = PixelBufferPool::create(kCVPixelFormatType_32BGRA, 288, 162);
    PixelBuffer frame = pool->makeBuffer().value();
    {
        PixelBufferLock lock(frame.get(), false);
        auto *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(frame.get()));
        for (size_t y = 0; y < 162; ++y) {
            for (size_t x = 0; x < 288; ++x) {
                uint8_t *p = base + y * CVPixelBufferGetBytesPerRow(frame.get()) + x * 4;
                const bool red = x < 144 && y < 81;
                p[0] = red ? 0 : 255;
                p[1] = 0;
                p[2] = red ? 255 : 0;
                p[3] = 255;
            }
        }
    }
    auto upright = ThumbnailService::renderThumbnail(frame, 144, 0);
    XCTAssertEqual(CGImageGetWidth(upright->get()), size_t(144));
    XCTAssertEqual(CGImageGetHeight(upright->get()), size_t(81));
    XCTAssertEqual(pixelAt(toPixelBuffer(upright->get()), 5, 5).r, 255);

    // 90 degrees clockwise: the top-left quadrant moves to the top-right.
    auto cw = ThumbnailService::renderThumbnail(frame, 288, 90);
    XCTAssertEqual(CGImageGetWidth(cw->get()), size_t(162));
    XCTAssertEqual(CGImageGetHeight(cw->get()), size_t(288));
    PixelBuffer cwPixels = toPixelBuffer(cw->get());
    XCTAssertEqual(pixelAt(cwPixels, 157, 5).r, 255, @"top-right is red");
    XCTAssertEqual(pixelAt(cwPixels, 5, 5).r, 0, @"top-left is blue");
    // 270: top-left goes to bottom-left. 180: to bottom-right.
    PixelBuffer ccw = toPixelBuffer(ThumbnailService::renderThumbnail(frame, 288, 270)->get());
    XCTAssertEqual(pixelAt(ccw, 5, 282).r, 255);
    PixelBuffer flipped = toPixelBuffer(ThumbnailService::renderThumbnail(frame, 288, 180)->get());
    XCTAssertEqual(pixelAt(flipped, 282, 157).r, 255);
    XCTAssertEqual(pixelAt(flipped, 5, 5).r, 0);

    // YUV input converts through VTPixelTransferSession.
    auto yuvPool = PixelBufferPool::create(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, 288, 162);
    PixelBuffer yuv = yuvPool->makeBuffer().value();
    auto converted = ThumbnailService::renderThumbnail(yuv, 100, 0);
    XCTAssertTrue(converted.ok());
    XCTAssertEqual(CGImageGetWidth(converted->get()), size_t(100));
    XCTAssertEqual(ThumbnailService::renderThumbnail(PixelBuffer(), 100, 0).error().code,
                   MediaErrorCode::InvalidArgument);
}

@end
