// The search for a video track's last frame, shared by every decode path that must show it: the decode
// pool's streams (step by step) and scrub requests, and the thumbnail service.
//
// A seek at or after the end of the pictures yields no frame: a time past the end of a clip's media, or a
// track whose duration overstates its pictures (a container whose audio lasts longer, a duration rounded
// up, a variable-frame-rate track that stops early). The last frame is then found by seeking back from
// where the pictures were expected to end (the track's end, or the time asked for if earlier) by a step of
// two frames (at least 0.25 s), decoding forward to the end, and doubling the step until a frame comes out
// or the start of the stream is reached.
#pragma once

#include "Interfaces.h"

#include <optional>

namespace ve::media {

struct LastFrameSearch {
    /// The first step back: two frames of `frameDuration`, at least 0.25 s (any non-positive or
    /// non-numeric frame duration: 0.25 s).
    static CMTime firstStep(CMTime frameDuration);
    /// The step after `step` (twice it).
    static CMTime nextStep(CMTime step);
    /// Where the next attempt seeks: `step` before `from`, never before zero.
    static CMTime probe(CMTime from, CMTime step);
    /// Where the search starts: `time`, or the track's end (`trackStart` + `trackDuration`) when that is
    /// earlier and numeric.
    static CMTime searchFrom(CMTime time, CMTime trackStart, CMTime trackDuration);

    /// The whole search on `decoder` (which may be positioned anywhere): the last frame, nullopt when the
    /// track has no frame at all, or the decoder's error. Leaves the decoder at the end of the stream.
    static Result<std::optional<VideoFrame>> run(IVideoDecoder &decoder, CMTime from, CMTime frameDuration);
};

} // namespace ve::media
