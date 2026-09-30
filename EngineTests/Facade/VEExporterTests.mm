// VEExporter on its own, constructed without an engine: the refusals before any file exists (a URL
// that is not a file URL, invalid settings, an empty sequence, missing media, a second export while
// one runs), an export that runs to its end (the handle while it runs, the progress and finish
// blocks on the main thread, the running export cleared before finish runs), cancel through the
// exporter, and an exporter released while its export runs (the export is cancelled and finish
// still runs once, reporting that no exporter was left to end it).

// The class's facade-private header comes first and alone: it must compile without the engine's
// headers (the test imports no FramewrightEngine umbrella, which would bring in VEEngine.h).
#import "../../Engine/Facade/VEExporter+Internal.h"

#import <XCTest/XCTest.h>

#include "../../Engine/Media/AssetImport.h"
#include "../../Engine/Media/BackendRouter.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Media/FrameCache.h"
#include "../Media/TestMedia.h"

#include <memory>
#include <optional>
#include <string>

using namespace ve;
using namespace ve::facade;

namespace {

/// A 1920x1080 30 fps project with one video track and one audio track, and the services to
/// export it (the engine's router setup: Apple first, FFmpeg as the fallback).
struct ExporterRig {
    std::shared_ptr<media::BackendRouter> router = media::BackendRouter::makeDefault();
    std::shared_ptr<media::FrameCache> cache = std::make_shared<media::FrameCache>();
    std::map<AssetId, media::RoutedMediaInfo> routing;
    Project project;

    ExporterRig() {
        (void)router->registerBackend(media::ffmpeg::makeFFmpegBackend());
        project.name = "Exporter";
        project.activeSequenceId = project.addSequence("Main", CMTimeMake(1, 30), 1920, 1080, 1, 1);
    }

    Sequence &sequence() { return *project.activeSequence(); }

    /// Adds the asset at `path` (probed like an import) and a video clip of `frames` frames from
    /// its start at time 0. Returns the asset's id (invalid on failure, with `error` set).
    AssetId addClip(const std::string &path, int frames, std::string &error) {
        auto routed = router->probe(path);
        if (!routed.ok()) {
            error = routed.error().description();
            return AssetId{};
        }
        const AssetId id = project.ids.make<AssetId>();
        auto asset = media::makeMediaAsset(*routed, id);
        if (!asset.ok()) {
            error = asset.error().description();
            return AssetId{};
        }
        project.assets.push_back(*asset);
        routing[id] = *routed;
        Clip clip;
        clip.id = project.ids.make<ClipId>();
        clip.assetId = id;
        clip.trackId = sequence().videoTracks[0].id;
        clip.timelineStart = kCMTimeZero;
        clip.timelineDuration = CMTimeMake(frames, 30);
        clip.sourceIn = kCMTimeZero;
        Track &track = sequence().videoTracks[0];
        track.clips.push_back(clip);
        track.sortClips();
        return id;
    }

    exporting::ExportServices services() const {
        exporting::ExportServices s;
        s.router = router;
        s.cache = cache;
        s.epoch = cache->epoch();
        s.routing = routing;
        return s;
    }
};

/// H.264 at 720p without audio (fast), or with `container` for a combination the settings refuse.
VEExportSettings *smallH264Settings(VEExportContainer container = VEExportContainerMP4) {
    return [[VEExportSettings alloc] initWithPreset:VEExportPresetH264
                                          container:container
                                         resolution:VEExportResolution720p
                                        customWidth:0
                                        rateControl:VEExportRateControlQuality
                                            quality:0.5
                                       videoBitRate:8'000'000
                                         audioCodec:VEExportAudioCodecNone
                                       audioBitRate:0];
}

/// Default options, except that progress is delivered as often as the main queue takes it (a short
/// export can end before the default 0.1 s interval has passed once; a delivery that finds the job
/// finished is dropped).
exporting::ExportOptions progressOnEveryFrame() {
    exporting::ExportOptions options;
    options.progressInterval = 0;
    return options;
}

/// What a started export reported through its blocks.
struct Report {
    int progressCount = 0;
    bool progressOnMain = true;
    int finishCount = 0;
    bool finishOnMain = false;
    std::optional<media::Result<exporting::ExportSummary>> result;
    BOOL endedRunningExport = NO;
    BOOL exportingDuringFinish = YES;
};

} // namespace

@interface VEExporterTests : XCTestCase
@end

@implementation VEExporterTests {
    NSURL *_scratch;
}

- (void)setUp {
    _scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
}

- (std::string)mediaPath:(const char *)file {
    std::string error;
    const std::string path = ve::test::testMediaPath(file, error);
    XCTAssertTrue(error.empty(), @"%s", error.c_str());
    return path;
}

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return condition();
}

/// Starts an export of `rig`'s project with blocks that record into `report`.
- (nullable VEExportHandle *)begin:(VEExporter *)exporter
                               rig:(const ExporterRig &)rig
                          settings:(VEExportSettings *)settings
                               url:(NSURL *)url
                            report:(std::shared_ptr<Report>)report
                           refusal:(ExportRefusal *)refusal {
    __weak VEExporter *weakExporter = exporter;
    return [exporter beginExportOfProject:rig.project
        settings:settings
        outputURL:url
        services:rig.services()
        options:progressOnEveryFrame()
        progress:^(VEExportProgress *progress) {
          XCTAssertNotNil(progress);
          report->progressCount += 1;
          report->progressOnMain = report->progressOnMain && NSThread.isMainThread;
        }
        finish:^(const media::Result<exporting::ExportSummary> &result, BOOL endedRunningExport) {
          report->finishCount += 1;
          report->finishOnMain = NSThread.isMainThread;
          report->result = result;
          report->endedRunningExport = endedRunningExport;
          report->exportingDuringFinish = weakExporter.isExporting;
        }
        refusal:refusal];
}

- (void)testRefusalsCreateNoFileAndLeaveNoRunningExport {
    ExporterRig rig;
    std::string error;
    XCTAssertTrue(rig.addClip([self mediaPath:"h264_1080p30.mp4"], 30, error), @"%s", error.c_str());
    VEExporter *exporter = [[VEExporter alloc] init];
    auto report = std::make_shared<Report>();
    NSURL *output = [_scratch URLByAppendingPathComponent:@"refused.mp4"];

    ExportRefusal refusal;
    XCTAssertNil([self begin:exporter
                         rig:rig
                    settings:smallH264Settings()
                         url:[NSURL URLWithString:@"https://example.com/out.mp4"]
                      report:report
                     refusal:&refusal]);
    XCTAssertTrue(refusal.reason == ExportRefusalReason::OutputNotWritable);
    XCTAssertEqualObjects(refusal.message, @"The export needs a file location.");

    // MKV is for AV1 only: the settings' own validation message.
    VEExportSettings *mkv = smallH264Settings(VEExportContainerMKV);
    XCTAssertNotNil(mkv.validationMessage);
    refusal = ExportRefusal{};
    XCTAssertNil([self begin:exporter rig:rig settings:mkv url:output report:report refusal:&refusal]);
    XCTAssertTrue(refusal.reason == ExportRefusalReason::Unsupported);
    XCTAssertEqualObjects(refusal.message, mkv.validationMessage);

    // ExportJob::start's refusals: an empty sequence, and media that is not there.
    ExporterRig empty;
    refusal = ExportRefusal{};
    XCTAssertNil([self begin:exporter rig:empty settings:smallH264Settings() url:output report:report refusal:&refusal]);
    XCTAssertTrue(refusal.reason == ExportRefusalReason::Unsupported);
    XCTAssertGreaterThan(refusal.message.length, 0u);

    ExporterRig missing;
    const std::string moved = std::string(_scratch.path.fileSystemRepresentation) + "/moved.mp4";
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtPath:@([self mediaPath:"h264_1080p30.mp4"].c_str())
                                                        toPath:@(moved.c_str())
                                                         error:nil]);
    XCTAssertTrue(missing.addClip(moved, 30, error), @"%s", error.c_str());
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtPath:@(moved.c_str()) error:nil]);
    refusal = ExportRefusal{};
    XCTAssertNil([self begin:exporter rig:missing settings:smallH264Settings() url:output report:report refusal:&refusal]);
    XCTAssertTrue(refusal.reason == ExportRefusalReason::MissingMedia, @"%@", refusal.message);

    XCTAssertFalse(exporter.isExporting);
    XCTAssertNil(exporter.activeExport);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:output.path]);
    XCTAssertEqual(report->finishCount, 0);
}

- (void)testAnExportRunsToItsEndAndClearsTheRunningExportBeforeFinish {
    ExporterRig rig;
    std::string error;
    XCTAssertTrue(rig.addClip([self mediaPath:"h264_1080p30.mp4"], 300, error), @"%s", error.c_str());
    VEExporter *exporter = [[VEExporter alloc] init];
    auto report = std::make_shared<Report>();
    NSURL *output = [_scratch URLByAppendingPathComponent:@"exported.mp4"];

    ExportRefusal refusal;
    VEExportHandle *handle = [self begin:exporter
                                     rig:rig
                                settings:smallH264Settings()
                                     url:output
                                  report:report
                                 refusal:&refusal];
    XCTAssertNotNil(handle, @"%@", refusal.message);
    XCTAssertTrue(exporter.isExporting);
    XCTAssertEqual(exporter.activeExport, handle);
    XCTAssertEqualObjects(handle.outputURL, output);

    // One export at a time: a second start is refused and the first keeps running.
    auto second = std::make_shared<Report>();
    refusal = ExportRefusal{};
    XCTAssertNil([self begin:exporter
                         rig:rig
                    settings:smallH264Settings()
                         url:[_scratch URLByAppendingPathComponent:@"second.mp4"]
                      report:second
                     refusal:&refusal]);
    XCTAssertTrue(refusal.reason == ExportRefusalReason::Busy);
    XCTAssertEqualObjects(refusal.message, @"An export is already running.");
    XCTAssertEqual(exporter.activeExport, handle);

    XCTAssertTrue([self spinUntil:^BOOL { return report->finishCount > 0; } timeout:120]);
    XCTAssertEqual(report->finishCount, 1);
    XCTAssertTrue(report->finishOnMain);
    XCTAssertTrue(report->progressOnMain);
    XCTAssertGreaterThan(report->progressCount, 0);
    XCTAssertTrue(report->result && report->result->ok(),
                  @"%s", report->result && !report->result->ok() ? report->result->error().description().c_str() : "");
    XCTAssertTrue(report->endedRunningExport);
    XCTAssertFalse(report->exportingDuringFinish);
    XCTAssertFalse(exporter.isExporting);
    XCTAssertNil(exporter.activeExport);
    if (report->result && report->result->ok()) {
        XCTAssertEqual(report->result->value().frames, 300);
    }
    XCTAssertTrue([NSFileManager.defaultManager fileExistsAtPath:output.path]);
    XCTAssertEqual(second->finishCount, 0);

    // Idle again: the next export starts.
    auto third = std::make_shared<Report>();
    VEExportHandle *next = [self begin:exporter
                                   rig:rig
                              settings:smallH264Settings()
                                   url:[_scratch URLByAppendingPathComponent:@"next.mp4"]
                                report:third
                               refusal:&refusal];
    XCTAssertNotNil(next, @"%@", refusal.message);
    [exporter cancel];
    XCTAssertTrue([self spinUntil:^BOOL { return third->finishCount > 0; } timeout:60]);
}

- (void)testCancelEndsTheRunningExportWithoutAFile {
    ExporterRig rig;
    std::string error;
    XCTAssertTrue(rig.addClip([self mediaPath:"h264_1080p30.mp4"], 150, error), @"%s", error.c_str());
    VEExporter *exporter = [[VEExporter alloc] init];
    auto report = std::make_shared<Report>();
    NSURL *output = [_scratch URLByAppendingPathComponent:@"cancelled.mp4"];
    ExportRefusal refusal;
    XCTAssertNotNil([self begin:exporter rig:rig settings:smallH264Settings() url:output report:report refusal:&refusal],
                    @"%@", refusal.message);
    [exporter cancel];
    XCTAssertTrue(exporter.isExporting, @"cancel does not block: the export ends through its finish block");
    XCTAssertTrue([self spinUntil:^BOOL { return report->finishCount > 0; } timeout:60]);
    XCTAssertEqual(report->finishCount, 1);
    XCTAssertTrue(report->result && !report->result->ok());
    if (report->result && !report->result->ok()) {
        XCTAssertTrue(report->result->error().code == media::MediaErrorCode::Cancelled);
    }
    XCTAssertTrue(report->endedRunningExport);
    XCTAssertFalse(exporter.isExporting);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:output.path]);
}

- (void)testReleasingTheExporterCancelsItsExport {
    ExporterRig rig;
    std::string error;
    XCTAssertTrue(rig.addClip([self mediaPath:"h264_1080p30.mp4"], 150, error), @"%s", error.c_str());
    auto report = std::make_shared<Report>();
    NSURL *output = [_scratch URLByAppendingPathComponent:@"released.mp4"];
    __weak VEExporter *weakExporter = nil;
    @autoreleasepool {
        VEExporter *exporter = [[VEExporter alloc] init];
        weakExporter = exporter;
        ExportRefusal refusal;
        XCTAssertNotNil([self begin:exporter rig:rig settings:smallH264Settings() url:output report:report refusal:&refusal],
                        @"%@", refusal.message);
    }
    XCTAssertNil(weakExporter);
    XCTAssertTrue([self spinUntil:^BOOL { return report->finishCount > 0; } timeout:60]);
    XCTAssertEqual(report->finishCount, 1);
    XCTAssertTrue(report->result && !report->result->ok());
    if (report->result && !report->result->ok()) {
        XCTAssertTrue(report->result->error().code == media::MediaErrorCode::Cancelled);
    }
    XCTAssertFalse(report->endedRunningExport);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:output.path]);
}

@end
