// VESourceMonitor on its own, constructed without an engine: the scrub position and the still
// status before it plays, stepping through its private project, the reset when its asset leaves
// the model, a still that cannot play, playing through its own controller (the status block on the
// main thread, one-monitor-at-a-time helpers), and the stopped lookahead following the visibility
// and the permission the engine gives (an export).

#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#import "../../Engine/Facade/VESourceMonitor+Internal.h"

#include "../../Engine/Media/AssetImport.h"
#include "../../Engine/Media/BackendRouter.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Media/FrameCache.h"
#include "../Media/TestMedia.h"

#include <map>
#include <memory>
#include <string>
#include <vector>

using namespace ve;
using namespace ve::facade;

namespace {

CMTime seconds(double s) {
    return CMTimeMakeWithSeconds(s, 600);
}

/// A model with probed assets, and the shared services a monitor decodes through.
struct MonitorRig {
    std::shared_ptr<media::BackendRouter> router = media::BackendRouter::makeDefault();
    std::shared_ptr<media::FrameCache> cache = std::make_shared<media::FrameCache>();
    std::map<AssetId, media::RoutedMediaInfo> routing;
    Project project;
    std::string error;

    MonitorRig() {
        (void)router->registerBackend(media::ffmpeg::makeFFmpegBackend());
        project.activeSequenceId = project.addSequence("Main", CMTimeMake(1, 30), 1920, 1080, 1, 1);
    }

    /// Adds the generated file `file` as an asset of the model (probed like an import).
    const MediaAsset *addAsset(const char *file) {
        const std::string path = test::testMediaPath(file, error);
        if (path.empty()) {
            return nullptr;
        }
        auto routed = router->probe(path);
        if (!routed.ok()) {
            error = routed.error().description();
            return nullptr;
        }
        auto asset = media::makeMediaAsset(*routed, project.ids.make<AssetId>());
        if (!asset.ok()) {
            error = asset.error().description();
            return nullptr;
        }
        project.assets.push_back(*asset);
        routing[asset->id] = *routed;
        return &project.assets.back();
    }
};

SourceMonitorConfig monitorConfig() {
    SourceMonitorConfig config;
    config.poolBudgetShare = 0.25;
    config.scrubLaneBase = uint64_t(1) << 40;
    config.playbackLaneBase = uint64_t(2) << 40;
    return config;
}

} // namespace

@interface VESourceMonitorTests : XCTestCase
@end

@implementation VESourceMonitorTests

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return condition();
}

- (VESourceMonitor *)makeMonitor:(MonitorRig &)rig statuses:(NSMutableArray<VEPlaybackStatus *> *)statuses {
    return [[VESourceMonitor alloc] initWithRouter:rig.router
                                        frameCache:rig.cache
                                            config:monitorConfig()
                                          onStatus:^(VEPlaybackStatus *status) {
                                            XCTAssertTrue(NSThread.isMainThread);
                                            [statuses addObject:status];
                                          }];
}

- (void)testScrubbingStepsThroughThePrivateProjectAndResetsWhenTheAssetLeaves {
    MonitorRig rig;
    const MediaAsset *asset = rig.addAsset("h264_1080p30.mp4");
    XCTAssertTrue(asset != nullptr, @"%s", rig.error.c_str());
    if (asset == nullptr) {
        return;
    }
    NSMutableArray<VEPlaybackStatus *> *statuses = [NSMutableArray array];
    VESourceMonitor *monitor = [self makeMonitor:rig statuses:statuses];
    XCTAssertFalse(monitor.asset);
    XCTAssertTrue(monitor.visible);
    XCTAssertTrue(monitor.idleLookaheadAllowed);

    XCTAssertFalse([monitor showAsset:*asset atTime:seconds(1) frameDuration:CMTimeMake(1, 30) project:rig.project],
                   @"no controller yet: the still picture is refreshed and the caller reports it");
    XCTAssertTrue(monitor.asset == asset->id);
    XCTAssertEqual(CMTimeCompare(monitor.time, seconds(1)), 0);
    XCTAssertEqual(monitor.playbackState, VEPlaybackStateStopped);
    XCTAssertEqual(CMTimeCompare(monitor.playbackStatus.time, seconds(1)), 0);
    XCTAssertEqual(monitor.playbackStatus.state, VEPlaybackStateStopped);
    XCTAssertEqual(monitor.playbackStats.decodeStreams, 0);
    XCTAssertFalse(monitor.running);

    XCTAssertFalse([monitor stepControllerFrames:3], @"no controller shows the monitor");
    const std::optional<CMTime> stepped = [monitor timeSteppedByFrames:3];
    XCTAssertTrue(stepped.has_value());
    if (stepped) {
        XCTAssertEqual(CMTimeCompare(*stepped, CMTimeAdd(seconds(1), CMTimeMake(3, 30))), 0);
    }
    const std::optional<CMTime> before = [monitor timeSteppedByFrames:-1000];
    XCTAssertTrue(before && CMTimeCompare(*before, kCMTimeZero) == 0, @"not before 0");

    XCTAssertFalse([monitor resetIfAssetLeft:rig.project], @"the asset is still in the model");
    Project without = rig.project;
    without.assets.clear();
    XCTAssertTrue([monitor resetIfAssetLeft:without]);
    XCTAssertFalse(monitor.asset);
    XCTAssertEqual(CMTimeCompare(monitor.time, kCMTimeZero), 0);
    XCTAssertFalse([monitor timeSteppedByFrames:1].has_value(), @"no private project without an asset");
    XCTAssertEqual(statuses.count, 0u, @"only the controller reports through the status block");
}

- (void)testAStillShowsButDoesNotPlay {
    MonitorRig rig;
    const MediaAsset *still = rig.addAsset("still.png");
    XCTAssertTrue(still != nullptr, @"%s", rig.error.c_str());
    if (still == nullptr) {
        return;
    }
    VESourceMonitor *monitor = [self makeMonitor:rig statuses:[NSMutableArray array]];
    XCTAssertFalse([monitor showAsset:*still atTime:kCMTimeZero frameDuration:CMTimeMake(1, 30) project:rig.project]);
    XCTAssertTrue(monitor.asset == still->id);
    XCTAssertFalse([monitor prepareToPlayWithRouting:rig.routing muted:YES]);
    XCTAssertFalse([monitor timeSteppedByFrames:1].has_value());
}

- (void)testItPlaysThroughItsOwnControllerAndReportsOnTheMainThread {
    MonitorRig rig;
    const MediaAsset *asset = rig.addAsset("h264_1080p30.mp4");
    XCTAssertTrue(asset != nullptr, @"%s", rig.error.c_str());
    if (asset == nullptr) {
        return;
    }
    NSMutableArray<VEPlaybackStatus *> *statuses = [NSMutableArray array];
    VESourceMonitor *monitor = [self makeMonitor:rig statuses:statuses];
    [monitor showAsset:*asset atTime:seconds(1) frameDuration:CMTimeMake(1, 30) project:rig.project];
    XCTAssertTrue([monitor prepareToPlayWithRouting:rig.routing muted:YES]);
    XCTAssertFalse(monitor.running);
    [monitor togglePlay];
    XCTAssertTrue([self spinUntil:^BOOL { return monitor.playbackState == VEPlaybackStatePlaying; } timeout:10]);
    XCTAssertTrue(monitor.running);
    XCTAssertTrue(monitor.controllerRunning);
    XCTAssertTrue([self spinUntil:^BOOL { return statuses.lastObject.state == VEPlaybackStatePlaying; } timeout:5]);
    XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(monitor.time), 1.0);

    [monitor pauseIfRunning];
    XCTAssertTrue([self spinUntil:^BOOL { return !monitor.running; } timeout:5]);
    XCTAssertTrue([self spinUntil:^BOOL { return statuses.lastObject.state != VEPlaybackStatePlaying; } timeout:5]);

    // Stepping and seeking go through the controller now; it reports the new position.
    XCTAssertTrue([monitor stepControllerFrames:2]);
    const NSUInteger reported = statuses.count;
    XCTAssertTrue([monitor showAsset:*asset atTime:seconds(2) frameDuration:CMTimeMake(1, 30) project:rig.project]);
    XCTAssertTrue([self spinUntil:^BOOL {
        return statuses.count > reported && CMTimeCompare(statuses.lastObject.time, seconds(2)) == 0;
    }
                          timeout:10]);

    // Another asset stops the controller and shows the still picture again.
    const MediaAsset *other = rig.addAsset("hevc_720p2997.mov");
    XCTAssertTrue(other != nullptr, @"%s", rig.error.c_str());
    if (other != nullptr) {
        XCTAssertFalse([monitor showAsset:*other
                                   atTime:kCMTimeZero
                            frameDuration:CMTimeMake(1, 30)
                                  project:rig.project]);
        XCTAssertEqual(monitor.playbackState, VEPlaybackStateStopped);
        XCTAssertFalse([monitor stepControllerFrames:1]);
    }
}

- (void)testTheStoppedLookaheadFollowsVisibilityAndPermission {
    MonitorRig rig;
    const MediaAsset *asset = rig.addAsset("h264_1080p30.mp4");
    XCTAssertTrue(asset != nullptr, @"%s", rig.error.c_str());
    if (asset == nullptr) {
        return;
    }
    VESourceMonitor *monitor = [self makeMonitor:rig statuses:[NSMutableArray array]];
    [monitor showAsset:*asset atTime:seconds(1) frameDuration:CMTimeMake(1, 30) project:rig.project];
    XCTAssertTrue([monitor prepareToPlayWithRouting:rig.routing muted:YES]);
    auto streams = ^NSInteger {
        return monitor.playbackStats.decodeStreams;
    };
    XCTAssertTrue([self spinUntil:^BOOL { return streams() > 0; } timeout:5],
                  @"shown and allowed: a stopped lookahead");

    monitor.visible = NO;
    XCTAssertTrue([self spinUntil:^BOOL { return streams() == 0; } timeout:5], @"hidden: none");
    monitor.visible = YES;
    XCTAssertTrue([self spinUntil:^BOOL { return streams() > 0; } timeout:5], @"shown again: it resumes");

    monitor.idleLookaheadAllowed = NO;
    XCTAssertTrue([self spinUntil:^BOOL { return streams() == 0; } timeout:5], @"not allowed: none");
    monitor.visible = NO;
    monitor.visible = YES;
    [self spinUntil:^BOOL { return NO; } timeout:0.3];
    XCTAssertEqual(streams(), 0, @"showing the monitor does not override the permission");
    monitor.idleLookaheadAllowed = YES;
    XCTAssertTrue([self spinUntil:^BOOL { return streams() > 0; } timeout:5], @"allowed and shown: it resumes");

    [monitor pauseController];
    XCTAssertFalse(monitor.controllerRunning);
}

@end
