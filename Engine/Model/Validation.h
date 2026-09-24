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

// How far clips of `asset` on a track of `kind` may use its media: MediaAsset::videoEnd() on
// video tracks (the video may end before the container's duration), duration on audio tracks.
CMTime mediaEndFor(const MediaAsset &asset, TrackKind kind);

// Why a clip's static video parameters are invalid (non-finite values, scale below 0, opacity
// outside [0, 1]), or nullopt.
std::optional<std::string> videoParamsProblem(const VideoParams &params);

// Why the effect span `span` (lanes 1-3) of `clip` on a track of `kind` is invalid on its own (id,
// lane, kind for the track, exact times, within the clip's source range, its tracks), or nullopt.
// Overlap with the clip's other spans is checked by validateSequence.
std::optional<std::string> effectSpanProblem(const EffectSpan &span, const Clip &clip, TrackKind kind);

enum class TransitionIssueKind {
    Structure,           // not a lane-0 transition span, keyframes, offsets on the wrong side of the edge
    NotAdjacent,         // a span running past the owner's end but no clip touches that end
    BadDuration,         // empty, times not exact, or a cross dissolve off the sequence frame grid
    TooLong,             // longer than the clip it lies in (the owner, or the next clip)
    InsufficientHandles, // not enough media beyond the cut
    Overlap,             // meets another transition span of the clip or of the next clip
    Touching,            // a fade in on a clip whose start another clip touches (the cut is the other clip's)
};

struct TransitionIssue {
    TransitionIssueKind kind = TransitionIssueKind::Structure;
    std::string message;
    // For InsufficientHandles: the clip that lacks media (the owner lacks it after its out point,
    // the next clip before its in point); otherwise invalid.
    ClipId clip{};
};

// Why the lane-0 span `span` of `owner` on `track` is not a valid transition (Transition.h), or
// nullopt: the rules of its role, whole sequence frames (`frameDuration`) for a cross dissolve,
// the owner's and the next clip's lengths and media (handles), and no overlap with the owner's
// other lane-0 span or the next clip's tail span.
std::optional<TransitionIssue> checkTransitionSpan(const Project &project, const Track &track, const Clip &owner,
                                                   const EffectSpan &span, CMTime frameDuration);

// First violated invariant of `sequence` (tracks, clips, links, spans and transitions), or
// nullopt. Every clip and span time must be an exact model time (numeric, no
// kCMTimeFlags_HasBeenRounded, epoch 0).
std::optional<std::string> validateSequence(const Sequence &sequence, const Project &project);

// First violated invariant of `project` (assets, every sequence, id uniqueness, id generator
// ahead of every id in use, active sequence), or nullopt.
std::optional<std::string> validateProject(const Project &project);

} // namespace ve
