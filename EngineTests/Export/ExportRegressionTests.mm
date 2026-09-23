// Regression tests for the phase 7 review (docs/reviews/2026-09-23-phase7-review.md), probes P1,
// P2 and P3 made permanent:
// - P1: an export over an existing file never destroys it. Cancelled, failed in the middle of the
//   file (a writer that reports "disk full" after some frames) or failed while finishing, on both
//   writer backends (AVAssetWriter for H.264/MP4, FFmpeg for AV1/Matroska), the user's previous
//   file is still there byte for byte and nothing else is left next to it; a successful export
//   replaces it.
// - P2: a video track that ends before the asset's duration (the container runs on with audio, or
//   the track's duration overstates it) exports: the tail holds the last picture, as the program
//   monitor does, instead of failing.
// - P3: an audio read error in the middle of the stream (not at open) fails the export with a
//   message naming the clip and the time, instead of writing silence and reporting success.

#import <XCTest/XCTest.h>

#include "../../Engine/Export/ExportJob.h"
#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../../Engine/Media/AssetImport.h"
#include "../../Engine/Media/FFmpeg/FFVideoEncoder.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Model/Validation.h"
#include "../Media/BurnIn.h"
#include "../Media/RouterTestSupport.h"
#include "../Media/TestMedia.h"

#import <Foundation/Foundation.h>

#include <sys/stat.h>

#include <fstream>
#include <iterator>
#include <mutex>
#include <optional>
#include <set>
#include <sstream>
#include <string>

using namespace ve;
namespace ex = ve::exporting;

namespace {

bool fileExists(const std::string &path) {
    struct stat st {};
    return ::stat(path.c_str(), &st) == 0;
}

std::string readFile(const std::string &path) {
    std::ifstream in(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

std::set<std::string> directoryListing(const std::string &dir) {
    std::set<std::string> names;
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@(dir.c_str()) error:nil]) {
        names.insert(name.UTF8String);
    }
    return names;
}

/// A writer that forwards to a real one and fails like a full disk: after `failAfterFrames`
/// video frames (the file is being written by then), or in finish().
class FailingWriter final : public media::IMediaWriter {
  public:
    /// `onFinish` runs at the start of finish() (e.g. to cancel the export while it finishes).
    FailingWriter(std::unique_ptr<media::IMediaWriter> inner, int failAfterFrames, bool failInFinish,
                  std::function<void()> onFinish = {})
        : inner_(std::move(inner)), failAfterFrames_(failAfterFrames), failInFinish_(failInFinish),
          onFinish_(std::move(onFinish)) {}

    media::Status open(const std::string &path, const media::EncodeSettings &settings) override {
        return inner_->open(path, settings);
    }
    media::Result<media::PixelBuffer> makePixelBuffer() override { return inner_->makePixelBuffer(); }
    media::Status appendVideo(const media::PixelBuffer &image, CMTime pts) override {
        return inner_->appendVideo(image, pts);
    }
    media::Status appendAudio(const float *interleaved, int frames) override {
        return inner_->appendAudio(interleaved, frames);
    }
    media::Status endStream(media::TrackKind kind) override { return inner_->endStream(kind); }
    media::Status runPull(const media::VideoPullFn &video, const media::AudioPullFn &audio) override {
        media::VideoPullFn failing;
        if (video) {
            failing = [this, video]() -> media::Result<std::optional<media::VideoInput>> {
                if (failAfterFrames_ >= 0 && frames_ >= failAfterFrames_) {
                    return media::makeError(media::MediaErrorCode::WriteFailed,
                                            "writing the movie failed: No space left on device (simulated)");
                }
                ++frames_;
                return video();
            };
        }
        return inner_->runPull(failing, audio);
    }
    media::Status finish() override {
        if (onFinish_) {
            onFinish_();
        }
        if (failInFinish_) {
            inner_->cancel();
            return media::makeError(media::MediaErrorCode::WriteFailed,
                                    "writing the index failed: No space left on device (simulated)");
        }
        return inner_->finish();
    }
    void setFinishCancellation(std::function<bool()> check) override { inner_->setFinishCancellation(std::move(check)); }
    void cancel() override { inner_->cancel(); }
    bool usesHardwareVideoEncoder() const override { return inner_->usesHardwareVideoEncoder(); }
    std::string videoEncoderName() const override { return inner_->videoEncoderName(); }

  private:
    std::unique_ptr<media::IMediaWriter> inner_;
    const int failAfterFrames_;
    const bool failInFinish_;
    const std::function<void()> onFinish_;
    int frames_ = 0; // the writer's video thread only
};

/// Stands in for a real backend (same name, so the router prefers it as it would the original)
/// and hands out FailingWriters around the original's writers.
class FailingWriterBackend final : public media::IMediaBackend {
  public:
    FailingWriterBackend(std::shared_ptr<media::IMediaBackend> inner, int failAfterFrames, bool failInFinish,
                         std::function<void()> onFinish = {})
        : inner_(std::move(inner)), failAfterFrames_(failAfterFrames), failInFinish_(failInFinish),
          onFinish_(std::move(onFinish)) {}
    std::string name() const override { return inner_->name(); }
    std::unique_ptr<media::IMediaProber> makeProber() override { return inner_->makeProber(); }
    std::unique_ptr<media::IVideoDecoder> makeVideoDecoder() override { return inner_->makeVideoDecoder(); }
    std::unique_ptr<media::IAudioDecoder> makeAudioDecoder() override { return inner_->makeAudioDecoder(); }
    std::unique_ptr<media::IMediaWriter> makeWriter() override {
        return std::make_unique<FailingWriter>(inner_->makeWriter(), failAfterFrames_, failInFinish_, onFinish_);
    }
    bool canHandle(const media::MediaInfo &info) const override { return inner_->canHandle(info); }
    bool canWrite(const media::EncodeSettings &settings) const override { return inner_->canWrite(settings); }

  private:
    std::shared_ptr<media::IMediaBackend> inner_;
    const int failAfterFrames_;
    const bool failInFinish_;
    const std::function<void()> onFinish_;
};

/// A 288x162 30 fps sequence with V1 and A1, and the plumbing to export it.
struct Rig {
    Project project;
    SequenceId seq;
    TrackId v1, a1;
    std::shared_ptr<media::BackendRouter> router;
    std::shared_ptr<media::FrameCache> cache = std::make_shared<media::FrameCache>();
    std::map<AssetId, media::RoutedMediaInfo> routing;
    dispatch_queue_t queue = dispatch_queue_create("com.justjohn12345.framewright.tests.export-regression",
                                                   DISPATCH_QUEUE_SERIAL);
    std::string error;
    /// The running export, and the working file it reported (ExportJob::workingPath()).
    std::mutex jobMutex;
    std::weak_ptr<ex::ExportJob> currentJob;
    std::string workingPath;

    void cancelCurrentJob() {
        std::lock_guard<std::mutex> l(jobMutex);
        if (auto job = currentJob.lock()) {
            job->cancel();
        }
    }

    explicit Rig(std::shared_ptr<media::BackendRouter> r) : router(std::move(r)) {
        seq = project.addSequence("S", CMTimeMake(1, 30), 288, 162, 1, 1);
        v1 = project.findSequence(seq)->videoTracks[0].id;
        a1 = project.findSequence(seq)->audioTracks[0].id;
    }
    Sequence &sequence() { return *project.findSequence(seq); }

    AssetId importPath(const std::string &path) {
        auto routed = router->probe(path);
        if (!routed.ok()) {
            error = routed.error().description();
            return {};
        }
        const AssetId id = project.ids.make<AssetId>();
        auto asset = media::makeMediaAsset(*routed, id);
        if (!asset.ok()) {
            error = asset.error().description();
            return {};
        }
        project.assets.push_back(*asset);
        routing[id] = *routed;
        return id;
    }
    AssetId importFile(const std::string &file) {
        std::string mediaError;
        const std::string path = test::testMediaPath(file, mediaError);
        if (path.empty()) {
            error = mediaError;
            return {};
        }
        return importPath(path);
    }

    ClipId add(TrackId track, AssetId asset, int64_t start, int64_t frames, CMTime in) {
        Clip c;
        c.id = project.ids.make<ClipId>();
        c.assetId = asset;
        c.trackId = track;
        c.timelineStart = CMTimeMake(start, 30);
        c.timelineDuration = CMTimeMake(frames, 30);
        c.sourceIn = in;
        c.isStill = project.findAsset(asset)->isStill();
        Track &t = *sequence().findTrack(track);
        t.clips.push_back(c);
        t.sortClips();
        return c.id;
    }

    ex::ExportRequest request(const std::string &path, media::VideoCodec codec, media::ContainerFormat container,
                              bool audio, int width, int height) {
        ex::ExportRequest r;
        r.project = std::make_shared<const Project>(project);
        r.sequenceId = seq;
        r.encode.container = container;
        media::VideoEncodeSettings v;
        v.codec = codec;
        v.width = width;
        v.height = height;
        v.quality = 0.9;
        r.encode.video = v;
        if (audio) {
            media::AudioEncodeSettings a;
            a.codec = media::AudioCodec::AAC;
            a.bitRate = 128000;
            r.encode.audio = a;
        }
        r.outputPath = path;
        return r;
    }

    ex::ExportServices services() {
        ex::ExportServices sv;
        sv.router = router;
        sv.cache = cache;
        sv.epoch = cache->epoch();
        sv.routing = routing;
        return sv;
    }

    /// Runs the export to completion; `onProgress` may cancel it. nullopt when start() refused
    /// (error set) or the completion did not come within two minutes.
    std::optional<media::Result<ex::ExportSummary>>
    run(const ex::ExportRequest &r, std::function<void(ex::ExportJob &, const ex::ExportProgress &)> onProgress = {}) {
        auto result = std::make_shared<std::optional<media::Result<ex::ExportSummary>>>();
        auto jobRef = std::make_shared<std::weak_ptr<ex::ExportJob>>();
        auto m = std::make_shared<std::mutex>();
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        auto started = ex::ExportJob::start(
            r, services(), {}, queue,
            [this, jobRef, m, onProgress](const ex::ExportProgress &p) {
                std::lock_guard<std::mutex> l(*m);
                if (auto j = jobRef->lock()) {
                    if (const std::string working = j->workingPath(); !working.empty()) {
                        std::lock_guard<std::mutex> jl(jobMutex);
                        workingPath = working;
                    }
                    if (onProgress) {
                        onProgress(*j, p);
                    }
                }
            },
            [result, m, done](media::Result<ex::ExportSummary> res) {
                std::lock_guard<std::mutex> l(*m);
                *result = std::move(res);
                dispatch_semaphore_signal(done);
            });
        if (!started.ok()) {
            error = started.error().description();
            return std::nullopt;
        }
        {
            std::lock_guard<std::mutex> l(*m);
            *jobRef = started.value();
        }
        {
            std::lock_guard<std::mutex> jl(jobMutex);
            currentJob = started.value();
        }
        started.value().reset();
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, int64_t(120) * NSEC_PER_SEC));
        std::lock_guard<std::mutex> l(*m);
        return *result;
    }
};

std::shared_ptr<media::BackendRouter> productionRouter() {
    auto router = media::BackendRouter::makeDefault();
    (void)router->registerBackend(media::ffmpeg::makeFFmpegBackend());
    return router;
}

/// A router whose `backendName` writer ("apple" or "ffmpeg") fails as FailingWriter does.
std::shared_ptr<media::BackendRouter> failingRouter(const std::string &backendName, int failAfterFrames,
                                                    bool failInFinish) {
    auto router = productionRouter();
    (void)router->registerBackend(
        std::make_shared<FailingWriterBackend>(router->backend(backendName), failAfterFrames, failInFinish));
    return router;
}

std::shared_ptr<media::BackendRouter> fakeRouter(std::shared_ptr<test::FakeBehavior> behavior) {
    auto router = std::make_shared<media::BackendRouter>();
    (void)router->registerBackend(std::make_shared<test::FakeBackend>(std::move(behavior)));
    (void)router->registerBackend(media::apple::makeAppleBackend());
    return router;
}

/// First video frame of `path` at or after `t`, through the router's decoders.
std::optional<media::VideoFrame> frameAt(const media::BackendRouter &router, const std::string &path, CMTime t) {
    auto routed = router.probe(path);
    if (!routed.ok()) {
        return std::nullopt;
    }
    auto decoder = router.makeVideoDecoder(*routed, -1, media::DecodeOptions{});
    if (!decoder.ok() || !decoder->decoder->seek(t).ok()) {
        return std::nullopt;
    }
    auto next = decoder->decoder->next();
    if (!next.ok() || !next.value()) {
        return std::nullopt;
    }
    return *next.value();
}

constexpr const char *kPrecious = "the user's previous export: must survive a cancelled or failed export";

} // namespace

@interface ExportRegressionTests : XCTestCase
@end

@implementation ExportRegressionTests {
    std::string _dir;
}

- (void)setUp {
    _dir = ve::test::scratchDirectory();
}

- (BOOL)av1Available {
    return media::ffmpeg::FFVideoEncoder::isAvailable(media::VideoCodec::AV1);
}

/// The sequence for the P1 cases: 10 s of the 1080p burn-in movie on V1 and A1.
- (void)buildLongSequence:(Rig &)rig {
    const AssetId movie = rig.importFile("h264_1080p30.mp4");
    XCTAssertTrue(rig.error.empty(), @"%s", rig.error.c_str());
    rig.add(rig.v1, movie, 0, 300, kCMTimeZero);
    rig.add(rig.a1, movie, 0, 300, kCMTimeZero);
}

/// Writes the "previous export" at `name` in the scratch folder; returns its path.
- (std::string)preexisting:(NSString *)name {
    const std::string path = _dir + "/" + name.UTF8String;
    std::ofstream(path, std::ios::binary) << kPrecious;
    XCTAssertTrue(fileExists(path));
    return path;
}

/// The previous file is untouched and nothing else was left in its folder.
- (void)assertPreexistingIntact:(const std::string &)path listingBefore:(const std::set<std::string> &)before
                           what:(NSString *)what {
    XCTAssertTrue(fileExists(path), @"%@: the user's previous file was deleted", what);
    XCTAssertEqual(readFile(path), std::string(kPrecious), @"%@: the user's previous file was changed", what);
    XCTAssertTrue(directoryListing(_dir) == before, @"%@: files were left next to the output", what);
}

/// The working file the export reported is gone, with its directory.
- (void)assertNoWorkingFileLeft:(Rig &)rig what:(NSString *)what {
    std::lock_guard<std::mutex> l(rig.jobMutex);
    XCTAssertFalse(rig.workingPath.empty(), @"%@: the export reported its working file", what);
    if (!rig.workingPath.empty()) {
        XCTAssertFalse(fileExists(rig.workingPath), @"%@: %s was left behind", what, rig.workingPath.c_str());
        XCTAssertFalse(fileExists(rig.workingPath.substr(0, rig.workingPath.find_last_of('/'))),
                       @"%@: the working directory was left behind", what);
    }
}

- (void)cancelOverExistingFileWithCodec:(media::VideoCodec)codec
                              container:(media::ContainerFormat)container
                                   name:(NSString *)name {
    Rig rig(productionRouter());
    [self buildLongSequence:rig];
    const std::string path = [self preexisting:name];
    const std::set<std::string> before = directoryListing(_dir);
    bool cancelled = false;
    auto result = rig.run(rig.request(path, codec, container, true, 640, 360),
                          [&](ex::ExportJob &job, const ex::ExportProgress &p) {
                              if (p.framesDone >= 10 && !cancelled) {
                                  cancelled = true;
                                  job.cancel();
                              }
                          });
    XCTAssertTrue(result.has_value(), @"%@: %s", name, rig.error.c_str());
    XCTAssertTrue(cancelled, @"%@: the export was cancelled while writing", name);
    [self assertNoWorkingFileLeft:rig what:name];
    if (result) {
        XCTAssertFalse(result->ok(), @"%@", name);
        if (!result->ok()) {
            XCTAssertEqual(result->error().code, media::MediaErrorCode::Cancelled, @"%@: %s", name,
                           result->error().description().c_str());
        }
    }
    [self assertPreexistingIntact:path listingBefore:before what:name];
}

- (void)testCancelledExportKeepsTheExistingFileAppleWriter {
    [self cancelOverExistingFileWithCodec:media::VideoCodec::H264
                                container:media::ContainerFormat::MP4
                                     name:@"precious.mp4"];
}

- (void)testCancelledExportKeepsTheExistingFileFFmpegWriter {
    XCTAssertTrue([self av1Available], @"this build is expected to have SVT-AV1 (Scripts/build-ffmpeg.sh)");
    [self cancelOverExistingFileWithCodec:media::VideoCodec::AV1
                                container:media::ContainerFormat::MKV
                                     name:@"precious.mkv"];
}

- (void)failOverExistingFileWithBackend:(const std::string &)backend
                                  codec:(media::VideoCodec)codec
                              container:(media::ContainerFormat)container
                                   name:(NSString *)name
                           failInFinish:(BOOL)failInFinish {
    Rig rig(failingRouter(backend, failInFinish ? -1 : 20, failInFinish));
    [self buildLongSequence:rig];
    const std::string path = [self preexisting:name];
    const std::set<std::string> before = directoryListing(_dir);
    auto result = rig.run(rig.request(path, codec, container, true, 640, 360));
    XCTAssertTrue(result.has_value(), @"%@: %s", name, rig.error.c_str());
    if (result) {
        XCTAssertFalse(result->ok(), @"%@: the write failure must fail the export", name);
        if (!result->ok()) {
            XCTAssertEqual(result->error().code, media::MediaErrorCode::WriteFailed, @"%@: %s", name,
                           result->error().description().c_str());
            XCTAssertNotEqual(result->error().description().find("No space left on device"), std::string::npos,
                              @"%@: %s", name, result->error().description().c_str());
        }
    }
    [self assertPreexistingIntact:path listingBefore:before what:name];
    [self assertNoWorkingFileLeft:rig what:name];
}

- (void)testWriteFailureMidFileKeepsTheExistingFileAppleWriter {
    [self failOverExistingFileWithBackend:"apple"
                                    codec:media::VideoCodec::H264
                                container:media::ContainerFormat::MP4
                                     name:@"precious-fail.mp4"
                             failInFinish:NO];
}

- (void)testWriteFailureMidFileKeepsTheExistingFileFFmpegWriter {
    XCTAssertTrue([self av1Available], @"this build is expected to have SVT-AV1 (Scripts/build-ffmpeg.sh)");
    [self failOverExistingFileWithBackend:"ffmpeg"
                                    codec:media::VideoCodec::AV1
                                container:media::ContainerFormat::MKV
                                     name:@"precious-fail.mkv"
                             failInFinish:NO];
}

- (void)testWriteFailureWhileFinishingKeepsTheExistingFile {
    [self failOverExistingFileWithBackend:"apple"
                                    codec:media::VideoCodec::H264
                                container:media::ContainerFormat::MOV
                                     name:@"precious-finish.mov"
                             failInFinish:YES];
}

- (void)successOverExistingFileWithCodec:(media::VideoCodec)codec
                               container:(media::ContainerFormat)container
                                    name:(NSString *)name {
    Rig rig(productionRouter());
    const AssetId movie = rig.importFile("h264_1080p30.mp4");
    XCTAssertTrue(rig.error.empty(), @"%s", rig.error.c_str());
    rig.add(rig.v1, movie, 0, 30, kCMTimeZero);
    rig.add(rig.a1, movie, 0, 30, kCMTimeZero);
    const std::string path = [self preexisting:name];
    const std::set<std::string> before = directoryListing(_dir);
    auto result = rig.run(rig.request(path, codec, container, true, 640, 360));
    XCTAssertTrue(result.has_value(), @"%@: %s", name, rig.error.c_str());
    if (!result) {
        return;
    }
    XCTAssertTrue(result->ok(), @"%@: %s", name, result->ok() ? "" : result->error().description().c_str());
    XCTAssertNotEqual(readFile(path), std::string(kPrecious), @"%@: the file was replaced", name);
    [self assertNoWorkingFileLeft:rig what:name];
    XCTAssertTrue(directoryListing(_dir) == before, @"%@: only the output itself is in its folder", name);
    auto probed = rig.router->probe(path);
    XCTAssertTrue(probed.ok(), @"%@: %s", name, probed.ok() ? "" : probed.error().description().c_str());
    if (probed.ok() && result->ok()) {
        const media::TrackInfo *video = probed->info.firstTrack(media::TrackKind::Video);
        XCTAssertTrue(video != nullptr);
        XCTAssertEqualWithAccuracy(CMTimeGetSeconds(probed->info.duration), 1.0, 0.002, @"%@", name);
        XCTAssertEqual(result->value().bytes, uint64_t(readFile(path).size()), @"%@", name);
    }
}

- (void)testSuccessfulExportReplacesTheExistingFileAppleWriter {
    [self successOverExistingFileWithCodec:media::VideoCodec::H264
                                 container:media::ContainerFormat::MP4
                                      name:@"replaced.mp4"];
}

- (void)testSuccessfulExportReplacesTheExistingFileFFmpegWriter {
    XCTAssertTrue([self av1Available], @"this build is expected to have SVT-AV1 (Scripts/build-ffmpeg.sh)");
    [self successOverExistingFileWithCodec:media::VideoCodec::AV1
                                 container:media::ContainerFormat::MKV
                                      name:@"replaced.mkv"];
}

/// A cancel while the writer finishes the file (AVAssetWriter rewriting an MP4 to put its index
/// first) is honoured: the export reports Cancelled, the previous file is kept, and nothing is
/// left behind.
- (void)testCancelWhileFinishingKeepsTheExistingFile {
    auto router = productionRouter();
    Rig *rigRef = nullptr;
    (void)router->registerBackend(std::make_shared<FailingWriterBackend>(router->backend("apple"), -1, false, [&rigRef] {
        if (rigRef != nullptr) {
            rigRef->cancelCurrentJob();
        }
    }));
    Rig rig(router);
    rigRef = &rig;
    [self buildLongSequence:rig];
    const std::string path = [self preexisting:@"precious-finishing.mp4"];
    const std::set<std::string> before = directoryListing(_dir);
    auto result = rig.run(rig.request(path, media::VideoCodec::H264, media::ContainerFormat::MP4, true, 640, 360));
    XCTAssertTrue(result.has_value(), @"%s", rig.error.c_str());
    if (result) {
        XCTAssertFalse(result->ok());
        if (!result->ok()) {
            XCTAssertEqual(result->error().code, media::MediaErrorCode::Cancelled, @"%s",
                           result->error().description().c_str());
        }
    }
    [self assertPreexistingIntact:path listingBefore:before what:@"cancel in finish()"];
    [self assertNoWorkingFileLeft:rig what:@"cancel in finish()"];
    rigRef = nullptr;
}

// P2: 60 frames of pictures (2 s) in media whose container and track say 10 s. A 3 s clip passes
// validation (the model knows only the durations the prober reported) and must export, holding
// the last picture over the last second, like the program monitor.
- (void)testVideoShorterThanItsDurationHoldsTheLastPicture {
    auto behavior = std::make_shared<test::FakeBehavior>();
    behavior->frames = 60;
    behavior->probe = [](const std::string &path) -> media::Result<media::MediaInfo> {
        return test::makeFakeInfo(path, "mp4", media::fourcc::H264, false);
    };
    Rig rig(fakeRouter(behavior));
    const std::string media = _dir + "/short-video.mp4";
    std::ofstream(media) << "synthesised by the fake backend";
    const AssetId asset = rig.importPath(media);
    XCTAssertTrue(rig.error.empty(), @"%s", rig.error.c_str());
    rig.add(rig.v1, asset, 0, 90, kCMTimeZero);
    const auto problem = validateProject(rig.project);
    XCTAssertFalse(problem.has_value(), @"%s", problem ? problem->c_str() : "");
    const std::string path = _dir + "/p2.mp4";
    auto result = rig.run(rig.request(path, media::VideoCodec::H264, media::ContainerFormat::MP4, false, 576, 324));
    XCTAssertTrue(result.has_value(), @"%s", rig.error.c_str());
    if (!result) {
        return;
    }
    XCTAssertTrue(result->ok(), @"P2: %s", result->ok() ? "" : result->error().description().c_str());
    if (!result->ok()) {
        return;
    }
    XCTAssertEqual(result->value().frames, 90);
    for (int64_t f : {0, 30, 59, 60, 75, 89}) {
        auto frame = frameAt(*rig.router, path, CMTimeMake(f, 30));
        XCTAssertTrue(frame.has_value(), @"frame %lld", f);
        if (frame) {
            XCTAssertEqual(test::readBurnIn(frame->image.get()).value_or(-1), int(std::min<int64_t>(f, 59)),
                           @"frame %lld shows the source's frame %lld (the last one past its end)", f,
                           std::min<int64_t>(f, 59));
        }
    }
}

// P3: the audio decoder fails at 0.512 s (sample 24576, after opening fine). The export must fail
// and say which clip and when; before, the rest of the clip was written as silence and the export
// "succeeded". (The fake fails a read that starts at or after the sample; the source reads in
// 1024-frame chunks from 0, so 24576 is where the first failing read starts.)
- (void)testAudioReadErrorMidStreamFailsTheExport {
    auto behavior = std::make_shared<test::FakeBehavior>();
    behavior->frames = 90;
    behavior->failAudioAtSample = 24576;
    behavior->probe = [](const std::string &path) -> media::Result<media::MediaInfo> {
        return test::makeFakeInfo(path, "mp4", media::fourcc::H264, true);
    };
    Rig rig(fakeRouter(behavior));
    const std::string media = _dir + "/fake-av.mp4";
    std::ofstream(media) << "synthesised by the fake backend";
    const AssetId asset = rig.importPath(media);
    XCTAssertTrue(rig.error.empty(), @"%s", rig.error.c_str());
    rig.add(rig.v1, asset, 0, 60, kCMTimeZero);
    rig.add(rig.a1, asset, 0, 60, kCMTimeZero);
    const std::string path = _dir + "/p3.mp4";
    auto result = rig.run(rig.request(path, media::VideoCodec::H264, media::ContainerFormat::MP4, true, 288, 162));
    XCTAssertTrue(result.has_value(), @"%s", rig.error.c_str());
    if (!result) {
        return;
    }
    XCTAssertFalse(result->ok(), @"P3: audio that failed to decode was exported as silence");
    if (!result->ok()) {
        const std::string message = result->error().description();
        NSLog(@"EXPORT P3: %s", message.c_str());
        XCTAssertEqual(result->error().code, media::MediaErrorCode::DecodeFailed, @"%s", message.c_str());
        XCTAssertNotEqual(message.find("fake-av.mp4"), std::string::npos, @"names the clip's media: %s",
                          message.c_str());
        XCTAssertNotEqual(message.find("could not be decoded at 0.512 s"), std::string::npos, @"says when: %s",
                          message.c_str());
        XCTAssertNotEqual(message.find("on A1"), std::string::npos, @"says on which track: %s", message.c_str());
    }
    XCTAssertFalse(fileExists(path), @"no file is left");
}

@end
