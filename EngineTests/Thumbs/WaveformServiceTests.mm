// WaveformService: peak positions (the 2 s beep), file format round trip, caching,
// coalescing, progress and cancellation.

#import <XCTest/XCTest.h>

#include "../../Engine/Thumbs/WaveformService.h"
#include "../Media/BurnIn.h"
#include "../Media/RouterTestSupport.h"
#include "../Media/TestMedia.h"

#include <filesystem>
#include <fstream>

using namespace ve;
using namespace ve::media;
using namespace ve::test;
using namespace ve::thumbs;

namespace {

struct WaveCollector {
    std::mutex mutex;
    std::map<int, std::vector<WaveformResult>> results;
    std::vector<double> progress;
    Latch *latch = nullptr;

    WaveformCallback completion(int id) {
        return [this, id](WaveformResult r) {
            {
                std::lock_guard<std::mutex> lock(mutex);
                results[id].push_back(std::move(r));
            }
            if (latch) {
                latch->countDown();
            }
        };
    }
    WaveformProgress progressCallback() {
        return [this](double f) {
            std::lock_guard<std::mutex> lock(mutex);
            progress.push_back(f);
        };
    }
};

/// First bucket whose mono peak magnitude exceeds `threshold`, or -1.
long firstLoudBucket(const WaveformPeaks &p, float threshold) {
    for (size_t i = 0; i < p.bucketCount(); ++i) {
        if (std::max(p.mono[i].max, -p.mono[i].min) > threshold) {
            return static_cast<long>(i);
        }
    }
    return -1;
}

} // namespace

@interface WaveformServiceTests : XCTestCase
@end

@implementation WaveformServiceTests {
    dispatch_queue_t _queue;
    std::string _dir;
}

- (void)setUp {
    _queue = dispatch_queue_create("ve.test.waveform", DISPATCH_QUEUE_SERIAL);
    _dir = scratchDirectory() + "/waveforms";
}

- (std::string)mediaPath:(const std::string &)file {
    std::string error;
    const std::string path = testMediaPath(file, error);
    XCTAssertFalse(path.empty(), @"test media: %s", error.c_str());
    return path;
}

- (WaveformResult)peaksFrom:(WaveformService &)service request:(const WaveformRequest &)request {
    Latch latch(1);
    WaveCollector c;
    c.latch = &latch;
    service.request(request, _queue, c.completion(0));
    XCTAssertTrue(latch.wait(std::chrono::seconds(30)));
    std::lock_guard<std::mutex> lock(c.mutex);
    return c.results[0].at(0);
}

- (void)testBeepLandsInTheRightBucketLossless {
    const std::string path = [self mediaPath:"audio_only.wav"];
    if (path.empty()) {
        return;
    }
    WaveformService service(BackendRouter::makeDefault(), {});
    auto result = [self peaksFrom:service request:WaveformRequest{AssetId(1), path}];
    XCTAssertTrue(result.ok(), @"%s", result.ok() ? "" : result.error().description().c_str());
    if (!result.ok()) {
        return;
    }
    const WaveformPeaks &p = *result.value();
    XCTAssertEqual(p.bucketsPerSecond, 100u);
    XCTAssertEqual(p.samplesPerBucket(), 480);
    XCTAssertEqual(p.sampleRate, 48000.0);
    XCTAssertEqual(p.bucketCount(), size_t(1000), @"10 s at 100 buckets/s");
    XCTAssertEqual(p.perChannel.size(), size_t(p.channels));
    XCTAssertGreaterThanOrEqual(p.channels, 1u);

    const size_t beep = p.bucketAt(kMediaBeepStart);
    XCTAssertEqual(beep, size_t(200));
    XCTAssertEqual(firstLoudBucket(p, 0.3f), 200L, @"nothing loud before the beep");
    for (size_t i = 200; i < 210; ++i) {
        XCTAssertGreaterThan(p.mono[i].max, 0.6f, @"bucket %zu", i);
        XCTAssertLessThan(p.mono[i].min, -0.6f, @"bucket %zu", i);
    }
    for (size_t i : {size_t(0), size_t(150), size_t(199), size_t(210), size_t(500), size_t(999)}) {
        XCTAssertGreaterThan(p.mono[i].max, 0.08f, @"the tone is present in bucket %zu", i);
        XCTAssertLessThan(p.mono[i].max, 0.12f, @"bucket %zu", i);
    }
    for (uint32_t ch = 0; ch < p.channels; ++ch) {
        XCTAssertEqual(p.perChannel[ch].size(), p.bucketCount());
        XCTAssertGreaterThan(p.perChannel[ch][205].max, 0.6f);
        XCTAssertLessThan(p.perChannel[ch][195].max, 0.12f);
    }
    XCTAssertEqual(service.stats().computed, uint64_t(1));
    XCTAssertEqual(service.cached(AssetId(1)), result.value());
}

- (void)testBeepInCompressedAudioAndVideoFiles {
    for (const char *file : {"h264_1080p30.mp4", "audio_only.m4a", "hevc_720p2997.mov"}) {
        const std::string path = [self mediaPath:file];
        if (path.empty()) {
            return;
        }
        WaveformService service(BackendRouter::makeDefault(), {});
        auto result = [self peaksFrom:service request:WaveformRequest{AssetId(1), path}];
        XCTAssertTrue(result.ok(), @"%s", file);
        if (!result.ok()) {
            continue;
        }
        // AAC pre-echo can lift the bucket before the onset a little, never to beep level.
        XCTAssertEqual(firstLoudBucket(*result.value(), 0.4f), 200L, @"%s", file);
        XCTAssertGreaterThan(result.value()->mono[205].max, 0.6f, @"%s", file);
    }
}

- (void)testFileFormatRoundTripAndValidation {
    WaveformPeaks peaks;
    peaks.sampleRate = 48000;
    peaks.bucketsPerSecond = 100;
    peaks.channels = 2;
    for (int i = 0; i < 257; ++i) {
        const float v = static_cast<float>(i) / 257.0f;
        peaks.mono.push_back({-v, v});
    }
    peaks.perChannel = {peaks.mono, peaks.mono};
    peaks.perChannel[1][7] = {-0.25f, 0.75f};
    const WaveformSource source{12345, 678};
    const std::string path = scratchDirectory() + "/peaks.vewf";
    XCTAssertTrue(writeWaveformFile(path, peaks, source).ok());
    auto read = readWaveformFile(path, &source);
    XCTAssertTrue(read.ok());
    XCTAssertTrue(read.value() == peaks);
    XCTAssertEqual(std::filesystem::file_size(path), uintmax_t(4 + 4 + 8 + 8 + 8 + 4 + 4 + 8 + 257 * 8 * 3));

    const WaveformSource changed{12345, 999};
    XCTAssertEqual(readWaveformFile(path, &changed).error().code, MediaErrorCode::InvalidState);
    XCTAssertTrue(readWaveformFile(path).ok(), @"validation is optional");
    XCTAssertEqual(readWaveformFile(path + ".missing").error().code, MediaErrorCode::FileNotFound);

    // Truncated.
    std::filesystem::resize_file(path, std::filesystem::file_size(path) - 3);
    XCTAssertEqual(readWaveformFile(path).error().code, MediaErrorCode::CorruptData);
    // Wrong version.
    {
        std::fstream f(path, std::ios::in | std::ios::out | std::ios::binary);
        f.seekp(4);
        const char v2[4] = {2, 0, 0, 0};
        f.write(v2, 4);
    }
    XCTAssertEqual(readWaveformFile(path).error().code, MediaErrorCode::UnsupportedFormat);
    // Not a waveform file at all.
    {
        std::ofstream f(path, std::ios::binary | std::ios::trunc);
        f << "hello";
    }
    XCTAssertEqual(readWaveformFile(path).error().code, MediaErrorCode::CorruptData);
    // Mismatched shapes are rejected on write.
    peaks.perChannel.pop_back();
    XCTAssertEqual(writeWaveformFile(path, peaks, source).error().code, MediaErrorCode::InvalidArgument);
}

- (void)testDiskCacheRoundTripsThroughTheService {
    const std::string path = [self mediaPath:"audio_only.m4a"];
    if (path.empty()) {
        return;
    }
    const WaveformRequest request{AssetId(4), path};
    std::shared_ptr<const WaveformPeaks> computed;
    {
        WaveformService service(BackendRouter::makeDefault(), {_dir});
        auto r = [self peaksFrom:service request:request];
        XCTAssertTrue(r.ok());
        computed = r.value();
        XCTAssertEqual(service.stats().computed, uint64_t(1));
        // Memory hit.
        XCTAssertTrue([self peaksFrom:service request:request].value() == computed);
        XCTAssertEqual(service.stats().memoryHits, uint64_t(1));
        service.purge(AssetId(4));
        XCTAssertEqual(service.cached(AssetId(4)), nullptr);
    }
    XCTAssertTrue(std::filesystem::exists(_dir + "/" + WaveformService({}, {_dir}).diskFileName(request)));
    WaveformService service(BackendRouter::makeDefault(), {_dir});
    auto fromDisk = [self peaksFrom:service request:request];
    XCTAssertTrue(fromDisk.ok());
    XCTAssertEqual(service.stats().diskHits, uint64_t(1));
    XCTAssertEqual(service.stats().computed, uint64_t(0));
    XCTAssertTrue(*fromDisk.value() == *computed, @"the disk copy is bit-identical");
}

/// The in-memory peaks are tied to the file as it was: replacing the file behind the same
/// asset (a relink, or an edit saved over it) makes cached() return nothing and a request
/// recompute, instead of serving the old waveform.
- (void)testReplacedSourceFileIsRecomputed {
    const std::string original = [self mediaPath:"audio_only.wav"];
    const std::string other = [self mediaPath:"audio_44k.wav"];
    if (original.empty() || other.empty()) {
        return;
    }
    const std::string path = scratchDirectory() + "/replaced.wav";
    std::filesystem::copy_file(original, path);
    WaveformService service(BackendRouter::makeDefault(), {});
    const WaveformRequest request{AssetId(9), path};
    auto first = [self peaksFrom:service request:request];
    XCTAssertTrue(first.ok());
    XCTAssertTrue(service.cached(AssetId(9)) != nullptr);
    std::filesystem::copy_file(other, path, std::filesystem::copy_options::overwrite_existing);
    XCTAssertEqual(service.cached(AssetId(9)), nullptr, @"stale peaks are not offered");
    auto second = [self peaksFrom:service request:request];
    XCTAssertTrue(second.ok());
    XCTAssertEqual(service.stats().computed, uint64_t(2));
    XCTAssertEqual(service.stats().memoryHits, uint64_t(0));
    if (first.ok() && second.ok()) {
        XCTAssertNotEqual(first.value()->bucketCount(), second.value()->bucketCount(), @"10 s vs 6 s of audio");
    }
}

/// The .vewf disk cache stays within Config::diskBudgetBytes.
- (void)testDiskCacheIsBounded {
    std::vector<std::string> files;
    for (const char *f : {"audio_only.wav", "audio_only.m4a", "audio_44k.wav", "audio_44k.m4a", "audio_mono.m4a"}) {
        files.push_back([self mediaPath:f]);
    }
    uint64_t one = 0;
    {
        WaveformService service(BackendRouter::makeDefault(), {_dir});
        const WaveformRequest first{AssetId(1), files[0]};
        XCTAssertTrue([self peaksFrom:service request:first].ok());
        for (const auto &entry : std::filesystem::directory_iterator(_dir)) {
            one = std::max<uint64_t>(one, entry.file_size());
        }
    }
    WaveformService::Config config;
    config.diskCacheDirectory = _dir;
    config.diskBudgetBytes = one * 2 + one / 2;
    WaveformService service(BackendRouter::makeDefault(), config);
    for (size_t i = 0; i < files.size(); ++i) {
        const WaveformRequest request{AssetId(10 + static_cast<int>(i)), files[i]};
        XCTAssertTrue([self peaksFrom:service request:request].ok());
    }
    uint64_t total = 0;
    for (const auto &entry : std::filesystem::directory_iterator(_dir)) {
        if (entry.path().extension() == ".vewf") {
            total += entry.file_size();
        }
    }
    XCTAssertLessThanOrEqual(total, config.diskBudgetBytes);
    XCTAssertEqual(service.stats().diskWriteFailures, uint64_t(0));
}

- (void)testCoalescingProgressAndCancellation {
    const std::string path = [self mediaPath:"hevc_720p2997.mov"];
    if (path.empty()) {
        return;
    }
    WaveformService service(BackendRouter::makeDefault(), {});
    WaveCollector c;
    Latch latch(3);
    c.latch = &latch;
    const WaveformRequest request{AssetId(5), path};
    service.request(request, _queue, c.completion(1), c.progressCallback());
    service.request(request, _queue, c.completion(2));
    const auto cancelled = service.request(request, _queue, c.completion(3));
    XCTAssertTrue(service.cancel(cancelled));
    XCTAssertFalse(service.cancel(cancelled), @"already cancelled");
    XCTAssertFalse(service.cancel(987654));
    XCTAssertTrue(latch.wait(std::chrono::seconds(30)));
    // Let the queued progress blocks drain.
    dispatch_sync(_queue, ^{
                  });
    std::lock_guard<std::mutex> lock(c.mutex);
    XCTAssertTrue(c.results[1].at(0).ok());
    XCTAssertTrue(c.results[2].at(0).ok());
    XCTAssertTrue(c.results[1].at(0).value() == c.results[2].at(0).value(), @"one computation");
    XCTAssertEqual(c.results[3].size(), size_t(1));
    XCTAssertEqual(c.results[3].at(0).error().code, MediaErrorCode::Cancelled);
    XCTAssertEqual(service.stats().computed, uint64_t(1));
    XCTAssertGreaterThanOrEqual(c.progress.size(), size_t(3));
    XCTAssertTrue(std::is_sorted(c.progress.begin(), c.progress.end()));
    XCTAssertEqual(c.progress.back(), 1.0);
}

- (void)testCancellingEveryRequestStopsTheComputation {
    // A fake audio track of ten hours: far too long to finish before the cancel lands.
    auto fake = std::make_shared<FakeBehavior>();
    fake->frames = 30 * 36000;
    fake->probe = [](const std::string &p) {
        MediaInfo info = makeFakeInfo(p, "mov", fourcc::H264);
        info.tracks.erase(info.tracks.begin());
        return Result<MediaInfo>(info);
    };
    auto router = std::make_shared<BackendRouter>();
    (void)router->registerBackend(std::make_shared<FakeBackend>(fake));
    WaveCollector c;
    Latch latch(1);
    c.latch = &latch;
    {
        WaveformService service(router, {});
        const auto id = service.request(WaveformRequest{AssetId(1), "/fake.mov"}, _queue, c.completion(1));
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
        XCTAssertTrue(service.cancel(id));
        XCTAssertTrue(latch.wait(std::chrono::seconds(5)));
        // The destructor joins the worker, which notices the cancellation at its next chunk.
    }
    std::lock_guard<std::mutex> lock(c.mutex);
    XCTAssertEqual(c.results[1].at(0).error().code, MediaErrorCode::Cancelled);
    XCTAssertEqual(c.results.size(), size_t(1));
}

- (void)testErrors {
    WaveformService service(BackendRouter::makeDefault(), {});
    auto missing = [self peaksFrom:service request:WaveformRequest{AssetId(1), "/nonexistent.wav"}];
    XCTAssertEqual(missing.error().code, MediaErrorCode::FileNotFound);
    auto invalid = [self peaksFrom:service request:WaveformRequest{AssetId(1), ""}];
    XCTAssertEqual(invalid.error().code, MediaErrorCode::InvalidArgument);
    const std::string still = [self mediaPath:"still.png"];
    if (!still.empty()) {
        auto noAudio = [self peaksFrom:service request:WaveformRequest{AssetId(2), still}];
        XCTAssertEqual(noAudio.error().code, MediaErrorCode::NoSuchTrack);
    }
    WaveformService::Config bad;
    bad.sampleRate = 44100;
    bad.bucketsPerSecond = 1000; // 44.1 samples per bucket.
    WaveformService badService(BackendRouter::makeDefault(), bad);
    auto rejected = [self peaksFrom:badService request:WaveformRequest{AssetId(1), "/x.wav"}];
    XCTAssertEqual(rejected.error().code, MediaErrorCode::InvalidArgument);
}

@end
