// A transition span's Softness parameter (Transition.h, TransitionParameter::Softness) from the model to
// the pixels: the scheduler hands each layer of a shaped transition its span's softness (the default,
// kTransitionFeather, when the span sets none), and the compositor draws the soft edge that wide, held to
// the reveal documented in RenderGraph.h with f = the softness (the reference of TransitionShapeTests,
// which covers the default, generalised to any f). Softness 0 is a hard edge.

#import <XCTest/XCTest.h>

#include "../../Engine/Model/Project.h"
#include "../../Engine/Model/Validation.h"
#include "../../Engine/Render/Compositor.h"
#include "../../Engine/Render/Scheduler.h"
#include "CompositorTestSupport.h"

#include <algorithm>
#include <cmath>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using namespace ve;
using namespace ve::render;
using namespace ve::rtest;

namespace {

constexpr int32_t kWidth = 96;
constexpr int32_t kHeight = 54;

// The shader's soft edge half width for a softness `s`: at least 1/1000 of a pixel (Shaders.metal).
double featherOf(double softness) {
    return std::max(softness, 1.0e-3);
}

// The distance d of (x, y) from where the incoming picture enters, and the distance L the edge travels.
std::pair<double, double> distanceAndTravel(TransitionKind kind, double x, double y) {
    switch (kind) {
    case TransitionKind::CrossDissolve:
        break;
    case TransitionKind::WipeLeft:
        return {kWidth - x, kWidth};
    case TransitionKind::WipeRight:
        return {x, kWidth};
    case TransitionKind::WipeUp:
        return {kHeight - y, kHeight};
    case TransitionKind::WipeDown:
        return {y, kHeight};
    case TransitionKind::Iris:
        return {std::hypot(x - kWidth / 2.0, y - kHeight / 2.0), std::hypot(kWidth, kHeight) / 2.0};
    }
    return {0.0, 0.0};
}

// m_p(d) = 1 - smoothstep(e(p) - f, e(p) + f, d), e(p) = p (L + 2f) - f.
double instantReveal(TransitionKind kind, double softness, double x, double y, double progress) {
    const auto [d, travel] = distanceAndTravel(kind, x, y);
    const double f = featherOf(softness);
    const double edge = progress * (travel + 2.0 * f) - f;
    const double t = std::clamp((d - (edge - f)) / (2.0 * f), 0.0, 1.0);
    return 1.0 - t * t * (3.0 - 2.0 * t);
}

// The instantaneous reveal averaged over 32 sub-steps of [p0, p1]; the instant itself without length. A
// hard edge (softness 0) is a step that sub-steps would quantise to 1/32: its exact mean, the fraction of
// the interval during which the edge has passed the point, clamp((e1 - d) / (e1 - e0), 0, 1) (the
// shader's f of 1/1000 pixel changes that by less than 1/1000 of a code).
double referenceReveal(TransitionKind kind, double softness, double x, double y, double p0, double p1) {
    if (p0 == p1) {
        return instantReveal(kind, softness, x, y, p0);
    }
    if (softness == 0.0) {
        const auto [d, travel] = distanceAndTravel(kind, x, y);
        return std::clamp((p1 * travel - d) / ((p1 - p0) * travel), 0.0, 1.0);
    }
    double sum = 0.0;
    for (int i = 0; i < 32; ++i) {
        sum += instantReveal(kind, softness, x, y, p0 + (i + 0.5) / 32.0 * (p1 - p0));
    }
    return sum / 32.0;
}

LayerTransition makeTransition(TransitionKind kind, double softness, double p0, double p1, bool incoming,
                               std::size_t partnerIndex, ClipId partner) {
    LayerTransition t;
    t.transitionId = SpanId{91};
    t.kind = kind;
    t.role = TransitionRole::CrossDissolve;
    t.mix = (p0 + p1) / 2.0;
    t.progressStart = p0;
    t.progressEnd = p1;
    t.isIncoming = incoming;
    t.softness = softness;
    t.partnerClipId = partner;
    t.partnerLayerIndex = partnerIndex;
    return t;
}

// A kWidth x kHeight, 30 fps project: two 30-frame still clips touching on V1 with a 10-frame `kind`
// transition centred on their cut, and on V2 a 30-frame still from frame 60 with a 10-frame `kind` fade
// in. `softness` sets both spans' Softness (nullopt: neither sets it).
Project softnessProject(TransitionKind kind, std::optional<double> softness) {
    Project project;
    project.name = "Softness";
    MediaAsset still;
    still.name = "white.png";
    still.url = "file:///media/white.png";
    still.kind = AssetKind::Still;
    still.width = kWidth;
    still.height = kHeight;
    const AssetId asset = project.addAsset(still);
    const SequenceId sequenceId = project.addSequence("Main", CMTimeMake(1, 30), kWidth, kHeight, 2, 0);
    Sequence &sequence = *project.findSequence(sequenceId);
    auto addClip = [&](Track &track, int64_t start) -> Clip & {
        Clip clip;
        clip.id = project.ids.make<ClipId>();
        clip.assetId = asset;
        clip.trackId = track.id;
        clip.isStill = true;
        clip.timelineStart = CMTimeMake(start, 30);
        clip.timelineDuration = CMTimeMake(30, 30);
        track.clips.push_back(clip);
        return track.clips.back();
    };
    auto span = [&](ClipEdge edge, CMTime start, CMTime end) {
        TransitionSpan s;
        s.id = project.ids.make<SpanId>();
        s.kind = kind;
        s.edge = edge;
        s.start = start;
        s.end = end;
        if (softness) {
            s.parameters[TransitionParameter::Softness] = TransitionValue::scalar(*softness);
        }
        return s;
    };
    Track &v1 = sequence.videoTracks[0];
    addClip(v1, 0).transitions.push_back(span(ClipEdge::Tail, CMTimeMake(-5, 30), CMTimeMake(5, 30)));
    addClip(v1, 30);
    Track &v2 = sequence.videoTracks[1];
    addClip(v2, 60).transitions.push_back(span(ClipEdge::Head, kCMTimeZero, CMTimeMake(10, 30)));
    return project;
}

const std::vector<TransitionKind> kShapes = {TransitionKind::WipeLeft, TransitionKind::WipeRight,
                                             TransitionKind::WipeUp, TransitionKind::WipeDown, TransitionKind::Iris};

} // namespace

@interface TransitionSoftnessTests : XCTestCase
@end

@implementation TransitionSoftnessTests {
    std::unique_ptr<Compositor> _compositor;
}

- (void)setUp {
    auto compositor = Compositor::create(device());
    XCTAssertTrue(compositor.ok(), @"%s", compositor.ok() ? "" : compositor.error().description().c_str());
    if (compositor.ok()) {
        _compositor = std::move(compositor).value();
    }
}

- (void)render:(const RenderGraph &)graph textures:(const std::vector<TextureSet> &)textures out:(media::PixelBuffer &)out {
    auto result = renderLayers(*_compositor, graph, textures, PixelBufferTarget{out});
    XCTAssertTrue(result.ok(), @"%s", result.ok() ? "" : result.error().description().c_str());
    if (result.ok()) {
        XCTAssertTrue(result->status.ok(), @"%s",
                      result->status.ok() ? "" : result->status.error().description().c_str());
    }
}

// Compares every pixel of `out` with mix(from, to, m), m the reference reveal with this softness over
// [p0, p1], within 1.5 codes (the output's rounding); returns the number of pixels partly revealed.
- (int)check:(const media::PixelBuffer &)out
        kind:(TransitionKind)kind
    softness:(double)softness
    interval:(std::pair<double, double>)interval
        from:(RGBA8)from
          to:(RGBA8)to
       label:(NSString *)label {
    const auto [p0, p1] = interval;
    int failures = 0;
    int partial = 0;
    for (int32_t y = 0; y < kHeight; ++y) {
        for (int32_t x = 0; x < kWidth; ++x) {
            const RGBA8 got = pixelAt(out, size_t(x), size_t(y));
            const double m = referenceReveal(kind, softness, x + 0.5, y + 0.5, p0, p1);
            partial += m > 1e-9 && m < 1.0 - 1e-9 ? 1 : 0;
            const double r = from.r + (to.r - from.r) * m;
            const double g = from.g + (to.g - from.g) * m;
            const double b = from.b + (to.b - from.b) * m;
            if (!near(got, r, g, b, 1.5) && ++failures <= 5) {
                XCTFail(@"%@ %s softness %.1f over [%.2f, %.2f], pixel (%d, %d): got %d %d %d, expected %.1f %.1f "
                        @"%.1f (m %.4f)",
                        label, nameOf(kind), softness, p0, p1, x, y, got.r, got.g, got.b, r, g, b, m);
            }
        }
    }
    XCTAssertEqual(failures, 0, @"%@ %s softness %.1f over [%.2f, %.2f]", label, nameOf(kind), softness, p0, p1);
    return partial;
}

// Across a cut, every shape at softness 0 (a hard edge), 12 and 40 matches the reference with that f, at
// an instant and over frames' exposure intervals; at an instant the soft band is 2f wide.
- (void)testEveryShapeDrawsItsSoftEdgeAsWideAsItsSoftness {
    media::PixelBuffer red = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    media::PixelBuffer blue = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    fillBGRA(red, {255, 0, 0, 255});
    fillBGRA(blue, {0, 0, 255, 255});
    const TextureSet a = texturesFor(*_compositor, red);
    const TextureSet b = texturesFor(*_compositor, blue);
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    const std::vector<std::pair<double, double>> intervals = {{0.5, 0.5}, {0.0, 0.1}, {0.45, 0.55}, {0.9, 1.0}};
    for (const TransitionKind kind : kShapes) {
        for (const double softness : {0.0, 12.0, 40.0}) {
            for (const auto &interval : intervals) {
                RenderGraph g = makeGraph(kWidth, kHeight);
                VideoLayer outgoing = makeLayer(1);
                VideoLayer incoming = makeLayer(2);
                outgoing.transition =
                    makeTransition(kind, softness, interval.first, interval.second, false, 1, incoming.clipId);
                incoming.transition =
                    makeTransition(kind, softness, interval.first, interval.second, true, 0, outgoing.clipId);
                g.layers = {outgoing, incoming};
                [self render:g textures:{a, b} out:out];
                const int partial = [self check:out
                                           kind:kind
                                       softness:softness
                                       interval:interval
                                           from:{255, 0, 0, 255}
                                             to:{0, 0, 255, 255}
                                          label:@"cut"];
                if (interval == std::pair<double, double>{0.5, 0.5} && kind == TransitionKind::WipeLeft) {
                    // At an instant the band is 2f pixels wide across the whole height: none for a hard
                    // edge whose pixel centres lie off it, 24 or 80 columns for f = 12 or 40.
                    const int columns = partial / kHeight;
                    if (softness == 0.0) {
                        XCTAssertEqual(partial, 0);
                    } else {
                        XCTAssertEqual(partial % kHeight, 0);
                        XCTAssertEqual(columns, int(2.0 * softness), @"softness %.0f", softness);
                    }
                }
            }
        }
    }
}

// The scheduler gives both layers of a transition across a cut, and a fade's layer, their span's
// softness, or kTransitionFeather when it sets none; the scheduled frames draw that edge.
- (void)testTheSchedulerHandsEachLayerItsSpansSoftness {
    media::PixelBuffer white = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    fillBGRA(white, {255, 255, 255, 255});
    const TextureSet t = texturesFor(*_compositor, white);
    media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    for (const TransitionKind kind : kShapes) {
        for (const std::optional<double> softness : {std::optional<double>(), std::optional<double>(9.5),
                                                     std::optional<double>(0.0)}) {
            const Project project = softnessProject(kind, softness);
            const auto problem = validateProject(project);
            XCTAssertFalse(problem.has_value(), @"%s", problem.value_or("").c_str());
            const Sequence &sequence = *project.activeSequence();
            const double expected = softness.value_or(kTransitionFeather);
            // Frame 27: the cut's transition (frames 25-34), both clips drawn.
            const RenderGraph cut = Scheduler::renderGraphAt(sequence, project, CMTimeMake(27, 30));
            XCTAssertEqual(cut.layers.size(), 2u, @"%s", nameOf(kind));
            for (const VideoLayer &layer : cut.layers) {
                XCTAssertTrue(layer.transition.has_value());
                if (layer.transition) {
                    XCTAssertEqual(layer.transition->kind, kind);
                    XCTAssertEqual(layer.transition->softness, expected, @"%s", nameOf(kind));
                }
            }
            // Frame 64 of the fade in (frames 60-69): its fifth frame, exposed over [3/10, 4/10].
            const RenderGraph fade = Scheduler::renderGraphAt(sequence, project, CMTimeMake(64, 30));
            XCTAssertEqual(fade.layers.size(), 1u, @"%s", nameOf(kind));
            if (fade.layers.size() != 1 || !fade.layers[0].transition) {
                XCTFail(@"%s: the fade's layer has no transition", nameOf(kind));
                continue;
            }
            XCTAssertEqual(fade.layers[0].transition->softness, expected, @"%s", nameOf(kind));
            XCTAssertEqual(fade.layers[0].transition->role, TransitionRole::FadeIn);
            [self render:fade textures:{t} out:out];
            [self check:out
                   kind:kind
               softness:expected
               interval:{0.3, 0.4}
                   from:{0, 0, 0, 255}
                     to:{255, 255, 255, 255}
                  label:@"scheduled fade in"];
        }
    }
}

// The cross dissolve has no softness: whatever a layer carries, its draw is the uniform mix.
- (void)testTheCrossDissolveIgnoresSoftness {
    media::PixelBuffer red = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    media::PixelBuffer blue = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    fillBGRA(red, {255, 0, 0, 255});
    fillBGRA(blue, {0, 0, 255, 255});
    const TextureSet a = texturesFor(*_compositor, red);
    const TextureSet b = texturesFor(*_compositor, blue);
    std::vector<RGBA8> first;
    for (const double softness : {kTransitionFeather, 0.0, 300.0}) {
        media::PixelBuffer out = makeBuffer(kCVPixelFormatType_32BGRA, kWidth, kHeight);
        RenderGraph g = makeGraph(kWidth, kHeight);
        VideoLayer outgoing = makeLayer(1);
        VideoLayer incoming = makeLayer(2);
        outgoing.transition =
            makeTransition(TransitionKind::CrossDissolve, softness, 0.25, 0.35, false, 1, incoming.clipId);
        incoming.transition =
            makeTransition(TransitionKind::CrossDissolve, softness, 0.25, 0.35, true, 0, outgoing.clipId);
        g.layers = {outgoing, incoming};
        [self render:g textures:{a, b} out:out];
        std::vector<RGBA8> pixels;
        for (int32_t y = 0; y < kHeight; ++y) {
            for (int32_t x = 0; x < kWidth; ++x) {
                pixels.push_back(pixelAt(out, size_t(x), size_t(y)));
            }
        }
        if (first.empty()) {
            first = pixels;
            XCTAssertTrue(pixels[0].r > 0 && pixels[0].r < 255 && pixels[0].b > 0 && pixels[0].b < 255); // a mix
        } else {
            XCTAssertTrue(std::equal(pixels.begin(), pixels.end(), first.begin(), [](RGBA8 l, RGBA8 r) {
                return l.r == r.r && l.g == r.g && l.b == r.b && l.a == r.a;
            }));
        }
    }
}

@end
