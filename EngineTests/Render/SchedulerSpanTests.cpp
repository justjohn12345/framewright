// The Scheduler evaluates effect spans and lane-0 transitions: layers carry the composed Motion at
// speeds other than 1, at 29.97 fps and on stills, each span holding its end value after its end
// (also in a dissolve's tail handle, and under a later span on its lane); asymmetric dissolves and
// fades to and from black mix at frame centres; the audio graph's level follows Gain spans exactly
// in dB (linear spans as one ramp, eased ones in steps of at most kEasedGainStep, a held level as
// flat segments), lane-0 fades and a 70/30 constant-power crossfade. Checked against the
// independent references of SpanReference.h.

#include "../../Engine/Render/Scheduler.h"
#include "../Edit/EditTestSupport.h"
#include "../Model/SpanReference.h"

#include <cmath>

using namespace vetest;

namespace {

using KI = KeyframeInterpolation;

bool close(double a, double b, double tolerance = 1e-9) {
    return std::fabs(a - b) <= tolerance * std::max(1.0, std::fabs(b));
}

const VideoLayer *layerOf(const RenderGraph &graph, ClipId clip) {
    for (const VideoLayer &layer : graph.layers) {
        if (layer.clipId == clip) {
            return &layer;
        }
    }
    return nullptr;
}

// The linear gain the mixer applies to `clip` at `t` (RenderGraph.h's law), from the graph's
// segments; nullopt when the clip does not sound then.
std::optional<double> gainAt(const AudioGraph &graph, ClipId clip, CMTime t) {
    for (const AudioSegment &segment : graph.segments) {
        if (segment.clipId != clip || !segment.timelineRange.contains(t)) {
            continue;
        }
        const double f = fractionThrough(segment.timelineRange, t);
        const double level = segment.level.start + (segment.level.end - segment.level.start) * f;
        const double fade = segment.fade.start + (segment.fade.end - segment.fade.start) * f;
        const double c = segment.crossfade.start + (segment.crossfade.end - segment.crossfade.start) * f;
        return decibelsToGain(level) * fade * (segment.transitionId ? constantPowerGain(c) : c);
    }
    return std::nullopt;
}

AudioGraph wholeAudio(const Fixture &fx) {
    return Scheduler::audioGraphFor(fx.sequence(), fx.project, TimeRange{kCMTimeZero, fx.sequence().duration()});
}

} // namespace

TEST_CASE("Scheduler spans: layers carry the composed Motion at speed 3/2, against the reference") {
    Fixture fx;
    // 60 frames at 3/2 from source 1 s: frame f shows source second 1 + f / 20.
    const ClipId id = fx.addClip(fx.v1, fx.av30, 0, 60, 30, 1.5);
    SpanTracks move;
    move.x = rampTrack(0, 300, CMTimeMake(2, 1), KI::EaseOut);
    move.rotation = rampTrack(0, 45, CMTimeMake(2, 1), KI::EaseOut);
    fx.addSpan(id, SpanKind::Motion, 1, CMTimeMake(3, 2), CMTimeMake(7, 2), move);
    SpanTracks fade;
    fade.opacity = rampTrack(1, 0, CMTimeMake(1, 1), KI::Linear);
    fx.addSpan(id, SpanKind::Opacity, 3, CMTimeMake(2, 1), CMTimeMake(3, 1), fade);
    fx.sequence().findClip(id)->video.opacity = 0.5;
    fx.requireValid();
    for (int f = 0; f < 60; ++f) {
        CAPTURE(f);
        const double s = 1 + f / 20.0;
        const RenderGraph graph = Scheduler::renderGraphAt(fx.sequence(), fx.project, f30(f));
        const VideoLayer *layer = layerOf(graph, id);
        REQUIRE(layer != nullptr);
        CHECK(close(layer->transform.x, referenceHeldSpanValue(1.5, 3.5, 0, 300, KI::EaseOut, s).value_or(0)));
        CHECK(close(layer->transform.rotationDegrees,
                    referenceHeldSpanValue(1.5, 3.5, 0, 45, KI::EaseOut, s).value_or(0)));
        CHECK(close(layer->opacity, 0.5 * referenceHeldSpanValue(2, 3, 1, 0, KI::Linear, s).value_or(1)));
        const VideoParams direct = Scheduler::motionAt(fx.clip(id), f30(f));
        CHECK(direct.x == layer->transform.x);
        CHECK(direct.opacity == layer->opacity);
    }
}

TEST_CASE("Scheduler spans: at 29.97 fps with an exact source time off every CMTime, the layer follows the span") {
    Fixture fx;
    fx.sequence().frameDuration = CMTimeMake(1001, 30000);
    Clip clip;
    clip.id = fx.project.ids.make<ClipId>();
    clip.assetId = fx.av24;
    clip.trackId = fx.v1;
    clip.timelineDuration = CMTimeMake(1001 * 90, 30000);
    clip.sourceIn = CMTimeMake(44101, 44100);
    clip.speed = Ratio{999, 1000};
    fx.track(fx.v1).clips.push_back(clip);
    fx.requireValid();
    AddSpan add(fx.seq, clip.id, SpanKind::Motion, 1, CMTimeMake(1001 * 10, 30000), CMTimeMake(1001 * 80, 30000));
    applyReversible(fx.project, add);
    SetSpanValues values(fx.seq, add.createdSpanId(), {SpanValueChange{SpanParameter::Scale, 1.0, 3.0}}, "Values",
                         KI::EaseInOut);
    applyReversible(fx.project, values);
    const EffectSpan &span = *fx.span(add.createdSpanId());
    const double start = seconds(span.start);
    const double end = seconds(span.end);
    for (int f = 0; f < 90; ++f) {
        CAPTURE(f);
        const CMTime t = CMTimeMake(1001 * f, 30000);
        const auto source = fx.clip(clip.id).exactSourceTimeAt(t);
        REQUIRE(source.has_value());
        const RenderGraph graph = Scheduler::renderGraphAt(fx.sequence(), fx.project, t);
        const VideoLayer *layer = layerOf(graph, clip.id);
        REQUIRE(layer != nullptr);
        const double want = f < 10    ? 1.0
                            : f >= 80 ? 3.0 // held from the span's end
                                      : *referenceSpanValue(start, end, 1, 3, KI::EaseInOut, source->toDouble());
        // The span's edges sit on the tick at or after the frames' exact source times, so the
        // reference in doubles agrees to within a tick's worth of the ramp.
        CHECK(close(layer->transform.scale, want, 1e-7));
    }
    // The first frame of the span shows its start value exactly, the frame before it nothing, and
    // every frame from its end on its end value exactly.
    const RenderGraph first = Scheduler::renderGraphAt(fx.sequence(), fx.project, CMTimeMake(1001 * 10, 30000));
    REQUIRE(layerOf(first, clip.id) != nullptr);
    CHECK(layerOf(first, clip.id)->transform.scale == 1.0);
    for (int f = 80; f < 90; ++f) {
        const RenderGraph held = Scheduler::renderGraphAt(fx.sequence(), fx.project, CMTimeMake(1001 * f, 30000));
        REQUIRE(layerOf(held, clip.id) != nullptr);
        CHECK(layerOf(held, clip.id)->transform.scale == 3.0);
    }
}

TEST_CASE("Scheduler spans: a still's spans are measured from its start") {
    Fixture fx;
    const ClipId still = fx.addClip(fx.v2, fx.still, 40, 60);
    SpanTracks grow;
    grow.scale = rampTrack(0.5, 1.5, f30(30), KI::EaseIn);
    fx.addSpan(still, SpanKind::Motion, 2, f30(15), f30(45), grow);
    fx.requireValid();
    for (int f = 40; f < 100; ++f) {
        const RenderGraph graph = Scheduler::renderGraphAt(fx.sequence(), fx.project, f30(f));
        const VideoLayer *layer = layerOf(graph, still);
        REQUIRE(layer != nullptr);
        CHECK(layer->sourceTime == kCMTimeZero);
        const double want = referenceHeldSpanValue(15, 45, 0.5, 1.5, KI::EaseIn, f - 40.0).value_or(1);
        CHECK(close(layer->transform.scale, want));
    }
}

TEST_CASE("Scheduler spans: a 70/30 dissolve mixes at frame centres across its asymmetric range") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    const SpanId t = fx.addTailTransition(a, 7, 3); // [53, 63)
    fx.requireValid();
    for (int f = 50; f < 66; ++f) {
        CAPTURE(f);
        const RenderGraph graph = Scheduler::renderGraphAt(fx.sequence(), fx.project, f30(f));
        const VideoLayer *out = layerOf(graph, a);
        const VideoLayer *in = layerOf(graph, b);
        if (f < 53 || f >= 63) {
            CHECK(graph.layers.size() == 1);
            CHECK_FALSE(graph.layers[0].transition.has_value());
            continue;
        }
        REQUIRE(out != nullptr);
        REQUIRE(in != nullptr);
        REQUIRE(out->transition.has_value());
        REQUIRE(in->transition.has_value());
        const double mix = (f - 53 + 0.5) / 10.0;
        CHECK(out->transition->transitionId == t);
        CHECK(out->transition->role == TransitionRole::CrossDissolve);
        CHECK(close(out->transition->mix, mix, 1e-12));
        CHECK(close(out->transition->weight(), 1 - mix, 1e-12));
        CHECK(close(in->transition->weight(), mix, 1e-12));
        CHECK(out->transition->partnerClipId == b);
        CHECK(&graph.layers[out->transition->partnerLayerIndex] == in);
        // Handles: A past its out point (source frame 90 on), B before its in point (300).
        if (f >= 60) {
            CHECK(out->sourceTime == f30(30 + f));
        } else {
            CHECK(in->sourceTime == f30(300 - (60 - f)));
        }
    }
}

TEST_CASE("Scheduler spans: fades from and to black are one layer weighted at frame centres") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.av30, 10, 60, 0);
    const SpanId in = fx.addFade(c, ClipEdge::Head, f30(12));
    const SpanId out = fx.addFade(c, ClipEdge::Tail, f30(8));
    fx.requireValid();
    for (int f = 10; f < 70; ++f) {
        CAPTURE(f);
        const RenderGraph graph = Scheduler::renderGraphAt(fx.sequence(), fx.project, f30(f));
        REQUIRE(graph.layers.size() == 1);
        const VideoLayer &layer = graph.layers[0];
        if (f < 22) {
            REQUIRE(layer.transition.has_value());
            CHECK(layer.transition->transitionId == in);
            CHECK(layer.transition->role == TransitionRole::FadeIn);
            CHECK(close(layer.transition->weight(), (f - 10 + 0.5) / 12.0, 1e-12));
            CHECK_FALSE(layer.transition->partnerClipId);
        } else if (f >= 62) {
            REQUIRE(layer.transition.has_value());
            CHECK(layer.transition->transitionId == out);
            CHECK(layer.transition->role == TransitionRole::FadeOut);
            CHECK(close(layer.transition->weight(), 1 - (f - 62 + 0.5) / 8.0, 1e-12));
        } else {
            CHECK_FALSE(layer.transition.has_value());
        }
    }
}

TEST_CASE("Scheduler spans: audio fades in and out are linear gains; the 70/30 crossfade is constant power") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.a1, fx.audioOnly, 0, 60, 0);
    const ClipId b = fx.addClip(fx.a1, fx.audioOnly, 60, 60, 600);
    fx.addTailTransition(a, 7, 3); // [53, 63)
    fx.addFade(a, ClipEdge::Head, f30(15));
    fx.addFade(b, ClipEdge::Tail, f30(20));
    fx.sequence().findClip(b)->audio.gainDb = -4;
    fx.requireValid();
    const AudioGraph graph = wholeAudio(fx);
    for (int k = 0; k < 120 * 8; ++k) {
        const CMTime t = CMTimeMake(k, 240);
        const double frame = k / 8.0;
        CAPTURE(frame);
        const auto ga = gainAt(graph, a, t);
        const auto gb = gainAt(graph, b, t);
        // Crossfade progress over [53, 63), the fade in over [0, 15), the fade out over [100, 120).
        const double p = std::clamp((frame - 53) / 10.0, 0.0, 1.0);
        const bool crossing = frame >= 53 && frame < 63;
        if (frame < 63) {
            REQUIRE(ga.has_value());
            const double fadeIn = std::min(1.0, frame / 15.0);
            CHECK(close(*ga, fadeIn * (crossing ? std::cos(p * M_PI / 2) : 1.0)));
        } else {
            CHECK_FALSE(ga.has_value());
        }
        if (frame >= 53) {
            REQUIRE(gb.has_value());
            const double fadeOut = std::min(1.0, (120 - frame) / 20.0);
            CHECK(close(*gb, std::pow(10, -4 / 20.0) * fadeOut * (crossing ? std::sin(p * M_PI / 2) : 1.0)));
        } else {
            CHECK_FALSE(gb.has_value());
        }
        if (crossing) {
            const double powerA = *ga * *ga;
            const double powerB = *gb * *gb / std::pow(10, -4 / 10.0);
            CHECK(close(powerA + powerB, 1.0)); // the fade in is complete by frame 15
        }
    }
    // At the cut the progress is 0.7 (seven frames before it, three after): A plays at
    // cos(0.7 pi / 2), B at sin(0.7 pi / 2) (times its -4 dB).
    CHECK(close(*gainAt(graph, a, f30(60)), std::cos(0.7 * M_PI / 2)));
    CHECK(close(*gainAt(graph, b, f30(60)), std::pow(10, -4 / 20.0) * std::sin(0.7 * M_PI / 2)));
}

TEST_CASE("Scheduler spans: Gain spans add decibels exactly; eased ones in steps of at most 5 ms; ends hold") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.a1, fx.audioOnly, 0, 90, 0);
    fx.sequence().findClip(c)->audio.gainDb = -2;
    SpanTracks ramp;
    ramp.gain = rampTrack(0, -18, CMTimeMake(1, 1), KI::Linear);
    fx.addSpan(c, SpanKind::Gain, 1, CMTimeMake(1, 2), CMTimeMake(3, 2), ramp);
    SpanTracks swell;
    swell.gain = rampTrack(0, 9, CMTimeMake(1, 1), KI::EaseInOut);
    fx.addSpan(c, SpanKind::Gain, 2, CMTimeMake(3, 2), CMTimeMake(5, 2), swell);
    fx.requireValid();
    const AudioGraph graph = wholeAudio(fx);
    // Segments: the linear span is one ramp in dB; the eased one is cut into steps.
    for (const AudioSegment &segment : graph.segments) {
        const double from = seconds(segment.timelineRange.start);
        const double to = seconds(segment.timelineRange.end);
        if (from >= 1.5 && to <= 2.5) {
            CHECK(to - from <= Scheduler::kEasedGainStep + 1e-12);
            // Exact at the step's edges (on top of the linear span's held -18 dB).
            CHECK(close(segment.level.start,
                        -2 - 18 + *referenceSpanValue(1.5, 2.5, 0, 9, KI::EaseInOut, from)));
        }
    }
    for (int k = 0; k < 720; ++k) {
        const double s = k / 240.0;
        const auto gain = gainAt(graph, c, CMTimeMake(k, 240));
        REQUIRE(gain.has_value());
        const double db = -2 + referenceHeldSpanValue(0.5, 1.5, 0, -18, KI::Linear, s).value_or(0) +
                          referenceHeldSpanValue(1.5, 2.5, 0, 9, KI::EaseInOut, s).value_or(0);
        CAPTURE(s);
        // Linear in dB is exact; the eased span between its 5 ms steps is within 0.01 dB.
        CHECK(std::fabs(20 * std::log10(*gain) - db) < (s >= 1.5 && s < 2.5 ? 0.01 : 1e-9));
    }
    // From 1.5 s the linear span holds its -18 dB (the eased one starts there, at 0 dB of its own);
    // from 2.5 s both end levels hold: one flat segment to the clip's end.
    CHECK(close(20 * std::log10(*gainAt(graph, c, CMTimeMake(3, 2))), -20.0));
    CHECK(close(20 * std::log10(*gainAt(graph, c, CMTimeMake(3, 2) - CMTimeMake(1, 48000))),
                -2 - 18 * (1 - 1.0 / 48000), 1e-6));
    std::size_t heldSegments = 0;
    for (const AudioSegment &segment : graph.segments) {
        if (segment.timelineRange.start >= CMTimeMake(5, 2)) {
            ++heldSegments;
            CHECK(segment.level.start == -2 - 18 + 9);
            CHECK(segment.level.end == -2 - 18 + 9);
        }
    }
    CHECK(heldSegments == 1);
}

TEST_CASE("Scheduler spans: a Gain span whose start has no CMTime on the timeline acts from its start (review L10)") {
    // At 7x the timeline time of a span starting one tick (1/705600000 s) after source second 1 is
    // 1/7 s + 1/4939200000 s: no CMTime, so the audio plan's cut there is rounded, here to the tick
    // before it, whose source time (exactly 1 s) is before the span's start. The level over the
    // piece from that cut must still include the span.
    Fixture fx;
    const ClipId c = fx.addClip(fx.a1, fx.audioOnly, 0, 90, 0, 7.0);
    const CMTime start = CMTimeMake(kPreciseTimescale + 1, kPreciseTimescale);
    const CMTime end = CMTimeMake(8, 1);
    SpanTracks ramp;
    ramp.gain = rampTrack(-6, -30, end - start, KI::Linear);
    fx.addSpan(c, SpanKind::Gain, 1, start, end, ramp);
    fx.requireValid();
    REQUIRE_FALSE(fx.clip(c).exactTimelineTimeAt(start)->toTime().has_value());
    const AudioGraph graph = wholeAudio(fx);
    for (int k = 1; k < 240; ++k) {
        const CMTime t = CMTimeMake(k, 240);
        const auto gain = gainAt(graph, c, t);
        REQUIRE(gain.has_value());
        const auto source = fx.clip(c).exactSourceTimeAt(t);
        REQUIRE(source.has_value());
        const double want = composeGainDb(fx.clip(c), *source);
        CAPTURE(k);
        CHECK(std::fabs(20 * std::log10(*gain) - want) < 1e-6);
    }
}

TEST_CASE("Scheduler spans: a short plan window of a long eased Gain span cuts only its own steps (review L10)") {
    // stepsWithin never leaves out a step inside the window, against brute force.
    const CMTime from = CMTimeMake(1, 3);
    const CMTime to = CMTimeMake(611, 3); // 203.33 s: 40667 steps of 5 ms
    const auto steps = static_cast<std::int64_t>(std::ceil(seconds(to - from) / Scheduler::kEasedGainStep));
    for (const auto &[a, b] : std::vector<std::pair<CMTime, CMTime>>{
             {CMTimeMake(0, 1), CMTimeMake(1, 2)}, {CMTimeMake(100, 1), CMTimeMake(2002, 20)},
             {CMTimeMake(7, 48000), CMTimeMake(1031, 48000)}, {CMTimeMake(203, 1), CMTimeMake(300, 1)},
             {CMTimeMake(500, 1), CMTimeMake(501, 1)}}) {
        const TimeRange window{a, b};
        const auto within = Scheduler::stepsWithin(from, to, steps, window);
        std::int64_t inside = 0;
        for (std::int64_t k = 1; k < steps; ++k) {
            const CMTime t = from + scaleTime(to - from, Ratio{k, steps});
            if (a < t && t < b) {
                ++inside;
                REQUIRE(within.has_value());
                CHECK(within->first <= k);
                CHECK(k <= within->second);
            }
        }
        if (within) {
            CHECK(within->second - within->first + 1 <= inside + 4); // its own steps, two either side at most
        }
    }
    // The graph of a short window is the whole graph's there.
    Fixture fx;
    const ClipId c = fx.addClip(fx.a1, fx.audioOnly, 0, 900, 0);
    SpanTracks swell;
    swell.gain = rampTrack(0, 9, CMTimeMake(28, 1), KI::EaseInOut);
    fx.addSpan(c, SpanKind::Gain, 1, CMTimeMake(1, 1), CMTimeMake(29, 1), swell);
    fx.requireValid();
    const AudioGraph whole = wholeAudio(fx);
    const TimeRange window{CMTimeMake(12, 1), CMTimeMake(12, 1) + CMTimeMake(1, 50)};
    const AudioGraph part = Scheduler::audioGraphFor(fx.sequence(), fx.project, window);
    REQUIRE(part.segments.size() >= 4);
    for (int k = 0; k < 20; ++k) {
        const CMTime t = window.start + CMTimeMake(k, 1000);
        CHECK(close(*gainAt(part, c, t), *gainAt(whole, c, t), 1e-12));
    }
}

TEST_CASE("Scheduler spans: held values per frame at 29.97 and 999/1000, on a chained lane, a still, a tail handle") {
    Fixture fx;
    fx.sequence().frameDuration = CMTimeMake(1001, 30000);
    // V1: 120 NTSC frames of av24 at 999/1000 from an in point with no 30000 form, a Motion move
    // over frames [10, 40) held, then a second move on the same lane over [70, 100) starting
    // neutral; an Opacity span on lane 2 over [20, 50) held. It ends in a cross dissolve into the
    // next clip (6 frames before the cut, 4 after), whose tail handle frames keep the held values.
    // V2: a still whose span over its frames [5, 25) holds.
    auto ntsc = [](std::int64_t frames) { return CMTimeMake(1001 * frames, 30000); };
    Clip clip;
    clip.id = fx.project.ids.make<ClipId>();
    clip.assetId = fx.av24;
    clip.trackId = fx.v1;
    clip.timelineDuration = ntsc(120);
    clip.sourceIn = CMTimeMake(44101, 44100);
    clip.speed = Ratio{999, 1000};
    EffectSpan dissolve;
    dissolve.id = fx.project.ids.make<SpanId>();
    dissolve.lane = kTransitionLane;
    dissolve.kind = SpanKind::Transition;
    dissolve.edge = ClipEdge::Tail;
    dissolve.start = -ntsc(6);
    dissolve.end = ntsc(4);
    clip.spans.push_back(dissolve);
    fx.track(fx.v1).clips.push_back(clip);
    Clip next;
    next.id = fx.project.ids.make<ClipId>();
    next.assetId = fx.av24;
    next.trackId = fx.v1;
    next.timelineStart = ntsc(120);
    next.timelineDuration = ntsc(30);
    next.sourceIn = CMTimeMake(10, 1);
    fx.track(fx.v1).clips.push_back(next);
    const ClipId still = fx.addClip(fx.v2, fx.still, 0, 60);
    fx.sequence().findClip(still)->timelineDuration = ntsc(60);
    SpanTracks grow;
    grow.scale = rampTrack(1, 1.4, f30(20), KI::EaseOut);
    fx.addSpan(still, SpanKind::Motion, 1, f30(5), f30(25), grow);
    fx.requireValid();
    auto add = [&](SpanKind kind, int lane, std::int64_t from, std::int64_t to) {
        AddSpan command(fx.seq, clip.id, kind, lane, ntsc(from), ntsc(to));
        applyReversible(fx.project, command);
        return command.createdSpanId();
    };
    const SpanId first = add(SpanKind::Motion, 1, 10, 40);
    SetSpanValues firstValues(fx.seq, first,
                              {SpanValueChange{SpanParameter::Scale, 1.0, 2.0},
                               SpanValueChange{SpanParameter::X, 0.0, -300.0}},
                              "Values", KI::EaseInOut);
    applyReversible(fx.project, firstValues);
    const SpanId second = add(SpanKind::Motion, 1, 70, 100);
    SetSpanValues secondValues(fx.seq, second,
                               {SpanValueChange{SpanParameter::Scale, 1.0, 0.75},
                                SpanValueChange{SpanParameter::X, 0.0, 120.0}});
    applyReversible(fx.project, secondValues);
    const SpanId dim = add(SpanKind::Opacity, 2, 20, 50);
    SetSpanValues dimValues(fx.seq, dim, {SpanValueChange{SpanParameter::Opacity, 1.0, 0.6}});
    applyReversible(fx.project, dimValues);
    const Clip &c = fx.clip(clip.id);
    auto edge = [&](SpanId id, bool atEnd) { return seconds(atEnd ? fx.span(id)->end : fx.span(id)->start); };
    for (int f = 0; f < 124; ++f) {
        CAPTURE(f);
        const CMTime t = ntsc(f);
        const RenderGraph graph = Scheduler::renderGraphAt(fx.sequence(), fx.project, t);
        const VideoLayer *layer = layerOf(graph, clip.id);
        REQUIRE(layer != nullptr);
        CHECK(layer->transform == motionValuesAt(c, t));
        const auto source = c.exactSourceTimeAt(minTime(t, c.timelineEnd()));
        REQUIRE(source.has_value());
        const double s = source->toDouble();
        const double scale =
            referenceHeldSpanValue(edge(first, false), edge(first, true), 1, 2, KI::EaseInOut, s).value_or(1) *
            referenceHeldSpanValue(edge(second, false), edge(second, true), 1, 0.75, KI::Linear, s).value_or(1);
        const double opacity =
            referenceHeldSpanValue(edge(dim, false), edge(dim, true), 1, 0.6, KI::Linear, s).value_or(1);
        // The span edges sit on the tick at or after the frames' exact source times.
        CHECK(close(layer->transform.scale, scale, 1e-7));
        CHECK(close(layer->opacity, opacity, 1e-7));
        if (f >= 40 && f <= 70) {
            // Between the moves the first one's end holds exactly, the second's first frame too.
            CHECK(layer->transform.scale == 2.0);
            CHECK(layer->transform.x == -300.0);
        }
        if (f >= 100) {
            // Both ends held, one on top of the other, through the dissolve's tail handle (frames
            // 120-123 lie past the clip's end).
            CHECK(layer->transform.scale == 2.0 * 0.75);
            CHECK(layer->transform.x == -300.0 + 120.0);
            CHECK(layer->opacity == 0.6);
        }
        if (f >= 114) {
            REQUIRE(layer->transition.has_value());
            CHECK_FALSE(layer->transition->isIncoming);
        }
    }
    for (int f = 0; f < 60; ++f) {
        const RenderGraph graph = Scheduler::renderGraphAt(fx.sequence(), fx.project, ntsc(f));
        const VideoLayer *layer = layerOf(graph, still);
        REQUIRE(layer != nullptr);
        CAPTURE(f);
        // The still's time is its timeline offset: frame f is 1001 f / 30000 s into it.
        const double into = f * 1001.0 / 30000.0 * 30.0; // in 30 fps frames
        const double want = referenceHeldSpanValue(5, 25, 1, 1.4, KI::EaseOut, into).value_or(1);
        CHECK(close(layer->transform.scale, want, 1e-7));
    }
}

TEST_CASE("Scheduler spans: a held gain is flat; a chained eased span ramps from it; a tail crossfade keeps it") {
    Fixture fx;
    // A1: a 120-frame clip at -1 dB; lane 1 ducks -12 dB over [0.5 s, 1 s) (linear), then swells
    // +8 dB over [2 s, 2.5 s) easing in and out, starting neutral (from the held -13 dB). It ends in
    // a crossfade into the next clip (10 frames before the cut, 5 after) whose outgoing handle keeps
    // the held -5 dB.
    const ClipId c = fx.addClip(fx.a1, fx.audioOnly, 0, 120, 0);
    const ClipId n = fx.addClip(fx.a1, fx.audioOnly, 120, 60, 300);
    fx.sequence().findClip(c)->audio.gainDb = -1;
    SpanTracks duck;
    duck.gain = rampTrack(0, -12, CMTimeMake(1, 2));
    fx.addSpan(c, SpanKind::Gain, 1, CMTimeMake(1, 2), CMTimeMake(1, 1), duck);
    SpanTracks swell;
    swell.gain = rampTrack(0, 8, CMTimeMake(1, 2), KI::EaseInOut);
    fx.addSpan(c, SpanKind::Gain, 1, CMTimeMake(2, 1), CMTimeMake(5, 2), swell);
    fx.addTailTransition(c, 10, 5); // [110, 125)
    fx.requireValid();
    const AudioGraph graph = wholeAudio(fx);
    const double held = -1 - 12;
    int eased = 0;
    for (const AudioSegment &segment : graph.segments) {
        if (segment.clipId != c) {
            continue;
        }
        const double from = seconds(segment.timelineRange.start);
        const double to = seconds(segment.timelineRange.end);
        CAPTURE(from);
        if (from >= 1 && to <= 2) {
            // The hold between the spans: one flat segment at the held level.
            CHECK(segment.level.start == held);
            CHECK(segment.level.end == held);
            CHECK(from == 1.0);
            CHECK(to == 2.0);
        } else if (from >= 2 && to <= 2.5) {
            // The eased swell: steps of at most 5 ms on top of the held level, starting there.
            ++eased;
            CHECK(to - from <= Scheduler::kEasedGainStep + 1e-12);
            CHECK(close(segment.level.start, held + *referenceSpanValue(2, 2.5, 0, 8, KI::EaseInOut, from)));
            if (from == 2.0) {
                CHECK(segment.level.start == held);
            }
        } else if (from >= 2.5) {
            // Both ends held to the clip's end and through the crossfade's handle.
            CHECK(segment.level.start == held + 8);
            CHECK(segment.level.end == held + 8);
        }
    }
    CHECK(eased >= 100);
    for (int k = 0; k < 125 * 8; ++k) {
        const CMTime t = CMTimeMake(k, 240);
        const double s = k / 240.0;
        CAPTURE(s);
        const auto gain = gainAt(graph, c, t);
        REQUIRE(gain.has_value());
        const double db = -1 + referenceHeldSpanValue(0.5, 1, 0, -12, KI::Linear, s).value_or(0) +
                          referenceHeldSpanValue(2, 2.5, 0, 8, KI::EaseInOut, s).value_or(0);
        const double progress = std::clamp((k / 8.0 - 110) / 15.0, 0.0, 1.0);
        const double shape = k / 8.0 >= 110 ? std::cos(progress * M_PI / 2) : 1.0;
        const double level = 20 * std::log10(*gain / shape);
        const double tolerance = s >= 2 && s < 2.5 ? 0.01 : 1e-9; // the eased swell is followed in steps
        CHECK(std::fabs(level - db) < tolerance);
        // The mixer's level is what the model's composition says (in the clip and in its handle).
        CHECK(std::fabs(level - gainDbAt(fx.clip(c), t)) < tolerance);
    }
    (void)n;
}
