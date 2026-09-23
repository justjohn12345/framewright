// Result of an edit: success, or the reason the edit was refused. Edits never throw for
// invalid requests; a refused edit leaves the project untouched.

#pragma once

#include "../Model/Ids.h"

#include <string>
#include <utility>
#include <vector>

namespace ve {

enum class EditError {
    None,
    SequenceNotFound,
    TrackNotFound,
    ClipNotFound,
    TransitionNotFound,
    AssetNotFound,
    TrackLocked,         // a track the edit would modify is locked
    TrackKindMismatch,   // e.g. an audio-only asset on a video track
    InvalidTime,         // non-numeric or negative time, or a time outside the allowed span
    InvalidArgument,     // any other bad parameter
    Overlap,             // the result would overlap another clip or transition
    OutOfSourceRange,    // the edit needs media beyond the asset's bounds
    InsufficientHandles, // not enough media beyond the cut for a transition
    NotAdjacent,         // transition clips do not touch
    AlreadyExists,       // e.g. a transition already sits on that cut
    AlreadyLinked,
    NotLinked,
    InsideTransition,    // the edit point lies inside a transition (see SplitOptions)
    KeyframeNotFound,    // no keyframe of the parameter at the given time
    NotRepresentable,    // an exact result time has no CMTime form (timescale > 2^31 - 1); nothing is rounded
    InvariantViolation,  // the edit would break a model invariant (a bug guard; should not happen)
};

const char *nameOf(EditError error);

struct EditResult {
    EditError error = EditError::None;
    std::string message;
    // Transitions a successful edit removed as a side effect because their cut no longer exists
    // or no longer has the length or media they need (e.g. a trim, an insert or overwrite across
    // the cut, deleting one of their clips). Transitions the edit removes on purpose
    // (RemoveTransition, RemoveTrack) are not listed. Undo restores them. Also reported on redo.
    std::vector<TransitionId> droppedTransitionIds;

    bool ok() const {
        return error == EditError::None;
    }
    explicit operator bool() const {
        return ok();
    }

    static EditResult success() {
        return EditResult{};
    }
    static EditResult failure(EditError error, std::string message) {
        return EditResult{error, std::move(message), {}};
    }
};

} // namespace ve
