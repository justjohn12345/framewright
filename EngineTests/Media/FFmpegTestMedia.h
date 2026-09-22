// Matroska copies of the generated conformance media, for running the conformance suite over
// the FFmpeg backend's MKV path. The remux is a pure stream copy through libavformat (ffmpeg::remux) (no
// re-encode), so frames, burn-ins and audio are bit-identical to the ISO-BMFF originals; only
// the container (and its millisecond time base) differs.
#pragma once

#include "TestMedia.h"

#include <string>
#include <vector>

namespace ve::test {

/// Directory holding the .mkv remuxes, a sibling of testMediaDirectory() ("<dir>-mkv<version>").
/// Created on first use (thread-safe); empty with `error` set on failure.
std::string mkvTestMediaDirectory(std::string &error);

/// The clips that are remuxed: h264_1080p30 and hevc_720p2997 as ".mkv", container "mkv",
/// every other property as in testClips().
const std::vector<TestClip> &mkvTestClips();

/// Stream-copies `source` into a Matroska file at `destination` (ffmpeg::remux): AAC encoder delay
/// from the source's edit list becomes CodecDelay.
bool remuxToMatroska(const std::string &source, const std::string &destination, std::string &error);

} // namespace ve::test
