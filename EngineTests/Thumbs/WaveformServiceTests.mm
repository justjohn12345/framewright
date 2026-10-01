// WaveformService: peak positions (the 2 s beep), file format round trip, caching,
// coalescing, progress and cancellation.

#import <XCTest/XCTest.h>

#include "../../Engine/Thumbs/WaveformService.h"
#include "../Audio/AudioTestSupport.h"
#include "../Media/BurnIn.h"
#include "../Media/RouterTestSupport.h"
#include "../Media/TestMedia.h"

#include <filesystem>
#include <fstream>
#include <thread>

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

/// Waits (up to 10 s) until `count` tone decoder reads are held at the behaviour's gate.
bool waitForBlockedReads(ToneBehavior &behavior, int count) {
    for (int i = 0; i < 2000 && behavior.blockedReads.load() < count; ++i) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    return behavior.blockedReads.load() >= count;
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
    XCTAssertEqual(service.cached(AssetId(1), path), result.value());
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
        XCTAssertEqual(service.cached(AssetId(4), path), nullptr);
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
    XCTAssertTrue(service.cached(AssetId(9), path) != nullptr);
    std::filesystem::copy_file(other, path, std::filesystem::copy_options::overwrite_existing);
    XCTAssertEqual(service.cached(AssetId(9), path), nullptr, @"stale peaks are not offered");
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

/// Asset ids restart in every project: a request for another file under the id of a running
/// computation (a new project's asset while the closed project's waveform still computes) must
/// get its own file's peaks, not join the computation of the other file.
- (void)testARequestForAnotherFileUnderTheSameAssetDoesNotJoinItsComputation {
    auto tone = std::make_shared<ToneBehavior>();
    tone->lengthFrames = 48000 * 3;
    tone->setSignal("/tone/loud.wav", constantSignal(0.9f, 0.9f));
    tone->setSignal("/tone/quiet.wav", constantSignal(0.1f, 0.1f));
    WaveformService service(makeToneRouter(tone), {});
    WaveCollector c;
    Latch latch(2);
    c.latch = &latch;
    tone->setReadsBlocked(true);
    service.request(WaveformRequest{AssetId(1), "/tone/loud.wav"}, _queue, c.completion(1));
    XCTAssertTrue(waitForBlockedReads(*tone, 1), @"the loud file's computation is running");
    service.request(WaveformRequest{AssetId(1), "/tone/quiet.wav"}, _queue, c.completion(2));
    tone->setReadsBlocked(false);
    XCTAssertTrue(latch.wait(std::chrono::seconds(30)));
    std::lock_guard<std::mutex> lock(c.mutex);
    const WaveformResult &loud = c.results[1].at(0);
    const WaveformResult &quiet = c.results[2].at(0);
    XCTAssertTrue(loud.ok() && quiet.ok());
    if (loud.ok() && quiet.ok()) {
        XCTAssertEqual(loud.value()->bucketCount(), size_t(300));
        XCTAssertEqualWithAccuracy(loud.value()->mono[150].max, 0.9f, 1e-5);
        XCTAssertEqualWithAccuracy(quiet.value()->mono[150].max, 0.1f, 1e-5, @"the quiet file's own peaks");
    }
    XCTAssertEqual(service.stats().computed, uint64_t(2), @"one computation per file");
}

/// cached() and the memory cache answer only for the file asked about: the peaks of another path
/// stored under the same asset id are not offered, and storing a new path's peaks for the asset
/// replaces the previous path's entry (one file per asset and track).
- (void)testTheMemoryCacheAnswersOnlyForTheRequestedFile {
    auto tone = std::make_shared<ToneBehavior>();
    tone->lengthFrames = 48000;
    tone->setSignal("/tone/loud.wav", constantSignal(0.9f, 0.9f));
    tone->setSignal("/tone/quiet.wav", constantSignal(0.1f, 0.1f));
    WaveformService service(makeToneRouter(tone), {});
    auto loud = [self peaksFrom:service request:WaveformRequest{AssetId(1), "/tone/loud.wav"}];
    XCTAssertTrue(loud.ok());
    XCTAssertTrue(service.cached(AssetId(1), "/tone/loud.wav") == loud.value());
    XCTAssertEqual(service.cached(AssetId(1), "/tone/quiet.wav"), nullptr, @"another file under the same id");
    XCTAssertEqual(service.cached(AssetId(2), "/tone/loud.wav"), nullptr, @"another asset");
    auto quiet = [self peaksFrom:service request:WaveformRequest{AssetId(1), "/tone/quiet.wav"}];
    XCTAssertTrue(quiet.ok());
    XCTAssertEqual(service.stats().memoryHits, uint64_t(0), @"the loud file's peaks did not answer");
    if (quiet.ok()) {
        XCTAssertEqualWithAccuracy(quiet.value()->mono[50].max, 0.1f, 1e-5);
    }
    XCTAssertTrue(service.cached(AssetId(1), "/tone/quiet.wav") == quiet.value());
    XCTAssertEqual(service.cached(AssetId(1), "/tone/loud.wav"), nullptr, @"the relinked asset's old file is dropped");
}

/// A job cancelled after it started that finishes anyway (its last read was under way) is neither delivered
/// nor stored (review R7 of the 2026-09-30 fix round): stored, it dropped another path's entry for the
/// asset and track (one file per asset and track), which after New/Open (asset ids restart) is the new
/// project's file, computed meanwhile on another worker.
- (void)testACancelledJobThatFinishesAnywayIsNotStored {
    auto tone = std::make_shared<ToneBehavior>();
    tone->lengthFrames = 12000; // a quarter second: one read (fewer frames than a chunk of 32 buckets)
    tone->setSignal("/tone/old.wav", constantSignal(0.9f, 0.9f));
    tone->setSignal("/tone/new.wav", constantSignal(0.1f, 0.1f));
    std::filesystem::remove_all(_dir);
    WaveformService::Config config;
    config.diskCacheDirectory = _dir;
    config.threads = 2;
    WaveformService service(makeToneRouter(tone), config);
    // The new file's peaks on disk, and not in memory: its next computation is a disk read (no decoder read).
    auto first = [self peaksFrom:service request:WaveformRequest{AssetId(1), "/tone/new.wav"}];
    XCTAssertTrue(first.ok());
    service.purge(AssetId(1));
    XCTAssertEqual(service.cached(AssetId(1), "/tone/new.wav"), nullptr);

    // The old project's file (asset 1) computes on one worker, held in its only read; its request is cancelled.
    tone->setReadsBlocked(true);
    WaveCollector c;
    Latch cancelled(1);
    c.latch = &cancelled;
    const auto old = service.request(WaveformRequest{AssetId(1), "/tone/old.wav"}, _queue, c.completion(1));
    XCTAssertTrue(waitForBlockedReads(*tone, 1), @"the old file's computation is running");
    XCTAssertTrue(service.cancel(old));
    XCTAssertTrue(cancelled.wait(std::chrono::seconds(10)));
    // The new project's asset 1 (the new file) comes from the disk cache on the other worker and is stored.
    auto fresh = [self peaksFrom:service request:WaveformRequest{AssetId(1), "/tone/new.wav"}];
    XCTAssertTrue(fresh.ok());
    XCTAssertTrue(service.cached(AssetId(1), "/tone/new.wav") == fresh.value());
    // The old computation's read returns: it finishes with its peaks, after its cancellation.
    tone->setReadsBlocked(false);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (service.stats().discarded + service.stats().computed < 2 && std::chrono::steady_clock::now() < deadline) {
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    const WaveformService::Stats stats = service.stats();
    XCTAssertEqual(stats.discarded, uint64_t(1), @"the cancelled job finished with its peaks and dropped them");
    XCTAssertEqual(stats.computed, uint64_t(1), @"the new file's first computation only");
    XCTAssertTrue(service.cached(AssetId(1), "/tone/new.wav") == fresh.value(), @"the new file's entry is kept");
    XCTAssertEqual(service.cached(AssetId(1), "/tone/old.wav"), nullptr, @"the cancelled job's peaks are not stored");
    std::lock_guard<std::mutex> lock(c.mutex);
    XCTAssertEqual(c.results[1].size(), size_t(1));
    XCTAssertEqual(c.results[1].at(0).error().code, MediaErrorCode::Cancelled);
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
