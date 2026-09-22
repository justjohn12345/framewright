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

/// Every generated file, in generation order.
const std::vector<TestClip> &testClips();
const TestClip &testClip(const std::string &file);

/// Directory holding the generated files. Generates them on first use by running
/// `xcrun swift Scripts/make_test_media.swift` into <build dir>/VidEditTestMedia/<script hash>
/// (so a changed script regenerates), or uses $VIDEDIT_TEST_MEDIA_DIR when set. Thread-safe.
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
