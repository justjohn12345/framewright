// A transition across the cut between two adjacent clips on one track.
//
// The transition is centred on the cut: with n = duration in sequence frames it starts
// floor(n/2) frames before the cut and ends ceil(n/2) frames after it (see
// Sequence::transitionRange). Invariants (validateSequence): both clips are on `trackId`, the
// outgoing clip ends exactly where the incoming clip starts, the duration is a positive whole
// number of frames, the range lies inside the two clips, each clip has enough media beyond its
// edge ("handles") to cover the range, and transitions on a clip do not overlap.

#pragma once

#include "Ids.h"
#include "TimeUtil.h"

namespace ve {

enum class TransitionKind {
    CrossDissolve, // video dissolve / audio linear crossfade
};

const char *nameOf(TransitionKind kind);

struct Transition {
    TransitionId id;
    TrackId trackId;
    TransitionKind kind = TransitionKind::CrossDissolve;
    ClipId fromClipId; // outgoing clip (before the cut)
    ClipId toClipId;   // incoming clip (after the cut)
    CMTime duration = kCMTimeZero;
};

inline bool operator==(const Transition &a, const Transition &b) {
    return a.id == b.id && a.trackId == b.trackId && a.kind == b.kind && a.fromClipId == b.fromClipId &&
           a.toClipId == b.toClipId && identical(a.duration, b.duration);
}

} // namespace ve
