// VEProgramMonitor on its own, constructed without an engine: which snapshot the controller gets (a
// new project generation or a detach moves it to frame 0, an edit of the same generation keeps the
// playhead), the transport and the status block on the main thread, the preview solo clip, and the
// output view's render loop following the transport.

#import <FramewrightEngine/FramewrightEngine.h>
#import <Metal/Metal.h>
#import <XCTest/XCTest.h>

#import "../../Engine/Facade/VEProgramMonitor+Internal.h"

#include "../../Engine/Media/AssetImport.h"
#include "../../Engine/Media/BackendRouter.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Media/FrameCache.h"
#include "../Media/TestMedia.h"

#include <memory>
#include <string>

using namespace ve;
using namespace ve::facade;

namespace {

CMTime frames(int64_t n) {
    return CMTimeMake(n, 30);
}

/// A 1920x1080 30 fps model with a 3 s clip of h264_1080p30.mp4 (and its linked audio), and the
/// shared services the monitor decodes through.
struct ProgramRig {
    std::shared_ptr<media::BackendRouter> router = media::BackendRouter::makeDefault();
    std::shared_ptr<media::FrameCache> cache = std::make_shared<media::FrameCache>();
    Project project;
    AssetId asset;
    ClipId videoClip;
    std::string error;

    ProgramRig() {
        (void)router->registerBackend(media::ffmpeg::makeFFmpegBackend());
        project.activeSequenceId = project.addSequence("Main", CMTimeMake(1, 30), 1920, 1080, 1, 1);
        const std::string path = test::testMediaPath("h264_1080p30.mp4", error);
        if (path.empty()) {
            return;
        }
        auto routed = router->probe(path);
        if (!routed.ok()) {
            error = routed.error().description();
            return;
        }
        auto made = media::makeMediaAsset(*routed, project.ids.make<AssetId>());
        if (!made.ok()) {
            error = made.error().description();
            return;
        }
        project.assets.push_back(*made);
        asset = made->id;
        Sequence &sequence = *project.activeSequence();
        Clip video;
        video.id = project.ids.make<ClipId>();
        video.assetId = asset;
        video.trackId = sequence.videoTracks[0].id;
        video.timelineStart = kCMTimeZero;
        video.timelineDuration = frames(90);
        video.sourceIn = kCMTimeZero;
        Clip audio = video;
        audio.id = project.ids.make<ClipId>();
        audio.trackId = sequence.audioTracks[0].id;
        video.linkedClipId = audio.id;
        audio.linkedClipId = video.id;
        sequence.videoTracks[0].clips.push_back(video);
        sequence.audioTracks[0].clips.push_back(audio);
        videoClip = video.id;
    }
};

ProgramMonitorConfig monitorConfig() {
    ProgramMonitorConfig config;
    config.poolBudgetShare = 0.5;
    config.scrubLaneBase = 0;
    return config;
}

} // namespace

@interface VEProgramMonitorTests : XCTestCase
@end

@implementation VEProgramMonitorTests

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return condition();
}

- (VEProgramMonitor *)makeMonitor:(ProgramRig &)rig statuses:(NSMutableArray<VEPlaybackStatus *> *)statuses {
    return [[VEProgramMonitor alloc] initWithRouter:rig.router
                                         frameCache:rig.cache
                                             config:monitorConfig()
                                           onStatus:^(VEPlaybackStatus *status) {
                                             XCTAssertTrue(NSThread.isMainThread);
                                             [statuses addObject:status];
                                           }];
}

- (BOOL)waitForTime:(CMTime)time monitor:(VEProgramMonitor *)monitor {
    return [self spinUntil:^BOOL { return CMTimeCompare(monitor.currentTime, time) == 0; } timeout:10];
}

- (void)testANewGenerationMovesToTheStartAndAnEditKeepsThePlayhead {
    ProgramRig rig;
    XCTAssertTrue(rig.asset, @"%s", rig.error.c_str());
    VEProgramMonitor *monitor = [self makeMonitor:rig statuses:[NSMutableArray array]];
    [monitor publishProject:rig.project generation:1];
    [monitor seekToTime:frames(30)];
    XCTAssertTrue([self waitForTime:frames(30) monitor:monitor]);

    // An edit of the same project: the controller keeps its position.
    rig.project.activeSequence()->videoTracks[0].clips[0].timelineDuration = frames(80);
    [monitor publishProject:rig.project generation:1];
    [self spinUntil:^BOOL { return NO; } timeout:0.2];
    XCTAssertEqual(CMTimeCompare(monitor.currentTime, frames(30)), 0);

    // Another project generation: its sequence from frame 0.
    [monitor publishProject:rig.project generation:2];
    XCTAssertTrue([self waitForTime:kCMTimeZero monitor:monitor]);

    // Detached (New/Open): the next publish of the same generation starts over too.
    [monitor seekToTime:frames(15)];
    XCTAssertTrue([self waitForTime:frames(15) monitor:monitor]);
    [monitor detachFromProject];
    [monitor publishProject:rig.project generation:2];
    XCTAssertTrue([self waitForTime:kCMTimeZero monitor:monitor]);

    // A time that is not numeric seeks to 0; a scrub to one is ignored.
    [monitor seekToTime:frames(10)];
    XCTAssertTrue([self waitForTime:frames(10) monitor:monitor]);
    [monitor scrubToTime:kCMTimeInvalid];
    [monitor endScrub];
    [monitor seekToTime:kCMTimeInvalid];
    XCTAssertTrue([self waitForTime:kCMTimeZero monitor:monitor]);
}

- (void)testTransportPreviewSoloAndTheStatusBlock {
    ProgramRig rig;
    XCTAssertTrue(rig.asset, @"%s", rig.error.c_str());
    NSMutableArray<VEPlaybackStatus *> *statuses = [NSMutableArray array];
    VEProgramMonitor *monitor = [self makeMonitor:rig statuses:statuses];
    [monitor publishProject:rig.project generation:1];
    monitor.muted = YES;
    XCTAssertTrue(monitor.muted);

    XCTAssertTrue([monitor setPreviewSoloClip:rig.videoClip identityMotion:YES]);
    XCTAssertTrue(monitor.previewSolo.has_value());
    if (monitor.previewSolo) {
        XCTAssertTrue(monitor.previewSolo->clip == rig.videoClip);
        XCTAssertTrue(monitor.previewSolo->identityMotion);
    }
    [monitor clearPreviewSolo];
    XCTAssertFalse(monitor.previewSolo.has_value());
    XCTAssertFalse([monitor setPreviewSoloClip:ClipId(999'999) identityMotion:NO], @"not a clip of the sequence");

    XCTAssertFalse(monitor.running);
    [monitor play];
    XCTAssertTrue([self spinUntil:^BOOL { return monitor.playbackState == VEPlaybackStatePlaying; } timeout:10]);
    XCTAssertTrue(monitor.running);
    XCTAssertEqual(monitor.rate, 1.0);
    XCTAssertTrue([self spinUntil:^BOOL { return statuses.lastObject.state == VEPlaybackStatePlaying; } timeout:5]);
    XCTAssertEqualObjects(monitor.playbackError, @"");
    [monitor pauseIfRunning];
    XCTAssertTrue([self spinUntil:^BOOL { return !monitor.running; } timeout:5]);
    [monitor pauseIfRunning]; // not running: nothing to do
    XCTAssertFalse(monitor.running);

    [monitor stepFrames:3];
    XCTAssertTrue([self spinUntil:^BOOL { return monitor.playbackStatus.state != VEPlaybackStatePlaying; } timeout:5]);
    [monitor togglePlay];
    XCTAssertTrue([self spinUntil:^BOOL { return monitor.running; } timeout:10]);
    [monitor togglePlay];
    XCTAssertTrue([self spinUntil:^BOOL { return !monitor.running; } timeout:5]);
    [monitor shuttleForward];
    XCTAssertTrue([self spinUntil:^BOOL { return monitor.running && monitor.rate > 0; } timeout:10]);
    [monitor pause];
    [monitor shuttleReverse];
    XCTAssertTrue([self spinUntil:^BOOL { return monitor.rate < 0; } timeout:10]);
    [monitor setRate:0];
    XCTAssertTrue([self spinUntil:^BOOL { return !monitor.running; } timeout:5]);
}

- (void)testTheOutputViewsRenderLoopFollowsTheTransport {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) {
        XCTSkip(@"no Metal device");
    }
    ProgramRig rig;
    XCTAssertTrue(rig.asset, @"%s", rig.error.c_str());
    VEPreviewView *program = [[VEPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 480, 270) device:device error:nil];
    VEPreviewView *output = [[VEPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 480, 270) device:device error:nil];
    VEProgramMonitor *monitor = [self makeMonitor:rig statuses:[NSMutableArray array]];
    [monitor publishProject:rig.project generation:1];
    [monitor attachView:program];
    XCTAssertEqual(monitor.view, program);
    [monitor attachOutputView:output];
    XCTAssertEqual(monitor.outputView, output);
    XCTAssertTrue(output.paused, @"stopped: the output's render loop is paused");

    monitor.muted = YES;
    [monitor play];
    XCTAssertTrue([self spinUntil:^BOOL { return monitor.running && !output.paused; } timeout:10],
                  @"playing: the monitor runs the output's render loop");
    [monitor pause];
    XCTAssertTrue([self spinUntil:^BOOL { return output.paused; } timeout:5], @"paused again with the transport");

    [monitor detachOutputView];
    XCTAssertNil(monitor.outputView);
    XCTAssertTrue(output.paused);
    [monitor attachView:nil];
    XCTAssertNil(monitor.view);
    [monitor handleMemoryPressure];
}

@end
