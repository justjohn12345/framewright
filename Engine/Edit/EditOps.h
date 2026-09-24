// The concrete edit commands. Construct one, then UndoStack::push it (or call apply directly).
//
// Common rules:
// - Timeline times passed in are rounded to the sequence frame grid; negative results are
//   refused. Every clip start and duration stays a whole number of frames.
// - Time math is exact (see TimeUtil.h). An edit whose exact result has no CMTime form (for
//   example a split that would need a source in point with a timescale above 2^31 - 1) is
//   refused with EditError::NotRepresentable; nothing is ever rounded.
// - An edit is refused (EditError::TrackLocked) if it would change a locked track in any way:
//   its clips (including clearing a link to a clip the edit removes) and their spans, or its
//   existence. SetTrackFlags is the only exception.
// - "includeLinked" options (default true) apply the edit to the clip's linked partner as well.
// - Ripple edits (Insert, RippleDelete, SetClipSpeed with ripple) move the time after the edit
//   point on the tracks chosen by a RippleScope (default AllUnlockedTracks) and never leave a
//   linked pair out of sync: a partner that cannot move with its clip refuses the edit.
// - Spans (EffectSpan.h) belong to their clip and move, trim and split with it: a trim through an
//   effect span clips it (the value at the new edge evaluated exactly), a split divides it, one
//   left with nothing inside the clip goes (EditResult::droppedSpanIds); lane-0 fades are
//   shortened to fit a shortened clip. Transitions whose cut no longer exists, or that lose the
//   media or length they need, are removed by the edit (and restored by undo) and listed in
//   EditResult::droppedTransitionIds, as is a fade in whose clip's start another clip now touches.
//   Splitting inside a transition's range is refused unless SplitOptions allows it.
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
    VideoParams video;                 // static values (a new clip has no spans)
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
    // Splitting strictly inside a transition's range (a cross dissolve over the cut, or a fade) would
    // leave a piece too short for it. By default such a split is refused (EditError::InsideTransition);
    // with this set the transition is removed instead and reported in
    // EditResult::droppedTransitionIds.
    bool allowBreakingTransitions = false;
};

// Splits a clip at `at` (strictly inside it). The linked partner is split too when it spans
// `at`, and the two right-hand pieces are linked to each other. The left piece keeps the lane-0
// span at its head, the right piece the one at its tail; effect spans across the cut are divided
// exactly (the right part gets a new id), so neither piece's pictures or sound change.
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

// Sets a clip's static video parameters (its spans compose onto them). Accepted on any clip.
class SetVideoParams final : public SequenceCommand {
  public:
    SetVideoParams(SequenceId sequenceId, ClipId clipId, VideoParams params,
                   std::string name = "Change Video Settings");
    std::string name() const override {
        return name_;
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    VideoParams params_;
    std::string name_;
};

// Sets a clip's static audio level (its Gain spans add to it).
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
    // The length of the clip's lane-0 fade in / fade out (0 removes it): a head fade span, or a
    // tail span ending on the cut (see setClipFade). Audio clips only, like `audio`.
    std::optional<CMTime> fadeIn = std::nullopt;
    std::optional<CMTime> fadeOut = std::nullopt;
};

// Sets the parameters of several clips as one edit (a multi-selection change in the inspector).
// Video parameters apply only to clips on video tracks and audio parameters and fades only to
// clips on audio tracks (EditError::TrackKindMismatch otherwise). Refused as a whole when a clip is
// missing, listed twice, on a locked track, or given invalid parameters or fades (see
// setClipFade). Under CoalesceMode::Accumulate successive batches merge into one undo step.
class SetClipsParams final : public SequenceCommand {
  public:
    SetClipsParams(SequenceId sequenceId, std::vector<ClipParamsChange> changes);
    std::string name() const override;

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    std::vector<ClipParamsChange> changes_;
};

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

// ----- Effect spans (EffectSpan.h) -----
//
// Span edits take timeline times, rounded to the sequence frame grid, and store the source times
// those frames show (spanTimeAt). An effect span covers at least one frame of its clip and lies
// within it; spans of one lane never overlap (refused with EditError::Overlap and
// EditResult::freeRange, the nearest free range of the lane). Motion and Opacity spans live on
// clips of video tracks and Gain spans on clips of audio tracks (TrackKindMismatch), on lanes
// 1-3 (InvalidArgument). Every command is one SequenceCommand, so an Accumulate coalescing group
// (keyboard nudges) merges successive steps, and a Replace group (a drag) replays each step
// against the state before the drag. Refused with SpanNotFound for an unknown span.

// Adds a span of `kind` (Motion, Opacity or Gain) on `lane` of `clipId` over the timeline frames
// [timelineStart, timelineEnd). It starts with a keyframe at each end holding the neutral values
// (position and rotation 0, scale and opacity 1, gain 0 dB), so it changes no frame until its
// values are set: the picture keeps the clip's framing at the range's edges.
class AddSpan final : public SequenceCommand {
  public:
    AddSpan(SequenceId sequenceId, ClipId clipId, SpanKind kind, int lane, CMTime timelineStart, CMTime timelineEnd);
    std::string name() const override;
    SpanId createdSpanId() const {
        return created_;
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    SpanKind kind_;
    int lane_;
    CMTime start_;
    CMTime end_;
    SpanId created_;
};

// Moves an effect span's edges to the timeline frames [timelineStart, timelineEnd) (a trim of one
// edge, or both for a move within the clip). Keyframes keep their places relative to the span:
// a move shifts them with it, a trim stretches the span's keyframes over the new range (the start
// and end values stay the span's start and end values).
class SetSpanRange final : public SequenceCommand {
  public:
    SetSpanRange(SequenceId sequenceId, SpanId spanId, CMTime timelineStart, CMTime timelineEnd);
    std::string name() const override {
        return "Change Span Range";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    SpanId spanId_;
    CMTime start_;
    CMTime end_;
};

// A new start and/or end value of one parameter of a span.
struct SpanValueChange {
    SpanParameter parameter = SpanParameter::X;
    std::optional<double> start;
    std::optional<double> end;
};

// Sets start and end values of an effect span's parameters (of its kind only; InvalidArgument for
// another kind's parameter or a value outside the parameter's range): the keyframe at the span's
// start or end gets the value (added there without reshaping its segment when there is none, like a
// keyframe insert); keyframes in between are kept. With `interpolation` every segment of the span
// then moves that way too (the Ken Burns move sets its values and easing in one step; not Bezier).
class SetSpanValues final : public SequenceCommand {
  public:
    SetSpanValues(SequenceId sequenceId, SpanId spanId, std::vector<SpanValueChange> changes,
                  std::string name = "Change Span Values",
                  std::optional<KeyframeInterpolation> interpolation = std::nullopt);
    std::string name() const override {
        return name_;
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    SpanId spanId_;
    std::vector<SpanValueChange> changes_;
    std::string name_;
    std::optional<KeyframeInterpolation> interpolation_;
};

// Sets how an effect span moves between its keyframes: every segment of every track gets
// `interpolation` (not Bezier, which only dividing a segment makes).
class SetSpanInterpolation final : public SequenceCommand {
  public:
    SetSpanInterpolation(SequenceId sequenceId, SpanId spanId, KeyframeInterpolation interpolation);
    std::string name() const override {
        return "Change Span Interpolation";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    SpanId spanId_;
    KeyframeInterpolation interpolation_;
};

// Moves an effect span to another lane (1-3) of its clip; refused (Overlap) where it would meet a
// span of that lane.
class MoveSpanLane final : public SequenceCommand {
  public:
    MoveSpanLane(SequenceId sequenceId, SpanId spanId, int lane);
    std::string name() const override {
        return "Move Span to Lane";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    SpanId spanId_;
    int lane_;
};

// Removes spans of any kind (transitions too) as one step; refused as a whole when one is missing
// (SpanNotFound) or on a locked track.
class RemoveSpans final : public SequenceCommand {
  public:
    RemoveSpans(SequenceId sequenceId, std::vector<SpanId> spanIds);
    std::string name() const override;

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    std::vector<SpanId> spanIds_;
    bool allTransitions_ = false;
};

// The timeline range an effect span covers (exact where representable, else rounded), or the
// range a transition span covers; nullopt on overflow.
std::optional<TimeRange> spanTimelineRange(const Clip &clip, const EffectSpan &span, const Track &track);

// The free timeline ranges (whole frames, in order) of `lane` of `clip`: its frames that no span of
// the lane covers, `except` left out (the span being moved).
std::vector<TimeRange> freeLaneRanges(const Clip &clip, int lane, CMTime frameDuration, SpanId except = {});

// The free range of `lane` nearest [start, end): the one overlapping it most, else the closest.
std::optional<TimeRange> nearestFreeRange(const Clip &clip, int lane, CMTime frameDuration, TimeRange requested,
                                          SpanId except = {});

// ----- Ken Burns and matching a neighbour (plans for SetSpanValues) -----

// Position and scale of a framing (VEMotionFraming in the facade): what the picture shows.
struct MotionFraming {
    double x = 0.0;
    double y = 0.0;
    double scale = 1.0;
};

// The Position X, Position Y and Scale start and end values of the Motion span `span` of `clip`
// that make the picture show the framing `start` at the span's start (its first frame) and reach
// `end` at its end, given everything else that composes onto the picture there (the clip's static
// values and its other lanes, taken at the span's first and last frames: spanEdgeFrameTime).
// spanEdgeMotion reads the framings back exactly. (The last frame shows the move a frame short of
// its end, so a move ending on a cut continues into a span starting there without a repeated
// framing.) Refused with InvalidArgument when a value would be invalid or the rest of the
// composition has scale 0 there (no span value can make it show a framing).
EditResult planKenBurns(const Clip &clip, const EffectSpan &span, CMTime frameDuration, MotionFraming start,
                        MotionFraming end, std::vector<SpanValueChange> &changes);

// The value changes that make the effect span `spanId` continue its touching neighbour at `edge`
// of its clip (Head: the previous clip, whose last frame is matched on this clip's first frame;
// Tail: the next clip, whose first frame is matched on this clip's last frame): the span's start
// (Head) or end (Tail) values are set so that the frame shows what the neighbour's frame shows
// (motionValuesAt for Motion and Opacity spans, gainDbAt for Gain spans), given everything else that
// composes there. Refused: SpanNotFound; NotAdjacent (no clip touches that edge); InvalidArgument
// for a transition span, for a span that does not reach that edge of its clip (its value does not
// act there), or when no value can match (scale 0 elsewhere in the composition). `changes` is empty
// when the span already matches.
EditResult planMatchSpanEdge(const Sequence &sequence, SpanId spanId, ClipEdge edge,
                             std::vector<SpanValueChange> &changes);

// Whether two values of `parameter` are the same for the picture or the sound: equal within a
// millionth of the larger magnitude (at least 1, so within a millionth of a pixel near the centre).
bool spanValuesMatch(SpanParameter parameter, double a, double b);

// The clip on the same track that touches `clipId` at `edge`: the one ending exactly where it
// starts (Head) or starting exactly where it ends (Tail); nullptr when there is none (a gap, the
// track's end, or no such clip).
const Clip *adjacentClip(const Sequence &sequence, ClipId clipId, ClipEdge edge);

// ----- Audio fades (lane-0 spans; the facade's VEAudioParams fades) -----

// Sets the length of the lane-0 fade in (`edge` Head) or fade out (Tail) of `clip`, an audio clip
// on `track`: a head fade span over the first `length` of the clip, or a tail span ending on the
// cut; zero removes it. Refused: InvalidTime (not an exact time >= 0, or longer than the clip);
// InvalidArgument for a fade in on a clip whose start another clip touches (the cut is that clip's)
// or a fade out on a clip that ends in a cross dissolve (the tail's transition is the dissolve), and
// when the two fades together would be longer than the clip. Unchanged fades change nothing. New
// span ids come from `ids`.
EditResult setClipFade(Clip &clip, const Track &track, ClipEdge edge, CMTime length, IdGenerator &ids);

// The clip's lane-0 fade in (Head: a head span) or fade out (Tail: a tail span ending on the cut)
// length; zero when it has none (a cross dissolve at the tail is not a fade).
CMTime clipFadeLength(const Clip &clip, ClipEdge edge);

// ----- Transitions (lane-0 spans, Transition.h) -----

// A transition span to add: on `clipId` at `edge`, covering [start, end] relative to that edge
// (EffectSpan::start/end: a tail span [-before, after] around the cut at the clip's end, a head span
// [0, length]).
struct TransitionSpanRequest {
    ClipId clipId{};
    ClipEdge edge = ClipEdge::Tail;
    CMTime start = kCMTimeZero;
    CMTime end = kCMTimeZero;
    TransitionKind kind = TransitionKind::CrossDissolve;
};

// Adds transition spans as one step (a dissolve and its linked audio crossfade): each must be a
// valid transition (checkTransitionSpan: a cross dissolve into the touching next clip in whole
// frames with enough media on both sides, a fade within the clip, a fade in only where nothing
// touches the clip's start). Refused as a whole: AlreadyExists (the clip has a lane-0 span at that
// edge, or the next clip's start is taken), NotAdjacent, InsufficientHandles, InvalidArgument
// (longer than a clip, off the frame grid, a fade in on a touched clip), Overlap (meets another
// transition), TrackLocked, ClipNotFound.
class AddTransitionSpans final : public SequenceCommand {
  public:
    AddTransitionSpans(SequenceId sequenceId, std::vector<TransitionSpanRequest> requests);
    std::string name() const override {
        return requests_.size() == 1 ? "Add Transition" : "Add Transitions";
    }
    // The new span ids, in request order.
    const std::vector<SpanId> &createdSpanIds() const {
        return created_;
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    std::vector<TransitionSpanRequest> requests_;
    std::vector<SpanId> created_;
};

// New offsets for a transition span (EffectSpan::start/end relative to its edge).
struct TransitionRangeChange {
    SpanId spanId{};
    CMTime start = kCMTimeZero;
    CMTime end = kCMTimeZero;
};

// Sets the ranges of several transition spans as one step (a dissolve and its linked crossfade
// resized together); each is checked like AddTransitionSpans, and the whole edit is refused when
// one does not fit. One SequenceCommand (not a composite), so an Accumulate group (keyboard nudges)
// merges successive steps. A tail span whose end becomes 0 turns into a fade out (to black or
// silence); one reaching past the cut again becomes a cross dissolve.
class SetTransitionRanges final : public SequenceCommand {
  public:
    // `durationChange`: the edit changes the transitions' lengths only (the facade's setDuration),
    // named "Change Transition Duration(s)"; otherwise "Change Transition(s)".
    SetTransitionRanges(SequenceId sequenceId, std::vector<TransitionRangeChange> changes, bool durationChange = false);
    std::string name() const override;

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    std::vector<TransitionRangeChange> changes_;
    bool durationChange_ = false;
};

// The transition resolved with its role, owner and timeline range, or nullopt when `spanId` is not
// a transition span of `sequence`.
std::optional<TransitionPlacement> findTransition(const Sequence &sequence, SpanId spanId);

// The transition linked to `spanId`: the linked partner of its owner has a lane-0 span at the same
// edge, and for a cross dissolve the partners of its two clips meet at that cut (the audio
// crossfade under a video dissolve, and the other way round). Nullopt when the owner is unlinked,
// the partners do not meet at a cut, or no transition is there.
std::optional<SpanId> linkedTransition(const Sequence &sequence, SpanId spanId);

// Whether the cut from `fromClipId` to `toClipId` is a through edit: both clips play the same
// asset at the same speed with the same static parameters and no effect spans, and the second
// continues exactly where the first stops in the source (a plain split). Both sides of a
// transition there show (or play) the same media, so it has no visible (audible) effect. Two
// pieces of one still are a through edit when neither has effect spans.
bool isThroughEdit(const Sequence &sequence, ClipId fromClipId, ClipId toClipId);

// How far a cross dissolve out of `owner` can reach on each side of its cut, and why not farther:
// before the cut it is limited by the owner's length (less a fade in at its head) and by the next
// clip's media before its in point; after the cut by the next clip's length (less its own tail
// span) and by the owner's media after its out point. Whole sequence frames.
struct TransitionSideLimits {
    std::int64_t maxBeforeFrames = 0;
    std::int64_t maxAfterFrames = 0;
    EditError beforeError = EditError::None; // InsufficientHandles, InvalidArgument (length), Overlap
    EditError afterError = EditError::None;
    std::string beforeReason; // sentences for the user
    std::string afterReason;
    ClipId beforeLimitingClip{}; // for InsufficientHandles: the clip lacking media
    ClipId afterLimitingClip{};
};
// Refused (nullopt with `why`) when the clips do not meet at a cut on one track, `owner` has a
// lane-0 tail span other than `existing`, the track is locked or a clip is missing.
std::optional<TransitionSideLimits> transitionSideLimits(const Project &project, SequenceId sequenceId,
                                                         ClipId owner, SpanId existing, EditResult &why);

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

// The longest centred transition (floor(n/2) frames before the cut, the rest after) that fits the
// cut between `fromClipId` and `toClipId` of `sequenceId` (transitionSideLimits). `existing` is the
// transition being resized, if any (any other lane-0 span at the owner's tail makes the limit zero
// with AlreadyExists).
TransitionLimit transitionLimit(const Project &project, SequenceId sequenceId, ClipId fromClipId, ClipId toClipId,
                                SpanId existing = {});

// The tail-span offsets (EffectSpan::start, end) of a transition of `frames` whole frames centred on
// its cut: floor(frames / 2) frames before it, the rest after (how version 4 drew transitions).
std::pair<CMTime, CMTime> centredTransitionOffsets(std::int64_t frames, CMTime frameDuration);

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
