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

    if (group_ && group_->hasCommand && index_ > 0) {
        Command &previous = *commands_[index_ - 1];
        if (group_->mode == CoalesceMode::ReplacePrevious) {
            previous.revert(project);
            EditResult result = command->apply(project);
            if (!result) {
                previous.apply(project); // restore the gesture's last good state
                return result;
            }
            commands_[index_ - 1] = std::move(command);
        } else {
            EditResult result = command->apply(project);
            if (!result) {
                return result;
            }
            if (!previous.mergeWith(*command)) {
                record(std::move(command));
            }
        }
        if (cleanIndex_ && *cleanIndex_ >= static_cast<std::int64_t>(index_)) {
            cleanIndex_.reset(); // the step at the clean position changed
        }
        ++changeCount_;
        return EditResult::success();
    }

    EditResult result = command->apply(project);
    if (!result) {
        return result;
    }
    record(std::move(command));
    if (group_) {
        group_->hasCommand = true;
    }
    ++changeCount_;
    return result;
}

void UndoStack::record(std::unique_ptr<Command> command) {
    if (index_ < commands_.size()) {
        commands_.erase(commands_.begin() + static_cast<std::ptrdiff_t>(index_), commands_.end());
        if (cleanIndex_ && *cleanIndex_ > static_cast<std::int64_t>(index_)) {
            cleanIndex_.reset(); // the saved state was on the discarded redo branch
        }
    }
    commands_.push_back(std::move(command));
    ++index_;
    trimToMaxDepth();
}

void UndoStack::trimToMaxDepth() {
    if (commands_.size() <= maxDepth_) {
        return;
    }
    const std::size_t excess = commands_.size() - maxDepth_;
    commands_.erase(commands_.begin(), commands_.begin() + static_cast<std::ptrdiff_t>(excess));
    index_ = index_ >= excess ? index_ - excess : 0;
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
    --index_;
    commands_[index_]->revert(project);
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
        // Only possible if the project was modified outside the stack; drop the stale branch.
        commands_.erase(commands_.begin() + static_cast<std::ptrdiff_t>(index_), commands_.end());
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
    --index_;
    commands_[index_]->revert(project);
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
