// Linear undo history of applied Commands.
//
// push() executes a command and records it; a refused command is not recorded, and neither is
// one that changed nothing (Command::isNoOp). Undo/redo replay the commands' recorded patches.
// Pushing after an undo discards the redo tail.
//
// Coalescing: between beginCoalescing(key) and endCoalescing(), commands whose coalescingKey()
// equals `key` collapse into a single undo step:
//   - CoalesceMode::ReplacePrevious (default, for drags): each new command replaces the
//     previous one of the group. The previous command is reverted first, so every command is
//     expressed against the state before the gesture (e.g. "move clip 7 to 12 s"). A drag that
//     returns to where it started leaves no undo step.
//   - CoalesceMode::Accumulate (for repeated nudges): each command applies on top of the last
//     and their changes are merged; changes that cancel out leave no undo step.
// A command with a different key ends the group and is pushed normally.
//
// History that no longer matches the project (only possible if the project is modified outside
// the stack) is never replayed onto the wrong state: undo() drops the undo side and redo() the
// redo side, and both return false.
//
// Document-modified tracking: markClean() records the current position; isDirty() reports
// whether the project differs from that position. changeCount() increases on every change
// (push, undo, redo, coalesced replace) and can serve as the model version.

#pragma once

#include "../Model/Project.h"
#include "Command.h"
#include "EditResult.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace ve {

enum class CoalesceMode {
    ReplacePrevious,
    Accumulate,
};

class UndoStack {
  public:
    static constexpr std::size_t kDefaultMaxDepth = 500;

    explicit UndoStack(std::size_t maxDepth = kDefaultMaxDepth);

    // Applies `command` to `project` and records it. Returns the command's result (including
    // droppedTransitionIds, droppedSpanIds); on failure nothing is recorded and the project is unchanged (during
    // ReplacePrevious coalescing the group's previous command stays applied).
    EditResult push(Project &project, std::unique_ptr<Command> command);

    bool canUndo() const {
        return index_ > 0;
    }
    bool canRedo() const {
        return index_ < commands_.size();
    }
    // Both end any open coalescing group first. Return false when there is nothing to do.
    bool undo(Project &project);
    bool redo(Project &project);

    // Names of the commands undo()/redo() would apply, or empty.
    std::string undoName() const;
    std::string redoName() const;

    void beginCoalescing(std::string key, CoalesceMode mode = CoalesceMode::ReplacePrevious);
    void endCoalescing();
    // Reverts and discards the command recorded by the open group, then ends it (e.g. Esc
    // during a drag). Returns true if a command was reverted.
    bool cancelCoalescing(Project &project);
    bool isCoalescing() const {
        return group_.has_value();
    }

    std::size_t maxDepth() const {
        return maxDepth_;
    }
    // Shortens the history to at most `maxDepth` steps (minimum 1): redo steps are dropped first
    // (newest first), then the oldest undo steps. The project is not modified.
    void setMaxDepth(std::size_t maxDepth);

    std::size_t undoCount() const {
        return index_;
    }
    std::size_t redoCount() const {
        return commands_.size() - index_;
    }

    // Forgets all history (the project is not modified). The current state becomes clean.
    void clear();

    void markClean();
    bool isDirty() const;
    // Signed number of undo steps between the current state and the clean state (positive:
    // redo-side edits applied since saving). nullopt when the clean state is no longer reachable.
    std::optional<std::int64_t> dirtyCount() const;

    std::uint64_t changeCount() const {
        return changeCount_;
    }

  private:
    struct Group {
        std::string key;
        CoalesceMode mode = CoalesceMode::ReplacePrevious;
        bool hasCommand = false; // commands_[index_ - 1] belongs to the group
    };

    void record(std::unique_ptr<Command> command);
    void trimToMaxDepth();
    void dropRedo();
    void dropUndo();

    std::vector<std::unique_ptr<Command>> commands_;
    std::size_t index_ = 0; // number of applied commands
    std::size_t maxDepth_;
    std::optional<std::int64_t> cleanIndex_ = 0;
    std::optional<Group> group_;
    std::uint64_t changeCount_ = 0;
};

} // namespace ve
