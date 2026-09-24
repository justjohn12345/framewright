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

// Transition state of a layer (a lane-0 span acting on this frame, Transition.h). The two clips
// of a cross dissolve are emitted as consecutive layers (outgoing first) and point at each other
// through `partnerLayerIndex`; a fade to or from black is a single layer whose `partnerLayerIndex`
// is its own index (no partner), faded by weight() over the black (or the tracks below).
struct LayerTransition {
    SpanId transitionId;
    TransitionKind kind = TransitionKind::CrossDissolve;
    TransitionRole role = TransitionRole::CrossDissolve;
    // Linear progress through the transition's range sampled at the centre of this output frame:
    // frame k of an n-frame range has mix (k + 0.5) / n (in general the fraction of the range at the
    // frame's centre), so the first frame already shows some of the incoming picture and the last
    // some of the outgoing one, and a 1-frame dissolve is an even mix. This equals the audio
    // crossfade's (or fade's) linear progress at the frame's midpoint, so picture and sound cross
    // over together.
    double mix = 0.0;
    // Cross dissolve: whether this layer is the incoming clip. Fades: true for a fade in (the
    // picture appears as mix grows), false for a fade out.
    bool isIncoming = false;
    ClipId partnerClipId; // invalid for a fade
    std::size_t partnerLayerIndex = 0;

    // Contribution of this layer: 1 - mix for the outgoing clip or a fade out, mix for the
    // incoming clip or a fade in.
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
    // The clip's Motion at this frame: its static values with its Motion and Opacity spans applied
    // (Scheduler::motionAt).
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

// The clip's level in decibels across a segment: linear in dB from `start` to `end` (constant when
// they are equal).
struct DecibelRamp {
    double start = 0.0;
    double end = 0.0;

    bool isConstant() const {
        return start == end;
    }
};

// `db` decibels as a linear gain.
inline double decibelsToGain(double db) {
    return std::pow(10.0, db / 20.0);
}

// One clip's contribution over a sub-span of the requested range. Segments are split wherever
// an envelope has a corner: the clip's edges, its fades and transitions, and the edges and
// keyframes of its Gain spans. The sample gain at time t is
//   decibelsToGain(level(t)) * fade(t)                                  outside cross dissolves
//   decibelsToGain(level(t)) * fade(t) * constantPowerGain(crossfade(t)) inside one
// where level, fade and crossfade interpolate their ramps linearly across the segment. `level` is
// the clip's gain plus its Gain spans in dB (a Linear gain ramp is linear in dB; an eased one is
// followed in steps of at most Scheduler::kEasedGainStep; after a span's end its end level holds,
// constant, and a later span on its lane ramps on top of it). `fade` is the clip's lane-0 fade in / fade
// out (linear, a gain). `crossfade` is the linear progress of a cross dissolve for this clip
// (outgoing 1 -> 0, incoming 0 -> 1), not a gain; this is what AudioMixer implements.
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
    DecibelRamp level;      // the clip's gain plus its Gain spans, in dB
    GainRamp fade;          // the clip's own fade in / fade out (a gain)
    GainRamp crossfade;     // cross dissolve progress (see above); unity outside one
    std::optional<SpanId> transitionId; // the cross dissolve's span
    std::optional<ClipId> crossfadePartner;
};

struct AudioGraph {
    TimeRange range; // the requested sequence time range
    std::int32_t sampleRate = 48000;
    std::vector<AudioSegment> segments; // in audio track order, then by clip, then by time
};

} // namespace ve
