// A clip: a range of one asset placed on one track.
//
// Timing model:
// - `sourceIn`/`sourceOut` is the used range of the asset, in source media time.
// - The timeline duration derives from that range and `speed`: duration = (out - in) / speed.
//   Speed is applied as the rational speedRatio() (denominator <= kMaxSpeedDenominator) so the
//   mapping between timeline and source time is exact and reversible.
// - Still-image clips (isStill) have no source timing: their source range is measured in
//   timeline time, sourceIn is always zero and speed is always 1.
// - Invariants (checked by validateSequence): speed within [kMinSpeed, kMaxSpeed]; source range
//   non-empty and inside the asset; timelineStart and timelineEnd() on the sequence frame grid.

#pragma once

#include "Ids.h"
#include "TimeUtil.h"

#include <cstdint>
#include <optional>

namespace ve {

inline constexpr double kMinSpeed = 0.01;
inline constexpr double kMaxSpeed = 100.0;
inline constexpr std::int64_t kMaxSpeedDenominator = 1000;

// Duration given to a still-image clip when none is specified.
inline CMTime defaultStillDuration() {
    return CMTimeMake(5, 1);
}

// Placement of a clip's picture in the sequence frame. x/y offset the clip's centre from the
// frame centre in sequence pixels (+y is down); scale 1 draws the source at its fitted size.
struct VideoParams {
    double x = 0.0;
    double y = 0.0;
    double scale = 1.0;
    double rotationDegrees = 0.0;
    double opacity = 1.0; // 0...1

    friend bool operator==(const VideoParams &, const VideoParams &) = default;
};

struct AudioParams {
    double gainDb = 0.0;
    CMTime fadeInDuration = kCMTimeZero;  // linear ramp from silence at the clip start
    CMTime fadeOutDuration = kCMTimeZero; // linear ramp to silence at the clip end
};

bool operator==(const AudioParams &a, const AudioParams &b); // bit-for-bit

struct Clip {
    ClipId id;
    AssetId assetId;
    TrackId trackId;
    CMTime timelineStart = kCMTimeZero;
    CMTime sourceIn = kCMTimeZero;
    CMTime sourceOut = kCMTimeZero;
    double speed = 1.0; // > 0; 2.0 plays twice as fast
    bool isStill = false;
    std::optional<ClipId> linkedClipId; // symmetric: the partner links back
    VideoParams video;
    AudioParams audio;

    // Rational form of `speed` used for all time mapping ({1, 1} for stills).
    Ratio speedRatio() const;

    CMTime sourceDuration() const {
        return sourceOut - sourceIn;
    }
    // Duration on the timeline.
    CMTime duration() const;
    CMTime timelineEnd() const {
        return timelineStart + duration();
    }
    TimeRange timelineRange() const {
        return TimeRange{timelineStart, timelineEnd()};
    }

    // Source time shown at timeline time `t`. Valid outside the clip too (transition handles).
    // For stills this is the offset into the still's timeline range.
    CMTime sourceTimeAt(CMTime t) const;

    // Timeline time at which source time `s` plays (inverse of sourceTimeAt).
    CMTime timelineTimeAt(CMTime s) const;

    // Moves the start to `newStart` keeping the end fixed (adjusts the source range).
    void setTimelineStartKeepingEnd(CMTime newStart);

    // Moves the end to `newEnd` keeping the start fixed (adjusts the source range).
    void setTimelineEnd(CMTime newEnd);
};

// Bit-for-bit equality of every field.
bool operator==(const Clip &a, const Clip &b);

} // namespace ve
