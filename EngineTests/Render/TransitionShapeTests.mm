// Shaped transitions (wipes and the iris) in the compositor, held to a C++ copy of the reveal
// formula documented in RenderGraph.h (kTransitionFeather): pair draws across a cut, single-layer
// draws of a fade role against black, and the partner-missing fallback. The cross dissolve path is
// covered, unchanged, by CompositorTests.testDissolveMix.

#import <XCTest/XCTest.h>

#include "../../Engine/Render/Compositor.h"
#include "CompositorTestSupport.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

using namespace ve;
using namespace ve::render;
using namespace ve::rtest;

namespace {

// The reference reveal m (RenderGraph.h): the incoming picture's share at sequence position (x, y).
double referenceReveal(TransitionKind kind, double x, double y, double width, double height, double progress) {
    const double f = kTransitionFeather;
    double d = 0.0;
    double length = 0.0;
    switch (kind) {
    case TransitionKind::CrossDissolve:
        return progress;
    case TransitionKind::WipeLeft:
        d = width - x;
        length = width;
        break;
    case TransitionKind::WipeRight:
        d = x;
        length = width;
        break;
    case TransitionKind::WipeUp:
        d = height - y;
        length = height;
        break;
    case TransitionKind::WipeDown:
        d = y;
        length = height;
        break;
    case TransitionKind::Iris:
        d = std::hypot(x - width / 2.0, y - height / 2.0);
        length = std::hypot(width, height) / 2.0;
        break;
    }
    const double r = progress * (length + 2.0 * f) - f;
    const double t = std::clamp((d - (r - f)) / (2.0 * f), 0.0, 1.0);
    return 1.0 - t * t * (3.0 - 2.0 * t);
}

LayerTransition makeTransition(TransitionKind kind, TransitionRole role, double progress, bool incoming,
                               std::size_t partnerIndex, ClipId partner) {
    LayerTransition t;
    t.transitionId = SpanId{77};
    t.kind = kind;
    t.role = role;
    t.mix = progress;
    t.isIncoming = incoming;
    t.partnerClipId = partner;
    t.partnerLayerIndex = partnerIndex;
    return t;
}

constexpr int32_t kWidth = 96;
constexpr int32_t kHeight = 54;

} // namespace

@interface TransitionShapeTests : XCTestCase
@end

@implementation TransitionShapeTests {
    std::unique_ptr<Compositor> _compositor;
}

- (void)setUp {
    auto compositor = Compositor::create(device());
    XCTAssertTrue(compositor.ok(), @"%s", compositor.ok() ? "" : compositor.error().description().c_str());
    if (compositor.ok()) {
        _compositor = std::move(compositor).value();
    }
}

- (RenderResult)render:(const RenderGraph &)graph textures:(const std::vector<TextureSet> &)textures out:(media::PixelBuffer &)out {
    auto result = renderLayers(*_compositor, graph, textures, PixelBufferTarget{out});
    XCTAssertTrue(result.ok(), @"%s", result.ok() ? "" : result.error().description().c_str());
    if (!result.ok()) {
        return {};
    }
    XCTAssertTrue(result->status.ok(), @"%s", result->status.ok() ? "" : result->status.error().description().c_str());
    return std::move(result).value();
}

// Compares every pixel of `out` with mix(from, to, m): exact (every channel equal) at progress 0 and
// 1, within one code where the reference reveal is 0 or 1, within two codes in the soft edge. Returns
// the number of pixels inside the soft edge (so a caller can tell the band was crossed).
- (int)check:(const media::PixelBuffer &)out
        kind:(TransitionKind)kind
    progress:(double)progress
        from:(RGBA8)from
          to:(RGBA8)to
       label:(NSString *)label {
    int failures = 0;
    int band = 0;
    const bool exact = progress == 0.0 || progress == 1.0;
    for (int32_t y = 0; y < kHeight; ++y) {
        for (int32_t x = 0; x < kWidth; ++x) {
            const double m = referenceReveal(kind, x + 0.5, y + 0.5, kWidth, kHeight, progress);
            const bool inBand = m != 0.0 && m != 1.0;
            band += inBand ? 1 : 0;
            const double r = from.r + (to.r - from.r) * m;
            const double g = from.g + (to.g - from.g) * m;
            const double b = from.b + (to.b - from.b) * m;
            const RGBA8 got = pixelAt(out, size_t(x), size_t(y));
            const double tolerance = exact ? 0.0 : (inBand ? 2.0 : 1.0);
            if (!near(got, r, g, b, tolerance)) {
                if (++failures <= 5) {
                    XCTFail(@"%@ %s at %.2f, pixel (%d, %d): got %d %d %d, expected %.1f %.1f %.1f (m %.4f)", label,
                            nameOf(kind), progress, x, y, got.r, got.g, got.b, r, g, b, m);
                }
            }
        }
    }
    XCTAssertEqual(failures, 0, @"%@ %s at %.2f: %d pixels differ", label, nameOf(kind), progress, failures);
    return band;
}

// Across a cut: the outgoing red picture, the incoming blue one, drawn as one pair.
- (void)testEveryShapeAcrossACutMatchesTheReference {
    media::PixelBuffer red = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    media::PixelBuffer blue = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    fillBGRA(red, {255, 0, 0, 255});
    fillBGRA(blue, {0, 0, 255, 255});
    const TextureSet a = texturesFor(*_compositor, red);
    const TextureSet b = texturesFor(*_compositor, blue);
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    for (const TransitionKind kind : kTransitionKinds) {
        int bandPixels = 0;
        for (const double progress : {0.0, 0.25, 0.5, 0.75, 1.0}) {
            RenderGraph g = makeGraph(kWidth, kHeight);
            VideoLayer outgoing = makeLayer(1);
            VideoLayer incoming = makeLayer(2);
            outgoing.transition = makeTransition(kind, TransitionRole::CrossDissolve, progress, false, 1, incoming.clipId);
            incoming.transition = makeTransition(kind, TransitionRole::CrossDissolve, progress, true, 0, outgoing.clipId);
            g.layers = {outgoing, incoming};
            const RenderResult r = [self render:g textures:{a, b} out:out];
            XCTAssertEqual(r.drawnLayers, 2u);
            bandPixels += [self check:out kind:kind progress:progress from:{255, 0, 0, 255} to:{0, 0, 255, 255} label:@"cut"];
        }
        if (kind != TransitionKind::CrossDissolve) {
            XCTAssertGreaterThan(bandPixels, 0, @"%s: the soft edge was never inside the frame", nameOf(kind));
        }
    }
}

// At a free edge: a fade in reveals the picture from black by m, a fade out hides it by m.
- (void)testEveryShapeAtAFreeEdgeRevealsOrHidesThePictureOverBlack {
    media::PixelBuffer green = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    fillBGRA(green, {0, 200, 0, 255});
    const TextureSet t = texturesFor(*_compositor, green);
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    const RGBA8 black{0, 0, 0, 255};
    const RGBA8 picture{0, 200, 0, 255};
    for (const TransitionKind kind : kTransitionKinds) {
        for (const double progress : {0.0, 0.25, 0.5, 0.75, 1.0}) {
            for (const bool fadeIn : {true, false}) {
                RenderGraph g = makeGraph(kWidth, kHeight);
                VideoLayer layer = makeLayer(1);
                layer.transition = makeTransition(kind, fadeIn ? TransitionRole::FadeIn : TransitionRole::FadeOut,
                                                  progress, fadeIn, 0, ClipId{});
                g.layers = {layer};
                [self render:g textures:{t} out:out];
                [self check:out
                       kind:kind
                   progress:progress
                       from:fadeIn ? black : picture
                         to:fadeIn ? picture : black
                      label:fadeIn ? @"fade in" : @"fade out"];
            }
        }
    }
}

// A cut whose incoming picture is missing (not decoded yet): the outgoing layer alone keeps its
// share 1 - m, over black.
- (void)testAShapeWhosePartnerIsMissingDrawsTheLayerAloneWithItsShare {
    media::PixelBuffer red = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    fillBGRA(red, {255, 0, 0, 255});
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    for (const TransitionKind kind : {TransitionKind::WipeRight, TransitionKind::Iris}) {
        RenderGraph g = makeGraph(kWidth, kHeight);
        VideoLayer outgoing = makeLayer(1);
        VideoLayer incoming = makeLayer(2);
        outgoing.transition = makeTransition(kind, TransitionRole::CrossDissolve, 0.5, false, 1, incoming.clipId);
        incoming.transition = makeTransition(kind, TransitionRole::CrossDissolve, 0.5, true, 0, outgoing.clipId);
        g.layers = {outgoing, incoming};
        const RenderResult r = [self render:g textures:{texturesFor(*_compositor, red), TextureSet{}} out:out];
        XCTAssertEqual(r.skippedLayers.size(), 1u);
        [self check:out kind:kind progress:0.5 from:{255, 0, 0, 255} to:{0, 0, 0, 255} label:@"partner missing"];
    }
}

// Opacity still applies under a shape: a half-transparent incoming picture over the outgoing one.
- (void)testAShapeKeepsEachSidesOpacity {
    media::PixelBuffer red = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    media::PixelBuffer blue = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    fillBGRA(red, {255, 0, 0, 255});
    fillBGRA(blue, {0, 0, 255, 255});
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    RenderGraph g = makeGraph(kWidth, kHeight);
    VideoLayer outgoing = makeLayer(1);
    VideoLayer incoming = makeLayer(2, 0.5);
    outgoing.transition = makeTransition(TransitionKind::WipeDown, TransitionRole::CrossDissolve, 1.0, false, 1, incoming.clipId);
    incoming.transition = makeTransition(TransitionKind::WipeDown, TransitionRole::CrossDissolve, 1.0, true, 0, outgoing.clipId);
    g.layers = {outgoing, incoming};
    [self render:g textures:{texturesFor(*_compositor, red), texturesFor(*_compositor, blue)} out:out];
    // Wholly revealed: the incoming picture at half opacity over black (the pair replaces what is below).
    const RGBA8 p = pixelAt(out, 40, 30);
    XCTAssertTrue(near(p, 0, 0, 127.5, 1), @"%d %d %d", p.r, p.g, p.b);
}

@end
