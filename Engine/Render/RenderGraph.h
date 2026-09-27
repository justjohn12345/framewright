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
#include <limits>
#include <optional>
#include <vector>

namespace ve {

// The half width, in sequence pixels, of the soft edge of a shaped transition (a wipe or the iris):
// at one instant the reveal goes from 0 to 1 across 2 * kTransitionFeather pixels, so the edge is
// anti-aliased without looking blurred at any frame size.
inline constexpr double kTransitionFeather = 2.0;

// The reveal m of a shaped transition (TransitionKind other than CrossDissolve) at the sequence
// position (x, y) (pixels, origin top left, +y down) of a W x H frame: the share of the incoming picture
// there (the compositor shows mix(outgoing, incoming, m), and a single layer of a fade role times m
// fading in or 1 - m fading out, except the closing iris below). It is the soft edge averaged over the
// frame's exposure: the frame [k, k + 1) of an n-frame transition stands for a progress interval [p0, p1]
// (LayerTransition::progressStart / progressEnd, clamped to [0, 1]) during which the edge sweeps on, set
// by role so that a fade starts or ends on a wholly black frame:
//   across a cut (TransitionRole::CrossDissolve): the frame's own [k / n, (k + 1) / n], centred on the mix;
//   a fade in: [(k - 1) / n, k / n], the interval ending at the frame's start, so frame 0 is [0, 0], exactly
//       black, and the reveal completes on the frame after the transition;
//   a fade out: [(k + 1) / n, (k + 2) / n], so the picture starts leaving one frame in and frame n - 1 is
//       [1, 1], exactly black.
// The fade out is the fade in played backwards: its frame n - 1 - k is exposed over the mirror image,
// 1 - [p0, p1], of the fade in's frame k. With f = kTransitionFeather:
//   d = the distance from where the incoming picture enters: W - x (WipeLeft), x (WipeRight),
//       H - y (WipeUp), y (WipeDown), |(x, y) - (W / 2, H / 2)| (Iris);
//   L = the distance the edge travels across the frame: W, W, H, H, and half the frame's diagonal
//       sqrt(W^2 + H^2) / 2 for the iris (so the circle reaches the corners);
//   e(p) = p (L + 2f) - f, the edge's distance from the entering side at progress p;
//   the soft edge at one instant: m_p(d) = 1 - S(d - e(p)), S(x) = smoothstep(-f, f, x) = t^2 (3 - 2t),
//       t = clamp((x + f) / (2f), 0, 1);
//   the frame's reveal: m(d) = the mean of m_p(d) over p in [p0, p1]. With e0 = e(p0), e1 = e(p1),
//       D = e1 - e0 and G(x) = the integral of S up to x (0 for x <= -f, 2f (t^3 - t^4 / 2) inside the
//       band, x from f on):  m(d) = 1 - (G(d - e0) - G(d - e1)) / D;  for D below 1/1000 of a pixel (a
//       frame without length) m = m_p at p = (p0 + p1) / 2.
// So the edge is the hard edge box-filtered over the exposure (a linear ramp from 1 at e0 to 0 at e1:
// the fraction of the frame's time during which the pixel is past the edge) with the 2 px feather
// rounding its ends; the wider of the two dominates, and away from the feather (d more than f from e0
// and e1) m is exactly the box-filtered hard edge, clamp((e1 - d) / D, 0, 1). A sweep of tens of pixels
// per frame no longer steps from frame to frame. The interval [0, 0] gives exactly the outgoing picture
// (the band [-2f, 0] lies before every d >= 0) and [1, 1] exactly the incoming one (the band [L, L + 2f]
// lies past every d <= L); the first and last frames across a cut ([0, 1/n] and [(n-1)/n, 1]) show the
// entering sliver partly revealed, as their exposure does. Shaders.metal implements it (transitionReveal);
// the compositor tests hold it to a C++ reference that averages m_p over 32 sub-steps of the interval.
// The closing iris (the FadeOut role of the Iris kind, Transition.h) keeps the picture inside a disc that
// shrinks to the centre instead of letting black grow from it: the picture's share is the opening iris's
// reveal over the mirrored interval [1 - p1, 1 - p0] (black's is 1 minus it), the disc of radius (1 - p) L
// with the same feather, averaged over the frame's exposure in the same way. Wipes at a fade out keep their
// direction (black enters from the kind's side, the picture's share 1 - m).

// Transition state of a layer (a lane-0 span acting on this frame, Transition.h). The two clips
// of a cross dissolve are emitted as consecutive layers (outgoing first) and point at each other
// through `partnerLayerIndex`; a fade to or from black is a single layer whose `partnerLayerIndex`
// is its own index (no partner), faded by weight() over the black (or the tracks below). A shaped
// kind (a wipe or the iris) replaces the uniform weight with the per-pixel reveal (see
// kTransitionFeather): the incoming layer (or a fade in) is drawn times m, the outgoing layer (or a
// fade out) times 1 - m, a closing iris times the opening iris's m over the mirrored interval.
struct LayerTransition {
    SpanId transitionId;
    TransitionKind kind = TransitionKind::CrossDissolve;
    TransitionRole role = TransitionRole::CrossDissolve;
    // Linear progress through the transition's range sampled at the centre of this output frame:
    // frame k of an n-frame range has mix (k + 0.5) / n (in general the fraction of the range at the
    // frame's centre), so the first frame already shows some of the incoming picture and the last
    // some of the outgoing one, and a 1-frame dissolve is an even mix. This equals the audio
    // crossfade's (or fade's) linear progress at the frame's midpoint, so picture and sound cross
    // over together. The cross dissolve's uniform mix; a shape uses the frame's interval below.
    double mix = 0.0;
    // The frame's exposure interval as fractions of the range (clamped to [0, 1]), by role (see
    // kTransitionFeather): k / n and (k + 1) / n for frame k of n across a cut, (k - 1) / n and k / n
    // for a fade in, (k + 1) / n and (k + 2) / n for a fade out. A shaped transition averages its edge
    // over this interval; NaN (not set) makes it the instant `mix` ([mix, mix]).
    double progressStart = std::numeric_limits<double>::quiet_NaN();
    double progressEnd = std::numeric_limits<double>::quiet_NaN();
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
    // Source frame to show, mapped exactly through the clip's speed (and, for a reversed clip, the
    // mirror: Clip.h "Reverse") and snapped down to the start of the asset frame containing it
    // (unsnapped for VFR sources; zero for stills); see Scheduler::sourceFrameTime.
    CMTime sourceTime = kCMTimeZero;
    bool isStill = false;
    // The clip plays its media backwards: as the timeline advances its sourceTime goes down, so
    // decoding ahead of the playhead runs the other way (the decode direction is this XOR a
    // reverse playback direction).
    bool reversed = false;
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
    // Matching clip times (speed applied; may extend into handles). Exact when the exact clip times
    // have a CMTime form, otherwise rounded to kPreciseTimescale (flagged). For a forward clip these
    // are the source media times; for a reversed one (`reversed`) the media read for clip time u is
    // mediaEnd - u, per output sample by the mirror rule (Clip.h "Reverse", ClipAudioSource).
    TimeRange sourceRange;
    bool reversed = false;
    CMTime mediaEnd = kCMTimeInvalid; // the clip's media end (mediaEndFor), set when reversed
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
