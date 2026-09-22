#include "Track.h"

#include <algorithm>

namespace ve {

const char *nameOf(TrackKind kind) {
    switch (kind) {
    case TrackKind::Video:
        return "video";
    case TrackKind::Audio:
        return "audio";
    }
    return "unknown";
}

bool operator==(const Track &a, const Track &b) {
    return a.id == b.id && a.kind == b.kind && a.name == b.name && a.muted == b.muted && a.solo == b.solo &&
           a.locked == b.locked && a.clips == b.clips;
}

std::optional<std::size_t> Track::indexOf(ClipId clipId) const {
    for (std::size_t i = 0; i < clips.size(); ++i) {
        if (clips[i].id == clipId) {
            return i;
        }
    }
    return std::nullopt;
}

const Clip *Track::find(ClipId clipId) const {
    const auto index = indexOf(clipId);
    return index ? &clips[*index] : nullptr;
}

Clip *Track::find(ClipId clipId) {
    const auto index = indexOf(clipId);
    return index ? &clips[*index] : nullptr;
}

std::size_t Track::firstClipStartingAtOrAfter(CMTime t) const {
    const auto it =
        std::partition_point(clips.begin(), clips.end(), [t](const Clip &clip) { return clip.timelineStart < t; });
    return static_cast<std::size_t>(it - clips.begin());
}

std::optional<std::size_t> Track::clipIndexAt(CMTime t) const {
    // Last clip whose start <= t.
    const auto it =
        std::partition_point(clips.begin(), clips.end(), [t](const Clip &clip) { return clip.timelineStart <= t; });
    if (it == clips.begin()) {
        return std::nullopt;
    }
    const auto index = static_cast<std::size_t>(it - clips.begin()) - 1;
    if (t < clips[index].timelineEnd()) {
        return index;
    }
    return std::nullopt;
}

const Clip *Track::clipAt(CMTime t) const {
    const auto index = clipIndexAt(t);
    return index ? &clips[*index] : nullptr;
}

CMTime Track::end() const {
    // Clips are sorted and never overlap, so the last one ends last.
    return clips.empty() ? kCMTimeZero : maxTime(kCMTimeZero, clips.back().timelineEnd());
}

void Track::sortClips() {
    std::stable_sort(clips.begin(), clips.end(),
                     [](const Clip &a, const Clip &b) { return a.timelineStart < b.timelineStart; });
}

std::optional<std::string> Track::checkInvariants() const {
    const std::string where = "track " + std::to_string(id.value());
    if (!id) {
        return where + ": invalid id";
    }
    for (std::size_t i = 0; i < clips.size(); ++i) {
        const Clip &clip = clips[i];
        const std::string clipWhere = where + ", clip " + std::to_string(clip.id.value());
        if (!clip.id) {
            return clipWhere + ": invalid id";
        }
        if (clip.trackId != id) {
            return clipWhere + ": trackId is " + std::to_string(clip.trackId.value());
        }
        if (!isNumeric(clip.timelineStart) || !isNumeric(clip.sourceIn) || !isNumeric(clip.sourceOut)) {
            return clipWhere + ": non-numeric time";
        }
        if (!(clip.sourceIn < clip.sourceOut)) {
            return clipWhere + ": empty source range";
        }
        if (clip.timelineStart < kCMTimeZero) {
            return clipWhere + ": starts before zero at " + describe(clip.timelineStart);
        }
        if (i > 0) {
            const Clip &previous = clips[i - 1];
            if (clip.timelineStart < previous.timelineStart) {
                return clipWhere + ": clips are not sorted by start";
            }
            if (clip.timelineStart < previous.timelineEnd()) {
                return clipWhere + ": overlaps clip " + std::to_string(previous.id.value()) + " (starts " +
                       describe(clip.timelineStart) + ", previous ends " + describe(previous.timelineEnd()) + ")";
            }
        }
    }
    return std::nullopt;
}

} // namespace ve
