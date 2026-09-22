#include "../../Engine/Render/Scheduler.h"
#include "../Model/ModelFixtures.h"

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

TEST_CASE("Scheduler: cross dissolve emits both clips with a linear mix") {
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
    CHECK(start.layers[0].transition->mix == 0.0);
    CHECK(start.layers[0].transition->weight() == 1.0);
    CHECK(start.layers[1].transition->weight() == 0.0);
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
    CHECK(middle.layers[0].transition->mix == doctest::Approx(0.5));
    CHECK(middle.layers[1].transition->weight() == doctest::Approx(0.5));
    CHECK(middle.layers[0].sourceTime == f30(90)); // outgoing handle past its out point
    CHECK(middle.layers[1].sourceTime == f30(300));

    const RenderGraph last = graphAt(fx, 69);
    REQUIRE(last.layers.size() == 2);
    CHECK(last.layers[1].transition->mix == doctest::Approx(19.0 / 20.0));
    CHECK(last.layers[0].sourceTime == f30(99));

    CHECK(layerClips(graphAt(fx, 70)) == std::vector<ClipId>{b});
    CHECK_FALSE(graphAt(fx, 70).layers[0].transition.has_value());
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
    CHECK(g.layers[1].transition->mix == doctest::Approx(0.3));
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
    // Half speed on a 30 fps source lands between frames 12 and 13: nearest (ties up) is 13.
    CHECK(graphAt(fx, 65).layers[0].sourceTime == f30(13));
    CHECK(graphAt(fx, 64).layers[0].sourceTime == f30(12));
    CHECK(graphAt(fx, 65).layers[0].clipId == slow30);
}

TEST_CASE("Scheduler: source time snaps to the nearest frame of a 23.976 source") {
    Fixture fx;
    fx.addClip(fx.v1, fx.av24, 0, 300);
    const CMTime k23976 = CMTimeMake(1001, 24000);
    CHECK(identical(graphAt(fx, 30).layers[0].sourceTime, CMTimeMake(24 * 1001, 24000))); // 1 s -> frame 24
    CHECK(identical(graphAt(fx, 45).layers[0].sourceTime, timeForFrame(36, k23976)));     // 1.5 s = 35.96
    CHECK(identical(graphAt(fx, 1).layers[0].sourceTime, timeForFrame(1, k23976)));       // 0.8 frames
    CHECK(graphAt(fx, 0).layers[0].sourceTime == kCMTimeZero);
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
    fx.sequence().findClip(c)->audio = AudioParams{-6.0, f30(10), f30(20)};
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
    CHECK(segments[0]->gain == doctest::Approx(std::pow(10.0, -6.0 / 20.0)));
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
    // Own fades on the transition edges are replaced by the crossfade.
    fx.sequence().findClip(a)->audio.fadeOutDuration = f30(15);
    fx.sequence().findClip(b)->audio.fadeInDuration = f30(15);
    const TransitionId t = fx.addTransition(fx.a1, a, b, 20); // [50, 70)
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

    // Sum of the two ramps is 1 everywhere in the transition.
    for (std::size_t i = 0; i < 2; ++i) {
        CHECK(outgoing[i + 1]->crossfade.start + incoming[i]->crossfade.start == doctest::Approx(1.0));
        CHECK(outgoing[i + 1]->crossfade.end + incoming[i]->crossfade.end == doctest::Approx(1.0));
    }
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
