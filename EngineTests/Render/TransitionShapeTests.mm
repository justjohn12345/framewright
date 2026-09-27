// Shaped transitions (wipes and the iris) in the compositor, held to C++ references of the reveal
// documented in RenderGraph.h (kTransitionFeather): the soft edge averaged over the frame's exposure
// interval [p0, p1]. The references: the instantaneous soft edge averaged over 32 sub-steps of the
// interval (everywhere), and the hard edge box-filtered over the interval (a linear ramp between the
// edge's two positions) away from the feather. Pair draws across a cut, single-layer draws of a fade role
// against black, and the partner-missing fallback. The cross dissolve path is covered, unchanged, by
// CompositorTests.testDissolveMix.

#import <XCTest/XCTest.h>

#include "../../Engine/Render/Compositor.h"
#include "CompositorTestSupport.h"

#include <algorithm>
#include <cmath>
#include <limits>
#include <string>
#include <utility>
#include <vector>

using namespace ve;
using namespace ve::render;
using namespace ve::rtest;

namespace {

// The distance d of (x, y) from where the incoming picture enters, and the distance L the edge travels
// across a width x height frame (RenderGraph.h).
std::pair<double, double> distanceAndTravel(TransitionKind kind, double x, double y, double width, double height) {
    switch (kind) {
    case TransitionKind::CrossDissolve:
        break;
    case TransitionKind::WipeLeft:
        return {width - x, width};
    case TransitionKind::WipeRight:
        return {x, width};
    case TransitionKind::WipeUp:
        return {height - y, height};
    case TransitionKind::WipeDown:
        return {y, height};
    case TransitionKind::Iris:
        return {std::hypot(x - width / 2.0, y - height / 2.0), std::hypot(width, height) / 2.0};
    }
    return {0.0, 0.0};
}

// The edge's distance from the entering side at progress p: e(p) = p (L + 2f) - f.
double edgeAt(double travel, double progress) {
    return progress * (travel + 2.0 * kTransitionFeather) - kTransitionFeather;
}

// The soft edge at one instant, m_p(d) = 1 - smoothstep(e(p) - f, e(p) + f, d).
double instantReveal(TransitionKind kind, double x, double y, double width, double height, double progress) {
    if (kind == TransitionKind::CrossDissolve) {
        return progress;
    }
    const auto [d, travel] = distanceAndTravel(kind, x, y, width, height);
    const double f = kTransitionFeather;
    const double t = std::clamp((d - (edgeAt(travel, progress) - f)) / (2.0 * f), 0.0, 1.0);
    return 1.0 - t * t * (3.0 - 2.0 * t);
}

// The reference reveal of a frame exposed over [p0, p1]: the instantaneous soft edge averaged over 32
// equal sub-steps (midpoints) of the interval; the instant itself for an interval without length.
double referenceReveal(TransitionKind kind, double x, double y, double width, double height, double p0, double p1) {
    if (p0 == p1) {
        return instantReveal(kind, x, y, width, height, p0);
    }
    double sum = 0.0;
    for (int i = 0; i < 32; ++i) {
        sum += instantReveal(kind, x, y, width, height, p0 + (i + 0.5) / 32.0 * (p1 - p0));
    }
    return sum / 32.0;
}

// The hard edge box-filtered over [p0, p1]: the fraction of the interval during which (x, y) is past
// the edge, clamp((e1 - d) / (e1 - e0), 0, 1). `away` says whether the point is more than the feather
// from both edge positions (where the shader must match it).
double boxFilteredHardEdge(TransitionKind kind, double x, double y, double width, double height, double p0,
                           double p1, bool &away) {
    const auto [d, travel] = distanceAndTravel(kind, x, y, width, height);
    const double e0 = edgeAt(travel, p0);
    const double e1 = edgeAt(travel, p1);
    away = std::abs(d - e0) > kTransitionFeather && std::abs(d - e1) > kTransitionFeather;
    return std::clamp((e1 - d) / (e1 - e0), 0.0, 1.0);
}

// A transition over the exposure interval [p0, p1] (its centre the dissolve's mix).
LayerTransition makeTransition(TransitionKind kind, TransitionRole role, double p0, double p1, bool incoming,
                               std::size_t partnerIndex, ClipId partner) {
    LayerTransition t;
    t.transitionId = SpanId{77};
    t.kind = kind;
    t.role = role;
    t.mix = (p0 + p1) / 2.0;
    t.progressStart = p0;
    t.progressEnd = p1;
    t.isIncoming = incoming;
    t.partnerClipId = partner;
    t.partnerLayerIndex = partnerIndex;
    return t;
}

constexpr int32_t kWidth = 96;
constexpr int32_t kHeight = 54;

// Exposure intervals: the frame before a transition's first ([0, 0], exactly the outgoing picture),
// frames of a 10-frame transition (its first and last, one in the middle), a frame of a 4-frame one (the
// edge sweeps a quarter of the frame during it), and the frame after its last ([1, 1], exactly the
// incoming picture).
const std::vector<std::pair<double, double>> kIntervals = {{0.0, 0.0}, {0.0, 0.1}, {0.45, 0.55}, {0.25, 0.5},
                                                           {0.9, 1.0}, {1.0, 1.0}};

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

// Compares every pixel of `out` with mix(from, to, m) for the frame exposed over [p0, p1]: exactly (every
// channel equal) for an interval without length at 0 or 1; otherwise within 1/255 of the reveal plus the
// output's rounding (1.5 codes of a full-range channel) of the 32-sub-step reference everywhere, and of the
// box-filtered hard edge away from the feather. Returns the number of pixels partly revealed (so a caller
// can tell the edge was inside the frame).
- (int)check:(const media::PixelBuffer &)out
        kind:(TransitionKind)kind
    interval:(std::pair<double, double>)interval
        from:(RGBA8)from
          to:(RGBA8)to
       label:(NSString *)label {
    const auto [p0, p1] = interval;
    int failures = 0;
    int partial = 0;
    const bool exact = p0 == p1 && (p0 == 0.0 || p0 == 1.0);
    auto expect = [&](double m, RGBA8 got, double tolerance, const char *what, int32_t x, int32_t y) {
        const double r = from.r + (to.r - from.r) * m;
        const double g = from.g + (to.g - from.g) * m;
        const double b = from.b + (to.b - from.b) * m;
        if (!near(got, r, g, b, tolerance)) {
            if (++failures <= 5) {
                XCTFail(@"%@ %s over [%.2f, %.2f], pixel (%d, %d), %s: got %d %d %d, expected %.1f %.1f %.1f (m %.4f)",
                        label, nameOf(kind), p0, p1, x, y, what, got.r, got.g, got.b, r, g, b, m);
            }
        }
    };
    for (int32_t y = 0; y < kHeight; ++y) {
        for (int32_t x = 0; x < kWidth; ++x) {
            const RGBA8 got = pixelAt(out, size_t(x), size_t(y));
            const double m = referenceReveal(kind, x + 0.5, y + 0.5, kWidth, kHeight, p0, p1);
            partial += m > 1e-9 && m < 1.0 - 1e-9 ? 1 : 0;
            expect(m, got, exact ? 0.0 : 1.5, "32 sub-steps", x, y);
            if (!exact && p0 != p1 && kind != TransitionKind::CrossDissolve) {
                bool away = false;
                const double box = boxFilteredHardEdge(kind, x + 0.5, y + 0.5, kWidth, kHeight, p0, p1, away);
                if (away) {
                    expect(box, got, 1.5, "box-filtered hard edge", x, y);
                }
            }
        }
    }
    XCTAssertEqual(failures, 0, @"%@ %s over [%.2f, %.2f]: %d pixel checks failed", label, nameOf(kind), p0, p1,
                   failures);
    return partial;
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
        if (kind == TransitionKind::CrossDissolve) {
            continue; // the uniform mix: CompositorTests.testDissolveMix
        }
        for (const auto &interval : kIntervals) {
            RenderGraph g = makeGraph(kWidth, kHeight);
            VideoLayer outgoing = makeLayer(1);
            VideoLayer incoming = makeLayer(2);
            outgoing.transition = makeTransition(kind, TransitionRole::CrossDissolve, interval.first, interval.second,
                                                 false, 1, incoming.clipId);
            incoming.transition = makeTransition(kind, TransitionRole::CrossDissolve, interval.first, interval.second,
                                                 true, 0, outgoing.clipId);
            g.layers = {outgoing, incoming};
            const RenderResult r = [self render:g textures:{a, b} out:out];
            XCTAssertEqual(r.drawnLayers, 2u);
            const int partial = [self check:out
                                       kind:kind
                                   interval:interval
                                       from:{255, 0, 0, 255}
                                         to:{0, 0, 255, 255}
                                      label:@"cut"];
            if (interval.first != interval.second) {
                // The edge sweeps during every frame of the transition: some pixels are partly revealed,
                // the entering sliver of the first frame and the last pixels of the last one included.
                XCTAssertGreaterThan(partial, 0, @"%s over [%.2f, %.2f]", nameOf(kind), interval.first,
                                     interval.second);
            }
        }
    }
}

// The edge no longer steps between frames: over a 4-frame wipe (25 px of travel per frame at this size)
// the reveal of one frame ramps across the whole sweep, and consecutive frames meet (the last pixels of
// one frame's ramp are the first of the next's), unlike the instant at each frame's centre, which jumped
// 25 px with a 4 px soft edge.
- (void)testAFastWipeRampsAcrossItsSweepInsteadOfStepping {
    media::PixelBuffer red = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    media::PixelBuffer blue = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    fillBGRA(red, {255, 0, 0, 255});
    fillBGRA(blue, {0, 0, 255, 255});
    const TextureSet a = texturesFor(*_compositor, red);
    const TextureSet b = texturesFor(*_compositor, blue);
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    for (int k = 0; k < 4; ++k) {
        const double p0 = k / 4.0;
        const double p1 = (k + 1) / 4.0;
        RenderGraph g = makeGraph(kWidth, kHeight);
        VideoLayer outgoing = makeLayer(1);
        VideoLayer incoming = makeLayer(2);
        outgoing.transition = makeTransition(TransitionKind::WipeRight, TransitionRole::CrossDissolve, p0, p1, false, 1,
                                             incoming.clipId);
        incoming.transition = makeTransition(TransitionKind::WipeRight, TransitionRole::CrossDissolve, p0, p1, true, 0,
                                             outgoing.clipId);
        g.layers = {outgoing, incoming};
        [self render:g textures:{a, b} out:out];
        // Along a row: the reveal falls from 1 to 0 across the sweep, never by more than a pixel's share of
        // it (1 / 25 of the way, plus rounding) from one pixel to the next.
        const double e0 = edgeAt(kWidth, p0);
        const double e1 = edgeAt(kWidth, p1);
        int ramp = 0;
        double previous = pixelAt(out, 0, 20).b / 255.0;
        for (int32_t x = 1; x < kWidth; ++x) {
            const double m = pixelAt(out, size_t(x), 20).b / 255.0;
            XCTAssertLessThanOrEqual(previous - m, 1.0 / (e1 - e0) + 2.0 / 255.0, @"frame %d, pixel %d", k, x);
            XCTAssertLessThanOrEqual(m, previous + 1.0 / 255.0, @"frame %d, pixel %d: the reveal only falls", k, x);
            ramp += m > 0.02 && m < 0.98 ? 1 : 0;
            previous = m;
        }
        XCTAssertGreaterThanOrEqual(ramp, 20, @"frame %d: the ramp spans the sweep (%.1f px)", k, e1 - e0);
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
        if (kind == TransitionKind::CrossDissolve) {
            continue;
        }
        for (const auto &interval : kIntervals) {
            for (const bool fadeIn : {true, false}) {
                RenderGraph g = makeGraph(kWidth, kHeight);
                VideoLayer layer = makeLayer(1);
                layer.transition = makeTransition(kind, fadeIn ? TransitionRole::FadeIn : TransitionRole::FadeOut,
                                                  interval.first, interval.second, fadeIn, 0, ClipId{});
                g.layers = {layer};
                [self render:g textures:{t} out:out];
                [self check:out
                       kind:kind
                   interval:interval
                       from:fadeIn ? black : picture
                         to:fadeIn ? picture : black
                      label:fadeIn ? @"fade in" : @"fade out"];
            }
        }
    }
}

// A transition built without its exposure interval (progressStart / progressEnd not set) is the
// instant at its mix, as before.
- (void)testATransitionWithoutItsIntervalIsTheInstantAtItsMix {
    media::PixelBuffer red = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    media::PixelBuffer blue = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    fillBGRA(red, {255, 0, 0, 255});
    fillBGRA(blue, {0, 0, 255, 255});
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    RenderGraph g = makeGraph(kWidth, kHeight);
    VideoLayer outgoing = makeLayer(1);
    VideoLayer incoming = makeLayer(2);
    outgoing.transition = makeTransition(TransitionKind::Iris, TransitionRole::CrossDissolve, 0.4, 0.4, false, 1,
                                         incoming.clipId);
    incoming.transition = makeTransition(TransitionKind::Iris, TransitionRole::CrossDissolve, 0.4, 0.4, true, 0,
                                         outgoing.clipId);
    for (VideoLayer *layer : {&outgoing, &incoming}) {
        layer->transition->progressStart = std::numeric_limits<double>::quiet_NaN();
        layer->transition->progressEnd = std::numeric_limits<double>::quiet_NaN();
    }
    g.layers = {outgoing, incoming};
    [self render:g textures:{texturesFor(*_compositor, red), texturesFor(*_compositor, blue)} out:out];
    [self check:out kind:TransitionKind::Iris interval:{0.4, 0.4} from:{255, 0, 0, 255} to:{0, 0, 255, 255} label:@"unset"];
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
        outgoing.transition = makeTransition(kind, TransitionRole::CrossDissolve, 0.45, 0.55, false, 1, incoming.clipId);
        incoming.transition = makeTransition(kind, TransitionRole::CrossDissolve, 0.45, 0.55, true, 0, outgoing.clipId);
        g.layers = {outgoing, incoming};
        const RenderResult r = [self render:g textures:{texturesFor(*_compositor, red), TextureSet{}} out:out];
        XCTAssertEqual(r.skippedLayers.size(), 1u);
        [self check:out kind:kind interval:{0.45, 0.55} from:{255, 0, 0, 255} to:{0, 0, 0, 255} label:@"partner missing"];
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
    outgoing.transition =
        makeTransition(TransitionKind::WipeDown, TransitionRole::CrossDissolve, 1.0, 1.0, false, 1, incoming.clipId);
    incoming.transition =
        makeTransition(TransitionKind::WipeDown, TransitionRole::CrossDissolve, 1.0, 1.0, true, 0, outgoing.clipId);
    g.layers = {outgoing, incoming};
    [self render:g textures:{texturesFor(*_compositor, red), texturesFor(*_compositor, blue)} out:out];
    // Wholly revealed: the incoming picture at half opacity over black (the pair replaces what is below).
    const RGBA8 p = pixelAt(out, 40, 30);
    XCTAssertTrue(near(p, 0, 0, 127.5, 1), @"%d %d %d", p.r, p.g, p.b);
}

@end
