// Project file serialization (JSON via nlohmann/json).
//
// Format (schema version 3): a top-level object with "schemaVersion" (kProjectSchemaVersion),
// "name", "nextId", "activeSequenceId", "assets" and "sequences". CMTime is {"value",
// "timescale"} plus "flags" when the flags are anything other than plain valid (e.g. infinite)
// and "epoch" when non-zero; kCMTimeInvalid is null. A clip stores "timelineStart", "duration"
// (whole sequence frames), "sourceIn" and "speed" as {"num", "den"}; its source out point is
// derived. Enums are lower-camel strings. Round trips are lossless: projectFromJson(projectToJson(p))
// == p bit for bit. Unknown fields are ignored so newer minor additions do not break loading.
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

inline constexpr int kProjectSchemaVersion = 3;

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
std::optional<std::string> migrateProjectJson(nlohmann::json &document, int fromVersion,
                                              std::vector<std::string> &warnings);

// Individual pieces (used by tests and by clipboard/export code).
nlohmann::json timeToJson(CMTime time);

} // namespace ve
