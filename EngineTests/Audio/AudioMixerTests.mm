// AudioMixer: sample-accurate gain, fades and constant-power crossfades against an independent
// per-sample model; mute/solo; 2x (with an anti-aliasing decimator) and seamless 1x <-> 2x;
// underruns under a starved producer; plan swaps and source reuse (also across tracks);
// repositioning reused sources after a seek; de-clicking (stop fade, gain-edit ramp, mute ramp);
// source destruction off the caller's thread; and no heap allocation on the render path.

#import <XCTest/XCTest.h>

#include "../../Engine/Audio/AudioMixer.h"
#include "../../Engine/Render/Scheduler.h"
#include "../Media/BurnIn.h"
#include "AudioTestSupport.h"

#include <chrono>
#include <cmath>
#include <stdexcept>
#include <thread>

using namespace ve;
using namespace ve::audio;
using namespace ve::test;

namespace {

constexpr double kSr = 48000.0;

/// A project whose assets are fake tone "files", plus a mixer over them.
struct MixFixture {
    std::shared_ptr<ToneBehavior> tones = std::make_shared<ToneBehavior>();
    std::shared_ptr<media::BackendRouter> router = makeToneRouter(tones);
    std::shared_ptr<HostClock> host = HostClock::makeVirtual();
    Clock clock{host, kSr};
    std::unique_ptr<AudioMixer> mixer;
    Project project;
    SequenceId seq;
    TrackId a1, a2;

    MixFixture() {
        mixer = std::make_unique<AudioMixer>(router, &clock);
        seq = project.addSequence("Mix", CMTimeMake(1, 30), 1920, 1080, 0, 2);
        a1 = sequence().audioTracks[0].id;
        a2 = sequence().audioTracks[1].id;
    }
    ~MixFixture() {
        tones->setReadsBlocked(false);
        mixer.reset();
    }
    Sequence &sequence() { return *project.findSequence(seq); }

    AssetId addTone(const std::string &path, ToneSignal signal) {
        tones->setSignal(path, std::move(signal));
        MediaAsset asset;
        asset.name = path;
        asset.url = path;
        asset.kind = AssetKind::Audio;
        asset.duration = CMTimeMake(20 * 48000, 48000);
        asset.audioSampleRate = 48000;
        asset.audioChannels = 2;
        const AssetId id = project.addAsset(asset);
        mixer->registerAsset(id, path);
        return id;
    }

    Clip &addClip(TrackId track, AssetId asset, CMTime start, CMTime duration, CMTime sourceIn, double speed = 1.0) {
        Clip clip;
        clip.id = project.ids.make<ClipId>();
        clip.assetId = asset;
        clip.trackId = track;
        clip.timelineStart = start;
        clip.sourceIn = sourceIn;
        clip.speed = speedFromDouble(speed);
        clip.timelineDuration = duration;
        Track &t = *sequence().findTrack(track);
        t.clips.push_back(clip);
        t.sortClips();
        return *t.find(clip.id);
    }

    // A cross dissolve of `frames` centred on the cut at the end of `from` (which `to` touches),
    // owned by `from` as a lane-0 tail span.
    void addTransition(TrackId track, ClipId from, ClipId to, int frames) {
        const Track &t = *sequence().findTrack(track);
        if (t.find(from) == nullptr || t.find(to) == nullptr ||
            !(t.find(from)->timelineEnd() == t.find(to)->timelineStart)) {
            throw std::logic_error("addTransition: the clips do not meet on the track");
        }
        EffectSpan span;
        span.id = project.ids.make<SpanId>();
        span.lane = kTransitionLane;
        span.kind = SpanKind::Transition;
        span.edge = ClipEdge::Tail;
        span.start = CMTimeMake(-(frames / 2), 30);
        span.end = CMTimeMake(frames - frames / 2, 30);
        Clip &clip = *sequence().findClip(from);
        clip.spans.push_back(span);
        clip.sortSpans();
    }

    // A Gain span over source [start, end) of `clip` moving from `from` to `to` dB with
    // `interpolation`.
    void addGainSpan(Clip &clip, int lane, CMTime start, CMTime end, double from, double to,
                     KeyframeInterpolation interpolation) {
        EffectSpan span;
        span.id = project.ids.make<SpanId>();
        span.lane = lane;
        span.kind = SpanKind::Gain;
        span.start = start;
        span.end = end;
        Keyframe first;
        first.time = kCMTimeZero;
        first.value = from;
        first.interpolation = interpolation;
        Keyframe last = first;
        last.time = CMTimeSubtract(end, start);
        last.value = to;
        span.tracks.gain = {first, last};
        clip.spans.push_back(span);
        clip.sortSpans();
    }

    // A lane-0 fade of `length` at `edge` of `clip` (head: fade in; tail: fade out ending on its end).
    void addFade(Clip &clip, ClipEdge edge, CMTime length) {
        EffectSpan span;
        span.id = project.ids.make<SpanId>();
        span.lane = kTransitionLane;
        span.kind = SpanKind::Transition;
        span.edge = edge;
        span.start = edge == ClipEdge::Head ? kCMTimeZero : CMTimeMultiply(length, -1);
        span.end = edge == ClipEdge::Head ? length : kCMTimeZero;
        clip.spans.push_back(span);
        clip.sortSpans();
    }

    void plan(CMTime from, CMTime to) {
        mixer->setGraph(Scheduler::audioGraphFor(sequence(), project, TimeRange{from, to}), from);
    }

    /// Output channel 0 of `frames` frames rendered in `block`-sized calls (no waiting).
    static std::vector<float> left(const std::vector<float> &interleaved) {
        std::vector<float> out(interleaved.size() / 2);
        for (size_t i = 0; i < out.size(); ++i) {
            out[i] = interleaved[i * 2];
        }
        return out;
    }

    /// prime + start at `at`, returns the clock epoch.
    uint32_t start(CMTime at, int rate = 1) {
        [[maybe_unused]] const bool primed = mixer->prime(at, std::chrono::seconds(5));
        const uint32_t epoch = clock.start(at, rate);
        mixer->start(at, rate, epoch);
        return epoch;
    }

    /// Renders `frames` output frames in blocks of `block`. The test renders faster than real
    /// time, so before each block it waits for the producers to be ahead (as they are in real
    /// time), which keeps the sample checks independent of machine speed and sanitizers.
    std::vector<float> render(int64_t frames, int block = 512) {
        std::vector<float> out(static_cast<size_t>(frames) * 2);
        for (int64_t done = 0; done < frames; done += block) {
            [[maybe_unused]] const bool ready = mixer->waitForBuffered(std::chrono::seconds(5));
            const int n = static_cast<int>(std::min<int64_t>(block, frames - done));
            mixer->render(out.data() + done * 2, n, 2);
        }
        return out;
    }
};

double maxAbsDiff(const std::vector<float> &a, const std::vector<double> &b) {
    double worst = 0;
    for (size_t i = 0; i < a.size() && i < b.size(); ++i) {
        worst = std::max(worst, std::fabs(static_cast<double>(a[i]) - b[i]));
    }
    return worst;
}

} // namespace

@interface AudioMixerTests : XCTestCase
@end

@implementation AudioMixerTests

- (void)testGainAndFadesAreSampleAccurate {
    MixFixture fx;
    const double amplitude = 0.8;
    const AssetId tone = fx.addTone("tone://sine440", sineSignal(440, amplitude));
    Clip &clip = fx.addClip(fx.a1, tone, CMTimeMake(6, 30), CMTimeMake(18, 30), CMTimeMake(1, 1));
    clip.audio.gainDb = 20.0 * std::log10(0.5);
    fx.addFade(clip, ClipEdge::Head, CMTimeMake(3, 30)); // 0.1 s
    fx.addFade(clip, ClipEdge::Tail, CMTimeMake(6, 30)); // 0.2 s
    fx.plan(kCMTimeZero, CMTimeMake(2, 1));
    fx.start(kCMTimeZero);
    const std::vector<float> out = fx.render(48000);

    // Independent model: clip [9600, 38400), source sample = n - 9600 + 48000.
    std::vector<double> expected(out.size(), 0.0);
    const double gain = std::pow(10.0, clip.audio.gainDb / 20.0);
    for (int64_t n = 9600; n < 38400; ++n) {
        const double fadeIn = std::min(1.0, static_cast<double>(n - 9600) / 4800.0);
        const double fadeOut = std::min(1.0, static_cast<double>(38400 - n) / 9600.0);
        const int64_t s = n - 9600 + 48000;
        const double v = gain * fadeIn * fadeOut * amplitude * std::sin(2.0 * M_PI * 440.0 * static_cast<double>(s) / kSr);
        expected[static_cast<size_t>(n) * 2] = v;
        expected[static_cast<size_t>(n) * 2 + 1] = v;
    }
    const double worst = maxAbsDiff(out, expected);
    XCTAssertLessThan(worst, 2e-6, @"max deviation from the model: %g", worst);
    // Spot checks of the envelope corners.
    XCTAssertEqual(out[9599 * 2], 0.0f);
    XCTAssertEqual(out[38400 * 2], 0.0f);
    XCTAssertEqual(fx.mixer->stats().underruns, 0u);
    NSLog(@"gain+fades: max |mixer - model| = %.3g over 48000 samples", worst);
}

- (void)testGainSpansAreSampleAccurateInDecibels {
    MixFixture fx;
    const double amplitude = 0.5;
    const AssetId tone = fx.addTone("tone://sine330", sineSignal(330, amplitude));
    // The clip plays source [1 s, 2.5 s) at timeline [0.25 s, 1.75 s) at -3 dB. Lane 1: a linear
    // ramp to -18 dB over source [1.25 s, 1.75 s); lane 2: an eased swell of +6 dB over source
    // [1.5 s, 2.25 s) (followed in 5 ms steps, linear in dB within each).
    Clip &clip = fx.addClip(fx.a1, tone, CMTimeMake(1, 4), CMTimeMake(45, 30), CMTimeMake(1, 1));
    clip.audio.gainDb = -3;
    fx.addGainSpan(clip, 1, CMTimeMake(5, 4), CMTimeMake(7, 4), 0, -18, KeyframeInterpolation::Linear);
    fx.addGainSpan(clip, 2, CMTimeMake(3, 2), CMTimeMake(9, 4), 0, 6, KeyframeInterpolation::EaseInOut);
    fx.plan(kCMTimeZero, CMTimeMake(2, 1));
    fx.start(kCMTimeZero);
    const std::vector<float> out = fx.render(96000);

    // Independent model: the level in dB at each sample from the spans' definitions; the eased
    // swell's Core Animation curve (0.42, 0, 0.58, 1) by bisection on x(t).
    auto easeInOut = [](double u) {
        auto bez = [](double p1, double p2, double t) {
            const double v = 1 - t;
            return 3 * v * v * t * p1 + 3 * v * t * t * p2 + t * t * t;
        };
        double lo = 0, hi = 1;
        for (int i = 0; i < 60; ++i) {
            const double mid = (lo + hi) / 2;
            (bez(0.42, 0.58, mid) < u ? lo : hi) = mid;
        }
        return bez(0.0, 1.0, (lo + hi) / 2);
    };
    std::vector<double> expected(out.size(), 0.0);
    for (int64_t n = 12000; n < 84000; ++n) {
        const double source = 1.0 + static_cast<double>(n - 12000) / kSr;
        double db = -3;
        if (source >= 1.25 && source < 1.75) {
            db += -18 * (source - 1.25) / 0.5;
        }
        if (source >= 1.5 && source < 2.25) {
            db += 6 * easeInOut((source - 1.5) / 0.75);
        }
        const int64_t s = n - 12000 + 48000;
        const double v = std::pow(10.0, db / 20.0) * amplitude * std::sin(2.0 * M_PI * 330.0 * static_cast<double>(s) / kSr);
        expected[static_cast<size_t>(n) * 2] = v;
        expected[static_cast<size_t>(n) * 2 + 1] = v;
    }
    // Linear in dB: sample accurate outside the eased swell.
    double worstLinear = 0;
    double worstEased = 0;
    for (int64_t n = 0; n < 96000; ++n) {
        const double source = 1.0 + static_cast<double>(n - 12000) / kSr;
        const double d = std::fabs(static_cast<double>(out[static_cast<size_t>(n) * 2]) - expected[static_cast<size_t>(n) * 2]);
        double &worst = source >= 1.5 && source < 2.25 ? worstEased : worstLinear;
        worst = std::max(worst, d);
    }
    // Within the swell each 5 ms step is linear in dB between exact values: the level is off by at
    // most a few thousandths of a dB, a relative gain error below 0.1 %.
    XCTAssertLessThan(worstLinear, 2e-6, @"linear ramp: max deviation %g", worstLinear);
    XCTAssertLessThan(worstEased, 1e-3 * amplitude, @"eased swell: max deviation %g", worstEased);
    XCTAssertEqual(fx.mixer->stats().underruns, 0u);
    NSLog(@"gain spans: max |mixer - model| = %.3g (linear), %.3g (eased)", worstLinear, worstEased);
}

- (void)testCrossfadeIsConstantPowerAndSampleAccurate {
    MixFixture fx;
    // Outgoing clip only on the left channel, incoming only on the right: the output channels
    // are the two crossfade gains.
    const AssetId left = fx.addTone("tone://left", constantSignal(0.5f, 0.0f));
    const AssetId right = fx.addTone("tone://right", constantSignal(0.0f, 0.5f));
    const ClipId p = fx.addClip(fx.a1, left, kCMTimeZero, CMTimeMake(18, 30), kCMTimeZero).id;
    const ClipId q = fx.addClip(fx.a1, right, CMTimeMake(18, 30), CMTimeMake(18, 30), CMTimeMake(1, 1)).id;
    fx.addTransition(fx.a1, p, q, 12); // [0.4 s, 0.8 s)
    fx.plan(kCMTimeZero, CMTimeMake(2, 1));
    fx.start(kCMTimeZero);
    const std::vector<float> out = fx.render(48000);

    double worstLaw = 0.0;
    double worstPower = 0.0;
    for (int64_t n = 0; n < 48000; ++n) {
        const double gp = out[static_cast<size_t>(n) * 2] / 0.5;
        const double gq = out[static_cast<size_t>(n) * 2 + 1] / 0.5;
        double ep = 0, eq = 0;
        if (n < 19200) {
            ep = 1;
        } else if (n < 38400) {
            const double c = static_cast<double>(n - 19200) / 19200.0;
            eq = std::sin(c * M_PI / 2);
            ep = std::sin((1.0 - c) * M_PI / 2);
            worstPower = std::max(worstPower, std::fabs(gp * gp + gq * gq - 1.0));
        } else if (n < 57600) {
            eq = 1;
        }
        worstLaw = std::max({worstLaw, std::fabs(gp - ep), std::fabs(gq - eq)});
    }
    XCTAssertLessThan(worstLaw, 1e-5, @"gain law deviation %g", worstLaw);
    XCTAssertLessThan(worstPower, 2e-5, @"power sum deviation %g", worstPower);
    // Midpoint: both at -3 dB.
    XCTAssertEqualWithAccuracy(out[28800 * 2] / 0.5, M_SQRT1_2, 1e-4);
    XCTAssertEqualWithAccuracy(out[28800 * 2 + 1] / 0.5, M_SQRT1_2, 1e-4);
    NSLog(@"crossfade: law deviation %.3g, |gA^2 + gB^2 - 1| <= %.3g", worstLaw, worstPower);
}

- (void)testTracksSumAndHonourMuteAndSolo {
    MixFixture fx;
    const AssetId a = fx.addTone("tone://a", constantSignal(0.25f, 0.25f));
    const AssetId b = fx.addTone("tone://b", constantSignal(0.125f, 0.125f));
    fx.addClip(fx.a1, a, kCMTimeZero, CMTimeMake(60, 30), kCMTimeZero);
    fx.addClip(fx.a2, b, kCMTimeZero, CMTimeMake(60, 30), kCMTimeZero);

    auto level = [&](void (^configure)(Sequence &)) {
        configure(fx.sequence());
        fx.mixer->stop();
        fx.plan(kCMTimeZero, CMTimeMake(2, 1));
        fx.start(kCMTimeZero);
        const std::vector<float> out = fx.render(4800);
        return out[4000];
    };
    XCTAssertEqualWithAccuracy(level(^(Sequence &) {
                               }),
                               0.375f, 1e-6);
    XCTAssertEqualWithAccuracy(level(^(Sequence &s) {
                                 s.audioTracks[1].muted = true;
                               }),
                               0.25f, 1e-6);
    XCTAssertEqualWithAccuracy(level(^(Sequence &s) {
                                 s.audioTracks[1].muted = false;
                                 s.audioTracks[1].solo = true;
                               }),
                               0.125f, 1e-6);
}

- (void)testMasterGainAndHardLimit {
    MixFixture fx;
    const AssetId a = fx.addTone("tone://loud", constantSignal(0.9f, -0.9f));
    fx.addClip(fx.a1, a, kCMTimeZero, CMTimeMake(60, 30), kCMTimeZero);
    fx.addClip(fx.a2, a, kCMTimeZero, CMTimeMake(60, 30), kCMTimeZero);
    fx.plan(kCMTimeZero, CMTimeMake(2, 1));
    fx.start(kCMTimeZero);
    std::vector<float> out = fx.render(2048);
    XCTAssertEqual(out[1000], 1.0f, @"1.8 is limited to 1");
    XCTAssertEqual(out[1001], -1.0f);
    fx.mixer->setMasterGain(0.5f);
    out = fx.render(2048);
    XCTAssertEqualWithAccuracy(out[1000], 0.9f, 1e-6);
}

- (void)testRateTwoDecimatesAndAdvancesTheClockTwiceAsFast {
    MixFixture fx;
    const AssetId a = fx.addTone("tone://sine", sineSignal(440, 0.5));
    fx.addClip(fx.a1, a, kCMTimeZero, CMTimeMake(300, 30), kCMTimeZero);
    fx.plan(kCMTimeZero, CMTimeMake(5, 1));
    fx.start(kCMTimeZero, 2);
    const std::vector<float> out = fx.render(24000); // 0.5 s of output
    XCTAssertEqual(fx.mixer->position(), 48000, @"two sequence samples per output sample");
    XCTAssertEqual(fx.clock.samplesRendered(), 24000);
    XCTAssertEqual(fx.clock.rate(), 2.0);
    const double now = CMTimeGetSeconds(fx.clock.now());
    XCTAssertGreaterThanOrEqual(now, 2.0 * (24000 - 512) / kSr);
    XCTAssertLessThanOrEqual(now, 1.0);
    const double hz = estimateFrequency(out.data(), 2400, 24000, 2, kSr);
    XCTAssertEqualWithAccuracy(hz, 880.0, 2.0, @"pitch doubles at 2x");
    XCTAssertEqual(fx.mixer->stats().underruns, 0u);
}

- (void)testUnderrunsAreCountedWhenTheProducerStarvesAndRenderNeverBlocks {
    MixFixture fx;
    const AssetId a = fx.addTone("tone://slow", constantSignal(0.5f, 0.5f));
    fx.addClip(fx.a1, a, kCMTimeZero, CMTimeMake(600, 30), kCMTimeZero);
    fx.plan(kCMTimeZero, CMTimeMake(20, 1));
    fx.start(kCMTimeZero);
    XCTAssertTrue(fx.mixer->waitForBuffered(std::chrono::seconds(5)));
    fx.tones->setReadsBlocked(true); // the decoder blocks from now on

    std::vector<float> block(512 * 2);
    double worstMs = 0;
    const int blocks = static_cast<int>(3.0 * kSr / 512);
    for (int i = 0; i < blocks; ++i) {
        const auto t0 = std::chrono::steady_clock::now();
        fx.mixer->render(block.data(), 512, 2);
        worstMs = std::max(worstMs, std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
    }
    const AudioMixer::Stats starved = fx.mixer->stats();
    XCTAssertGreaterThan(starved.underruns, 0u);
    XCTAssertGreaterThan(starved.underrunFrames, uint64_t(0.5 * kSr), @"~1 s beyond the 2 s lookahead is missing");
    XCTAssertEqual(block[0], 0.0f, @"missing audio is silence");
    XCTAssertLessThan(worstMs, 5.0, @"render must not wait for the producer");
    NSLog(@"starved producer: %llu underrun callbacks, %llu frames missing, worst render %.3f ms",
          starved.underruns, starved.underrunFrames, worstMs);

    // Recovery: the producer catches up and the output is whole again.
    fx.tones->setReadsBlocked(false);
    bool recovered = false;
    for (int i = 0; i < 500 && !recovered; ++i) {
        fx.mixer->render(block.data(), 512, 2); // the consumer skips ahead while the producer catches up
        recovered = fx.mixer->waitForBuffered(std::chrono::milliseconds(10));
    }
    XCTAssertTrue(recovered);
    const uint64_t before = fx.mixer->stats().underruns;
    const std::vector<float> out = fx.render(4800);
    XCTAssertEqual(fx.mixer->stats().underruns, before);
    XCTAssertEqual(out[4000], 0.5f);
}

- (void)testSourcesSurviveEditsThatKeepTheirMapping {
    MixFixture fx;
    const AssetId a = fx.addTone("tone://a", sineSignal(300, 0.5));
    const ClipId id = fx.addClip(fx.a1, a, kCMTimeZero, CMTimeMake(150, 30), kCMTimeZero).id;
    fx.plan(kCMTimeZero, CMTimeMake(5, 1));
    XCTAssertEqual(fx.mixer->stats().sourcesCreated, 1u);

    // Gain change and a tail trim: same media mapping, same source.
    Clip *clip = fx.sequence().findClip(id);
    clip->audio.gainDb = -3;
    XCTAssertTrue(clip->setTimelineEnd(CMTimeMake(120, 30)) == RetimeResult::Ok);
    fx.plan(kCMTimeZero, CMTimeMake(5, 1));
    XCTAssertEqual(fx.mixer->stats().sourcesCreated, 1u);
    // Split into two pieces: still continuous media on the same track.
    Clip right = *clip;
    right.id = fx.project.ids.make<ClipId>();
    XCTAssertTrue(clip->setTimelineEnd(CMTimeMake(60, 30)) == RetimeResult::Ok);
    XCTAssertTrue(right.setTimelineStartKeepingEnd(CMTimeMake(60, 30)) == RetimeResult::Ok);
    fx.sequence().audioTracks[0].clips.push_back(right);
    fx.plan(kCMTimeZero, CMTimeMake(5, 1));
    XCTAssertEqual(fx.mixer->stats().sourcesCreated, 1u);
    XCTAssertEqual(fx.mixer->stats().sources.size(), 1u);
    // A slip (different source offset) needs new media.
    clip = fx.sequence().findClip(id);
    clip->sourceIn = CMTimeMake(1, 1); // keeps its 60-frame duration
    fx.plan(kCMTimeZero, CMTimeMake(5, 1));
    XCTAssertEqual(fx.mixer->stats().sourcesCreated, 2u);
}

- (void)testPlanSwapDuringPlaybackIsSeamless {
    MixFixture fx;
    const AssetId a = fx.addTone("tone://a", sineSignal(440, 0.5));
    fx.addClip(fx.a1, a, kCMTimeZero, CMTimeMake(300, 30), kCMTimeZero);
    fx.plan(kCMTimeZero, CMTimeMake(2, 1));
    fx.start(kCMTimeZero);
    std::vector<float> out(48000 * 2);
    for (int64_t done = 0; done < 48000; done += 480) {
        if (done % 4800 == 0) {
            fx.plan(CMTimeMake(done, 48000), CMTimeMake(done + 96000, 48000)); // re-plan every 100 ms
        }
        [[maybe_unused]] const bool ready = fx.mixer->waitForBuffered(std::chrono::seconds(5));
        fx.mixer->render(out.data() + done * 2, 480, 2);
    }
    double worst = 0;
    for (int64_t n = 0; n < 48000; ++n) {
        const double e = 0.5 * std::sin(2 * M_PI * 440 * static_cast<double>(n) / kSr);
        worst = std::max(worst, std::fabs(out[static_cast<size_t>(n) * 2] - e));
    }
    XCTAssertLessThan(worst, 1e-6);
    XCTAssertGreaterThanOrEqual(fx.mixer->stats().planSwaps, 10u);
    XCTAssertEqual(fx.mixer->stats().underruns, 0u);
}

- (void)testSilentSequenceStillDrivesTheClock {
    MixFixture fx;
    fx.plan(kCMTimeZero, CMTimeMake(2, 1));
    const uint32_t epoch = fx.clock.start(kCMTimeZero, 1);
    fx.mixer->start(kCMTimeZero, 1, epoch);
    const std::vector<float> out = fx.render(48000);
    XCTAssertEqual(fx.clock.samplesRendered(), 48000);
    XCTAssertTrue(std::all_of(out.begin(), out.end(), [](float v) { return v == 0.0f; }));
    // Stopped transport: silence and no clock movement.
    fx.mixer->stop();
    fx.render(4800);
    XCTAssertEqual(fx.clock.samplesRendered(), 48000);
}

- (void)testReusedSourceIsMovedBackToItsHeadAfterASeek {
    // The review's scenario: clip C on [1 s, 3 s) plays from 1 s to 2 s; the transport stops and
    // restarts at 0.2 s. C's source (reused: same mapping) was consumed to 2 s; reaching 1 s
    // again must play C from its first sample without an underrun.
    MixFixture fx;
    const AssetId c = fx.addTone("tone://c", constantSignal(0.5f, 0.5f));
    fx.addClip(fx.a1, c, CMTimeMake(1, 1), CMTimeMake(2, 1), kCMTimeZero);
    fx.plan(CMTimeMake(1, 1), CMTimeMake(5, 1));
    fx.start(CMTimeMake(1, 1));
    fx.render(48000); // 1 s -> 2 s
    fx.mixer->stop();
    fx.render(512); // the render thread finishes the fade-out
    const uint64_t underruns = fx.mixer->stats().underruns;
    fx.plan(CMTimeMakeWithSeconds(0.2, 30), CMTimeMake(5, 1));
    XCTAssertEqual(fx.mixer->stats().sourcesCreated, 1u, @"the source is reused");
    XCTAssertEqual(fx.mixer->stats().repositionsWhileStopped, 1u, @"and moved back to C's head");
    fx.start(CMTimeMakeWithSeconds(0.2, 30));
    const std::vector<float> out = MixFixture::left(fx.render(48000)); // 0.2 s -> 1.2 s
    int64_t silentInC = 0;
    for (int64_t n = 38400; n < 48000; ++n) { // sequence 1.0 s -> 1.2 s
        silentInC += out[static_cast<size_t>(n)] == 0.0f ? 1 : 0;
    }
    XCTAssertEqual(silentInC, 0, @"C's head is audible");
    XCTAssertEqual(out[38399], 0.0f, @"nothing before C");
    XCTAssertEqual(out[38400], 0.5f, @"C from its first sample");
    XCTAssertEqual(fx.mixer->stats().underruns, underruns, @"no underrun");
}

- (void)testStopFadesOutOverTheRamp {
    MixFixture fx;
    const AssetId a = fx.addTone("tone://a", constantSignal(0.5f, 0.5f));
    fx.addClip(fx.a1, a, kCMTimeZero, CMTimeMake(5, 1), kCMTimeZero);
    fx.plan(kCMTimeZero, CMTimeMake(5, 1));
    fx.start(kCMTimeZero);
    fx.render(4800);
    const uint64_t serial = fx.mixer->stop();
    XCTAssertFalse(fx.mixer->stopCompleted(serial));
    const std::vector<float> out = MixFixture::left(fx.render(1024));
    XCTAssertTrue(fx.mixer->stopCompleted(serial));
    // 5 ms at 48 kHz: 240 samples from 0.5 down to 0, linearly; then silence.
    for (int k = 0; k < 240; ++k) {
        XCTAssertEqualWithAccuracy(out[static_cast<size_t>(k)], 0.5 * (1.0 - (k + 1) / 240.0), 1e-6, @"sample %d", k);
    }
    for (size_t k = 240; k < out.size(); ++k) {
        XCTAssertEqual(out[k], 0.0f);
    }
    XCTAssertEqual(fx.mixer->stats().stopFades, 1u);
    XCTAssertEqual(fx.clock.samplesRendered(), 4800, @"the fade does not advance the clock");
}

- (void)testGainEditRampsOverOneRampInsteadOfStepping {
    MixFixture fx;
    const AssetId a = fx.addTone("tone://a", constantSignal(0.5f, 0.5f));
    const ClipId id = fx.addClip(fx.a1, a, kCMTimeZero, CMTimeMake(5, 1), kCMTimeZero).id;
    fx.plan(kCMTimeZero, CMTimeMake(5, 1));
    fx.start(kCMTimeZero);
    fx.render(4800);
    fx.sequence().findClip(id)->audio.gainDb = 20.0 * std::log10(0.5);
    fx.plan(CMTimeMake(4800, 48000), CMTimeMake(5, 1)); // re-plan while running
    const std::vector<float> out = MixFixture::left(fx.render(1024));
    XCTAssertEqual(fx.mixer->stats().planBlends, 1u);
    XCTAssertEqual(fx.mixer->stats().sourcesCreated, 1u);
    for (int k = 0; k < 240; ++k) { // 0.5 -> 0.25 over 240 samples
        XCTAssertEqualWithAccuracy(out[static_cast<size_t>(k)], 0.5 - 0.25 * (k + 1) / 240.0, 1e-6, @"sample %d", k);
    }
    for (size_t k = 240; k < out.size(); ++k) {
        XCTAssertEqualWithAccuracy(out[k], 0.25f, 1e-6);
    }
}

- (void)testMuteRampsTheOutputAndKeepsTheClock {
    MixFixture fx;
    const AssetId a = fx.addTone("tone://a", constantSignal(0.5f, 0.5f));
    fx.addClip(fx.a1, a, kCMTimeZero, CMTimeMake(5, 1), kCMTimeZero);
    fx.plan(kCMTimeZero, CMTimeMake(5, 1));
    fx.start(kCMTimeZero);
    fx.render(4800);
    fx.mixer->setMuted(true);
    std::vector<float> out = MixFixture::left(fx.render(512));
    for (int k = 0; k < 240; ++k) {
        XCTAssertEqualWithAccuracy(out[static_cast<size_t>(k)], 0.5 * (1.0 - (k + 1) / 240.0), 1e-6);
    }
    XCTAssertEqual(out[300], 0.0f);
    XCTAssertEqual(fx.clock.samplesRendered(), 4800 + 512, @"muted audio still drives the clock");
    fx.mixer->setMuted(false);
    out = MixFixture::left(fx.render(512));
    XCTAssertEqualWithAccuracy(out[119], 0.25, 1e-6, @"ramping back up");
    XCTAssertEqual(out[400], 0.5f);
}

- (void)testChangeRateContinuesWithoutAGap {
    MixFixture fx;
    const AssetId a = fx.addTone("tone://a", sineSignal(300, 0.5));
    fx.addClip(fx.a1, a, kCMTimeZero, CMTimeMake(10, 1), kCMTimeZero);
    fx.plan(kCMTimeZero, CMTimeMake(10, 1));
    const uint32_t first = fx.start(kCMTimeZero);
    fx.render(24000);
    XCTAssertEqual(fx.mixer->position(), 24000);
    const uint32_t second = fx.clock.startContinuation(2.0);
    XCTAssertNotEqual(second, first);
    XCTAssertTrue(fx.mixer->changeRate(2, second));
    fx.render(24000);
    XCTAssertEqual(fx.mixer->position(), 24000 + 48000, @"continued from the render position at 2x");
    XCTAssertEqual(fx.mixer->stats().underruns, 0u, @"no reposition, no gap");
    XCTAssertEqual(fx.mixer->stats().sources[0].repositions, 1u);
    XCTAssertEqual(fx.clock.samplesRendered(), 24000, @"the new epoch counts from the switch");
    // The continuation's origin is the render position: at the last IO time the clock is there.
    // (fx.render renders 512-frame blocks: the last of 24000 frames is 448 long.)
    const int64_t lastBlock = 24000 % 512;
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds(fx.clock.timeAt(fx.clock.lastCallbackNanos())),
                               (24000 + 2 * (24000 - lastBlock)) / kSr, 1e-9);
    fx.mixer->stop();
    XCTAssertFalse(fx.mixer->changeRate(1, fx.clock.startContinuation(1.0)), @"only while running");
}

- (void)testRateTwoFiltersWhatWouldAlias {
    MixFixture fx;
    // 16 kHz would fold to 16 kHz at 2x (32 kHz above a 24 kHz Nyquist); 2 kHz becomes 4 kHz.
    const AssetId high = fx.addTone("tone://high", sineSignal(16000, 0.5));
    const AssetId low = fx.addTone("tone://low", sineSignal(2000, 0.5));
    fx.addClip(fx.a1, high, kCMTimeZero, CMTimeMake(5, 1), kCMTimeZero);
    fx.addClip(fx.a2, low, kCMTimeZero, CMTimeMake(5, 1), kCMTimeZero);
    fx.sequence().audioTracks[1].muted = true;
    fx.plan(kCMTimeZero, CMTimeMake(5, 1));
    fx.start(kCMTimeZero, 2);
    const std::vector<float> aliased = MixFixture::left(fx.render(24000));
    double rmsHigh = 0;
    for (size_t k = 4800; k < aliased.size(); ++k) {
        rmsHigh += aliased[k] * aliased[k];
    }
    rmsHigh = std::sqrt(rmsHigh / static_cast<double>(aliased.size() - 4800));
    XCTAssertLessThan(rmsHigh, 0.5 / std::sqrt(2.0) * 0.001, @"more than 60 dB below the input (%.2e)", rmsHigh);

    fx.mixer->stop();
    fx.sequence().audioTracks[0].muted = true;
    fx.sequence().audioTracks[1].muted = false;
    fx.render(512);
    fx.plan(kCMTimeZero, CMTimeMake(5, 1));
    fx.start(kCMTimeZero, 2);
    const std::vector<float> passed = MixFixture::left(fx.render(24000));
    double rmsLow = 0;
    for (size_t k = 4800; k < passed.size(); ++k) {
        rmsLow += passed[k] * passed[k];
    }
    rmsLow = std::sqrt(rmsLow / static_cast<double>(passed.size() - 4800));
    XCTAssertEqualWithAccuracy(rmsLow, 0.5 / std::sqrt(2.0), 0.005, @"the passband is flat");
    XCTAssertEqualWithAccuracy(estimateFrequency(passed.data(), 4800, 24000, 1, kSr), 4000.0, 5.0);
    XCTAssertGreaterThan(fx.mixer->processingLatency(2), 0.0);
    XCTAssertEqual(fx.mixer->processingLatency(1), 0.0);
    NSLog(@"2x decimation: 16 kHz input -> %.2e RMS (%.1f dB), 2 kHz -> %.4f RMS", rmsHigh,
          20 * std::log10(rmsHigh / (0.5 / std::sqrt(2.0))), rmsLow);
}

- (void)testMovingAClipToAnotherTrackKeepsItsSource {
    MixFixture fx;
    const AssetId a = fx.addTone("tone://a", sineSignal(300, 0.5));
    const ClipId id = fx.addClip(fx.a1, a, kCMTimeZero, CMTimeMake(5, 1), kCMTimeZero).id;
    fx.plan(kCMTimeZero, CMTimeMake(5, 1));
    fx.start(kCMTimeZero);
    fx.render(9600);
    Clip moved = *fx.sequence().findClip(id);
    fx.sequence().audioTracks[0].clips.clear();
    moved.trackId = fx.a2;
    fx.sequence().audioTracks[1].clips.push_back(moved);
    fx.plan(CMTimeMake(9600, 48000), CMTimeMake(5, 1));
    XCTAssertEqual(fx.mixer->stats().sourcesCreated, 1u);
    XCTAssertEqual(fx.mixer->stats().sources.size(), 1u);
    XCTAssertEqual(fx.mixer->stats().sources[0].track, fx.a2);
    const std::vector<float> out = MixFixture::left(fx.render(4800));
    double worst = 0;
    for (int64_t n = 0; n < 4800; ++n) {
        const double e = 0.5 * std::sin(2 * M_PI * 300 * static_cast<double>(n + 9600) / kSr);
        worst = std::max(worst, std::fabs(out[static_cast<size_t>(n)] - e));
    }
    XCTAssertLessThan(worst, 1e-6, @"continuous across the move");
    XCTAssertEqual(fx.mixer->stats().underruns, 0u);
}

- (void)testDroppedSourcesAreDestroyedOffTheCallersThread {
    MixFixture fx;
    const AssetId a = fx.addTone("tone://a", constantSignal(0.5f, 0.5f));
    fx.addClip(fx.a1, a, kCMTimeZero, CMTimeMake(5, 1), kCMTimeZero);
    fx.plan(kCMTimeZero, CMTimeMake(5, 1));
    fx.start(kCMTimeZero);
    fx.render(4800);
    // The decoder hangs; the producer blocks inside read() on its next refill.
    fx.tones->setReadsBlocked(true);
    std::vector<float> block(4096 * 2);
    for (int i = 0; i < 100 && fx.tones->blockedReads.load() == 0; ++i) {
        fx.mixer->render(block.data(), 4096, 2);
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    XCTAssertGreaterThanOrEqual(fx.tones->blockedReads.load(), 1);
    fx.mixer->stop();
    fx.mixer->render(block.data(), 512, 2);
    const auto t0 = std::chrono::steady_clock::now();
    fx.mixer->clearGraph(); // drops the source
    fx.mixer->render(block.data(), 512, 2); // the render thread retires the old plan
    fx.mixer->collectGarbage();
    fx.mixer->collectGarbage();
    const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
    XCTAssertLessThan(ms, 5.0, @"control calls never join a producer");
    XCTAssertTrue(fx.mixer->stats().sources.empty());
    XCTAssertGreaterThanOrEqual(fx.mixer->stats().garbageBatches, 1u);
    fx.tones->setReadsBlocked(false); // the reaper can now finish destroying the source
    NSLog(@"dropping a source whose decoder hangs: %.3f ms on the caller", ms);
}

- (void)testRenderPathDoesNotAllocate {
#if defined(__has_feature)
#if __has_feature(thread_sanitizer) || __has_feature(address_sanitizer)
    XCTSkip(@"the sanitizer runtime replaces malloc, so the malloc_logger hook sees nothing");
#endif
#endif
    MixFixture fx;
    const AssetId left = fx.addTone("tone://left", sineSignal(300, 0.4));
    const AssetId right = fx.addTone("tone://right", sineSignal(500, 0.4));
    Clip &p = fx.addClip(fx.a1, left, kCMTimeZero, CMTimeMake(30, 30), kCMTimeZero);
    fx.addFade(p, ClipEdge::Head, CMTimeMake(5, 30));
    const ClipId pid = p.id;
    const ClipId qid = fx.addClip(fx.a1, right, CMTimeMake(30, 30), CMTimeMake(60, 30), CMTimeMake(1, 1)).id;
    fx.addTransition(fx.a1, pid, qid, 10);
    fx.addClip(fx.a2, right, CMTimeMake(10, 30), CMTimeMake(60, 30), kCMTimeZero).audio.gainDb = -6;
    fx.plan(kCMTimeZero, CMTimeMake(4, 1));
    fx.start(kCMTimeZero);
    std::vector<float> buffer(4096 * 2);
    for (int i = 0; i < 10; ++i) {
        fx.mixer->render(buffer.data(), 512, 2); // warm up
    }

    AllocationCounter counter;
    // Positive control: the hook sees this thread's allocations.
    counter.start();
    auto *probe = new std::vector<int>(100);
    delete probe;
    XCTAssertGreaterThan(counter.stop(), 0u, @"allocation hook is not working");

    // Inside the measured region: a re-plan of the running transport (envelope crossfade), a
    // switch to 2x (continuation, anti-aliasing filter), a gain edit, mute and unmute ramps, a
    // stop (fade-out) and a new start.
    int64_t frames = 0;
    auto renderSome = [&](int count) {
        for (int i = 0; i < count; ++i) {
            const int n = (i % 10 == 0) ? 2048 : 100 + i % 50; // odd sizes, some above the internal chunk
            fx.mixer->render(buffer.data(), n, 2);
            frames += n;
        }
    };
    fx.plan(CMTimeMake(5120, 48000), CMTimeMake(4, 1));
    counter.start();
    renderSome(20);
    uint64_t allocations = counter.stop();
    fx.mixer->changeRate(2, fx.clock.startContinuation(2.0));
    fx.mixer->setMuted(true);
    counter.start();
    renderSome(40);
    allocations += counter.stop();
    fx.mixer->setMuted(false);
    fx.mixer->setMasterGain(0.5f);
    counter.start();
    renderSome(40);
    allocations += counter.stop();
    fx.mixer->stop();
    counter.start();
    renderSome(20);
    allocations += counter.stop();
    fx.mixer->start(CMTimeMake(1, 1), 1, fx.clock.start(CMTimeMake(1, 1), 1.0));
    counter.start();
    renderSome(80);
    allocations += counter.stop();
    XCTAssertEqual(allocations, 0u, @"heap allocations on the render path");
    XCTAssertGreaterThanOrEqual(fx.mixer->stats().planSwaps, 4u);
    XCTAssertGreaterThanOrEqual(fx.mixer->stats().planBlends, 2u);
    XCTAssertGreaterThanOrEqual(fx.mixer->stats().stopFades, 1u);
    NSLog(@"render path: %lld frames rendered with %llu allocations", frames, allocations);
}

@end
