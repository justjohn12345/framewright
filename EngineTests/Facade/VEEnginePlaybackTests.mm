// VEEngine playback and monitor wiring: the program monitor driven by the playback controller
// (play, pause, seek, JKL, scrub, stats, notifications, control-call latency) and the source
// monitor, checked on the burn-in media through a real VEPreviewView; plus the facade's other
// review fixes that need the new API (main-thread enforcement, edit results, ripple scope,
// exact speeds, load warnings, memory pressure, use counts).

#import <Metal/Metal.h>
#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#include "../Media/BurnIn.h"
#include "../Media/FFmpegTestMedia.h"
#include "../Media/TestMedia.h"

#include <algorithm>
#include <ctime>
#include <cmath>
#include <functional>
#include <map>
#include <set>
#include <string>
#include <vector>

namespace {

CMTime seconds(double s) {
    return CMTimeMakeWithSeconds(s, 600);
}

int64_t frameOf(CMTime t) {
    return static_cast<int64_t>(std::floor(CMTimeGetSeconds(t) * 30.0 + 1e-6));
}

/// Reads the burn-in frame index of what `view` shows (-1 if unreadable, e.g. mid-dissolve).
int shownIndex(VEPreviewView *view) {
    CGImageRef image = [view snapshot];
    if (image == NULL) {
        return -1;
    }
    const size_t w = CGImageGetWidth(image);
    const size_t h = CGImageGetHeight(image);
    CVPixelBufferRef buffer = nullptr;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nullptr, &buffer) !=
        kCVReturnSuccess) {
        return -1;
    }
    CVPixelBufferLockBaseAddress(buffer, 0);
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer), w, h, 8,
                                             CVPixelBufferGetBytesPerRow(buffer), CGImageGetColorSpace(image),
                                             CGBitmapInfo(kCGImageAlphaNoneSkipFirst) |
                                                 CGBitmapInfo(kCGBitmapByteOrder32Little));
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, CGFloat(w), CGFloat(h)), image);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    const int index = ve::test::readBurnIn(buffer).value_or(-1);
    CVPixelBufferRelease(buffer);
    return index;
}

/// The BGRA bytes of what `view` shows (empty if nothing was rendered).
std::vector<uint8_t> pixelsOf(VEPreviewView *view, size_t *widthOut = nullptr, size_t *heightOut = nullptr) {
    CGImageRef image = [view snapshot];
    if (image == NULL) {
        return {};
    }
    const size_t w = CGImageGetWidth(image);
    const size_t h = CGImageGetHeight(image);
    std::vector<uint8_t> bytes(w * h * 4);
    CGContextRef ctx = CGBitmapContextCreate(bytes.data(), w, h, 8, w * 4, CGImageGetColorSpace(image),
                                             CGBitmapInfo(kCGImageAlphaNoneSkipFirst) |
                                                 CGBitmapInfo(kCGBitmapByteOrder32Little));
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    CGContextDrawImage(ctx, CGRectMake(0, 0, CGFloat(w), CGFloat(h)), image);
    CGContextRelease(ctx);
    if (widthOut != nullptr) {
        *widthOut = w;
    }
    if (heightOut != nullptr) {
        *heightOut = h;
    }
    return bytes;
}

} // namespace

@interface VEEnginePlaybackTests : XCTestCase
@end

@implementation VEEnginePlaybackTests {
    NSURL *_cacheDir;
    id<MTLDevice> _device;
}

- (void)setUp {
    NSURL *scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
    _cacheDir = [scratch URLByAppendingPathComponent:@"Caches" isDirectory:YES];
    _device = MTLCreateSystemDefaultDevice();
}

- (VEEngine *)makeEngine {
    return [[VEEngine alloc] initWithCacheDirectory:_cacheDir];
}

- (VEPreviewView *)makeView {
    if (_device == nil) {
        return nil;
    }
    VEPreviewView *view = [[VEPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 480, 270) device:_device error:nil];
    XCTAssertNotNil(view);
    return view;
}

- (NSURL *)mediaURL:(const char *)file {
    std::string error;
    const std::string path = ve::test::testMediaPath(file, error);
    XCTAssertTrue(error.empty(), @"%s", error.c_str());
    return [NSURL fileURLWithPath:@(path.c_str())];
}

- (VEAssetInfo *)importOne:(const char *)file into:(VEEngine *)engine {
    XCTestExpectation *done = [self expectationWithDescription:@"import"];
    __block VEAssetInfo *asset = nil;
    [engine importMediaAtURLs:@[ [self mediaURL:file] ]
                   completion:^(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors) {
                       XCTAssertEqual(errors.count, 0u, @"%@", errors);
                       asset = assets.firstObject;
                       [done fulfill];
                   }];
    [self waitForExpectations:@[ done ] timeout:60];
    XCTAssertNotNil(asset);
    return asset;
}

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return condition();
}

/// renderOnce and wait for the GPU (the preview view's completion API).
- (void)renderAndWait:(VEPreviewView *)view {
    XCTestExpectation *rendered = [self expectationWithDescription:@"rendered"];
    [view renderOnceWithCompletion:^(NSError *) {
        [rendered fulfill];
    }];
    [self waitForExpectations:@[ rendered ] timeout:5];
}

/// Renders until the view shows burn-in `expected` (or `timeout`); returns what it showed last.
- (int)renderUntil:(VEPreviewView *)view shows:(int)expected timeout:(NSTimeInterval)timeout {
    int shown = -1;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (shown != expected && deadline.timeIntervalSinceNow > 0) {
        [self renderAndWait:view];
        shown = shownIndex(view);
    }
    return shown;
}

/// The test sequence: h264_1080p30.mp4 (burn-in = source frame) on V1 as clip A [0, 2 s) from
/// source 0 and clip B [2 s, 5 s) from source 5 s, with a 10-frame dissolve on the cut; their
/// linked audio on A1. Returns the transition id.
- (VETransitionID)buildSequence:(VEEngine *)engine asset:(VEAssetInfo *)asset {
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
    return t.createdIDs.firstObject.longLongValue;
}

/// Burn-in expected at sequence frame `f` of the test sequence (-1 inside the dissolve, where
/// two pictures are mixed).
static int expectedIndex(int64_t f) {
    if (f >= 55 && f < 65) {
        return -1;
    }
    return f < 60 ? int(f) : int(150 + (f - 60));
}

/// Whether burn-in `shown` is a picture of sequence frame `f`: inside the dissolve the dominant
/// picture may be readable, and it is then clip A's (source f) or clip B's (source 150 + f - 60).
static bool showsFrame(int shown, int64_t f) {
    if (f >= 55 && f < 65) {
        return shown == int(f) || shown == int(150 + (f - 60));
    }
    return shown == expectedIndex(f);
}

// MARK: - Program monitor

- (void)testPlaybackShowsTheFrameAtTheClockThenPausesSeeksAndScrubs {
    VEPreviewView *view = [self makeView];
    if (view == nil) {
        XCTSkip(@"no Metal device");
    }
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    [self buildSequence:engine asset:asset];
    [engine attachProgramView:view];
    XCTAssertEqual(engine.programView, view);
    XCTAssertEqual([self renderUntil:view shows:0 timeout:20], 0, @"the paused picture at 0");

    __block NSInteger notifications = 0;
    __block VEPlaybackState lastState = VEPlaybackStateStopped;
    id token = [NSNotificationCenter.defaultCenter addObserverForName:VEEnginePlaybackDidChangeNotification
                                                               object:engine
                                                                queue:nil
                                                           usingBlock:^(NSNotification *note) {
                                                               VEPlaybackStatus *status =
                                                                   note.userInfo[VEEnginePlaybackStatusKey];
                                                               lastState = status.state;
                                                               notifications += 1;
                                                           }];

    [engine play];
    XCTAssertTrue(engine.playbackState == VEPlaybackStatePrerolling || engine.playbackState == VEPlaybackStatePlaying);
    XCTAssertTrue([self spinUntil:^BOOL {
        return lastState == VEPlaybackStatePlaying;
    }
                          timeout:10]);
    XCTAssertTrue(engine.playbackStatus.isRunning);

    // Until 20 different pictures were checked and the playhead is past the dissolve (bounded
    // by the sequence position, not wall time): render (completion API), read the burn-in, and
    // check it against the clock read around the render: the picture is the frame at the clock
    // within one frame.
    const CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    int checked = 0;
    int64_t previousFrame = -1;
    std::set<int> pictures;
    constexpr size_t kPictures = 20;
    while ((pictures.size() < kPictures || CMTimeGetSeconds(engine.currentTime) < 2.5) &&
           engine.playbackState == VEPlaybackStatePlaying && CMTimeGetSeconds(engine.currentTime) < 4.5) {
        const int64_t before = frameOf(engine.currentTime);
        [self renderAndWait:view];
        const int64_t after = frameOf(engine.currentTime);
        const int shown = shownIndex(view);
        if (shown < 0) {
            continue; // inside the dissolve: no single picture to read
        }
        bool matched = false;
        for (int64_t f = before - 1; f <= after + 1; ++f) {
            matched = matched || showsFrame(shown, f);
        }
        XCTAssertTrue(matched, @"showed %d with the clock at frames %lld...%lld", shown, before, after);
        XCTAssertGreaterThanOrEqual(after, previousFrame, @"the clock never goes backwards");
        previousFrame = after;
        ++checked;
        pictures.insert(shown);
    }
    XCTAssertGreaterThanOrEqual(pictures.size(), kPictures, @"enough pictures before the end of the sequence (%d checks)",
                                checked);
    const NSInteger duringPlay = notifications;
    const double elapsed = CFAbsoluteTimeGetCurrent() - start;
    XCTAssertLessThanOrEqual(double(duringPlay), elapsed * 30.0 + 10, @"at most one notification per frame");

    VEPlaybackStats *stats = engine.playbackStats;
    XCTAssertGreaterThanOrEqual(stats.presentedFrames, uint64_t(kPictures), @"every picture seen was presented");
    XCTAssertGreaterThanOrEqual(stats.presentedFrameIndex, 0, @"the HUD's presented frame is reported");
    XCTAssertTrue(stats.presentedClockDriven);
    XCTAssertGreaterThan(stats.cacheHits, 0u);
    XCTAssertGreaterThan(stats.cacheHitRate, 0.5);
    XCTAssertNotEqual(stats.clockMode, VEClockModeStopped);
    XCTAssertGreaterThan(stats.audioOutputKind.length, 0u);
    XCTAssertGreaterThanOrEqual(stats.activeClips.count, 2u, @"a video and an audio clip under the playhead");
    bool sawVideoBackend = false;
    for (VEActiveClipInfo *clip in stats.activeClips) {
        XCTAssertEqual(clip.assetID, asset.assetID);
        XCTAssertFalse(clip.failed);
        sawVideoBackend = sawVideoBackend || (!clip.isAudio && clip.backendName.length > 0);
    }
    XCTAssertTrue(sawVideoBackend, @"the HUD names the video decoder backend");
    NSLog(@"playback stats: fps %.1f presented %llu dropped %llu late %llu hit rate %.2f queue %ld underruns %llu "
          @"clock %ld output %@ latency %.1f ms",
          stats.fps, stats.presentedFrames, stats.droppedFrames, stats.lateFrames, stats.cacheHitRate,
          long(stats.decodeQueueDepth), stats.audioUnderruns, long(stats.clockMode), stats.audioOutputKind,
          stats.outputLatency * 1000);

    // Pause: the picture converges on exactly the paused frame.
    [engine pause];
    XCTAssertEqual(engine.playbackState, VEPlaybackStateStopped);
    const int64_t pausedFrame = frameOf(engine.currentTime);
    const int pausedExpected = expectedIndex(pausedFrame);
    if (pausedExpected >= 0) {
        XCTAssertEqual([self renderUntil:view shows:pausedExpected timeout:10], pausedExpected);
    }

    // Seek (exact) to 3.5 s: source 5 s + 1.5 s = frame 195.
    [engine seekToTime:seconds(3.5)];
    XCTAssertEqual(CMTimeCompare(engine.currentTime, CMTimeMake(105, 30)), 0);
    XCTAssertEqual([self renderUntil:view shows:195 timeout:20], 195);
    XCTAssertNil(view.lastError);
    XCTAssertEqual(view.missingLayerCount, 0u);

    // Frame steps.
    [engine stepFrames:-3];
    XCTAssertEqual(CMTimeCompare(engine.currentTime, CMTimeMake(102, 30)), 0);
    XCTAssertEqual([self renderUntil:view shows:192 timeout:20], 192);

    // Scrub: lands on the right frame, no audio, ends Stopped.
    [engine scrubToTime:seconds(1.0)];
    XCTAssertEqual(engine.playbackState, VEPlaybackStateScrubbing);
    [engine scrubToTime:seconds(1.5)];
    XCTAssertEqual([self renderUntil:view shows:45 timeout:20], 45);
    [engine endScrub];
    XCTAssertEqual(engine.playbackState, VEPlaybackStateStopped);
    XCTAssertEqual(CMTimeCompare(engine.currentTime, CMTimeMake(45, 30)), 0);

    // Still frames via the old entry point.
    [engine showProgramFrameAtTime:seconds(0.5)];
    XCTAssertEqual([self renderUntil:view shows:15 timeout:20], 15);

    [NSNotificationCenter.defaultCenter removeObserver:token];
    [engine attachProgramView:nil];
}

- (void)testPausedDissolveOfOneAssetShowsBothLayers {
    VEPreviewView *view = [self makeView];
    if (view == nil) {
        XCTSkip(@"no Metal device");
    }
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    [self buildSequence:engine asset:asset];
    [engine attachProgramView:view];
    // Frame 60 is mid-dissolve: both layers come from the same asset. Each must be decoded
    // (their scrub requests use different lanes, so one does not cancel the other).
    [engine seekToTime:CMTimeMake(60, 30)];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    do {
        [self renderAndWait:view];
    } while ((view.missingLayerCount != 0 || view.renderCount == 0) && deadline.timeIntervalSinceNow > 0);
    XCTAssertEqual(view.missingLayerCount, 0u, @"both dissolve layers are shown");
    XCTAssertNil(view.lastError);
    [engine attachProgramView:nil];
}

- (void)testShuttleRatesAndMute {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    [self buildSequence:engine asset:asset];
    [engine seekToTime:seconds(2.5)];

    [engine shuttleForward];
    XCTAssertEqual(engine.playbackRate, 1.0);
    XCTAssertTrue(engine.playbackStatus.isRunning);
    [engine shuttleForward];
    XCTAssertEqual(engine.playbackRate, 2.0);
    [engine shuttleForward];
    XCTAssertEqual(engine.playbackRate, 4.0);
    [engine shuttleReverse];
    XCTAssertEqual(engine.playbackRate, -1.0, @"the other direction restarts at 1x");
    [engine shuttleReverse];
    XCTAssertEqual(engine.playbackRate, -2.0);
    XCTAssertTrue([self spinUntil:^BOOL {
        return engine.playbackState == VEPlaybackStatePlaying;
    }
                          timeout:10]);
    const CMTime t0 = engine.currentTime;
    [self spinUntil:^BOOL {
        return NO;
    }
            timeout:0.3];
    XCTAssertLessThan(CMTimeCompare(engine.currentTime, t0), 0, @"reverse play moves backwards");
    [engine shuttleStop];
    XCTAssertEqual(engine.playbackState, VEPlaybackStateStopped);
    [engine setRate:8];
    XCTAssertEqual(engine.playbackRate, 8.0);
    [engine setRate:0];
    XCTAssertEqual(engine.playbackState, VEPlaybackStateStopped);

    XCTAssertFalse(engine.isMuted);
    engine.muted = YES;
    XCTAssertTrue(engine.isMuted);
    engine.muted = NO;
    XCTAssertFalse(engine.isMuted);
    XCTAssertEqualObjects(engine.playbackError, engine.playbackStatus.errorMessage);
}

- (void)testControlCallsReturnWithinOneMillisecond {
#if defined(__has_feature)
#if __has_feature(thread_sanitizer)
    XCTSkip(@"timing is meaningless under ThreadSanitizer (every memory access is instrumented)");
#endif
#endif
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    [self buildSequence:engine asset:asset];
    VEPreviewView *view = [self makeView];
    if (view != nil) {
        [engine attachProgramView:view];
    }
    std::map<std::string, std::vector<double>> samples;
    auto measure = [&](const char *name, void (^call)(void)) {
        const CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
        call();
        samples[name].push_back((CFAbsoluteTimeGetCurrent() - begin) * 1000.0);
    };
    for (int i = 0; i < 40; ++i) {
        measure("play", ^{ [engine play]; });
        [self spinUntil:^BOOL { return NO; } timeout:0.01];
        measure("seek (playing)", ^{ [engine seekToTime:seconds(1 + 0.1 * i)]; });
        measure("setRate 2", ^{ [engine setRate:2]; });
        measure("shuttleForward", ^{ [engine shuttleForward]; });
        measure("shuttleReverse", ^{ [engine shuttleReverse]; });
        [self spinUntil:^BOOL { return NO; } timeout:0.01];
        measure("pause", ^{ [engine pause]; });
        measure("togglePlay", ^{ [engine togglePlay]; });
        measure("shuttleStop", ^{ [engine shuttleStop]; });
        measure("seek (stopped)", ^{ [engine seekToTime:seconds(0.2 * i)]; });
        measure("stepFrames", ^{ [engine stepFrames:1]; });
        measure("scrubToTime", ^{ [engine scrubToTime:seconds(0.15 * i)]; });
        measure("endScrub", ^{ [engine endScrub]; });
        measure("setMuted", ^{ engine.muted = (i % 2) == 0; });
        measure("currentTime", ^{ (void)engine.currentTime; });
        measure("playbackStatus", ^{ (void)engine.playbackStatus; });
    }
    // Every call must return in well under a millisecond. The main thread can still be preempted
    // by the OS in the middle of one (seen as a rare ~2 ms sample when the machine is loaded by
    // the rest of the suite), so the bound is on the 95th percentile, and the worst case only has
    // to stay far below anything that waits for work (a device start or decode takes 10+ ms).
    for (auto &[name, values] : samples) {
        std::sort(values.begin(), values.end());
        const double median = values[values.size() / 2];
        const double p95 = values[(values.size() * 95) / 100];
        const double worst = values.back();
        NSLog(@"control call %-16s median %.3f ms, p95 %.3f ms, max %.3f ms", name.c_str(), median, p95, worst);
        XCTAssertLessThan(p95, 1.0, @"%s: 95th percentile %.3f ms on the main thread", name.c_str(), p95);
        XCTAssertLessThan(worst, 5.0, @"%s took %.3f ms on the main thread", name.c_str(), worst);
    }
    [engine pause];
    [engine attachProgramView:nil];
}

// MARK: - Source monitor

- (void)testSourceMonitorScrubsOnTheAssetGridAndPlays {
    VEPreviewView *view = [self makeView];
    if (view == nil) {
        XCTSkip(@"no Metal device");
    }
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    NSURL *thumbs = [_cacheDir URLByAppendingPathComponent:@"Thumbnails" isDirectory:YES];
    NSArray *thumbsBefore = [NSFileManager.defaultManager contentsOfDirectoryAtPath:thumbs.path error:nil] ?: @[];

    [engine attachSourceView:view];
    // 1.01 s is inside frame 30: shown on the asset's frame grid.
    XCTAssertEqual(CMTimeCompare([engine frameTimeForAsset:asset.assetID atTime:seconds(1.01)], CMTimeMake(30, 30)), 0);
    [engine sourceMonitorShowAsset:asset.assetID atTime:seconds(1.01)];
    XCTAssertEqual(engine.sourceMonitorAssetID, asset.assetID);
    XCTAssertEqual(CMTimeCompare(engine.sourceMonitorTime, CMTimeMake(30, 30)), 0);
    XCTAssertEqual([self renderUntil:view shows:30 timeout:20], 30);
    // Scrubbing: the newest request wins.
    for (int f = 40; f <= 120; f += 20) {
        [engine sourceMonitorShowAsset:asset.assetID atTime:CMTimeMake(f, 30)];
    }
    XCTAssertEqual([self renderUntil:view shows:120 timeout:20], 120);
    [engine sourceMonitorStepFrames:5];
    XCTAssertEqual([self renderUntil:view shows:125 timeout:20], 125);

    // Play the asset (its own controller: picture and sound), then pause.
    __block VEPlaybackState state = VEPlaybackStateStopped;
    id token = [NSNotificationCenter.defaultCenter addObserverForName:VEEngineSourcePlaybackDidChangeNotification
                                                               object:engine
                                                                queue:nil
                                                           usingBlock:^(NSNotification *note) {
                                                               VEPlaybackStatus *status =
                                                                   note.userInfo[VEEnginePlaybackStatusKey];
                                                               state = status.state;
                                                           }];
    [engine sourceMonitorTogglePlay];
    XCTAssertTrue([self spinUntil:^BOOL {
        return state == VEPlaybackStatePlaying;
    }
                          timeout:10]);
    XCTAssertEqual(engine.sourceMonitorPlaybackState, VEPlaybackStatePlaying);
    const CMTime playingFrom = engine.sourceMonitorTime;
    [self spinUntil:^BOOL { return NO; } timeout:0.5];
    XCTAssertGreaterThan(CMTimeGetSeconds(engine.sourceMonitorTime) - CMTimeGetSeconds(playingFrom), 0.25);
    [self renderAndWait:view];
    const int playingShown = shownIndex(view);
    XCTAssertGreaterThan(playingShown, 125, @"the source monitor shows the playing picture");
    [engine sourceMonitorPause];
    XCTAssertEqual(engine.sourceMonitorPlaybackState, VEPlaybackStateStopped);
    const int paused = int(frameOf(engine.sourceMonitorTime));
    XCTAssertEqual([self renderUntil:view shows:paused timeout:20], paused);
    // Scrubbing after playing goes through the same controller.
    [engine sourceMonitorShowAsset:asset.assetID atTime:CMTimeMake(10, 30)];
    XCTAssertEqual([self renderUntil:view shows:10 timeout:20], 10);
    // The program monitor is unaffected.
    XCTAssertEqual(engine.playbackState, VEPlaybackStateStopped);

    // Clearing.
    [engine sourceMonitorShowAsset:0 atTime:kCMTimeZero];
    XCTAssertEqual(engine.sourceMonitorAssetID, 0);
    NSArray *thumbsAfter = [NSFileManager.defaultManager contentsOfDirectoryAtPath:thumbs.path error:nil] ?: @[];
    // The poster thumbnail may land during the test; scrubbing itself writes nothing.
    XCTAssertLessThanOrEqual(thumbsAfter.count, thumbsBefore.count + 1, @"scrubbing writes no thumbnails to disk");
    [NSNotificationCenter.defaultCenter removeObserver:token];
    [engine attachSourceView:nil];
}

// MARK: - Facade rules

- (void)testMainThreadIsEnforcedInEveryConfiguration {
    VEEngine *engine = [self makeEngine];
    XCTestExpectation *done = [self expectationWithDescription:@"background"];
    __block BOOL threw = NO;
    __block BOOL capsThrew = NO;
    __weak VEEngine *weakEngine = engine; // the engine must be released on the main thread
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            VEEngine *strongEngine = weakEngine;
            @try {
                (void)strongEngine.changeCount;
            } @catch (NSException *exception) {
                threw = [exception.name isEqualToString:NSInternalInconsistencyException];
            }
            @try {
                (void)strongEngine.hardwareCaps;
            } @catch (NSException *exception) {
                capsThrew = YES;
            }
        }
        [done fulfill];
    });
    [self waitForExpectations:@[ done ] timeout:10];
    XCTAssertTrue(threw);
    XCTAssertTrue(capsThrew);
}

- (void)testEditResultsReportDroppedTransitionsAndErrorCodes {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    const VETransitionID transition = [self buildSequence:engine asset:asset];
    const VETrackID v1 = engine.sequence.videoTrackIDs[0].longLongValue;
    NSArray<VEClipInfo *> *clips = [engine clipsOnTrack:v1];
    XCTAssertEqual(clips.count, 2u);

    // A split inside the dissolve is refused with its own code...
    VEEditResult *r = [engine splitClips:@[ @(clips[0].clipID) ] atTime:CMTimeMake(58, 30)];
    XCTAssertFalse(r.ok);
    XCTAssertEqual(r.errorCode, VEEditErrorInsideTransition);
    // ...and allowed when breaking transitions, which reports the removed transition.
    r = [engine splitClips:@[ @(clips[0].clipID) ] atTime:CMTimeMake(58, 30) breakingTransitions:YES];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(r.droppedTransitionIDs, @[ @(transition) ]);
    XCTAssertGreaterThan(r.note.length, 0u);
    XCTAssertNil([engine transitionInfo:transition]);
    XCTAssertTrue([engine undo]);
    XCTAssertNotNil([engine transitionInfo:transition], @"undo restores it");

    // Trimming the cut away drops it too (a plain edit reporting a side effect).
    r = [engine trimClipTail:clips[0].clipID toTime:seconds(1) clamp:NO];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(r.droppedTransitionIDs, @[ @(transition) ]);

    // Removing media while a gesture is open is refused (it would end the gesture's undo step).
    [engine beginCoalescingWithKey:@"drag"];
    r = [engine removeAsset:asset.assetID];
    XCTAssertFalse(r.ok);
    XCTAssertEqual(r.errorCode, VEEditErrorBusy);
    [engine endCoalescing];
}

- (void)testRippleScopeFallsBackToSyncedTracksAndSpeedIsExact {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    NSArray<NSNumber *> *video = engine.sequence.videoTrackIDs;
    VEEditResult *x = [engine overwriteAsset:asset.assetID
                                      atTime:kCMTimeZero
                                  videoTrack:video[0].longLongValue
                                  audioTrack:0
                                    sourceIn:kCMTimeZero
                                   sourceOut:seconds(2)];
    VEEditResult *after = [engine overwriteAsset:asset.assetID
                                          atTime:seconds(2)
                                      videoTrack:video[0].longLongValue
                                      audioTrack:0
                                        sourceIn:seconds(3)
                                       sourceOut:seconds(4)];
    VEEditResult *blocker = [engine overwriteAsset:asset.assetID
                                            atTime:seconds(1)
                                        videoTrack:video[1].longLongValue
                                        audioTrack:0
                                          sourceIn:kCMTimeZero
                                         sourceOut:seconds(2)];
    XCTAssertTrue(x.ok && after.ok && blocker.ok);
    XCTAssertEqual(engine.rippleScope, VERippleScopeAllTracks);
    // Closing [0, 2) on every track is blocked by the V2 clip at [1, 3): falls back.
    VEEditResult *r = [engine rippleDeleteClips:@[ x.createdIDs[0] ]];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertGreaterThan(r.note.length, 0u, @"the fallback is reported");
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds([engine clipInfo:after.createdIDs[0].longLongValue].timelineStart), 0,
                               1e-9);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds([engine clipInfo:blocker.createdIDs[0].longLongValue].timelineStart), 1,
                               1e-9, @"the other track did not move");
    XCTAssertTrue([engine undo]);
    engine.rippleScope = VERippleScopeSyncedTracks;
    r = [engine rippleDeleteClips:@[ x.createdIDs[0] ]];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualObjects(r.note, @"");

    // Exact speeds.
    const VEClipID clip = after.createdIDs[0].longLongValue;
    r = [engine setSpeedNumerator:1 denominator:3 forClip:clip];
    XCTAssertTrue(r.ok, @"%@", r.message);
    VEClipInfo *info = [engine clipInfo:clip];
    XCTAssertEqual(info.speedNumerator, 1);
    XCTAssertEqual(info.speedDenominator, 3);
    XCTAssertEqualWithAccuracy(info.speed, 1.0 / 3.0, 1e-12);
    r = [engine setSpeedNumerator:2 denominator:4 forClip:clip];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual([engine clipInfo:clip].speedNumerator, 1, @"reduced");
    XCTAssertEqual([engine clipInfo:clip].speedDenominator, 2);
    XCTAssertFalse([engine setSpeedNumerator:0 denominator:1 forClip:clip].ok);
    XCTAssertFalse([engine setSpeedNumerator:1 denominator:1001 forClip:clip].ok);
    XCTAssertFalse([engine setSpeed:-1 forClip:clip].ok);
}

- (void)testOpenReportsLoadWarnings {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    [self buildSequence:engine asset:asset];
    NSURL *scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str())];
    NSURL *url = [scratch URLByAppendingPathComponent:@"w.framewright"];
    NSError *error = nil;
    XCTAssertTrue([engine saveProjectToURL:url error:&error], @"%@", error);
    NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    XCTAssertTrue([text containsString:@"\"crossDissolve\""]);
    text = [text stringByReplacingOccurrencesOfString:@"\"crossDissolve\"" withString:@"\"pageCurl\""];
    XCTAssertTrue([text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    XCTAssertTrue([engine openProjectAtURL:url error:&error], @"%@", error);
    XCTAssertEqual(engine.loadWarnings.count, 1u);
    XCTAssertTrue([engine.loadWarnings.firstObject containsString:@"pageCurl"], @"%@", engine.loadWarnings);
    [engine newProjectWithName:@"Clean"];
    XCTAssertEqual(engine.loadWarnings.count, 0u);
}

- (void)testUseCountsAndMemoryPressureAreDelivered {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    __block NSInteger assetNotes = 0;
    id assetsToken = [NSNotificationCenter.defaultCenter addObserverForName:VEEngineAssetsDidChangeNotification
                                                                     object:engine
                                                                      queue:nil
                                                                 usingBlock:^(NSNotification *) {
                                                                     assetNotes += 1;
                                                                 }];
    const VETrackID v1 = engine.sequence.videoTrackIDs[0].longLongValue;
    XCTAssertTrue([engine overwriteAsset:asset.assetID
                                  atTime:kCMTimeZero
                              videoTrack:v1
                              audioTrack:0
                                sourceIn:kCMTimeZero
                               sourceOut:seconds(1)]
                      .ok);
    XCTAssertEqual(assetNotes, 1, @"the use count changed: the bin is told");
    XCTAssertEqual([engine assetInfo:asset.assetID].useCount, 1);
    XCTAssertTrue([engine setTrack:v1 muted:YES].ok);
    XCTAssertEqual(assetNotes, 1, @"no use count change, no assets notification");
    [NSNotificationCenter.defaultCenter removeObserver:assetsToken];

    VEPreviewView *view = [self makeView];
    if (view != nil) {
        [engine attachProgramView:view];
        [self renderAndWait:view];
    }
    [engine seekToTime:seconds(0.5)];
    XCTAssertTrue([self spinUntil:^BOOL {
        return engine.playbackStats.cacheBytes > 0;
    }
                          timeout:10]);
    XCTestExpectation *peaks = [self expectationWithDescription:@"waveform"];
    [engine waveformForAsset:asset.assetID
                  completion:^(VEWaveform *, NSError *) {
                      [peaks fulfill];
                  }];
    [self waitForExpectations:@[ peaks ] timeout:30];
    XCTAssertNotNil([engine cachedWaveformForAsset:asset.assetID]);
    __block BOOL critical = NO;
    id token = [NSNotificationCenter.defaultCenter addObserverForName:VEEngineMemoryPressureNotification
                                                               object:engine
                                                                queue:nil
                                                           usingBlock:^(NSNotification *note) {
                                                               NSNumber *value = note.userInfo[VEEngineCriticalKey];
                                                               critical = value.boolValue;
                                                           }];
    [engine handleMemoryPressure:YES];
    XCTAssertTrue(critical);
    XCTAssertNil([engine cachedWaveformForAsset:asset.assetID], @"in-memory peaks were released");
    [NSNotificationCenter.defaultCenter removeObserver:token];
    [engine attachProgramView:nil];
}

// MARK: - Play-start latency (open finding 3)

/// Press-to-first-presented-frame through the facade, with the machine's real audio output (the
/// clock starts when the first sample is audible, so the output latency is part of it): renders
/// are requested every millisecond (a display link faster than any screen) and the host time
/// at which the frame source handed out the first new clock-driven frame is read from the stats.
/// The paused frame is already on screen, so that frame is a later one; the latency subtracts
/// the playing time it stands for.
/// Press-to-picture latency through the facade with the real AVAudioEngine output: a wall-clock
/// measurement, so it is skipped under ThreadSanitizer (every memory access is instrumented) and
/// its bounds leave room for a machine loaded by the rest of the suite: the median of the cached
/// starts must meet the 50 ms target and the worst stay under 80 ms (measured: 17-27 ms cached).
- (void)testPlayStartLatencyThroughTheFacade {
#if defined(__has_feature)
#if __has_feature(thread_sanitizer)
    XCTSkip(@"a wall-clock latency measurement is meaningless under ThreadSanitizer");
#endif
#endif
    VEPreviewView *view = [self makeView];
    if (view == nil) {
        XCTSkip(@"no Metal device");
    }
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    [self buildSequence:engine asset:asset];
    [engine attachProgramView:view];
    XCTAssertEqual([self renderUntil:view shows:0 timeout:20], 0);

    struct Start {
        double latencyMs = -1;
        double rawMs = -1;
        int64_t frame = -1;
    };
    auto measure = [&](int64_t start) {
        __block Start result;
        // The host time base of presentedHostTime (mach absolute time, in seconds).
        const double t0 = double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9;
        [engine play];
        [self spinUntil:^BOOL {
            [view renderOnce];
            VEPlaybackStats *stats = engine.playbackStats;
            if (stats.presentedClockDriven && stats.presentedFrameIndex > start) {
                result.frame = stats.presentedFrameIndex;
                result.rawMs = (stats.presentedHostTime - t0) * 1000;
                result.latencyMs = result.rawMs - double(result.frame - start) * 1000.0 / 30.0;
                return YES;
            }
            return NO;
        }
                timeout:10];
        [engine pause];
        return result;
    };

    std::vector<double> cached;
    for (int64_t frame : {15, 40, 90, 120}) {
        [engine seekToTime:CMTimeMake(frame, 30)];
        const int expected = expectedIndex(frame);
        XCTAssertEqual([self renderUntil:view shows:expected timeout:20], expected);
        // Still: the lookahead and the audio get ready.
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        const Start start = measure(frame);
        XCTAssertGreaterThanOrEqual(start.rawMs, 0.0, @"playback from frame %lld presented a new frame", frame);
        cached.push_back(start.latencyMs);
    }
    // Cold: every unpinned frame purged, a jump into media nothing decoded, play at once.
    [engine handleMemoryPressure:YES];
    [engine seekToTime:CMTimeMake(130, 30)];
    const Start cold = measure(130);
    XCTAssertGreaterThanOrEqual(cold.rawMs, 0.0);
    std::sort(cached.begin(), cached.end());
    VEPlaybackStats *stats = engine.playbackStats;
    NSLog(@"PLAY START LATENCY (facade, %@ output, latency %.1f ms): cached %.1f / %.1f / %.1f / %.1f ms, cold %.1f ms "
          @"(first new frame %lld after %.1f ms)",
          stats.audioOutputKind, stats.outputLatency * 1000, cached[0], cached[1], cached[2], cached[3], cold.latencyMs,
          cold.frame, cold.rawMs);
    XCTAssertLessThan(cached[cached.size() / 2], 50.0, @"cached media starts within the 50 ms target (median)");
    XCTAssertLessThan(cached.back(), 80.0, @"no cached start is far off the target (worst %.1f ms)", cached.back());
    [engine attachProgramView:nil];
}

// MARK: - Output view (program monitor on a second display, open finding 7)

- (void)testAnOutputViewMirrorsTheProgramMonitor {
    VEPreviewView *program = [self makeView];
    VEPreviewView *output = [self makeView];
    if (program == nil || output == nil) {
        XCTSkip(@"no Metal device");
    }
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *asset = [self importOne:"h264_1080p30.mp4" into:engine];
    [self buildSequence:engine asset:asset];
    [engine attachProgramView:program];
    [engine attachOutputView:output];
    XCTAssertEqual(engine.outputView, output);
    XCTAssertTrue(output.isPaused, @"stopped: the engine keeps the output's render loop paused");

    // Paused: both show the same frame.
    [engine seekToTime:CMTimeMake(45, 30)];
    XCTAssertEqual([self renderUntil:program shows:45 timeout:20], 45);
    XCTAssertEqual([self renderUntil:output shows:45 timeout:20], 45);
    const uint64_t presented = engine.playbackStats.presentedFrames;
    for (int i = 0; i < 3; ++i) {
        [engine stepFrames:1];
        XCTAssertEqual([self renderUntil:output shows:46 + i timeout:20], 46 + i);
    }
    XCTAssertEqual([self renderUntil:program shows:48 timeout:20], 48);
    XCTAssertGreaterThan(engine.playbackStats.presentedFrames, presented);

    // Only the program view counts: with the program view detached, the output alone shows new
    // frames and the counters stay put.
    [engine attachProgramView:nil];
    const uint64_t counted = engine.playbackStats.presentedFrames;
    [engine seekToTime:CMTimeMake(20, 30)];
    XCTAssertEqual([self renderUntil:output shows:20 timeout:20], 20);
    [engine stepFrames:1];
    XCTAssertEqual([self renderUntil:output shows:21 timeout:20], 21);
    XCTAssertEqual(engine.playbackStats.presentedFrames, counted, @"the mirror's frames are not counted");
    [engine attachProgramView:program];
    XCTAssertEqual([self renderUntil:program shows:21 timeout:20], 21);

    // Playing: the engine runs the output's render loop, and both show the frame at the clock.
    [engine play];
    XCTAssertTrue([self spinUntil:^BOOL {
        return engine.playbackState == VEPlaybackStatePlaying && !output.isPaused;
    }
                          timeout:10]);
    int compared = 0;
    while (compared < 10 && engine.playbackState == VEPlaybackStatePlaying && CMTimeGetSeconds(engine.currentTime) < 1.7) {
        [self renderAndWait:program];
        [self renderAndWait:output];
        const int a = shownIndex(program);
        const int b = shownIndex(output);
        if (a < 0 || b < 0) {
            continue;
        }
        XCTAssertLessThanOrEqual(std::abs(a - b), 1, @"the two displays show the same moment (%d / %d)", a, b);
        ++compared;
    }
    XCTAssertGreaterThanOrEqual(compared, 5);
    [engine pause];
    XCTAssertTrue([self spinUntil:^BOOL {
        return output.isPaused;
    }
                          timeout:5],
                  @"paused again with the transport");
    const int pausedFrame = int(frameOf(engine.currentTime));
    XCTAssertEqual([self renderUntil:program shows:pausedFrame timeout:20], pausedFrame);
    XCTAssertEqual([self renderUntil:output shows:pausedFrame timeout:20], pausedFrame, @"the same paused frame");

    // Exporting: playback is refused for the output as for the monitors.
    NSURL *movie = [NSURL fileURLWithPath:[@(ve::test::scratchDirectory().c_str())
                                              stringByAppendingPathComponent:@"output-view-export.mp4"]];
    NSError *error = nil;
    VEExportHandle *handle = [engine beginExportWithSettings:[VEExportSettings defaultSettingsForPreset:VEExportPresetH264]
                                                   outputURL:movie
                                                    progress:nil
                                                  completion:^(VEExportSummary *, NSError *) {
                                                  }
                                                       error:&error];
    XCTAssertNotNil(handle, @"%@", error);
    if (handle != nil) {
        [engine play];
        XCTAssertEqual(engine.playbackState, VEPlaybackStateStopped, @"no playback while exporting");
        XCTAssertTrue(output.isPaused);
        XCTAssertTrue([handle cancelAndWaitWithTimeout:10]);
    }

    // Detached: the output keeps its last picture and follows nothing; the program goes on.
    [engine detachOutputView];
    XCTAssertNil(engine.outputView);
    XCTAssertTrue(output.isPaused);
    [engine seekToTime:CMTimeMake(30, 30)];
    XCTAssertEqual([self renderUntil:program shows:30 timeout:20], 30);
    [self renderAndWait:output];
    XCTAssertEqual(shownIndex(output), pausedFrame, @"a detached output view is not driven any more");
    [engine attachProgramView:nil];
}

// MARK: - VFR dissolve (open finding 1b)

/// A dissolve between two different variable-frame-rate sources (vfr_h264.mp4 through the Apple
/// backend and its Matroska remux vfr_h264_blockdur.mkv, whose irregular frame durations come
/// from BlockDurations, through FFmpeg), shown through VEEngine and the program view: mid-transition
/// each pixel is the mix of the two pictures at the frame centre's mix factor ((k + 0.5) / n for
/// frame k of n), and each picture is the source frame containing the clip's exact source time
/// (the monitor shows the same frame for that clip alone).
- (void)testADissolveBetweenTwoVFRSourcesMixesTheirPicturesAtTheFrameCentre {
    VEPreviewView *view = [self makeView];
    if (view == nil) {
        XCTSkip(@"no Metal device");
    }
    std::string derivedError;
    const std::string mkv = ve::test::derivedMediaPath("vfr_h264_blockdur.mkv", derivedError);
    XCTAssertFalse(mkv.empty(), @"%s", derivedError.c_str());
    if (mkv.empty()) {
        return;
    }
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *first = [self importOne:"vfr_h264.mp4" into:engine];
    XCTestExpectation *done = [self expectationWithDescription:@"import mkv"];
    __block VEAssetInfo *second = nil;
    [engine importMediaAtURLs:@[ [NSURL fileURLWithPath:@(mkv.c_str())] ]
                   completion:^(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors) {
                       XCTAssertEqual(errors.count, 0u, @"%@", errors);
                       second = assets.firstObject;
                       [done fulfill];
                   }];
    [self waitForExpectations:@[ done ] timeout:60];
    XCTAssertNotNil(first);
    XCTAssertNotNil(second);
    XCTAssertTrue(first.isVFR && second.isVFR, @"both sources are flagged VFR");
    XCTAssertNotEqual(first.assetID, second.assetID);
    const VETrackID v1 = engine.sequence.videoTrackIDs[0].longLongValue;
    // A: frames [0, 60) from source 0; B: frames [60, 120) from source 3 s; 20-frame dissolve
    // [50, 70) (A's source runs to 2.33 s, B's back to 2.67 s: both inside the media).
    VEEditResult *a = [engine overwriteAsset:first.assetID
                                      atTime:kCMTimeZero
                                  videoTrack:v1
                                  audioTrack:0
                                    sourceIn:kCMTimeZero
                                   sourceOut:CMTimeMake(60, 30)];
    VEEditResult *b = [engine overwriteAsset:second.assetID
                                      atTime:CMTimeMake(60, 30)
                                  videoTrack:v1
                                  audioTrack:0
                                    sourceIn:CMTimeMake(3, 1)
                                   sourceOut:CMTimeMake(5, 1)];
    XCTAssertTrue(a.ok && b.ok, @"%@ %@", a.message, b.message);
    const VEClipID clipA = a.createdIDs.firstObject.longLongValue;
    const VEClipID clipB = b.createdIDs.firstObject.longLongValue;
    VEEditResult *t = [engine addTransitionFromClip:clipA toClip:clipB duration:CMTimeMake(20, 30)];
    XCTAssertTrue(t.ok, @"%@", t.message);
    XCTAssertFalse([t.note containsString:@"Both sides"], @"different sources: no through-edit note");
    [engine attachProgramView:view];

    // What the view shows at `frame` once complete (every layer decoded).
    auto capture = [&](int64_t frame) {
        [engine seekToTime:CMTimeMake(frame, 30)];
        [self spinUntil:^BOOL {
            [self renderAndWait:view];
            return engine.playbackStats.presentedFrameIndex == frame && view.missingLayerCount == 0 &&
                   view.lastError == nil;
        }
                timeout:20];
        XCTAssertEqual(engine.playbackStats.presentedFrameIndex, frame);
        XCTAssertEqual(view.missingLayerCount, 0u);
        return pixelsOf(view);
    };
    const std::vector<int64_t> frames{52, 56, 63, 68};
    std::map<int64_t, std::vector<uint8_t>> mixed;
    for (int64_t f : frames) {
        mixed[f] = capture(f);
    }
    // The two pictures alone: A extended over the transition (B removed), then B (A removed).
    XCTAssertTrue([engine undo]); // the transition
    XCTAssertTrue([engine removeClips:@[ @(clipB) ]].ok);
    XCTAssertTrue([engine trimClipTail:clipA toTime:CMTimeMake(70, 30) clamp:NO].ok);
    std::map<int64_t, std::vector<uint8_t>> alone;
    std::map<int64_t, int> burnA;
    for (int64_t f : frames) {
        alone[f] = capture(f);
        burnA[f] = shownIndex(view);
    }
    XCTAssertTrue([engine undo]);
    XCTAssertTrue([engine undo]);
    XCTAssertTrue([engine removeClips:@[ @(clipA) ]].ok);
    XCTAssertTrue([engine trimClipHead:clipB toTime:CMTimeMake(50, 30) clamp:NO].ok);
    std::map<int64_t, std::vector<uint8_t>> incoming;
    std::map<int64_t, int> burnB;
    for (int64_t f : frames) {
        incoming[f] = capture(f);
        burnB[f] = shownIndex(view);
    }
    for (int64_t f : frames) {
        // Each picture is the VFR source frame containing the layer's exact source time.
        const CMTime sourceA = CMTimeMake(f, 30);
        const CMTime sourceB = CMTimeAdd(CMTimeMake(3, 1), CMTimeMake(f - 60, 30));
        XCTAssertEqual(burnA[f], ve::test::vfrFrameAt(sourceA), @"A's picture at frame %lld", f);
        // (Matroska keeps millisecond timestamps: a source time within a millisecond of a frame
        // boundary may land on either side of it.)
        const int earlyB = ve::test::vfrFrameAt(CMTimeSubtract(sourceB, CMTimeMake(1, 1000)));
        const int lateB = ve::test::vfrFrameAt(CMTimeAdd(sourceB, CMTimeMake(1, 1000)));
        XCTAssertTrue(burnB[f] == earlyB || burnB[f] == lateB, @"B's picture at frame %lld: %d, expected %d..%d", f,
                      burnB[f], earlyB, lateB);

        const std::vector<uint8_t> &m = mixed[f];
        const std::vector<uint8_t> &pa = alone[f];
        const std::vector<uint8_t> &pb = incoming[f];
        XCTAssertTrue(!m.empty() && m.size() == pa.size() && m.size() == pb.size());
        if (m.empty() || m.size() != pa.size() || m.size() != pb.size()) {
            continue;
        }
        const double mix = (double(f - 50) + 0.5) / 20.0;
        int worst = 0;
        size_t differing = 0;
        double sumError = 0;
        for (size_t i = 0; i < m.size(); ++i) {
            if (i % 4 == 3) {
                continue; // alpha (skipped)
            }
            const double expected = (1.0 - mix) * pa[i] + mix * pb[i];
            const int error = int(std::lround(std::fabs(double(m[i]) - expected)));
            worst = std::max(worst, error);
            sumError += error;
            differing += std::abs(int(pa[i]) - int(pb[i])) > 32 ? 1 : 0;
        }
        const double samples = double(m.size()) * 3 / 4;
        XCTAssertGreaterThan(double(differing) / samples, 0.001,
                             @"frame %lld: the two pictures differ (so a missing mix would show)", f);
        XCTAssertLessThanOrEqual(worst, 3, @"frame %lld: mixed pixels match (1 - %.3f) A + %.3f B", f, mix, mix);
        XCTAssertLessThan(sumError / samples, 1.0, @"frame %lld", f);
        NSLog(@"VFR dissolve frame %lld: mix %.3f, A %d, B %d, worst error %d, mean %.3f, %.1f%% differ", f, mix,
              burnA[f], burnB[f], worst, sumError / samples, 100.0 * double(differing) / samples);
    }
    [engine attachProgramView:nil];
}

@end
