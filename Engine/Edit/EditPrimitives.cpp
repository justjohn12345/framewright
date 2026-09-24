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

EditResult retimeRefusal(RetimeResult result, ClipId clipId, CMTime at) {
    switch (result) {
    case RetimeResult::Ok:
        return EditResult::success();
    case RetimeResult::NotRepresentable:
        return notRepresentable(clipId, at);
    case RetimeResult::SpanCurveOvershoot:
        break;
    }
    return EditResult::failure(EditError::InvalidArgument,
                               "clip " + std::to_string(clipId.value()) + " cannot be cut at " + describe(at) +
                                   ": a span's custom timing curve goes outside its parameter's range there, so the "
                                   "cut would change the picture");
}

EditResult splitClipAt(Sequence &, Track &track, std::size_t index, CMTime at, IdGenerator &ids, ClipId &rightId) {
    Clip left = track.clips[index];
    Clip right = track.clips[index];
    // Lane 0: the head span stays with the left piece, the tail span goes with the right one.
    std::erase_if(left.spans, [](const EffectSpan &span) { return span.isTransition() && span.edge == ClipEdge::Tail; });
    std::erase_if(right.spans, [](const EffectSpan &span) { return span.isTransition() && span.edge == ClipEdge::Head; });
    right.linkedClipId.reset();
    // Each piece clips the effect spans to its own source range (fitSpans): a span across the cut
    // is divided exactly, the value at the cut evaluated.
    if (EditResult r = retimeRefusal(right.setTimelineStartKeepingEnd(at), left.id, at); !r) {
        return r;
    }
    if (EditResult r = retimeRefusal(left.setTimelineEnd(at), left.id, at); !r) {
        return r;
    }
    right.id = ids.make<ClipId>();
    // A span divided by the cut is on both pieces: the right piece's part gets a new id.
    for (EffectSpan &span : right.spans) {
        if (!span.isTransition() && left.findSpan(span.id) != nullptr) {
            span.id = ids.make<SpanId>();
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
            if (EditResult r = retimeRefusal(track.clips[i].setTimelineEnd(range.start), original, range.start); !r) {
                return r;
            }
            i += 2;
            continue;
        }
        if (clipRange.start < range.start) {
            if (EditResult r = retimeRefusal(clip.setTimelineEnd(range.start), clip.id, range.start); !r) {
                return r;
            }
        } else if (EditResult r = retimeRefusal(clip.setTimelineStartKeepingEnd(range.end), clip.id, range.end); !r) {
            return r;
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

    // Spans in order; transition spans that are no longer valid go. Two transitions that meet (a
    // cross dissolve into a clip whose own tail span it now reaches) are resolved from the right:
    // the later clip's span is checked first and kept.
    for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (Track &track : *list) {
            for (Clip &clip : track.clips) {
                clip.sortSpans();
            }
            for (std::size_t i = track.clips.size(); i-- > 0;) {
                Clip &clip = track.clips[i];
                for (const ClipEdge edge : {ClipEdge::Tail, ClipEdge::Head}) {
                    const EffectSpan *span = clip.transitionAt(edge);
                    if (span != nullptr &&
                        checkTransitionSpan(project, track, clip, *span, sequence.frameDuration).has_value()) {
                        const SpanId id = span->id;
                        std::erase_if(clip.spans, [id](const EffectSpan &s) { return s.id == id; });
                    }
                }
            }
        }
    }
}

} // namespace ve
