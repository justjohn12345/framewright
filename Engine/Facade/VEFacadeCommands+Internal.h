// Commands the facade adds on top of Engine/Edit/EditOps: asset list changes (import, remove),
// a composite that groups several commands into one undo step (multi-clip split), a multi-clip
// move that lifts every clip before placing any, and the wrapper that keeps ids unique across
// undo.
// Private to the facade implementation: excluded from the framework's headers (project.yml).

#pragma once

#include "../Edit/Command.h"
#include "../Model/Project.h"

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace ve::facade {

/// Adds assets to the project under newly generated ids (the ids in the given assets are
/// ignored). Undo removes them again and restores the id generator.
class ImportAssets final : public Command {
  public:
    explicit ImportAssets(std::vector<MediaAsset> assets);
    EditResult apply(Project &project) override;
    void revert(Project &project) override;
    std::string name() const override {
        return "Import";
    }
    /// Ids of the added assets, in the order given; valid after the first successful apply().
    const std::vector<AssetId> &createdAssetIds() const {
        return created_;
    }

  private:
    std::vector<MediaAsset> assets_;
    std::vector<AssetId> created_;
    bool applied_ = false;
    IdGenerator idsBefore_;
    IdGenerator idsAfter_;
};

/// Removes an asset no clip uses. Undo puts it back at the same position.
class RemoveAsset final : public Command {
  public:
    explicit RemoveAsset(AssetId assetId);
    EditResult apply(Project &project) override;
    void revert(Project &project) override;
    std::string name() const override {
        return "Remove Media";
    }

  private:
    AssetId assetId_;
    MediaAsset removed_;
    size_t index_ = 0;
};

/// Number of clips of every sequence of `project` that use `assetId`.
size_t countAssetUses(const Project &project, AssetId assetId);

/// Applies child commands in order as one step; if one is refused, the ones already applied
/// are reverted and the whole command is refused. Revert runs the children backwards.
class CompositeCommand final : public Command {
  public:
    CompositeCommand(std::string name, std::vector<std::unique_ptr<Command>> children);
    EditResult apply(Project &project) override;
    void revert(Project &project) override;
    bool canRevert(const Project &project) const override;
    bool isNoOp() const override;
    std::string name() const override {
        return name_;
    }
    const std::vector<std::unique_ptr<Command>> &children() const {
        return children_;
    }

  private:
    std::string name_;
    std::vector<std::unique_ptr<Command>> children_;
};

/// Keeps ids unique within a project across undo. The model restores the id generator on undo
/// (so redo recreates identical ids), which alone would hand the ids of undone objects to the
/// next new ones: an undone import's asset id would name a different file, and every cache keyed
/// by id (frame cache, thumbnails, waveforms, bookmarks, the UI's caches) would serve the old
/// media. This wrapper raises the generator to `floor` (the highest value the project's
/// generator has reached) before running `inner`, and restores the generator exactly on
/// revert, so the history below it still replays bit for bit and redo recreates the same ids.
class FreshIds final : public Command {
  public:
    FreshIds(std::unique_ptr<Command> inner, uint64_t floor);
    EditResult apply(Project &project) override;
    void revert(Project &project) override;
    bool canRevert(const Project &project) const override;
    bool isNoOp() const override;
    std::string name() const override {
        return inner_->name();
    }

  private:
    std::unique_ptr<Command> inner_;
    uint64_t floor_;
    IdGenerator before_;
};

/// Moves several clips as one edit: every clip (and its linked partner) is lifted off its
/// track first, then each is placed at its destination with overwrite semantics, so a moved
/// clip never cuts another clip of the same move. `delta` (snapped to the sequence frame grid)
/// applies to every moved clip; `trackOffset` moves the listed clips on tracks of `offsetKind`
/// (every kind when nullopt) that many tracks within their kind. Other clips, and linked
/// partners that are not listed, keep their track and follow in time. Refused when a
/// destination track does not exist or is locked, a clip would start before zero, or two moved
/// clips would overlap each other.
class MoveClips final : public SequenceCommand {
  public:
    MoveClips(SequenceId sequenceId, std::vector<ClipId> clipIds, CMTime delta, int64_t trackOffset,
              std::optional<TrackKind> offsetKind);
    std::string name() const override {
        return clipIds_.size() == 1 ? "Move Clip" : "Move Clips";
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    std::vector<ClipId> clipIds_;
    CMTime delta_;
    int64_t trackOffset_;
    std::optional<TrackKind> offsetKind_;
};

} // namespace ve::facade
