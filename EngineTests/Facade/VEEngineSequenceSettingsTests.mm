// Sequence settings through the facade (VEEngine "Sequence settings"): a new project's sequence adopts
// its first video clip's size and frame rate in the placement's undo step (stills and sound never
// count; a variable frame rate, a rotation and a slow-motion clip), an opened project never adopts,
// the Sequence Settings preview and apply (one undo step, the confirmation's sentences, refusals),
// the sharpening setting, "Sequence size" giving the sequence's own size to an export (a 4K sequence
// made from a 4K clip exports 3840x2160) and the export writing the sequence's audio sample rate.

#import <AVFoundation/AVFoundation.h>
#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#include "../Media/TestMedia.h"
#include "../Media/TextCard.h"

#include <string>

namespace {

CMTime seconds(double s) {
    return CMTimeMakeWithSeconds(s, 600);
}

bool anyContains(NSArray<NSString *> *sentences, NSString *part) {
    for (NSString *sentence in sentences) {
        if ([sentence containsString:part]) {
            return true;
        }
    }
    return false;
}

} // namespace

@interface VEEngineSequenceSettingsTests : XCTestCase
@end

@implementation VEEngineSequenceSettingsTests {
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

- (NSArray<VEAssetInfo *> *)importURLs:(NSArray<NSURL *> *)urls into:(VEEngine *)engine {
    XCTestExpectation *done = [self expectationWithDescription:@"import"];
    __block NSArray<VEAssetInfo *> *imported = @[];
    [engine importMediaAtURLs:urls
                   completion:^(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors) {
                       XCTAssertEqual(errors.count, 0u, @"%@", errors);
                       imported = assets;
                       [done fulfill];
                   }];
    [self waitForExpectations:@[ done ] timeout:120];
    XCTAssertEqual(imported.count, urls.count);
    return imported;
}

- (VEAssetInfo *)importURL:(NSURL *)url into:(VEEngine *)engine {
    return [self importURLs:@[ url ] into:engine].firstObject;
}

- (VETrackID)videoTrack:(VEEngine *)engine index:(NSUInteger)index {
    return engine.sequence.videoTrackIDs[index].longLongValue;
}

- (VETrackID)audioTrack:(VEEngine *)engine index:(NSUInteger)index {
    return engine.sequence.audioTrackIDs[index].longLongValue;
}

- (void)assertSequence:(VEEngine *)engine
                 width:(NSInteger)width
                height:(NSInteger)height
         frameDuration:(CMTime)frameDuration
            configured:(BOOL)configured
               context:(NSString *)context {
    VESequenceInfo *sequence = engine.sequence;
    XCTAssertEqual(sequence.width, width, @"%@", context);
    XCTAssertEqual(sequence.height, height, @"%@", context);
    XCTAssertEqual(CMTimeCompare(sequence.frameDuration, frameDuration), 0, @"%@: %@ fps", context,
                   [VEEngine nameForFrameDuration:sequence.frameDuration]);
    XCTAssertEqual(sequence.configured, configured, @"%@", context);
}

// MARK: - Adoption

- (void)testANewSequenceAdoptsItsFirstVideoClipInThePlacementsUndoStep {
    VEEngine *engine = [self makeEngine];
    [self assertSequence:engine width:1920 height:1080 frameDuration:CMTimeMake(1, 30) configured:NO context:@"new"];
    NSArray<VEAssetInfo *> *assets = [self importURLs:@[
        [self mediaURL:"still.png"], [self mediaURL:"audio_only.wav"], [self mediaURL:"hevc_720p2997.mov"],
        [self mediaURL:"prores_540p25.mov"]
    ]
                                                 into:engine];
    VEAssetInfo *still = assets[0], *sound = assets[1], *movie = assets[2], *prores = assets[3];
    XCTAssertTrue(still.isStill);
    // Importing sets nothing.
    [self assertSequence:engine width:1920 height:1080 frameDuration:CMTimeMake(1, 30) configured:NO context:@"import"];

    // A still, the sound of a file and the movie's sound alone never count.
    const VETrackID v1 = [self videoTrack:engine index:0], v2 = [self videoTrack:engine index:1];
    const VETrackID a1 = [self audioTrack:engine index:0], a2 = [self audioTrack:engine index:1];
    VEEditResult *placedStill = [engine overwriteAsset:still.assetID
                                                atTime:kCMTimeZero
                                            videoTrack:v1
                                            audioTrack:0
                                              sourceIn:kCMTimeInvalid
                                             sourceOut:kCMTimeInvalid];
    XCTAssertTrue(placedStill.ok, @"%@", placedStill.message);
    XCTAssertEqualObjects(placedStill.note, @"");
    XCTAssertTrue([engine overwriteAsset:sound.assetID
                                  atTime:kCMTimeZero
                              videoTrack:0
                              audioTrack:a1
                                sourceIn:kCMTimeInvalid
                               sourceOut:kCMTimeInvalid]
                      .ok);
    XCTAssertTrue([engine overwriteAsset:movie.assetID
                                  atTime:seconds(6)
                              videoTrack:0
                              audioTrack:a2
                                sourceIn:kCMTimeInvalid
                               sourceOut:kCMTimeInvalid]
                      .ok);
    [self assertSequence:engine
                   width:1920
                  height:1080
           frameDuration:CMTimeMake(1, 30)
              configured:NO
                 context:@"a still and sound"];
    const NSUInteger clipsBefore = 3; // the still, the sound, the movie's sound
    XCTAssertEqual(engine.allClips.count, clipsBefore);
    const CMTime stillEndBefore = [engine clipInfo:placedStill.createdIDs[0].longLongValue].timelineEnd;

    // The movie's picture: 1280x720 at 29.97, in the Overwrite's own undo step.
    VEEditResult *placed = [engine overwriteAsset:movie.assetID
                                           atTime:seconds(1.0 / 3.0)
                                       videoTrack:v2
                                       audioTrack:0
                                         sourceIn:kCMTimeInvalid
                                        sourceOut:seconds(2)];
    XCTAssertTrue(placed.ok, @"%@", placed.message);
    XCTAssertTrue([placed.note containsString:@"The sequence takes “hevc_720p2997.mov”'s settings: 1280×720 at "
                                              @"29.97 fps."],
                  @"%@", placed.note);
    // And what that did to the clips already there (nit (a) of the 2026-09-30 fix round: the composite's
    // settings change conformed them silently): the settings change's own sentences follow.
    XCTAssertTrue([placed.note containsString:@"The frame becomes 1280×720 (from 1920×1080)"], @"%@", placed.note);
    XCTAssertTrue([placed.note containsString:@"The frame rate becomes 29.97 fps (from 30): "], @"%@", placed.note);
    XCTAssertTrue([placed.note rangeOfString:@"The sequence takes"].location <
                      [placed.note rangeOfString:@"The frame becomes"].location,
                  @"%@", placed.note);
    [self assertSequence:engine
                   width:1280
                  height:720
           frameDuration:CMTimeMake(1001, 30000)
              configured:YES
                 context:@"the first video clip"];
    XCTAssertEqualObjects(engine.undoActionName, @"Overwrite");
    // The clips already there are on the new frame grid: the still's 5 s end is the nearest 29.97 frame.
    VEClipInfo *stillClip = [engine clipInfo:placedStill.createdIDs[0].longLongValue];
    XCTAssertEqual(CMTimeCompare(stillClip.timelineEnd, CMTimeMake(150 * 1001, 30000)), 0, @"%@",
                   CMTimeCopyDescription(nullptr, stillClip.timelineEnd));
    // The placed clip starts on a 29.97 frame (1/3 s is 9.99 frames: 10).
    VEClipInfo *movieClip = [engine clipInfo:placed.createdIDs[0].longLongValue];
    XCTAssertEqual(CMTimeCompare(movieClip.timelineStart, CMTimeMake(10 * 1001, 30000)), 0);

    // One undo takes back the clip and the settings; redo brings both.
    XCTAssertTrue([engine undo]);
    [self assertSequence:engine width:1920 height:1080 frameDuration:CMTimeMake(1, 30) configured:NO context:@"undo"];
    XCTAssertNil([engine clipInfo:placed.createdIDs[0].longLongValue]);
    XCTAssertEqual(CMTimeCompare([engine clipInfo:placedStill.createdIDs[0].longLongValue].timelineEnd, stillEndBefore),
                   0);
    XCTAssertEqual(engine.allClips.count, clipsBefore);
    XCTAssertTrue([engine redo]);
    [self assertSequence:engine
                   width:1280
                  height:720
           frameDuration:CMTimeMake(1001, 30000)
              configured:YES
                 context:@"redo"];
    XCTAssertNotNil([engine clipInfo:placed.createdIDs[0].longLongValue]);

    // The first video clip wins: another one leaves the settings alone.
    VEEditResult *second = [engine overwriteAsset:prores.assetID
                                           atTime:seconds(8)
                                       videoTrack:v1
                                       audioTrack:0
                                         sourceIn:kCMTimeInvalid
                                        sourceOut:seconds(1)];
    XCTAssertTrue(second.ok, @"%@", second.message);
    XCTAssertEqualObjects(second.note, @"");
    [self assertSequence:engine
                   width:1280
                  height:720
           frameDuration:CMTimeMake(1001, 30000)
              configured:YES
                 context:@"a second video clip"];

    // New Project starts over.
    [engine newProjectWithName:@"Again"];
    [self assertSequence:engine width:1920 height:1080 frameDuration:CMTimeMake(1, 30) configured:NO context:@"new again"];
}

- (void)testVariableFrameRateRotatedAndSlowMotionSourcesAdoptStandardRates {
    struct Case {
        const char *file;
        NSInteger width;
        NSInteger height;
        CMTime frameDuration;
    };
    const Case cases[] = {
        // Frames 1/60 s apart at the fastest (a variable rate): 60 fps.
        {"vfr_h264.mp4", 640, 360, CMTimeMake(1, 60)},
        // Stored 640x360, shown turned a quarter: a portrait sequence.
        {"rotated90_h264.mp4", 360, 640, CMTimeMake(1, 30)},
        // 240 fps in its slow section (above 60: the standard rate it is a multiple of), portrait.
        {"slowmo_hevc_portrait.mov", 360, 640, CMTimeMake(1, 60)},
        // A screen recording: frames only when the screen changes, at most 60 a second.
        {"screencast_vfr_h264.mov", 1280, 720, CMTimeMake(1, 60)},
        {"prores_540p25.mov", 960, 540, CMTimeMake(1, 25)},
    };
    bool insert = false;
    for (const Case &c : cases) {
        VEEngine *engine = [self makeEngine];
        VEAssetInfo *asset = [self importURL:[self mediaURL:c.file] into:engine];
        // Insert and overwrite alike (every other case), each in its own undo step.
        insert = !insert;
        const VETrackID v1 = [self videoTrack:engine index:0];
        VEEditResult *placed =
            insert ? [engine insertAsset:asset.assetID
                                  atTime:kCMTimeZero
                              videoTrack:v1
                              audioTrack:0
                                sourceIn:kCMTimeInvalid
                               sourceOut:kCMTimeInvalid]
                   : [engine overwriteAsset:asset.assetID
                                     atTime:kCMTimeZero
                                 videoTrack:v1
                                 audioTrack:0
                                   sourceIn:kCMTimeInvalid
                                  sourceOut:kCMTimeInvalid];
        XCTAssertTrue(placed.ok, @"%s: %@", c.file, placed.message);
        XCTAssertEqualObjects(engine.undoActionName, insert ? @"Insert" : @"Overwrite");
        [self assertSequence:engine
                       width:c.width
                      height:c.height
               frameDuration:c.frameDuration
                  configured:YES
                     context:@(c.file)];
    }
}

- (void)testAnOpenedProjectNeverAdopts {
    // A version 7 project saved configured, and a version 6 project (no "configured"): placing a clip
    // of another size and rate leaves their settings as they are. A project saved unconfigured (only a
    // still on it) opens unconfigured and unchanged; its first video clip then sets it, as in a new one.
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *movie = [self importURL:[self mediaURL:"hevc_720p2997.mov"] into:engine];
    VEAssetInfo *still = [self importURL:[self mediaURL:"still.png"] into:engine];
    XCTAssertTrue([engine overwriteAsset:still.assetID
                                  atTime:kCMTimeZero
                              videoTrack:[self videoTrack:engine index:0]
                              audioTrack:0
                                sourceIn:kCMTimeInvalid
                               sourceOut:kCMTimeInvalid]
                      .ok);
    NSURL *unconfiguredURL = [_scratch URLByAppendingPathComponent:@"unconfigured.framewright"];
    NSError *error = nil;
    XCTAssertTrue([engine saveProjectToURL:unconfiguredURL error:&error], @"%@", error);
    XCTAssertTrue([engine.projectJSON containsString:@"\"configured\": false"]);

    VEEditResult *settings = [engine applySequenceSettings:[[VESequenceSettings alloc] initWithWidth:1920
                                                                                              height:1080
                                                                                       frameDuration:CMTimeMake(1, 30)
                                                                                     audioSampleRate:48000
                                                                            sharpenScaledDownSources:YES]];
    XCTAssertTrue(settings.ok, @"%@", settings.message);
    XCTAssertTrue(engine.sequence.configured);
    NSURL *configuredURL = [_scratch URLByAppendingPathComponent:@"configured.framewright"];
    XCTAssertTrue([engine saveProjectToURL:configuredURL error:&error], @"%@", error);

    // Version 6: the configured project's file with its version 7 keys taken out.
    NSData *data = [NSData dataWithContentsOfURL:configuredURL];
    NSMutableDictionary *document = [NSJSONSerialization JSONObjectWithData:data
                                                                    options:NSJSONReadingMutableContainers
                                                                      error:&error];
    XCTAssertNotNil(document, @"%@", error);
    document[@"schemaVersion"] = @6;
    [document removeObjectForKey:@"sharpenScaledDownSources"];
    for (NSMutableDictionary *sequence in document[@"sequences"]) {
        [sequence removeObjectForKey:@"configured"];
    }
    NSURL *v6URL = [_scratch URLByAppendingPathComponent:@"v6.framewright"];
    XCTAssertTrue([[NSJSONSerialization dataWithJSONObject:document options:0 error:&error] writeToURL:v6URL
                                                                                                atomically:YES]);

    for (NSURL *url in @[ configuredURL, v6URL ]) {
        VEEngine *opened = [self makeEngine];
        XCTAssertTrue([opened openProjectAtURL:url error:&error], @"%@: %@", url.lastPathComponent, error);
        [self assertSequence:opened
                       width:1920
                      height:1080
               frameDuration:CMTimeMake(1, 30)
                  configured:YES
                     context:url.lastPathComponent];
        XCTAssertTrue(opened.sharpenScaledDownSources);
        VEEditResult *placed = [opened overwriteAsset:movie.assetID
                                               atTime:seconds(6)
                                           videoTrack:[self videoTrack:opened index:1]
                                           audioTrack:0
                                             sourceIn:kCMTimeInvalid
                                            sourceOut:kCMTimeInvalid];
        XCTAssertTrue(placed.ok, @"%@", placed.message);
        XCTAssertEqualObjects(placed.note, @"");
        [self assertSequence:opened
                       width:1920
                      height:1080
               frameDuration:CMTimeMake(1, 30)
                  configured:YES
                     context:[url.lastPathComponent stringByAppendingString:@" after a placement"]];
    }

    VEEngine *reopened = [self makeEngine];
    XCTAssertTrue([reopened openProjectAtURL:unconfiguredURL error:&error], @"%@", error);
    [self assertSequence:reopened
                   width:1920
                  height:1080
           frameDuration:CMTimeMake(1, 30)
              configured:NO
                 context:@"saved unconfigured, reopened"];
    XCTAssertFalse(reopened.isDirty, @"opening changed nothing");
    XCTAssertTrue([reopened overwriteAsset:movie.assetID
                                    atTime:seconds(6)
                                videoTrack:[self videoTrack:reopened index:1]
                                audioTrack:0
                                  sourceIn:kCMTimeInvalid
                                 sourceOut:kCMTimeInvalid]
                      .ok);
    [self assertSequence:reopened
                   width:1280
                  height:720
           frameDuration:CMTimeMake(1001, 30000)
              configured:YES
                 context:@"its first video clip"];
}

// MARK: - The Sequence Settings sheet's calls

- (void)testPreviewAndApplySequenceSettings {
    VEEngine *engine = [self makeEngine];
    VESequenceSettings *current = engine.sequenceSettings;
    XCTAssertEqual(current.width, 1920);
    XCTAssertTrue(current.sharpenScaledDownSources);
    NSArray<NSValue *> *rates = VEEngine.standardSequenceFrameDurations;
    XCTAssertEqual(rates.count, 8u);
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSValue *rate in rates) {
        [names addObject:[VEEngine nameForFrameDuration:rate.CMTimeValue]];
    }
    XCTAssertEqualObjects(names, (@[ @"23.976", @"24", @"25", @"29.97", @"30", @"50", @"59.94", @"60" ]));

    auto settings = ^(NSInteger width, NSInteger height, CMTime frameDuration, NSInteger rate, BOOL sharpen) {
        return [[VESequenceSettings alloc] initWithWidth:width
                                                  height:height
                                           frameDuration:frameDuration
                                         audioSampleRate:rate
                                sharpenScaledDownSources:sharpen];
    };
    // An empty sequence: no confirmation, the sentences still say what changes.
    VESequenceSettingsPreview *empty = [engine previewSequenceSettings:settings(3840, 2160, CMTimeMake(1, 25), 48000, YES)];
    XCTAssertNil(empty.refusal);
    XCTAssertTrue(empty.changesSettings);
    XCTAssertFalse(empty.needsConfirmation);
    XCTAssertTrue(anyContains(empty.changes, @"The frame becomes 3840×2160 (from 1920×1080)."), @"%@", empty.changes);
    XCTAssertTrue(anyContains(empty.changes, @"The frame rate becomes 25 fps (from 30)."), @"%@", empty.changes);
    XCTAssertTrue(anyContains(empty.changes, @"The sequence keeps these settings"), @"%@", empty.changes);

    VEAssetInfo *movie = [self importURL:[self mediaURL:"h264_1080p30.mp4"] into:engine];
    VEEditResult *placed = [engine overwriteAsset:movie.assetID
                                           atTime:kCMTimeZero
                                       videoTrack:[self videoTrack:engine index:0]
                                       audioTrack:[self audioTrack:engine index:0]
                                         sourceIn:kCMTimeInvalid
                                        sourceOut:seconds(1.5)];
    XCTAssertTrue(placed.ok, @"%@", placed.message);
    XCTAssertTrue(engine.sequence.configured);
    const VEClipID clip = placed.createdIDs[0].longLongValue;
    VEVideoParams params = [engine clipInfo:clip].videoParams;
    params.x = 100;
    params.scale = 0.5;
    XCTAssertTrue([engine setVideoParams:params forClip:clip].ok);

    // Nothing differs: nothing to do.
    VESequenceSettingsPreview *same = [engine previewSequenceSettings:engine.sequenceSettings];
    XCTAssertFalse(same.changesSettings);
    XCTAssertFalse(same.needsConfirmation);
    XCTAssertEqual(same.changes.count, 0u);

    // Refusals: an odd width, a rate outside 1...240 fps.
    XCTAssertTrue([[engine previewSequenceSettings:settings(1919, 1080, CMTimeMake(1, 30), 48000, YES)].refusal
        containsString:@"even"]);
    XCTAssertTrue([[engine previewSequenceSettings:settings(1920, 1080, CMTimeMake(1, 480), 48000, YES)].refusal
        containsString:@"frame rate"]);
    VEEditResult *refused = [engine applySequenceSettings:settings(1919, 1080, CMTimeMake(1, 30), 48000, YES)];
    XCTAssertFalse(refused.ok);
    XCTAssertEqual(engine.sequence.width, 1920);

    // 4K at 25 fps: a confirmation naming the rescale and the moved edges.
    VESequenceSettingsPreview *preview = [engine previewSequenceSettings:settings(3840, 2160, CMTimeMake(1, 25), 44100, NO)];
    XCTAssertNil(preview.refusal);
    XCTAssertTrue(preview.needsConfirmation);
    XCTAssertEqual(preview.clipsRescaled, 1);
    XCTAssertEqual(preview.clipsRetimed, 2); // the picture and its sound: 1.5 s is 37.5 frames at 25
    XCTAssertTrue(anyContains(preview.changes, @"positions, sizes and Motion spans are scaled ×2 with it"), @"%@",
                  preview.changes);
    XCTAssertTrue(anyContains(preview.changes, @"2 clips move their start or end to the nearest frame"), @"%@",
                  preview.changes);
    XCTAssertTrue(anyContains(preview.changes, @"Audio is mixed and exported at 44.1 kHz (from 48 kHz)."), @"%@",
                  preview.changes);
    XCTAssertTrue(anyContains(preview.changes, @"Scaled-down sources are no longer sharpened."), @"%@", preview.changes);
    // The preview changed nothing.
    XCTAssertEqual(engine.sequence.width, 1920);
    XCTAssertEqual([engine clipInfo:clip].videoParams.x, 100);

    const uint64_t changes = engine.changeCount;
    VEEditResult *applied = [engine applySequenceSettings:settings(3840, 2160, CMTimeMake(1, 25), 44100, NO)];
    XCTAssertTrue(applied.ok, @"%@", applied.message);
    XCTAssertGreaterThan(engine.changeCount, changes);
    XCTAssertEqualObjects(engine.undoActionName, @"Sequence Settings");
    [self assertSequence:engine width:3840 height:2160 frameDuration:CMTimeMake(1, 25) configured:YES context:@"applied"];
    XCTAssertEqual(engine.sequence.audioSampleRate, 44100);
    XCTAssertFalse(engine.sharpenScaledDownSources);
    XCTAssertEqual([engine clipInfo:clip].videoParams.x, 200);
    XCTAssertEqual([engine clipInfo:clip].videoParams.scale, 0.5);
    XCTAssertEqual(CMTimeCompare([engine clipInfo:clip].timelineEnd, CMTimeMake(38, 25)), 0);
    // One undo step takes all of it back.
    XCTAssertTrue([engine undo]);
    [self assertSequence:engine width:1920 height:1080 frameDuration:CMTimeMake(1, 30) configured:YES context:@"undone"];
    XCTAssertEqual(engine.sequence.audioSampleRate, 48000);
    XCTAssertTrue(engine.sharpenScaledDownSources);
    XCTAssertEqual([engine clipInfo:clip].videoParams.x, 100);
    XCTAssertEqual(CMTimeCompare([engine clipInfo:clip].timelineEnd, seconds(1.5)), 0);

    // The sharpening alone: no confirmation, its own undo step.
    VESequenceSettingsPreview *sharpenOnly =
        [engine previewSequenceSettings:settings(1920, 1080, CMTimeMake(1, 30), 48000, NO)];
    XCTAssertTrue(sharpenOnly.changesSettings);
    XCTAssertFalse(sharpenOnly.needsConfirmation);
    XCTAssertEqualObjects(sharpenOnly.changes, @[ @"Scaled-down sources are no longer sharpened." ]);
    XCTAssertTrue([engine setSharpenScaledDownSources:NO].ok);
    XCTAssertFalse(engine.sharpenScaledDownSources);
    XCTAssertFalse(engine.sequenceSettings.sharpenScaledDownSources);
    XCTAssertTrue([engine.projectJSON containsString:@"\"sharpenScaledDownSources\": false"]);
    XCTAssertTrue([engine undo]);
    XCTAssertTrue(engine.sharpenScaledDownSources);
}

// MARK: - Export

- (void)testA4KSequenceExportsAtItsOwnSizeAndTheSequenceSampleRate {
    // A 4K "screen recording" (small text): the new project adopts 3840x2160, and the export's
    // "Sequence size" is 3840x2160.
    NSURL *movieURL = [_scratch URLByAppendingPathComponent:@"text4k.mov"];
    const std::string written = ve::test::writeTextCardMovie(movieURL.path.UTF8String, 3840, 2160, 20, 30,
                                                             40'000'000, 22, false, 5);
    XCTAssertTrue(written.empty(), @"%s", written.c_str());
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *movie = [self importURL:movieURL into:engine];
    XCTAssertEqual(movie.width, 3840);
    VEEditResult *placed = [engine overwriteAsset:movie.assetID
                                           atTime:kCMTimeZero
                                       videoTrack:[self videoTrack:engine index:0]
                                       audioTrack:0
                                         sourceIn:kCMTimeInvalid
                                        sourceOut:kCMTimeInvalid];
    XCTAssertTrue(placed.ok, @"%@", placed.message);
    [self assertSequence:engine width:3840 height:2160 frameDuration:CMTimeMake(1, 30) configured:YES context:@"4K"];
    // Sound for the sample rate: the sequence at 44.1 kHz.
    VEAssetInfo *tone = [self importURL:[self mediaURL:"audio_only.wav"] into:engine];
    XCTAssertTrue([engine overwriteAsset:tone.assetID
                                  atTime:kCMTimeZero
                              videoTrack:0
                              audioTrack:[self audioTrack:engine index:0]
                                sourceIn:kCMTimeInvalid
                               sourceOut:CMTimeMake(20, 30)]
                      .ok);
    VESequenceSettings *s = engine.sequenceSettings;
    XCTAssertTrue([engine applySequenceSettings:[[VESequenceSettings alloc] initWithWidth:s.width
                                                                                    height:s.height
                                                                             frameDuration:s.frameDuration
                                                                           audioSampleRate:44100
                                                                  sharpenScaledDownSources:YES]]
                      .ok);

    VEExportSettings *settings = [VEExportSettings defaultSettingsForPreset:VEExportPresetHEVC];
    XCTAssertEqual(settings.resolution, VEExportResolutionSequence);
    const CGSize size = [engine exportSizeForSettings:settings];
    XCTAssertEqual(size.width, 3840);
    XCTAssertEqual(size.height, 2160);
    NSURL *output = [_scratch URLByAppendingPathComponent:@"4k.mp4"];
    XCTestExpectation *done = [self expectationWithDescription:@"export"];
    __block VEExportSummary *summary = nil;
    NSError *error = nil;
    VEExportHandle *handle = [engine beginExportWithSettings:settings
                                                   outputURL:output
                                                    progress:nil
                                                  completion:^(VEExportSummary *result, NSError *failure) {
                                                      XCTAssertNil(failure);
                                                      summary = result;
                                                      [done fulfill];
                                                  }
                                                       error:&error];
    XCTAssertNotNil(handle, @"%@", error);
    [self waitForExpectations:@[ done ] timeout:180];
    XCTAssertEqual(summary.width, 3840);
    XCTAssertEqual(summary.height, 2160);
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:output options:nil];
    AVAssetTrack *video = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *audio = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    XCTAssertEqual(video.naturalSize.width, 3840);
    XCTAssertEqual(video.naturalSize.height, 2160);
    XCTAssertNotNil(audio);
    const AudioStreamBasicDescription *asbd =
        audio ? CMAudioFormatDescriptionGetStreamBasicDescription(
                    (__bridge CMAudioFormatDescriptionRef)audio.formatDescriptions.firstObject)
              : nullptr;
    XCTAssertTrue(asbd != nullptr);
    if (asbd != nullptr) {
        XCTAssertEqual(asbd->mSampleRate, 44100.0);
    }
}

@end
