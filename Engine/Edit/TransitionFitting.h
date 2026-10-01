// Fitting transitions to their cuts and clips, and the sentences that explain a limit: the rules
// the facade's transition calls (VEEngine+Transitions.mm) apply before they build an
// AddTransitionSpans or SetTransitionRanges command (EditOps.h), which checks the result again.

#pragma once

#include "EditOps.h"

#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace ve {

// "12 frames (0.40 s)", "1 frame (0.03 s)": `frames` of `frameDuration` for messages.
std::string describeFrames(std::int64_t frames, CMTime frameDuration);

// Whether a transition refusal is about length (media, clip length, neighbours: InsufficientHandles,
// InvalidArgument, Overlap) rather than structure (missing clips, no cut, locked track, a
// transition already there).
bool isLengthLimit(EditError error);

// The user-facing refusal of a transition of `frames` on a cut limited by `limit`: "No transition
// fits this cut: <reason>" (or the reason alone for a structural limit) when none fits, else "A
// transition of <frames> does not fit this cut: <reason> The longest it allows is <maximum>."
std::string transitionRefusal(const TransitionLimit &limit, std::int64_t frames, CMTime frameDuration);

// The error a refusal by `limit` reports: its limitError, InvalidArgument when it has none.
EditError refusalError(const TransitionLimit &limit);

// The kind a transition on a track of `trackKind` gets when `requested` is asked for: audio
// transitions have no kinds (always CrossDissolve, see Transition.h).
TransitionKind transitionKindOnTrack(TrackKind trackKind, TransitionKind requested);

// "black" for a video track, "silence" for an audio track: what a fade goes to or comes from.
const char *fadeTargetName(TrackKind trackKind);

// The longest fade (whole frames of `frameDuration`) `clip` (on `track`) takes at `edge`: its length
// less its other lane-0 span's part inside it and, for a fade out, less the part inside it of a cross
// dissolve coming into it; and why not longer (limitError Overlap or InvalidArgument, and the
// sentence). Only spans at the other edge count, so the fade being resized never counts against itself.
// `maximum` is the length in time (zero when no frame fits).
TransitionLimit fadeLimit(const Clip &clip, const Track &track, ClipEdge edge, CMTime frameDuration);

// The offsets (EffectSpan::start, end) `transition` gets at a length of `frames` whole frames: a
// centred cross dissolve stays centred, an uneven one keeps its share before the cut in proportion
// (rounded down), a fade keeps its edge.
std::pair<CMTime, CMTime> resizedTransitionOffsets(const TransitionPlacement &transition, std::int64_t frames,
                                                   CMTime frameDuration);

// The longest duration `transition` (of `sequence`, which is in `project`) can be given by resizing
// it as resizedTransitionOffsets does, and why not longer: for a fade its fadeLimit (its own length
// not counting); for a cross dissolve the longest length whose resized offsets fit both sides'
// limits (transitionSideLimits), with the reason of the side one frame more would overrun.
TransitionLimit transitionDurationLimit(const Project &project, const Sequence &sequence,
                                        const TransitionPlacement &transition);

// The offsets of `transition` (of `sequence`, which is in `project`) that cover the timeline frames
// `range` (whole frames), fitted to what its clips allow, or the refusal when nothing fits. `notes`
// are sentences for the user about what was fitted or changed role, naming it "The transition" or,
// with `linked`, "The linked transition".
struct TransitionRangeFit {
    std::optional<std::pair<CMTime, CMTime>> offsets; // nullopt: refused (see `refusal`)
    EditResult refusal = EditResult::success();
    std::vector<std::string> notes;
};
// A fade in keeps its start at its clip's start (refused with InvalidTime otherwise) and is
// shortened to its fadeLimit. A tail transition's range must start at or before the cut
// (InvalidTime); the part after the cut is dropped when no clip touches the owner's end (it becomes a
// fade out), each side is shortened to transitionSideLimits (refused with that call's refusal when
// the cut has none), a fade that now reaches past the cut becomes a cross dissolve, and one that no
// longer does is shortened to its fadeLimit as a fade out. Refused with InvalidArgument when no frame
// is left.
TransitionRangeFit fitTransitionRange(const Project &project, const Sequence &sequence,
                                      const TransitionPlacement &transition, TimeRange range, bool linked);

// A fade of `frames` whole frames at `edge` of `owner` (on `ownerTrack`), with the kind `requested`
// (transitionKindOnTrack), fitted to its fadeLimit when `fitToCut` allows it.
struct FadePlan {
    std::optional<TransitionSpanRequest> request; // nullopt: refused (see `refusal`)
    std::string refusal;
    std::optional<std::string> note; // the shortening, when it was fitted
};
// Refused when the owner already has a transition at that edge, when another clip touches its start
// (for a fade in: the cut belongs to that clip), and when the fade is longer than its limit and
// `fitToCut` is off or not one frame fits. The note names the owner "The linked clip" when `linked`.
FadePlan planFade(const Clip &owner, const Track &ownerTrack, ClipEdge edge, std::int64_t frames,
                  CMTime frameDuration, bool fitToCut, TransitionKind requested, bool linked);

} // namespace ve
