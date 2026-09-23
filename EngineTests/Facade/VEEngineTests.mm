// VEEngine facade: versions, project lifecycle, import of the generated test media, edits
// through the facade with undo/redo, save/open with bookmarks, missing media, thumbnails and
// waveforms, notifications, hardware caps and the program monitor frame source.

#import <Metal/Metal.h>
#import <VidEditEngine/VidEditEngine.h>
#import <XCTest/XCTest.h>

#include "../Media/BurnIn.h"
#include "../Media/TestMedia.h"

#include <string>
#include <vector>

namespace {

CMTime seconds(double s) {
    return CMTimeMakeWithSeconds(s, 600);
}

NSURL *scratchURL() {
    return [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
}

} // namespace

@interface VEEngineTestObserver : NSObject <VEEngineObserver>
@property (nonatomic) uint64_t lastChangeCount;
@property (nonatomic) NSInteger modelChanges;
@property (nonatomic) NSInteger assetChanges;
@end

@implementation VEEngineTestObserver
- (void)engine:(VEEngine *)engine modelDidChange:(uint64_t)changeCount {
    self.lastChangeCount = changeCount;
    self.modelChanges += 1;
}
- (void)engineAssetsDidChange:(VEEngine *)engine {
    self.assetChanges += 1;
}
@end

@interface VEEngineTests : XCTestCase
@end

@implementation VEEngineTests {
    NSURL *_cacheDir;
}

- (void)setUp {
    _cacheDir = [scratchURL() URLByAppendingPathComponent:@"Caches" isDirectory:YES];
}

- (VEEngine *)makeEngine {
    return [[VEEngine alloc] initWithCacheDirectory:_cacheDir];
}

- (NSURL *)mediaURL:(const char *)file {
    std::string error;
    const std::string path = ve::test::testMediaPath(file, error);
    XCTAssertTrue(error.empty(), @"%s", error.c_str());
    return [NSURL fileURLWithPath:@(path.c_str())];
}

- (NSArray<NSURL *> *)allMediaURLs {
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    for (const ve::test::TestClip &clip : ve::test::testClips()) {
        [urls addObject:[self mediaURL:clip.file.c_str()]];
    }
    return urls;
}

/// Imports and waits (spinning the main run loop) for the completion.
- (NSArray<VEAssetInfo *> *)import:(NSArray<NSURL *> *)urls into:(VEEngine *)engine {
    XCTestExpectation *done = [self expectationWithDescription:@"import"];
    __block NSArray<VEAssetInfo *> *result = @[];
    [engine importMediaAtURLs:urls
                   completion:^(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors) {
                       XCTAssertEqual(errors.count, 0u, @"%@", errors);
                       result = assets;
                       [done fulfill];
                   }];
    [self waitForExpectations:@[ done ] timeout:60];
    return result;
}

- (VEAssetInfo *)importOne:(const char *)file into:(VEEngine *)engine {
    NSArray<VEAssetInfo *> *assets = [self import:@[ [self mediaURL:file] ] into:engine];
    XCTAssertEqual(assets.count, 1u);
    return assets.firstObject;
}

- (VETrackID)videoTrack:(VEEngine *)engine index:(NSUInteger)index {
    return engine.sequence.videoTrackIDs[index].longLongValue;
}

- (VETrackID)audioTrack:(VEEngine *)engine index:(NSUInteger)index {
    return engine.sequence.audioTrackIDs[index].longLongValue;
}

// MARK: - Versions (framework plumbing)

- (void)testVersionMatchesFrameworkBundle {
    NSString *version = VEEngine.engineVersion;
    XCTAssertGreaterThan(version.length, 0u);
    NSBundle *bundle = [NSBundle bundleForClass:VEEngine.class];
    XCTAssertEqualObjects(version, [bundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);
}

- (void)testFFmpegIsLoadedAndLGPL {
    // Exercises the @rpath resolution of the FFmpeg dylibs from the framework.
    XCTAssertTrue([VEEngine.ffmpegVersion hasPrefix:@"7.1"], @"%@", VEEngine.ffmpegVersion);
    XCTAssertTrue([VEEngine.ffmpegLicense containsString:@"LGPL"], @"%@", VEEngine.ffmpegLicense);
    XCTAssertFalse([VEEngine.ffmpegLicense containsString:@"nonfree"], @"%@", VEEngine.ffmpegLicense);
}

- (void)testCompositorShadersAreInFrameworkLibrary {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    XCTAssertNotNil(device);
    NSError *error = nil;
    id<MTLLibrary> library = [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:VEEngine.class] error:&error];
    XCTAssertNotNil(library, @"%@", error);

    // The layer pipeline: vertex function plus the fragment function specialised by its three
    // function constants (source A is YCbCr, has a dissolve partner, partner is YCbCr).
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"ve_layer_vertex"];
    XCTAssertNotNil(desc.vertexFunction);
    MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
    const bool yes = true;
    [constants setConstantValue:&yes type:MTLDataTypeBool atIndex:0];
    [constants setConstantValue:&yes type:MTLDataTypeBool atIndex:1];
    [constants setConstantValue:&yes type:MTLDataTypeBool atIndex:2];
    desc.fragmentFunction = [library newFunctionWithName:@"ve_layer_fragment" constantValues:constants error:&error];
    XCTAssertNotNil(desc.fragmentFunction, @"%@", error);
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    XCTAssertNotNil(pipeline, @"%@", error);

    // The compute kernels: export conversions and the minification premultiply.
    for (NSString *name in @[ @"ve_convert_to_bgra", @"ve_convert_to_420", @"ve_premultiply" ]) {
        id<MTLFunction> kernel = [library newFunctionWithName:name];
        XCTAssertNotNil(kernel, @"%@", name);
        if (kernel != nil) {
            XCTAssertNotNil([device newComputePipelineStateWithFunction:kernel error:&error], @"%@: %@", name, error);
        }
    }
    // The phase-0 passthrough shaders are gone.
    XCTAssertNil([library newFunctionWithName:@"ve_passthrough_vertex"]);
    XCTAssertNil([library newFunctionWithName:@"ve_passthrough_fragment"]);
}

// MARK: - Project

- (void)testNewProjectHasDefaultSequence {
    VEEngine *engine = [self makeEngine];
    VESequenceInfo *sequence = engine.sequence;
    XCTAssertEqual(sequence.width, 1920);
    XCTAssertEqual(sequence.height, 1080);
    XCTAssertEqual(CMTimeCompare(sequence.frameDuration, CMTimeMake(1, 30)), 0);
    XCTAssertEqual(sequence.videoTrackIDs.count, 2u);
    XCTAssertEqual(sequence.audioTrackIDs.count, 2u);
    XCTAssertEqual(CMTimeCompare(sequence.duration, kCMTimeZero), 0);
    XCTAssertFalse(engine.isDirty);
    XCTAssertFalse(engine.canUndo);
    XCTAssertNil(engine.projectURL);
    XCTAssertEqual(engine.allAssets.count, 0u);
    XCTAssertEqual(engine.allTracks.count, 4u);
    VETrackInfo *v1 = [engine trackInfo:[self videoTrack:engine index:0]];
    XCTAssertEqualObjects(v1.name, @"V1");
    XCTAssertEqual(v1.kind, VETrackKindVideo);

    const uint64_t before = engine.changeCount;
    [engine newProjectWithName:@"Second"];
    XCTAssertGreaterThan(engine.changeCount, before, @"the model version keeps increasing across projects");
    XCTAssertEqualObjects(engine.projectName, @"Second");
}

// MARK: - Import

- (void)testImportAllTestMediaReportsAssetInfo {
    VEEngine *engine = [self makeEngine];
    NSArray<NSURL *> *urls = [self allMediaURLs];
    XCTAssertEqual(urls.count, 7u);

    // Heartbeat on the main queue: the longest gap between beats is the worst main-thread stall.
    __block CFAbsoluteTime lastBeat = CFAbsoluteTimeGetCurrent();
    __block double worstGap = 0;
    NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:0.002
                                                     repeats:YES
                                                       block:^(NSTimer *) {
                                                           const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
                                                           worstGap = std::max(worstGap, now - lastBeat);
                                                           lastBeat = now;
                                                       }];
    const CFAbsoluteTime callStart = CFAbsoluteTimeGetCurrent();
    XCTestExpectation *done = [self expectationWithDescription:@"import"];
    __block NSArray<VEAssetInfo *> *assets = @[];
    [engine importMediaAtURLs:urls
                   completion:^(NSArray<VEAssetInfo *> *imported, NSArray<NSError *> *errors) {
                       XCTAssertEqual(errors.count, 0u, @"%@", errors);
                       assets = imported;
                       [done fulfill];
                   }];
    const double callSeconds = CFAbsoluteTimeGetCurrent() - callStart;
    [self waitForExpectations:@[ done ] timeout:60];
    [timer invalidate];

    // Main thread budget: the synchronous call plus the bookkeeping on the main thread.
    const double mainSeconds = callSeconds + engine.mainThreadImportSeconds;
    NSLog(@"import of 7 files: main thread %.2f ms (call %.2f ms), worst main-queue gap %.1f ms", mainSeconds * 1000,
          callSeconds * 1000, worstGap * 1000);
    XCTAssertLessThan(mainSeconds, 0.050, @"importing 7 files must not block the main thread for 50 ms");

    XCTAssertEqual(assets.count, 7u);
    XCTAssertEqual(engine.allAssets.count, 7u);
    XCTAssertTrue(engine.canUndo);
    XCTAssertEqualObjects(engine.undoActionName, @"Import");
    NSMutableDictionary<NSString *, VEAssetInfo *> *byName = [NSMutableDictionary dictionary];
    for (VEAssetInfo *a in assets) {
        byName[a.name] = a;
        XCTAssertGreaterThan(a.assetID, 0);
        XCTAssertGreaterThan(a.codecName.length, 0u, @"%@", a);
        XCTAssertGreaterThan(a.backendName.length, 0u, @"%@", a);
        XCTAssertGreaterThan(a.routingReason.length, 0u, @"%@", a);
        XCTAssertFalse(a.isMissing);
        XCTAssertEqual(a.useCount, 0);
    }
    for (const ve::test::TestClip &clip : ve::test::testClips()) {
        VEAssetInfo *a = byName[@(clip.file.c_str())];
        XCTAssertNotNil(a, @"%s", clip.file.c_str());
        if (a == nil) {
            continue;
        }
        XCTAssertEqualObjects(a.container, @(clip.container.c_str()), @"%s", clip.file.c_str());
        XCTAssertEqual(a.hasAudio, clip.hasAudio(), @"%s", clip.file.c_str());
        XCTAssertEqual(a.hasVideo, clip.hasVideo() || clip.isStill(), @"%s", clip.file.c_str());
        if (clip.isStill()) {
            XCTAssertEqual(a.kind, VEAssetKindStill);
            XCTAssertEqual(a.width, clip.width);
            XCTAssertEqual(a.height, clip.height);
            XCTAssertEqualObjects(a.fpsString, @"");
        } else if (clip.hasVideo()) {
            XCTAssertEqual(a.kind, clip.hasAudio() ? VEAssetKindAudioVideo : VEAssetKindVideo);
            XCTAssertEqual(a.width, clip.width);
            XCTAssertEqual(a.height, clip.height);
            XCTAssertEqual(CMTimeCompare(a.frameDuration, clip.frameDuration), 0, @"%s", clip.file.c_str());
            XCTAssertEqualWithAccuracy(CMTimeGetSeconds(a.duration), CMTimeGetSeconds(clip.videoDuration()), 0.1,
                                       @"%s", clip.file.c_str());
            XCTAssertFalse(a.isVFR);
            XCTAssertEqualObjects(a.backendName, @"apple", @"%s", clip.file.c_str());
        } else {
            XCTAssertEqual(a.kind, VEAssetKindAudio);
            XCTAssertEqualWithAccuracy(CMTimeGetSeconds(a.duration), clip.audioSeconds, 0.1);
        }
        if (clip.hasAudio()) {
            XCTAssertEqual(a.sampleRate, 48000, @"%s", clip.file.c_str());
            XCTAssertGreaterThan(a.channels, 0);
            XCTAssertGreaterThan(a.audioCodecName.length, 0u);
        }
    }
    XCTAssertEqualObjects(byName[@"h264_1080p30.mp4"].fpsString, @"30");
    XCTAssertEqualObjects(byName[@"hevc_720p2997.mov"].fpsString, @"29.97");
    XCTAssertEqualObjects(byName[@"prores_540p25.mov"].fpsString, @"25");
    XCTAssertEqualObjects(byName[@"h264_1080p30.mp4"].codecName, @"H.264");
    VEHardwareCaps *caps = engine.hardwareCaps;
    for (VECodecCapability *c in caps.codecs) {
        if ([c.name isEqualToString:@"h264"]) {
            XCTAssertEqual(byName[@"h264_1080p30.mp4"].hardwareDecode, c.hardwareDecode);
        }
    }

    // Importing the same file again reports the existing asset and adds nothing.
    const uint64_t changes = engine.changeCount;
    NSArray<VEAssetInfo *> *again = [self import:@[ urls[0] ] into:engine];
    XCTAssertEqual(again.count, 1u);
    XCTAssertEqual(engine.allAssets.count, 7u);
    XCTAssertEqual(engine.changeCount, changes);

    // Undo removes the whole import; redo brings back the same ids.
    const VEAssetID firstID = engine.allAssets.firstObject.assetID;
    XCTAssertTrue([engine undo]);
    XCTAssertEqual(engine.allAssets.count, 0u);
    XCTAssertTrue([engine redo]);
    XCTAssertEqual(engine.allAssets.count, 7u);
    XCTAssertEqual(engine.allAssets.firstObject.assetID, firstID);
}

- (void)testImportReportsUnreadableFiles {
    VEEngine *engine = [self makeEngine];
    NSURL *bogus = [scratchURL() URLByAppendingPathComponent:@"not-media.mov"];
    [[@"hello" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:bogus atomically:YES];
    NSURL *absent = [scratchURL() URLByAppendingPathComponent:@"absent.mov"];
    XCTestExpectation *done = [self expectationWithDescription:@"import"];
    [engine importMediaAtURLs:@[ bogus, absent, [self mediaURL:"audio_only.wav"] ]
                   completion:^(NSArray<VEAssetInfo *> *assets, NSArray<NSError *> *errors) {
                       XCTAssertEqual(assets.count, 1u);
                       XCTAssertEqual(errors.count, 2u);
                       for (NSError *e in errors) {
                           XCTAssertEqualObjects(e.domain, VEEngineErrorDomain);
                           XCTAssertGreaterThan(e.localizedDescription.length, 0u);
                       }
                       [done fulfill];
                   }];
    [self waitForExpectations:@[ done ] timeout:60];
}

// MARK: - Edits

- (void)testEditRoundTripWithUndoRedo {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *h264 = [self importOne:"h264_1080p30.mp4" into:engine];
    VEAssetInfo *prores = [self importOne:"prores_540p25.mov" into:engine];
    const VETrackID v1 = [self videoTrack:engine index:0];
    const VETrackID v2 = [self videoTrack:engine index:1];
    const VETrackID a1 = [self audioTrack:engine index:0];
    NSString *emptyJSON = engine.projectJSON;
    NSMutableArray<NSString *> *states = [NSMutableArray arrayWithObject:emptyJSON];

    // Insert 0...10 s on V1/A1, linked.
    VEEditResult *r = [engine insertAsset:h264.assetID
                                   atTime:kCMTimeZero
                               videoTrack:v1
                               audioTrack:a1
                                 sourceIn:kCMTimeInvalid
                                sourceOut:kCMTimeInvalid];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual(r.createdIDs.count, 2u);
    const VEClipID video = r.createdIDs[0].longLongValue;
    const VEClipID audio = r.createdIDs[1].longLongValue;
    VEClipInfo *clip = [engine clipInfo:video];
    XCTAssertEqual(clip.linkedClipID, audio);
    XCTAssertEqual([engine clipInfo:audio].linkedClipID, video);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds(clip.duration), 10.0, 1e-9);
    XCTAssertEqual([engine assetInfo:h264.assetID].useCount, 2);
    XCTAssertTrue(engine.isDirty);
    [states addObject:engine.projectJSON];

    // Overwrite 1 s of ProRes (source 0.5...1.5 s) at 2 s on V1/A1: splits the h264 clips.
    r = [engine overwriteAsset:prores.assetID
                        atTime:seconds(2)
                    videoTrack:v1
                    audioTrack:a1
                      sourceIn:seconds(0.5)
                     sourceOut:seconds(1.5)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual([engine clipsOnTrack:v1].count, 3u);
    [states addObject:engine.projectJSON];

    // Move the ProRes video (and its audio) to V2 at 12 s.
    const VEClipID proresVideo = r.createdIDs[0].longLongValue;
    r = [engine moveClip:proresVideo toTrack:v2 start:seconds(12)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual([engine clipInfo:proresVideo].trackID, v2);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds([engine clipInfo:proresVideo].timelineStart), 12, 1e-9);
    [states addObject:engine.projectJSON];

    // Trim the head of the first clip to 0.5 s and its tail to 1.5 s.
    r = [engine trimClipHead:video toTime:seconds(0.5) clamp:NO];
    XCTAssertTrue(r.ok, @"%@", r.message);
    [states addObject:engine.projectJSON];
    r = [engine trimClipTail:video toTime:seconds(1.5) clamp:NO];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds([engine clipInfo:video].duration), 1.0, 1e-9);
    [states addObject:engine.projectJSON];

    // Split at 1 s: the linked audio splits too.
    r = [engine splitClip:video atTime:seconds(1)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual(r.createdIDs.count, 2u);
    [states addObject:engine.projectJSON];

    // Remove the right-hand pieces.
    r = [engine removeClips:@[ r.createdIDs[0] ]];
    XCTAssertTrue(r.ok, @"%@", r.message);
    [states addObject:engine.projectJSON];

    // Refused edits change nothing and say why.
    const uint64_t changes = engine.changeCount;
    r = [engine trimClipTail:video toTime:seconds(100) clamp:NO];
    XCTAssertFalse(r.ok);
    XCTAssertGreaterThan(r.message.length, 0u);
    XCTAssertEqual(engine.changeCount, changes);
    XCTAssertEqualObjects(engine.projectJSON, states.lastObject);

    // Undo everything, checking every intermediate state; then redo everything.
    for (NSInteger i = NSInteger(states.count) - 2; i >= 0; --i) {
        XCTAssertTrue([engine undo]);
        XCTAssertEqualObjects(engine.projectJSON, states[NSUInteger(i)], @"undo to state %ld", long(i));
    }
    XCTAssertEqualObjects(engine.undoActionName, @"Import");
    for (NSUInteger i = 1; i < states.count; ++i) {
        XCTAssertTrue([engine redo]);
        XCTAssertEqualObjects(engine.projectJSON, states[i], @"redo to state %lu", (unsigned long)i);
    }
    XCTAssertFalse(engine.canRedo);
    XCTAssertEqualObjects(engine.undoActionName, @"Delete");
}

- (void)testMultiClipMoveSplitAllAndRippleDelete {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *h264 = [self importOne:"h264_1080p30.mp4" into:engine];
    const VETrackID v1 = [self videoTrack:engine index:0];
    const VETrackID v2 = [self videoTrack:engine index:1];
    const VETrackID a1 = [self audioTrack:engine index:0];
    VEEditResult *first = [engine insertAsset:h264.assetID
                                       atTime:kCMTimeZero
                                   videoTrack:v1
                                   audioTrack:a1
                                     sourceIn:kCMTimeZero
                                    sourceOut:seconds(2)];
    VEEditResult *second = [engine insertAsset:h264.assetID
                                        atTime:seconds(2)
                                    videoTrack:v1
                                    audioTrack:a1
                                      sourceIn:seconds(4)
                                     sourceOut:seconds(6)];
    XCTAssertTrue(first.ok && second.ok);
    NSArray<NSNumber *> *all = [first.createdIDs arrayByAddingObjectsFromArray:second.createdIDs];

    // Move both pairs 1 s later (linked partners selected too: each pair moves once), one undo step.
    VEEditResult *r = [engine moveClips:all byTime:seconds(1) trackOffset:0];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds([engine clipInfo:first.createdIDs[0].longLongValue].timelineStart), 1,
                               1e-9);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds([engine clipInfo:second.createdIDs[1].longLongValue].timelineStart), 3,
                               1e-9);
    XCTAssertEqualObjects(engine.undoActionName, @"Move Clips");

    // A coalesced drag passes the total offset on every step.
    NSString *beforeDrag = engine.projectJSON;
    [engine beginCoalescingWithKey:@"drag"];
    for (int step = 1; step <= 4; ++step) {
        XCTAssertTrue([engine performInCoalescingGroup:@"drag"
                                                  edit:^VEEditResult * {
                                                      return [engine moveClips:all
                                                                        byTime:seconds(0.5 * step)
                                                                   trackOffset:0];
                                                  }]
                          .ok);
    }
    [engine endCoalescing];
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds([engine clipInfo:first.createdIDs[0].longLongValue].timelineStart), 3,
                               1e-9);
    XCTAssertTrue([engine undo]);
    XCTAssertEqualObjects(engine.projectJSON, beforeDrag);

    // Up one video track.
    r = [engine moveClips:@[ first.createdIDs[0] ] byTime:kCMTimeZero trackOffset:1];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual([engine clipInfo:first.createdIDs[0].longLongValue].trackID, v2);
    r = [engine moveClips:@[ first.createdIDs[0] ] byTime:kCMTimeZero trackOffset:1];
    XCTAssertFalse(r.ok, @"there is no V3");

    // Split everything under 3.5 s (the second pair): one step.
    r = [engine splitClips:@[] atTime:seconds(3.5)];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual(r.createdIDs.count, 2u);
    XCTAssertEqual([engine clipsOnTrack:v1].count, 2u);

    // Ripple delete the first half of the split: later clips close the gap.
    const VEClipID right = r.createdIDs[0].longLongValue;
    r = [engine rippleDeleteClips:@[ second.createdIDs[0] ]];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds([engine clipInfo:right].timelineStart), 3, 1e-9);
}

- (void)testCoalescedDragIsOneUndoStepAndCancelReverts {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *wav = [self importOne:"audio_only.wav" into:engine];
    const VETrackID a1 = [self audioTrack:engine index:0];
    VEEditResult *r = [engine insertAsset:wav.assetID
                                   atTime:kCMTimeZero
                               videoTrack:0
                               audioTrack:a1
                                 sourceIn:kCMTimeInvalid
                                sourceOut:kCMTimeInvalid];
    XCTAssertTrue(r.ok, @"%@", r.message);
    const VEClipID clip = r.createdIDs[0].longLongValue;
    NSString *before = engine.projectJSON;

    [engine beginCoalescingWithKey:@"drag"];
    XCTAssertTrue(engine.isCoalescing);
    for (int step = 1; step <= 10; ++step) {
        XCTAssertTrue([engine performInCoalescingGroup:@"drag"
                                                  edit:^VEEditResult * {
                                                      return [engine moveClip:clip
                                                                      toTrack:a1
                                                                        start:seconds(step * 0.5)];
                                                  }]
                          .ok);
    }
    [engine endCoalescing];
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds([engine clipInfo:clip].timelineStart), 5, 1e-9);
    XCTAssertTrue([engine undo]);
    XCTAssertEqualObjects(engine.projectJSON, before, @"the whole drag is one undo step");

    [engine beginCoalescingWithKey:@"drag"];
    XCTAssertTrue([engine performInCoalescingGroup:@"drag"
                                              edit:^VEEditResult * {
                                                  return [engine moveClip:clip toTrack:a1 start:seconds(3)];
                                              }]
                      .ok);
    [engine cancelCoalescing];
    XCTAssertFalse(engine.isCoalescing);
    XCTAssertEqualObjects(engine.projectJSON, before, @"cancel reverts the drag");

    // Parameters and speed.
    VEAudioParams audio = VEAudioParamsDefault();
    audio.gainDb = -6;
    audio.fadeInDuration = seconds(1);
    XCTAssertTrue([engine setAudioParams:audio forClip:clip].ok);
    XCTAssertEqual([engine clipInfo:clip].audioParams.gainDb, -6);
    XCTAssertTrue([engine setSpeed:2 forClip:clip].ok);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds([engine clipInfo:clip].duration), 5, 1e-9);
    XCTAssertEqualObjects(engine.undoActionName, @"Change Speed");
}

- (void)testTracksTransitionsAndLinks {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *h264 = [self importOne:"h264_1080p30.mp4" into:engine];
    const VETrackID v1 = [self videoTrack:engine index:0];
    VEEditResult *a = [engine insertAsset:h264.assetID
                                   atTime:kCMTimeZero
                               videoTrack:v1
                               audioTrack:0
                                 sourceIn:kCMTimeZero
                                sourceOut:seconds(4)];
    VEEditResult *b = [engine insertAsset:h264.assetID
                                   atTime:seconds(4)
                               videoTrack:v1
                               audioTrack:0
                                 sourceIn:seconds(5)
                                sourceOut:seconds(9)];
    XCTAssertTrue(a.ok && b.ok);
    VEEditResult *t = [engine addTransitionFromClip:a.createdIDs[0].longLongValue
                                             toClip:b.createdIDs[0].longLongValue
                                           duration:seconds(1)];
    XCTAssertTrue(t.ok, @"%@", t.message);
    XCTAssertEqual(engine.sequence.transitions.count, 1u);
    const VETransitionID transition = t.createdIDs[0].longLongValue;
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds([engine transitionInfo:transition].start), 3.5, 1e-9);
    XCTAssertTrue([engine setDuration:seconds(2) forTransition:transition].ok);
    XCTAssertTrue([engine removeTransition:transition].ok);
    XCTAssertEqual(engine.sequence.transitions.count, 0u);

    VEEditResult *added = [engine addTrackOfKind:VETrackKindAudio name:nil];
    XCTAssertTrue(added.ok);
    const VETrackID a3 = added.createdIDs[0].longLongValue;
    XCTAssertEqualObjects([engine trackInfo:a3].name, @"A3");
    XCTAssertTrue([engine setTrack:a3 muted:YES].ok);
    XCTAssertTrue([engine setTrack:a3 solo:YES].ok);
    XCTAssertTrue([engine renameTrack:a3 to:@"Music"].ok);
    VETrackInfo *info = [engine trackInfo:a3];
    XCTAssertTrue(info.muted && info.solo);
    XCTAssertEqualObjects(info.name, @"Music");
    XCTAssertTrue([engine setTrack:v1 locked:YES].ok);
    XCTAssertFalse([engine removeClips:@[ a.createdIDs[0] ]].ok, @"locked track");
    XCTAssertTrue([engine setTrack:v1 locked:NO].ok);

    // Link the video clip with a new audio clip; unlink again.
    VEAssetInfo *wav = [self importOne:"audio_only.wav" into:engine];
    VEEditResult *music = [engine insertAsset:wav.assetID
                                       atTime:kCMTimeZero
                                   videoTrack:0
                                   audioTrack:a3
                                     sourceIn:kCMTimeZero
                                    sourceOut:seconds(4)];
    XCTAssertTrue(music.ok);
    XCTAssertTrue([engine linkClip:a.createdIDs[0].longLongValue withClip:music.createdIDs[0].longLongValue].ok);
    XCTAssertEqual([engine clipInfo:a.createdIDs[0].longLongValue].linkedClipID, music.createdIDs[0].longLongValue);
    XCTAssertTrue([engine unlinkClip:a.createdIDs[0].longLongValue].ok);
    XCTAssertEqual([engine clipInfo:a.createdIDs[0].longLongValue].linkedClipID, 0);

    XCTAssertTrue([engine removeTrack:a3].ok);
    XCTAssertNil([engine trackInfo:a3]);
}

- (void)testRemoveAssetRefusedWhileUsed {
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *wav = [self importOne:"audio_only.wav" into:engine];
    VEEditResult *r = [engine insertAsset:wav.assetID
                                   atTime:kCMTimeZero
                               videoTrack:0
                               audioTrack:[self audioTrack:engine index:0]
                                 sourceIn:kCMTimeInvalid
                                sourceOut:kCMTimeInvalid];
    XCTAssertTrue(r.ok);
    VEEditResult *removal = [engine removeAsset:wav.assetID];
    XCTAssertFalse(removal.ok);
    XCTAssertTrue([removal.message containsString:@"used by 1 clip"], @"%@", removal.message);
    XCTAssertTrue([engine removeClips:r.createdIDs].ok);
    XCTAssertTrue([engine removeAsset:wav.assetID].ok);
    XCTAssertEqual(engine.allAssets.count, 0u);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual(engine.allAssets.count, 1u);
    XCTAssertEqual(engine.allAssets.firstObject.assetID, wav.assetID);
}

// MARK: - Save / open

- (void)testSaveThenOpenRestoresProjectAndResolvesAssets {
    VEEngine *engine = [self makeEngine];
    NSArray<VEAssetInfo *> *assets = [self import:[self allMediaURLs] into:engine];
    XCTAssertEqual(assets.count, 7u);
    for (VEAssetInfo *asset in assets) {
        VEEditResult *r = [engine insertAsset:asset.assetID
                                       atTime:engine.sequence.duration
                                   videoTrack:asset.hasVideo ? [self videoTrack:engine index:0] : 0
                                   audioTrack:asset.hasAudio ? [self audioTrack:engine index:0] : 0
                                     sourceIn:kCMTimeInvalid
                                    sourceOut:kCMTimeInvalid];
        XCTAssertTrue(r.ok, @"%@: %@", asset.name, r.message);
    }
    NSURL *url = [scratchURL() URLByAppendingPathComponent:@"Round Trip.videdit"];
    NSError *error = nil;
    XCTAssertTrue([engine saveProjectToURL:url error:&error], @"%@", error);
    XCTAssertFalse(engine.isDirty);
    XCTAssertEqualObjects(engine.projectURL, url);
    XCTAssertEqualObjects(engine.projectName, @"Round Trip");
    NSString *json = engine.projectJSON;

    // The file holds the model JSON plus one bookmark per asset.
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSDictionary *file = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    XCTAssertEqual([file[@"assetBookmarks"] count], 7u);

    VEEngine *reopened = [self makeEngine];
    XCTestExpectation *probed = [self expectationForNotification:VEEngineAssetsDidChangeNotification
                                                          object:reopened
                                                         handler:^BOOL(NSNotification *) {
                                                             for (VEAssetInfo *a in reopened.allAssets) {
                                                                 if (a.codecName.length == 0) {
                                                                     return NO;
                                                                 }
                                                             }
                                                             return reopened.allAssets.count == 7;
                                                         }];
    XCTAssertTrue([reopened openProjectAtURL:url error:&error], @"%@", error);
    XCTAssertEqualObjects(reopened.projectJSON, json);
    XCTAssertEqual(reopened.missingAssetIDs.count, 0u);
    XCTAssertFalse(reopened.isDirty);
    XCTAssertFalse(reopened.canUndo);
    [self waitForExpectations:@[ probed ] timeout:60];
    XCTAssertEqualObjects([reopened assetInfo:assets[0].assetID].codecName, assets[0].codecName);

    // Re-saving an unchanged project reproduces the file byte for byte.
    NSURL *copy = [scratchURL() URLByAppendingPathComponent:@"Copy.videdit"];
    XCTAssertTrue([reopened saveProjectToURL:copy error:&error], @"%@", error);
    XCTAssertEqualObjects([NSData dataWithContentsOfURL:copy], data);

    // A broken file is refused and the open project is kept.
    NSURL *broken = [scratchURL() URLByAppendingPathComponent:@"Broken.videdit"];
    [[@"{\"schemaVersion\": 1" dataUsingEncoding:NSUTF8StringEncoding] writeToURL:broken atomically:YES];
    XCTAssertFalse([reopened openProjectAtURL:broken error:&error]);
    XCTAssertEqual(error.code, VEEngineErrorInvalidProject);
    XCTAssertEqualObjects(reopened.projectJSON, json);
}

- (void)testMissingAssetIsReportedOnOpen {
    VEEngine *engine = [self makeEngine];
    NSURL *dir = scratchURL();
    NSURL *copy = [dir URLByAppendingPathComponent:@"vanishing.wav"];
    NSError *error = nil;
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:[self mediaURL:"audio_only.wav"] toURL:copy error:&error],
                  @"%@", error);
    VEAssetInfo *wav = [self importOne:"audio_only.wav" into:engine];
    VEAssetInfo *vanishing = [self import:@[ copy ] into:engine].firstObject;
    XCTAssertNotNil(vanishing);
    NSURL *url = [dir URLByAppendingPathComponent:@"Missing.videdit"];
    XCTAssertTrue([engine saveProjectToURL:url error:&error], @"%@", error);
    XCTAssertTrue([NSFileManager.defaultManager removeItemAtURL:copy error:&error], @"%@", error);

    VEEngine *reopened = [self makeEngine];
    XCTAssertTrue([reopened openProjectAtURL:url error:&error], @"%@", error);
    XCTAssertEqualObjects(reopened.missingAssetIDs, @[ @(vanishing.assetID) ]);
    XCTAssertTrue([reopened assetInfo:vanishing.assetID].isMissing);
    XCTAssertFalse([reopened assetInfo:wav.assetID].isMissing);

    XCTestExpectation *thumbFails = [self expectationWithDescription:@"waveform of a missing file fails"];
    [reopened waveformForAsset:vanishing.assetID
                    completion:^(VEWaveform *waveform, NSError *waveError) {
                        XCTAssertNil(waveform);
                        XCTAssertNotNil(waveError);
                        [thumbFails fulfill];
                    }];
    [self waitForExpectations:@[ thumbFails ] timeout:10];
}

// MARK: - Thumbnails, waveforms, notifications

- (void)testThumbnailsAndWaveformsAreDelivered {
    VEEngine *engine = [self makeEngine];
    XCTestExpectation *posterReady = [self expectationForNotification:VEEngineThumbnailDidBecomeAvailableNotification
                                                               object:engine
                                                              handler:nil];
    XCTestExpectation *waveReady = [self expectationForNotification:VEEngineWaveformDidBecomeAvailableNotification
                                                             object:engine
                                                            handler:nil];
    VEAssetInfo *h264 = [self importOne:"h264_1080p30.mp4" into:engine];
    [self waitForExpectations:@[ posterReady, waveReady ] timeout:60];

    XCTestExpectation *thumb = [self expectationWithDescription:@"thumbnail"];
    [engine thumbnailForAsset:h264.assetID
                       atTime:seconds(1)
                 maxDimension:160
                   completion:^(CGImageRef image, NSError *error) {
                       XCTAssertTrue(NSThread.isMainThread);
                       XCTAssertTrue(image != NULL, @"%@", error);
                       if (image != NULL) {
                           XCTAssertEqual(CGImageGetWidth(image), 160u);
                           XCTAssertEqual(CGImageGetHeight(image), 90u);
                       }
                       [thumb fulfill];
                   }];
    XCTestExpectation *wave = [self expectationWithDescription:@"waveform"];
    [engine waveformForAsset:h264.assetID
                  completion:^(VEWaveform *waveform, NSError *error) {
                      XCTAssertNotNil(waveform, @"%@", error);
                      XCTAssertEqual(waveform.assetID, h264.assetID);
                      XCTAssertEqual(waveform.bucketsPerSecond, 100);
                      XCTAssertEqualWithAccuracy(double(waveform.bucketCount), 1000, 2);
                      XCTAssertEqual(waveform.minMaxPairs.length, NSUInteger(waveform.bucketCount) * 8);
                      const VEPeakRange peak = [waveform peakRangeFromSeconds:2 toSeconds:3];
                      XCTAssertGreaterThan(peak.maximum, 0.1f);
                      XCTAssertLessThan(peak.minimum, -0.1f);
                      [wave fulfill];
                  }];
    [self waitForExpectations:@[ thumb, wave ] timeout:60];
    XCTAssertNotNil([engine cachedWaveformForAsset:h264.assetID]);

    // Audio has no picture and stills have no audio: errors, not crashes.
    VEAssetInfo *wav = [self importOne:"audio_only.wav" into:engine];
    XCTestExpectation *noPicture = [self expectationWithDescription:@"no picture"];
    [engine thumbnailForAsset:wav.assetID
                       atTime:kCMTimeZero
                 maxDimension:64
                   completion:^(CGImageRef image, NSError *error) {
                       XCTAssertTrue(image == NULL);
                       XCTAssertNotNil(error);
                       [noPicture fulfill];
                   }];
    [self waitForExpectations:@[ noPicture ] timeout:10];
}

- (void)testModelNotificationsCarryTheChangeCount {
    VEEngine *engine = [self makeEngine];
    VEEngineTestObserver *observer = [VEEngineTestObserver new];
    [engine addObserver:observer];
    VEAssetInfo *wav = [self importOne:"audio_only.wav" into:engine];
    XCTAssertEqual(observer.lastChangeCount, engine.changeCount);
    XCTAssertGreaterThan(observer.assetChanges, 0);

    __block uint64_t notified = 0;
    id token = [NSNotificationCenter.defaultCenter addObserverForName:VEEngineModelDidChangeNotification
                                                               object:engine
                                                                queue:nil
                                                           usingBlock:^(NSNotification *note) {
                                                               notified = [note.userInfo[VEEngineChangeCountKey]
                                                                   unsignedLongLongValue];
                                                           }];
    const uint64_t before = engine.changeCount;
    VEEditResult *r = [engine insertAsset:wav.assetID
                                   atTime:kCMTimeZero
                               videoTrack:0
                               audioTrack:[self audioTrack:engine index:0]
                                 sourceIn:kCMTimeInvalid
                                sourceOut:kCMTimeInvalid];
    XCTAssertTrue(r.ok);
    XCTAssertGreaterThan(engine.changeCount, before);
    XCTAssertEqual(notified, engine.changeCount);
    XCTAssertEqual(observer.lastChangeCount, engine.changeCount);
    XCTAssertTrue([engine undo]);
    XCTAssertEqual(notified, engine.changeCount);
    const NSInteger changes = observer.modelChanges;
    XCTAssertFalse([engine moveClip:12345 toTrack:1 start:kCMTimeZero].ok);
    XCTAssertEqual(observer.modelChanges, changes, @"refused edits do not notify");
    [NSNotificationCenter.defaultCenter removeObserver:token];
    [engine removeObserver:observer];
}

- (void)testHardwareCapsArePopulated {
    VEEngine *engine = [self makeEngine];
    VEHardwareCaps *caps = engine.hardwareCaps;
    XCTAssertEqual(caps.codecs.count, 5u);
    XCTAssertGreaterThan(caps.summary.length, 0u);
    NSMutableSet<NSString *> *names = [NSMutableSet set];
    for (VECodecCapability *c in caps.codecs) {
        [names addObject:c.name];
        XCTAssertEqual(c.codecType.length, 4u);
    }
    XCTAssertEqualObjects(names, ([NSSet setWithArray:@[ @"h264", @"hevc", @"prores", @"av1", @"vp9" ]]));
#if defined(__arm64__)
    XCTAssertTrue(caps.codecs[0].hardwareDecode, @"Apple silicon decodes H.264 in hardware");
#endif
    XCTAssertEqualObjects(engine.backendNames, (@[ @"apple", @"ffmpeg" ]));
    engine.preferredBackend = @"ffmpeg";
    XCTAssertEqualObjects(engine.preferredBackend, @"ffmpeg");
    engine.preferredBackend = nil;
    XCTAssertNil(engine.preferredBackend);
    engine.frameCacheBudgetBytes = 256u << 20;
    XCTAssertEqual(engine.frameCacheBudgetBytes, 256u << 20);
}

// MARK: - Program monitor

- (void)testProgramViewShowsTheFrameAtTheRequestedTime {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) {
        XCTSkip(@"no Metal device");
    }
    VEEngine *engine = [self makeEngine];
    VEAssetInfo *clip = [self importOne:"h264_1080p30.mp4" into:engine]; // burn-in index = frame number
    VEPreviewView *view = [[VEPreviewView alloc] initWithFrame:NSMakeRect(0, 0, 480, 270) device:device error:nil];
    XCTAssertNotNil(view);
    [engine attachProgramView:view];
    VEEditResult *r = [engine insertAsset:clip.assetID
                                   atTime:kCMTimeZero
                               videoTrack:[self videoTrack:engine index:0]
                               audioTrack:0
                                 sourceIn:kCMTimeInvalid
                                sourceOut:kCMTimeInvalid];
    XCTAssertTrue(r.ok, @"%@", r.message);

    // Reads the burn-in frame index of what the view shows now (-1 if unreadable).
    auto shownIndex = [view]() -> int {
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
        // Same colour space as the image, so the pixels are copied, not colour matched.
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
    };

    for (const auto &[atSeconds, expectedFrame] : {std::pair<double, int>{1.0, 30}, std::pair<double, int>{2.5, 75}}) {
        [engine showProgramFrameAtTime:CMTimeMake(expectedFrame, 30)];
        // The frame is decoded asynchronously and then rendered by the engine; render (and wait
        // for the GPU) until the view shows it. Earlier frames (time 0 from the insert) may
        // show first, never a later one.
        int shown = -1;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
        while (shown != expectedFrame && deadline.timeIntervalSinceNow > 0) {
            XCTestExpectation *rendered = [self expectationWithDescription:@"rendered"];
            [view renderOnceWithCompletion:^(NSError *) {
                [rendered fulfill];
            }];
            [self waitForExpectations:@[ rendered ] timeout:5];
            shown = shownIndex();
            XCTAssertTrue(shown <= expectedFrame, @"showed frame %d past the requested %d", shown, expectedFrame);
        }
        XCTAssertEqual(shown, expectedFrame, @"at %.1f s", atSeconds);
        // -snapshot re-composites the current frame, so it can show the picture that landed
        // after the last completed render drew the layer without it (missingLayerCount counts
        // that render). Render once more: now nothing may be missing.
        XCTestExpectation *settled = [self expectationWithDescription:@"settled"];
        [view renderOnceWithCompletion:^(NSError *) {
            [settled fulfill];
        }];
        [self waitForExpectations:@[ settled ] timeout:5];
        XCTAssertNil(view.lastError);
        XCTAssertEqual(view.missingLayerCount, 0u);
    }
    [engine attachProgramView:nil];
}

@end
