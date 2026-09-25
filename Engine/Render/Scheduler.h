// Resolves a sequence at a time (or over a time range) into render/audio graphs.
//
// Visibility rules: a muted video track is hidden and a muted audio track is silent. If any
// track of a kind is solo, only the solo tracks of that kind play (mute still applies).
// Times outside [0, sequence duration) resolve to empty graphs.
//
// Stateless and thread-compatible: safe to call concurrently on an immutable snapshot.

#pragma once

#include "../Model/Project.h"
#include "RenderGraph.h"

#include <CoreMedia/CMTimeRange.h>

#include <cstdint>
#include <optional>
#include <utility>
#include <vector>

namespace ve {

class Scheduler {
  public:
    // An eased Gain span ramp (not linear in dB) is followed by AudioSegments of at most this
    // length, each linear in dB between the ramp's exact values at its ends.
    static constexpr double kEasedGainStep = 0.005; // seconds

    // The steps k in [1, steps - 1] of a ramp from `from` to `to` cut into `steps` equal parts
    // whose times from + (to - from) * k / steps can lie inside `window` (open): the first and
    // last, or nullopt when none can. May include a step just outside (the caller keeps only the
    // times inside); never leaves one out. So a short plan window looks at its few steps, not at
    // every step of a long eased span (review L10).
    static std::optional<std::pair<std::int64_t, std::int64_t>> stepsWithin(CMTime from, CMTime to,
                                                                              std::int64_t steps,
                                                                              const TimeRange &window);

    // The layers visible at `time` (snapped down to the sequence frame containing it).
    static RenderGraph renderGraphAt(const Sequence &sequence, const Project &project, CMTime time);

    // Audio contributions over `range` (sequence time).
    static AudioGraph audioGraphFor(const Sequence &sequence, const Project &project, CMTimeRange range);
    static AudioGraph audioGraphFor(const Sequence &sequence, const Project &project, const TimeRange &range);

    // Whether a track currently contributes output, given mute and solo on its kind.
    static bool isTrackActive(const Sequence &sequence, const Track &track);

    // Clip covering `time` on `trackId` (transition handles not included).
    static std::optional<ClipId> clipAt(const Sequence &sequence, TrackId trackId, CMTime time);

    // Clips covering `time` on every track, video tracks bottom to top then audio tracks.
    static std::vector<ClipId> clipsAt(const Sequence &sequence, CMTime time);

    // The clip's Motion at sequence time `time`: its static values with its Motion and Opacity
    // spans composed onto them (motionValuesAt: each from its start on, holding its end value after
    // its end), evaluated at the exact source time the frame maps to (held at the clip's edge in
    // transition handles). Playback, the output view and export all get it from here.
    static VideoParams motionAt(const Clip &clip, CMTime time);

    // Source frame time for `clip` at sequence time `time`: exact speed mapping, then the start
    // of the asset frame containing that time (Floor; skipped for VFR or unknown frame rate),
    // clamped to the media. Inside the clip it never reaches the clip's out point: at 0.5x the
    // last timeline frame shows the last source frame that starts before sourceOut. Outside the
    // clip (transition handles) the mapping continues past the in and out points.
    static CMTime sourceFrameTime(const Clip &clip, const MediaAsset &asset, CMTime time);
};

} // namespace ve
