// The export API of the facade (VEEngine "Export", VEExport.h): presets and sizes, format
// availability against VideoToolbox, the size estimate, an export of an imported sequence through
// -beginExportWithSettings:... checked with the FFmpeg prober (a second, independent reader) and
// the Apple decoders, paced progress notifications, refusals before any file exists (gesture,
// another export, invalid settings, empty sequence, missing media, unwritable output), cancel
// through the handle, and playback pausing when an export starts.

#import <VidEditEngine/VidEditEngine.h>
#import <XCTest/XCTest.h>

#include "../../Engine/Media/BackendRouter.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../Media/BurnIn.h"
#include "../Media/TestMedia.h"
#include "../Media/VideoToolboxProbe.h"

#include <chrono>
#include <string>
#include <vector>

namespace {

/// Monotonic seconds (the tests' own clock for pacing and latency).
double nowSeconds() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

CMTime seconds(double s) {
    return CMTimeMakeWithSeconds(s, 600);
}

} // namespace

@interface VEEngineExportTests : XCTestCase
@end

@implementation VEEngineExportTests {
    NSURL *_scratch;
}

- (void)setUp {
    _scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
}

- (VEEngine *)makeEngine {
    return [[VEEngine alloc] initWithCacheDirectory:[_scratch URLByAppendingPathComponent:@"Caches"]];
}

- (NSURL *)mediaURL:(const char *)file {
    std::string error;
    const std::string path = ve::test::testMediaPath(file, error);
    XCTAssertTrue(error.empty(), @"%s", error.c_str());
    return [NSURL fileURLWithPath:@(path.c_str())];
}

- (VEAssetInfo *)importURL:(NSURL *)url into:(VEEngine *)engine {
    XCTestExpectation *done = [self expectationWithDescription:@"import"];
    __block VEAssetInfo *asset = nil;
    [engine importMediaAtURLs:@[ url ]
                   completion:^(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors) {
                       XCTAssertEqual(errors.count, 0u, @"%@", errors);
                       asset = assets.firstObject;
                       [done fulfill];
                   }];
    [self waitForExpectations:@[ done ] timeout:60];
    XCTAssertNotNil(asset);
    return asset;
}

/// A [0, 2 s) from source 0, B [2 s, 5 s) from source 5 s, 10-frame dissolve; linked audio on A1.
- (void)buildSequence:(VEEngine *)engine asset:(VEAssetInfo *)asset {
    const VETrackID v1 = engine.sequence.videoTrackIDs[0].longLongValue;
    const VETrackID a1 = engine.sequence.audioTrackIDs[0].longLongValue;
    VEEditResult *a = [engine overwriteAsset:asset.assetID
                                      atTime:kCMTimeZero
                                  videoTrack:v1
                                  audioTrack:a1
                                    sourceIn:kCMTimeZero
                                   sourceOut:seconds(2)];
    VEEditResult *b = [engine overwriteAsset:asset.assetID
                                      atTime:seconds(2)
                                  videoTrack:v1
                                  audioTrack:a1
                                    sourceIn:seconds(5)
                                   sourceOut:seconds(8)];
    XCTAssertTrue(a.ok && b.ok, @"%@ %@", a.message, b.message);
    VEEditResult *t = [engine addTransitionFromClip:a.createdIDs[0].longLongValue
                                             toClip:b.createdIDs[0].longLongValue
                                           duration:CMTimeMake(10, 30)];
    XCTAssertTrue(t.ok, @"%@", t.message);
}

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return condition();
}

- (VEExportSettings *)settingsFor:(VEExportPreset)preset resolution:(VEExportResolution)resolution {
    VEExportSettings *d = [VEExportSettings defaultSettingsForPreset:preset];
    return [[VEExportSettings alloc] initWithPreset:preset
                                          container:d.container
                                         resolution:resolution
                                        customWidth:d.customWidth
                                        rateControl:d.rateControl
                                            quality:d.quality
                                       videoBitRate:d.videoBitRate
                                         audioCodec:d.audioCodec
                                       audioBitRate:d.audioBitRate];
}

// MARK: - Settings and formats

- (void)testPresetsSizesAndValidation {
    VEExportSettings *h264 = [VEExportSettings defaultSettingsForPreset:VEExportPresetH264];
    XCTAssertEqual(h264.container, VEExportContainerMP4);
    XCTAssertEqual(h264.audioCodec, VEExportAudioCodecAAC);
    XCTAssertEqualObjects(h264.fileExtension, @"mp4");
    XCTAssertNil(h264.validationMessage);
    XCTAssertEqual([VEExportSettings defaultSettingsForPreset:VEExportPresetProRes422].container, VEExportContainerMOV);
    XCTAssertEqual([VEExportSettings defaultSettingsForPreset:VEExportPresetProRes422].audioCodec, VEExportAudioCodecPCM);
    XCTAssertEqualObjects([VEExportSettings containersForPreset:VEExportPresetAV1],
                          (@[ @(VEExportContainerMP4), @(VEExportContainerMKV) ]));

    // Sizes keep the sequence's aspect, with even sides.
    CGSize s = [[self settingsFor:VEExportPresetH264 resolution:VEExportResolution720p] outputSizeForSequenceWidth:1920
                                                                                                           height:1080];
    XCTAssertEqual(s.width, 1280);
    XCTAssertEqual(s.height, 720);
    s = [[self settingsFor:VEExportPresetH264 resolution:VEExportResolution1080p] outputSizeForSequenceWidth:1080
                                                                                                      height:1920];
    XCTAssertEqual(s.width, 608); // 1080 * 9/16 = 607.5 -> nearest even
    XCTAssertEqual(s.height, 1080);
    VEExportSettings *custom = [[VEExportSettings alloc] initWithPreset:VEExportPresetHEVC
                                                              container:VEExportContainerMOV
                                                             resolution:VEExportResolutionCustom
                                                            customWidth:1001
                                                            rateControl:VEExportRateControlBitRate
                                                                quality:0.5
                                                           videoBitRate:8'000'000
                                                             audioCodec:VEExportAudioCodecPCM
                                                           audioBitRate:256'000];
    s = [custom outputSizeForSequenceWidth:1920 height:1080];
    XCTAssertEqual(s.width, 1000);
    XCTAssertEqual(s.height, 562); // 1000 * 9/16 = 562.5 -> even
    XCTAssertNil(custom.validationMessage);

    // Invalid combinations say why.
    VEExportSettings *proresMP4 = [[VEExportSettings alloc] initWithPreset:VEExportPresetProRes422
                                                                 container:VEExportContainerMP4
                                                                resolution:VEExportResolutionSequence
                                                               customWidth:0
                                                               rateControl:VEExportRateControlQuality
                                                                   quality:0.7
                                                              videoBitRate:0
                                                                audioCodec:VEExportAudioCodecPCM
                                                              audioBitRate:0];
    XCTAssertTrue([proresMP4.validationMessage containsString:@"QuickTime (MOV)"], @"%@", proresMP4.validationMessage);
    VEExportSettings *pcmMP4 = [[VEExportSettings alloc] initWithPreset:VEExportPresetH264
                                                              container:VEExportContainerMP4
                                                             resolution:VEExportResolutionSequence
                                                            customWidth:0
                                                            rateControl:VEExportRateControlQuality
                                                                quality:0.7
                                                           videoBitRate:0
                                                             audioCodec:VEExportAudioCodecPCM
                                                           audioBitRate:0];
    XCTAssertTrue([pcmMP4.validationMessage containsString:@"PCM"], @"%@", pcmMP4.validationMessage);
    XCTAssertEqualObjects(h264, [h264 copy]);
}

- (void)testFormatsMatchVideoToolboxAndTheEstimateScales {
    VEEngine *engine = [self makeEngine];
    NSArray<VEExportFormat *> *formats = [engine exportFormatsForWidth:1920 height:1080];
    XCTAssertEqual(formats.count, 5u);
    const CMVideoCodecType types[] = {kCMVideoCodecType_H264, kCMVideoCodecType_HEVC, kCMVideoCodecType_HEVC,
                                      kCMVideoCodecType_AppleProRes422};
    for (VEExportFormat *format in formats) {
        NSLog(@"EXPORT format %@", format);
        if (format.preset == VEExportPresetAV1) {
            XCTAssertFalse(format.hardware);
            continue;
        }
        XCTAssertEqual(format.hardware,
                       ve::test::videoToolboxEncodesInHardware(types[format.preset], 1920, 1080) &&
                           (format.preset != VEExportPresetHEVC10Bit || format.available),
                       @"%@", format.name);
    }
    XCTAssertTrue(formats[VEExportPresetH264].available);

    XCTestExpectation *async = [self expectationWithDescription:@"formats"];
    [engine exportFormatsForWidth:1280
                           height:720
                       completion:^(NSArray<VEExportFormat *> *list) {
                           XCTAssertTrue(NSThread.isMainThread);
                           XCTAssertEqual(list.count, 5u);
                           XCTAssertEqual(list.firstObject.width, 1280);
                           [async fulfill];
                       }];
    [self waitForExpectations:@[ async ] timeout:10];

    // Empty sequence: nothing to estimate. With 5 s of media: grows with the bit rate.
    VEExportSettings *h264 = [VEExportSettings defaultSettingsForPreset:VEExportPresetH264];
    XCTAssertEqual([engine estimatedFileSizeForSettings:h264], 0);
    VEAssetInfo *asset = [self importURL:[self mediaURL:"h264_1080p30.mp4"] into:engine];
    [self buildSequence:engine asset:asset];
    VEExportSettings *rate10 = [[VEExportSettings alloc] initWithPreset:VEExportPresetH264
                                                              container:VEExportContainerMP4
                                                             resolution:VEExportResolutionSequence
                                                            customWidth:0
                                                            rateControl:VEExportRateControlBitRate
                                                                quality:0.7
                                                           videoBitRate:10'000'000
                                                             audioCodec:VEExportAudioCodecAAC
                                                           audioBitRate:256'000];
    const int64_t bytes = [engine estimatedFileSizeForSettings:rate10];
    // (10 Mb/s + 256 kb/s) x 5 s / 8 = 6.41 MB, plus about 1 %.
    XCTAssertEqualWithAccuracy(double(bytes), 6.41e6 * 1.01, 0.1e6);
    XCTAssertGreaterThan([engine estimatedFileSizeForSettings:h264], 0);
}

// MARK: - Export

- (void)testExportThroughTheFacadeProducesAPlayableFile {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importURL:[self mediaURL:"h264_1080p30.mp4"] into:engine];
    [self buildSequence:engine asset:asset];
    VEExportSettings *settings = [self settingsFor:VEExportPresetH264 resolution:VEExportResolution720p];
    CGSize size = [engine exportSizeForSettings:settings];
    XCTAssertEqual(size.width, 1280);
    NSURL *url = [_scratch URLByAppendingPathComponent:@"facade.mp4"];

    [engine play];
    __block NSMutableArray<NSNumber *> *progressTimes = [NSMutableArray array];
    id token = [NSNotificationCenter.defaultCenter addObserverForName:VEEngineExportDidProgressNotification
                                                               object:engine
                                                                queue:nil
                                                           usingBlock:^(NSNotification *note) {
                                                               XCTAssertTrue([note.userInfo[VEEngineExportProgressKey]
                                                                   isKindOfClass:[VEExportProgress class]]);
                                                               [progressTimes addObject:@(nowSeconds())];
                                                           }];
    __block VEExportSummary *summary = nil;
    __block NSError *failure = nil;
    __block BOOL completed = NO;
    __block int progressCalls = 0;
    NSError *error = nil;
    VEExportHandle *handle = [engine beginExportWithSettings:settings
        outputURL:url
        progress:^(VEExportProgress *progress) {
            XCTAssertTrue(NSThread.isMainThread);
            XCTAssertLessThanOrEqual(progress.fractionCompleted, 1.0);
            ++progressCalls;
        }
        completion:^(VEExportSummary *s, NSError *e) {
            XCTAssertTrue(NSThread.isMainThread);
            summary = s;
            failure = e;
            completed = YES;
        }
        error:&error];
    XCTAssertNotNil(handle, @"%@", error);
    XCTAssertTrue(engine.isExporting);
    XCTAssertEqual(engine.activeExport, handle);
    XCTAssertNotEqual(engine.playbackState, VEPlaybackStatePlaying, @"playback paused for the export");
    NSError *busy = nil;
    XCTAssertNil([engine beginExportWithSettings:settings
                                       outputURL:[_scratch URLByAppendingPathComponent:@"second.mp4"]
                                        progress:nil
                                      completion:^(VEExportSummary *, NSError *) {
                                          XCTFail(@"a refused export never completes");
                                      }
                                           error:&busy]);
    XCTAssertEqual(busy.code, VEEngineErrorBusy);

    XCTAssertTrue([self spinUntil:^BOOL { return completed; } timeout:120]);
    [NSNotificationCenter.defaultCenter removeObserver:token];
    XCTAssertNil(failure, @"%@", failure);
    XCTAssertNotNil(summary);
    XCTAssertFalse(engine.isExporting);
    XCTAssertTrue(handle.isFinished);
    XCTAssertEqual(summary.frameCount, 150);
    XCTAssertEqual(summary.width, 1280);
    XCTAssertEqual(summary.height, 720);
    XCTAssertEqual(CMTimeCompare(summary.duration, CMTimeMake(5, 1)), 0);
    XCTAssertEqual(summary.hardwareAccelerated, ve::test::videoToolboxEncodesInHardware(kCMVideoCodecType_H264, 1280, 720));
    XCTAssertEqualObjects(summary.backendName, @"apple");
    XCTAssertGreaterThan(summary.fileSize, 0u);
    NSLog(@"EXPORT facade: %@ %.1f fps, %llu bytes", summary.encoderName, summary.averageFramesPerSecond,
          summary.fileSize);
    for (NSUInteger i = 1; i < progressTimes.count; ++i) {
        XCTAssertGreaterThanOrEqual(progressTimes[i].doubleValue - progressTimes[i - 1].doubleValue, 0.095);
    }
    XCTAssertEqual(NSUInteger(progressCalls), progressTimes.count);

    // An independent reader (FFmpeg's demuxer and decoders) sees a complete, playable file.
    ve::media::ffmpeg::FFmpegBackend ffmpeg;
    const std::string path = url.path.fileSystemRepresentation;
    auto probed = ffmpeg.makeProber()->probe(path);
    XCTAssertTrue(probed.ok(), @"%s", probed.ok() ? "" : probed.error().description().c_str());
    if (!probed.ok()) {
        return;
    }
    const ve::media::TrackInfo *video = probed->firstTrack(ve::media::TrackKind::Video);
    const ve::media::TrackInfo *audio = probed->firstTrack(ve::media::TrackKind::Audio);
    XCTAssertTrue(video && audio);
    if (!video || !audio) {
        return;
    }
    XCTAssertEqual(video->codec.fourCC, ve::media::fourcc::H264);
    XCTAssertEqual(video->width, 1280);
    XCTAssertEqual(video->height, 720);
    XCTAssertEqual(audio->codec.fourCC, ve::media::fourcc::AAC);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds(probed->duration), 5.0, 0.001);
    auto decoder = ffmpeg.makeVideoDecoder();
    XCTAssertTrue(decoder->open(path, video->index, {}).ok());
    XCTAssertTrue(decoder->seek(CMTimeMake(10, 30)).ok());
    auto frame = decoder->next();
    XCTAssertTrue(frame.ok() && frame.value());
    if (frame.ok() && frame.value()) {
        XCTAssertEqual(ve::test::readBurnIn(frame.value()->image.get()).value_or(-1), 10);
    }
}

- (void)testRefusalsCreateNoFile {
    VEEngine *engine = [self makeEngine];
    VEExportSettings *settings = [VEExportSettings defaultSettingsForPreset:VEExportPresetH264];
    NSURL *url = [_scratch URLByAppendingPathComponent:@"refused.mp4"];
    void (^never)(VEExportSummary *, NSError *) = ^(VEExportSummary *, NSError *) {
        XCTFail(@"a refused export never completes");
    };
    NSError *error = nil;
    // Empty sequence.
    XCTAssertNil([engine beginExportWithSettings:settings outputURL:url progress:nil completion:never error:&error]);
    XCTAssertEqual(error.code, VEEngineErrorExportUnsupported, @"%@", error);

    // Media that went missing after the import.
    NSURL *copy = [_scratch URLByAppendingPathComponent:@"to-be-deleted.mp4"];
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:[self mediaURL:"h264_1080p30.mp4"] toURL:copy error:nil]);
    VEAssetInfo *asset = [self importURL:copy into:engine];
    [self buildSequence:engine asset:asset];
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:copy error:nil]);
    error = nil;
    XCTAssertNil([engine beginExportWithSettings:settings outputURL:url progress:nil completion:never error:&error]);
    XCTAssertEqual(error.code, VEEngineErrorMissingMedia, @"%@", error);
    XCTAssertTrue([error.localizedDescription containsString:@"to-be-deleted.mp4"], @"%@", error.localizedDescription);
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:[self mediaURL:"h264_1080p30.mp4"] toURL:copy error:nil]);

    // A gesture in progress.
    [engine beginCoalescingWithKey:@"drag"];
    error = nil;
    XCTAssertNil([engine beginExportWithSettings:settings outputURL:url progress:nil completion:never error:&error]);
    XCTAssertEqual(error.code, VEEngineErrorBusy, @"%@", error);
    [engine cancelCoalescing];

    // Invalid settings, an unwritable location.
    VEExportSettings *proresMP4 = [[VEExportSettings alloc] initWithPreset:VEExportPresetProRes422
                                                                 container:VEExportContainerMP4
                                                                resolution:VEExportResolutionSequence
                                                               customWidth:0
                                                               rateControl:VEExportRateControlQuality
                                                                   quality:0.7
                                                              videoBitRate:0
                                                                audioCodec:VEExportAudioCodecNone
                                                              audioBitRate:0];
    error = nil;
    XCTAssertNil([engine beginExportWithSettings:proresMP4 outputURL:url progress:nil completion:never error:&error]);
    XCTAssertEqual(error.code, VEEngineErrorExportUnsupported, @"%@", error);
    error = nil;
    NSURL *nowhere = [_scratch URLByAppendingPathComponent:@"missing-folder/out.mp4"];
    XCTAssertNil([engine beginExportWithSettings:settings outputURL:nowhere progress:nil completion:never error:&error]);
    XCTAssertEqual(error.code, VEEngineErrorOutputNotWritable, @"%@", error);

    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:url.path]);
    XCTAssertFalse(engine.isExporting);
    // Give any (wrongly) scheduled completion a chance to run.
    [self spinUntil:^BOOL { return NO; } timeout:0.3];
}

- (void)testCancelThroughTheHandle {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importURL:[self mediaURL:"h264_1080p30.mp4"] into:engine];
    [self buildSequence:engine asset:asset];
    NSURL *url = [_scratch URLByAppendingPathComponent:@"cancel.mov"];
    VEExportSettings *settings = [VEExportSettings defaultSettingsForPreset:VEExportPresetHEVC];
    __block NSError *failure = nil;
    __block BOOL completed = NO;
    __block BOOL finishNotified = NO;
    id token = [NSNotificationCenter.defaultCenter addObserverForName:VEEngineExportDidFinishNotification
                                                               object:engine
                                                                queue:nil
                                                           usingBlock:^(NSNotification *note) {
                                                               XCTAssertNotNil(note.userInfo[VEEngineExportErrorKey]);
                                                               finishNotified = YES;
                                                           }];
    NSError *error = nil;
    VEExportHandle *handle = [engine beginExportWithSettings:settings
                                                   outputURL:url
                                                    progress:nil
                                                  completion:^(VEExportSummary *s, NSError *e) {
                                                      XCTAssertNil(s);
                                                      failure = e;
                                                      completed = YES;
                                                  }
                                                       error:&error];
    XCTAssertNotNil(handle, @"%@", error);
    const double cancelledAt = nowSeconds();
    XCTAssertTrue([handle cancelAndWaitWithTimeout:1.0], @"ended within a second");
    XCTAssertLessThan(nowSeconds() - cancelledAt, 0.5);
    XCTAssertTrue(handle.isFinished);
    XCTAssertTrue([self spinUntil:^BOOL { return completed; } timeout:5]);
    [NSNotificationCenter.defaultCenter removeObserver:token];
    XCTAssertEqual(failure.code, VEEngineErrorExportCancelled, @"%@", failure);
    XCTAssertTrue(finishNotified);
    XCTAssertFalse([NSFileManager.defaultManager fileExistsAtPath:url.path]);
    XCTAssertFalse(engine.isExporting);
}

@end
