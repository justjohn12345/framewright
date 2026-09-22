// A timeline track holding clips of one kind.
//
// Invariants (checkInvariants / validateSequence): `clips` is sorted by timelineStart, clips
// never overlap (a clip's end <= the next clip's start; touching is allowed), and every clip's
// trackId is this track's id.

#pragma once

#include "Clip.h"
#include "Ids.h"
#include "TimeUtil.h"

#include <cstddef>
#include <optional>
#include <string>
#include <vector>

namespace ve {

enum class TrackKind {
    Video,
    Audio,
};

const char *nameOf(TrackKind kind);

struct Track {
    TrackId id;
    TrackKind kind = TrackKind::Video;
    std::string name;
    bool muted = false;  // video: hidden; audio: silent
    bool solo = false;   // when any track of a kind is solo, only solo tracks of that kind play
    bool locked = false; // edits touching the track are refused
    std::vector<Clip> clips;

    std::optional<std::size_t> indexOf(ClipId clipId) const;
    const Clip *find(ClipId clipId) const;
    Clip *find(ClipId clipId);

    // The clip covering `t` (start <= t < end), if any. O(log n).
    std::optional<std::size_t> clipIndexAt(CMTime t) const;
    const Clip *clipAt(CMTime t) const;

    // Index of the first clip starting at or after `t`.
    std::size_t firstClipStartingAtOrAfter(CMTime t) const;

    // End of the last clip (zero when empty).
    CMTime end() const;

    // Restores ordering by timelineStart (stable).
    void sortClips();

    // Describes the first violated invariant, or nullopt.
    std::optional<std::string> checkInvariants() const;
};

// Bit-for-bit equality of every field.
bool operator==(const Track &a, const Track &b);

} // namespace ve
