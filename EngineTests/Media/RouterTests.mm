// BackendRouter: routing rules, policy overrides, decoder fallback, reasons, thread safety.

#import <XCTest/XCTest.h>

#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../../Engine/Media/BackendRouter.h"
#include "../../Engine/Media/HardwareCaps.h"
#include "BurnIn.h"
#include "RouterTestSupport.h"
#include "TestMedia.h"

#include <thread>

using namespace ve::media;
using namespace ve::test;

@interface RouterTests : XCTestCase
@end

@implementation RouterTests {
    std::shared_ptr<FakeBehavior> _apple; // A fake that claims the name "apple".
    std::shared_ptr<FakeBehavior> _other;
    std::shared_ptr<BackendRouter> _router;
}

- (void)setUp {
    _apple = std::make_shared<FakeBehavior>();
    _apple->name = "apple";
    _other = std::make_shared<FakeBehavior>();
    _other->name = "other";
    _router = std::make_shared<BackendRouter>();
}

- (std::string)mediaPath:(const std::string &)file {
    std::string error;
    const std::string path = testMediaPath(file, error);
    XCTAssertFalse(path.empty(), @"test media: %s", error.c_str());
    return path;
}

/// A prober answer describing `makeFakeInfo(path, container, codec, audio, firstIndex, backend)`.
static std::function<Result<MediaInfo>(const std::string &)> answer(const char *container, uint32_t codec, bool audio,
                                                                   int firstIndex, const char *backend) {
    return [=](const std::string &p) {
        return Result<MediaInfo>(makeFakeInfo(p, container, codec, audio, firstIndex, backend));
    };
}

static bool contains(const std::string &haystack, const std::string &needle) {
    return haystack.find(needle) != std::string::npos;
}

// MARK: - Real Apple backend

- (void)testPicksAppleForGeneratedAppleMedia {
    XCTAssertTrue(_router->registerBackend(apple::makeAppleBackend()).ok());
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_other)).ok());
    const HardwareCaps &caps = HardwareCaps::get();
    for (const TestClip &clip : testClips()) {
        const std::string path = [self mediaPath:clip.file];
        if (path.empty()) {
            return;
        }
        auto routed = _router->probe(path);
        XCTAssertTrue(routed.ok(), @"%s: %s", clip.file.c_str(),
                      routed.ok() ? "" : routed.error().description().c_str());
        if (!routed.ok()) {
            continue;
        }
        XCTAssertEqual(routed->info.backend, "apple", @"%s", clip.file.c_str());
        XCTAssertEqual(routed->routes.size(), routed->info.tracks.size());
        for (const TrackRoute &r : routed->routes) {
            XCTAssertEqual(r.backend, "apple", @"%s track %d: %s", clip.file.c_str(), r.trackIndex, r.reason.c_str());
            XCTAssertEqual(r.backendTrackIndex, r.trackIndex);
            XCTAssertTrue(contains(r.reason, "apple fast path") || r.kind == TrackKind::Video, @"%s", r.reason.c_str());
            const bool expectHW = r.kind == TrackKind::Video && caps.hardwareDecode(r.codec);
            XCTAssertEqual(r.hardwareDecode, expectHW, @"%s track %d", clip.file.c_str(), r.trackIndex);
            // The fake accepts everything, so it is listed as the fallback.
            XCTAssertEqual(r.fallbacks, std::vector<std::string>{"other"});
        }
        XCTAssertTrue(contains(routed->reason, "probe: apple ok"), @"%s", routed->reason.c_str());
        if (clip.hasVideo()) {
            XCTAssertEqual(routed->backendFor(TrackKind::Video), "apple");
        }
        if (clip.hasAudio()) {
            XCTAssertEqual(routed->backendFor(TrackKind::Audio), "apple");
        }
        XCTAssertEqual(_apple->opens.load(), 0);
    }
    // The fake prober was never asked: Apple handled everything.
    XCTAssertEqual(_other->opens.load(), 0);
}

- (void)testOpensDecodersThroughTheAppleRoute {
    XCTAssertTrue(_router->registerBackend(apple::makeAppleBackend()).ok());
    const std::string path = [self mediaPath:"h264_1080p30.mp4"];
    if (path.empty()) {
        return;
    }
    auto routed = _router->probe(path);
    XCTAssertTrue(routed.ok());
    auto video = _router->makeVideoDecoder(routed.value(), -1, {});
    XCTAssertTrue(video.ok(), @"%s", video.ok() ? "" : video.error().description().c_str());
    XCTAssertEqual(video->backend, "apple");
    XCTAssertFalse(video->fellBack);
    auto frame = video->decoder->next();
    XCTAssertTrue(frame.ok() && frame.value());
    auto audio = _router->makeAudioDecoder(routed.value(), -1, {});
    XCTAssertTrue(audio.ok());
    XCTAssertEqual(audio->backend, "apple");
    // Kind mismatches are rejected.
    const int audioIndex = routed->firstRoute(TrackKind::Audio)->trackIndex;
    XCTAssertEqual(_router->makeVideoDecoder(routed.value(), audioIndex, {}).error().code, MediaErrorCode::NoSuchTrack);
    const int videoIndex = routed->firstRoute(TrackKind::Video)->trackIndex;
    XCTAssertEqual(_router->makeAudioDecoder(routed.value(), videoIndex, {}).error().code, MediaErrorCode::NoSuchTrack);
}

- (void)testMissingFileReportsTheMostSpecificError {
    XCTAssertTrue(_router->registerBackend(apple::makeAppleBackend()).ok());
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_other)).ok()); // UnsupportedFormat
    auto routed = _router->probe("/nonexistent/clip.mov");
    XCTAssertFalse(routed.ok());
    XCTAssertEqual(routed.error().code, MediaErrorCode::FileNotFound);
    XCTAssertTrue(contains(routed.error().message, "apple:"), @"%s", routed.error().message.c_str());
    XCTAssertTrue(contains(routed.error().message, "other:"), @"%s", routed.error().message.c_str());
}

- (void)testNoBackendsIsAnError {
    XCTAssertEqual(_router->probe("/x.mov").error().code, MediaErrorCode::InvalidState);
}

// MARK: - Rules with fakes

- (void)testFallsBackToOtherBackendWhenAppleCannotProbe {
    _other->probe = [](const std::string &p) { return Result<MediaInfo>(makeFakeInfo(p, "mkv", fourcc::H264)); };
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_apple)).ok()); // probe fails
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_other)).ok());
    auto routed = _router->probe("/media/clip.mkv");
    XCTAssertTrue(routed.ok());
    XCTAssertEqual(routed->info.backend, "other");
    for (const TrackRoute &r : routed->routes) {
        XCTAssertEqual(r.backend, "other");
        XCTAssertTrue(contains(r.reason, "apple cannot probe the file"), @"%s", r.reason.c_str());
    }
    XCTAssertTrue(contains(routed->reason, "probe: apple failed"), @"%s", routed->reason.c_str());
    // The route reports what the chosen backend's prober measured (the fake reports hardware
    // for H.264 like a real prober on this machine would).
    XCTAssertEqual(routed->firstRoute(TrackKind::Video)->hardwareDecode,
                   HardwareCaps::get().hardwareDecode(fourcc::H264));
}

- (void)testPicksOtherBackendWhenAppleRejectsTheCodec {
    const uint32_t vorbis = fourcc::make("vorb");
    _apple->probe = [&](const std::string &p) {
        MediaInfo info = makeFakeInfo(p, "mp4", fourcc::VP9, true, 0, "apple");
        info.tracks[1].codec = {vorbis, "Vorbis"};
        return Result<MediaInfo>(info);
    };
    _apple->canHandle = [](const MediaInfo &) { return false; };
    // The other backend numbers its tracks differently.
    _other->probe = [&](const std::string &p) {
        MediaInfo info = makeFakeInfo(p, "mp4", fourcc::VP9, true, 7, "other");
        info.tracks[1].codec = {vorbis, "Vorbis"};
        return Result<MediaInfo>(info);
    };
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_apple)).ok());
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_other)).ok());
    auto routed = _router->probe("/media/vp9.mp4");
    XCTAssertTrue(routed.ok());
    XCTAssertEqual(routed->info.backend, "apple", @"the first successful probe describes the asset");
    const TrackRoute *video = routed->firstRoute(TrackKind::Video);
    XCTAssertEqual(video->backend, "other");
    XCTAssertEqual(video->trackIndex, 0);
    XCTAssertEqual(video->backendTrackIndex, 7);
    XCTAssertTrue(contains(video->reason, "first backend accepting it"), @"%s", video->reason.c_str());
    XCTAssertTrue(contains(video->reason, "apple cannot decode VP9 in mp4"), @"%s", video->reason.c_str());
    XCTAssertTrue(video->fallbacks.empty());
    const TrackRoute *audio = routed->firstRoute(TrackKind::Audio);
    XCTAssertEqual(audio->backend, "other");
    XCTAssertEqual(audio->backendTrackIndex, 8);
    XCTAssertFalse(audio->hardwareDecode);

    // The decoder is opened with the other backend's own track index.
    auto decoder = _router->makeVideoDecoder(routed.value(), -1, {});
    XCTAssertTrue(decoder.ok());
    XCTAssertEqual(decoder->backend, "other");
    XCTAssertEqual(_other->openedTrackIndices, std::vector<int>{7});
}

- (void)testSoftwareOnlyCodecStaysOnAppleWhenItIsTheFirstAcceptingBackend {
    const uint32_t mpeg4 = fourcc::make("mp4v");
    _apple->probe = answer("mov", mpeg4, false, 0, "apple");
    _other->probe = _apple->probe;
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_apple)).ok());
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_other)).ok());
    auto routed = _router->probe("/media/old.mov");
    XCTAssertTrue(routed.ok());
    const TrackRoute &r = routed->routes.at(0);
    XCTAssertEqual(r.backend, "apple");
    XCTAssertFalse(r.hardwareDecode);
    XCTAssertTrue(contains(r.reason, "does not decode in VideoToolbox hardware here"), @"%s", r.reason.c_str());
    XCTAssertTrue(contains(routed->reason, "[sw]"), @"%s", routed->reason.c_str());
}

- (void)testPreferBackendNameOverridesTheFastPath {
    _apple->probe = answer("mp4", fourcc::H264, true, 0, "apple");
    _other->probe = answer("mp4", fourcc::H264, true, 3, "other");
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_apple)).ok());
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_other)).ok());

    RoutingPolicy prefer;
    prefer.preferBackendName = "other";
    auto routed = _router->probe("/media/a.mp4", prefer);
    XCTAssertTrue(routed.ok());
    XCTAssertEqual(routed->info.backend, "other", @"the preferred backend is probed first");
    for (const TrackRoute &r : routed->routes) {
        XCTAssertEqual(r.backend, "other");
        XCTAssertTrue(contains(r.reason, "preferred by policy (other)"), @"%s", r.reason.c_str());
        XCTAssertEqual(r.fallbacks, std::vector<std::string>{"apple"});
    }
    XCTAssertEqual(routed->policy, prefer);

    // Through the global default as well.
    _router->setDefaultPolicy(prefer);
    XCTAssertEqual(_router->defaultPolicy(), prefer);
    XCTAssertEqual(_router->probe("/media/a.mp4")->routes.at(0).backend, "other");
    _router->setDefaultPolicy({});
    XCTAssertEqual(_router->probe("/media/a.mp4")->routes.at(0).backend, "apple");

    // Unknown or incapable preferences are ignored and explained.
    RoutingPolicy unknown;
    unknown.preferBackendName = "gstreamer";
    auto r2 = _router->probe("/media/a.mp4", unknown);
    XCTAssertEqual(r2->routes.at(0).backend, "apple");
    XCTAssertTrue(contains(r2->routes.at(0).reason, "preferred backend 'gstreamer' is not registered"),
                  @"%s", r2->routes.at(0).reason.c_str());
    _other->canHandle = [](const MediaInfo &) { return false; };
    auto r3 = _router->probe("/media/a.mp4", prefer);
    XCTAssertEqual(r3->routes.at(0).backend, "apple");
    XCTAssertTrue(contains(r3->routes.at(0).reason, "preferred backend 'other' cannot decode it"),
                  @"%s", r3->routes.at(0).reason.c_str());
}

- (void)testFallsBackWhenOpenFails {
    _apple->probe = answer("mp4", fourcc::H264, true, 0, "apple");
    _apple->failOpen = true;
    _other->probe = answer("mp4", fourcc::H264, true, 10, "other");
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_apple)).ok());
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_other)).ok());
    auto routed = _router->probe("/media/a.mp4");
    XCTAssertTrue(routed.ok());
    XCTAssertEqual(routed->firstRoute(TrackKind::Video)->backend, "apple");

    auto video = _router->makeVideoDecoder(routed.value(), -1, {});
    XCTAssertTrue(video.ok());
    XCTAssertEqual(video->backend, "other");
    XCTAssertTrue(video->fellBack);
    XCTAssertEqual(video->backendTrackIndex, 10);
    XCTAssertTrue(contains(video->reason, "apple open failed"), @"%s", video->reason.c_str());
    XCTAssertTrue(contains(video->reason, "scripted open failure"), @"%s", video->reason.c_str());
    XCTAssertTrue(contains(video->reason, "fell back to other"), @"%s", video->reason.c_str());
    XCTAssertEqual(_other->openedTrackIndices, std::vector<int>{10});

    auto audio = _router->makeAudioDecoder(routed.value(), -1, {});
    XCTAssertTrue(audio.ok());
    XCTAssertEqual(audio->backend, "other");
    XCTAssertEqual(audio->backendTrackIndex, 11);

    // Every backend failing reports the first failure with the whole story.
    _other->failOpen = true;
    auto failed = _router->makeVideoDecoder(routed.value(), -1, {});
    XCTAssertFalse(failed.ok());
    XCTAssertEqual(failed.error().code, MediaErrorCode::DecodeFailed);
    XCTAssertTrue(contains(failed.error().message, "apple open failed"), @"%s", failed.error().message.c_str());
    XCTAssertTrue(contains(failed.error().message, "other open failed"), @"%s", failed.error().message.c_str());
}

/// The routed decoder switches backends at run time: the Apple-routed decoder opens (so open-
/// time fallback cannot help) and then fails while decoding; the wrapper moves to the next
/// backend and resumes exactly where the caller was. Interrupts are not failures.
- (void)testRuntimeFallbackSwitchesBackendAndResumes {
    _apple->probe = answer("mov", fourcc::H264, true, 0, "apple");
    _other->probe = answer("mov", fourcc::H264, true, 0, "other");
    _apple->failAtFrame = 45;
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_apple)).ok());
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_other)).ok());
    auto routed = _router->probe("/media/a.mov");
    XCTAssertTrue(routed.ok());
    XCTAssertEqual(routed->backendFor(TrackKind::Video), "apple");
    auto opened = _router->makeVideoDecoder(routed.value(), -1, {});
    XCTAssertTrue(opened.ok());
    if (!opened.ok()) {
        return;
    }
    IVideoDecoder &decoder = *opened->decoder;
    XCTAssertEqual(opened->backend, "apple");
    XCTAssertFalse(opened->fellBack);
    XCTAssertEqual(decoder.activeBackend(), "apple");
    for (int i = 0; i < 60; ++i) {
        auto f = decoder.next();
        XCTAssertTrue(f.ok() && f.value(), @"frame %d: %s", i, f.ok() ? "end" : f.error().description().c_str());
        if (!f.ok() || !f.value()) {
            return;
        }
        XCTAssertEqual(readBurnIn(f.value()->image.get()), std::optional<int>(i), @"continuous across the switch");
    }
    XCTAssertEqual(decoder.activeBackend(), "other");
    XCTAssertEqual(_other->opens.load(), 1);

    // A failure on the very first frame switches too; a seek target is replayed.
    _apple->failAtFrame = 0;
    auto second = _router->makeVideoDecoder(routed.value(), -1, {});
    // The Apple fake fails at frame 0 only when decoding, so open succeeds.
    XCTAssertTrue(second.ok());
    if (second.ok()) {
        XCTAssertTrue(second->decoder->seek(CMTimeMake(3, 1)).ok());
        auto f = second->decoder->next();
        XCTAssertTrue(f.ok() && f.value());
        if (f.ok() && f.value()) {
            XCTAssertEqual(readBurnIn(f.value()->image.get()), std::optional<int>(90), @"resumed at the seek target");
        }
        XCTAssertEqual(second->decoder->activeBackend(), "other");
    }

    // Cancelled is not a decode failure: no switch.
    _apple->failAtFrame = 5;
    _apple->failCode = MediaErrorCode::Cancelled;
    auto third = _router->makeVideoDecoder(routed.value(), -1, {});
    XCTAssertTrue(third.ok());
    if (third.ok()) {
        for (int i = 0; i < 5; ++i) {
            XCTAssertTrue(third->decoder->next().ok());
        }
        auto f = third->decoder->next();
        XCTAssertFalse(f.ok());
        XCTAssertEqual(third->decoder->activeBackend(), "apple");
    }

    // Audio: the wrapper resumes at the sample position read() had reached.
    _apple->failAudioAtSample = 48000;
    auto audio = _router->makeAudioDecoder(routed.value(), -1, {});
    XCTAssertTrue(audio.ok());
    if (audio.ok()) {
        std::vector<float> buffer(4096 * 2);
        int64_t total = 0;
        for (int i = 0; i < 20; ++i) {
            auto n = audio->decoder->read(buffer.data(), 4096);
            XCTAssertTrue(n.ok());
            total += n.ok() ? n.value() : 0;
        }
        XCTAssertEqual(total, 20 * 4096);
        XCTAssertEqual(audio->decoder->position(), total, @"no samples lost or repeated across the switch");
        XCTAssertEqual(audio->decoder->activeBackend(), "other");
    }
}

- (void)testUnroutableTracksAndTotalFailure {
    const uint32_t weird = fourcc::make("wxyz");
    _apple->probe = [&](const std::string &p) {
        MediaInfo info = makeFakeInfo(p, "mov", weird, true, 0, "apple");
        return Result<MediaInfo>(info);
    };
    // Apple decodes only the audio track; nobody decodes the video.
    _apple->canHandle = [&](const MediaInfo &i) { return i.tracks.at(0).kind == TrackKind::Audio; };
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_apple)).ok());
    auto routed = _router->probe("/media/w.mov");
    XCTAssertTrue(routed.ok());
    XCTAssertTrue(routed->firstRoute(TrackKind::Video)->backend.empty());
    XCTAssertTrue(contains(routed->firstRoute(TrackKind::Video)->reason, "no backend can decode it"));
    XCTAssertEqual(routed->firstRoute(TrackKind::Audio)->backend, "apple");
    auto video = _router->makeVideoDecoder(routed.value(), -1, {});
    XCTAssertEqual(video.error().code, MediaErrorCode::UnsupportedCodec);

    _apple->canHandle = [](const MediaInfo &) { return false; };
    auto none = _router->probe("/media/w.mov");
    XCTAssertFalse(none.ok());
    XCTAssertEqual(none.error().code, MediaErrorCode::UnsupportedCodec);
    XCTAssertTrue(contains(none.error().message, "no backend can decode any track"), @"%s",
                  none.error().message.c_str());
}

- (void)testAllowHardwareFalseIsPropagated {
    _apple->probe = answer("mp4", fourcc::H264, true, 0, "apple");
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_apple)).ok());
    RoutingPolicy software;
    software.allowHardware = false;
    auto routed = _router->probe("/media/a.mp4", software);
    XCTAssertTrue(routed.ok());
    for (const TrackRoute &r : routed->routes) {
        XCTAssertFalse(r.hardwareDecode);
    }
    DecodeOptions options;
    options.allowHardware = true;
    XCTAssertTrue(_router->makeVideoDecoder(routed.value(), -1, options).ok());
    XCTAssertEqual(_apple->openedAllowHardware, std::vector<bool>{false});
}

- (void)testRegistration {
    XCTAssertEqual(_router->registerBackend(nullptr).error().code, MediaErrorCode::InvalidArgument);
    auto unnamed = std::make_shared<FakeBehavior>();
    unnamed->name = "";
    XCTAssertEqual(_router->registerBackend(std::make_shared<FakeBackend>(unnamed)).error().code,
                   MediaErrorCode::InvalidArgument);
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_apple)).ok());
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_other)).ok());
    XCTAssertEqual(_router->backendNames(), (std::vector<std::string>{"apple", "other"}));
    // Same name replaces in place, keeping the priority.
    auto replacement = std::make_shared<FakeBehavior>();
    replacement->name = "apple";
    auto replacementBackend = std::make_shared<FakeBackend>(replacement);
    XCTAssertTrue(_router->registerBackend(replacementBackend).ok());
    XCTAssertEqual(_router->backendNames(), (std::vector<std::string>{"apple", "other"}));
    XCTAssertEqual(_router->backend("apple"), std::static_pointer_cast<IMediaBackend>(replacementBackend));
    XCTAssertTrue(_router->unregisterBackend("apple"));
    XCTAssertFalse(_router->unregisterBackend("apple"));
    XCTAssertEqual(_router->backendNames(), std::vector<std::string>{"other"});
    XCTAssertEqual(BackendRouter::makeDefault()->backendNames(), std::vector<std::string>{"apple"});
}

- (void)testConcurrentProbesAndRegistration {
    _apple->probe = answer("mp4", fourcc::H264, true, 0, "apple");
    _other->probe = answer("mkv", fourcc::VP9, true, 0, "other");
    XCTAssertTrue(_router->registerBackend(std::make_shared<FakeBackend>(_apple)).ok());
    std::atomic<int> ok{0};
    std::vector<std::thread> threads;
    for (int t = 0; t < 8; ++t) {
        threads.emplace_back([&, t] {
            for (int i = 0; i < 200; ++i) {
                if (t == 0 && i % 10 == 0) {
                    if (i % 20 == 0) {
                        (void)_router->registerBackend(std::make_shared<FakeBackend>(_other));
                    } else {
                        _router->unregisterBackend("other");
                    }
                    RoutingPolicy p;
                    p.allowHardware = (i % 40) == 0;
                    _router->setDefaultPolicy(p);
                }
                auto routed = _router->probe("/media/c.mp4");
                if (routed.ok()) {
                    ++ok;
                    auto d = _router->makeVideoDecoder(routed.value(), -1, {});
                    (void)d;
                }
            }
        });
    }
    for (auto &t : threads) {
        t.join();
    }
    XCTAssertEqual(ok.load(), 8 * 200);
}

@end
