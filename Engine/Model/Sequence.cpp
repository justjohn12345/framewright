#include "Sequence.h"

namespace ve {

bool operator==(const Sequence &a, const Sequence &b) {
    return a.id == b.id && a.name == b.name && identical(a.frameDuration, b.frameDuration) && a.width == b.width &&
           a.height == b.height && a.audioSampleRate == b.audioSampleRate && a.videoTracks == b.videoTracks &&
           a.audioTracks == b.audioTracks;
}

CMTime Sequence::duration() const {
    CMTime result = kCMTimeZero;
    for (const Track &track : videoTracks) {
        result = maxTime(result, track.end());
    }
    for (const Track &track : audioTracks) {
        result = maxTime(result, track.end());
    }
    return result;
}

const Track *Sequence::findTrack(TrackId trackId) const {
    for (const Track &track : videoTracks) {
        if (track.id == trackId) {
            return &track;
        }
    }
    for (const Track &track : audioTracks) {
        if (track.id == trackId) {
            return &track;
        }
    }
    return nullptr;
}

Track *Sequence::findTrack(TrackId trackId) {
    return const_cast<Track *>(static_cast<const Sequence *>(this)->findTrack(trackId));
}

std::optional<ClipLocation> Sequence::locateClip(ClipId clipId) const {
    for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
        const std::vector<Track> &list = tracks(kind);
        for (std::size_t t = 0; t < list.size(); ++t) {
            if (const auto index = list[t].indexOf(clipId)) {
                return ClipLocation{kind, t, *index};
            }
        }
    }
    return std::nullopt;
}

const Clip *Sequence::findClip(ClipId clipId) const {
    const auto location = locateClip(clipId);
    if (!location) {
        return nullptr;
    }
    return &tracks(location->trackKind)[location->trackIndex].clips[location->clipIndex];
}

Clip *Sequence::findClip(ClipId clipId) {
    return const_cast<Clip *>(static_cast<const Sequence *>(this)->findClip(clipId));
}

const Track *Sequence::trackOfClip(ClipId clipId) const {
    const auto location = locateClip(clipId);
    if (!location) {
        return nullptr;
    }
    return &tracks(location->trackKind)[location->trackIndex];
}

Track *Sequence::trackOfClip(ClipId clipId) {
    return const_cast<Track *>(static_cast<const Sequence *>(this)->trackOfClip(clipId));
}

const EffectSpan *Sequence::findSpan(SpanId spanId, const Clip **owner, const Track **track) const {
    for (const std::vector<Track> *list : {&videoTracks, &audioTracks}) {
        for (const Track &t : *list) {
            for (const Clip &clip : t.clips) {
                if (const EffectSpan *span = clip.findSpan(spanId)) {
                    if (owner != nullptr) {
                        *owner = &clip;
                    }
                    if (track != nullptr) {
                        *track = &t;
                    }
                    return span;
                }
            }
        }
    }
    return nullptr;
}

EffectSpan *Sequence::findSpan(SpanId spanId, Clip **owner, Track **track) {
    const Clip *constOwner = nullptr;
    const Track *constTrack = nullptr;
    const EffectSpan *span = static_cast<const Sequence *>(this)->findSpan(spanId, &constOwner, &constTrack);
    if (owner != nullptr) {
        *owner = const_cast<Clip *>(constOwner);
    }
    if (track != nullptr) {
        *track = const_cast<Track *>(constTrack);
    }
    return const_cast<EffectSpan *>(span);
}

const Clip *touchingClip(const Track &track, const Clip &clip, ClipEdge edge) {
    const auto index = track.indexOf(clip.id);
    if (!index) {
        return nullptr;
    }
    if (edge == ClipEdge::Head) {
        if (*index == 0) {
            return nullptr;
        }
        const Clip &previous = track.clips[*index - 1];
        return previous.timelineEnd() == clip.timelineStart ? &previous : nullptr;
    }
    if (*index + 1 >= track.clips.size()) {
        return nullptr;
    }
    const Clip &next = track.clips[*index + 1];
    return next.timelineStart == clip.timelineEnd() ? &next : nullptr;
}

CMTime incomingTransitionInside(const Track &track, const Clip &clip) {
    const Clip *previous = touchingClip(track, clip, ClipEdge::Head);
    if (previous == nullptr) {
        return kCMTimeZero;
    }
    const EffectSpan *tail = previous->transitionAt(ClipEdge::Tail);
    return tail != nullptr && kCMTimeZero < tail->end ? tail->end : kCMTimeZero;
}

std::optional<TransitionPlacement> placeTransition(const Track &track, const Clip &owner, const EffectSpan &span) {
    if (!span.isTransition()) {
        return std::nullopt;
    }
    TransitionPlacement placement;
    placement.track = &track;
    placement.owner = &owner;
    placement.span = &span;
    if (span.edge == ClipEdge::Head) {
        placement.role = TransitionRole::FadeIn;
        placement.cut = owner.timelineStart;
    } else {
        placement.cut = owner.timelineEnd();
        placement.role = kCMTimeZero < span.end ? TransitionRole::CrossDissolve : TransitionRole::FadeOut;
        if (placement.role == TransitionRole::CrossDissolve) {
            placement.partner = touchingClip(track, owner, ClipEdge::Tail);
        }
    }
    const auto start = checkedAdd(placement.cut, span.start);
    const auto end = checkedAdd(placement.cut, span.end);
    if (!start || !end) {
        return std::nullopt;
    }
    placement.range = TimeRange{*start, *end};
    return placement;
}

std::optional<TransitionPlacement> transitionAt(const Track &track, CMTime t) {
    const auto index = track.clipIndexAt(t);
    if (!index) {
        return std::nullopt;
    }
    const Clip &clip = track.clips[*index];
    auto covering = [&](const Clip &owner, ClipEdge edge) -> std::optional<TransitionPlacement> {
        const EffectSpan *span = owner.transitionAt(edge);
        if (span == nullptr) {
            return std::nullopt;
        }
        auto placement = placeTransition(track, owner, *span);
        if (placement && placement->range.contains(t)) {
            return placement;
        }
        return std::nullopt;
    };
    if (auto own = covering(clip, ClipEdge::Tail)) {
        return own;
    }
    if (auto head = covering(clip, ClipEdge::Head)) {
        return head;
    }
    if (const Clip *previous = touchingClip(track, clip, ClipEdge::Head)) {
        if (auto incoming = covering(*previous, ClipEdge::Tail)) {
            return incoming;
        }
    }
    return std::nullopt;
}

} // namespace ve
