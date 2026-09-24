// Project file serialization (JSON via nlohmann/json).
//
// Format (schema version 5): a top-level object with "schemaVersion" (kProjectSchemaVersion),
// "name", "nextId", "activeSequenceId", "assets" and "sequences". CMTime is {"value",
// "timescale"} plus "flags" when the flags are anything other than plain valid (e.g. infinite)
// and "epoch" when non-zero; kCMTimeInvalid is null. A clip stores "timelineStart", "duration"
// (whole sequence frames), "sourceIn" and "speed" as {"num", "den"}; its source out point is
// derived. Its "video" object holds the static Motion values and "audio" its "gainDb"; "spans"
// (left out when empty) lists its effect spans (EffectSpan.h): {"id", "lane", "kind": "transition"
// | "motion" | "opacity" | "gain", "start", "end"} plus, for a transition, "edge": "head" | "tail"
// and "transition": "crossDissolve", and for an effect span "tracks": {"x" | "y" | "scale" |
// "rotation" | "opacity" | "gain": [{"time" (relative to the span's start), "value",
// "interpolation": "hold" | "linear" | "easeOut" | "easeIn" | "easeInOut" | "bezier", "curve":
// [x1, y1, x2, y2] (bezier only)}, ...]} (parameters without keyframes left out). Enums are
// lower-camel strings. Round trips are lossless: projectFromJson(projectToJson(p)) == p bit for
// bit. Unknown fields are ignored so newer minor additions do not break loading; a span of an
// unknown kind, or a track of an unknown parameter, is dropped with a warning.
//
// Older files are upgraded on load by migrateProjectJson, one schema version at a time. Loading
// never throws: errors come back as a message naming the offending JSON path; recoverable
// oddities (an unknown transition kind, values a migration had to adjust) are fixed and listed
// in ProjectLoadResult::warnings; a loaded project must pass validateProject.
//
// Writing never throws either: strings that are not valid UTF-8 are written with U+FFFD in
// place of the bad bytes.

#pragma once

#include "../Model/Project.h"

#include <json.hpp>

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace ve {

inline constexpr int kProjectSchemaVersion = 5;

nlohmann::json projectToJson(const Project &project);

// `indent` < 0 produces compact output.
std::string serializeProject(const Project &project, int indent = 2);

struct ProjectLoadResult {
    std::optional<Project> project;
    std::string error;                 // empty on success
    std::vector<std::string> warnings; // what was adjusted to load the file (success only)

    bool ok() const {
        return project.has_value();
    }
};

ProjectLoadResult projectFromJson(const nlohmann::json &json);
ProjectLoadResult parseProject(std::string_view text);

// Upgrades `document`, a project of schema version `fromVersion` (1 <= fromVersion <=
// kProjectSchemaVersion), to kProjectSchemaVersion in place by running each registered
// migration step in turn; appends what the steps adjusted to `warnings`. Returns an error
// message naming the JSON path of a value a step cannot convert, or nullopt on success.
// Migration steps:
//   1 -> 2: clip "sourceOut" and double "speed" become "duration" (whole sequence frames) and a
//           {"num", "den"} speed; overlapping fades are shortened to fit; rounded flags and
//           epochs left in stored times by the version 1 time math are dropped (the rounded
//           values are within 1.5 ns of the intended ones) and durations snapped back to the
//           frame grid.
//   2 -> 3: video and A/V assets get "videoDuration" (where their video ends), set to their
//           "duration" (version 2 did not record it separately).
//   3 -> 4: nothing to convert. Version 4 added Motion keyframes: a clip's "video" object may hold
//           "keyframes": {"x" | "y" | "scale" | "rotation" | "opacity": [{"time": source time,
//           "value", "interpolation", "curve"}, ...]}; a version 3 clip has none.
//   4 -> 5: effect spans. Per clip, the x/y/scale/rotation keyframes become one Motion span on
//           lane 1 over the clip's used source range (its tracks are the keyframes re-based to the
//           span's start and cut exactly at the clip's edges, so the values version 4 held before
//           the first and after the last keyframe are held inside the span), and the opacity
//           keyframes an Opacity span (lane 2 when there is a Motion span, else lane 1); the static
//           value of an animated parameter (unused by version 4) becomes neutral. Each
//           transition becomes a lane-0 span of its outgoing clip centred on the cut (floor(n/2)
//           frames before it, the rest after), keeping its id. An audio clip's fade in becomes a
//           head fade span and its fade out a tail fade span, except on an edge with a crossfade
//           (version 4 ignored the fade there); a fade in on a clip whose start another clip
//           touches cannot be a span (the cut is the other clip's) and is dropped with a warning,
//           as is the part of a fade in that would meet the clip's tail transition. Fades on
//           clips of video tracks (never audible) are dropped. New span ids come from "nextId".
std::optional<std::string> migrateProjectJson(nlohmann::json &document, int fromVersion,
                                              std::vector<std::string> &warnings);

// Individual pieces (used by tests and by clipboard/export code).
nlohmann::json timeToJson(CMTime time);

} // namespace ve
