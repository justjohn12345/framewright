#include "EditPrimitives.h"

#include "../Model/Validation.h"

#include <algorithm>
#include <unordered_map>
#include <unordered_set>

namespace ve {

CMTime snapToSequence(const Sequence &sequence, CMTime t, SnapMode mode) {
    return snapToFrame(t, sequence.frameDuration, mode);
}

EditResult requireEditableTrack(const Track *track, TrackId trackId) {
    if (!track) {
        return EditResult::failure(EditError::TrackNotFound,
                                   "track " + std::to_string(trackId.value()) + " does not exist");
    }
    if (track->locked) {
        return EditResult::failure(EditError::TrackLocked, "track \"" + track->name + "\" is locked");
    }
    return EditResult::success();
}

EditResult findEditableClip(Sequence &sequence, ClipId clipId, Track *&track, Clip *&clip) {
    track = sequence.trackOfClip(clipId);
    clip = track ? track->find(clipId) : nullptr;
    if (!clip) {
        return EditResult::failure(EditError::ClipNotFound,
                                   "clip " + std::to_string(clipId.value()) + " does not exist");
    }
    return requireEditableTrack(track, track->id);
}

void insertClipSorted(Track &track, Clip clip) {
    const std::size_t index = track.firstClipStartingAtOrAfter(clip.timelineStart);
    track.clips.insert(track.clips.begin() + static_cast<std::ptrdiff_t>(index), std::move(clip));
}

Clip removeClip(Track &track, ClipId clipId) {
    const std::size_t index = *track.indexOf(clipId);
    Clip clip = std::move(track.clips[index]);
    track.clips.erase(track.clips.begin() + static_cast<std::ptrdiff_t>(index));
    return clip;
}

ClipId splitClipAt(Sequence &sequence, Track &track, std::size_t index, CMTime at, IdGenerator &ids) {
    Clip right = track.clips[index];
    Clip &left = track.clips[index];
    right.id = ids.make<ClipId>();
    right.linkedClipId.reset();
    right.setTimelineStartKeepingEnd(at);
    right.audio.fadeInDuration = kCMTimeZero;
    left.setTimelineEnd(at);
    left.audio.fadeOutDuration = kCMTimeZero;
    for (Transition &transition : sequence.transitions) {
        if (transition.fromClipId == left.id) {
            transition.fromClipId = right.id;
        }
    }
    const ClipId rightId = right.id;
    track.clips.insert(track.clips.begin() + static_cast<std::ptrdiff_t>(index) + 1, std::move(right));
    return rightId;
}

void relinkSplitPieces(Sequence &sequence, const SplitList &splits) {
    std::unordered_map<ClipId, ClipId> rightOf;
    for (const auto &[original, right] : splits) {
        rightOf[original] = right;
    }
    for (const auto &[original, right] : splits) {
        const Clip *left = sequence.findClip(original);
        if (!left || !left->linkedClipId) {
            continue;
        }
        const auto partnerRight = rightOf.find(*left->linkedClipId);
        if (partnerRight == rightOf.end()) {
            continue;
        }
        if (Clip *rightClip = sequence.findClip(right)) {
            rightClip->linkedClipId = partnerRight->second;
        }
    }
}

void clearRange(Sequence &sequence, Track &track, const TimeRange &range, IdGenerator &ids, SplitList &splits) {
    if (range.isEmpty()) {
        return;
    }
    std::size_t i = 0;
    while (i < track.clips.size()) {
        Clip &clip = track.clips[i];
        const TimeRange clipRange = clip.timelineRange();
        if (!clipRange.intersects(range)) {
            ++i;
            continue;
        }
        if (range.contains(clipRange)) {
            track.clips.erase(track.clips.begin() + static_cast<std::ptrdiff_t>(i));
            continue;
        }
        if (clipRange.start < range.start && range.end < clipRange.end) {
            // The range lands inside the clip: split at its end, then trim the left piece.
            const ClipId original = clip.id;
            const ClipId right = splitClipAt(sequence, track, i, range.end, ids);
            splits.emplace_back(original, right);
            track.clips[i].setTimelineEnd(range.start);
            i += 2;
            continue;
        }
        if (clipRange.start < range.start) {
            clip.setTimelineEnd(range.start);
        } else {
            clip.setTimelineStartKeepingEnd(range.end);
        }
        ++i;
    }
    track.sortClips();
}

void shiftClips(Track &track, CMTime from, CMTime delta) {
    for (Clip &clip : track.clips) {
        if (clip.timelineStart >= from) {
            clip.timelineStart = clip.timelineStart + delta;
        }
    }
    track.sortClips();
}

void normalizeSequence(Sequence &sequence, const Project &project) {
    for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (Track &track : *list) {
            track.sortClips();
        }
    }

    // Links: partner must exist, be another clip on another track, and link back.
    std::unordered_map<ClipId, std::optional<ClipId>> links;
    std::unordered_map<ClipId, TrackId> trackOf;
    for (const std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (const Track &track : *list) {
            for (const Clip &clip : track.clips) {
                links[clip.id] = clip.linkedClipId;
                trackOf[clip.id] = track.id;
            }
        }
    }
    for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (Track &track : *list) {
            for (Clip &clip : track.clips) {
                if (!clip.linkedClipId) {
                    continue;
                }
                const ClipId partner = *clip.linkedClipId;
                const auto partnerLink = links.find(partner);
                const bool valid = partner != clip.id && partnerLink != links.end() && partnerLink->second == clip.id &&
                                   trackOf[partner] != track.id;
                if (!valid) {
                    clip.linkedClipId.reset();
                }
            }
        }
    }

    // Transitions: drop invalid ones, then ones conflicting with an earlier kept transition.
    std::vector<Transition> kept;
    std::unordered_map<ClipId, TimeRange> outgoing; // clip -> range of the transition at its end
    std::unordered_map<ClipId, TimeRange> incoming; // clip -> range of the transition at its start
    for (const Transition &transition : sequence.transitions) {
        if (checkTransition(sequence, project, transition)) {
            continue;
        }
        const TimeRange range = *sequence.transitionRange(transition);
        if (outgoing.count(transition.fromClipId) || incoming.count(transition.toClipId)) {
            continue;
        }
        const auto fromHead = incoming.find(transition.fromClipId);
        if (fromHead != incoming.end() && fromHead->second.end > range.start) {
            continue;
        }
        const auto toTail = outgoing.find(transition.toClipId);
        if (toTail != outgoing.end() && range.end > toTail->second.start) {
            continue;
        }
        outgoing.emplace(transition.fromClipId, range);
        incoming.emplace(transition.toClipId, range);
        kept.push_back(transition);
    }
    sequence.transitions = std::move(kept);
}

} // namespace ve
