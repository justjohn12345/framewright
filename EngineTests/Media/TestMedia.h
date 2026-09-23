// The generated conformance media: descriptions of what Scripts/make_test_media.swift writes
// and a cached, self-generating location for the files.
#pragma once

#include <CoreMedia/CoreMedia.h>

#include <cstdint>
#include <string>
#include <vector>

namespace ve::test {

struct TestClip {
    std::string file;
    std::string container; ///< Expected MediaInfo::container.
    // Video (frames > 0) or still (stillIndex >= 0).
    uint32_t videoCodec = 0;
    int width = 0;
    int height = 0;
    CMTime frameDuration = kCMTimeInvalid;
    int frames = 0;
    int stillIndex = -1;
    int gopFrames = 0; ///< Keyframe interval written (0 = every frame is a keyframe or unknown).
    // Audio.
    uint32_t audioCodec = 0;
    double toneHz = 0;
    double audioSeconds = 0;

    bool hasVideo() const { return frames > 0; }
    bool isStill() const { return stillIndex >= 0; }
    bool hasAudio() const { return audioCodec != 0; }
    CMTime videoDuration() const { return CMTimeMultiply(frameDuration, frames); }
};

/// The conformance clips (constant frame rate, unrotated), in generation order. The suite in
/// MediaBackendConformanceTests runs over these.
const std::vector<TestClip> &testClips();
/// Any generated clip by file name: the conformance clips and the special-purpose ones below.
const TestClip &testClip(const std::string &file);

// Special-purpose clips (not in testClips()):
//   vfr_h264.mp4            640x360 H.264 with B-frames, 150 frames whose durations cycle through
//                           kVfrPattern600 (1/600 s units); keyframe every 30 frames.
//   rotated90_h264.mp4      640x360 stored, displayed rotated 90 degrees clockwise; 30 frames 30 fps.
//   gop5s_h264_1080p30.mp4  1920x1080 H.264, 300 frames, keyframe every 150 frames (5 s).
//   leading_gap_h264.mov    640x360 H.264, 60 frames at 30 fps, the first presented at 0.5 s.
//   prores4444_alpha.mov    576x324 ProRes 4444, 10 frames at 25 fps; the left half has alpha 128
//                           with straight colour.
//   audio_44k.m4a / .wav    44.1 kHz stereo AAC (880 Hz) / PCM (990 Hz), 6 s, beep at 2 s.
//   audio_mono.m4a          48 kHz mono AAC, 660 Hz, 4 s.   audio_51.m4a  48 kHz 5.1 AAC, 520 Hz, 4 s.

/// Durations of consecutive frames of vfr_h264.mp4 in 1/600 s, repeating (keep in sync with
/// Scripts/make_test_media.swift).
inline constexpr int64_t kVfrPattern600[] = {20, 20, 60, 20, 10, 10, 20, 100, 20, 30, 20, 15};
inline constexpr int kVfrFrames = 150;
/// Presentation time of frame `index` of vfr_h264.mp4 (index == kVfrFrames gives the end).
CMTime vfrFrameTime(int index);
/// Index of the vfr_h264.mp4 frame containing `t` (the frame with time(i) <= t < time(i + 1)).
int vfrFrameAt(CMTime t);

/// Directory holding the generated files. Generates them on first use by running
/// `xcrun swift Scripts/make_test_media.swift` into <build dir>/FramewrightTestMedia/<script hash>
/// (so a changed script regenerates), or uses $FRAMEWRIGHT_TEST_MEDIA_DIR when set. Thread-safe.
/// Returns an empty string and sets `error` if generation fails.
std::string testMediaDirectory(std::string &error);

/// Full path of a generated file (empty if generation failed; see testMediaDirectory).
std::string testMediaPath(const std::string &file, std::string &error);

/// A fresh scratch directory for files a test writes (removed at process exit is not
/// guaranteed; it lives under NSTemporaryDirectory()).
std::string scratchDirectory();

/// Resident memory footprint of this process in bytes (task_vm_info.phys_footprint).
uint64_t physicalFootprint();

} // namespace ve::test
