#include "FFmpegTestMedia.h"

#include "../../Engine/Media/FFmpeg/FFRemux.h"

#import <Foundation/Foundation.h>

#include <filesystem>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>
#include <unistd.h>
#include <vector>

namespace ve::test {

namespace fs = std::filesystem;

namespace {

/// Bump when the remux changes so cached copies are regenerated.
constexpr int kRemuxVersion = 1;

} // namespace

bool remuxToMatroska(const std::string &source, const std::string &destination, std::string &error) {
    const ve::media::Status s = ve::media::ffmpeg::remux(source, destination, "matroska");
    if (!s.ok()) {
        error = s.error().description();
    }
    return s.ok();
}

const std::vector<TestClip> &mkvTestClips() {
    static const std::vector<TestClip> clips = [] {
        std::vector<TestClip> c;
        for (const char *name : {"h264_1080p30.mp4", "hevc_720p2997.mov"}) {
            TestClip clip = testClip(name);
            clip.file = clip.file.substr(0, clip.file.rfind('.')) + ".mkv";
            clip.container = "mkv";
            c.push_back(clip);
        }
        return c;
    }();
    return clips;
}

std::string mkvTestMediaDirectory(std::string &error) {
    static std::once_flag once;
    static std::string dir;
    static std::string failure;
    std::call_once(once, [] {
        std::string mediaError;
        const std::string media = testMediaDirectory(mediaError);
        if (media.empty()) {
            failure = mediaError;
            return;
        }
        const fs::path target = fs::path(media).string() + "-mkv" + std::to_string(kRemuxVersion);
        std::error_code ec;
        bool complete = true;
        for (const TestClip &clip : mkvTestClips()) {
            complete = complete && fs::exists(target / clip.file, ec);
        }
        if (complete) {
            dir = target.string();
            return;
        }
        const fs::path tmp = target.string() + ".tmp-" + std::to_string(getpid());
        fs::remove_all(tmp, ec);
        fs::create_directories(tmp, ec);
        for (const char *name : {"h264_1080p30.mp4", "hevc_720p2997.mov"}) {
            const std::string file = std::string(name);
            const std::string mkv = file.substr(0, file.rfind('.')) + ".mkv";
            std::string remuxError;
            if (!remuxToMatroska((fs::path(media) / file).string(), (tmp / mkv).string(), remuxError)) {
                failure = "remux " + file + ": " + remuxError;
                fs::remove_all(tmp, ec);
                return;
            }
        }
        fs::remove_all(target, ec);
        fs::rename(tmp, target, ec);
        if (ec) {
            fs::remove_all(tmp, ec); // Another process won the race; use theirs.
        }
        dir = target.string();
    });
    error = failure;
    return dir;
}

// MARK: - Derived special-purpose media

namespace {

struct Recipe {
    std::string file;
    std::string source; ///< A generated clip (TestMedia.h).
    bool tool = false;  ///< Made with the ffmpeg command-line tool (else ffmpeg::remux).
    std::string format; ///< remux: libavformat muxer.
    ve::media::ffmpeg::RemuxOptions options;
    std::vector<std::string> args; ///< tool: arguments between "-i <source>" and the output path.
};

const std::vector<Recipe> &recipes() {
    static const std::vector<Recipe> list = [] {
        using Args = std::vector<std::string>;
        std::vector<Recipe> r;
        auto remux = [&](const char *file, const char *source, bool frameRate, bool durations) {
            Recipe x;
            x.file = file;
            x.source = source;
            x.format = "matroska";
            x.options.frameRate = frameRate;
            x.options.packetDurations = durations;
            r.push_back(x);
        };
        auto tool = [&](const char *file, const char *source, Args args) {
            Recipe x;
            x.file = file;
            x.source = source;
            x.tool = true;
            x.args = std::move(args);
            r.push_back(x);
        };
        remux("vfr_h264_defaultdur.mkv", "vfr_h264.mp4", true, false);
        remux("vfr_h264_nodefaultdur.mkv", "vfr_h264.mp4", false, false);
        remux("vfr_h264_blockdur.mkv", "vfr_h264.mp4", true, true);
        remux("rotated90_h264.mkv", "rotated90_h264.mp4", true, true);
        const Args av1 = {"-c:v", "libsvtav1", "-preset", "10", "-crf", "28", "-g", "30", "-pix_fmt", "yuv420p"};
        auto with = [](Args a, const Args &b) {
            a.insert(a.end(), b.begin(), b.end());
            return a;
        };
        tool("vfr_av1.webm", "vfr_h264.mp4", with(with({"-an"}, av1), {"-fps_mode", "passthrough", "-f", "webm"}));
        tool("av1_640.mp4", "h264_1080p30.mp4", with(with({"-t", "4", "-an", "-vf", "scale=640:360"}, av1), {"-f", "mp4"}));
        tool("av1_640.webm", "h264_1080p30.mp4", with(with({"-t", "4", "-an", "-vf", "scale=640:360"}, av1), {"-f", "webm"}));
        tool("asp_mpeg4.mp4", "h264_1080p30.mp4",
             {"-t", "4", "-vf", "scale=640:360", "-c:v", "mpeg4", "-q:v", "2", "-bf", "2", "-g", "30", "-c:a", "copy",
              "-f", "mp4"});
        tool("opus.webm", "audio_only.wav", {"-c:a", "opus", "-strict", "-2", "-b:a", "160k", "-f", "webm"});
        tool("vorbis.mkv", "audio_only.wav", {"-c:a", "vorbis", "-strict", "-2", "-q:a", "6", "-f", "matroska"});
        tool("flac.mp4", "audio_only.wav", {"-c:a", "flac", "-strict", "-2", "-f", "mp4"});
        tool("aac_adts.aac", "audio_only.m4a", {"-c:a", "copy", "-f", "adts"});
        tool("h264_offset.ts", "h264_1080p30.mp4",
             {"-c", "copy", "-bsf:v", "h264_mp4toannexb", "-output_ts_offset", "10", "-f", "mpegts"});
        tool("live_no_duration.mkv", "h264_1080p30.mp4", {"-c", "copy", "-live", "1", "-f", "matroska"});
        tool("audio_gap.mkv", "audio_only.wav",
             {"-t", "6", "-c:a", "pcm_s16le", "-bsf:a", "setts=ts=if(gte(PTS\\,144000)\\,PTS+28800000\\,PTS)", "-f",
              "matroska"});
        return r;
    }();
    return list;
}

const Recipe *findRecipe(const std::string &file) {
    for (const Recipe &r : recipes()) {
        if (r.file == file) {
            return &r;
        }
    }
    return nullptr;
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

std::string readFile(const fs::path &path) {
    std::ifstream in(path, std::ios::binary);
    std::stringstream s;
    s << in.rdbuf();
    return s.str();
}

/// Runs the tool; returns "" on success, else its output.
std::string runTool(const std::string &tool, const std::vector<std::string> &args) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@(tool.c_str())];
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    for (const std::string &arg : args) {
        [a addObject:@(arg.c_str())];
    }
    task.arguments = a;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        return "cannot launch " + tool + ": " + error.localizedDescription.UTF8String;
    }
    NSData *output = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding];
        return "ffmpeg exited with " + std::to_string(task.terminationStatus) + ": " + (text ? text.UTF8String : "");
    }
    return {};
}

struct DerivedState {
    std::string dir;
    std::map<std::string, std::string> failures; ///< file -> reason.
    std::string setupError;
};

const DerivedState &derivedState() {
    static const DerivedState state = [] {
        DerivedState st;
        std::string mediaError;
        const std::string media = testMediaDirectory(mediaError);
        if (media.empty()) {
            st.setupError = mediaError;
            return st;
        }
        const std::string tool = ffmpegToolPath();
        // Key: every recipe, and the tool build (a rebuilt tool may encode differently).
        std::string key = "derived-v1\n";
        for (const Recipe &r : recipes()) {
            key += r.file + "|" + r.source + "|" + (r.tool ? "tool" : "remux:" + r.format) + "|" +
                   std::to_string(r.options.frameRate) + std::to_string(r.options.packetDurations);
            for (const std::string &a : r.args) {
                key += " " + a;
            }
            key += "\n";
        }
        if (!tool.empty()) {
            key += readFile(fs::path(tool).parent_path().parent_path().parent_path() / ".build-stamp");
        }
        const fs::path target = media + "-derived-" + fnv1a64Hex(key);
        std::error_code ec;
        if (fs::exists(target / "complete", ec)) {
            st.dir = target.string();
            for (const Recipe &r : recipes()) {
                if (!fs::exists(target / r.file, ec)) {
                    st.failures[r.file] = r.tool && tool.empty() ? "the ffmpeg command-line tool was not built"
                                                                 : "not generated (see the first run's log)";
                }
            }
            return st;
        }
        const fs::path tmp = target.string() + ".tmp-" + std::to_string(getpid());
        fs::remove_all(tmp, ec);
        fs::create_directories(tmp, ec);
        for (const Recipe &r : recipes()) {
            const std::string source = (fs::path(media) / r.source).string();
            const std::string out = (tmp / r.file).string();
            if (r.tool) {
                if (tool.empty()) {
                    st.failures[r.file] = "the ffmpeg command-line tool was not built (Scripts/build-ffmpeg.sh, BUILD_TOOLS=1)";
                    continue;
                }
                std::vector<std::string> args = {"-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", source};
                args.insert(args.end(), r.args.begin(), r.args.end());
                args.push_back(out);
                const std::string failure = runTool(tool, args);
                if (!failure.empty()) {
                    st.failures[r.file] = failure;
                    fs::remove(out, ec);
                }
            } else {
                const ve::media::Status s = ve::media::ffmpeg::remux(source, out, r.format, r.options);
                if (!s.ok()) {
                    st.failures[r.file] = s.error().description();
                }
            }
        }
        std::ofstream(tmp / "complete") << "ok\n";
        fs::remove_all(target, ec);
        fs::rename(tmp, target, ec);
        if (ec) {
            fs::remove_all(tmp, ec); // Another process won the race; use theirs.
        }
        st.dir = target.string();
        return st;
    }();
    return state;
}

} // namespace

std::string ffmpegToolPath() {
    // EngineTests/Media/FFmpegTestMedia.mm -> repository root.
    const fs::path tool = fs::path(__FILE__).parent_path().parent_path().parent_path() / "ThirdParty" / "ffmpeg" /
                          "tools" / "bin" / "ffmpeg";
    std::error_code ec;
    return fs::exists(tool, ec) ? tool.string() : std::string();
}

bool derivedNeedsTool(const std::string &file) {
    const Recipe *r = findRecipe(file);
    return r != nullptr && r->tool;
}

std::string derivedMediaPath(const std::string &file, std::string &error) {
    if (findRecipe(file) == nullptr) {
        error = "no recipe for " + file;
        return {};
    }
    const DerivedState &st = derivedState();
    if (st.dir.empty()) {
        error = st.setupError;
        return {};
    }
    if (auto it = st.failures.find(file); it != st.failures.end()) {
        error = file + ": " + it->second;
        return {};
    }
    return (fs::path(st.dir) / file).string();
}

} // namespace ve::test
