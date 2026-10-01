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
#include "../../Engine/Media/Apple/AppleWriter.h"
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

/// A file URL that counts its security-scoped access (a test host is not sandboxed, so real file URLs
/// grant none), and lists its directory when the access ends.
@interface VECountingURL : NSURL
@property (nonatomic) int starts;
@property (nonatomic) int stops;
@property (nonatomic, copy, nullable) NSArray<NSString *> *directoryAtStop;
@end

@implementation VECountingURL
- (BOOL)startAccessingSecurityScopedResource {
    self.starts += 1;
    return YES;
}
- (void)stopAccessingSecurityScopedResource {
    self.stops += 1;
    self.directoryAtStop =
        [NSFileManager.defaultManager contentsOfDirectoryAtPath:self.URLByDeletingLastPathComponent.path error:nil];
}
@end

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

/// An export of `rig` with AAC (or PCM in a MOV) audio at `bitRate`; returns the refusal message, or nil
/// once the export finished (`result` set).
- (nullable NSString *)exportAudioOf:(ExporterRig &)rig
                                 pcm:(BOOL)pcm
                             bitRate:(NSInteger)bitRate
                                  to:(NSURL *)output
                              result:(std::optional<media::Result<exporting::ExportSummary>> *)result {
    VEExportSettings *settings =
        [[VEExportSettings alloc] initWithPreset:VEExportPresetH264
                                       container:pcm ? VEExportContainerMOV : VEExportContainerMP4
                                      resolution:VEExportResolution720p
                                     customWidth:0
                                     rateControl:VEExportRateControlQuality
                                         quality:0.5
                                    videoBitRate:8'000'000
                                      audioCodec:pcm ? VEExportAudioCodecPCM : VEExportAudioCodecAAC
                                    audioBitRate:bitRate];
    XCTAssertNil(settings.validationMessage);
    VEExporter *exporter = [[VEExporter alloc] init];
    auto report = std::make_shared<Report>();
    ExportRefusal refusal;
    VEExportHandle *handle = [self begin:exporter rig:rig settings:settings url:output report:report refusal:&refusal];
    if (handle == nil) {
        XCTAssertTrue(refusal.reason == ExportRefusalReason::Unsupported);
        XCTAssertFalse(exporter.isExporting);
        return refusal.message ?: @"";
    }
    XCTAssertTrue([self spinUntil:^BOOL { return report->finishCount > 0; } timeout:60]);
    *result = report->result;
    return nil;
}

/// The sequence's audio rate (8 to 192 kHz) and AAC (nit (b) of the 2026-09-30 fix round): Apple's AAC encoder
/// takes 22.05 to 48 kHz (lower rates at low bit rates only), FFmpeg's its standard rates up to 96 kHz, PCM
/// any rate. The writers say so in their validation (asked of the encoders), so the router writes what Apple
/// cannot through FFmpeg (96 kHz AAC failed with "AVAssetWriter cannot apply the h264 settings"), and a rate
/// no AAC encoder takes is refused before the export starts, saying what to do (192 kHz failed once the job
/// opened its writer, with the same misleading message).
- (void)testTheSequencesAudioRateIsWrittenOrRefusedWithTheReason {
    // The writers' validation, with the reason.
    media::EncodeSettings aac;
    aac.container = media::ContainerFormat::MP4;
    aac.audio = media::AudioEncodeSettings{};
    aac.audio->codec = media::AudioCodec::AAC;
    aac.audio->channels = 2;
    aac.audio->bitRate = 128'000;
    aac.audio->sampleRate = 48000;
    XCTAssertTrue(media::apple::AppleWriter::validate(aac).ok());
    aac.audio->sampleRate = 96000;
    media::Status apple = media::apple::AppleWriter::validate(aac);
    XCTAssertFalse(apple.ok());
    XCTAssertEqualObjects(apple.ok() ? @"" : @(apple.error().message.c_str()),
                          @"Apple's AAC encoder does not encode 2 channels at 96 kHz");
    XCTAssertTrue(media::ffmpeg::FFmpegBackend::validate(aac).ok(), @"FFmpeg's AAC encoder takes 96 kHz");
    aac.audio->sampleRate = 16000;
    apple = media::apple::AppleWriter::validate(aac);
    XCTAssertEqualObjects(apple.ok() ? @"" : @(apple.error().message.c_str()),
                          @"Apple's AAC encoder takes 24 to 96 kb/s at 16 kHz with 2 channels, not 128 kb/s");
    aac.audio->sampleRate = 192000;
    const media::Status ffmpeg = media::ffmpeg::FFmpegBackend::validate(aac);
    XCTAssertEqualObjects(ffmpeg.ok() ? @"" : @(ffmpeg.error().message.c_str()),
                          @"AAC is encoded at 96, 88.2, 64, 48, 44.1, 32, 24, 22.05, 16, 12, 11.025, 8 or 7.35 kHz, not "
                          @"192 kHz");

    std::string error;
    std::optional<media::Result<exporting::ExportSummary>> result;
    // 96 kHz AAC: written (through FFmpeg), at 96 kHz.
    {
        ExporterRig rig;
        XCTAssertTrue(rig.addClip([self mediaPath:"h264_1080p30.mp4"], 10, error), @"%s", error.c_str());
        rig.sequence().audioSampleRate = 96000;
        NSURL *output = [_scratch URLByAppendingPathComponent:@"aac-96k.mp4"];
        XCTAssertNil([self exportAudioOf:rig pcm:NO bitRate:128'000 to:output result:&result]);
        XCTAssertTrue(result && result->ok(), @"%s", result && !result->ok() ? result->error().description().c_str() : "");
        auto probed = rig.router->probe(output.path.UTF8String);
        XCTAssertTrue(probed.ok());
        if (probed.ok()) {
            const media::TrackInfo *track = nullptr;
            for (const media::TrackInfo &t : probed->info.tracks) {
                if (t.kind == media::TrackKind::Audio) {
                    track = &t;
                }
            }
            XCTAssertTrue(track != nullptr && track->sampleRate == 96000, @"the file's audio is 96 kHz");
        }
    }
    // 192 kHz and a rate that is no standard one: AAC refused before anything is written, PCM in a MOV written.
    for (const int rate : {192000, 37000}) {
        ExporterRig rig;
        XCTAssertTrue(rig.addClip([self mediaPath:"h264_1080p30.mp4"], 10, error), @"%s", error.c_str());
        rig.sequence().audioSampleRate = rate;
        NSURL *output = [_scratch URLByAppendingPathComponent:[NSString stringWithFormat:@"aac-%d.mp4", rate]];
        result.reset();
        NSString *refused = [self exportAudioOf:rig pcm:NO bitRate:128'000 to:output result:&result];
        XCTAssertEqualObjects(refused, ([NSString stringWithFormat:@"AAC audio cannot be written at %g kHz, the "
                                                                   @"sequence's audio rate. Choose PCM audio in a "
                                                                   @"QuickTime (MOV) file, or set the sequence's audio "
                                                                   @"to 48 kHz in Sequence Settings.",
                                                                   rate / 1000.0]));
        XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:output.path]);
        NSURL *pcmOutput = [_scratch URLByAppendingPathComponent:[NSString stringWithFormat:@"pcm-%d.mov", rate]];
        result.reset();
        XCTAssertNil([self exportAudioOf:rig pcm:YES bitRate:0 to:pcmOutput result:&result]);
        XCTAssertTrue(result && result->ok(), @"%d Hz PCM: %s", rate,
                      result && !result->ok() ? result->error().description().c_str() : "");
    }
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

/// A counting output URL in a fresh directory (so its listing shows only what the export leaves).
- (VECountingURL *)countingURLNamed:(NSString *)name {
    NSURL *directory = [_scratch URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:directory
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
    return [[VECountingURL alloc] initFileURLWithPath:[directory URLByAppendingPathComponent:name].path];
}

/// The output URL's security-scoped access starts once per export and ends once when it ends: after an
/// export that runs to its end, and after one cancelled through the exporter.
- (void)testTheOutputURLAccessEndsWithTheExport {
    ExporterRig rig;
    std::string error;
    XCTAssertTrue(rig.addClip([self mediaPath:"h264_1080p30.mp4"], 15, error), @"%s", error.c_str());
    VEExporter *exporter = [[VEExporter alloc] init];
    for (const bool cancel : {false, true}) {
        VECountingURL *output = [self countingURLNamed:cancel ? @"cancelled.mp4" : @"finished.mp4"];
        auto report = std::make_shared<Report>();
        ExportRefusal refusal;
        XCTAssertNotNil([self begin:exporter rig:rig settings:smallH264Settings() url:output report:report
                            refusal:&refusal],
                        @"%@", refusal.message);
        XCTAssertEqual(output.starts, 1);
        XCTAssertEqual(output.stops, 0, @"accessed while the export runs");
        if (cancel) {
            [exporter cancel];
        }
        XCTAssertTrue([self spinUntil:^BOOL { return report->finishCount > 0; } timeout:60]);
        XCTAssertEqual(output.starts, 1);
        XCTAssertEqual(output.stops, 1, @"%s: the access ended with the export", cancel ? "cancelled" : "finished");
    }
}

/// An exporter released while its export runs: dealloc cancels the job, which deletes its partial file on
/// its own queue and then completes; the completion ends the output URL's access although no exporter is
/// left (the access leaked for the process's life), after the partial file is gone.
- (void)testReleasingTheExporterMidExportEndsTheOutputURLAccess {
    ExporterRig rig;
    std::string error;
    XCTAssertTrue(rig.addClip([self mediaPath:"h264_1080p30.mp4"], 150, error), @"%s", error.c_str());
    auto report = std::make_shared<Report>();
    VECountingURL *output = [self countingURLNamed:@"released.mp4"];
    __weak VEExporter *weakExporter = nil;
    @autoreleasepool {
        VEExporter *exporter = [[VEExporter alloc] init];
        weakExporter = exporter;
        ExportRefusal refusal;
        XCTAssertNotNil([self begin:exporter rig:rig settings:smallH264Settings() url:output report:report
                            refusal:&refusal],
                        @"%@", refusal.message);
    }
    XCTAssertNil(weakExporter);
    XCTAssertTrue([self spinUntil:^BOOL { return report->finishCount > 0; } timeout:60]);
    XCTAssertFalse(report->endedRunningExport, @"no exporter was left to end it");
    XCTAssertEqual(output.starts, 1);
    XCTAssertEqual(output.stops, 1, @"the access ended although the exporter was gone");
    XCTAssertNotNil(output.directoryAtStop);
    XCTAssertEqual(output.directoryAtStop.count, 0u, @"the partial file was deleted before the access ended: %@",
                   output.directoryAtStop);
}

@end
