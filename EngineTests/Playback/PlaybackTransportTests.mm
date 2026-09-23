// PlaybackController transport latency and robustness: transport calls return at once while the
// pipeline pre-rolls behind slow (gated) decoders and a slow (gated) device start; readers are
// never blocked by source destruction; device events race transport calls without a second
// Clock writer; a lost device falls back to the host clock with an error; paused audio
// producers stop waking up.
//
// Most tests use the tone backend (AudioTestSupport: synthetic audio whose decoder reads can be
// blocked) and a ScriptedAudioOutput on a virtual host clock (a "device" whose start can be
// blocked and whose callbacks the test paces). Latency bounds: every transport and reader call
// must return in under 5 ms on the calling thread (it does sub-millisecond work plus a mutex no
// thread holds across a blocking call); measured values are logged.

#import <XCTest/XCTest.h>

#include "../Audio/AudioTestSupport.h"
#include "PlaybackTestSupport.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <map>
#include <thread>

using namespace ve;
using namespace ve::playback;
using namespace ve::test;
using SteadyClock = std::chrono::steady_clock;

namespace {

constexpr double kSr = 48000.0;
constexpr double kCallerBudgetMs = 5.0;

double msSince(SteadyClock::time_point t) {
    return std::chrono::duration<double, std::milli>(SteadyClock::now() - t).count();
}

/// Times `call` on this thread (ms).
template <class F> double timed(F &&call) {
    const auto t0 = SteadyClock::now();
    call();
    return msSince(t0);
}

struct Worst {
    double ms = 0;
    std::string what;
    void note(const char *name, double value) {
        if (value > ms) {
            ms = value;
            what = name;
        }
    }
};

} // namespace

@interface PlaybackTransportTests : XCTestCase
@end

@implementation PlaybackTransportTests

- (void)testTransportCallsReturnAtOnceWhileThePipelinePrerolls {
    ToneRig rig(1, [](PlaybackConfig &config) { config.prerollTimeout = std::chrono::seconds(60); });
    // A slow device start (the tick thread blocks in it from the moment the sequence opens) and
    // decoders that cannot deliver.
    rig.out->setStartGate(true);
    rig.tones->setReadsBlocked(true);
    rig.load();
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return rig.out->startAttempts.load() >= 1; }),
                  @"the tick thread is inside the device start");
    Worst worst;
    std::map<std::string, double> log; // worst per call
    auto measure = [&](const char *name, auto &&call) {
        const double ms = timed(call);
        worst.note(name, ms);
        log[name] = std::max(log[name], ms);
        return ms;
    };

    measure("play", [&] { rig.controller->play(); });
    XCTAssertEqual(rig.controller->state(), PlaybackState::Prerolling, @"Prerolling is published at once");
    XCTAssertEqual(rig.out->starts.load(), 0);
    // The tick thread is blocked inside the device start; callers never wait for it.
    for (int i = 0; i < 20; ++i) {
        measure("currentTime", [&] { (void)rig.controller->currentTime(); });
        measure("stats", [&] { (void)rig.controller->stats(); });
        measure("status", [&] { (void)rig.controller->status(); });
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    measure("seek while prerolling", [&] { rig.controller->seek(CMTimeMake(1, 2)); });
    XCTAssertEqual(rig.controller->state(), PlaybackState::Prerolling);
    XCTAssertEqual(CMTimeCompare(rig.controller->currentTime(), CMTimeMake(1, 2)), 0);
    measure("setRate(2)", [&] { rig.controller->setRate(2.0); });
    measure("shuttleForward", [&] { rig.controller->shuttleForward(); });
    XCTAssertEqual(rig.controller->rate(), 4.0);
    measure("setMuted", [&] { rig.controller->setMuted(true); });
    measure("setMuted", [&] { rig.controller->setMuted(false); });
    measure("setRate(1)", [&] { rig.controller->setRate(1.0); });
    XCTAssertEqual(rig.controller->state(), PlaybackState::Prerolling);

    // The device comes up; the audio still cannot prime, so pre-roll keeps waiting (its timeout
    // is a minute here).
    rig.out->setStartGate(false);
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return rig.out->starts.load() >= 1; }));
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    XCTAssertEqual(rig.controller->state(), PlaybackState::Prerolling, @"waits for the audio");
    measure("seek while waiting for audio", [&] { rig.controller->seek(CMTimeMake(1, 1)); });

    // Decoders deliver: playback starts, on the audio clock, from the last seek.
    rig.tones->setReadsBlocked(false);
    XCTAssertTrue(rig.waitForState(PlaybackState::Playing));
    XCTAssertEqual(rig.controller->clock().mode(), audio::ClockMode::AudioSamples);
    rig.startPump();
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return CMTimeGetSeconds(rig.controller->currentTime()) > 1.2; }));
    const auto capture = rig.out->capture();
    XCTAssertEqual(capture.firstSequenceSample, static_cast<int64_t>(kSr), @"audio starts at the seek target");
    double sum = 0;
    for (size_t i = 0; i < 9600 && i < capture.samples.size(); ++i) {
        sum += capture.samples[i] * capture.samples[i];
    }
    XCTAssertGreaterThan(std::sqrt(sum / 9600), 0.3, @"the 0.5-amplitude tone plays from the first sample");

    // While playing: rate changes in one direction, a seek, pause.
    measure("setRate(2) playing", [&] { rig.controller->setRate(2.0); });
    XCTAssertEqual(rig.controller->state(), PlaybackState::Playing, @"1x -> 2x without pre-roll");
    XCTAssertEqual(rig.controller->clock().mode(), audio::ClockMode::AudioSamples);
    measure("shuttleForward playing", [&] { rig.controller->shuttleForward(); });
    XCTAssertEqual(rig.controller->clock().mode(), audio::ClockMode::HostTime, @"4x: video only");
    measure("setRate(1) playing", [&] { rig.controller->setRate(1.0); });
    XCTAssertEqual(rig.controller->state(), PlaybackState::Playing, @"4x -> 1x without pre-roll");
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return rig.controller->clock().mode() == audio::ClockMode::AudioSamples; }),
                  @"the audio joins the running playback");
    rig.tones->setReadsBlocked(true);
    measure("seek playing", [&] { rig.controller->seek(CMTimeMake(5, 1)); });
    XCTAssertEqual(rig.controller->state(), PlaybackState::Prerolling);
    measure("pause", [&] { rig.controller->pause(); });
    rig.tones->setReadsBlocked(false);
    rig.stopPump();

    std::string all;
    for (const auto &[name, ms] : log) {
        char line[96];
        std::snprintf(line, sizeof(line), "%s %.4f ms; ", name.c_str(), ms);
        all += line;
    }
    XCTAssertLessThan(worst.ms, kCallerBudgetMs, @"%s took %.3f ms", worst.what.c_str(), worst.ms);
    NSLog(@"caller-side latency while pre-rolling behind a blocked device start and blocked decoders: worst %.3f ms "
          @"(%s); %s",
          worst.ms, worst.what.c_str(), all.c_str());
}

- (void)testColdCachePlayAndSeeksDoNotBlockTheCaller {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 1.0);
    const AssetId h264 = h.importAsset("h264_1080p30.mp4");
    const AssetId hevc = h.importAsset("hevc_720p2997.mov");
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    const ClipId a = h.addClip(h.v1, h264, 0, 120, kCMTimeZero);
    const ClipId b = h.addClip(h.v1, hevc, 120, 150, CMTimeMake(1, 1));
    const ClipId aa = h.addClip(h.a1, h264, 0, 120, kCMTimeZero);
    const ClipId ba = h.addClip(h.a1, hevc, 120, 150, CMTimeMake(1, 1));
    h.link(a, aa);
    h.link(b, ba);
    h.load();
    Worst worst;
    // Cold: nothing decoded, no decoder open, the output possibly still starting.
    h.controller->seek(CMTimeMake(3, 1));
    const double play = timed([&] { h.controller->play(); });
    worst.note("play (cold)", play);
    XCTAssertEqual(h.controller->state(), PlaybackState::Prerolling);
    XCTAssertTrue(h.waitForState(PlaybackState::Playing));
    const double seek = timed([&] { h.controller->seek(CMTimeMake(7, 1)); }); // cold region, other decoder
    worst.note("seek (cold)", seek);
    XCTAssertTrue(h.waitForState(PlaybackState::Playing));
    worst.note("setRate(2)", timed([&] { h.controller->setRate(2.0); }));
    worst.note("shuttleForward", timed([&] { h.controller->shuttleForward(); }));
    worst.note("setMuted", timed([&] { h.controller->setMuted(true); }));
    worst.note("setRate(-1)", timed([&] { h.controller->setRate(-1.0); }));
    XCTAssertTrue(h.waitForState(PlaybackState::Playing));
    worst.note("pause", timed([&] { h.controller->pause(); }));
    XCTAssertLessThan(worst.ms, kCallerBudgetMs, @"%s took %.3f ms", worst.what.c_str(), worst.ms);
    NSLog(@"cold cache: play() %.3f ms, seek() %.3f ms; worst transport call %.3f ms (%s)", play, seek, worst.ms,
          worst.what.c_str());
}

- (void)testDeviceEventsRacingTransportKeepASingleClockWriter {
    ToneRig rig(2);
    rig.load();
    rig.startPump(std::chrono::microseconds(500));
    std::atomic<bool> running{true};
    std::atomic<int> events{0};
    // AVAudioEngine posts configuration changes on its own thread; the scripted output delivers
    // them on this one, as fast as it can.
    std::thread device([&] {
        int k = 0;
        while (running.load()) {
            audio::AudioOutputEvent event;
            event.kind = audio::AudioOutputEvent::Kind::ConfigurationChanged;
            event.running = true;
            event.latency = (k++ % 2) ? 0.02 : 0.01;
            rig.out->setLatency(event.latency);
            rig.out->emit(event);
            ++events;
            std::this_thread::sleep_for(std::chrono::microseconds(200));
        }
    });
    const auto t0 = SteadyClock::now();
    int calls = 0;
    while (msSince(t0) < 1500) {
        switch (calls++ % 7) {
        case 0:
            rig.controller->play();
            break;
        case 1:
            rig.controller->setRate(2.0);
            break;
        case 2:
            rig.controller->seek(CMTimeMakeWithSeconds(0.5 * (calls % 20), 30));
            break;
        case 3:
            rig.controller->setRate(1.0);
            break;
        case 4:
            rig.controller->shuttleForward();
            break;
        case 5:
            rig.controller->pause();
            break;
        default:
            rig.controller->setMuted(calls % 2 == 0);
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(3));
    }
    running = false;
    device.join();
    XCTAssertEqual(rig.controller->clock().controlViolations(), 0u, @"the Clock had a second control writer");
    // Still healthy: plays on the audio clock with the latest latency applied.
    rig.controller->seek(kCMTimeZero);
    rig.controller->setRate(1.0);
    XCTAssertTrue(rig.waitForState(PlaybackState::Playing));
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return rig.controller->clock().mode() == audio::ClockMode::AudioSamples; }));
    XCTAssertTrue(PlaybackHarness::waitUntil([&] {
        return std::fabs(rig.controller->clock().outputLatency() - rig.out->outputLatency()) < 1e-9;
    }));
    rig.controller->pause();
    rig.stopPump();
    NSLog(@"%d configuration-change events raced %d transport calls: %llu clock control violations", events.load(),
          calls, rig.controller->clock().controlViolations());
}

- (void)testLostDeviceFallsBackToTheHostClockWithAnError {
    ToneRig rig(1);
    dispatch_queue_t queue = dispatch_queue_create("playback.error.test", DISPATCH_QUEUE_SERIAL);
    std::atomic<bool> errorSeen{false};
    rig.controller->setObserver(queue, PlaybackObserver{[&](const PlaybackStatus &status) {
                                                             if (status.lastError &&
                                                                 status.lastError->code == PlaybackErrorCode::AudioDeviceLost) {
                                                                 errorSeen = true;
                                                             }
                                                         },
                                                         nullptr});
    rig.load();
    rig.controller->play();
    XCTAssertTrue(rig.waitForState(PlaybackState::Playing));
    XCTAssertEqual(rig.controller->clock().mode(), audio::ClockMode::AudioSamples);
    for (int i = 0; i < 50; ++i) {
        rig.renderBlock();
    }
    // The engine stopped for a device change and could not restart (reported from its thread).
    std::thread device([&] {
        audio::AudioOutputEvent event;
        event.kind = audio::AudioOutputEvent::Kind::RestartFailed;
        event.message = "the output device went away";
        rig.out->emit(event);
    });
    device.join();
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return rig.controller->status().lastError.has_value(); }));
    const PlaybackStatus status = rig.controller->status();
    XCTAssertEqual(status.state, PlaybackState::Playing, @"playback goes on");
    XCTAssertFalse(status.audioActive);
    XCTAssertEqual(status.lastError->code, PlaybackErrorCode::AudioDeviceLost);
    XCTAssertEqual(status.lastError->message, "the output device went away");
    XCTAssertEqual(rig.controller->clock().mode(), audio::ClockMode::HostTime);
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return errorSeen.load(); }), @"the observer is told");
    // No device callbacks any more: the host clock carries the time.
    const double t0 = CMTimeGetSeconds(rig.controller->clock().now());
    rig.host->advance(500'000'000ull);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds(rig.controller->clock().now()), t0 + 0.5, 1e-6);
    XCTAssertEqual(rig.controller->clock().controlViolations(), 0u);
    // The next play tries the output again and clears the error once audio runs.
    rig.controller->pause();
    rig.controller->play();
    XCTAssertTrue(rig.waitForState(PlaybackState::Playing));
    XCTAssertEqual(rig.controller->clock().mode(), audio::ClockMode::AudioSamples);
    XCTAssertFalse(rig.controller->status().lastError.has_value());
    rig.controller->pause();
    rig.controller->setObserver(nullptr, PlaybackObserver{});
}

- (void)testReadersAreNotBlockedWhileSourcesAreDestroyed {
    ToneRig rig(2);
    rig.load();
    rig.controller->play();
    XCTAssertTrue(rig.waitForState(PlaybackState::Playing));
    rig.startPump();
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return CMTimeGetSeconds(rig.controller->currentTime()) > 0.3; }));
    // The decoder hangs (a network stall): the producer blocks inside read(), so destroying its
    // source (which joins the producer) blocks until the stall ends.
    rig.tones->setReadsBlocked(true);
    // Consumption triggers a refill, which then blocks in the gated read.
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return rig.tones->blockedReads.load() >= 1; }));
    // The playing clip goes away (the sequence goes on to 20 s): its source must be destroyed.
    Track &a1 = rig.sequence().audioTracks[0];
    a1.clips.erase(std::remove_if(a1.clips.begin(), a1.clips.end(), [&](const Clip &c) { return c.id == rig.clips[0]; }),
                   a1.clips.end());
    const double edit = timed([&] { rig.publish(); });
    Worst worst;
    worst.note("modelChanged", edit);
    const auto t0 = SteadyClock::now();
    while (msSince(t0) < 300) {
        worst.note("currentTime", timed([&] { (void)rig.controller->currentTime(); }));
        worst.note("stats", timed([&] { (void)rig.controller->stats(); }));
        worst.note("state", timed([&] { (void)rig.controller->state(); }));
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return rig.controller->mixer().stats().sources.empty(); }));
    // The tick thread stays responsive too: a seek completes its pre-roll (no audio there).
    rig.controller->seek(CMTimeMake(2, 1));
    XCTAssertTrue(rig.waitForState(PlaybackState::Playing));
    XCTAssertLessThan(worst.ms, kCallerBudgetMs, @"%s took %.3f ms", worst.what.c_str(), worst.ms);
    rig.tones->setReadsBlocked(false); // the stall ends; the reaper finishes the destruction
    rig.controller->pause();
    rig.stopPump();
    NSLog(@"source destruction stuck behind a hung decoder: worst reader/control call %.3f ms (%s)", worst.ms,
          worst.what.c_str());
}

- (void)testPausedProducersStopWakingUp {
    ToneRig rig(3);
    rig.load();
    rig.controller->play();
    XCTAssertTrue(rig.waitForState(PlaybackState::Playing));
    rig.startPump();
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return CMTimeGetSeconds(rig.controller->currentTime()) > 1.0; }));
    const uint64_t playingStart = rig.producerWakeups();
    const auto playingT0 = SteadyClock::now();
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
    const double playingRate = static_cast<double>(rig.producerWakeups() - playingStart) / (msSince(playingT0) / 1000.0);
    rig.controller->pause();
    // The device keeps rendering (silence); the paused sources top up (at least to the refill
    // level, then on to the lookahead) and go to sleep.
    const int64_t refill = static_cast<int64_t>(rig.controller->mixer().config().refillSeconds * kSr);
    XCTAssertTrue(PlaybackHarness::waitUntil([&] {
        const auto sources = rig.controller->mixer().stats().sources;
        return !sources.empty() &&
               std::all_of(sources.begin(), sources.end(), [&](const auto &s) { return s.bufferedFrames >= refill; });
    }));
    std::this_thread::sleep_for(std::chrono::milliseconds(50));
    const uint64_t before = rig.producerWakeups();
    std::this_thread::sleep_for(std::chrono::seconds(1));
    const uint64_t wakeups = rig.producerWakeups() - before;
    XCTAssertLessThanOrEqual(wakeups, 2u, @"paused producers must not poll");
    rig.stopPump();
    NSLog(@"producer wake-ups: %.1f/s while playing (5x real time), %llu in 1 s paused", playingRate, wakeups);
}

@end
