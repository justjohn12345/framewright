#include "VEFacadeCommands+Internal.h"

#include <algorithm>

namespace ve::facade {

// MARK: - ImportAssets

ImportAssets::ImportAssets(std::vector<MediaAsset> assets) : assets_(std::move(assets)) {}

EditResult ImportAssets::apply(Project &project) {
    if (!applied_) {
        if (assets_.empty()) {
            return EditResult::failure(EditError::InvalidArgument, "no media to import");
        }
        idsBefore_ = project.ids;
        created_.clear();
        for (const MediaAsset &asset : assets_) {
            created_.push_back(project.addAsset(asset));
        }
        idsAfter_ = project.ids;
        // Keep the assets with their ids so redo re-adds exactly these.
        for (size_t i = 0; i < assets_.size(); ++i) {
            assets_[i].id = created_[i];
        }
        applied_ = true;
        return EditResult::success();
    }
    for (const MediaAsset &asset : assets_) {
        project.assets.push_back(asset);
    }
    project.ids = idsAfter_;
    return EditResult::success();
}

void ImportAssets::revert(Project &project) {
    auto &assets = project.assets;
    assets.erase(std::remove_if(assets.begin(), assets.end(),
                                [&](const MediaAsset &a) {
                                    return std::find(created_.begin(), created_.end(), a.id) != created_.end();
                                }),
                 assets.end());
    project.ids = idsBefore_;
}

// MARK: - RemoveAsset

size_t countAssetUses(const Project &project, AssetId assetId) {
    size_t uses = 0;
    for (const Sequence &sequence : project.sequences) {
        for (const auto *tracks : {&sequence.videoTracks, &sequence.audioTracks}) {
            for (const Track &track : *tracks) {
                uses += static_cast<size_t>(std::count_if(track.clips.begin(), track.clips.end(),
                                                          [&](const Clip &c) { return c.assetId == assetId; }));
            }
        }
    }
    return uses;
}

RemoveAsset::RemoveAsset(AssetId assetId) : assetId_(assetId) {}

EditResult RemoveAsset::apply(Project &project) {
    auto it = std::find_if(project.assets.begin(), project.assets.end(),
                           [&](const MediaAsset &a) { return a.id == assetId_; });
    if (it == project.assets.end()) {
        return EditResult::failure(EditError::AssetNotFound, "the media is not in the project");
    }
    if (const size_t uses = countAssetUses(project, assetId_); uses > 0) {
        return EditResult::failure(EditError::InvalidArgument,
                                   "\"" + it->name + "\" is used by " + std::to_string(uses) +
                                       (uses == 1 ? " clip" : " clips") + " in the timeline");
    }
    index_ = static_cast<size_t>(it - project.assets.begin());
    removed_ = *it;
    project.assets.erase(it);
    return EditResult::success();
}

void RemoveAsset::revert(Project &project) {
    const size_t index = std::min(index_, project.assets.size());
    project.assets.insert(project.assets.begin() + static_cast<std::ptrdiff_t>(index), removed_);
}

// MARK: - CompositeCommand

CompositeCommand::CompositeCommand(std::string name, std::vector<std::unique_ptr<Command>> children)
    : name_(std::move(name)), children_(std::move(children)) {}

EditResult CompositeCommand::apply(Project &project) {
    if (children_.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "nothing to do");
    }
    for (size_t i = 0; i < children_.size(); ++i) {
        EditResult result = children_[i]->apply(project);
        if (!result) {
            for (size_t j = i; j-- > 0;) {
                children_[j]->revert(project);
            }
            return result;
        }
    }
    return EditResult::success();
}

void CompositeCommand::revert(Project &project) {
    for (size_t i = children_.size(); i-- > 0;) {
        children_[i]->revert(project);
    }
}

} // namespace ve::facade
