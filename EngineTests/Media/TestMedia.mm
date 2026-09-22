#include "TestMedia.h"

#import <Foundation/Foundation.h>

#include "../../Engine/Media/MediaTypes.h"

#include <mach/mach.h>

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>

/// Anchors NSBundle lookup of the test bundle.
@interface VETestMediaAnchor : NSObject
@end
@implementation VETestMediaAnchor
@end

namespace ve::test {

namespace fs = std::filesystem;
using ve::media::fourcc::make;

const std::vector<TestClip> &testClips() {
    static const std::vector<TestClip> clips = [] {
        std::vector<TestClip> c;
        TestClip h264;
        h264.file = "h264_1080p30.mp4";
        h264.container = "mp4";
        h264.videoCodec = make("avc1");
        h264.width = 1920;
        h264.height = 1080;
        h264.frameDuration = CMTimeMake(1, 30);
        h264.frames = 300;
        h264.gopFrames = 30;
        h264.audioCodec = make("aac ");
        h264.toneHz = 440;
        h264.audioSeconds = 10;
        c.push_back(h264);

        TestClip hevc;
        hevc.file = "hevc_720p2997.mov";
        hevc.container = "mov";
        hevc.videoCodec = make("hvc1");
        hevc.width = 1280;
        hevc.height = 720;
        hevc.frameDuration = CMTimeMake(1001, 30000);
        hevc.frames = 300;
        hevc.gopFrames = 60;
        hevc.audioCodec = make("aac ");
        hevc.toneHz = 550;
        hevc.audioSeconds = 300 * 1001 / 30000.0;
        c.push_back(hevc);

        TestClip prores;
        prores.file = "prores_540p25.mov";
        prores.container = "mov";
        prores.videoCodec = make("apcn");
        prores.width = 960;
        prores.height = 540;
        prores.frameDuration = CMTimeMake(1, 25);
        prores.frames = 75;
        prores.audioCodec = make("lpcm");
        prores.toneHz = 660;
        prores.audioSeconds = 3;
        c.push_back(prores);

        TestClip m4a;
        m4a.file = "audio_only.m4a";
        m4a.container = "m4a";
        m4a.audioCodec = make("aac ");
        m4a.toneHz = 330;
        m4a.audioSeconds = 10;
        c.push_back(m4a);

        TestClip wav;
        wav.file = "audio_only.wav";
        wav.container = "wav";
        wav.audioCodec = make("lpcm");
        wav.toneHz = 770;
        wav.audioSeconds = 10;
        c.push_back(wav);

        TestClip png;
        png.file = "still.png";
        png.container = "png";
        png.videoCodec = make("png ");
        png.width = 1280;
        png.height = 720;
        png.stillIndex = 0x1234;
        c.push_back(png);

        TestClip heic;
        heic.file = "still.heic";
        heic.container = "heic";
        heic.videoCodec = make("heic");
        heic.width = 1024;
        heic.height = 576;
        heic.stillIndex = 0xBEEF;
        c.push_back(heic);
        return c;
    }();
    return clips;
}

const TestClip &testClip(const std::string &file) {
    for (const TestClip &c : testClips()) {
        if (c.file == file) {
            return c;
        }
    }
    static const TestClip none;
    return none;
}

namespace {

fs::path scriptPath() {
    // EngineTests/Media/TestMedia.mm -> repository root.
    return fs::path(__FILE__).parent_path().parent_path().parent_path() / "Scripts" / "make_test_media.swift";
}

std::string fnv1a64Hex(const std::string &data) {
    uint64_t h = 1469598103934665603ull;
    for (unsigned char ch : data) {
        h ^= ch;
        h *= 1099511628211ull;
    }
    char buf[17];
    snprintf(buf, sizeof buf, "%016llx", static_cast<unsigned long long>(h));
    return buf;
}

std::string generate(std::string &error) {
    if (const char *overrideDir = getenv("VIDEDIT_TEST_MEDIA_DIR")) {
        return overrideDir;
    }
    const fs::path script = scriptPath();
    std::ifstream in(script, std::ios::binary);
    if (!in) {
        error = "cannot read " + script.string();
        return {};
    }
    std::stringstream contents;
    contents << in.rdbuf();
    // <build>/Products/Debug/EngineTests.xctest -> <build>/VidEditTestMedia/<hash>
    NSURL *bundle = [NSBundle bundleForClass:VETestMediaAnchor.class].bundleURL;
    const fs::path buildDir = fs::path(bundle.path.UTF8String).parent_path().parent_path().parent_path();
    const fs::path dir = buildDir / "VidEditTestMedia" / fnv1a64Hex(contents.str());
    std::error_code ec;
    if (fs::exists(dir / "manifest.json", ec)) {
        return dir.string();
    }
    fs::create_directories(dir.parent_path(), ec);
    const fs::path tmp = dir.string() + ".tmp-" + std::to_string(getpid());
    fs::remove_all(tmp, ec);
    const fs::path log = tmp.string() + ".log";

    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    task.arguments = @[ @"swift", @(script.c_str()), @(tmp.c_str()) ];
    [NSFileManager.defaultManager createFileAtPath:@(log.c_str()) contents:nil attributes:nil];
    NSFileHandle *logHandle = [NSFileHandle fileHandleForWritingAtPath:@(log.c_str())];
    task.standardOutput = logHandle;
    task.standardError = logHandle;
    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        error = "cannot run xcrun swift: " + std::string(launchError.localizedDescription.UTF8String);
        return {};
    }
    [task waitUntilExit];
    [logHandle closeFile];
    if (task.terminationStatus != 0) {
        std::ifstream logIn(log);
        std::stringstream logText;
        logText << logIn.rdbuf();
        error = "make_test_media.swift failed (" + std::to_string(task.terminationStatus) + "): " + logText.str();
        return {};
    }
    fs::remove(log, ec);
    fs::rename(tmp, dir, ec);
    if (ec) {
        // Another process generated it concurrently; use theirs.
        fs::remove_all(tmp, ec);
    }
    if (!fs::exists(dir / "manifest.json", ec)) {
        error = "generated media missing in " + dir.string();
        return {};
    }
    return dir.string();
}

} // namespace

std::string testMediaDirectory(std::string &error) {
    static std::once_flag once;
    static std::string dir;
    static std::string generationError;
    std::call_once(once, [] { dir = generate(generationError); });
    error = generationError;
    return dir;
}

std::string testMediaPath(const std::string &file, std::string &error) {
    const std::string dir = testMediaDirectory(error);
    return dir.empty() ? std::string() : (fs::path(dir) / file).string();
}

std::string scratchDirectory() {
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:@"VidEditEngineTests"];
    NSString *dir = [base stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir.UTF8String;
}

uint64_t physicalFootprint() {
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) {
        return 0;
    }
    return info.phys_footprint;
}

} // namespace ve::test
