// Result of an edit: success, or the reason the edit was refused. Edits never throw for
// invalid requests; a refused edit leaves the project untouched.

#pragma once

#include <string>
#include <utility>

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
    InvariantViolation, // the edit would break a model invariant (a bug guard; should not happen)
};

const char *nameOf(EditError error);

struct EditResult {
    EditError error = EditError::None;
    std::string message;

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
        return EditResult{error, std::move(message)};
    }
};

} // namespace ve
