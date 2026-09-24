#include "../../Engine/Edit/EditOps.h"
#include "../../Engine/Render/Scheduler.h"
#include "../Edit/EditTestSupport.h"

#include <cmath>

using namespace vetest;

namespace {

RenderGraph graphAt(const Fixture &fx, std::int64_t frame) {
    return Scheduler::renderGraphAt(fx.sequence(), fx.project, f30(frame));
}

std::vector<ClipId> layerClips(const RenderGraph &graph) {
    std::vector<ClipId> ids;
    for (const VideoLayer &layer : graph.layers) {
        ids.push_back(layer.clipId);
    }
    return ids;
}

AudioGraph audioFor(const Fixture &fx, std::int64_t startFrame, std::int64_t endFrame) {
    return Scheduler::audioGraphFor(fx.sequence(), fx.project, TimeRange{f30(startFrame), f30(endFrame)});
}

std::vector<const AudioSegment *> segmentsOf(const AudioGraph &graph, ClipId clip) {
    std::vector<const AudioSegment *> result;
    for (const AudioSegment &segment : graph.segments) {
        if (segment.clipId == clip) {
            result.push_back(&segment);
        }
    }
    return result;
}

} // namespace

TEST_CASE("Scheduler: layers stack bottom to top across overlapping tracks; gaps are empty") {
    Fixture fx;
    const ClipId low = fx.addClip(fx.v1, fx.av30, 0, 60);
    const ClipId high = fx.addClip(fx.v2, fx.av30, 30, 60, 300);
    const ClipId late = fx.addClip(fx.v1, fx.av30, 120, 30);
    fx.sequence().findClip(high)->video = VideoParams{10, 20, 0.5, 90, 0.25};
    fx.requireValid();

    CHECK(layerClips(graphAt(fx, 15)) == std::vector<ClipId>{low});
    const RenderGraph both = graphAt(fx, 45);
    CHECK(layerClips(both) == std::vector<ClipId>{low, high});
    CHECK(both.width == 1920);
    CHECK(both.height == 1080);
    CHECK(both.time == f30(45));
    CHECK(both.layers[1].transform == VideoParams{10, 20, 0.5, 90, 0.25});
    CHECK(both.layers[1].opacity == 0.25);
    CHECK(both.layers[1].trackId == fx.v2);
    CHECK(both.layers[1].assetId == fx.av30);
    CHECK_FALSE(both.layers[0].transition.has_value());
    CHECK(both.layers[1].sourceTime == f30(315));
    CHECK(layerClips(graphAt(fx, 75)) == std::vector<ClipId>{high});
    CHECK(graphAt(fx, 100).isEmpty()); // gap inside the sequence
    CHECK(layerClips(graphAt(fx, 149)) == std::vector<ClipId>{late});
}

TEST_CASE("Scheduler: times outside the sequence give empty graphs; times snap down to the frame") {
    Fixture fx;
    fx.addClip(fx.v1, fx.av30, 0, 30);
    CHECK(graphAt(fx, -1).isEmpty());
    CHECK(graphAt(fx, 30).isEmpty());
    CHECK(graphAt(fx, 3000).isEmpty());
    CHECK(Scheduler::renderGraphAt(fx.sequence(), fx.project, kCMTimeInvalid).isEmpty());
    const RenderGraph mid = Scheduler::renderGraphAt(fx.sequence(), fx.project, CMTimeMake(105, 300)); // 10.5 frames
    CHECK(mid.time == f30(10));
    REQUIRE(mid.layers.size() == 1);
    CHECK(mid.layers[0].sourceTime == f30(10));
    Fixture empty;
    CHECK(Scheduler::renderGraphAt(empty.sequence(), empty.project, kCMTimeZero).isEmpty());
}

TEST_CASE("Scheduler: cross dissolve emits both clips with a linear mix sampled at frame centres") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);   // source 30..90
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300); // source 300..360
    fx.addTransition(fx.v1, a, b, 20);                        // [50, 70)
    fx.requireValid();

    CHECK(layerClips(graphAt(fx, 49)) == std::vector<ClipId>{a});

    const RenderGraph start = graphAt(fx, 50);
    REQUIRE(layerClips(start) == std::vector<ClipId>{a, b});
    REQUIRE(start.layers[0].transition.has_value());
    REQUIRE(start.layers[1].transition.has_value());
    // Frame 0 of 20 shows the mix at its centre: 0.5 / 20.
    CHECK(start.layers[0].transition->mix == doctest::Approx(0.025));
    CHECK(start.layers[0].transition->weight() == doctest::Approx(0.975));
    CHECK(start.layers[1].transition->weight() == doctest::Approx(0.025));
    CHECK_FALSE(start.layers[0].transition->isIncoming);
    CHECK(start.layers[1].transition->isIncoming);
    CHECK(start.layers[0].transition->partnerLayerIndex == 1);
    CHECK(start.layers[1].transition->partnerLayerIndex == 0);
    CHECK(start.layers[0].transition->partnerClipId == b);
    CHECK(start.layers[1].transition->partnerClipId == a);
    CHECK(start.layers[0].sourceTime == f30(80));
    CHECK(start.layers[1].sourceTime == f30(290)); // incoming handle before its in point

    const RenderGraph middle = graphAt(fx, 60);
    REQUIRE(middle.layers.size() == 2);
    CHECK(middle.layers[0].transition->mix == doctest::Approx(10.5 / 20.0));
    CHECK(middle.layers[1].transition->weight() == doctest::Approx(10.5 / 20.0));
    CHECK(middle.layers[0].sourceTime == f30(90)); // outgoing handle past its out point
    CHECK(middle.layers[1].sourceTime == f30(300));

    const RenderGraph last = graphAt(fx, 69);
    REQUIRE(last.layers.size() == 2);
    CHECK(last.layers[1].transition->mix == doctest::Approx(19.5 / 20.0)); // the outgoing clip still shows
    CHECK(last.layers[0].sourceTime == f30(99));

    CHECK(layerClips(graphAt(fx, 70)) == std::vector<ClipId>{b});
    CHECK_FALSE(graphAt(fx, 70).layers[0].transition.has_value());
}

TEST_CASE("Scheduler: short dissolves are symmetric and match the audio crossfade at frame centres") {
    for (const std::int64_t frames : {1, 2, 3}) {
        CAPTURE(frames);
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
        const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
        const ClipId aa = fx.addClip(fx.a1, fx.av30, 0, 60, 30);
        const ClipId ab = fx.addClip(fx.a1, fx.av30, 60, 60, 300);
        fx.addTransition(fx.v1, a, b, frames);
        fx.addTransition(fx.a1, aa, ab, frames);
        fx.requireValid();
        const TimeRange range = findTransition(fx.sequence(), fx.clip(a).transitionAt(ClipEdge::Tail)->id)->range;
        const std::int64_t first = frameIndexAt(range.start, f30(1), SnapMode::Floor);
        for (std::int64_t k = 0; k < frames; ++k) {
            const RenderGraph g = graphAt(fx, first + k);
            REQUIRE(g.layers.size() == 2);
            const double mix = g.layers[0].transition->mix;
            CHECK(mix == doctest::Approx((static_cast<double>(k) + 0.5) / static_cast<double>(frames)));
            // Mirror symmetry: frame k and frame n-1-k mix to complementary weights.
            const RenderGraph mirror = graphAt(fx, first + frames - 1 - k);
            CHECK(mirror.layers[0].transition->mix == doctest::Approx(1.0 - mix));
            // The incoming clip's audio crossfade progress at the frame's midpoint equals the mix.
            const AudioGraph audio = audioFor(fx, first + k, first + k + 1);
            const auto incoming = segmentsOf(audio, ab);
            REQUIRE(incoming.size() == 1);
            const double midpoint = (incoming[0]->crossfade.start + incoming[0]->crossfade.end) / 2.0;
            CHECK(midpoint == doctest::Approx(mix));
        }
        // A one-frame dissolve is an even mix and never shows the outgoing clip at its out point
        // alone.
        if (frames == 1) {
            CHECK(graphAt(fx, first).layers[0].transition->weight() == doctest::Approx(0.5));
        }
    }
}

TEST_CASE("Scheduler: a transition under another track keeps layer order and partner indices") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v2, fx.av30, 0, 60, 30);
    const ClipId b = fx.addClip(fx.v2, fx.av30, 60, 60, 300);
    const ClipId base = fx.addClip(fx.v1, fx.av30, 0, 120);
    fx.addTransition(fx.v2, a, b, 10);
    const RenderGraph g = graphAt(fx, 58);
    REQUIRE(layerClips(g) == std::vector<ClipId>{base, a, b});
    CHECK(g.layers[1].transition->partnerLayerIndex == 2);
    CHECK(g.layers[2].transition->partnerLayerIndex == 1);
    CHECK(g.layers[1].transition->mix == doctest::Approx(0.35)); // frame 3 of [55, 65): 3.5 / 10
}

TEST_CASE("Scheduler: clip speed maps timeline time to source time") {
    Fixture fx;
    const ClipId fast = fx.addClip(fx.v1, fx.av30, 0, 30, 10, 2.0);    // source 10..70 @30
    const ClipId slow = fx.addClip(fx.v2, fx.video60, 0, 30, 10, 0.5); // source 10/30 s .. +0.5 s @60
    const ClipId slow30 = fx.addClip(fx.v1, fx.av30, 60, 30, 10, 0.5); // 30 fps source at half speed
    fx.requireValid();
    const RenderGraph g = graphAt(fx, 5);
    REQUIRE(layerClips(g) == std::vector<ClipId>{fast, slow});
    CHECK(g.layers[0].sourceTime == f30(20));            // 10 + 2 * 5
    CHECK(g.layers[1].sourceTime == CMTimeMake(25, 60)); // 20/60 + 0.5 * 10/60
    // Half speed on a 30 fps source lands between frames 12 and 13 at 12.5: frame 12 is on
    // screen until 13 starts.
    CHECK(graphAt(fx, 64).layers[0].sourceTime == f30(12));
    CHECK(graphAt(fx, 65).layers[0].sourceTime == f30(12));
    CHECK(graphAt(fx, 66).layers[0].sourceTime == f30(13));
    CHECK(graphAt(fx, 65).layers[0].clipId == slow30);
}

TEST_CASE("Scheduler: source time snaps down to the frame of a 23.976 source that is on screen") {
    Fixture fx;
    fx.addClip(fx.v1, fx.av24, 0, 300);
    const CMTime k23976 = CMTimeMake(1001, 24000);
    CHECK(identical(graphAt(fx, 30).layers[0].sourceTime, timeForFrame(23, k23976))); // 1 s = 23.976 frames
    CHECK(identical(graphAt(fx, 45).layers[0].sourceTime, timeForFrame(35, k23976))); // 1.5 s = 35.96
    CHECK(identical(graphAt(fx, 1).layers[0].sourceTime, timeForFrame(0, k23976)));   // 0.8 frames
    CHECK(graphAt(fx, 0).layers[0].sourceTime == kCMTimeZero);
    // Every timeline frame shows the source frame whose display interval contains its time.
    for (std::int64_t f = 0; f < 300; ++f) {
        const CMTime shown = graphAt(fx, f).layers[0].sourceTime;
        CHECK(shown <= f30(f));
        CHECK(f30(f) < shown + k23976);
    }
}

TEST_CASE("Scheduler: at slow speeds the last frame of a clip stays inside its source range (review finding 2)") {
    for (const double speed : {0.5, 0.4, 0.999, 1.0 / 3.0}) {
        CAPTURE(speed);
        Fixture fx;
        const Ratio ratio = speedFromDouble(speed);
        // 30 source frames [0, 30) at this speed, rounded down to whole timeline frames.
        const auto timeline = ExactTime::from(f30(30))->dividedBy(ratio);
        const std::int64_t frames = *timeline->frameIndex(f30(1), SnapMode::Floor);
        const ClipId c = fx.addClip(fx.v1, fx.av30, 0, frames, 0, speed);
        fx.requireValid();
        const CMTime out = fx.clip(c).sourceOut();
        for (std::int64_t f = 0; f < frames; ++f) {
            const CMTime shown = graphAt(fx, f).layers[0].sourceTime;
            CHECK(shown < out);
            CHECK(shown <= fx.clip(c).sourceTimeAt(f30(f)));
        }
        if (speed != 0.999) { // at 0.999 the last timeline frame samples source frame 28.97
            CHECK(graphAt(fx, frames - 1).layers[0].sourceTime == f30(29));
        }
    }
    // Directly: a source frame grid finer than the mapping still stops before the out point.
    Fixture fx;
    const ClipId c = fx.addClip(fx.v1, fx.video60, 0, 30, 0, 0.5); // source [0, 0.5 s) at 60 fps
    const MediaAsset &asset = *fx.project.findAsset(fx.video60);
    const Clip &clip = fx.clip(c);
    CHECK(Scheduler::sourceFrameTime(clip, asset, f30(29)) == CMTimeMake(29, 60));
    // In a transition handle (outside the clip) the mapping may pass the out point.
    CHECK(Scheduler::sourceFrameTime(clip, asset, f30(31)) == CMTimeMake(31, 60));
}

TEST_CASE("Scheduler: layers carry the asset's container rotation") {
    Fixture fx;
    fx.project.findAsset(fx.av30)->rotationDegrees = 90;
    fx.addClip(fx.v1, fx.av30, 0, 30);
    fx.addClip(fx.v2, fx.video60, 0, 30);
    const RenderGraph g = graphAt(fx, 0);
    REQUIRE(g.layers.size() == 2);
    CHECK(g.layers[0].sourceRotationDegrees == 90);
    CHECK(g.layers[1].sourceRotationDegrees == 0);
}

TEST_CASE("Scheduler: transitions on muted or non-solo tracks are not drawn or heard") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v2, fx.av30, 0, 60, 30);
    const ClipId b = fx.addClip(fx.v2, fx.av30, 60, 60, 300);
    const ClipId base = fx.addClip(fx.v1, fx.av30, 0, 120);
    const ClipId aa = fx.addClip(fx.a1, fx.av30, 0, 60, 30);
    const ClipId ab = fx.addClip(fx.a1, fx.av30, 60, 60, 300);
    fx.addTransition(fx.v2, a, b, 10);
    fx.addTransition(fx.a1, aa, ab, 10);
    fx.requireValid();
    fx.track(fx.v2).muted = true;
    CHECK(layerClips(graphAt(fx, 58)) == std::vector<ClipId>{base});
    fx.track(fx.v2).muted = false;
    fx.track(fx.v1).solo = true;
    CHECK(layerClips(graphAt(fx, 58)) == std::vector<ClipId>{base});
    fx.track(fx.v2).solo = true;
    CHECK(layerClips(graphAt(fx, 58)) == std::vector<ClipId>{base, a, b});
    fx.track(fx.a1).muted = true;
    CHECK(audioFor(fx, 50, 70).segments.empty());
    fx.track(fx.a1).muted = false;
    fx.track(fx.a2).solo = true;
    CHECK(audioFor(fx, 50, 70).segments.empty());
}

TEST_CASE("Scheduler: VFR sources are not snapped; source time stays inside the media") {
    Fixture fx;
    fx.project.findAsset(fx.video60)->isVFR = true;
    fx.addClip(fx.v1, fx.video60, 0, 30, 0, 0.5);
    CHECK(identical(graphAt(fx, 1).layers[0].sourceTime, CMTimeMake(1, 60)));

    Fixture end;
    const ClipId last = end.addClip(end.v1, end.av30, 0, 30, 1770); // last frame of the media
    CHECK(graphAt(end, 29).layers[0].sourceTime == f30(1799));
    CHECK(graphAt(end, 29).layers[0].clipId == last);
}

TEST_CASE("Scheduler: stills always show source time zero") {
    Fixture fx;
    const ClipId s = fx.addClip(fx.v1, fx.still, 10, 150);
    const RenderGraph g = graphAt(fx, 100);
    REQUIRE(layerClips(g) == std::vector<ClipId>{s});
    CHECK(g.layers[0].isStill);
    CHECK(g.layers[0].sourceTime == kCMTimeZero);
    CHECK(graphAt(fx, 9).isEmpty());
}

TEST_CASE("Scheduler: muted and solo tracks") {
    Fixture fx;
    const ClipId low = fx.addClip(fx.v1, fx.av30, 0, 30);
    const ClipId high = fx.addClip(fx.v2, fx.av30, 0, 30);
    fx.track(fx.v2).muted = true;
    CHECK(layerClips(graphAt(fx, 0)) == std::vector<ClipId>{low});
    fx.track(fx.v2).muted = false;
    fx.track(fx.v2).solo = true;
    CHECK(layerClips(graphAt(fx, 0)) == std::vector<ClipId>{high});
    CHECK_FALSE(Scheduler::isTrackActive(fx.sequence(), fx.track(fx.v1)));
    CHECK(Scheduler::isTrackActive(fx.sequence(), fx.track(fx.a1))); // solo is per kind
    fx.track(fx.v1).solo = true;
    CHECK(layerClips(graphAt(fx, 0)) == std::vector<ClipId>{low, high});
    fx.track(fx.v2).muted = true; // mute wins over solo
    CHECK(layerClips(graphAt(fx, 0)) == std::vector<ClipId>{low});
}

TEST_CASE("Scheduler: reverse lookup helpers") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(10, 20);
    const ClipId other = fx.addClip(fx.v2, fx.still, 0, 15);
    CHECK(Scheduler::clipAt(fx.sequence(), fx.v1, f30(10)) == v);
    CHECK_FALSE(Scheduler::clipAt(fx.sequence(), fx.v1, f30(30)).has_value());
    CHECK_FALSE(Scheduler::clipAt(fx.sequence(), TrackId{999}, f30(10)).has_value());
    CHECK(Scheduler::clipsAt(fx.sequence(), f30(12)) == std::vector<ClipId>{v, other, a});
    CHECK(Scheduler::clipsAt(fx.sequence(), f30(20)) == std::vector<ClipId>{v, a});
}

TEST_CASE("Scheduler: audio graph gain, fades and source ranges") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.a1, fx.audioOnly, 30, 60, 90); // [30, 90), source 90..150
    fx.sequence().findClip(c)->audio = AudioParams{-6.0};
    fx.addFade(c, ClipEdge::Head, f30(10));
    fx.addFade(c, ClipEdge::Tail, f30(20));
    fx.requireValid();

    const AudioGraph whole = audioFor(fx, 0, 120);
    CHECK(whole.sampleRate == 48000);
    const auto segments = segmentsOf(whole, c);
    REQUIRE(segments.size() == 3); // fade in, body, fade out
    CHECK(segments[0]->timelineRange == TimeRange{f30(30), f30(40)});
    CHECK(segments[1]->timelineRange == TimeRange{f30(40), f30(70)});
    CHECK(segments[2]->timelineRange == TimeRange{f30(70), f30(90)});
    CHECK(segments[0]->sourceRange == TimeRange{f30(90), f30(100)});
    CHECK(segments[2]->sourceRange == TimeRange{f30(130), f30(150)});
    CHECK(segments[0]->level.start == -6.0);
    CHECK(segments[0]->level.isConstant());
    CHECK(decibelsToGain(segments[0]->level.start) == doctest::Approx(std::pow(10.0, -6.0 / 20.0)));
    CHECK(segments[0]->fade.start == 0.0);
    CHECK(segments[0]->fade.end == doctest::Approx(1.0));
    CHECK(segments[1]->fade.isUnity());
    CHECK(segments[2]->fade.start == doctest::Approx(1.0));
    CHECK(segments[2]->fade.end == 0.0);
    for (const AudioSegment *s : segments) {
        CHECK(s->crossfade.isUnity());
        CHECK_FALSE(s->crossfadePartner.has_value());
        CHECK(s->trackId == fx.a1);
        CHECK(s->assetId == fx.audioOnly);
    }

    // A range inside the fade-out: values interpolate along the ramp.
    const AudioGraph part = audioFor(fx, 75, 80);
    REQUIRE(part.segments.size() == 1);
    CHECK(part.segments[0].fade.start == doctest::Approx(15.0 / 20.0));
    CHECK(part.segments[0].fade.end == doctest::Approx(10.0 / 20.0));
    CHECK(part.segments[0].sourceRange == TimeRange{f30(135), f30(140)});

    CHECK(audioFor(fx, 0, 30).segments.empty());
    CHECK(audioFor(fx, 90, 200).segments.empty());
    CHECK(audioFor(fx, -30, -10).segments.empty());
    CHECK(audioFor(fx, 50, 50).segments.empty());
    const AudioGraph viaCM = Scheduler::audioGraphFor(fx.sequence(), fx.project, CMTimeRangeMake(f30(40), f30(30)));
    REQUIRE(viaCM.segments.size() == 1);
    CHECK(viaCM.segments[0].fade.isUnity());
}

TEST_CASE("Scheduler: audio crossfade ramps both clips linearly across the transition") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.a1, fx.audioOnly, 0, 60, 30);
    const ClipId b = fx.addClip(fx.a1, fx.audioOnly, 60, 60, 300);
    const SpanId t = fx.addTransition(fx.a1, a, b, 20); // [50, 70)
    fx.requireValid();

    const AudioGraph g = audioFor(fx, 40, 80);
    const auto outgoing = segmentsOf(g, a);
    const auto incoming = segmentsOf(g, b);
    REQUIRE(outgoing.size() == 3); // [40,50) plain, [50,60) and [60,70) crossfading
    REQUIRE(incoming.size() == 3); // [50,60) and [60,70) crossfading, [70,80) plain
    CHECK(outgoing[0]->crossfade.isUnity());
    CHECK(outgoing[0]->fade.isUnity());
    CHECK(outgoing[1]->timelineRange == TimeRange{f30(50), f30(60)});
    CHECK(outgoing[1]->crossfade.start == doctest::Approx(1.0));
    CHECK(outgoing[1]->crossfade.end == doctest::Approx(0.5));
    CHECK(outgoing[2]->crossfade.start == doctest::Approx(0.5));
    CHECK(outgoing[2]->crossfade.end == doctest::Approx(0.0));
    CHECK(outgoing[2]->sourceRange == TimeRange{f30(90), f30(100)}); // handle past the out point
    CHECK(outgoing[2]->crossfadePartner == b);
    CHECK(outgoing[2]->transitionId == t);
    CHECK(outgoing[2]->fade.isUnity());

    CHECK(incoming[0]->timelineRange == TimeRange{f30(50), f30(60)});
    CHECK(incoming[0]->sourceRange == TimeRange{f30(290), f30(300)}); // handle before the in point
    CHECK(incoming[0]->crossfade.start == doctest::Approx(0.0));
    CHECK(incoming[0]->crossfade.end == doctest::Approx(0.5));
    CHECK(incoming[1]->crossfade.end == doctest::Approx(1.0));
    CHECK(incoming[1]->crossfadePartner == a);
    CHECK(incoming[2]->crossfade.isUnity());
    CHECK(incoming[0]->fade.isUnity());

    // A range entirely before the cut still picks up the incoming clip's handle.
    const AudioGraph beforeCut = audioFor(fx, 50, 55);
    REQUIRE(segmentsOf(beforeCut, a).size() == 1);
    REQUIRE(segmentsOf(beforeCut, b).size() == 1);
    CHECK(segmentsOf(beforeCut, b)[0]->crossfade.end == doctest::Approx(0.25));

    // The mixer applies the constant-power law to the linear progress (RenderGraph.h): the two
    // clips' powers sum to 1 everywhere in the transition, including between segment edges
    // where it interpolates the progress linearly.
    for (std::size_t i = 0; i < 2; ++i) {
        const GainRamp out = outgoing[i + 1]->crossfade;
        const GainRamp in = incoming[i]->crossfade;
        for (const double u : {0.0, 0.25, 0.5, 0.75, 1.0}) {
            const double gOut = constantPowerGain(out.start + (out.end - out.start) * u);
            const double gIn = constantPowerGain(in.start + (in.end - in.start) * u);
            CHECK(gOut * gOut + gIn * gIn == doctest::Approx(1.0));
        }
    }
    // At the centre both clips play at -3 dB, not -6 dB.
    CHECK(constantPowerGain(outgoing[1]->crossfade.end) == doctest::Approx(std::sqrt(0.5)));
    CHECK(constantPowerGain(incoming[0]->crossfade.end) == doctest::Approx(std::sqrt(0.5)));
}

TEST_CASE("Scheduler: fade envelopes are exactly linear per segment because fades never overlap") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.a1, fx.audioOnly, 0, 30);
    // Overlapping fades (20 in + 20 out on 30 frames) are not a valid model: their product is
    // not linear on [10, 20) (it peaks at 0.5625), so validation refuses them.
    const SpanId in = fx.addFade(c, ClipEdge::Head, f30(20));
    const SpanId out = fx.addFade(c, ClipEdge::Tail, f30(20));
    CHECK(problemOf(fx.project).find("meets the fade in") != std::string::npos);
    fx.sequence().findSpan(out)->start = -f30(10);
    ClipParamsChange overlapping{c, std::nullopt, std::nullopt};
    overlapping.fadeOut = f30(20);
    SetClipsParams overlap(fx.seq, {overlapping});
    applyRefused(fx.project, overlap, EditError::InvalidTime);

    // Fades that meet exactly: every segment is one linear ramp of the true envelope.
    fx.requireValid();
    (void)in;
    const AudioGraph g = audioFor(fx, 0, 30);
    const auto segments = segmentsOf(g, c);
    REQUIRE(segments.size() == 2);
    auto envelope = [](double frame) { return frame <= 20 ? frame / 20.0 : (30.0 - frame) / 10.0; };
    for (const AudioSegment *segment : segments) {
        const double s0 = CMTimeGetSeconds(segment->timelineRange.start) * 30;
        const double s1 = CMTimeGetSeconds(segment->timelineRange.end) * 30;
        for (const double u : {0.0, 0.3, 0.5, 0.9, 1.0}) {
            const double linear = segment->fade.start + (segment->fade.end - segment->fade.start) * u;
            CHECK(linear == doctest::Approx(envelope(s0 + (s1 - s0) * u)));
        }
    }
}

TEST_CASE("Scheduler: fades of split pieces fit their pieces") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.a1, fx.audioOnly, 0, 300);
    fx.addFade(c, ClipEdge::Head, f30(90));
    fx.addFade(c, ClipEdge::Tail, f30(60));
    fx.requireValid();
    // An insert splits the clip inside its fade in (a user split there is refused).
    InsertClip insert(fx.seq, f30(30), {place(fx.a1, fx.audioOnly, 600, 610)}, InsertOptions{false, RippleScope::SyncedTracks});
    applyReversible(fx.project, insert);
    const ClipId right = fx.sequence().findTrack(fx.a1)->clips.back().id;
    CHECK(clipFadeLength(fx.clip(c), ClipEdge::Head) == f30(30)); // was 90 on a 30-frame piece
    CHECK(clipFadeLength(fx.clip(right), ClipEdge::Tail) == f30(60));
    // The left piece's gain ramps 0 -> 1 over its whole length and never jumps.
    const AudioGraph g = audioFor(fx, 0, 30);
    const auto segments = segmentsOf(g, c);
    REQUIRE(segments.size() == 1);
    CHECK(segments[0]->fade.start == 0.0);
    CHECK(segments[0]->fade.end == doctest::Approx(1.0));
}

TEST_CASE("Scheduler: audio lookup finds a transition tail from two clips back") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.a1, fx.audioOnly, 0, 60, 30);
    const ClipId b = fx.addClip(fx.a1, fx.audioOnly, 60, 4, 300);
    const ClipId c = fx.addClip(fx.a1, fx.audioOnly, 64, 36, 600);
    fx.addTransition(fx.a1, a, b, 8); // [56, 64): ends where B ends
    fx.requireValid();
    const AudioGraph g = audioFor(fx, 62, 70);
    REQUIRE(segmentsOf(g, a).size() == 1);
    CHECK(segmentsOf(g, a)[0]->timelineRange == TimeRange{f30(62), f30(64)});
    CHECK(segmentsOf(g, a)[0]->crossfade.end == doctest::Approx(0.0));
    REQUIRE(segmentsOf(g, b).size() == 1);
    REQUIRE(segmentsOf(g, c).size() == 1);
    CHECK(segmentsOf(g, c)[0]->timelineRange == TimeRange{f30(64), f30(70)});
}

TEST_CASE("Scheduler: audio respects speed, mute and solo") {
    Fixture fx;
    const ClipId fast = fx.addClip(fx.a1, fx.audioOnly, 0, 30, 0, 2.0);
    const ClipId other = fx.addClip(fx.a2, fx.audioOnly, 0, 30, 300);
    fx.addClip(fx.v1, fx.av30, 0, 30); // video clips never appear in the audio graph
    AudioGraph g = audioFor(fx, 0, 30);
    REQUIRE(g.segments.size() == 2);
    CHECK(g.segments[0].clipId == fast);
    CHECK(g.segments[0].speed == 2.0);
    CHECK(g.segments[0].sourceRange == TimeRange{f30(0), f30(60)});
    CHECK(g.segments[1].clipId == other);

    fx.track(fx.a2).muted = true;
    g = audioFor(fx, 0, 30);
    REQUIRE(g.segments.size() == 1);
    CHECK(g.segments[0].clipId == fast);

    fx.track(fx.a2).muted = false;
    fx.track(fx.a2).solo = true;
    g = audioFor(fx, 0, 30);
    REQUIRE(g.segments.size() == 1);
    CHECK(g.segments[0].clipId == other);

    fx.track(fx.v1).muted = true; // video mute does not affect audio
    CHECK(audioFor(fx, 0, 30).segments.size() == 1);
}

TEST_CASE("Scheduler: layers carry the clip's Motion and Opacity spans at each frame, held in dissolve handles") {
    Fixture fx;
    // V1: a clip from source frame 30 at timeline 0 (60 frames) cutting to a second one at 60;
    // a 10-frame dissolve on the cut shows the first clip's handle past its out point.
    const ClipId first = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
    const ClipId second = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    fx.addTransition(fx.v1, first, second, 10);
    // A Motion span over the whole clip (source frames [30, 90)): x linear 0 -> 600, scale holds
    // 1 then 2 at source frame 60; an Opacity span easing out from 1 to 0 over [60, 90).
    SpanTracks motion;
    motion.x = {key(f30(0), 0, KeyframeInterpolation::Linear), key(f30(60), 600)};
    motion.scale = {key(f30(0), 1, KeyframeInterpolation::Hold), key(f30(30), 2)};
    fx.addSpan(first, SpanKind::Motion, 1, f30(30), f30(90), motion);
    SpanTracks opacity;
    opacity.opacity = {key(f30(0), 1, KeyframeInterpolation::EaseOut), key(f30(30), 0)};
    fx.addSpan(first, SpanKind::Opacity, 2, f30(60), f30(90), opacity);
    fx.sequence().findClip(first)->video.y = 25;
    fx.requireValid();

    for (std::int64_t frame = 0; frame < 55; ++frame) {
        CAPTURE(frame);
        const RenderGraph graph = graphAt(fx, frame);
        REQUIRE(graph.layers.size() == 1);
        const VideoLayer &layer = graph.layers[0];
        CHECK(layer.transform.x == doctest::Approx(10.0 * double(frame)).epsilon(1e-12));
        CHECK(layer.transform.y == 25);
        CHECK(layer.transform.scale == (frame < 30 ? 1.0 : 2.0));
        const double u = frame < 30 ? 0.0 : double(frame - 30) / 30.0;
        CHECK(layer.opacity == doctest::Approx(1.0 - timingCurveFor(KeyframeInterpolation::EaseOut).valueAt(u)).epsilon(1e-12));
        CHECK(layer.opacity == layer.transform.opacity);
    }
    // In the dissolve, past the first clip's out point (its handle), the spans that reach the out
    // point hold their end values.
    const RenderGraph mixed = graphAt(fx, 63);
    REQUIRE(mixed.layers.size() == 2);
    CHECK(mixed.layers[0].clipId == first);
    CHECK(mixed.layers[0].transform.x == 600);
    CHECK(mixed.layers[0].opacity == 0);
    CHECK(mixed.layers[1].transform == VideoParams{});

    // The same evaluation for a still, on its time into the clip.
    const ClipId still = fx.addClip(fx.v2, fx.still, 30, 30);
    SpanTracks turn;
    turn.rotation = {key(f30(0), 0), key(f30(29), 290)};
    fx.addSpan(still, SpanKind::Motion, 1, f30(0), f30(30), turn);
    fx.requireValid();
    const RenderGraph withStill = graphAt(fx, 40);
    REQUIRE(withStill.layers.size() == 2);
    CHECK(withStill.layers[1].transform.rotationDegrees == doctest::Approx(100).epsilon(1e-12));
}

TEST_CASE("Scheduler: a Motion span over the first 5 s of a 30 s clip holds its end framing for the other 25 s") {
    Fixture fx;
    // V1: a 30 s clip (900 frames) of av30, and after it a second clip that must stay unanimated.
    const ClipId clip = fx.addClip(fx.v1, fx.av30, 0, 900);
    const ClipId next = fx.addClip(fx.v1, fx.av30, 900, 60, 900);
    fx.sequence().findClip(clip)->video.rotationDegrees = 12; // the clip's static value
    SpanTracks move;
    move.x = {key(f30(0), 0, KeyframeInterpolation::EaseInOut), key(f30(150), -240)};
    move.y = {key(f30(0), 0, KeyframeInterpolation::EaseInOut), key(f30(150), 90)};
    move.scale = {key(f30(0), 1, KeyframeInterpolation::EaseInOut), key(f30(150), 1.6)};
    fx.addSpan(clip, SpanKind::Motion, 1, f30(0), f30(150), move);
    fx.requireValid();

    const TimingCurve ease = timingCurveFor(KeyframeInterpolation::EaseInOut);
    for (std::int64_t frame = 0; frame < 960; ++frame) {
        CAPTURE(frame);
        const RenderGraph graph = graphAt(fx, frame);
        REQUIRE(graph.layers.size() == 1);
        const VideoParams &shown = graph.layers[0].transform;
        if (frame >= 900) {
            CHECK(graph.layers[0].clipId == next);
            CHECK(shown == VideoParams{});
            continue;
        }
        CHECK(shown.rotationDegrees == 12);
        if (frame >= 150) {
            // After the span: its end framing, held exactly until the clip ends (the next clip
            // above stays unanimated).
            CHECK(shown.x == -240);
            CHECK(shown.y == 90);
            CHECK(shown.scale == 1.6);
        } else {
            const double u = ease.valueAt(double(frame) / 150.0);
            CHECK(shown.x == doctest::Approx(-240.0 * u).epsilon(1e-9));
            CHECK(shown.y == doctest::Approx(90.0 * u).epsilon(1e-9));
            CHECK(shown.scale == doctest::Approx(1.0 + 0.6 * u).epsilon(1e-9));
        }
    }
}
