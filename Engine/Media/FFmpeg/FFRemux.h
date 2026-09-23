// Stream-copy remuxing (change the container without re-encoding) over libavformat.
#pragma once

#include "../Result.h"

#include <string>

namespace ve::media::ffmpeg {

/// What a remux keeps besides the streams themselves.
struct RemuxOptions {
    /// Carry the video frame rate over (Matroska: the track's DefaultDuration). When false the
    /// output declares no frame rate, so readers must take frame timing from the timestamps.
    bool frameRate = true;
    /// Carry per-packet durations over (Matroska: BlockDuration where it differs from the
    /// DefaultDuration). When false every packet is written without a duration, as mkvmerge
    /// writes SimpleBlocks: readers then only know the DefaultDuration, if any.
    bool packetDurations = true;
};

/// Copies every audio and video stream of `source` (cover art, subtitles and data streams are
/// dropped) into a new file at `destination` written by the libavformat muxer `formatName`
/// ("matroska", "mov", "mp4", ...), without decoding. Timestamps are rescaled to the output's
/// time bases; frame rates and packet durations are carried over unless `options` says
/// otherwise; stream side data (e.g. the display matrix, written as Matroska ProjectionPoseRoll)
/// is copied. An audio stream that starts before time 0 (encoder delay expressed by an edit
/// list or skip-samples) keeps that delay: as CodecDelay in Matroska, as an edit list in
/// MOV/MP4. Overwrites `destination`; deletes it again on failure. Blocking; thread-safe (no
/// shared state).
Status remux(const std::string &source, const std::string &destination, const std::string &formatName,
             const RemuxOptions &options = {});

} // namespace ve::media::ffmpeg
