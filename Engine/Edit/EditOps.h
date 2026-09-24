// The concrete edit commands. Construct one, then UndoStack::push it (or call apply directly).
//
// Common rules:
// - Timeline times passed in are rounded to the sequence frame grid; negative results are
//   refused. Every clip start and duration stays a whole number of frames.
// - Time math is exact (see TimeUtil.h). An edit whose exact result has no CMTime form (for
//   example a split that would need a source in point with a timescale above 2^31 - 1) is
//   refused with EditError::NotRepresentable; nothing is ever rounded.
// - An edit is refused (EditError::TrackLocked) if it would change a locked track in any way:
//   its clips (including clearing a link to a clip the edit removes), its transitions, or its
//   existence. SetTrackFlags is the only exception.
// - "includeLinked" options (default true) apply the edit to the clip's linked partner as well.
// - Ripple edits (Insert, RippleDelete, SetClipSpeed with ripple) move the time after the edit
//   point on the tracks chosen by a RippleScope (default AllUnlockedTracks) and never leave a
//   linked pair out of sync: a partner that cannot move with its clip refuses the edit.
// - Transitions whose clips stop being adjacent, or lose the media or length they need, are
//   removed by the edit (and restored by undo) and listed in EditResult::droppedTransitionIds.
//   Splitting inside a transition's range is refused unless SplitOptions allows it.
// - Edits that shorten a clip shorten its fades to fit (fadeIn + fadeOut <= duration).
// - Accessors like createdClipIds() are valid after the first successful apply() and stay
//   valid through undo/redo (redo recreates the same ids).

#pragma once

#include "../Model/Project.h"
#include "Command.h"
#include "EditPrimitives.h"

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace ve {

// One clip to add with InsertClip / OverwriteClip.
struct ClipPlacement {
    TrackId trackId;
    AssetId assetId;
    // Used source range. For a still asset only the length (sourceOut - sourceIn) matters; if it
    // is not positive the still gets defaultStillDuration().
    // On a video track the range ends at the latest where the media's video ends
    // (MediaAsset::videoEnd(), which may come before `duration` when the container runs on with
    // audio): a longer sourceOut is cut there (compare the clip's length with the request to tell
    // the user), a sourceIn at or after it is refused (OutOfSourceRange).
    CMTime sourceIn = kCMTimeZero;
    CMTime sourceOut = kCMTimeInvalid; // invalid: to the end of the media
    Ratio speed{1, 1};                 // see speedFromDouble(); ignored for stills
    VideoParams video;
    AudioParams audio;
};

// Placement of the whole of `asset` on `trackId` (stills get the default duration).
ClipPlacement placementForAsset(const MediaAsset &asset, TrackId trackId);

struct InsertOptions {
    // With exactly two placements, link the new clips to each other.
    bool linkPair = true;
    // Which tracks make room for the new clips.
    RippleScope ripple = RippleScope::AllUnlockedTracks;
};

// Adds clips at `at`, one per placement (each on a different track). Time opens at `at` on the
// ripple tracks (the target tracks always included): a clip spanning `at` is split and
// everything from `at` on moves right by the longest new clip's duration, so all rippled tracks
// stay in sync. Shorter new clips leave a gap after them. The placed duration is the source
// duration / speed rounded down to whole frames.
class InsertClip final : public SequenceCommand {
  public:
    InsertClip(SequenceId sequenceId, CMTime at, std::vector<ClipPlacement> placements, bool linkPair = true);
    InsertClip(SequenceId sequenceId, CMTime at, std::vector<ClipPlacement> placements, InsertOptions options);
    std::string name() const override {
        return "Insert";
    }
    const std::vector<ClipId> &createdClipIds() const {
        return created_;
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    CMTime at_;
    std::vector<ClipPlacement> placements_;
    InsertOptions options_;
    std::vector<ClipId> created_;
};

// Like InsertClip but nothing ripples: clips under the new clips are trimmed, removed, or split
// (when the new clip lands inside one).
class OverwriteClip final : public SequenceCommand {
  public:
    OverwriteClip(SequenceId sequenceId, CMTime at, std::vector<ClipPlacement> placements, bool linkPair = true);
    std::string name() const override {
        return "Overwrite";
    }
    const std::vector<ClipId> &createdClipIds() const {
        return created_;
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    CMTime at_;
    std::vector<ClipPlacement> placements_;
    bool linkPair_;
    std::vector<ClipId> created_;
};

// Moves a clip to `destinationTrackId` starting at `newStart`, with overwrite semantics at the
// destination. The linked partner (if includeLinked) shifts by the same time on its own track.
class MoveClip final : public SequenceCommand {
  public:
    MoveClip(SequenceId sequenceId, ClipId clipId, TrackId destinationTrackId, CMTime newStart,
             bool includeLinked = true);
    std::string name() const override {
        return "Move Clip";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    TrackId destinationTrackId_;
    CMTime newStart_;
    bool includeLinked_;
};

struct TrimOptions {
    bool includeLinked = true;
    // Clamp the requested time to the allowed range instead of refusing it.
    bool clampToLimits = false;
};

// Moves a clip's start (its end stays put), bounded by time zero, the previous clip on the
// track, the start of the source media (not for stills) and a minimum length of one frame.
class TrimClipHead final : public SequenceCommand {
  public:
    TrimClipHead(SequenceId sequenceId, ClipId clipId, CMTime newStart, TrimOptions options = {});
    std::string name() const override {
        return "Trim Clip Start";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    CMTime newStart_;
    TrimOptions options_;
};

// Moves a clip's end, bounded by the next clip on the track, the end of the source media (not
// for stills) and a minimum length of one frame.
class TrimClipTail final : public SequenceCommand {
  public:
    TrimClipTail(SequenceId sequenceId, ClipId clipId, CMTime newEnd, TrimOptions options = {});
    std::string name() const override {
        return "Trim Clip End";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    CMTime newEnd_;
    TrimOptions options_;
};

struct SplitOptions {
    bool includeLinked = true;
    // Splitting strictly inside a transition's range would leave a piece too short for it. By
    // default such a split is refused (EditError::InsideTransition); with this set the
    // transition is removed instead and reported in EditResult::droppedTransitionIds.
    bool allowBreakingTransitions = false;
};

// Splits a clip at `at` (strictly inside it). The linked partner is split too when it spans
// `at`, and the two right-hand pieces are linked to each other. Each piece keeps the fade on
// its outer edge, shortened to fit.
class SplitClip final : public SequenceCommand {
  public:
    SplitClip(SequenceId sequenceId, ClipId clipId, CMTime at, bool includeLinked = true);
    SplitClip(SequenceId sequenceId, ClipId clipId, CMTime at, SplitOptions options);
    std::string name() const override {
        return "Split Clip";
    }
    // Right-hand pieces: the clip's first, then the partner's if it was split.
    const std::vector<ClipId> &createdClipIds() const {
        return created_;
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    CMTime at_;
    SplitOptions options_;
    std::vector<ClipId> created_;
};

// Removes clips, leaving gaps.
class RemoveClips final : public SequenceCommand {
  public:
    RemoveClips(SequenceId sequenceId, std::vector<ClipId> clipIds, bool includeLinked = true);
    std::string name() const override {
        return "Delete";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    std::vector<ClipId> clipIds_;
    bool includeLinked_;
};

struct RippleOptions {
    bool includeLinked = true;
    // Tracks on which the removed time closes. The default (every unlocked track) mirrors
    // InsertClip, so a delete undoes an insert and everything after the edit stays in sync; it
    // is refused (EditError::Overlap) when another track has a clip in the removed time.
    // SyncedTracks closes the time only on the clips' own tracks and the tracks of linked
    // partners of clips that move.
    RippleScope scope = RippleScope::AllUnlockedTracks;
};

// Removes clips and closes the gaps: the union of the removed clips' time ranges is removed
// from every ripple track, so later clips shift left by the removed time before them.
class RippleDelete final : public SequenceCommand {
  public:
    RippleDelete(SequenceId sequenceId, std::vector<ClipId> clipIds, RippleOptions options = {});
    std::string name() const override {
        return "Ripple Delete";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    std::vector<ClipId> clipIds_;
    RippleOptions options_;
};

// Sets a clip's video parameters, keyframes included (the facade keeps a clip's keyframes when
// the inspector sets static values).
class SetVideoParams final : public SequenceCommand {
  public:
    SetVideoParams(SequenceId sequenceId, ClipId clipId, VideoParams params);
    std::string name() const override {
        return "Change Video Settings";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    VideoParams params_;
};

// Fades must be exact times >= 0 that together fit the clip (fadeIn + fadeOut <= duration).
class SetAudioParams final : public SequenceCommand {
  public:
    SetAudioParams(SequenceId sequenceId, ClipId clipId, AudioParams params);
    std::string name() const override {
        return "Change Audio Settings";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    AudioParams params_;
};

// One clip's new parameters in a SetClipsParams batch; parts left empty are unchanged.
struct ClipParamsChange {
    ClipId clipId{};
    std::optional<VideoParams> video;
    std::optional<AudioParams> audio;
};

// Sets the parameters of several clips as one edit (a multi-selection change in the inspector).
// Video parameters apply only to clips on video tracks and audio parameters only to clips on
// audio tracks (EditError::TrackKindMismatch otherwise). Refused as a whole when a clip is
// missing, listed twice, on a locked track, or given invalid parameters (see SetVideoParams and
// SetAudioParams). Under CoalesceMode::Accumulate successive batches merge into one undo step.
class SetClipsParams final : public SequenceCommand {
  public:
    SetClipsParams(SequenceId sequenceId, std::vector<ClipParamsChange> changes);
    std::string name() const override;

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    std::vector<ClipParamsChange> changes_;
};

// ----- Keyframed Motion (Keyframes.h) -----
//
// Keyframe times are source times of the clip (Clip::exactSourceTimeAt; for a still the time into
// the clip) and must be exact model times. Keyframes are added and moved only within the clip's
// used source range [sourceIn, source out] (a still's [0, duration]); keyframes a trim cut off
// stay, hidden, and can still be changed or removed. Only clips on video tracks have Motion
// (EditError::TrackKindMismatch otherwise). Every command is one SequenceCommand, so an
// Accumulate coalescing group (keyboard nudges) merges successive steps into one undo step.

// Adds a keyframe to `parameter` at `time` with `value` (default: the value the parameter has
// there now, so the picture does not change) and `interpolation` (default Linear, Premiere's
// default). Refused with AlreadyExists when the parameter has a keyframe at `time`.
class AddKeyframe final : public SequenceCommand {
  public:
    AddKeyframe(SequenceId sequenceId, ClipId clipId, MotionParameter parameter, CMTime time,
                std::optional<double> value = std::nullopt,
                KeyframeInterpolation interpolation = KeyframeInterpolation::Linear);
    std::string name() const override {
        return "Add Keyframe";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    MotionParameter parameter_;
    CMTime time_;
    std::optional<double> value_;
    KeyframeInterpolation interpolation_;
};

// Sets a Motion value. With `keyframeTime` the keyframe at that time gets `value` (and
// `interpolation`, when given), and when there is none one is added there (Linear unless
// `interpolation` says otherwise): what the inspector does for an animated parameter. Without a
// time the static value is set (the value of a parameter that has no keyframes).
class SetMotionValue final : public SequenceCommand {
  public:
    SetMotionValue(SequenceId sequenceId, ClipId clipId, MotionParameter parameter, std::optional<CMTime> keyframeTime,
                   double value, std::optional<KeyframeInterpolation> interpolation = std::nullopt);
    std::string name() const override;

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    MotionParameter parameter_;
    std::optional<CMTime> keyframeTime_;
    double value_;
    std::optional<KeyframeInterpolation> interpolation_;
    bool added_ = false;
};

// Removes the keyframe of `parameter` at `time` (KeyframeNotFound when there is none). Removing a
// parameter's last keyframe makes its value static at that keyframe's value, so the picture does
// not change.
class RemoveKeyframe final : public SequenceCommand {
  public:
    RemoveKeyframe(SequenceId sequenceId, ClipId clipId, MotionParameter parameter, CMTime time);
    std::string name() const override {
        return "Delete Keyframe";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    MotionParameter parameter_;
    CMTime time_;
};

// Moves the keyframe of `parameter` at `from` to `to` (within the clip's used source range),
// keeping its value and interpolation. Refused with AlreadyExists when another keyframe is at `to`.
class MoveKeyframe final : public SequenceCommand {
  public:
    MoveKeyframe(SequenceId sequenceId, ClipId clipId, MotionParameter parameter, CMTime from, CMTime to);
    std::string name() const override {
        return "Move Keyframe";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    MotionParameter parameter_;
    CMTime from_;
    CMTime to_;
};

// Sets the interpolation of the segment that starts at the keyframe of `parameter` at `time`.
// Bezier (a custom curve, which only a split creates) cannot be set this way.
class SetKeyframeInterpolation final : public SequenceCommand {
  public:
    SetKeyframeInterpolation(SequenceId sequenceId, ClipId clipId, MotionParameter parameter, CMTime time,
                             KeyframeInterpolation interpolation);
    std::string name() const override {
        return "Change Keyframe Interpolation";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    MotionParameter parameter_;
    CMTime time_;
    KeyframeInterpolation interpolation_;
};

// One parameter's complete replacement in a SetMotionTracks edit.
struct MotionTrackChange {
    MotionParameter parameter = MotionParameter::X;
    KeyframeTrack keyframes;   // may be empty (no animation)
    double staticValue = 0.0;  // the value when `keyframes` is empty
};

// Replaces whole keyframe tracks (and static values) of one clip as one edit: the Ken Burns
// helper (position and scale from a start and an end framing, planned by planMotionMove),
// matching a neighbour's framing (planMotionAtFrame) and turning a parameter's animation off. Each
// track is validated like the model (keyframeTrackProblem); a keyframe of a non-empty track must
// lie within the clip's used source range unless the clip's track already has that very keyframe
// (one a trim hid, which a partial Ken Burns move keeps).
class SetMotionTracks final : public SequenceCommand {
  public:
    SetMotionTracks(SequenceId sequenceId, ClipId clipId, std::vector<MotionTrackChange> changes,
                    std::string name = "Change Animation");
    std::string name() const override {
        return name_;
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    std::vector<MotionTrackChange> changes_;
    std::string name_;
};

// ----- Ken Burns moves and matching a neighbour's framing (plans for SetMotionTracks) -----

// Position and scale of a framing (VEMotionFraming in the facade).
struct MotionFraming {
    double x = 0.0;
    double y = 0.0;
    double scale = 1.0;
};

// A Ken Burns move over part of a clip: position and scale go from `start` on the sequence frame
// starting at `firstFrame` to `end` on the frame starting at `lastFrame` (two frames of the clip,
// `firstFrame` before `lastFrame`; the move covers the frames between them, both included).
struct MotionMoveRequest {
    CMTime firstFrame = kCMTimeInvalid;
    CMTime lastFrame = kCMTimeInvalid;
    MotionFraming start;
    MotionFraming end;
    // The segment from the start keyframe to the end keyframe (not Bezier).
    KeyframeInterpolation interpolation = KeyframeInterpolation::EaseInOut;
};

// Kept keyframes that lead into the move (before it) or on from it (after it) with a framing other
// than the move's start (end) framing: the frames between them and the move then change instead of
// holding that framing.
struct MotionMoveDrift {
    // The parameters concerned, in MotionParameter order (empty: the framing holds).
    std::vector<MotionParameter> parameters;
    // The source time of the concerned keyframe farthest from the move (the earliest before it, the
    // latest after it): the drift spans from there to the move. Invalid when `parameters` is empty.
    CMTime keyframeTime = kCMTimeInvalid;
};

struct MotionMovePlan {
    // Position X, Position Y and Scale, for SetMotionTracks (named "Ken Burns" by the facade).
    std::vector<MotionTrackChange> changes;
    MotionMoveDrift before;
    MotionMoveDrift after;
};

// Plans the Ken Burns move `request` on `clip` (on a sequence with `frameDuration` frames):
// - The start keyframe goes on `firstFrame` and the end keyframe on `lastFrame`
//   (keyframeTimeForFrame), with the request's interpolation on the start keyframe and Linear on
//   the end keyframe (it matters only when a kept keyframe follows the move).
// - Position and scale keyframes that the move's frames show (keyframeIndexForFrame's rule: a
//   keyframe belongs to the frame whose source span contains it) are replaced. Keyframes the
//   clip shows outside the move are kept, so a second move can be added elsewhere in the clip.
//   Keyframes a trim hid (outside the clip's used source range) are kept too, except on a side
//   the move reaches: a move from the clip's first frame replaces those before the clip, one to
//   its last frame those after it (the move then owns that end of the clip, and its framing holds
//   there if the clip is extended again). A move over the whole clip therefore replaces every
//   position and scale keyframe, as the helper always did.
// - Without kept keyframes the start framing holds before the move and the end framing after it
//   (the evaluation's hold before the first and after the last keyframe). A kept keyframe with a
//   different value leads into (out of) the move instead; `plan.before` / `plan.after` report it
//   (compared with motionValuesMatch).
// The static values of position and scale become the start framing (unused while animated).
// Refused with InvalidTime (frames not on the grid, not frames of the clip, not in order),
// InvalidArgument (Bezier interpolation, an invalid value) or NotRepresentable.
EditResult planMotionMove(const Clip &clip, CMTime frameDuration, const MotionMoveRequest &request,
                          MotionMovePlan &plan);

// Plans setting all five Motion values of `clip` to `values` (its static values; its keyframes
// are ignored) on the frame starting at `frame` (a frame of the clip): an animated parameter gets
// a keyframe on the frame's start (keyframeTimeForFrame), so the frame shows exactly that value;
// the keyframes the frame showed (keyframeIndexForFrame's rule, e.g. one on the out point) are
// replaced by it, and it takes the first one's interpolation (Linear when there was none). A
// static parameter gets the value as its static value, so the whole clip shows it. The changes
// list every parameter in MotionParameter order. Refused like planMotionMove.
EditResult planMotionAtFrame(const Clip &clip, CMTime frameDuration, CMTime frame, const VideoParams &values,
                             std::vector<MotionTrackChange> &changes);

// The Add Motion Keyframe toggle on the frame starting at `frame` (a frame of the clip). When every
// Motion parameter has a keyframe that frame shows (keyframeIndexForFrame), it plans removing them
// all: a track left without keyframes keeps the value the frame showed as its static value, so that
// frame's picture does not change. Otherwise it plans adding a Linear keyframe on the frame's start
// (keyframeTimeForFrame) to each parameter without one there, with the value it has there (like
// AddKeyframe: the picture does not change). `changes` lists only the parameters that change, in
// MotionParameter order; `removing` says which way it went. Refused like planMotionAtFrame.
struct MotionKeyframeToggle {
    std::vector<MotionTrackChange> changes;
    bool removing = false;
};
EditResult planMotionKeyframeToggle(const Clip &clip, CMTime frameDuration, CMTime frame, MotionKeyframeToggle &plan);

// Whether two values of `parameter` are the same for the picture: equal within a millionth of the
// larger magnitude (at least 1, so within a millionth of a pixel near the centre).
bool motionValuesMatch(MotionParameter parameter, double a, double b);

// The clip on the same track that touches `clipId` at `edge`: the one ending exactly where it
// starts (Head) or starting exactly where it ends (Tail); nullptr when there is none (a gap, the
// track's end, or no such clip).
const Clip *adjacentClip(const Sequence &sequence, ClipId clipId, ClipEdge edge);

struct SpeedOptions {
    bool includeLinked = true;
    // Shift later clips by the change in duration. Without it, a speed change that would make
    // the clip overlap the next one is refused.
    bool ripple = false;
    // With ripple: the tracks that move. Slowing down opens time at the clip's old end on those
    // tracks (splitting clips that span it); speeding up closes it (refused with Overlap if
    // another of those tracks has a clip there).
    RippleScope scope = RippleScope::AllUnlockedTracks;
};

// Changes playback speed keeping sourceIn and the start; the duration becomes the source
// duration / speed rounded down to whole frames (at least one frame, and never past the end of
// the media), so the source out point never moves later. Not for stills. With ripple, the clip
// and its linked partner must end together before and after the change.
class SetClipSpeed final : public SequenceCommand {
  public:
    SetClipSpeed(SequenceId sequenceId, ClipId clipId, Ratio speed, SpeedOptions options = {});
    // `speed` is converted with speedFromDouble().
    SetClipSpeed(SequenceId sequenceId, ClipId clipId, double speed, SpeedOptions options = {});
    std::string name() const override {
        return "Change Speed";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    Ratio speed_;
    SpeedOptions options_;
};

// Adds a transition on the cut between two adjacent clips of one track (`fromClipId` ends where
// `toClipId` starts). Refused without enough handle media.
class AddTransition final : public SequenceCommand {
  public:
    AddTransition(SequenceId sequenceId, ClipId fromClipId, ClipId toClipId, CMTime duration,
                  TransitionKind kind = TransitionKind::CrossDissolve);
    std::string name() const override {
        return "Add Transition";
    }
    TransitionId createdTransitionId() const {
        return created_;
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId fromClipId_;
    ClipId toClipId_;
    CMTime duration_;
    TransitionKind kind_;
    TransitionId created_;
};

class RemoveTransition final : public SequenceCommand {
  public:
    RemoveTransition(SequenceId sequenceId, TransitionId transitionId);
    std::string name() const override {
        return "Remove Transition";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    TransitionId transitionId_;
};

class SetTransitionDuration final : public SequenceCommand {
  public:
    SetTransitionDuration(SequenceId sequenceId, TransitionId transitionId, CMTime duration);
    std::string name() const override {
        return "Change Transition Duration";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    TransitionId transitionId_;
    CMTime duration_;
};

// Removes several transitions as one step (a dissolve and its linked audio crossfade).
// Refused as a whole when one is missing or on a locked track.
class RemoveTransitions final : public SequenceCommand {
  public:
    RemoveTransitions(SequenceId sequenceId, std::vector<TransitionId> transitionIds);
    std::string name() const override {
        return transitionIds_.size() == 1 ? "Remove Transition" : "Remove Transitions";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    std::vector<TransitionId> transitionIds_;
};

// Sets the durations of several transitions as one step (a dissolve and its linked crossfade
// resized together); each is checked like SetTransitionDuration, and the whole edit is refused
// when one does not fit. One SequenceCommand (not a composite), so an Accumulate group (keyboard
// nudges) merges successive steps.
class SetTransitionDurations final : public SequenceCommand {
  public:
    struct Change {
        TransitionId transitionId;
        CMTime duration = kCMTimeZero;
    };
    SetTransitionDurations(SequenceId sequenceId, std::vector<Change> changes);
    std::string name() const override {
        return changes_.size() == 1 ? "Change Transition Duration" : "Change Transition Durations";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    std::vector<Change> changes_;
};

// The transition linked to `transitionId`: the one on the cut between the linked partners of
// its two clips (the audio crossfade under a video dissolve, and the other way round). Nullopt
// when either clip is unlinked, the partners do not meet at a cut, or no transition joins them.
std::optional<TransitionId> linkedTransition(const Sequence &sequence, TransitionId transitionId);

// Whether the cut from `fromClipId` to `toClipId` is a through edit: both clips play the same
// asset at the same speed with the same parameters, and the second continues exactly where the
// first stops in the source (a plain split). Both sides of a transition there show (or play)
// the same media, so it has no visible (audible) effect.
bool isThroughEdit(const Sequence &sequence, ClipId fromClipId, ClipId toClipId);

// The longest transition a cut can take, and what stops a longer one.
struct TransitionLimit {
    // Whole sequence frames; zero when no transition fits the cut at all.
    CMTime maximum = kCMTimeZero;
    std::int64_t maximumFrames = 0;
    // Why a transition one frame longer than `maximum` is refused: InsufficientHandles (media
    // beyond the cut), InvalidArgument (longer than the clips it joins), Overlap (a neighbouring
    // transition), or a structural reason (ClipNotFound, NotAdjacent, AlreadyExists, TrackLocked,
    // InvalidArgument) that allows no transition at all.
    EditError limitError = EditError::None;
    // The same as a sentence for the user, naming clips by their media ("“a.mov” has no more
    // media after its out point.").
    std::string reason;
    // For InsufficientHandles: the clip that lacks the media.
    ClipId limitingClip{};
};

// The longest transition (centred on the cut, see Sequence::transitionRange) that fits the cut
// between `fromClipId` and `toClipId` of `sequenceId`: within both clips, with enough media
// beyond the cut in each (stills have unlimited media), and clear of the clips' other
// transitions. `existing` is the transition being resized, if any (ignored as a neighbour; any
// other transition on the cut makes the limit zero with AlreadyExists). Validity grows
// monotonically shorter-to-longer, so the maximum is found by bisection over whole frames.
TransitionLimit transitionLimit(const Project &project, SequenceId sequenceId, ClipId fromClipId, ClipId toClipId,
                                TransitionId existing = {});

// Links two unlinked clips on different tracks so they move, trim and split together.
class LinkClips final : public SequenceCommand {
  public:
    LinkClips(SequenceId sequenceId, ClipId first, ClipId second);
    std::string name() const override {
        return "Link";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId first_;
    ClipId second_;
};

// Breaks the link of a clip (and its partner).
class UnlinkClip final : public SequenceCommand {
  public:
    UnlinkClip(SequenceId sequenceId, ClipId clipId);
    std::string name() const override {
        return "Unlink";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
};

// Adds an empty track at `index` in its kind's list (default: top / end). An empty name
// becomes "V<n>" / "A<n>".
class AddTrack final : public SequenceCommand {
  public:
    AddTrack(SequenceId sequenceId, TrackKind kind, std::string trackName = {},
             std::optional<std::size_t> index = std::nullopt);
    std::string name() const override {
        return kind_ == TrackKind::Video ? "Add Video Track" : "Add Audio Track";
    }
    TrackId createdTrackId() const {
        return created_;
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    TrackKind kind_;
    std::string trackName_;
    std::optional<std::size_t> index_;
    TrackId created_;
};

// Removes a track with its clips and transitions; links to its clips are cleared.
class RemoveTrack final : public SequenceCommand {
  public:
    RemoveTrack(SequenceId sequenceId, TrackId trackId);
    std::string name() const override {
        return "Delete Track";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    TrackId trackId_;
};

// Fields left empty are unchanged.
struct TrackFlagsUpdate {
    std::optional<bool> muted;
    std::optional<bool> solo;
    std::optional<bool> locked;
    std::optional<std::string> name;
};

// Changes track flags/name. Allowed on locked tracks (so they can be unlocked).
class SetTrackFlags final : public SequenceCommand {
  public:
    SetTrackFlags(SequenceId sequenceId, TrackId trackId, TrackFlagsUpdate update);
    std::string name() const override {
        return "Change Track";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;
    bool mayEditLockedTracks() const override {
        return true;
    }

  private:
    TrackId trackId_;
    TrackFlagsUpdate update_;
};

} // namespace ve
