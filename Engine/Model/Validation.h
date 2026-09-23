// Whole-model invariant checks. Every edit command validates its result with
// validateSequence before committing it, and ProjectJSON validates loaded projects, so the
// rest of the engine may assume these invariants hold.

#pragma once

#include "MediaAsset.h"
#include "Project.h"
#include "Sequence.h"

#include <optional>
#include <string>

namespace ve {

// Problem with a stored numeric model time (not numeric, kCMTimeFlags_HasBeenRounded, non-zero
// epoch), phrased as "<what> <time> ...", or nullopt.
std::optional<std::string> modelTimeProblem(CMTime t, const std::string &what);

// First violated invariant of one asset (URL, times, per-kind frame size, frame duration,
// rotation and audio format), or nullopt. Every stored time is either an exact model time
// (numeric, not rounded, epoch 0) or, where the field allows it, non-numeric; an invalid time is
// always the canonical kCMTimeInvalid.
std::optional<std::string> validateAsset(const MediaAsset &asset);

// True if clips of `asset` may live on tracks of `kind` (video: Video/AudioVideo/Still;
// audio: Audio/AudioVideo).
bool assetFitsTrack(const MediaAsset &asset, TrackKind kind);

enum class TransitionIssueKind {
    Structure,           // unknown track, clips missing or not on that track, clip joined to itself
    NotAdjacent,         // outgoing clip does not end where the incoming clip starts
    BadDuration,         // not a positive whole number of sequence frames
    TooLong,             // range extends beyond the clips it joins
    InsufficientHandles, // not enough media beyond the cut
};

struct TransitionIssue {
    TransitionIssueKind kind = TransitionIssueKind::Structure;
    std::string message;
    // For InsufficientHandles: the clip that lacks media (the outgoing clip lacks it after its
    // out point, the incoming clip before its in point); otherwise invalid.
    ClipId clip{};
};

// Why `transition` is not valid in `sequence`, or nullopt. Does not check overlap with other
// transitions (see validateSequence).
std::optional<TransitionIssue> checkTransition(const Sequence &sequence, const Project &project,
                                               const Transition &transition);

// First violated invariant of `sequence` (tracks, clips, links, transitions), or nullopt. Every
// clip and transition time must be an exact model time (numeric, no kCMTimeFlags_HasBeenRounded,
// epoch 0).
std::optional<std::string> validateSequence(const Sequence &sequence, const Project &project);

// First violated invariant of `project` (assets, every sequence, id uniqueness, id generator
// ahead of every id in use, active sequence), or nullopt.
std::optional<std::string> validateProject(const Project &project);

} // namespace ve
