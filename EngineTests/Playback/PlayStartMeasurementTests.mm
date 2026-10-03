// Press-to-picture and press-to-audio after the ways a playhead comes to rest: a pause, a scrub released at a random
// point, a ruler click, and a J/K/L shuttle stopped with K. Run in the Measurements scheme (it prints numbers and
// asserts nothing about them: wall-clock times vary with the Mac and its load).
//
// The controller runs as the program monitor's does (the machine's real audio output, the frame cache's default
// budget, the pool's lookahead), its frame source called every half millisecond on one thread (a display link far
// faster than any screen, so the numbers are the controller's, not the vsync's). The media are long-GOP: a keyframe
// every 5 s in 1080p and 4K H.264 and HEVC, and a variable-frame-rate 4K screen recording whose keyframes lie up to
// tens of seconds apart (the generated clips re-encoded with VideoToolbox through the ffmpeg tool, with film grain so
// the decoder has real work; cached beside the generated media).
//
// Per start it reports
// - picture: when the first clock-driven frame after the paused one was presented with every layer showing its own
//   picture (not a held earlier one), minus the playing time that frame stands for, i.e. how late the moving picture
//   runs against a start at the instant of the press;
// - audio: press to the clock start (state Playing; the first sample is audible one output latency later);
// - late: presentations in the first second that held an earlier picture for want of a decoded one;
// - decoded: frames the lookahead stream of the clip delivered from the release (the end of the scrub, the click or
//   the pause) to the picture above, its seeks in that time (each decodes from the keyframe before the time sought:
//   the frames of the GOP before it are decoded but not delivered, so they are not in the count) and the seeks after
//   the press (a seek on the press path).
//
// FW_PLAYSTART_TRIALS sets the starts per case (default 5); FW_PLAYSTART_MEDIA a substring of the media label to run
// one file only; FW_PLAYSTART_FILE a generated test clip (TestMedia.h) to measure instead of the long-GOP files. From
// xcodebuild, prefix them with TEST_RUNNER_.

#import <XCTest/XCTest.h>

#include "PlaybackTestSupport.h"

#include "../Media/FFmpegTestMedia.h"
#include "../Media/TestMedia.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <mutex>
#include <random>
#include <thread>

using namespace ve;
using namespace ve::playback;
using namespace ve::test;

namespace {

namespace fs = std::filesystem;
using SteadyClock = std::chrono::steady_clock;

double msBetween(SteadyClock::time_point a, SteadyClock::time_point b) {
    return std::chrono::duration<double, std::milli>(b - a).count();
}

void sleepMs(double ms) {
    std::this_thread::sleep_for(std::chrono::microseconds(static_cast<int64_t>(ms * 1000)));
}

/// A measurement file: made by the ffmpeg tool from generated clips.
struct MeasureMedia {
    std::string label;
    std::string file;
    std::vector<std::string> sources; ///< Generated clips, the tool's inputs in order.
    std::vector<std::string> args;    ///< The tool's arguments after the inputs.
    bool loopSecondInput = false;     ///< -stream_loop -1 before the second input (audio as long as the video).
};

const std::vector<MeasureMedia> &measureMedia() {
    static const std::vector<MeasureMedia> media = {
        {"H.264 1080p, GOP 5 s", "gop5s_h264_1080p_grain.mp4", {"gop5s_h264_1080p30.mp4", "h264_1080p30.mp4"},
         {"-map", "0:v", "-map", "1:a", "-vf", "noise=alls=12:allf=t", "-c:v", "h264_videotoolbox", "-b:v", "20M", "-g",
          "150", "-pix_fmt", "yuv420p", "-c:a", "copy"}},
        {"HEVC 1080p, GOP 5 s", "gop5s_hevc_1080p_grain.mp4", {"gop5s_h264_1080p30.mp4", "h264_1080p30.mp4"},
         {"-map", "0:v", "-map", "1:a", "-vf", "noise=alls=12:allf=t", "-c:v", "hevc_videotoolbox", "-tag:v", "hvc1",
          "-b:v", "15M", "-g", "150", "-pix_fmt", "yuv420p", "-c:a", "copy"}},
        {"H.264 4K, GOP 5 s", "gop5s_h264_2160p_grain.mp4", {"gop5s_h264_1080p30.mp4", "h264_1080p30.mp4"},
         {"-map", "0:v", "-map", "1:a", "-vf", "scale=3840:2160,noise=alls=12:allf=t", "-c:v", "h264_videotoolbox",
          "-b:v", "40M", "-g", "150", "-pix_fmt", "yuv420p", "-c:a", "copy"}},
        {"HEVC 4K, GOP 5 s", "gop5s_hevc_2160p_grain.mp4", {"gop5s_h264_1080p30.mp4", "h264_1080p30.mp4"},
         {"-map", "0:v", "-map", "1:a", "-vf", "scale=3840:2160,noise=alls=12:allf=t", "-c:v", "hevc_videotoolbox",
          "-tag:v", "hvc1", "-b:v", "30M", "-g", "150", "-pix_fmt", "yuv420p", "-c:a", "copy"}},
        {"VFR 4K screen recording, GOP 120 frames", "screencast_vfr_2160p_grain.mov",
         {"screencast_vfr_h264.mov", "h264_1080p30.mp4"},
         {"-map", "0:v", "-map", "1:a", "-vf", "scale=3840:2160,noise=alls=6:allf=t", "-fps_mode", "passthrough",
          "-c:v", "h264_videotoolbox", "-b:v", "20M", "-g", "120", "-pix_fmt", "yuv420p", "-c:a", "copy", "-shortest"},
         true},
    };
    return media;
}

/// Runs the ffmpeg tool; "" on success, else what went wrong.
std::string runTool(const std::vector<std::string> &args) {
    const std::string tool = ffmpegToolPath();
    if (tool.empty()) {
        return "the ffmpeg tool was not built (BUILD_TOOLS=0)";
    }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@(tool.c_str())];
    NSMutableArray<NSString *> *list = [NSMutableArray array];
    for (const std::string &arg : args) {
        [list addObject:@(arg.c_str())];
    }
    task.arguments = list;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return std::string("cannot launch ffmpeg: ") + error.localizedDescription.UTF8String;
    }
    NSData *output = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
        return "ffmpeg exited with " + std::to_string(task.terminationStatus) + ": " + (text ? text.UTF8String : "");
    }
    return {};
}

/// The measurement file (made on first use, kept beside the generated media); "" with `error` set on failure.
std::string measurementMediaPath(const MeasureMedia &media, std::string &error) {
    const std::string base = testMediaDirectory(error);
    if (base.empty()) {
        return {};
    }
    const fs::path dir = fs::path(base + "-playstart1");
    std::error_code ec;
    fs::create_directories(dir, ec);
    const fs::path path = dir / media.file;
    if (fs::exists(path, ec)) {
        return path.string();
    }
    std::vector<std::string> args = {"-hide_banner", "-loglevel", "error", "-y"};
    for (size_t i = 0; i < media.sources.size(); ++i) {
        const std::string source = testMediaPath(media.sources[i], error);
        if (source.empty()) {
            return {};
        }
        if (i == 1 && media.loopSecondInput) {
            args.insert(args.end(), {"-stream_loop", "-1"});
        }
        args.insert(args.end(), {"-i", source});
    }
    args.insert(args.end(), media.args.begin(), media.args.end());
    const fs::path working = dir / ("working-" + media.file);
    args.push_back(working.string());
    if (std::string failure = runTool(args); !failure.empty()) {
        error = failure;
        fs::remove(working, ec);
        return {};
    }
    fs::rename(working, path, ec);
    if (ec) {
        error = ec.message();
        return {};
    }
    return path.string();
}

/// What the frame source presented, as the presenter thread saw it.
struct Presentation {
    SteadyClock::time_point at;
    int64_t frameIndex = -1;
    bool clockDriven = false;
    bool exact = false; ///< Every layer showed its own picture.
};

/// Calls a frame source of the controller every half millisecond on its own thread (the render thread of a view
/// whose display link runs far faster than any screen) and logs what it presented.
class Presenter {
  public:
    explicit Presenter(PlaybackController &controller) : controller_(controller) {
        auto created = render::TextureCache::create(MTLCreateSystemDefaultDevice());
        if (created.ok()) {
            textures_ = std::move(created).value();
        }
        source_ = controller_.frameSource();
        thread_ = std::thread([this] { run(); });
    }
    ~Presenter() {
        stop_ = true;
        thread_.join();
        source_ = nullptr;
    }
    /// The presentations from `from` on.
    std::vector<Presentation> since(SteadyClock::time_point from) const {
        std::lock_guard<std::mutex> lock(mutex_);
        std::vector<Presentation> out;
        for (const Presentation &p : log_) {
            if (p.at >= from) {
                out.push_back(p);
            }
        }
        return out;
    }
    void clear() {
        std::lock_guard<std::mutex> lock(mutex_);
        log_.clear();
    }

  private:
    void run() {
        render::PreviewFrame frame;
        while (!stop_) {
            render::PreviewFrameRequest request;
            request.textureCache = &textures_;
            if (source_(request, frame)) {
                const PresentedFrame presented = controller_.lastPresented();
                Presentation p;
                p.at = SteadyClock::now();
                p.frameIndex = presented.frameIndex;
                p.clockDriven = presented.clockDriven;
                p.exact = std::all_of(presented.layers.begin(), presented.layers.end(),
                                      [](const PresentedLayer &layer) { return layer.exact; });
                std::lock_guard<std::mutex> lock(mutex_);
                log_.push_back(p);
            }
            std::this_thread::sleep_for(std::chrono::microseconds(500));
        }
    }

    PlaybackController &controller_;
    render::TextureCache textures_;
    render::PreviewFrameSource source_;
    std::atomic<bool> stop_{false};
    mutable std::mutex mutex_;
    std::vector<Presentation> log_;
    std::thread thread_;
};

struct Start {
    double pictureMs = NAN; ///< Lateness of the first exact moving frame against the press.
    double audioMs = NAN;   ///< Press to Playing.
    uint64_t late = 0;      ///< Late presentations in the first second.
    uint64_t decoded = 0;   ///< Frames the clip's stream delivered from the release to the picture.
    uint64_t seeks = 0;     ///< Its seeks from the release to the picture.
    uint64_t seeksAfterPress = 0;
};

double percentile(std::vector<double> values, double p) {
    values.erase(std::remove_if(values.begin(), values.end(), [](double v) { return std::isnan(v); }), values.end());
    if (values.empty()) {
        return NAN;
    }
    std::sort(values.begin(), values.end());
    const size_t i = std::min(values.size() - 1, static_cast<size_t>(std::lround(p * double(values.size() - 1))));
    return values[i];
}

} // namespace

@interface PlayStartMeasurementTests : XCTestCase
@end

@implementation PlayStartMeasurementTests

- (void)testPlayStartAfterTheWaysThePlayheadComesToRest {
#if defined(__has_feature)
#if __has_feature(thread_sanitizer)
    XCTSkip(@"a wall-clock measurement is meaningless under ThreadSanitizer");
#endif
#endif
    const char *trialsVariable = getenv("FW_PLAYSTART_TRIALS");
    const int trials = std::max(1, trialsVariable ? atoi(trialsVariable) : 5);
    const char *only = getenv("FW_PLAYSTART_MEDIA");
    if (const char *generated = getenv("FW_PLAYSTART_FILE")) {
        std::string error;
        const std::string path = testMediaPath(generated, error);
        if (path.empty()) {
            XCTSkip(@"no test clip %s: %s", generated, error.c_str());
        }
        MeasureMedia media{generated, generated, {}, {}};
        [self measure:media path:path trials:trials];
        return;
    }
    for (const MeasureMedia &media : measureMedia()) {
        if (only && media.label.find(only) == std::string::npos) {
            continue;
        }
        std::string error;
        const std::string path = measurementMediaPath(media, error);
        if (path.empty()) {
            XCTSkip(@"no measurement media %s: %s", media.file.c_str(), error.c_str());
        }
        @autoreleasepool {
            [self measure:media path:path trials:trials];
        }
    }
}

- (void)measure:(const MeasureMedia &)media path:(const std::string &)path trials:(int)trials {
    // The machine's audio output (AVAudioEngine), as the app plays.
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 0.0,
                      [](PlaybackConfig &config) { config.makeOutput = nullptr; });
    const AssetId asset = h.importAssetAtPath(path);
    if (!h.ok()) {
        XCTFail(@"%s", h.error().c_str());
        return;
    }
    const MediaAsset &info = *h.project.findAsset(asset);
    const int64_t clipFrames = static_cast<int64_t>(std::floor(CMTimeGetSeconds(info.videoEnd()) * 30)) - 1;
    const ClipId clip = h.addClip(h.v1, asset, 0, clipFrames, kCMTimeZero);
    const ClipId sound = h.addClip(h.a1, asset, 0, clipFrames, kCMTimeZero);
    h.link(clip, sound);
    h.load();
    PlaybackController &controller = *h.controller;
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return controller.output().isRunning(); }), @"the output starts");
    Presenter presenter(controller);
    std::mt19937 random(20261003);
    std::uniform_int_distribution<int64_t> anywhere(15, clipFrames - 75);

    auto streamStats = [&]() -> media::DecodePool::StreamStats {
        for (const auto &stream : h.pool->stats().streams) {
            if (stream.lane == clip.value()) {
                return stream;
            }
        }
        return {};
    };
    auto waitForPicture = [&](int64_t frame) {
        PlaybackHarness::waitUntil([&] {
            const PresentedFrame p = controller.lastPresented();
            return p.frameIndex == frame && p.heldBackFrameIndex < 0 &&
                   std::all_of(p.layers.begin(), p.layers.end(), [](const PresentedLayer &l) { return l.exact; });
        });
    };
    // Parks the playhead somewhere else and lets everything settle (a user who was working there).
    auto park = [&](int64_t awayFrom) {
        int64_t elsewhere = anywhere(random);
        while (std::llabs(elsewhere - awayFrom) < 90) {
            elsewhere = anywhere(random);
        }
        controller.seek(frames30(elsewhere));
        waitForPicture(elsewhere);
        h.pool->waitUntilIdle(std::chrono::seconds(10));
        sleepMs(300);
        return elsewhere;
    };
    // Space at `start` (the playhead is there and its picture shown); `atRelease`: the stream's counts when the
    // playhead came to rest.
    auto press = [&](int64_t start, const media::DecodePool::StreamStats &atRelease) {
        Start result;
        const media::DecodePool::StreamStats beforePress = streamStats();
        const uint64_t lateBefore = controller.stats().lateFrames;
        const auto t0 = SteadyClock::now();
        controller.play();
        bool playing = false;
        bool pictured = false;
        while (msBetween(t0, SteadyClock::now()) < 3000 && !(playing && pictured)) {
            if (!playing && controller.state() == PlaybackState::Playing) {
                playing = true;
                result.audioMs = msBetween(t0, SteadyClock::now());
            }
            if (!pictured) {
                for (const Presentation &p : presenter.since(t0)) {
                    if (p.clockDriven && p.frameIndex > start && p.exact) {
                        pictured = true;
                        result.pictureMs = msBetween(t0, p.at) - double(p.frameIndex - start) * 1000.0 / 30.0;
                        const media::DecodePool::StreamStats now = streamStats();
                        result.decoded = now.framesDecoded - atRelease.framesDecoded;
                        result.seeks = now.seeks - atRelease.seeks;
                        result.seeksAfterPress = now.seeks - beforePress.seeks;
                        break;
                    }
                }
            }
            sleepMs(0.5);
        }
        const double remaining = 1000.0 - msBetween(t0, SteadyClock::now());
        if (remaining > 0) {
            sleepMs(remaining);
        }
        result.late = controller.stats().lateFrames - lateBefore;
        controller.pause();
        return result;
    };

    struct Case {
        std::string name;
        std::vector<Start> starts;
    };
    std::vector<Case> cases;
    auto record = [&](const std::string &name, const Start &start) {
        auto it = std::find_if(cases.begin(), cases.end(), [&](const Case &c) { return c.name == name; });
        if (it == cases.end()) {
            cases.push_back(Case{name, {}});
            it = cases.end() - 1;
        }
        it->starts.push_back(start);
    };

    for (int trial = 0; trial < trials; ++trial) {
        // Pause, then Space (the baseline: playing left its lookahead ahead of the playhead).
        {
            park(-1000);
            controller.play();
            sleepMs(1000);
            controller.pause();
            const media::DecodePool::StreamStats decoded = streamStats();
            const int64_t at = frameIndexAt(controller.currentTime(), CMTimeMake(1, 30), SnapMode::Floor);
            waitForPicture(at);
            sleepMs(300);
            record("pause, Space 300 ms later", press(at, decoded));
        }
        // A scrub released at a random point (60 Hz mouse moves over half a second), Space after a gap.
        for (double gap : {150.0, 400.0}) {
            const int64_t target = anywhere(random);
            const int64_t from = park(target);
            for (int step = 1; step <= 30; ++step) {
                const double f = double(from) + double(target - from) * step / 30.0;
                controller.scrubTo(frames30(static_cast<int64_t>(std::lround(f))));
                sleepMs(16);
            }
            controller.endScrub();
            const media::DecodePool::StreamStats decoded = streamStats();
            sleepMs(gap);
            waitForPicture(target);
            char name[96];
            snprintf(name, sizeof name, "scrub, Space %.0f ms after the release", gap);
            record(name, press(target, decoded));
        }
        // A ruler click (mouse down, up 90 ms later), Space after a gap.
        for (double gap : {150.0, 400.0}) {
            const int64_t target = anywhere(random);
            park(target);
            controller.scrubTo(frames30(target));
            sleepMs(90);
            controller.endScrub();
            const media::DecodePool::StreamStats decoded = streamStats();
            sleepMs(gap);
            waitForPicture(target);
            char name[96];
            snprintf(name, sizeof name, "ruler click, Space %.0f ms after the release", gap);
            record(name, press(target, decoded));
        }
        // L, L (2x), K, then Space.
        {
            const int64_t target = anywhere(random);
            park(target);
            controller.seek(frames30(std::max<int64_t>(0, target - 45)));
            waitForPicture(std::max<int64_t>(0, target - 45));
            controller.shuttleForward();
            sleepMs(700);
            controller.shuttleForward();
            sleepMs(400);
            controller.pause();
            const media::DecodePool::StreamStats decoded = streamStats();
            const int64_t at = frameIndexAt(controller.currentTime(), CMTimeMake(1, 30), SnapMode::Floor);
            waitForPicture(at);
            sleepMs(300);
            record("L, L, K, Space 300 ms later", press(at, decoded));
        }
    }

    NSLog(@"PLAY START MEASURE %s (%s; output %s, latency %.1f ms; %d starts per case)", media.label.c_str(),
          media.file.c_str(), controller.output().kind().c_str(), controller.output().outputLatency() * 1000, trials);
    for (const Case &c : cases) {
        std::vector<double> picture, audio, late, decoded, seeks, pressSeeks;
        for (const Start &s : c.starts) {
            picture.push_back(s.pictureMs);
            audio.push_back(s.audioMs);
            late.push_back(double(s.late));
            decoded.push_back(double(s.decoded));
            seeks.push_back(double(s.seeks));
            pressSeeks.push_back(double(s.seeksAfterPress));
        }
        NSLog(@"PLAY START MEASURE %s | %-44s | picture median %6.1f max %6.1f ms | audio median %6.1f max %6.1f ms | "
              @"late median %3.0f max %3.0f | decoded median %3.0f max %3.0f | seeks max %.0f, after the press max %.0f",
              media.label.c_str(), c.name.c_str(), percentile(picture, 0.5), percentile(picture, 1.0),
              percentile(audio, 0.5), percentile(audio, 1.0), percentile(late, 0.5), percentile(late, 1.0),
              percentile(decoded, 0.5), percentile(decoded, 1.0), percentile(seeks, 1.0), percentile(pressSeeks, 1.0));
    }
}

@end
