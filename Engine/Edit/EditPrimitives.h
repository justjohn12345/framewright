// Building blocks shared by the edit commands. They operate on a working copy of a sequence
// inside SequenceCommand::perform and do no validation of their own beyond what is documented;
// callers check preconditions and SequenceCommand validates the final result. Primitives that
// compute new source times return EditError::NotRepresentable instead of rounding; the working
// copy is then discarded by the caller.

#pragma once

#include "../Model/Project.h"
#include "EditResult.h"

#include <unordered_set>
#include <utility>
#include <vector>

namespace ve {

// Which tracks a ripple (an edit that shifts everything after a point) moves.
enum class RippleScope {
    // The tracks the edit targets, plus, transitively, every track holding a linked partner of a
    // clip that moves. Tracks with no linked material are left alone.
    SyncedTracks,
    // Every unlocked track, so everything after the edit point stays in sync. A linked partner
    // on a locked track refuses the edit (it cannot move with its clip).
    AllUnlockedTracks,
};

// (original clip id, id of the new right-hand piece) for every clip split during an edit.
using SplitList = std::vector<std::pair<ClipId, ClipId>>;

// `t` rounded to the sequence frame grid.
CMTime snapToSequence(const Sequence &sequence, CMTime t, SnapMode mode = SnapMode::Round);

// Failure unless `track` exists and is unlocked.
EditResult requireEditableTrack(const Track *track, TrackId trackId);

// Finds `clipId` and its track; fails if either is missing or the track is locked.
EditResult findEditableClip(Sequence &sequence, ClipId clipId, Track *&track, Clip *&clip);

// Inserts `clip` keeping the track sorted (the caller guarantees no overlap).
void insertClipSorted(Track &track, Clip clip);

// Removes and returns the clip. Precondition: it is on the track.
Clip removeClip(Track &track, ClipId clipId);

// The failure returned when an exact source time has no CMTime form.
EditResult notRepresentable(ClipId clipId, CMTime at);

// The failure for a clip timing change (Clip::setTimelineEnd and friends) that did not succeed:
// NotRepresentable, or InvalidArgument when a span's custom timing curve overshoots at the new
// edge. Success for RetimeResult::Ok.
EditResult retimeRefusal(RetimeResult result, ClipId clipId, CMTime at);

// Splits the clip at `index` at timeline time `at` (strictly inside it). The left piece keeps
// the id, the link and the lane-0 span at its head; the right piece gets a new id, no link and the
// lane-0 span at its tail (a fade shortened to fit its piece; a transition at the clip's end thus
// moves to the right piece). Effect spans are divided exactly at the cut (clipSpan / splitSpan):
// the left piece keeps a divided span's id, the right piece's part gets a new one; both pieces show
// exactly what the clip showed. Stores the right piece's id in `rightId`. Fails (changing nothing)
// with NotRepresentable when the right piece's source in point has no exact CMTime form, and with
// InvalidArgument when a custom timing curve (from a project file) overshoots a parameter's range
// at the cut.
EditResult splitClipAt(Sequence &sequence, Track &track, std::size_t index, CMTime at, IdGenerator &ids,
                       ClipId &rightId);

// Links the right pieces of split clips whose left pieces are linked to each other, so a split
// linked pair yields two linked pairs.
void relinkSplitPieces(Sequence &sequence, const SplitList &splits);

// Overwrite semantics: removes, trims or splits the clips of `track` so nothing overlaps
// `range`. Splits are appended to `splits`.
EditResult clearRange(Sequence &sequence, Track &track, const TimeRange &range, IdGenerator &ids, SplitList &splits);

// Moves every clip that starts at or after `from` by `delta`.
void shiftClips(Track &track, CMTime from, CMTime delta);

// The tracks a ripple at `from` moves: `seeds` plus the tracks `scope` adds (see RippleScope).
// A clip "moves" when it ends after `from`. Fails with TrackLocked when a moving clip's linked
// partner is on a locked track, or a seed track is locked.
EditResult rippleTracks(const Sequence &sequence, RippleScope scope, const std::vector<TrackId> &seeds, CMTime from,
                        std::unordered_set<TrackId> &out);

// Opens `delta` (> 0) of time at `at` on each of `tracks`: a clip spanning `at` is split there
// and everything from `at` on shifts right. A linked clip split this way whose partner lies
// wholly after `at` (and so moves) hands its link to its right piece. Splits are appended to
// `splits`; call relinkSplitPieces afterwards.
EditResult openTime(Sequence &sequence, const std::unordered_set<TrackId> &tracks, CMTime at, CMTime delta,
                    IdGenerator &ids, SplitList &splits);

// Removes the (sorted, disjoint) `ranges` of time from each of `tracks`: later clips shift left
// by the removed time before them. Fails with Overlap when a clip on one of the tracks
// intersects a removed range.
EditResult closeTime(Sequence &sequence, const std::unordered_set<TrackId> &tracks,
                     const std::vector<TimeRange> &ranges);

// Tidies an edited sequence before validation: sorts clips and their spans, clears links whose
// partner is gone or no longer reciprocates, and removes transition spans that are no longer valid
// (checkTransitionSpan: their cut is gone, they lost the length or media they need, a fade in
// whose clip's start another clip now touches). Tracks are processed in order and clips from left
// to right, so of two transitions that meet, the later clip's is kept.
void normalizeSequence(Sequence &sequence, const Project &project);

} // namespace ve
