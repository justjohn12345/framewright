// VEMediaLibrary on its own, constructed without an engine: probing files for an import (the asset,
// routing, details and bookmark of a readable file, the media error of a missing one), recording an
// imported asset, locating an opened project's files (a moved file followed through its bookmark, a
// missing file recorded, a present file kept), probing an opened project's details again (missing
// files skipped), bookmarks for saving, thumbnails and waveforms (a poster and a waveform ready, the
// memory cache purged), and New/Open: the state forgotten and the results of earlier requests
// dropped.

// The class's facade-private header comes first and alone: it must compile without the engine's
// headers (the test imports no FramewrightEngine umbrella, which would bring in VEEngine.h).
#import "../../Engine/Facade/VEMediaLibrary+Internal.h"

#import <XCTest/XCTest.h>

#include "../../Engine/Media/BackendRouter.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../Audio/AudioTestSupport.h"
#include "../Media/TestMedia.h"

#include <algorithm>
#include <memory>
#include <set>
#include <optional>
#include <string>
#include <thread>
#include <vector>

using namespace ve;
using namespace ve::facade;

namespace {

std::shared_ptr<media::BackendRouter> makeRouter() {
    auto router = media::BackendRouter::makeDefault();
    (void)router->registerBackend(media::ffmpeg::makeFFmpegBackend());
    return router;
}

} // namespace

@interface VEMediaLibraryTests : XCTestCase
@end

@implementation VEMediaLibraryTests {
    NSURL *_scratch;
}

- (void)setUp {
    _scratch = [NSURL fileURLWithPath:@(ve::test::scratchDirectory().c_str()) isDirectory:YES];
}

- (NSURL *)mediaURL:(const char *)file {
    std::string error;
    const std::string path = ve::test::testMediaPath(file, error);
    XCTAssertTrue(error.empty(), @"%s", error.c_str());
    return [NSURL fileURLWithPath:@(path.c_str())];
}

/// A copy of a generated file in the scratch directory (so the test may move or delete it).
- (NSURL *)copyOf:(const char *)file named:(NSString *)name {
    NSURL *copy = [_scratch URLByAppendingPathComponent:name];
    NSError *error = nil;
    XCTAssertTrue([NSFileManager.defaultManager copyItemAtURL:[self mediaURL:file] toURL:copy error:&error], @"%@", error);
    return copy;
}

- (BOOL)spinUntil:(BOOL (^)(void))condition timeout:(NSTimeInterval)timeout {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    return condition();
}

- (std::shared_ptr<std::vector<ProbedMediaFile>>)probe:(VEMediaLibrary *)library urls:(NSArray<NSURL *> *)urls {
    __block std::shared_ptr<std::vector<ProbedMediaFile>> probed;
    __block BOOL onMain = NO;
    [library probeFilesAtURLs:urls
                   completion:^(std::shared_ptr<std::vector<ProbedMediaFile>> files) {
                     onMain = NSThread.isMainThread;
                     probed = std::move(files);
                   }];
    XCTAssertTrue([self spinUntil:^BOOL { return probed != nullptr; } timeout:60]);
    XCTAssertTrue(onMain);
    return probed;
}

/// `file` probed and recorded as imported asset `assetId`; returns the asset as the model would hold it.
- (MediaAsset)import:(VEMediaLibrary *)library url:(NSURL *)url as:(AssetId)assetId {
    auto probed = [self probe:library urls:@[ url ]];
    XCTAssertEqual(probed->size(), 1u);
    const ProbedMediaFile &file = probed->front();
    XCTAssertTrue(file.asset.has_value());
    MediaAsset asset = file.asset.value_or(MediaAsset{});
    asset.id = assetId;
    [library addImportedAsset:assetId file:file url:url];
    return asset;
}

- (void)testProbingReportsTheAssetOrTheMediaError {
    VEMediaLibrary *library = [[VEMediaLibrary alloc] initWithRouter:makeRouter() cacheDirectory:nil];
    NSURL *missing = [_scratch URLByAppendingPathComponent:@"not-there.mp4"];
    auto probed = [self probe:library urls:@[ [self mediaURL:"h264_1080p30.mp4"], missing ]];
    XCTAssertEqual(probed->size(), 2u);
    const ProbedMediaFile &good = (*probed)[0];
    XCTAssertTrue(good.asset.has_value());
    XCTAssertTrue(good.routed.has_value());
    XCTAssertFalse(good.error.has_value());
    XCTAssertNotNil(good.bookmark);
    XCTAssertFalse(good.details.codecName.empty());
    XCTAssertTrue(good.details.container == good.routed->info.container);
    XCTAssertNotEqual(good.details.routingReason.find("video: apple"), std::string::npos,
                      @"%s", good.details.routingReason.c_str());
    if (good.asset) {
        XCTAssertTrue(good.asset->hasVideo());
        XCTAssertEqual(good.asset->width, 1920);
    }
    const ProbedMediaFile &bad = (*probed)[1];
    XCTAssertFalse(bad.asset.has_value());
    XCTAssertTrue(bad.error.has_value());
    XCTAssertNil(bad.bookmark);
    // Probing records nothing: only an import does.
    XCTAssertTrue([library routing].empty());
}

- (void)testAnImportedAssetIsRecordedAndBookmarkedForSaving {
    VEMediaLibrary *library = [[VEMediaLibrary alloc] initWithRouter:makeRouter() cacheDirectory:nil];
    const AssetId assetId(7);
    XCTAssertFalse([library detailsForAsset:assetId].has_value());
    const MediaAsset asset = [self import:library url:[self mediaURL:"h264_1080p30.mp4"] as:assetId];
    const std::optional<AssetDetails> details = [library detailsForAsset:assetId];
    XCTAssertTrue(details.has_value());
    if (details) {
        XCTAssertFalse(details->codecName.empty());
    }
    XCTAssertEqual([library routing].count(assetId), 1u);
    XCTAssertFalse([library isAssetMissing:assetId]);
    NSData *bookmark = [library bookmarkForSavingAsset:asset];
    XCTAssertNotNil(bookmark);
    XCTAssertEqualObjects([library bookmarkForSavingAsset:asset], bookmark, @"the remembered bookmark is saved again");

    // An asset the library has no bookmark for gets a new one, remembered from then on.
    MediaAsset other = asset;
    other.id = AssetId(8);
    other.url = [self mediaURL:"hevc_720p2997.mov"].path.fileSystemRepresentation;
    NSData *made = [library bookmarkForSavingAsset:other];
    XCTAssertNotNil(made);
    XCTAssertEqualObjects([library bookmarkForSavingAsset:other], made);
}

- (void)testOpenedAssetsFollowTheirBookmarksAndMissingFilesAreRecorded {
    VEMediaLibrary *library = [[VEMediaLibrary alloc] initWithRouter:makeRouter() cacheDirectory:nil];
    NSURL *original = [self copyOf:"h264_1080p30.mp4" named:@"before-move.mp4"];
    NSData *movedBookmark = [original bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
    XCTAssertNotNil(movedBookmark);
    NSURL *moved = [_scratch URLByAppendingPathComponent:@"after-move.mp4"];
    XCTAssertTrue([NSFileManager.defaultManager moveItemAtURL:original toURL:moved error:nil]);

    std::vector<MediaAsset> assets(3);
    assets[0].id = AssetId(1); // moved: found through its bookmark
    assets[0].url = original.path.fileSystemRepresentation;
    assets[1].id = AssetId(2); // gone, no bookmark
    assets[1].url = [_scratch URLByAppendingPathComponent:@"gone.mp4"].path.fileSystemRepresentation;
    assets[2].id = AssetId(3); // where it was stored, no bookmark
    assets[2].url = [self mediaURL:"hevc_720p2997.mov"].path.fileSystemRepresentation;

    const std::vector<AssetRelink> relinks = [library locateOpenedAssets:assets bookmarks:@{@1 : movedBookmark}];
    XCTAssertEqual(relinks.size(), 1u);
    if (!relinks.empty()) {
        XCTAssertEqual(relinks[0].index, 0u);
        NSString *relinked = [NSURL fileURLWithPath:@(relinks[0].path.c_str())].URLByResolvingSymlinksInPath.path;
        XCTAssertEqualObjects(relinked, moved.URLByResolvingSymlinksInPath.path);
    }
    XCTAssertFalse([library isAssetMissing:AssetId(1)]);
    XCTAssertTrue([library isAssetMissing:AssetId(2)]);
    XCTAssertFalse([library isAssetMissing:AssetId(3)]);
    XCTAssertTrue([library missingAssets] == (std::set<AssetId>{AssetId(2)}));
    XCTAssertNil([library bookmarkForSavingAsset:assets[1]], @"a missing file gets no new bookmark");

    // The details probe skips the missing asset and reports the others on the main thread.
    assets[0].url = relinks.empty() ? assets[0].url : relinks[0].path;
    __block std::vector<AssetId> reported;
    __block BOOL onMain = YES;
    [library probeDetailsOfAssets:assets
                       completion:^(AssetId asset, const std::string &path, const media::RoutedMediaInfo &routed) {
                         onMain = onMain && NSThread.isMainThread;
                         reported.push_back(asset);
                         XCTAssertFalse(path.empty());
                         XCTAssertFalse(routed.routes.empty());
                         [library recordProbe:routed forAsset:asset];
                       }];
    XCTAssertTrue([self spinUntil:^BOOL { return reported.size() == 2; } timeout:60]);
    XCTAssertTrue(onMain);
    std::sort(reported.begin(), reported.end());
    XCTAssertTrue(reported == (std::vector<AssetId>{AssetId(1), AssetId(3)}));
    XCTAssertTrue([library detailsForAsset:AssetId(3)].has_value());
    XCTAssertEqual([library routing].size(), 2u);
}

- (void)testThumbnailsAndWaveformsAreDeliveredAndPurged {
    VEMediaLibrary *library = [[VEMediaLibrary alloc] initWithRouter:makeRouter() cacheDirectory:nil];
    const MediaAsset asset = [self import:library url:[self mediaURL:"h264_1080p30.mp4"] as:AssetId(4)];
    XCTAssertTrue(asset.hasVideo() && asset.hasAudio());

    __block std::vector<AssetId> posters;
    __block std::vector<AssetId> waveforms;
    [library startPosterAndWaveformForAsset:asset
        thumbnailReady:^(AssetId ready) {
          posters.push_back(ready);
        }
        waveformReady:^(AssetId ready) {
          waveforms.push_back(ready);
        }];
    XCTAssertTrue([self spinUntil:^BOOL { return !posters.empty() && !waveforms.empty(); } timeout:60]);
    XCTAssertTrue(posters == std::vector<AssetId>{asset.id});
    XCTAssertTrue(waveforms == std::vector<AssetId>{asset.id});
    XCTAssertTrue([library cachedWaveformOfAsset:asset] != nullptr);

    __block BOOL thumbnailDone = NO;
    [library thumbnailOfAsset:asset
                       atTime:CMTimeMake(1, 1)
                 maxDimension:4 // clamped to 16
                   completion:^(const media::Result<thumbs::ThumbnailImage> *result) {
                     XCTAssertTrue(result != nullptr && result->ok());
                     if (result != nullptr && result->ok()) {
                         const size_t longest = std::max(CGImageGetWidth(result->value().get()),
                                                         CGImageGetHeight(result->value().get()));
                         XCTAssertEqual(longest, 16u);
                     }
                     thumbnailDone = YES;
                   }];
    XCTAssertTrue([self spinUntil:^BOOL { return thumbnailDone; } timeout:60]);

    __block BOOL waveformDone = NO;
    [library waveformOfAsset:asset
                  completion:^(const thumbs::WaveformResult *result) {
                    XCTAssertTrue(result != nullptr && result->ok() && result->value() != nullptr);
                    waveformDone = YES;
                  }];
    XCTAssertTrue([self spinUntil:^BOOL { return waveformDone; } timeout:60]);

    [library purgeThumbnailsAndWaveformsOfAssets:{asset}];
    XCTAssertTrue([library cachedWaveformOfAsset:asset] == nullptr);
}

- (void)testForgettingTheProjectDropsItsStateAndEarlierResults {
    VEMediaLibrary *library = [[VEMediaLibrary alloc] initWithRouter:makeRouter() cacheDirectory:nil];
    const MediaAsset asset = [self import:library url:[self copyOf:"h264_1080p30.mp4" named:@"forget.mp4"] as:AssetId(5)];
    std::vector<MediaAsset> gone(1);
    gone[0].id = AssetId(6);
    gone[0].url = [_scratch URLByAppendingPathComponent:@"forget-gone.mp4"].path.fileSystemRepresentation;
    (void)[library locateOpenedAssets:gone bookmarks:@{}];
    XCTAssertTrue([library isAssetMissing:AssetId(6)]);

    __block int thumbnailCalls = 0;
    __block BOOL thumbnailDropped = NO;
    [library thumbnailOfAsset:asset
                       atTime:kCMTimeZero
                 maxDimension:64
                   completion:^(const media::Result<thumbs::ThumbnailImage> *result) {
                     thumbnailCalls += 1;
                     thumbnailDropped = result == nullptr;
                   }];
    __block int waveformCalls = 0;
    __block BOOL waveformDropped = NO;
    [library waveformOfAsset:asset
                  completion:^(const thumbs::WaveformResult *result) {
                    waveformCalls += 1;
                    waveformDropped = result == nullptr;
                  }];
    __block int posterCalls = 0;
    [library startPosterAndWaveformForAsset:asset
        thumbnailReady:^(AssetId) {
          posterCalls += 1;
        }
        waveformReady:^(AssetId) {
          posterCalls += 1;
        }];
    __block int detailCalls = 0;
    [library probeDetailsOfAssets:{asset}
                       completion:^(AssetId, const std::string &, const media::RoutedMediaInfo &) {
                         detailCalls += 1;
                       }];

    [library forgetThumbnailsAndWaveformsOfAssets:{asset}];
    [library forgetProjectAssets];
    XCTAssertTrue([library routing].empty());
    XCTAssertTrue([library missingAssets].empty());
    XCTAssertFalse([library detailsForAsset:asset.id].has_value());

    XCTAssertTrue([self spinUntil:^BOOL { return thumbnailCalls > 0 && waveformCalls > 0; } timeout:60]);
    // Give the poster, waveform and details probes time to come back too.
    [self spinUntil:^BOOL { return NO; } timeout:1.0];
    XCTAssertEqual(thumbnailCalls, 1);
    XCTAssertTrue(thumbnailDropped);
    XCTAssertEqual(waveformCalls, 1);
    XCTAssertTrue(waveformDropped);
    XCTAssertEqual(posterCalls, 0);
    XCTAssertEqual(detailCalls, 0);
}

/// A library over the tone backend (fake audio files, reads held at a gate while
/// `tone->readsBlocked`), for the waveform lifecycle tests.
- (VEMediaLibrary *)toneLibrary:(std::shared_ptr<ve::test::ToneBehavior>)tone {
    return [[VEMediaLibrary alloc] initWithRouter:ve::test::makeToneRouter(std::move(tone)) cacheDirectory:nil];
}

- (BOOL)waitForBlockedReads:(int)count of:(ve::test::ToneBehavior &)tone {
    ve::test::ToneBehavior *behavior = &tone;
    return [self spinUntil:^BOOL { return behavior->blockedReads.load() >= count; } timeout:10];
}

/// Asset ids restart per project. The closed project's waveform (asset 1, one file) is still
/// computing when the new project's asset 1 (another file) asks for its waveform: the new asset gets
/// its own file's peaks, and the memory cache answers for its file only.
- (void)testANewProjectsAssetUnderAReusedIdGetsItsOwnFilesWaveform {
    auto tone = std::make_shared<ve::test::ToneBehavior>();
    tone->lengthFrames = 48000 * 4;
    tone->setSignal("/tone/closed-project.wav", ve::test::constantSignal(0.9f, 0.9f));
    tone->setSignal("/tone/new-project.wav", ve::test::constantSignal(0.1f, 0.1f));
    VEMediaLibrary *library = [self toneLibrary:tone];
    const MediaAsset closed = [self import:library url:[NSURL fileURLWithPath:@"/tone/closed-project.wav"] as:AssetId(1)];
    tone->setReadsBlocked(true);
    [library startPosterAndWaveformForAsset:closed
                             thumbnailReady:^(AssetId) {
                               XCTFail(@"an audio file has no poster");
                             }
                              waveformReady:^(AssetId) {
                                XCTFail(@"the closed project's waveform is not reported");
                              }];
    XCTAssertTrue([self waitForBlockedReads:1 of:*tone], @"the closed project's waveform is computing");
    [library forgetThumbnailsAndWaveformsOfAssets:{closed}];
    [library forgetProjectAssets];

    const MediaAsset reused = [self import:library url:[NSURL fileURLWithPath:@"/tone/new-project.wav"] as:AssetId(1)];
    __block std::shared_ptr<const thumbs::WaveformPeaks> peaks;
    __block BOOL done = NO;
    [library waveformOfAsset:reused
                  completion:^(const thumbs::WaveformResult *result) {
                    XCTAssertTrue(result != nullptr && result->ok());
                    if (result != nullptr && result->ok()) {
                        peaks = result->value();
                    }
                    done = YES;
                  }];
    tone->setReadsBlocked(false);
    XCTAssertTrue([self spinUntil:^BOOL { return done; } timeout:30]);
    XCTAssertTrue(peaks != nullptr);
    if (peaks != nullptr) {
        XCTAssertEqual(peaks->bucketCount(), 400u);
        XCTAssertEqualWithAccuracy(peaks->mono[200].max, 0.1f, 1e-5, @"the new project's file, not the closed one's");
    }
    const auto cached = [library cachedWaveformOfAsset:reused];
    XCTAssertTrue(cached != nullptr && cached == peaks);
    XCTAssertTrue([library cachedWaveformOfAsset:closed] == nullptr, @"the closed project's file is not cached");
}

/// New/Open cancels the closed project's waveform requests (the service computes on one thread, so
/// the new project's waveforms would wait behind them): the poster pass's and a view's request of an
/// asset still in the project, and a request of an asset removed from it before (not in the list
/// the engine forgets, so -forgetProjectAssets ends it). The computation in flight stops at its next
/// chunk and the queued one never starts.
- (void)testNewOpenCancelsTheClosedProjectsWaveformRequests {
    auto tone = std::make_shared<ve::test::ToneBehavior>();
    tone->lengthFrames = 48000 * 600; // ten minutes each: far more than the reads the test allows
    tone->setSignal("/tone/a.wav", ve::test::constantSignal(0.5f, 0.5f));
    tone->setSignal("/tone/removed.wav", ve::test::constantSignal(0.5f, 0.5f));
    VEMediaLibrary *library = [self toneLibrary:tone];
    const MediaAsset a = [self import:library url:[NSURL fileURLWithPath:@"/tone/a.wav"] as:AssetId(1)];
    const MediaAsset removed = [self import:library url:[NSURL fileURLWithPath:@"/tone/removed.wav"] as:AssetId(2)];
    tone->setReadsBlocked(true);
    __block int posterPassCalls = 0;
    [library startPosterAndWaveformForAsset:a
                             thumbnailReady:^(AssetId) {
                               posterPassCalls += 1;
                             }
                              waveformReady:^(AssetId) {
                                posterPassCalls += 1;
                              }];
    __block int dropped = 0;
    __block int reported = 0;
    for (const MediaAsset *asset : {&a, &removed}) {
        [library waveformOfAsset:*asset
                      completion:^(const thumbs::WaveformResult *result) {
                        (result == nullptr ? dropped : reported) += 1;
                      }];
    }
    XCTAssertTrue([self waitForBlockedReads:1 of:*tone], @"asset 1's waveform is computing, asset 2's queued");
    [library forgetThumbnailsAndWaveformsOfAssets:{a}];
    [library forgetProjectAssets];
    tone->setReadsBlocked(false);
    XCTAssertTrue([self spinUntil:^BOOL { return dropped + reported == 2; } timeout:30]);
    XCTAssertEqual(dropped, 2);
    XCTAssertEqual(reported, 0);
    // The service's one worker takes the new project's request only after the closed project's
    // work ended, so its completion marks that end.
    tone->setSignal("/tone/next.wav", ve::test::constantSignal(0.25f, 0.25f));
    const MediaAsset next = [self import:library url:[NSURL fileURLWithPath:@"/tone/next.wav"] as:AssetId(1)];
    __block BOOL nextDone = NO;
    [library waveformOfAsset:next
                  completion:^(const thumbs::WaveformResult *result) {
                    XCTAssertTrue(result != nullptr && result->ok());
                    nextDone = YES;
                  }];
    XCTAssertTrue([self spinUntil:^BOOL { return nextDone; } timeout:60]);
    // The computation in flight read the chunk it was held in (a third of a second), the queued one
    // nothing; the new project's file was read whole.
    const int64_t closedFrames = tone->framesRead.load() - tone->lengthFrames;
    XCTAssertGreaterThanOrEqual(closedFrames, 0);
    XCTAssertLessThanOrEqual(closedFrames, int64_t(48000), @"the closed project's requests read %lld frames",
                             static_cast<long long>(closedFrames));
    XCTAssertEqual(tone->opens.load(), 2, @"the removed asset's queued request never started");
    XCTAssertEqual(posterPassCalls, 0);
}

@end
