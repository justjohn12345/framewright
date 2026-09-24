// A sequence (timeline): video and audio tracks. Transitions are lane-0 spans of the clips that own
// them (Transition.h); placeTransition resolves one in its sequence.

#pragma once

#include "Ids.h"
#include "TimeUtil.h"
#include "Track.h"

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

    // The span with `spanId` on any clip, or nullptr; `owner` / `track` receive where it lives.
    const EffectSpan *findSpan(SpanId spanId, const Clip **owner = nullptr, const Track **track = nullptr) const;
    EffectSpan *findSpan(SpanId spanId, Clip **owner = nullptr, Track **track = nullptr);
};

// Bit-for-bit equality of every field.
bool operator==(const Sequence &a, const Sequence &b);

// The clip of `track` touching `clip` at `edge`: the one ending exactly where it starts (Head) or
// starting exactly where it ends (Tail); nullptr when there is none (a gap, the track's end).
const Clip *touchingClip(const Track &track, const Clip &clip, ClipEdge edge);

// A transition span resolved in its sequence.
struct TransitionPlacement {
    const Track *track = nullptr;
    const Clip *owner = nullptr;
    const EffectSpan *span = nullptr;
    TransitionRole role = TransitionRole::FadeOut;
    // CrossDissolve: the clip touching the owner's end (nullptr when none touches it: the span is
    // then invalid, see checkTransitionSpan).
    const Clip *partner = nullptr;
    CMTime cut = kCMTimeZero; // the owner's end (tail span) or start (head span)
    TimeRange range;          // the timeline range the span covers
};

// Where the lane-0 span `span` of `owner` (on `track`) acts. Nullopt when the times cannot be
// added (only for invalid spans).
std::optional<TransitionPlacement> placeTransition(const Track &track, const Clip &owner, const EffectSpan &span);

// The transition acting at timeline time `t` on `track`: the tail span of the clip at `t` or of the
// clip touching its start, or its head span, whose range contains `t`; nullopt when none does.
std::optional<TransitionPlacement> transitionAt(const Track &track, CMTime t);

} // namespace ve
