#include "FFmpegTestMedia.h"

#include "../../Engine/Media/FFmpeg/FFRemux.h"

#include <filesystem>
#include <mutex>
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

} // namespace ve::test
