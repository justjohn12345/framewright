// TEMPORARY synthetic frame source for VEPreviewView until the engine facade wires the real
// playback path (phase 5). Shows two generated burn-in style frames (a '420v' frame and a
// BGRA frame, like decoded video and a still) at 50 % opacity; the top layer rotates slowly
// while the display link runs, which makes the render loop visibly alive.

#pragma once

#include "../Media/Result.h"
#include "PreviewFrame.h"

namespace ve::render {

/// Generates the placeholder pictures (on the calling thread, a few milliseconds) and returns
/// a frame source rendering them in a 1920x1080 sequence.
media::Result<PreviewFrameSource> makePlaceholderTestSource();

} // namespace ve::render
