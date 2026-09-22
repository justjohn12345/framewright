// AudioMixer: sample-accurate gain, fades and constant-power crossfades against an independent
// per-sample model; mute/solo; 2x; underruns under a starved producer; plan swaps and source
// reuse; and no heap allocation on the render path.

#import <XCTest/XCTest.h>

#include "../../Engine/Audio/AudioMixer.h"
#include "../../Engine/Render/Scheduler.h"
#include "../Media/BurnIn.h"
#include "AudioTestSupport.h"

#include <chrono>
#include <cmath>
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
        tones->readAllowed = nullptr;
        tones->notifyGate();
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
        clip.speed = speed;
        clip.sourceOut = sourceIn + scaleTime(duration, clip.speedRatio());
        Track &t = *sequence().findTrack(track);
        t.clips.push_back(clip);
        t.sortClips();
        return *t.find(clip.id);
    }

    void addTransition(TrackId track, ClipId from, ClipId to, int frames) {
        Transition t;
        t.id = project.ids.make<TransitionId>();
        t.trackId = track;
        t.fromClipId = from;
        t.toClipId = to;
        t.duration = CMTimeMake(frames, 30);
        sequence().transitions.push_back(t);
    }

    void plan(CMTime from, CMTime to) {
        mixer->setGraph(Scheduler::audioGraphFor(sequence(), project, TimeRange{from, to}), from);
    }

    /// prime + start at `at`, returns the clock epoch.
    uint32_t start(CMTime at, int rate = 1) {
        [[maybe_unused]] const bool primed = mixer->prime(at, std::chrono::seconds(5));
        const uint32_t epoch = clock.start(at, rate);
        mixer->start(at, rate, epoch);
        return epoch;
    }

    /// Renders `frames` output frames in blocks of `block`.
    std::vector<float> render(int64_t frames, int block = 512) {
        std::vector<float> out(static_cast<size_t>(frames) * 2);
        for (int64_t done = 0; done < frames; done += block) {
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
    clip.audio.fadeInDuration = CMTimeMake(3, 30);  // 0.1 s
    clip.audio.fadeOutDuration = CMTimeMake(6, 30); // 0.2 s
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
    std::atomic<bool> allowed{true};
    fx.tones->readAllowed = [&] { return allowed.load(); };
    const AssetId a = fx.addTone("tone://slow", constantSignal(0.5f, 0.5f));
    fx.addClip(fx.a1, a, kCMTimeZero, CMTimeMake(600, 30), kCMTimeZero);
    fx.plan(kCMTimeZero, CMTimeMake(20, 1));
    fx.start(kCMTimeZero);
    XCTAssertTrue(fx.mixer->waitForBuffered(std::chrono::seconds(5)));
    allowed = false; // the decoder blocks from now on

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
    allowed = true;
    fx.tones->notifyGate();
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
    clip->setTimelineEnd(CMTimeMake(120, 30));
    fx.plan(kCMTimeZero, CMTimeMake(5, 1));
    XCTAssertEqual(fx.mixer->stats().sourcesCreated, 1u);
    // Split into two pieces: still continuous media on the same track.
    Clip right = *clip;
    right.id = fx.project.ids.make<ClipId>();
    clip->setTimelineEnd(CMTimeMake(60, 30));
    right.setTimelineStartKeepingEnd(CMTimeMake(60, 30));
    fx.sequence().audioTracks[0].clips.push_back(right);
    fx.plan(kCMTimeZero, CMTimeMake(5, 1));
    XCTAssertEqual(fx.mixer->stats().sourcesCreated, 1u);
    XCTAssertEqual(fx.mixer->stats().sources.size(), 1u);
    // A slip (different source offset) needs new media.
    clip = fx.sequence().findClip(id);
    clip->sourceIn = CMTimeMake(1, 1);
    clip->sourceOut = clip->sourceIn + CMTimeMake(60, 30);
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

- (void)testRenderPathDoesNotAllocate {
    MixFixture fx;
    const AssetId left = fx.addTone("tone://left", sineSignal(300, 0.4));
    const AssetId right = fx.addTone("tone://right", sineSignal(500, 0.4));
    Clip &p = fx.addClip(fx.a1, left, kCMTimeZero, CMTimeMake(30, 30), kCMTimeZero);
    p.audio.fadeInDuration = CMTimeMake(5, 30);
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

    // A new plan and a 2x transport are adopted inside the measured region.
    fx.plan(CMTimeMake(5120, 48000), CMTimeMake(4, 1));
    fx.mixer->start(CMTimeMake(5120, 48000), 2, fx.clock.epoch());
    counter.start();
    int64_t frames = 0;
    for (int i = 0; i < 200; ++i) {
        const int n = (i % 10 == 0) ? 2048 : 100 + i % 50; // odd sizes, some above the internal chunk
        fx.mixer->render(buffer.data(), n, 2);
        frames += n;
    }
    const uint64_t allocations = counter.stop();
    XCTAssertEqual(allocations, 0u, @"heap allocations on the render path");
    XCTAssertGreaterThanOrEqual(fx.mixer->stats().planSwaps, 2u);
    NSLog(@"render path: %lld frames rendered with %llu allocations", frames, allocations);
}

@end
