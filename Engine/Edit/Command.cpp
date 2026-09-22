#include "Command.h"

#include "../Model/Validation.h"
#include "EditPrimitives.h"

#include <unordered_map>
#include <utility>

namespace ve {

namespace {

std::vector<TrackId> trackOrder(const std::vector<Track> &tracks) {
    std::vector<TrackId> order;
    order.reserve(tracks.size());
    for (const Track &track : tracks) {
        order.push_back(track.id);
    }
    return order;
}

const Track *findIn(const Sequence &sequence, TrackId trackId) {
    return sequence.findTrack(trackId);
}

} // namespace

SequencePatch diffSequences(const Sequence &before, const Sequence &after, const IdGenerator &idsBefore,
                            const IdGenerator &idsAfter) {
    SequencePatch patch;
    patch.sequenceId = before.id;
    patch.idsBefore = idsBefore;
    patch.idsAfter = idsAfter;

    for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
        for (const Track &oldTrack : before.tracks(kind)) {
            const Track *newTrack = findIn(after, oldTrack.id);
            if (!newTrack) {
                patch.tracks.push_back(TrackSnapshot{oldTrack.id, oldTrack, std::nullopt});
            } else if (!(*newTrack == oldTrack)) {
                patch.tracks.push_back(TrackSnapshot{oldTrack.id, oldTrack, *newTrack});
            }
        }
    }
    for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
        for (const Track &newTrack : after.tracks(kind)) {
            if (!findIn(before, newTrack.id)) {
                patch.tracks.push_back(TrackSnapshot{newTrack.id, std::nullopt, newTrack});
            }
        }
    }

    patch.videoOrderBefore = trackOrder(before.videoTracks);
    patch.videoOrderAfter = trackOrder(after.videoTracks);
    patch.audioOrderBefore = trackOrder(before.audioTracks);
    patch.audioOrderAfter = trackOrder(after.audioTracks);
    patch.trackOrderChanged =
        patch.videoOrderBefore != patch.videoOrderAfter || patch.audioOrderBefore != patch.audioOrderAfter;
    if (!patch.trackOrderChanged) {
        patch.videoOrderBefore.clear();
        patch.videoOrderAfter.clear();
        patch.audioOrderBefore.clear();
        patch.audioOrderAfter.clear();
    }

    if (!(before.transitions == after.transitions)) {
        patch.transitionsChanged = true;
        patch.transitionsBefore = before.transitions;
        patch.transitionsAfter = after.transitions;
    }
    return patch;
}

void applyPatch(Sequence &sequence, IdGenerator &ids, const SequencePatch &patch, PatchDirection direction) {
    const bool forward = direction == PatchDirection::Forward;
    auto target = [forward](const TrackSnapshot &snapshot) -> const std::optional<Track> & {
        return forward ? snapshot.after : snapshot.before;
    };

    if (patch.trackOrderChanged) {
        std::unordered_map<TrackId, Track> pool;
        for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
            for (Track &track : *list) {
                const TrackId trackId = track.id;
                pool.emplace(trackId, std::move(track));
            }
            list->clear();
        }
        for (const TrackSnapshot &snapshot : patch.tracks) {
            pool.erase(snapshot.trackId);
            if (const auto &track = target(snapshot)) {
                pool.emplace(snapshot.trackId, *track);
            }
        }
        const auto &videoOrder = forward ? patch.videoOrderAfter : patch.videoOrderBefore;
        const auto &audioOrder = forward ? patch.audioOrderAfter : patch.audioOrderBefore;
        for (const TrackId trackId : videoOrder) {
            sequence.videoTracks.push_back(std::move(pool.at(trackId)));
        }
        for (const TrackId trackId : audioOrder) {
            sequence.audioTracks.push_back(std::move(pool.at(trackId)));
        }
    } else {
        for (const TrackSnapshot &snapshot : patch.tracks) {
            Track *track = sequence.findTrack(snapshot.trackId);
            const auto &replacement = target(snapshot);
            if (track && replacement) {
                *track = *replacement;
            }
        }
    }

    if (patch.transitionsChanged) {
        sequence.transitions = forward ? patch.transitionsAfter : patch.transitionsBefore;
    }
    ids = forward ? patch.idsAfter : patch.idsBefore;
}

SequencePatch composePatches(const SequencePatch &first, const SequencePatch &second) {
    SequencePatch result;
    result.sequenceId = first.sequenceId;
    result.idsBefore = first.idsBefore;
    result.idsAfter = second.idsAfter;

    for (const TrackSnapshot &a : first.tracks) {
        TrackSnapshot combined = a;
        for (const TrackSnapshot &b : second.tracks) {
            if (b.trackId == a.trackId) {
                combined.after = b.after;
                break;
            }
        }
        result.tracks.push_back(std::move(combined));
    }
    for (const TrackSnapshot &b : second.tracks) {
        bool inFirst = false;
        for (const TrackSnapshot &a : first.tracks) {
            if (a.trackId == b.trackId) {
                inFirst = true;
                break;
            }
        }
        if (!inFirst) {
            result.tracks.push_back(b);
        }
    }

    if (first.trackOrderChanged || second.trackOrderChanged) {
        result.trackOrderChanged = true;
        const SequencePatch &from = first.trackOrderChanged ? first : second;
        const SequencePatch &to = second.trackOrderChanged ? second : first;
        result.videoOrderBefore = from.videoOrderBefore;
        result.audioOrderBefore = from.audioOrderBefore;
        result.videoOrderAfter = to.videoOrderAfter;
        result.audioOrderAfter = to.audioOrderAfter;
    }
    if (first.transitionsChanged || second.transitionsChanged) {
        result.transitionsChanged = true;
        result.transitionsBefore = first.transitionsChanged ? first.transitionsBefore : second.transitionsBefore;
        result.transitionsAfter = second.transitionsChanged ? second.transitionsAfter : first.transitionsAfter;
    }
    return result;
}

EditResult SequenceCommand::apply(Project &project) {
    Sequence *sequence = project.findSequence(sequenceId_);
    if (!sequence) {
        return EditResult::failure(EditError::SequenceNotFound,
                                   "sequence " + std::to_string(sequenceId_.value()) + " does not exist");
    }
    if (patch_) {
        applyPatch(*sequence, project.ids, *patch_, PatchDirection::Forward);
        return EditResult::success();
    }

    Sequence working = *sequence;
    IdGenerator ids = project.ids;
    EditResult result = perform(project, working, ids);
    if (!result) {
        return result;
    }
    normalizeSequence(working, project);
    if (auto problem = validateSequence(working, project)) {
        return EditResult::failure(EditError::InvariantViolation,
                                   name() + " would leave an invalid sequence: " + *problem);
    }
    patch_ = diffSequences(*sequence, working, project.ids, ids);
    *sequence = std::move(working);
    project.ids = ids;
    return result;
}

void SequenceCommand::revert(Project &project) {
    Sequence *sequence = project.findSequence(sequenceId_);
    if (!sequence || !patch_) {
        return;
    }
    applyPatch(*sequence, project.ids, *patch_, PatchDirection::Backward);
}

bool SequenceCommand::mergeWith(const Command &next) {
    const auto *other = dynamic_cast<const SequenceCommand *>(&next);
    if (!other || other->sequenceId_ != sequenceId_ || !patch_ || !other->patch_) {
        return false;
    }
    patch_ = composePatches(*patch_, *other->patch_);
    return true;
}

} // namespace ve
