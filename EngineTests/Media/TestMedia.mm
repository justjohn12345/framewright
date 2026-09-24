#include "TestMedia.h"

#import <Foundation/Foundation.h>

#include "../../Engine/Media/MediaTypes.h"

#include <mach/mach.h>

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
#include <vector>

/// Anchors NSBundle lookup of the test bundle.
@interface VETestMediaAnchor : NSObject
@end
@implementation VETestMediaAnchor
@end

namespace ve::test {

namespace fs = std::filesystem;
using ve::media::fourcc::make;

namespace {
/// The script's hash inside a generated media directory.
constexpr const char *kScriptHashFile = ".script-hash";
} // namespace

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

namespace {

const std::vector<TestClip> &specialClips() {
    static const std::vector<TestClip> clips = [] {
        std::vector<TestClip> c;
        auto video = [&](const char *file, const char *container, uint32_t codec, int w, int h, CMTime fd,
                         int frames, int gop) {
            TestClip clip;
            clip.file = file;
            clip.container = container;
            clip.videoCodec = codec;
            clip.width = w;
            clip.height = h;
            clip.frameDuration = fd;
            clip.frames = frames;
            clip.gopFrames = gop;
            c.push_back(clip);
        };
        // frameDuration of the VFR clip: its shortest frame (10/600 s), as TrackInfo reports it.
        video("vfr_h264.mp4", "mp4", make("avc1"), 640, 360, CMTimeMake(10, 600), kVfrFrames, 30);
        video("rotated90_h264.mp4", "mp4", make("avc1"), 640, 360, CMTimeMake(1, 30), 30, 30);
        video("slowmo_hevc_portrait.mov", "mov", make("hvc1"), 640, 360, CMTimeMake(1, 240), kSlowmoFrames, 30);
        video("gop5s_h264_1080p30.mp4", "mp4", make("avc1"), 1920, 1080, CMTimeMake(1, 30), 300, 150);
        video("leading_gap_h264.mov", "mov", make("avc1"), 640, 360, CMTimeMake(1, 30), 60, 30);
        video("prores4444_alpha.mov", "mov", make("ap4h"), 576, 324, CMTimeMake(1, 25), 10, 0);
        auto audio = [&](const char *file, const char *container, uint32_t codec, double hz, double seconds) {
            TestClip clip;
            clip.file = file;
            clip.container = container;
            clip.audioCodec = codec;
            clip.toneHz = hz;
            clip.audioSeconds = seconds;
            c.push_back(clip);
        };
        audio("audio_44k.m4a", "m4a", make("aac "), 880, 6);
        audio("audio_44k.wav", "wav", make("lpcm"), 990, 6);
        audio("audio_mono.m4a", "m4a", make("aac "), 660, 4);
        audio("audio_51.m4a", "m4a", make("aac "), 520, 4);
        return c;
    }();
    return clips;
}

} // namespace

const TestClip &testClip(const std::string &file) {
    for (const auto *list : {&testClips(), &specialClips()}) {
        for (const TestClip &c : *list) {
            if (c.file == file) {
                return c;
            }
        }
    }
    static const TestClip none;
    return none;
}

CMTime vfrFrameTime(int index) {
    int64_t t = 0;
    constexpr int n = static_cast<int>(sizeof kVfrPattern600 / sizeof kVfrPattern600[0]);
    for (int i = 0; i < index; ++i) {
        t += kVfrPattern600[i % n];
    }
    return CMTimeMake(t, 600);
}

int vfrFrameAt(CMTime t) {
    for (int i = 0; i < kVfrFrames; ++i) {
        if (CMTimeCompare(t, vfrFrameTime(i + 1)) < 0) {
            return i;
        }
    }
    return kVfrFrames; // At or past the end.
}

CMTime slowmoFrameTime(int index) {
    int64_t ticks = 0; // 1/960 s
    for (int i = 0; i < index; ++i) {
        ticks += (i >= 30 && i < 150) ? 4 : 32;
    }
    return CMTimeMake(ticks, 960);
}

int slowmoFrameAt(CMTime t) {
    for (int i = 0; i < kSlowmoFrames; ++i) {
        if (CMTimeCompare(t, slowmoFrameTime(i + 1)) < 0) {
            return i;
        }
    }
    return kSlowmoFrames;
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

/// Generates the media into `dir` (replacing what is there): the script writes into a temporary
/// directory beside it, which is renamed into place with the script's hash inside.
bool generateInto(const fs::path &dir, const fs::path &script, const std::string &hash, std::string &error) {
    std::error_code ec;
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
        return false;
    }
    [task waitUntilExit];
    [logHandle closeFile];
    if (task.terminationStatus != 0) {
        std::ifstream logIn(log);
        std::stringstream logText;
        logText << logIn.rdbuf();
        error = "make_test_media.swift failed (" + std::to_string(task.terminationStatus) + "): " + logText.str();
        return false;
    }
    fs::remove(log, ec);
    std::ofstream(tmp / kScriptHashFile) << hash;
    if (fs::exists(dir, ec) && !testMediaIsComplete(dir.string(), hash)) {
        fs::remove_all(dir, ec); // an incomplete or outdated copy is replaced
    }
    fs::rename(tmp, dir, ec);
    if (ec) {
        // Another process generated it concurrently; use theirs.
        fs::remove_all(tmp, ec);
    }
    if (!testMediaIsComplete(dir.string(), hash)) {
        error = "generated media missing in " + dir.string();
        return false;
    }
    return true;
}

std::string generate(std::string &error) {
    const fs::path script = scriptPath();
    std::ifstream in(script, std::ios::binary);
    if (!in) {
        error = "cannot read " + script.string();
        return {};
    }
    std::stringstream contents;
    contents << in.rdbuf();
    const std::string hash = fnv1a64Hex(contents.str());
    if (const char *overrideDir = getenv("FRAMEWRIGHT_TEST_MEDIA_DIR")) {
        // A directory the developer chose: used when it is complete and made by this script, else
        // regenerated into it.
        if (testMediaIsComplete(overrideDir, hash)) {
            return overrideDir;
        }
        std::string why;
        if (!generateInto(overrideDir, script, hash, why)) {
            error = "FRAMEWRIGHT_TEST_MEDIA_DIR=" + std::string(overrideDir) +
                    " lacks a file of the current Scripts/make_test_media.swift (or was made by an earlier "
                    "version) and could not be regenerated there: " +
                    why + ". Unset FRAMEWRIGHT_TEST_MEDIA_DIR, or delete that directory so it is made again.";
            return {};
        }
        return overrideDir;
    }
    // <build>/Products/Debug/EngineTests.xctest -> <build>/FramewrightTestMedia/<hash>
    NSURL *bundle = [NSBundle bundleForClass:VETestMediaAnchor.class].bundleURL;
    const fs::path buildDir = fs::path(bundle.path.UTF8String).parent_path().parent_path().parent_path();
    const fs::path dir = buildDir / "FramewrightTestMedia" / hash;
    if (testMediaIsComplete(dir.string(), hash)) {
        return dir.string();
    }
    if (!generateInto(dir, script, hash, error)) {
        return {};
    }
    pruneTestMediaVersions(dir.string());
    return dir.string();
}

} // namespace

/// Media directories of earlier versions of the script beside `current` (named by their hash,
/// alone or as the prefix of media derived from them, "<hash>-..."): removed, so the build folder
/// does not grow with every change of the script.
void pruneTestMediaVersions(const std::string &currentDirectory) {
    const fs::path current(currentDirectory);
    std::error_code ec;
    const std::string hash = current.filename().string();
    std::vector<fs::path> stale;
    for (const auto &entry : fs::directory_iterator(current.parent_path(), ec)) {
        const std::string name = entry.path().filename().string();
        const std::string prefix = name.substr(0, 16);
        const bool hashNamed = prefix.size() == 16 && prefix.find_first_not_of("0123456789abcdef") == std::string::npos &&
                               (name.size() == 16 || name[16] == '-');
        if (hashNamed && prefix != hash) {
            stale.push_back(entry.path());
        }
    }
    for (const fs::path &path : stale) {
        fs::remove_all(path, ec);
    }
}

bool testMediaIsComplete(const std::string &directory, const std::string &scriptHash) {
    const fs::path dir(directory);
    std::ifstream hashIn(dir / kScriptHashFile);
    std::string stored;
    if (!hashIn || !(hashIn >> stored) || stored != scriptHash) {
        return false;
    }
    NSData *data = [NSData dataWithContentsOfFile:@((dir / "manifest.json").c_str())];
    NSDictionary *manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *files = [manifest isKindOfClass:NSDictionary.class] ? manifest[@"files"] : nil;
    if (![files isKindOfClass:NSArray.class] || files.count == 0) {
        return false;
    }
    std::error_code ec;
    for (NSDictionary *entry in files) {
        NSString *name = [entry isKindOfClass:NSDictionary.class] ? entry[@"file"] : nil;
        if (![name isKindOfClass:NSString.class] || !fs::exists(dir / name.UTF8String, ec)) {
            return false;
        }
    }
    return true;
}

std::string testMediaScriptHash() {
    std::ifstream in(scriptPath(), std::ios::binary);
    std::stringstream contents;
    contents << in.rdbuf();
    return fnv1a64Hex(contents.str());
}

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
    NSString *base = [NSTemporaryDirectory() stringByAppendingPathComponent:@"FramewrightEngineTests"];
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
