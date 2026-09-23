// Plain descriptions of what to draw for one output frame (RenderGraph) and what to mix for a
// span of output time (AudioGraph). Produced by Scheduler from the model; consumed by the
// compositor, the audio mixer and export. No pointers into the model.

#pragma once

#include "../Model/Clip.h"
#include "../Model/Ids.h"
#include "../Model/TimeUtil.h"
#include "../Model/Transition.h"

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <vector>

namespace ve {

// Transition state of a layer. The two clips of a transition are emitted as consecutive layers
// (outgoing first); `partnerLayerIndex` points at the other one.
struct LayerTransition {
    TransitionId transitionId;
    TransitionKind kind = TransitionKind::CrossDissolve;
    // Linear progress through the transition sampled at the centre of this output frame: frame
    // k of an n-frame transition has mix (k + 0.5) / n, so the first frame already shows some of
    // the incoming clip and the last some of the outgoing one, and a 1-frame dissolve is an even
    // mix. This equals the audio crossfade's linear progress (AudioSegment::crossfade) at the
    // frame's midpoint, so picture and sound cross over together.
    double mix = 0.0;
    bool isIncoming = false; // false: the outgoing clip (before the cut)
    ClipId partnerClipId;
    std::size_t partnerLayerIndex = 0;

    // Contribution of this layer in a cross dissolve: 1 - mix for the outgoing clip, mix for
    // the incoming clip.
    double weight() const {
        return isIncoming ? mix : 1.0 - mix;
    }
};

struct VideoLayer {
    ClipId clipId;
    AssetId assetId;
    TrackId trackId;
    // Source frame to show, mapped exactly through the clip's speed and snapped down to the
    // start of the asset frame containing it (unsnapped for VFR sources; zero for stills); see
    // Scheduler::sourceFrameTime.
    CMTime sourceTime = kCMTimeZero;
    bool isStill = false;
    // The asset's container rotation (MediaAsset::rotationDegrees): degrees clockwise to rotate
    // the decoded storage-orientation frame before the clip transform is applied.
    std::int32_t sourceRotationDegrees = 0;
    // The clip's Motion at this frame (keyframes evaluated by Scheduler::motionAt; no keyframes).
    VideoParams transform;
    double opacity = 1.0; // the clip's opacity at this frame (transition weight is separate)
    std::optional<LayerTransition> transition;
};

struct RenderGraph {
    CMTime time = kCMTimeInvalid; // the sequence frame this graph shows (on the frame grid)
    std::int32_t width = 0;
    std::int32_t height = 0;
    std::vector<VideoLayer> layers; // bottom to top; empty means black

    bool isEmpty() const {
        return layers.empty();
    }
};

// The constant-power crossfade law the audio mixer applies to a crossfade's linear progress c
// (AudioSegment::crossfade): gain sin(c * pi / 2). The outgoing clip's progress runs 1 -> 0 and
// the incoming clip's 0 -> 1, so their gains are cos(f pi/2) and sin(f pi/2) and their powers
// always sum to 1.
inline double constantPowerGain(double progress) {
    return std::sin(progress * 1.57079632679489661923);
}

// A linear ramp across a segment: value at the segment start and at its end.
struct GainRamp {
    double start = 1.0;
    double end = 1.0;

    bool isUnity() const {
        return start == 1.0 && end == 1.0;
    }
};

// One clip's contribution over a sub-span of the requested range. Segments are split wherever
// an envelope has a corner (fade or transition boundaries). A clip's fades never overlap
// (validateSequence requires fadeIn + fadeOut <= duration), so within a segment the fade is one
// linear ramp and `fade` is exact at every sample; the crossfade progress is linear too.
// The sample gain at time t is
//   gain * fade(t)                                  outside transitions (transitionId empty)
//   gain * fade(t) * constantPowerGain(crossfade(t)) inside a transition
// where fade(t) and crossfade(t) interpolate their ramps linearly. `crossfade` is therefore the
// linear progress of the transition for this clip (outgoing 1 -> 0, incoming 0 -> 1), not a
// gain; this is what AudioMixer implements.
struct AudioSegment {
    ClipId clipId;
    AssetId assetId;
    TrackId trackId;
    TimeRange timelineRange; // part of the requested range this segment covers
    // Matching source media (speed applied; may extend into handles). Exact when the exact
    // source times have a CMTime form, otherwise rounded to kPreciseTimescale (flagged).
    TimeRange sourceRange;
    double speed = 1.0;     // speedRatio as a double
    Ratio speedRatio{1, 1}; // the clip's exact speed
    double gain = 1.0;      // linear, from the clip's gainDb
    GainRamp fade;          // the clip's own fade in / fade out (a gain)
    GainRamp crossfade;     // transition progress (see above); unity outside transitions
    std::optional<TransitionId> transitionId;
    std::optional<ClipId> crossfadePartner;
};

struct AudioGraph {
    TimeRange range; // the requested sequence time range
    std::int32_t sampleRate = 48000;
    std::vector<AudioSegment> segments; // in audio track order, then by clip, then by time
};

} // namespace ve
