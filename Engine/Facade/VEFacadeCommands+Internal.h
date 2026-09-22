// Commands the facade adds on top of Engine/Edit/EditOps: asset list changes (import, remove)
// and a composite that groups several commands into one undo step (multi-clip move/split).
// Private to the facade implementation: excluded from the framework's headers (project.yml).

#pragma once

#include "../Edit/Command.h"
#include "../Model/Project.h"

#include <memory>
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

} // namespace ve::facade
