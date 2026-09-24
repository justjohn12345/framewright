// Result of an edit: success, or the reason the edit was refused. Edits never throw for
// invalid requests; a refused edit leaves the project untouched.

#pragma once

#include "../Model/Ids.h"
#include "../Model/TimeUtil.h"

#include <optional>

#include <string>
#include <utility>
#include <vector>

namespace ve {

enum class EditError {
    None,
    SequenceNotFound,
    TrackNotFound,
    ClipNotFound,
    TransitionNotFound,  // no transition span with that id
    AssetNotFound,
    TrackLocked,         // a track the edit would modify is locked
    TrackKindMismatch,   // e.g. an audio-only asset on a video track
    InvalidTime,         // non-numeric or negative time, or a time outside the allowed span
    InvalidArgument,     // any other bad parameter
    Overlap,             // the result would overlap another clip, transition or span of the lane
    OutOfSourceRange,    // the edit needs media beyond the asset's bounds
    InsufficientHandles, // not enough media beyond the cut for a transition
    NotAdjacent,         // transition clips do not touch
    AlreadyExists,       // e.g. a transition already sits on that cut
    AlreadyLinked,
    NotLinked,
    InsideTransition,    // the edit point lies inside a transition (see SplitOptions)
    SpanNotFound,        // no effect span with that id
    NotRepresentable,    // an exact result time has no CMTime form (timescale > 2^31 - 1); nothing is rounded
    InvariantViolation,  // the edit would break a model invariant (a bug guard; should not happen)
};

const char *nameOf(EditError error);

struct EditResult {
    EditError error = EditError::None;
    std::string message;
    // Transition spans a successful edit removed as a side effect: their cut no longer exists or
    // no longer has the length or media they need (a trim, an insert or overwrite across the cut,
    // deleting one of their clips), or a fade in whose clip's start another clip now touches.
    // Spans the edit removes on purpose (RemoveSpans, RemoveTrack) are not listed. Undo restores
    // them. Also reported on redo.
    std::vector<SpanId> droppedTransitionIds;
    // Effect spans (lanes 1-3) a successful edit removed as a side effect because nothing of them
    // is left inside their clip (a trim or an overwrite cut them away). A clip's spans removed
    // with the clip are not listed.
    std::vector<SpanId> droppedSpanIds;
    // Refusals of a span that would overlap another on its lane (EditError::Overlap): the free
    // range of that lane nearest the requested one, in timeline time (whole frames), when there is
    // one.
    std::optional<TimeRange> freeRange;

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
        EditResult result;
        result.error = error;
        result.message = std::move(message);
        return result;
    }
};

} // namespace ve
