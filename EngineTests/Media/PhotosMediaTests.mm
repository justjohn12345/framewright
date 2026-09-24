// What Photos hands over (feature request 9), imported through the facade and shown by the
// program monitor: an HEIC photo (a still), HEVC video, and an iPhone-style slow-motion clip
// (HEVC, portrait rotation, 30 fps around a 240 fps section: variable frame rate) whose pictures
// are the frames containing each layer's exact source time (playback::pictureTimeFor), at normal
// speed (the 240 fps section skips frames) and at 1/8 speed (it shows every 240 fps frame). Also
// the media folder bookmark the app stores with a project.

#import <FramewrightEngine/FramewrightEngine.h>
#import <XCTest/XCTest.h>

#include "../Playback/PlaybackTestSupport.h"
#include "TestMedia.h"

#include <string>

using namespace ve;
using namespace ve::test;

@interface PhotosMediaTests : XCTestCase
@end

@implementation PhotosMediaTests {
    NSURL *_scratch;
}

- (void)setUp {
    _scratch = [NSURL fileURLWithPath:@(scratchDirectory().c_str()) isDirectory:YES];
}

- (NSURL *)mediaURL:(const char *)file {
    std::string error;
    const std::string path = testMediaPath(file, error);
    XCTAssertFalse(path.empty(), @"%s", error.c_str());
    return [NSURL fileURLWithPath:@(path.c_str())];
}

- (void)testHEICHEVCAndSlowMotionImportThroughTheFacade {
    VEEngine *engine = [[VEEngine alloc] initWithCacheDirectory:[_scratch URLByAppendingPathComponent:@"Caches"]];
    NSArray<NSURL *> *urls = @[
        [self mediaURL:"still.heic"], [self mediaURL:"hevc_720p2997.mov"], [self mediaURL:"slowmo_hevc_portrait.mov"]
    ];
    XCTestExpectation *done = [self expectationWithDescription:@"import"];
    __block NSArray<VEAssetInfo *> *assets = @[];
    [engine importMediaAtURLs:urls
                   completion:^(NSArray<VEAssetInfo *> *imported, NSArray<NSError *> *errors) {
                       XCTAssertEqual(errors.count, 0u, @"%@", errors);
                       assets = imported;
                       [done fulfill];
                   }];
    [self waitForExpectations:@[ done ] timeout:60];
    XCTAssertEqual(assets.count, 3u);
    VEAssetInfo *photo = nil, *hevc = nil, *slowmo = nil;
    for (VEAssetInfo *asset in assets) {
        if ([asset.name isEqualToString:@"still.heic"]) {
            photo = asset;
        } else if ([asset.name isEqualToString:@"hevc_720p2997.mov"]) {
            hevc = asset;
        } else if ([asset.name isEqualToString:@"slowmo_hevc_portrait.mov"]) {
            slowmo = asset;
        }
    }
    XCTAssertNotNil(photo);
    XCTAssertNotNil(hevc);
    XCTAssertNotNil(slowmo);

    // An HEIC photo imports as a still.
    XCTAssertEqual(photo.kind, VEAssetKindStill);
    XCTAssertTrue(photo.isStill);
    XCTAssertEqualObjects(photo.codecName, @"HEIC");
    XCTAssertEqual(photo.width, 1024);
    XCTAssertEqual(photo.height, 576);

    // HEVC video with its audio, decoded in hardware where the Mac has it.
    XCTAssertEqual(hevc.kind, VEAssetKindAudioVideo);
    XCTAssertEqualObjects(hevc.codecName, @"HEVC");
    XCTAssertEqual(hevc.width, 1280);
    XCTAssertEqualObjects(hevc.backendName, @"apple");

    // The slow-motion clip: portrait (rotation applied to the display size) and flagged VFR.
    XCTAssertEqual(slowmo.kind, VEAssetKindVideo);
    XCTAssertEqualObjects(slowmo.codecName, @"HEVC");
    XCTAssertEqual(slowmo.rotationDegrees, 90);
    XCTAssertEqual(slowmo.width, 360);
    XCTAssertEqual(slowmo.height, 640);
    XCTAssertTrue(slowmo.isVFR);
    XCTAssertEqual(CMTimeCompare(slowmo.duration, CMTimeMake(5, 2)), 0);

    // Each can be placed: the still with the default still duration, the video over its media.
    const VETrackID v1 = engine.sequence.videoTrackIDs[0].longLongValue;
    VEEditResult *r = [engine insertAsset:photo.assetID atTime:kCMTimeZero videoTrack:v1 audioTrack:0
                                 sourceIn:kCMTimeInvalid sourceOut:kCMTimeInvalid];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertTrue([engine clipInfo:r.createdIDs[0].longLongValue].isStill);
    r = [engine insertAsset:slowmo.assetID atTime:CMTimeMake(5, 1) videoTrack:v1 audioTrack:0
                   sourceIn:kCMTimeInvalid sourceOut:kCMTimeInvalid];
    XCTAssertTrue(r.ok, @"%@", r.message);
    XCTAssertEqual(CMTimeCompare([engine clipInfo:r.createdIDs[0].longLongValue].duration, CMTimeMake(75, 30)), 0);
}

/// Every sequence frame shows the source frame containing its exact source time, at normal speed
/// (through the 240 fps section each sequence frame moves 8 source frames) and at 1/8 speed (the
/// 240 fps section plays every frame, the way a slow-motion edit shows it).
- (void)testSlowMotionPicturesAreTheFramesContainingTheExactSourceTime {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    const AssetId slowmo = h.importAsset("slowmo_hevc_portrait.mov");
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    const MediaAsset &asset = *h.project.findAsset(slowmo);
    XCTAssertTrue(asset.isVFR);
    XCTAssertEqual(asset.rotationDegrees, 90);
    // V1: the whole clip at speed 1 for 75 frames, then the 240 fps section (source 1 s...1.5 s) at
    // 1/8 speed for 120 frames.
    constexpr int64_t kNormal = 75;
    constexpr int64_t kSlow = 120;
    h.addClip(h.v1, slowmo, 0, kNormal, kCMTimeZero);
    const ClipId slowClip = h.addClip(h.v1, slowmo, kNormal, kSlow, CMTimeMake(1, 1));
    h.sequence().findClip(slowClip)->speed = Ratio{1, 8};
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();

    int distinctSlowFrames = 0;
    int previous = -1;
    for (int64_t frame = 0; frame < kNormal + kSlow; ++frame) {
        const CMTime source = frame < kNormal ? frames30(frame)
                                              : CMTimeAdd(CMTimeMake(1, 1), CMTimeMake(frame - kNormal, 240));
        h.controller->seek(frames30(frame));
        const PlaybackHarness::Sample s = h.presentExact();
        XCTAssertEqual(s.presented.frameIndex, frame);
        XCTAssertEqual(s.burnIns.size(), 1u, @"frame %lld", frame);
        if (s.burnIns.size() != 1) {
            continue;
        }
        const int shown = s.burnIns[0].value_or(-1);
        XCTAssertEqual(shown, slowmoFrameAt(source), @"sequence frame %lld (source %.4f s)", frame,
                       CMTimeGetSeconds(source));
        if (frame >= kNormal && shown != previous) {
            ++distinctSlowFrames;
        }
        previous = shown;
    }
    XCTAssertEqual(distinctSlowFrames, int(kSlow), @"at 1/8 speed every 240 fps frame is shown once");
}

- (void)testTheSlowMotionTableMatchesTheScript {
    // slowmoFrameTime is a C++ copy of the script's frame times: the manifest carries the script's.
    std::string error;
    const std::string dir = testMediaDirectory(error);
    XCTAssertTrue(error.empty(), @"%s", error.c_str());
    NSData *data = [NSData dataWithContentsOfFile:@((dir + "/manifest.json").c_str())];
    NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray<NSNumber *> *ticks = nil;
    for (NSDictionary *entry in manifest[@"files"]) {
        if ([entry[@"file"] isEqualToString:@"slowmo_hevc_portrait.mov"]) {
            ticks = entry[@"frameTicks960"];
        }
    }
    XCTAssertEqual(ticks.count, (NSUInteger)kSlowmoFrames + 1, @"every frame's start and the end");
    for (NSUInteger i = 0; i < ticks.count; ++i) {
        XCTAssertEqual(CMTimeCompare(slowmoFrameTime(int(i)), CMTimeMake(ticks[i].longLongValue, 960)), 0,
                       @"frame %lu", (unsigned long)i);
    }
}

- (void)testAnIncompleteOrOutdatedTestMediaDirectoryIsRecognised {
    // What decides whether FRAMEWRIGHT_TEST_MEDIA_DIR is used as it is or regenerated.
    std::string error;
    const std::string generated = testMediaDirectory(error);
    const std::string hash = testMediaScriptHash();
    XCTAssertTrue(testMediaIsComplete(generated, hash), @"the generated media is complete");
    NSString *copy = [_scratch.path stringByAppendingPathComponent:@"media"];
    NSFileManager *files = NSFileManager.defaultManager;
    XCTAssertTrue([files createDirectoryAtPath:copy withIntermediateDirectories:YES attributes:nil error:nil]);
    XCTAssertFalse(testMediaIsComplete(copy.UTF8String, hash), @"empty");
    for (NSString *name in @[ @"manifest.json", @".script-hash", @"h264_1080p30.mp4" ]) {
        NSString *from = [@(generated.c_str()) stringByAppendingPathComponent:name];
        XCTAssertTrue([files copyItemAtPath:from toPath:[copy stringByAppendingPathComponent:name] error:nil]);
    }
    XCTAssertFalse(testMediaIsComplete(copy.UTF8String, hash), @"files the manifest lists are missing");
    XCTAssertFalse(testMediaIsComplete(generated, hash + "0"), @"made by another version of the script");

    // Pruning keeps the current version and what is derived from it, and anything not hash-named.
    NSString *root = [_scratch.path stringByAppendingPathComponent:@"FramewrightTestMedia"];
    for (NSString *name in @[ @"0123456789abcdef", @"0123456789abcdef-derived-1", @"fedcba9876543210",
                              @"fedcba9876543210-mkv1", @"notes", @"0123456789abcdeg" ]) {
        XCTAssertTrue([files createDirectoryAtPath:[root stringByAppendingPathComponent:name]
                       withIntermediateDirectories:YES attributes:nil error:nil]);
    }
    pruneTestMediaVersions([root stringByAppendingPathComponent:@"0123456789abcdef"].UTF8String);
    NSArray<NSString *> *left = [[files contentsOfDirectoryAtPath:root error:nil]
        sortedArrayUsingSelector:@selector(compare:)];
    XCTAssertEqualObjects(left, (@[ @"0123456789abcdef", @"0123456789abcdef-derived-1", @"0123456789abcdeg",
                                    @"notes" ]));
}

- (void)testTheMediaFolderBookmarkIsSavedWithTheProject {
    VEEngine *engine = [[VEEngine alloc] initWithCacheDirectory:nil];
    XCTAssertNil(engine.mediaFolderBookmark);
    XCTAssertFalse(engine.isDirty);
    NSURL *folder = [_scratch URLByAppendingPathComponent:@"Media" isDirectory:YES];
    XCTAssertTrue([NSFileManager.defaultManager createDirectoryAtURL:folder
                                         withIntermediateDirectories:YES
                                                          attributes:nil
                                                               error:nil]);
    NSData *bookmark = [folder bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
    XCTAssertNotNil(bookmark);
    const uint64_t before = engine.changeCount;
    engine.mediaFolderBookmark = bookmark;
    XCTAssertTrue(engine.isDirty, @"an unsaved change of the project");
    XCTAssertGreaterThan(engine.changeCount, before);
    XCTAssertFalse(engine.canUndo, @"not an undo step");
    const uint64_t same = engine.changeCount;
    engine.mediaFolderBookmark = [bookmark copy];
    XCTAssertEqual(engine.changeCount, same, @"the same bookmark changes nothing");

    NSURL *url = [_scratch URLByAppendingPathComponent:@"project.framewright"];
    NSError *error = nil;
    XCTAssertTrue([engine saveProjectToURL:url error:&error], @"%@", error);
    XCTAssertFalse(engine.isDirty);
    VEEngine *reopened = [[VEEngine alloc] initWithCacheDirectory:nil];
    XCTAssertTrue([reopened openProjectAtURL:url error:&error], @"%@", error);
    XCTAssertEqualObjects(reopened.mediaFolderBookmark, bookmark);
    XCTAssertFalse(reopened.isDirty);
    BOOL stale = NO;
    NSURL *resolved = [NSURL URLByResolvingBookmarkData:reopened.mediaFolderBookmark
                                                options:0
                                          relativeToURL:nil
                                    bookmarkDataIsStale:&stale
                                                  error:nil];
    XCTAssertEqualObjects(resolved.URLByResolvingSymlinksInPath.path, folder.URLByResolvingSymlinksInPath.path);
    [reopened newProjectWithName:@"Next"];
    XCTAssertNil(reopened.mediaFolderBookmark, @"New forgets it");

    // Save As keeps what is set (the app decides what to store); opening a project without the key
    // after one with it leaves none.
    XCTAssertTrue([engine openProjectAtURL:url error:&error], @"%@", error);
    NSURL *copy = [_scratch URLByAppendingPathComponent:@"copy.framewright"];
    XCTAssertTrue([engine saveProjectToURL:copy error:&error], @"%@", error);
    NSString *copied = [NSString stringWithContentsOfURL:copy encoding:NSUTF8StringEncoding error:nil];
    XCTAssertTrue([copied containsString:@"\"mediaFolderBookmark\""]);
    engine.mediaFolderBookmark = nil;
    NSURL *without = [_scratch URLByAppendingPathComponent:@"without.framewright"];
    XCTAssertTrue([engine saveProjectToURL:without error:&error], @"%@", error);
    XCTAssertFalse([[NSString stringWithContentsOfURL:without encoding:NSUTF8StringEncoding error:nil]
        containsString:@"mediaFolderBookmark"]);
    XCTAssertTrue([reopened openProjectAtURL:url error:&error], @"%@", error);
    XCTAssertNotNil(reopened.mediaFolderBookmark);
    XCTAssertTrue([reopened openProjectAtURL:without error:&error], @"%@", error);
    XCTAssertNil(reopened.mediaFolderBookmark, @"nothing carried over from the previous project");
    XCTAssertEqual(reopened.loadWarnings.count, 0u);

    // A value that is not base64 (a hand edit) is left out with a warning.
    NSString *text = [NSString stringWithContentsOfURL:copy encoding:NSUTF8StringEncoding error:nil];
    NSRange key = [text rangeOfString:@"\"mediaFolderBookmark\": \""];
    XCTAssertNotEqual(key.location, (NSUInteger)NSNotFound);
    NSUInteger valueStart = NSMaxRange(key);
    NSRange valueEnd = [text rangeOfString:@"\"" options:0 range:NSMakeRange(valueStart, text.length - valueStart)];
    NSString *broken = [text stringByReplacingCharactersInRange:NSMakeRange(valueStart, valueEnd.location - valueStart)
                                                     withString:@"***not base64***"];
    NSURL *malformed = [_scratch URLByAppendingPathComponent:@"malformed.framewright"];
    XCTAssertTrue([broken writeToURL:malformed atomically:YES encoding:NSUTF8StringEncoding error:&error], @"%@", error);
    XCTAssertTrue([reopened openProjectAtURL:malformed error:&error], @"%@", error);
    XCTAssertNil(reopened.mediaFolderBookmark);
    XCTAssertEqual(reopened.loadWarnings.count, 1u);
    XCTAssertTrue([reopened.loadWarnings.firstObject containsString:@"asked for again"], @"%@", reopened.loadWarnings);
}

@end
