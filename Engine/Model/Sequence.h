// A sequence (timeline): video and audio tracks plus the transitions between their clips.

#pragma once

#include "Ids.h"
#include "TimeUtil.h"
#include "Track.h"
#include "Transition.h"

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace ve {

// Where a clip lives inside a sequence.
struct ClipLocation {
    TrackKind trackKind = TrackKind::Video;
    std::size_t trackIndex = 0; // index into videoTracks or audioTracks
    std::size_t clipIndex = 0;  // index into that track's clips
};

struct Sequence {
    SequenceId id;
    std::string name;
    CMTime frameDuration = CMTimeMake(1, 30); // the timeline frame grid
    std::int32_t width = 1920;
    std::int32_t height = 1080;
    std::int32_t audioSampleRate = 48000;
    std::vector<Track> videoTracks; // bottom to top (later tracks draw over earlier ones)
    std::vector<Track> audioTracks;
    std::vector<Transition> transitions;

    // End of the last clip on any track.
    CMTime duration() const;

    std::vector<Track> &tracks(TrackKind kind) {
        return kind == TrackKind::Video ? videoTracks : audioTracks;
    }
    const std::vector<Track> &tracks(TrackKind kind) const {
        return kind == TrackKind::Video ? videoTracks : audioTracks;
    }

    const Track *findTrack(TrackId trackId) const;
    Track *findTrack(TrackId trackId);

    std::optional<ClipLocation> locateClip(ClipId clipId) const;
    const Clip *findClip(ClipId clipId) const;
    Clip *findClip(ClipId clipId);
    // The track holding `clipId`, or nullptr.
    const Track *trackOfClip(ClipId clipId) const;
    Track *trackOfClip(ClipId clipId);

    const Transition *findTransition(TransitionId transitionId) const;
    // The transition on the cut where `clipId` is the outgoing / incoming clip.
    const Transition *transitionFrom(ClipId clipId) const;
    const Transition *transitionTo(ClipId clipId) const;

    // Timeline range covered by a transition, or nullopt when its outgoing clip is missing.
    std::optional<TimeRange> transitionRange(const Transition &transition) const;

    // Transition on `trackId` whose range contains `t`, if any.
    const Transition *transitionAt(TrackId trackId, CMTime t) const;
};

// Bit-for-bit equality of every field.
bool operator==(const Sequence &a, const Sequence &b);

} // namespace ve
