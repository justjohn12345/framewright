// ProgramFrameProvider (the program monitor's still-frame source): a scrub request cancelled by
// another client's request for the same asset is made again, decode failures and texture
// mapping failures are reported as the frame's status, and the published frame carries the
// picture of the requested time.

#import <XCTest/XCTest.h>

#include "../../Engine/Facade/VEProgramFrameProvider+Internal.h"
#include "../../Engine/Media/BackendRouter.h"
#include "../../Engine/Media/DecodePool.h"
#include "../../Engine/Media/FrameCache.h"
#include "../Media/BurnIn.h"
#include "../Media/RouterTestSupport.h"
#include "CompositorTestSupport.h"

#include <atomic>
#include <chrono>
#include <memory>

using namespace ve;
using namespace ve::media;
using namespace ve::render;
using namespace ve::test;

@interface ProgramFrameProviderTests : XCTestCase
@end

@implementation ProgramFrameProviderTests {
    std::shared_ptr<FakeBehavior> _fake;
    std::shared_ptr<BackendRouter> _router;
    std::shared_ptr<FrameCache> _cache;
    std::shared_ptr<DecodePool> _pool;
    TextureCache _textures;
}

- (void)setUp {
    _fake = std::make_shared<FakeBehavior>();
    _fake->probe = [](const std::string &p) { return Result<MediaInfo>(makeFakeInfo(p, "mov", fourcc::H264)); };
    _router = std::make_shared<BackendRouter>();
    (void)_router->registerBackend(std::make_shared<FakeBackend>(_fake));
    _cache = std::make_shared<FrameCache>();
    _pool = std::make_shared<DecodePool>(_router, _cache);
    _pool->registerAsset(AssetId(1), "/fake/a.mov");
    _pool->registerAsset(AssetId(2), "/fake/b.mov");
    auto textures = TextureCache::create(rtest::device());
    XCTAssertTrue(textures.ok());
    if (textures.ok()) {
        _textures = std::move(textures).value();
    }
}

- (void)tearDown {
    _pool.reset(); // joins the scrub thread before the fakes go away
}

- (RenderGraph)graphShowing:(AssetId)asset atFrame:(int)frame {
    RenderGraph g = rtest::makeGraph(288, 162);
    VideoLayer layer = rtest::makeLayer(1);
    layer.assetId = asset;
    layer.sourceTime = CMTimeMake(frame, 30);
    g.layers.push_back(layer);
    return g;
}

// Shows `graph` and spins the main run loop until onReady.
- (void)show:(RenderGraph)graph on:(facade::ProgramFrameProvider &)provider {
    XCTestExpectation *ready = [self expectationWithDescription:@"ready"];
    provider.show(std::move(graph), [ready] { [ready fulfill]; });
    [self waitForExpectations:@[ ready ] timeout:10];
}

- (PreviewFrame)pull:(const facade::ProgramFrameProvider &)provider cache:(const TextureCache *)cache {
    PreviewFrame frame;
    PreviewFrameRequest request;
    request.isRenderOnce = true;
    request.textureCache = cache;
    const bool fresh = provider.makeSource()(request, frame);
    XCTAssertTrue(fresh);
    return frame;
}

// The scrub thread is busy (a decode of asset 2 held at a gate) while the provider asks for
// asset 1 at frame 30; another client then asks for asset 1 at frame 90, which cancels the
// provider's request before it starts. The provider asks again, so the frame it publishes has
// the picture of frame 30, not a hole.
- (void)testCancelledScrubRequestIsMadeAgain {
    auto gate = std::make_shared<Gate>();
    auto firstDecode = std::make_shared<std::atomic<bool>>(true);
    auto entered = std::make_shared<Gate>();
    _fake->onDecode = [gate, firstDecode, entered](int64_t) {
        if (firstDecode->exchange(false)) {
            entered->open();
            gate->pass();
        }
    };
    auto provider = std::make_shared<facade::ProgramFrameProvider>(_pool);

    auto otherResults = std::make_shared<std::atomic<int>>(0);
    _pool->requestFrame(AssetId(2), CMTimeMake(5, 30), [otherResults](Result<ScrubFrame>) { otherResults->fetch_add(1); });
    XCTAssertTrue(entered->pass(std::chrono::seconds(10)), @"the scrub thread should be decoding asset 2");

    XCTestExpectation *ready = [self expectationWithDescription:@"ready"];
    provider->show([self graphShowing:AssetId(1) atFrame:30], [ready] { [ready fulfill]; });
    // Another client (e.g. the source monitor) scrubs the same asset: replaces the pending request.
    auto otherFrame = std::make_shared<std::atomic<int>>(-1);
    _pool->requestFrame(AssetId(1), CMTimeMake(90, 30), [otherFrame](Result<ScrubFrame> r) {
        if (r.ok()) {
            otherFrame->store(readBurnIn(r->image.get()).value_or(-2));
        }
    });
    gate->open();
    [self waitForExpectations:@[ ready ] timeout:10];

    const PreviewFrame frame = [self pull:*provider cache:&_textures];
    XCTAssertTrue(frame.status.ok(), @"%s", frame.status.ok() ? "" : frame.status.error().description().c_str());
    XCTAssertEqual(frame.textures.size(), 1u);
    if (frame.textures.size() == 1) {
        XCTAssertTrue(frame.textures[0], @"the cancelled layer must be requested again, not left empty");
        if (frame.textures[0]) {
            XCTAssertEqual(readBurnIn(frame.textures[0].pixelBuffer().get()).value_or(-1), 30);
        }
    }
    XCTAssertTrue(_pool->waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertEqual(otherFrame->load(), 90, @"the other client still gets its frame");
    XCTAssertGreaterThanOrEqual(_pool->stats().scrubCancelled, 1u, @"the scenario must actually cancel a request");
}

// A layer that cannot be decoded is published without a picture and the error as the status.
- (void)testDecodeFailureIsTheFrameStatus {
    _fake->failOpen = true;
    auto provider = std::make_shared<facade::ProgramFrameProvider>(_pool);
    [self show:[self graphShowing:AssetId(1) atFrame:3] on:*provider];
    const PreviewFrame frame = [self pull:*provider cache:&_textures];
    XCTAssertFalse(frame.status.ok());
    if (!frame.status.ok()) {
        XCTAssertNotEqual(frame.status.error().code, MediaErrorCode::Cancelled);
    }
    XCTAssertEqual(frame.textures.size(), 1u);
    XCTAssertFalse(frame.textures.empty() ? true : bool(frame.textures[0]));

    // The next good frame has an ok status.
    _fake->failOpen = false;
    _pool->invalidate(AssetId(1));
    [self show:[self graphShowing:AssetId(1) atFrame:4] on:*provider];
    const PreviewFrame good = [self pull:*provider cache:&_textures];
    XCTAssertTrue(good.status.ok(), @"%s", good.status.ok() ? "" : good.status.error().description().c_str());
    XCTAssertTrue(!good.textures.empty() && good.textures[0]);
}

// A picture that cannot be mapped to Metal textures is reported, not silently dropped.
- (void)testTextureMappingFailureIsTheFrameStatus {
    auto provider = std::make_shared<facade::ProgramFrameProvider>(_pool);
    [self show:[self graphShowing:AssetId(1) atFrame:7] on:*provider];
    TextureCache notCreated; // textures() fails: InvalidState
    const PreviewFrame frame = [self pull:*provider cache:&notCreated];
    XCTAssertFalse(frame.status.ok());
    if (!frame.status.ok()) {
        XCTAssertEqual(frame.status.error().code, MediaErrorCode::InvalidState);
    }
    XCTAssertTrue(frame.textures.size() == 1 && !frame.textures[0]);

    // Without any texture cache (Metal unavailable) likewise.
    [self show:[self graphShowing:AssetId(1) atFrame:8] on:*provider];
    const PreviewFrame none = [self pull:*provider cache:nullptr];
    XCTAssertFalse(none.status.ok());
}

@end
