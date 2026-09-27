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

#include <array>
#include <optional>
#include <string_view>

namespace ve {

// The kind of transition a lane-0 span makes: how the picture changes over the linear progress p
// (LayerTransition::mix, 0 at the start of the range, 1 at its end). The kind is a video property:
// audio always uses a constant-power crossfade across a cut (constantPowerGain of the linear
// progress) or a linear fade against silence at a free edge, and a transition span on an audio
// track is always CrossDissolve (checkTransitionSpan). Where no clip is on the other side (a fade
// role), the other picture is black, or the tracks below. The shaped kinds reveal the incoming
// picture per pixel through a soft edge kTransitionFeather sequence pixels wide on each side
// (RenderGraph.h, transitionReveal); p = 0 shows none of it and p = 1 all of it.
enum class TransitionKind {
    // Every pixel mixes linearly: (1 - p) of the outgoing picture and p of the incoming one.
    CrossDissolve,
    // The incoming picture enters from the right edge; the edge between them travels left.
    WipeLeft,
    // The incoming picture enters from the left edge; the edge between them travels right.
    WipeRight,
    // The incoming picture enters from the bottom edge; the edge between them travels up.
    WipeUp,
    // The incoming picture enters from the top edge; the edge between them travels down.
    WipeDown,
    // The incoming picture shows inside a circle growing from the frame's centre until it covers
    // the corners. Iris opens on a cut or a fade-in and closes on a fade-out: at a clip's end the
    // picture stays inside a circle shrinking to the centre, black coming in from the corners.
    Iris,
};

inline constexpr std::array<TransitionKind, 6> kTransitionKinds{
    TransitionKind::CrossDissolve, TransitionKind::WipeLeft, TransitionKind::WipeRight,
    TransitionKind::WipeUp,        TransitionKind::WipeDown, TransitionKind::Iris};

// "crossDissolve", "wipeLeft", "wipeRight", "wipeUp", "wipeDown", "iris" (the project file's names).
const char *nameOf(TransitionKind kind);
// "Cross Dissolve", "Wipe Left", "Wipe Right", "Wipe Up", "Wipe Down", "Iris" (messages).
const char *displayNameOf(TransitionKind kind);
// The kind named `name` (nameOf), or nullopt.
std::optional<TransitionKind> transitionKindNamed(std::string_view name);

// What a transition span does where it sits (see the top of this file).
enum class TransitionRole {
    CrossDissolve, // across the cut into the touching next clip
    FadeOut,       // to black / silence at the owner's end
    FadeIn,        // from black / silence at the owner's start
};

// "crossDissolve", "fadeOut", "fadeIn".
const char *nameOf(TransitionRole role);

} // namespace ve
