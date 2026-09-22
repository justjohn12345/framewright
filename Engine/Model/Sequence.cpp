#include "Sequence.h"

namespace ve {

bool operator==(const Sequence &a, const Sequence &b) {
    return a.id == b.id && a.name == b.name && identical(a.frameDuration, b.frameDuration) && a.width == b.width &&
           a.height == b.height && a.audioSampleRate == b.audioSampleRate && a.videoTracks == b.videoTracks &&
           a.audioTracks == b.audioTracks && a.transitions == b.transitions;
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

const Transition *Sequence::findTransition(TransitionId transitionId) const {
    for (const Transition &transition : transitions) {
        if (transition.id == transitionId) {
            return &transition;
        }
    }
    return nullptr;
}

const Transition *Sequence::transitionFrom(ClipId clipId) const {
    for (const Transition &transition : transitions) {
        if (transition.fromClipId == clipId) {
            return &transition;
        }
    }
    return nullptr;
}

const Transition *Sequence::transitionTo(ClipId clipId) const {
    for (const Transition &transition : transitions) {
        if (transition.toClipId == clipId) {
            return &transition;
        }
    }
    return nullptr;
}

std::optional<TimeRange> Sequence::transitionRange(const Transition &transition) const {
    const Clip *from = findClip(transition.fromClipId);
    if (!from || !isPositive(frameDuration)) {
        return std::nullopt;
    }
    const CMTime cut = from->timelineEnd();
    const std::int64_t frames = frameIndexAt(transition.duration, frameDuration, SnapMode::Round);
    const CMTime before = timeForFrame(frames / 2, frameDuration);
    const CMTime after = timeForFrame(frames - frames / 2, frameDuration);
    return TimeRange{cut - before, cut + after};
}

const Transition *Sequence::transitionAt(TrackId trackId, CMTime t) const {
    for (const Transition &transition : transitions) {
        if (transition.trackId != trackId) {
            continue;
        }
        const auto range = transitionRange(transition);
        if (range && range->contains(t)) {
            return &transition;
        }
    }
    return nullptr;
}

} // namespace ve
