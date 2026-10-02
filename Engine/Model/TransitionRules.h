// The one owner of how much room a transition has at an edge of its clip (review 1.8): what the
// clip's length, its other transition, a cross dissolve coming into it, the next clip and the media
// beyond the cut leave. Validation (checkTransitionSpan, pruneInvalidTransitions), the clip's own
// fade fitting after a trim (Clip::fitSpans), the edits (setClipFade, the frame-rate conform) and
// the limits the app shows (fadeLimit, transitionSideLimits, TransitionFitting.h) all read it here;
// each decides for itself what gives way when two transitions meet.
//
// The sides of a transition at `edge` of its owner:
//   - inside: the part inside the owner, after its start (a fade in) or before its end (a fade out, or
//     a cross dissolve's share before the cut). The owner's length, less its transition at the other
//     edge (that span's part inside the clip: a fade in's length, or a tail span's share before the
//     cut) and, for a tail span, less the part inside it of a cross dissolve coming into it (the tail
//     span of the clip touching its start, past that clip's end). A cross dissolve also needs the next
//     clip's media before its in point for this share.
//   - beyond (a cross dissolve, when a clip touches the owner's end): its share after the cut, inside
//     the next clip: that clip's length less its own tail span's share before its end, and the
//     owner's media after its out point.
// In a valid sequence a clip never has both a fade in and a dissolve coming into it (the cut belongs
// to the other clip), so at most one of them takes room inside a tail span's side.
//
// Plain C++ (CoreMedia's CMTime only): unit-testable without media.

#pragma once

#include "Project.h"

#include <cstdint>
#include <optional>
#include <string>

namespace ve {

// What limits one side of a transition.
enum class RoomLimit {
    ClipLength,       // the length of the clip the side lies in
    OtherEdge,        // the owner's transition at its other edge (inside), or the next clip's tail span (beyond)
    IncomingDissolve, // a cross dissolve coming into the owner from the clip touching its start (inside a tail span)
    Media,            // the media beyond the cut: the next clip's before its in point, the owner's after its out point
};

// The words a reason uses: a fade's ("A fade cannot be longer than its clip.") or a cross
// dissolve's ("A transition cannot be longer than the clips it joins.").
enum class TransitionShape {
    Fade,
    CrossDissolve,
};

// One side's room and what limits it.
struct SideRoom {
    // The parts of the room, as timeline times (exact model times, or derived from them).
    CMTime length = kCMTimeZero;    // the clip the side lies in
    CMTime otherEdge = kCMTimeZero; // what that clip's other transition takes of it (see the header)
    CMTime incoming = kCMTimeZero;  // inside a tail span: the part of a cross dissolve coming into the owner
    // A cross dissolve's side: the media beyond the cut in timeline time (zero for a clip without a
    // usable asset); nullopt when media does not limit it (a still, or a fade).
    std::optional<ExactTime> media;
    // length - otherEdge - incoming, at most `media`: what is left (may be negative where the parts
    // already overlap); nullopt only when the exact arithmetic overflows (then nothing limits it).
    std::optional<ExactTime> room;
    // Whole frames of the frame duration in `room`, rounded down; 0 when none.
    std::int64_t frames = 0;
    // What limits it, and the clip that does: the clip the side lies in (ClipLength), the clip whose
    // transition it would meet (OtherEdge, IncomingDissolve: the owner of that span), the clip lacking
    // the media (Media).
    RoomLimit limit = RoomLimit::ClipLength;
    ClipId limitingClip{};
    // The sentence for the user, naming clips by their media.
    std::string reason;
};

struct EdgeRoom {
    SideRoom inside;
    // A cross dissolve's side past the cut; nullopt for a fade, or when no clip touches the owner's end.
    std::optional<SideRoom> beyond;
};

namespace TransitionRules {

// The room of a transition of `shape` at `edge` of `owner` (on `track`, in a sequence of
// `frameDuration`; `project` holds the assets). The transition at `edge` itself, if any, never takes
// room (it is the one being sized). For a fade only `inside` is filled and media does not count.
EdgeRoom edgeRoom(const Project &project, const Track &track, const Clip &owner, ClipEdge edge,
                  TransitionShape shape, CMTime frameDuration);

// The room of a fade at `edge` of `owner` (on `track`): edgeRoom(..., TransitionShape::Fade, ...).inside,
// which needs no assets.
SideRoom fadeRoom(const Track &track, const Clip &owner, ClipEdge edge, CMTime frameDuration);

// `length` less `taken`, at least zero: what a fade has left in a clip of `length` beside the other
// transition's part `taken` (Clip::fitSpans fits a clip's own fades with it after a trim, where
// neighbours do not count); nullopt when the difference has no exact form.
std::optional<CMTime> fadeRoomBeside(CMTime length, CMTime taken);

// The longest fade at `edge` of `owner` the frame-rate conform keeps (SetSequenceFormat), in whole
// frames of `frameDuration`: it counts the owner's length and, for a fade out, its fade in, but
// neither the owner's tail dissolve for a fade in nor a dissolve coming into it for a fade out; those
// dissolves are fitted around the fade instead (transitionSideLimits). Elsewhere a fade gives way to a
// dissolve (Clip::fitSpans, pruneInvalidTransitions): see open-findings, "Colour grading prerequisites
// round 2", item 5.
std::int64_t conformFadeFrames(const Clip &owner, ClipEdge edge, CMTime frameDuration);

// The part inside `owner` of its lane-0 span at `edge`: a fade in's length (`end`), a tail span's
// share before the cut (`-start`); zero when there is none.
CMTime partInside(const Clip &owner, ClipEdge edge);

// The part inside `clip` of a cross dissolve coming into it: the tail span of the clip of `track`
// touching its start, where it reaches past that clip's end (its `end`); zero when there is none.
CMTime incomingPartInside(const Track &track, const Clip &clip);

// Whole frames of `length` (a timeline time), rounded down; 0 for a length at or below zero, and
// unlimited (a quarter of INT64_MAX) for nullopt (an overflow: nothing limits it).
std::int64_t wholeFrames(const std::optional<ExactTime> &length, CMTime frameDuration);

} // namespace TransitionRules

} // namespace ve
