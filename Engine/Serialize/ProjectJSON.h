// Project file serialization (JSON via nlohmann/json).
//
// Format: a top-level object with "schemaVersion" (kProjectSchemaVersion), "name", "nextId",
// "activeSequenceId", "assets" and "sequences". CMTime is {"value", "timescale"} plus "flags"
// when the flags are anything other than plain valid (e.g. rounded, infinite); kCMTimeInvalid
// is null. Enums are lower-camel strings. Round trips are lossless: projectFromJson(projectToJson(p))
// == p bit for bit. Unknown fields are ignored so newer minor additions do not break loading.
// Loading never throws: errors come back as a message naming the offending JSON path, and a
// loaded project must pass validateProject.

#pragma once

#include "../Model/Project.h"

#include <json.hpp>

#include <optional>
#include <string>
#include <string_view>

namespace ve {

inline constexpr int kProjectSchemaVersion = 1;

nlohmann::json projectToJson(const Project &project);

// `indent` < 0 produces compact output.
std::string serializeProject(const Project &project, int indent = 2);

struct ProjectLoadResult {
    std::optional<Project> project;
    std::string error; // empty on success

    bool ok() const {
        return project.has_value();
    }
};

ProjectLoadResult projectFromJson(const nlohmann::json &json);
ProjectLoadResult parseProject(std::string_view text);

// Individual pieces (used by tests and by clipboard/export code).
nlohmann::json timeToJson(CMTime time);

} // namespace ve
