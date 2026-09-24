#include "Command.h"

#include "../Model/Validation.h"
#include "EditPrimitives.h"

#include <algorithm>
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

    return patch;
}

bool patchApplies(const Sequence &sequence, const IdGenerator &ids, const SequencePatch &patch,
                  PatchDirection direction) {
    const bool forward = direction == PatchDirection::Forward;
    if (sequence.id != patch.sequenceId || !(ids == (forward ? patch.idsBefore : patch.idsAfter))) {
        return false;
    }
    for (const TrackSnapshot &snapshot : patch.tracks) {
        const std::optional<Track> &source = forward ? snapshot.before : snapshot.after;
        const Track *current = sequence.findTrack(snapshot.trackId);
        if (source.has_value() != (current != nullptr) || (current && !(*current == *source))) {
            return false;
        }
    }
    if (patch.trackOrderChanged) {
        if (trackOrder(sequence.videoTracks) != (forward ? patch.videoOrderBefore : patch.videoOrderAfter) ||
            trackOrder(sequence.audioTracks) != (forward ? patch.audioOrderBefore : patch.audioOrderAfter)) {
            return false;
        }
    }
    return true;
}

bool applyPatch(Sequence &sequence, IdGenerator &ids, const SequencePatch &patch, PatchDirection direction) {
    if (!patchApplies(sequence, ids, patch, direction)) {
        return false;
    }
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
        // patchApplies() checked the source order, so every id of the target order is pooled.
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

    ids = forward ? patch.idsAfter : patch.idsBefore;
    return true;
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
        if (combined.before != combined.after) { // a track changed and changed back is not in the patch
            result.tracks.push_back(std::move(combined));
        }
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
        if (result.videoOrderBefore == result.videoOrderAfter && result.audioOrderBefore == result.audioOrderAfter) {
            result.trackOrderChanged = false;
            result.videoOrderBefore.clear();
            result.videoOrderAfter.clear();
            result.audioOrderBefore.clear();
            result.audioOrderAfter.clear();
        }
    }
    return result;
}

namespace {

// Refusal if the change touches a locked track: its clips (and their spans) or properties, or
// its existence.
std::optional<EditResult> lockedTrackChange(const SequencePatch &patch) {
    for (const TrackSnapshot &snapshot : patch.tracks) {
        if (snapshot.before && snapshot.before->locked) {
            return EditResult::failure(EditError::TrackLocked, "track \"" + snapshot.before->name + "\" is locked" +
                                                                   (snapshot.after ? "" : " and cannot be removed"));
        }
    }
    return std::nullopt;
}

struct SpanRecord {
    SpanId id;
    ClipId clip;
    bool transition = false;
};

std::vector<SpanRecord> spanRecords(const Sequence &sequence) {
    std::vector<SpanRecord> records;
    for (const std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (const Track &track : *list) {
            for (const Clip &clip : track.clips) {
                for (const EffectSpan &span : clip.spans) {
                    records.push_back(SpanRecord{span.id, clip.id, span.isTransition()});
                }
            }
        }
    }
    return records;
}

} // namespace

EditResult SequenceCommand::apply(Project &project) {
    Sequence *sequence = project.findSequence(sequenceId_);
    if (!sequence) {
        return EditResult::failure(EditError::SequenceNotFound,
                                   "sequence " + std::to_string(sequenceId_.value()) + " does not exist");
    }
    if (patch_) {
        if (!applyPatch(*sequence, project.ids, *patch_, PatchDirection::Forward)) {
            return EditResult::failure(EditError::InvariantViolation,
                                       name() + " cannot be redone: the sequence no longer matches its starting state");
        }
        EditResult redone = EditResult::success();
        redone.droppedTransitionIds = droppedTransitions_;
        redone.droppedSpanIds = droppedSpans_;
        return redone;
    }

    Sequence working = *sequence;
    IdGenerator ids = project.ids;
    removedOnPurpose_.clear();
    EditResult result = perform(project, working, ids);
    if (!result) {
        return result;
    }
    normalizeSequence(working, project);
    if (auto problem = validateSequence(working, project)) {
        return EditResult::failure(EditError::InvariantViolation,
                                   name() + " would leave an invalid sequence: " + *problem);
    }
    SequencePatch patch = diffSequences(*sequence, working, project.ids, ids);
    if (!mayEditLockedTracks()) {
        if (auto refusal = lockedTrackChange(patch)) {
            return *refusal;
        }
    }
    // Spans that went as a side effect: not removed on purpose, and not effect spans that left
    // with their clip.
    droppedTransitions_.clear();
    droppedSpans_.clear();
    for (const SpanRecord &record : spanRecords(*sequence)) {
        if (working.findSpan(record.id) != nullptr ||
            std::find(removedOnPurpose_.begin(), removedOnPurpose_.end(), record.id) != removedOnPurpose_.end()) {
            continue;
        }
        if (record.transition) {
            droppedTransitions_.push_back(record.id);
        } else if (working.findClip(record.clip) != nullptr) {
            droppedSpans_.push_back(record.id);
        }
    }
    patch_ = std::move(patch);
    *sequence = std::move(working);
    project.ids = ids;
    result.droppedTransitionIds = droppedTransitions_;
    result.droppedSpanIds = droppedSpans_;
    return result;
}

void SequenceCommand::revert(Project &project) {
    Sequence *sequence = project.findSequence(sequenceId_);
    if (!sequence || !patch_) {
        return;
    }
    (void)applyPatch(*sequence, project.ids, *patch_, PatchDirection::Backward);
}

bool SequenceCommand::canRevert(const Project &project) const {
    const Sequence *sequence = project.findSequence(sequenceId_);
    return sequence && patch_ && patchApplies(*sequence, project.ids, *patch_, PatchDirection::Backward);
}

bool SequenceCommand::isNoOp() const {
    return patch_ && patch_->isEmpty();
}

bool SequenceCommand::mergeWith(const Command &next) {
    const auto *other = dynamic_cast<const SequenceCommand *>(&next);
    if (!other || other->sequenceId_ != sequenceId_ || !patch_ || !other->patch_) {
        return false;
    }
    patch_ = composePatches(*patch_, *other->patch_);
    droppedTransitions_.insert(droppedTransitions_.end(), other->droppedTransitions_.begin(),
                               other->droppedTransitions_.end());
    droppedSpans_.insert(droppedSpans_.end(), other->droppedSpans_.begin(), other->droppedSpans_.end());
    return true;
}

} // namespace ve
