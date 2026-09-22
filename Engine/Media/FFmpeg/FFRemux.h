// Stream-copy remuxing (change the container without re-encoding) over libavformat.
#pragma once

#include "../Result.h"

#include <string>

namespace ve::media::ffmpeg {

/// Copies every audio and video stream of `source` (cover art, subtitles and data streams are
/// dropped) into a new file at `destination` written by the libavformat muxer `formatName`
/// ("matroska", "mov", "mp4", ...), without decoding. Timestamps are rescaled to the output's
/// time bases; frame rates are carried over (Matroska DefaultDuration). An audio stream that
/// starts before time 0 (encoder delay expressed by an edit list or skip-samples) keeps that
/// delay: as CodecDelay in Matroska, as an edit list in MOV/MP4. Overwrites `destination`;
/// deletes it again on failure. Blocking; thread-safe (no shared state).
Status remux(const std::string &source, const std::string &destination, const std::string &formatName);

} // namespace ve::media::ffmpeg
