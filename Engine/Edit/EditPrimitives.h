// Building blocks shared by the edit commands. They operate on a working copy of a sequence
// inside SequenceCommand::perform and do no validation of their own beyond what is documented;
// callers check preconditions and SequenceCommand validates the final result.

#pragma once

#include "../Model/Project.h"
#include "EditResult.h"

#include <utility>
#include <vector>

namespace ve {

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

// Splits the clip at `index` at timeline time `at` (strictly inside it). The left piece keeps
// the id, link and fade-in; the right piece gets a new id, no link and the fade-out; a
// transition at the clip's end moves to the right piece. Returns the right piece's id.
ClipId splitClipAt(Sequence &sequence, Track &track, std::size_t index, CMTime at, IdGenerator &ids);

// Links the right pieces of split clips whose left pieces are linked to each other, so a split
// linked pair yields two linked pairs.
void relinkSplitPieces(Sequence &sequence, const SplitList &splits);

// Overwrite semantics: removes, trims or splits the clips of `track` so nothing overlaps
// `range`. Splits are appended to `splits`.
void clearRange(Sequence &sequence, Track &track, const TimeRange &range, IdGenerator &ids, SplitList &splits);

// Moves every clip that starts at or after `from` by `delta`.
void shiftClips(Track &track, CMTime from, CMTime delta);

// Tidies an edited sequence before validation: sorts clips, clears links whose partner is gone
// or no longer reciprocates, and removes transitions that are no longer valid (their clips were
// moved, trimmed or deleted) or that conflict with an earlier transition.
void normalizeSequence(Sequence &sequence, const Project &project);

} // namespace ve
