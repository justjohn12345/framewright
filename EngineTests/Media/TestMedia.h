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
//   screencast_vfr_h264.mov 1280x720 H.264 with B-frames, a screen recording: 574 frames in bursts 1/60 s
//                           apart between static gaps of up to 5.9 s (80.47 s), a keyframe every 120 frames
//                           (up to 21 s apart).
//   prores4444_alpha.mov    576x324 ProRes 4444, 10 frames at 25 fps; the left half has alpha 128
//                           with straight colour.
//   slowmo_hevc_portrait.mov 640x360 HEVC stored, displayed rotated 90 degrees clockwise; 180 frames:
//                           30 of 1/30 s, 120 of 1/240 s, 30 of 1/30 s (an iPhone slow-motion clip).
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

/// slowmo_hevc_portrait.mov: frame count, presentation time of frame `index` (index ==
/// kSlowmoFrames gives the end) and the frame containing `t`.
inline constexpr int kSlowmoFrames = 180;
CMTime slowmoFrameTime(int index);
/// Whether `directory` holds the media the current script makes: its hash (written when the media
/// was generated), a manifest, and every file the manifest lists. `FRAMEWRIGHT_TEST_MEDIA_DIR` is
/// regenerated when it is not complete.
bool testMediaIsComplete(const std::string &directory, const std::string &scriptHash);
/// The hash of Scripts/make_test_media.swift as it is now.
std::string testMediaScriptHash();
/// Removes the media of other script versions beside `currentDirectory` (directories named by a
/// 16-digit hash, or "<hash>-..." for media derived from it); done after generating new media.
void pruneTestMediaVersions(const std::string &currentDirectory);
int slowmoFrameAt(CMTime t);

/// Directory holding the generated files. Generates them on first use by running
/// `xcrun swift Scripts/make_test_media.swift` into <build dir>/FramewrightTestMedia/<script hash>
/// (so a changed script regenerates), or uses $FRAMEWRIGHT_TEST_MEDIA_DIR when set. Thread-safe.
/// Returns an empty string and sets `error` if generation fails.
std::string testMediaDirectory(std::string &error);

/// Full path of a generated file (empty if generation failed; see testMediaDirectory).
std::string testMediaPath(const std::string &file, std::string &error);

/// Directory holding the media of the opt-in stress tests (`make_test_media.swift --stress`: the
/// sync marker and the long filler clips; see the script's "Stress media"), "<testMediaDirectory>-stress".
/// Generated on first use and cached like the conformance media (thread-safe); empty with `error`
/// set on failure. Only the stress tests ask for it, so ordinary runs never make these files.
std::string stressMediaDirectory(std::string &error);
/// Full path of a stress media file (empty if generation failed).
std::string stressMediaPath(const std::string &file, std::string &error);

/// Writes an AAC (.m4a) file of `seconds` of a sine tone at `frequency` Hz, amplitude `amplitude`, mono at
/// `sampleRate`, for tests that need audio of a chosen length (a long file whose waveform takes seconds
/// to compute, a short one). Empty on success, else what failed.
std::string writeToneAudioFile(const std::string &path, double seconds, double frequency, double amplitude = 0.5,
                               double sampleRate = 48000);

/// A fresh scratch directory for files a test writes, under NSTemporaryDirectory()/FramewrightEngineTests.
/// It is removed when the test that made it ends (one made outside a test: when the test bundle ends),
/// unless FRAMEWRIGHT_KEEP_TEST_SCRATCH=1 is set in the test process (from xcodebuild:
/// TEST_RUNNER_FRAMEWRIGHT_KEEP_TEST_SCRATCH=1), for a test that logs a file to look at.
std::string scratchDirectory();
/// A scratch directory for files several tests share (written once per run): removed when the test bundle
/// ends (or kept, as above).
std::string bundleScratchDirectory();
/// Removes the scratch directories made since the last call (what the end of a test does).
void removeScratchDirectories();

/// Resident memory footprint of this process in bytes (task_vm_info.phys_footprint).
uint64_t physicalFootprint();

} // namespace ve::test
