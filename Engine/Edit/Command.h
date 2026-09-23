// Undoable commands.
//
// Every edit is a Command. apply() performs it the first time and re-applies it after a
// revert(); revert() restores the exact previous state (bit for bit, including ids and the id
// generator). Sequence edits derive from SequenceCommand, which runs the edit on a copy of the
// sequence, validates the result, and records a SequencePatch (before/after snapshots of only
// the tracks and transitions that changed). Undo and redo replay those snapshots rather than
// re-running the edit, so arbitrarily long undo/redo chains are stable.

#pragma once

#include "../Model/Project.h"
#include "EditResult.h"

#include <optional>
#include <string>
#include <vector>

namespace ve {

class Command {
  public:
    virtual ~Command() = default;
    Command(const Command &) = delete;
    Command &operator=(const Command &) = delete;

    // First call: performs the edit (or refuses it, leaving `project` untouched).
    // After revert(): re-applies exactly the same change.
    virtual EditResult apply(Project &project) = 0;

    // Undoes a successful apply(). Precondition: `project` is in the state apply() left it in
    // (check with canRevert()); otherwise the project is left unchanged.
    virtual void revert(Project &project) = 0;

    // Whether revert() can undo this command on `project` (it is in the state apply() left it
    // in). UndoStack checks this before undoing so a history that no longer matches the project
    // (the project was changed outside the stack) is dropped instead of corrupting it.
    virtual bool canRevert(const Project &project) const {
        (void)project;
        return true;
    }

    // True when the applied command changed nothing (e.g. a move to where the clip already is).
    // UndoStack does not record such commands.
    virtual bool isNoOp() const {
        return false;
    }

    // Human-readable name for the Undo/Redo menu items ("Move Clip").
    virtual std::string name() const = 0;

    // Commands with the same non-empty key may be coalesced into one undo step by UndoStack
    // (e.g. every step of one drag). Defaults to "<op>:<target id>"; callers may override it.
    const std::string &coalescingKey() const {
        return coalescingKey_;
    }
    void setCoalescingKey(std::string key) {
        coalescingKey_ = std::move(key);
    }

    // Absorbs `next`, an applied command that directly followed this one, so that this command
    // alone spans both changes. Returns false if the commands cannot merge.
    virtual bool mergeWith(const Command &next) {
        (void)next;
        return false;
    }

  protected:
    Command() = default;

  private:
    std::string coalescingKey_;
};

// Before/after snapshots of the parts of one sequence an edit changed.
struct TrackSnapshot {
    TrackId trackId;
    std::optional<Track> before; // nullopt: the track did not exist before
    std::optional<Track> after;  // nullopt: the track does not exist after
};

struct SequencePatch {
    SequenceId sequenceId;
    std::vector<TrackSnapshot> tracks; // only tracks whose contents changed
    bool trackOrderChanged = false;    // tracks added, removed or reordered
    std::vector<TrackId> videoOrderBefore, videoOrderAfter;
    std::vector<TrackId> audioOrderBefore, audioOrderAfter;
    bool transitionsChanged = false;
    std::vector<Transition> transitionsBefore, transitionsAfter;
    IdGenerator idsBefore, idsAfter;

    bool isEmpty() const {
        return tracks.empty() && !trackOrderChanged && !transitionsChanged && idsBefore == idsAfter;
    }
};

// Records what changed between `before` and `after` (the same sequence).
SequencePatch diffSequences(const Sequence &before, const Sequence &after, const IdGenerator &idsBefore,
                            const IdGenerator &idsAfter);

enum class PatchDirection {
    Forward,  // before -> after (redo)
    Backward, // after -> before (undo)
};

// Whether `sequence` and `ids` are exactly in the patch's source state for `direction` (the
// "before" state going forward, the "after" state going backward): every recorded track equal
// to its snapshot (or absent where it did not exist), the track order, the transitions and the
// id generator as recorded.
bool patchApplies(const Sequence &sequence, const IdGenerator &ids, const SequencePatch &patch,
                  PatchDirection direction);

// Moves `sequence` and `ids` across the patch. Returns false, changing nothing, unless
// patchApplies() (so a mismatched base can never throw or corrupt the sequence).
bool applyPatch(Sequence &sequence, IdGenerator &ids, const SequencePatch &patch, PatchDirection direction);

// The single patch equivalent to applying `first` then `second`. Parts that end where they
// started (a track changed and changed back) are left out, so a round trip composes to an empty
// patch.
SequencePatch composePatches(const SequencePatch &first, const SequencePatch &second);

class SequenceCommand : public Command {
  public:
    EditResult apply(Project &project) final;
    void revert(Project &project) final;
    bool canRevert(const Project &project) const final;
    bool isNoOp() const final;
    bool mergeWith(const Command &next) final;

    SequenceId sequenceId() const {
        return sequenceId_;
    }
    // The recorded change; empty until the first successful apply().
    const std::optional<SequencePatch> &patch() const {
        return patch_;
    }

  protected:
    explicit SequenceCommand(SequenceId sequenceId) : sequenceId_(sequenceId) {}

    // Performs the edit on `sequence`, a working copy, allocating new ids from `ids`. `project`
    // still holds the unedited sequence and is only for lookups (assets). Returns a failure to
    // refuse the edit; the copy is then discarded.
    virtual EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) = 0;

  private:
    SequenceId sequenceId_;
    std::optional<SequencePatch> patch_;
};

} // namespace ve
