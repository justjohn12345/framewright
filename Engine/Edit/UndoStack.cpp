#include "UndoStack.h"

#include <utility>

namespace ve {

UndoStack::UndoStack(std::size_t maxDepth) : maxDepth_(maxDepth == 0 ? 1 : maxDepth) {}

EditResult UndoStack::push(Project &project, std::unique_ptr<Command> command) {
    if (!command) {
        return EditResult::failure(EditError::InvalidArgument, "no command");
    }
    if (group_ && command->coalescingKey() != group_->key) {
        endCoalescing();
    }
    if (group_ && group_->hasCommand && index_ > 0 && !commands_[index_ - 1]->canRevert(project)) {
        endCoalescing(); // the project changed behind the group's back; start a new step
    }

    if (group_ && group_->hasCommand && index_ > 0) {
        Command &previous = *commands_[index_ - 1];
        EditResult result;
        bool stepRemoved = false;
        if (group_->mode == CoalesceMode::ReplacePrevious) {
            previous.revert(project);
            result = command->apply(project);
            if (!result) {
                previous.apply(project); // restore the gesture's last good state
                return result;
            }
            if (command->isNoOp()) {
                // Back where the gesture started: the gesture no longer changes anything.
                commands_.erase(commands_.begin() + static_cast<std::ptrdiff_t>(index_ - 1));
                --index_;
                stepRemoved = true;
            } else {
                commands_[index_ - 1] = std::move(command);
            }
        } else {
            result = command->apply(project);
            if (!result || command->isNoOp()) {
                return result;
            }
            if (!previous.mergeWith(*command)) {
                record(std::move(command));
            } else if (previous.isNoOp()) {
                // The accumulated changes cancel out.
                commands_.erase(commands_.begin() + static_cast<std::ptrdiff_t>(index_ - 1));
                --index_;
                stepRemoved = true;
            }
        }
        if (stepRemoved) {
            group_->hasCommand = false;
            if (cleanIndex_ && *cleanIndex_ > static_cast<std::int64_t>(index_)) {
                cleanIndex_.reset(); // the saved state was the removed step
            }
        } else if (cleanIndex_ && *cleanIndex_ >= static_cast<std::int64_t>(index_)) {
            cleanIndex_.reset(); // the step at the clean position changed
        }
        ++changeCount_;
        return result;
    }

    EditResult result = command->apply(project);
    if (!result || command->isNoOp()) {
        return result; // refused, or nothing changed: nothing to record
    }
    record(std::move(command));
    if (group_) {
        group_->hasCommand = true;
    }
    ++changeCount_;
    return result;
}

void UndoStack::record(std::unique_ptr<Command> command) {
    dropRedo();
    commands_.push_back(std::move(command));
    ++index_;
    trimToMaxDepth();
}

void UndoStack::dropRedo() {
    if (index_ < commands_.size()) {
        commands_.erase(commands_.begin() + static_cast<std::ptrdiff_t>(index_), commands_.end());
        if (cleanIndex_ && *cleanIndex_ > static_cast<std::int64_t>(index_)) {
            cleanIndex_.reset(); // the saved state was on the discarded redo branch
        }
    }
}

void UndoStack::dropUndo() {
    commands_.erase(commands_.begin(), commands_.begin() + static_cast<std::ptrdiff_t>(index_));
    index_ = 0;
    cleanIndex_.reset(); // the history no longer describes the project
    group_.reset();
}

void UndoStack::trimToMaxDepth() {
    // Redo steps go first, then the oldest undo steps; the current state never moves.
    while (commands_.size() > maxDepth_ && commands_.size() > index_) {
        commands_.pop_back();
    }
    if (cleanIndex_ && *cleanIndex_ > static_cast<std::int64_t>(commands_.size())) {
        cleanIndex_.reset(); // the saved state was on a dropped redo step
    }
    if (commands_.size() <= maxDepth_) {
        return;
    }
    const std::size_t excess = commands_.size() - maxDepth_; // all applied: index_ == size()
    commands_.erase(commands_.begin(), commands_.begin() + static_cast<std::ptrdiff_t>(excess));
    index_ -= excess;
    if (cleanIndex_) {
        *cleanIndex_ -= static_cast<std::int64_t>(excess);
        if (*cleanIndex_ < 0) {
            cleanIndex_.reset();
        }
    }
    if (group_ && group_->hasCommand && index_ == 0) {
        group_->hasCommand = false;
    }
}

bool UndoStack::undo(Project &project) {
    endCoalescing();
    if (!canUndo()) {
        return false;
    }
    Command &command = *commands_[index_ - 1];
    if (!command.canRevert(project)) {
        dropUndo(); // only possible if the project was modified outside the stack
        return false;
    }
    --index_;
    command.revert(project);
    ++changeCount_;
    return true;
}

bool UndoStack::redo(Project &project) {
    endCoalescing();
    if (!canRedo()) {
        return false;
    }
    const EditResult result = commands_[index_]->apply(project);
    if (!result) {
        dropRedo(); // only possible if the project was modified outside the stack
        return false;
    }
    ++index_;
    ++changeCount_;
    return true;
}

std::string UndoStack::undoName() const {
    return canUndo() ? commands_[index_ - 1]->name() : std::string();
}

std::string UndoStack::redoName() const {
    return canRedo() ? commands_[index_]->name() : std::string();
}

void UndoStack::beginCoalescing(std::string key, CoalesceMode mode) {
    endCoalescing();
    group_ = Group{std::move(key), mode, false};
}

void UndoStack::endCoalescing() {
    group_.reset();
}

bool UndoStack::cancelCoalescing(Project &project) {
    const bool hadCommand = group_ && group_->hasCommand && index_ > 0;
    group_.reset();
    if (!hadCommand) {
        return false;
    }
    Command &command = *commands_[index_ - 1];
    if (!command.canRevert(project)) {
        dropUndo();
        return false;
    }
    --index_;
    command.revert(project);
    commands_.erase(commands_.begin() + static_cast<std::ptrdiff_t>(index_), commands_.end());
    if (cleanIndex_ && *cleanIndex_ > static_cast<std::int64_t>(index_)) {
        cleanIndex_.reset();
    }
    ++changeCount_;
    return true;
}

void UndoStack::setMaxDepth(std::size_t maxDepth) {
    maxDepth_ = maxDepth == 0 ? 1 : maxDepth;
    trimToMaxDepth();
}

void UndoStack::clear() {
    commands_.clear();
    index_ = 0;
    cleanIndex_ = 0;
    group_.reset();
    ++changeCount_;
}

void UndoStack::markClean() {
    cleanIndex_ = static_cast<std::int64_t>(index_);
}

bool UndoStack::isDirty() const {
    return !cleanIndex_ || *cleanIndex_ != static_cast<std::int64_t>(index_);
}

std::optional<std::int64_t> UndoStack::dirtyCount() const {
    if (!cleanIndex_) {
        return std::nullopt;
    }
    return static_cast<std::int64_t>(index_) - *cleanIndex_;
}

} // namespace ve
