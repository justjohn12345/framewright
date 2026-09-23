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

EditResult notRepresentable(ClipId clipId, CMTime at) {
    return EditResult::failure(EditError::NotRepresentable,
                               "the exact source time of clip " + std::to_string(clipId.value()) + " at " +
                                   describe(at) + " has no CMTime form (its timescale would exceed 2^31 - 1)");
}

EditResult splitClipAt(Sequence &sequence, Track &track, std::size_t index, CMTime at, IdGenerator &ids,
                       ClipId &rightId) {
    Clip left = track.clips[index];
    Clip right = track.clips[index];
    if (left.video.isAnimated()) {
        // Each piece keeps the keyframes on its side of the cut (source time `cut`), the cut itself
        // interpolated, so neither piece's pictures change (Keyframes.h, splitTrack).
        const auto source = left.exactSourceTimeAt(at);
        const auto cut = source ? source->toTime() : std::nullopt;
        if (!cut) {
            return notRepresentable(left.id, at);
        }
        for (const MotionParameter parameter : kMotionParameters) {
            TrackSplit pieces = splitTrack(left.video.keyframes.track(parameter), left.video.staticValue(parameter), *cut);
            left.video.keyframes.track(parameter) = std::move(pieces.left);
            left.video.setStaticValue(parameter, pieces.leftStatic);
            right.video.keyframes.track(parameter) = std::move(pieces.right);
            right.video.setStaticValue(parameter, pieces.rightStatic);
        }
    }
    right.linkedClipId.reset();
    right.audio.fadeInDuration = kCMTimeZero;
    if (!right.setTimelineStartKeepingEnd(at)) {
        return notRepresentable(left.id, at);
    }
    left.audio.fadeOutDuration = kCMTimeZero;
    if (!left.setTimelineEnd(at)) {
        return notRepresentable(left.id, at);
    }
    right.id = ids.make<ClipId>();
    for (Transition &transition : sequence.transitions) {
        if (transition.fromClipId == left.id) {
            transition.fromClipId = right.id;
        }
    }
    rightId = right.id;
    track.clips[index] = std::move(left);
    track.clips.insert(track.clips.begin() + static_cast<std::ptrdiff_t>(index) + 1, std::move(right));
    return EditResult::success();
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

EditResult clearRange(Sequence &sequence, Track &track, const TimeRange &range, IdGenerator &ids, SplitList &splits) {
    if (range.isEmpty()) {
        return EditResult::success();
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
            ClipId right;
            if (EditResult r = splitClipAt(sequence, track, i, range.end, ids, right); !r) {
                return r;
            }
            splits.emplace_back(original, right);
            if (!track.clips[i].setTimelineEnd(range.start)) {
                return notRepresentable(original, range.start);
            }
            i += 2;
            continue;
        }
        if (clipRange.start < range.start) {
            if (!clip.setTimelineEnd(range.start)) {
                return notRepresentable(clip.id, range.start);
            }
        } else if (!clip.setTimelineStartKeepingEnd(range.end)) {
            return notRepresentable(clip.id, range.end);
        }
        ++i;
    }
    track.sortClips();
    return EditResult::success();
}

void shiftClips(Track &track, CMTime from, CMTime delta) {
    for (Clip &clip : track.clips) {
        if (clip.timelineStart >= from) {
            clip.timelineStart = clip.timelineStart + delta;
        }
    }
    track.sortClips();
}

EditResult rippleTracks(const Sequence &sequence, RippleScope scope, const std::vector<TrackId> &seeds, CMTime from,
                        std::unordered_set<TrackId> &out) {
    out.clear();
    std::vector<TrackId> pending;
    auto add = [&](const Track &track) {
        if (out.insert(track.id).second) {
            pending.push_back(track.id);
        }
    };
    for (const TrackId trackId : seeds) {
        const Track *track = sequence.findTrack(trackId);
        if (EditResult r = requireEditableTrack(track, trackId); !r) {
            return r;
        }
        add(*track);
    }
    if (scope == RippleScope::AllUnlockedTracks) {
        for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
            for (const Track &track : sequence.tracks(kind)) {
                if (!track.locked) {
                    add(track);
                }
            }
        }
    }
    // A linked pair with material after `from` on both sides must ripple on both tracks.
    while (!pending.empty()) {
        const Track &track = *sequence.findTrack(pending.back());
        pending.pop_back();
        for (const Clip &clip : track.clips) {
            if (!clip.linkedClipId || !(from < clip.timelineEnd())) {
                continue;
            }
            const Track *partnerTrack = sequence.trackOfClip(*clip.linkedClipId);
            const Clip *partner = partnerTrack ? partnerTrack->find(*clip.linkedClipId) : nullptr;
            if (!partner || !(from < partner->timelineEnd()) || out.count(partnerTrack->id)) {
                continue;
            }
            if (scope == RippleScope::AllUnlockedTracks || partnerTrack->locked) {
                return EditResult::failure(EditError::TrackLocked,
                                           "clip " + std::to_string(clip.id.value()) + " is linked to clip " +
                                               std::to_string(partner->id.value()) + " on locked track \"" +
                                               partnerTrack->name + "\", which cannot move with it");
            }
            add(*partnerTrack);
        }
    }
    return EditResult::success();
}

EditResult openTime(Sequence &sequence, const std::unordered_set<TrackId> &tracks, CMTime at, CMTime delta,
                    IdGenerator &ids, SplitList &splits) {
    SplitList local;
    for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (Track &track : *list) {
            if (!tracks.count(track.id)) {
                continue;
            }
            if (const auto index = track.clipIndexAt(at); index && track.clips[*index].timelineStart < at) {
                const ClipId original = track.clips[*index].id;
                ClipId right;
                if (EditResult r = splitClipAt(sequence, track, *index, at, ids, right); !r) {
                    return r;
                }
                local.emplace_back(original, right);
            }
        }
    }
    // A split clip whose partner lies wholly after `at` moves its link to the right piece, which
    // moves with the partner. (Partners that were split too are paired by relinkSplitPieces.)
    std::unordered_set<ClipId> splitOriginals;
    for (const auto &[original, right] : local) {
        splitOriginals.insert(original);
    }
    for (const auto &[original, right] : local) {
        Clip *left = sequence.findClip(original);
        if (!left->linkedClipId || splitOriginals.count(*left->linkedClipId)) {
            continue;
        }
        Clip *partner = sequence.findClip(*left->linkedClipId);
        if (partner && partner->timelineStart >= at) {
            sequence.findClip(right)->linkedClipId = partner->id;
            partner->linkedClipId = right;
            left->linkedClipId.reset();
        }
    }
    for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (Track &track : *list) {
            if (tracks.count(track.id)) {
                shiftClips(track, at, delta);
            }
        }
    }
    splits.insert(splits.end(), local.begin(), local.end());
    return EditResult::success();
}

EditResult closeTime(Sequence &sequence, const std::unordered_set<TrackId> &tracks,
                     const std::vector<TimeRange> &ranges) {
    for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (Track &track : *list) {
            if (!tracks.count(track.id)) {
                continue;
            }
            for (const Clip &clip : track.clips) {
                for (const TimeRange &range : ranges) {
                    if (clip.timelineRange().intersects(range)) {
                        return EditResult::failure(EditError::Overlap,
                                                   "clip " + std::to_string(clip.id.value()) + " on track \"" +
                                                       track.name + "\" overlaps the time the edit closes (" +
                                                       describe(range.start) + " - " + describe(range.end) +
                                                       "); ripple fewer tracks or clear that time first");
                    }
                }
            }
        }
    }
    for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (Track &track : *list) {
            if (!tracks.count(track.id)) {
                continue;
            }
            for (Clip &clip : track.clips) {
                CMTime removed = kCMTimeZero;
                for (const TimeRange &range : ranges) {
                    if (range.end <= clip.timelineStart) {
                        removed = removed + range.duration();
                    }
                }
                clip.timelineStart = clip.timelineStart - removed;
            }
            track.sortClips();
        }
    }
    return EditResult::success();
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
