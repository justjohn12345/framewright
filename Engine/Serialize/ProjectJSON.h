// Project file serialization (JSON via nlohmann/json).
//
// Format (schema version 11): a top-level object with "schemaVersion" (kProjectSchemaVersion),
// "name", "nextId", "activeSequenceId", "assets", "sequences", "sharpenScaledDownSources"
// (Project.h) and "luts" (left out when no clip uses a LUT): the colour LUTs the clips' grades use, each
// {"id" (its content id, cubeContentId), "kind": "1d" | "3d", "size", "domainMin", "domainMax" ([r, g, b]),
// "title", "fileName", "path" (where it was imported from, for display), "data" (the table, red fastest,
// RGB float32 little-endian, base64)}. A sequence holds its settings ("frameDuration", "width", "height",
// "audioSampleRate", and "configured": false while a new project's sequence waits for its first
// video clip, Sequence.h) and its tracks. A missing "configured" or "sharpenScaledDownSources"
// reads as true. CMTime is {"value",
// "timescale"} plus "flags" when the flags are anything other than plain valid (e.g. infinite)
// and "epoch" when non-zero; kCMTimeInvalid is null. A clip stores "timelineStart", "duration"
// (whole sequence frames), "sourceIn" and "speed" as {"num", "den"}; its source out point is
// derived; "reversed": true (left out when false) marks a clip that plays its media backwards (its
// times are clip times, Clip.h "Reverse"). Its "video" object holds the static Motion values and
// "audio" its "gainDb"; "grade" (a clip on a video track; left out when every value is neutral and
// nothing foreign is kept) its colour grade, {"exposure" | "contrast" | "temperature" | "tint" |
// "saturation": number} with the values that are not neutral (ClipGrade.h), plus the slice 2 keys: the
// wheels "liftLevel", "liftCb", "liftCr", "gammaLevel", ... (numbers, when not 0), the curves "curveLuma",
// "curveRed", "curveGreen", "curveBlue" (lists of [x, y], when not the identity), "inputLut" and "lookLut"
// (ids into "luts") and "lookStrength" (0 to 1, when a look is set and the strength is not 1); "spans"
// (left out when empty) lists its spans in one list, its transitions (Clip::transitions, lane 0) then
// its effect spans (EffectSpan.h): {"id", "lane", "kind": "transition"
// | "motion" | "opacity" | "gain", "start", "end"} plus, for a transition, "edge": "head" | "tail"
// and "transition": "crossDissolve" | "wipeLeft" | "wipeRight" | "wipeUp" | "wipeDown" | "iris" and
// "parameters": {"softness": number} (the static values it sets of its kind's parameters, Transition.h;
// left out when none; forms in TransitionValueJSON.h), and
// for an effect span "tracks": {"x" | "y" | "scale" |
// "rotation" | "opacity" | "gain": [{"time" (relative to the span's start), "value",
// "interpolation": "hold" | "linear" | "easeOut" | "easeIn" | "easeInOut" | "bezier", "curve":
// [x1, y1, x2, y2] (bezier only)}, ...]} (parameters without keyframes left out). Enums are
// lower-camel strings. Round trips are lossless: projectFromJson(projectToJson(p)) == p bit for
// bit. Unknown fields are ignored so newer minor additions do not break loading, except in spans:
// what a newer version wrote there (a span of an unknown kind on an effect lane, a track of an
// unknown parameter, a transition parameter of an unknown name or choice, any other unknown key) is
// kept on the model as it was read (EffectSpan.h, ForeignSpanContent, TransitionSpan) and written back
// on save, so an older build does not strip a newer one's spans; unknown kinds and parameters are
// reported as warnings. The same holds for a clip's grade: an unknown grade parameter is kept
// (ClipGrade::foreign) with a warning; a grade value outside its range is limited to it, with a warning. A span of an unknown kind on lane 0,
// or one outside its clip's source range, is dropped with a warning.
//
// Titles and colour mattes (schema 10; GeneratedContent.h): an asset may hold "generator": "title" |
// "colourMatte" (a generator asset: a still without a file; left out for a file, and the asset is not written
// while no clip uses it); a clip of one holds "generated": {"kind": "title", then every title parameter by
// its TitleParameterInfo name: "text", "font" ({"system": weight} or {"name": PostScript name, "family",
// "style"}), the numbers, the colours as [r, g, b] sRGB components, "alignment": "left" | "centre" |
// "right", the toggles as booleans, and (schema 11) "pointText" (a boolean: no wrapping, the block grows with the
// text) and "anchor": "top" | "centre" | "bottom" (where "y" lies on the block)} or {"kind": "colourMatte",
// "colour": [r, g, b]}. A number or colour
// outside its range is limited, an unknown alignment, anchor or system font weight read as the default, with a
// warning; an unknown key is kept (GeneratedContent::foreign) and written back, with a warning; an unknown
// generator or content kind fails the load naming its path. A grade on a generated clip is dropped with a
// warning.
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

inline constexpr int kProjectSchemaVersion = 11;

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
//   5 -> 6: nothing to convert. Version 6 added "reversed" on clips (absent: forward) and the wipe
//           and iris transition kinds; a version 5 file has neither.
//   6 -> 7: every sequence gets "configured": true (an existing project's settings are chosen: it
//           never adopts a clip's) and the project "sharpenScaledDownSources": true (the default).
//   7 -> 8: nothing to convert. Version 8 added clips' "grade" (absent: no grade); a version 7 file
//           has none (one that has it anyway keeps it, with a warning).
//   8 -> 9: nothing to convert. Version 9 added the project's "luts" and a grade's "inputLut", "lookLut" and
//           "lookStrength"; a version 8 file has none (one that has them anyway keeps them, with a warning).
//   9 -> 10: nothing to convert. Version 10 added titles and colour mattes: an asset's "generator" and a
//           clip's "generated"; a version 9 file has none (one that has them anyway keeps them, with a
//           warning).
//   10 -> 11: nothing to convert. Version 11 added a title's "pointText" and "anchor" (absent: area text
//           anchored at its centre, which is how version 10 draws every title); a version 10 file has neither (one
//           that has them anyway keeps them, with a warning).
// The steps are frozen (ProjectMigrations.h): a later schema version adds a step and never changes
// how an older file is converted.
std::optional<std::string> migrateProjectJson(nlohmann::json &document, int fromVersion,
                                              std::vector<std::string> &warnings);

// As above, but stops at `toVersion` (fromVersion <= toVersion <= kProjectSchemaVersion), which is
// also the version a warning about newer content says the project is saved as. The golden
// migration tests use it to compare each older file with its fixtures migrated to versions 7 and 8.
std::optional<std::string> migrateProjectJson(nlohmann::json &document, int fromVersion, int toVersion,
                                              std::vector<std::string> &warnings);

// Individual pieces (used by tests and by clipboard/export code).
nlohmann::json timeToJson(CMTime time);

} // namespace ve
