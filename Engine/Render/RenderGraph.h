// Plain descriptions of what to draw for one output frame (RenderGraph) and what to mix for a
// span of output time (AudioGraph). Produced by Scheduler from the model; consumed by the
// compositor, the audio mixer and export. No pointers into the model.

#pragma once

#include "../Model/Clip.h"
#include "../Model/Ids.h"
#include "../Model/TimeUtil.h"
#include "../Model/Transition.h"

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
    // Linear progress through the transition: 0 at its first frame, approaching 1 at its end.
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
    // Source frame to show, already mapped through the clip's speed and snapped to the nearest
    // frame of the asset's frame grid (unsnapped for VFR sources; zero for stills).
    CMTime sourceTime = kCMTimeZero;
    bool isStill = false;
    // The asset's container rotation (MediaAsset::rotationDegrees): degrees clockwise to rotate
    // the decoded storage-orientation frame before the clip transform is applied.
    std::int32_t sourceRotationDegrees = 0;
    VideoParams transform;
    double opacity = 1.0; // the clip's opacity (transition weight is separate)
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

// A linear gain ramp across a segment: value at the segment start and at its end.
struct GainRamp {
    double start = 1.0;
    double end = 1.0;

    bool isUnity() const {
        return start == 1.0 && end == 1.0;
    }
};

// One clip's contribution over a sub-span of the requested range. Segments are split wherever
// an envelope has a corner (fade or transition boundaries), so every ramp is exactly linear.
// The sample gain at time t is gain * fade(t) * crossfade(t).
struct AudioSegment {
    ClipId clipId;
    AssetId assetId;
    TrackId trackId;
    TimeRange timelineRange; // part of the requested range this segment covers
    TimeRange sourceRange;   // matching source media (speed applied; may extend into handles)
    double speed = 1.0;
    double gain = 1.0;  // linear, from the clip's gainDb
    GainRamp fade;      // the clip's own fade in / fade out
    GainRamp crossfade; // transition ramp; unity outside transitions
    std::optional<TransitionId> transitionId;
    std::optional<ClipId> crossfadePartner;
};

struct AudioGraph {
    TimeRange range; // the requested sequence time range
    std::int32_t sampleRate = 48000;
    std::vector<AudioSegment> segments; // in audio track order, then by clip, then by time
};

} // namespace ve
