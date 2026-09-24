// The Scheduler evaluates effect spans and lane-0 transitions: layers carry the composed Motion at
// speeds other than 1, at 29.97 fps and on stills; asymmetric dissolves and fades to and from black
// mix at frame centres; the audio graph's level follows Gain spans exactly in dB (linear spans as
// one ramp, eased ones in steps of at most kEasedGainStep), lane-0 fades and a 70/30 constant-power
// crossfade. Checked against the independent references of SpanReference.h.

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
        CHECK(close(layer->transform.x, referenceSpanValue(1.5, 3.5, 0, 300, KI::EaseOut, s).value_or(0)));
        CHECK(close(layer->transform.rotationDegrees, referenceSpanValue(1.5, 3.5, 0, 45, KI::EaseOut, s).value_or(0)));
        CHECK(close(layer->opacity, 0.5 * referenceSpanValue(2, 3, 1, 0, KI::Linear, s).value_or(1)));
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
        const double want = f < 10 || f >= 80 ? 1.0
                                              : *referenceSpanValue(start, end, 1, 3, KI::EaseInOut, source->toDouble());
        // The span's edges sit on the tick at or after the frames' exact source times, so the
        // reference in doubles agrees to within a tick's worth of the ramp.
        CHECK(close(layer->transform.scale, want, 1e-7));
    }
    // The first frame of the span shows its start value exactly, the frame before it nothing.
    const RenderGraph first = Scheduler::renderGraphAt(fx.sequence(), fx.project, CMTimeMake(1001 * 10, 30000));
    REQUIRE(layerOf(first, clip.id) != nullptr);
    CHECK(layerOf(first, clip.id)->transform.scale == 1.0);
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
        CHECK(close(layer->transform.scale, referenceSpanValue(15, 45, 0.5, 1.5, KI::EaseIn, f - 40.0).value_or(1)));
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

TEST_CASE("Scheduler spans: Gain spans add decibels exactly; eased ones in steps of at most 5 ms") {
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
            // Exact at the step's edges.
            CHECK(close(segment.level.start,
                        -2 + *referenceSpanValue(1.5, 2.5, 0, 9, KI::EaseInOut, from)));
        }
    }
    for (int k = 0; k < 720; ++k) {
        const double s = k / 240.0;
        const auto gain = gainAt(graph, c, CMTimeMake(k, 240));
        REQUIRE(gain.has_value());
        const double db = -2 + referenceSpanValue(0.5, 1.5, 0, -18, KI::Linear, s).value_or(0) +
                          referenceSpanValue(1.5, 2.5, 0, 9, KI::EaseInOut, s).value_or(0);
        CAPTURE(s);
        // Linear in dB is exact; the eased span between its 5 ms steps is within 0.01 dB.
        CHECK(std::fabs(20 * std::log10(*gain) - db) < (s >= 1.5 && s < 2.5 ? 0.01 : 1e-9));
    }
    // A span's end is exclusive: at 1.5 s the linear span no longer acts (its -18 dB is gone).
    CHECK(close(20 * std::log10(*gainAt(graph, c, CMTimeMake(3, 2))), -2.0));
    CHECK(close(20 * std::log10(*gainAt(graph, c, CMTimeMake(3, 2) - CMTimeMake(1, 48000))),
                -2 - 18 * (1 - 1.0 / 48000), 1e-6));
}
