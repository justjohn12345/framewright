// Transitions: what a lane-0 effect span (EffectSpan.h, SpanKind::Transition) does.
//
// A transition is a span on lane 0 of the clip that owns it. Where it sits decides its role:
// - At the clip's tail (ClipEdge::Tail) it covers the timeline range [cut + start, cut + end]
//   around the cut at the clip's end (start <= 0 <= end, offsets in sequence time). When it runs
//   past the cut (end > 0) it overlays the clip that touches the owner's end on the same track: a
//   cross dissolve (video) or a constant-power crossfade (audio) whose share of each side is the
//   range's split at the cut, using the owner's media after its out point and the next clip's
//   media before its in point (the handles). A tail span ending on the cut (end == 0) is a fade
//   out to black (video) or silence (audio) inside the clip, touching neighbour or not.
// - At the clip's head (ClipEdge::Head) it is a fade in from black or silence over
//   [clip start, clip start + end] (start == 0), allowed only when no clip touches the owner's
//   start: a cut between two touching clips belongs to the outgoing (left) clip, so it takes one
//   transition at most, the outgoing clip's.
// Validation lives in Validation.h (checkTransitionSpan).

#pragma once

namespace ve {

// The kind of transition a lane-0 span makes. The only kind: a linear dissolve for video
// (LayerTransition::mix) and a constant-power crossfade for audio (constantPowerGain, applied to
// the linear progress), or a linear fade against black / silence where no clip is on the other
// side.
enum class TransitionKind {
    CrossDissolve,
};

// "crossDissolve".
const char *nameOf(TransitionKind kind);

// What a transition span does where it sits (see the top of this file).
enum class TransitionRole {
    CrossDissolve, // across the cut into the touching next clip
    FadeOut,       // to black / silence at the owner's end
    FadeIn,        // from black / silence at the owner's start
};

// "crossDissolve", "fadeOut", "fadeIn".
const char *nameOf(TransitionRole role);

} // namespace ve
