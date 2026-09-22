// The concrete edit commands. Construct one, then UndoStack::push it (or call apply directly).
//
// Common rules:
// - Timeline times passed in are rounded to the sequence frame grid; negative results are
//   refused. Every clip start and end stays on the frame grid.
// - An edit is refused (EditError::TrackLocked) if any track it would modify is locked, including
//   the track of a linked partner the edit would carry along.
// - "includeLinked" options (default true) apply the edit to the clip's linked partner as well.
// - Transitions whose clips stop being adjacent, or lose the media or length they need, are
//   removed by the edit (and restored by undo).
// - Accessors like createdClipIds() are valid after the first successful apply() and stay
//   valid through undo/redo (redo recreates the same ids).

#pragma once

#include "../Model/Project.h"
#include "Command.h"

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
    CMTime sourceIn = kCMTimeZero;
    CMTime sourceOut = kCMTimeInvalid;
    double speed = 1.0;
    VideoParams video;
    AudioParams audio;
};

// Placement of the whole of `asset` on `trackId` (stills get the default duration).
ClipPlacement placementForAsset(const MediaAsset &asset, TrackId trackId);

// Adds clips at `at`, one per placement (each on a different track). On each target track a clip
// spanning `at` is split and everything from `at` on ripples right by the new clip's duration.
// With `linkPair` and exactly two placements the new clips are linked to each other.
// The placed duration is the source duration / speed rounded down to whole frames.
class InsertClip final : public SequenceCommand {
  public:
    InsertClip(SequenceId sequenceId, CMTime at, std::vector<ClipPlacement> placements, bool linkPair = true);
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
    bool linkPair_;
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

// Splits a clip at `at` (strictly inside it). The linked partner is split too when it spans
// `at`, and the two right-hand pieces are linked to each other.
class SplitClip final : public SequenceCommand {
  public:
    SplitClip(SequenceId sequenceId, ClipId clipId, CMTime at, bool includeLinked = true);
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
    bool includeLinked_;
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
    // Close the removed time on every unlocked track, not just the tracks the clips were on.
    // Refused if a clip on another track overlaps the removed time.
    bool allTracks = false;
};

// Removes clips and closes the gaps: later clips shift left by the removed time.
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

// Fades must be >= 0 and each at most the clip's duration.
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

struct SpeedOptions {
    bool includeLinked = true;
    // Shift later clips on the affected tracks by the change in duration. Without it, a speed
    // change that would make the clip overlap the next one is refused.
    bool ripple = false;
};

// Changes playback speed keeping sourceIn and the start; the duration becomes source duration /
// speed rounded to whole frames (the source out point is adjusted to match). Not for stills.
class SetClipSpeed final : public SequenceCommand {
  public:
    SetClipSpeed(SequenceId sequenceId, ClipId clipId, double speed, SpeedOptions options = {});
    std::string name() const override {
        return "Change Speed";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    ClipId clipId_;
    double speed_;
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

  private:
    TrackId trackId_;
    TrackFlagsUpdate update_;
};

} // namespace ve
