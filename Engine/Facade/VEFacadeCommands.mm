#include "VEFacadeCommands+Internal.h"

#include "../Edit/EditPrimitives.h"

#include <algorithm>
#include <map>
#include <set>

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
    EditResult combined = EditResult::success();
    for (size_t i = 0; i < children_.size(); ++i) {
        EditResult result = children_[i]->apply(project);
        if (!result) {
            for (size_t j = i; j-- > 0;) {
                children_[j]->revert(project);
            }
            return result;
        }
        // Every child's side effects are the composite's.
        for (TransitionId id : result.droppedTransitionIds) {
            if (std::find(combined.droppedTransitionIds.begin(), combined.droppedTransitionIds.end(), id) ==
                combined.droppedTransitionIds.end()) {
                combined.droppedTransitionIds.push_back(id);
            }
        }
    }
    return combined;
}

bool CompositeCommand::canRevert(const Project &project) const {
    // The project must be in the state the last child left it in; each earlier child's state
    // is then restored by the revert of the one after it.
    return children_.empty() || children_.back()->canRevert(project);
}

bool CompositeCommand::isNoOp() const {
    return std::all_of(children_.begin(), children_.end(), [](const auto &child) { return child->isNoOp(); });
}

void CompositeCommand::revert(Project &project) {
    for (size_t i = children_.size(); i-- > 0;) {
        children_[i]->revert(project);
    }
}

// MARK: - FreshIds

FreshIds::FreshIds(std::unique_ptr<Command> inner, uint64_t floor) : inner_(std::move(inner)), floor_(floor) {
    setCoalescingKey(inner_->coalescingKey());
}

EditResult FreshIds::apply(Project &project) {
    const IdGenerator saved = project.ids;
    if (floor_ > 0) {
        project.ids.reserveThrough(floor_ - 1);
    }
    EditResult result = inner_->apply(project);
    if (!result || inner_->isNoOp()) {
        project.ids = saved; // refused or nothing changed: the project is exactly as it was
        return result;
    }
    before_ = saved;
    return result;
}

void FreshIds::revert(Project &project) {
    inner_->revert(project);
    project.ids = before_;
}

bool FreshIds::canRevert(const Project &project) const {
    return inner_->canRevert(project);
}

bool FreshIds::isNoOp() const {
    return inner_->isNoOp();
}

bool FreshIds::mergeWith(const Command &next) {
    const auto *other = dynamic_cast<const FreshIds *>(&next);
    return other != nullptr && inner_->mergeWith(*other->inner_);
}

// MARK: - MoveClips

MoveClips::MoveClips(SequenceId sequenceId, std::vector<ClipId> clipIds, CMTime delta, int64_t trackOffset,
                     std::optional<TrackKind> offsetKind)
    : SequenceCommand(sequenceId), clipIds_(std::move(clipIds)), delta_(delta), trackOffset_(trackOffset),
      offsetKind_(offsetKind) {}

EditResult MoveClips::perform(const Project &, Sequence &sequence, IdGenerator &ids) {
    if (clipIds_.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "nothing to move");
    }
    if (!CMTIME_IS_NUMERIC(delta_)) {
        return EditResult::failure(EditError::InvalidTime, "the move offset is not a valid time");
    }
    const CMTime delta = snapToSequence(sequence, delta_);

    // The clips to move: the chosen ones and their linked partners, each once.
    std::vector<ClipId> moving;
    std::set<ClipId> seen;
    auto add = [&](ClipId id) {
        if (seen.insert(id).second) {
            moving.push_back(id);
        }
    };
    for (ClipId id : clipIds_) {
        const Clip *clip = sequence.findClip(id);
        if (clip == nullptr) {
            return EditResult::failure(EditError::ClipNotFound, "a selected clip no longer exists");
        }
        add(id);
        if (clip->linkedClipId) {
            add(*clip->linkedClipId);
        }
    }

    struct Placement {
        Clip clip;
        TrackId destination;
    };
    std::vector<Placement> placements;
    placements.reserve(moving.size());
    for (ClipId id : moving) {
        Track *track = nullptr;
        Clip *clip = nullptr;
        if (EditResult r = findEditableClip(sequence, id, track, clip); !r) {
            return r;
        }
        const auto &tracks = sequence.tracks(track->kind);
        const auto position =
            std::find_if(tracks.begin(), tracks.end(), [&](const Track &t) { return t.id == track->id; });
        const bool listed = std::find(clipIds_.begin(), clipIds_.end(), id) != clipIds_.end();
        const bool changesTrack = listed && (!offsetKind_ || track->kind == *offsetKind_);
        const int64_t destinationIndex =
            static_cast<int64_t>(position - tracks.begin()) + (changesTrack ? trackOffset_ : 0);
        if (destinationIndex < 0 || destinationIndex >= static_cast<int64_t>(tracks.size())) {
            return EditResult::failure(EditError::TrackNotFound, "there is no track there");
        }
        const Track &destination = tracks[static_cast<size_t>(destinationIndex)];
        if (EditResult r = requireEditableTrack(&destination, destination.id); !r) {
            return r;
        }
        if (clip->timelineStart + delta < kCMTimeZero) {
            return EditResult::failure(EditError::InvalidTime, "clips cannot move before the sequence start");
        }
        placements.push_back(Placement{*clip, destination.id});
    }
    if (delta == kCMTimeZero && std::all_of(placements.begin(), placements.end(), [](const Placement &p) {
            return p.destination == p.clip.trackId;
        })) {
        return EditResult::success(); // nothing moves: a no-op, not recorded
    }

    // Lift everything first, so no moved clip can cut another one of the same move.
    for (Placement &p : placements) {
        removeClip(*sequence.findTrack(p.clip.trackId), p.clip.id);
        p.clip.timelineStart = p.clip.timelineStart + delta;
        p.clip.trackId = p.destination;
    }
    for (size_t i = 0; i < placements.size(); ++i) {
        for (size_t j = i + 1; j < placements.size(); ++j) {
            if (placements[i].destination == placements[j].destination &&
                placements[i].clip.timelineRange().intersects(placements[j].clip.timelineRange())) {
                return EditResult::failure(EditError::Overlap, "the moved clips would overlap each other");
            }
        }
    }
    // Transitions whose two clips land on the same track move there with them: the whole move
    // shares one delta, so the cut between them is intact.
    std::map<ClipId, TrackId> destinationOf;
    for (const Placement &p : placements) {
        destinationOf[p.clip.id] = p.destination;
    }
    for (Transition &transition : sequence.transitions) {
        auto from = destinationOf.find(transition.fromClipId);
        auto to = destinationOf.find(transition.toClipId);
        if (from != destinationOf.end() && to != destinationOf.end() && from->second == to->second) {
            transition.trackId = from->second;
        }
    }
    SplitList splits;
    for (Placement &p : placements) {
        Track &target = *sequence.findTrack(p.destination);
        if (EditResult r = clearRange(sequence, target, p.clip.timelineRange(), ids, splits); !r) {
            return r;
        }
        insertClipSorted(target, std::move(p.clip));
    }
    relinkSplitPieces(sequence, splits);
    return EditResult::success();
}

} // namespace ve::facade
