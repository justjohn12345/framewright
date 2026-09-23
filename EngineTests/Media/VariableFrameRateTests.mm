// Variable-frame-rate sources through both backends: vfr_h264.mp4 (irregular frame durations,
// B-frames) and its Matroska/WebM derivatives (DefaultDuration only, no timing metadata at
// all, BlockDurations, and an AV1 re-encode in WebM). The decoders must report every frame's
// real display interval, seek into a long frame must return that frame, and the probers must
// flag the track as VFR.

#import <XCTest/XCTest.h>

#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "BurnIn.h"
#include "FFmpegTestMedia.h"
#include "TestMedia.h"

#include <cmath>

using namespace ve::media;
using namespace ve::test;

namespace {

double sec(CMTime t) {
    return CMTimeGetSeconds(t);
}

struct VfrFile {
    std::string file;
    bool derived = false;
    /// Timestamp resolution of the container (Matroska/WebM: 1 ms), the tolerance for pts and
    /// duration comparisons.
    double tolerance = 1e-6;
    bool lossy = false; ///< Re-encoded: the burn-in is still readable, but only frames are compared.
    /// The container records how long the last frame lasts (ISO-BMFF: the edit list / track end).
    /// Matroska written without BlockDurations cannot: its DURATION tag is the last timestamp plus
    /// whatever duration the muxer assumed, so the decoder's last-frame duration follows it.
    bool lastDurationKnown = true;
};

std::vector<VfrFile> vfrFiles(bool appleOnly) {
    std::vector<VfrFile> files{{"vfr_h264.mp4", false, 1e-6, false, true}};
    if (!appleOnly) {
        files.push_back({"vfr_h264_defaultdur.mkv", true, 1.01e-3, false, false});
        files.push_back({"vfr_h264_nodefaultdur.mkv", true, 1.01e-3, false, false});
        files.push_back({"vfr_h264_blockdur.mkv", true, 1.01e-3, false, false});
        files.push_back({"vfr_av1.webm", true, 1.01e-3, true, false});
    }
    return files;
}

} // namespace

@interface VariableFrameRateTests : XCTestCase
@end

@implementation VariableFrameRateTests

- (void)setUp {
    self.continueAfterFailure = YES;
}

/// Path of a generated or derived file; XCTSkip when a tool-made file cannot be produced
/// because the ffmpeg command-line tool is missing, failure otherwise.
- (std::string)pathFor:(const VfrFile &)f {
    std::string error;
    const std::string path = f.derived ? derivedMediaPath(f.file, error) : testMediaPath(f.file, error);
    if (path.empty()) {
        if (f.derived && derivedNeedsTool(f.file) && ffmpegToolPath().empty()) {
            return {}; // Reported by the caller as a skip.
        }
        XCTFail(@"%s unavailable: %s", f.file.c_str(), error.c_str());
    }
    return path;
}

- (void)runOnBackend:(const std::shared_ptr<IMediaBackend> &)backend appleOnly:(bool)appleOnly {
    int skipped = 0;
    for (const VfrFile &f : vfrFiles(appleOnly)) {
        const std::string path = [self pathFor:f];
        if (path.empty()) {
            ++skipped;
            continue;
        }
        [self checkProbe:*backend path:path file:f];
        [self checkSequential:*backend path:path file:f];
        [self checkSeeks:*backend path:path file:f];
    }
    if (skipped > 0) {
        XCTSkip(@"%d tool-made VFR files skipped: ThirdParty/ffmpeg/tools/bin/ffmpeg is not built", skipped);
    }
}

- (void)checkProbe:(IMediaBackend &)backend path:(const std::string &)path file:(const VfrFile &)f {
    auto info = backend.makeProber()->probe(path);
    XCTAssertTrue(info.ok(), @"%s: %s", f.file.c_str(), info.ok() ? "" : info.error().description().c_str());
    if (!info.ok()) {
        return;
    }
    const TrackInfo *v = info->firstTrack(TrackKind::Video);
    XCTAssertTrue(v != nullptr);
    if (v == nullptr) {
        return;
    }
    XCTAssertTrue(v->isVFR, @"%s (%s): isVFR", f.file.c_str(), backend.name().c_str());
    // frameDuration of a VFR track is its shortest frame: 10/600 s (in 1 ms steps for Matroska).
    XCTAssertLessThanOrEqual(std::fabs(sec(v->frameDuration) - 10.0 / 600), f.tolerance + 1e-9,
                             @"%s (%s): frameDuration %.6f", f.file.c_str(), backend.name().c_str(),
                             sec(v->frameDuration));
}

- (void)checkSequential:(IMediaBackend &)backend path:(const std::string &)path file:(const VfrFile &)f {
    auto decoder = backend.makeVideoDecoder();
    Status s = decoder->open(path, -1, DecodeOptions{});
    XCTAssertTrue(s.ok(), @"%s: %s", f.file.c_str(), s.ok() ? "" : s.error().description().c_str());
    if (!s.ok()) {
        return;
    }
    int mismatches = 0;
    for (int i = 0; i < kVfrFrames; ++i) {
        auto r = decoder->next();
        if (!r.ok() || !r.value()) {
            XCTFail(@"%s (%s): frame %d: %s", f.file.c_str(), backend.name().c_str(), i,
                    r.ok() ? "end of stream" : r.error().description().c_str());
            return;
        }
        const VideoFrame &frame = *r.value();
        const double wantPts = sec(vfrFrameTime(i));
        const double wantDur = sec(vfrFrameTime(i + 1)) - wantPts;
        const std::optional<int> burnIn = readBurnIn(frame.image.get());
        const bool checkDuration = i + 1 < kVfrFrames || f.lastDurationKnown;
        if (burnIn != i || std::fabs(sec(frame.pts) - wantPts) > f.tolerance ||
            (checkDuration && std::fabs(sec(frame.duration) - wantDur) > 2 * f.tolerance) ||
            !(sec(frame.duration) > 0)) {
            if (++mismatches <= 5) {
                XCTFail(@"%s (%s): frame %d: burn-in %d pts %.4f duration %.4f, wanted pts %.4f duration %.4f",
                        f.file.c_str(), backend.name().c_str(), i, burnIn.value_or(-1), sec(frame.pts),
                        sec(frame.duration), wantPts, wantDur);
            }
        }
    }
    XCTAssertEqual(mismatches, 0, @"%s (%s): frames with wrong pts/duration/burn-in", f.file.c_str(),
                   backend.name().c_str());
    auto end = decoder->next();
    XCTAssertTrue(end.ok() && !end.value(), @"%s: end of stream after %d frames", f.file.c_str(), kVfrFrames);
}

- (void)checkSeeks:(IMediaBackend &)backend path:(const std::string &)path file:(const VfrFile &)f {
    auto decoder = backend.makeVideoDecoder();
    Status s = decoder->open(path, -1, DecodeOptions{});
    if (!s.ok()) {
        return; // Reported by checkSequential.
    }
    // Into every long frame (>= 0.1 s), 80 % of the way through, in a scrambled order so both
    // forward (close-ahead) and backward seeks happen; then times near the end of short frames.
    std::vector<double> targets;
    for (int i = 0; i < kVfrFrames; ++i) {
        const double a = sec(vfrFrameTime(i));
        const double b = sec(vfrFrameTime(i + 1));
        if (b - a >= 0.099) {
            targets.push_back(a + 0.8 * (b - a));
        }
    }
    for (size_t k = 0; k + 1 < targets.size(); k += 2) {
        std::swap(targets[k], targets[k + 1]);
    }
    for (int i : {3, 17, 58, 99, 140}) {
        const double a = sec(vfrFrameTime(i));
        const double b = sec(vfrFrameTime(i + 1));
        targets.push_back(b - std::max(0.25 * (b - a), 2 * f.tolerance));
    }
    for (double t : targets) {
        const CMTime at = CMTimeMakeWithSeconds(t, 600000);
        const int want = vfrFrameAt(at);
        s = decoder->seek(at);
        XCTAssertTrue(s.ok());
        auto r = decoder->next();
        XCTAssertTrue(r.ok() && r.value(), @"%s: seek(%.4f)", f.file.c_str(), t);
        if (!r.ok() || !r.value()) {
            continue;
        }
        const VideoFrame &frame = *r.value();
        XCTAssertEqual(readBurnIn(frame.image.get()), std::optional<int>(want),
                       @"%s (%s): seek(%.4f) must return frame %d [%.4f, %.4f), got pts %.4f duration %.4f",
                       f.file.c_str(), backend.name().c_str(), t, want, sec(vfrFrameTime(want)),
                       sec(vfrFrameTime(want + 1)), sec(frame.pts), sec(frame.duration));
        XCTAssertTrue(frame.contains(at), @"%s (%s): the returned frame [%.4f + %.4f) must contain %.4f",
                      f.file.c_str(), backend.name().c_str(), sec(frame.pts), sec(frame.duration), t);
    }
}

- (void)testAppleBackendDecodesVariableFrameRateMP4 {
    [self runOnBackend:apple::makeAppleBackend() appleOnly:true];
}

- (void)testFFmpegBackendDecodesVariableFrameRateInEveryContainer {
    [self runOnBackend:ffmpeg::makeFFmpegBackend() appleOnly:false];
}

@end
