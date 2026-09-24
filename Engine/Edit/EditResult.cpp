#include "EditResult.h"

namespace ve {

const char *nameOf(EditError error) {
    switch (error) {
    case EditError::None:
        return "none";
    case EditError::SequenceNotFound:
        return "sequence not found";
    case EditError::TrackNotFound:
        return "track not found";
    case EditError::ClipNotFound:
        return "clip not found";
    case EditError::TransitionNotFound:
        return "transition not found";
    case EditError::AssetNotFound:
        return "asset not found";
    case EditError::TrackLocked:
        return "track locked";
    case EditError::TrackKindMismatch:
        return "track kind mismatch";
    case EditError::InvalidTime:
        return "invalid time";
    case EditError::InvalidArgument:
        return "invalid argument";
    case EditError::Overlap:
        return "overlap";
    case EditError::OutOfSourceRange:
        return "out of source range";
    case EditError::InsufficientHandles:
        return "insufficient handles";
    case EditError::NotAdjacent:
        return "not adjacent";
    case EditError::AlreadyExists:
        return "already exists";
    case EditError::AlreadyLinked:
        return "already linked";
    case EditError::NotLinked:
        return "not linked";
    case EditError::InsideTransition:
        return "inside a transition";
    case EditError::SpanNotFound:
        return "span not found";
    case EditError::NotRepresentable:
        return "not representable";
    case EditError::InvariantViolation:
        return "invariant violation";
    }
    return "unknown";
}

} // namespace ve
