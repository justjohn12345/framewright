// The project file's migration steps (one per schema version bump), private to Engine/Serialize.
// ProjectJSON.h documents what each step converts; migrateProjectJson and projectFromJson run them.
//
// The steps are frozen (review core #8): each reads and writes the JSON with its own code and the
// constants of the version it produces (names, parameter tables, ranges, neutral values, the span
// writer of version 5, version 1's speed rules), so that a later schema version, a renamed or added
// kind, or a change to the model or to the current parser and writer cannot change how an older
// file loads. They depend only on the exact time arithmetic (TimeUtil.h) and on the JSON reader
// (JsonNode.h). The golden fixtures `EngineTests/Serialize/golden/project-v*.migrated.json` hold
// each checked-in file of versions 1-7 migrated to version 7 (the version current when the steps
// were frozen), with the warnings, and `golden/v8/*.migrated.json` the same files migrated to
// version 8 (recorded when the 7 -> 8 step was added), `golden/v9/*.migrated.json` to version 9 (the
// 8 -> 9 step) and `golden/v10/*.migrated.json` to version 10 (the 9 -> 10 step); they fail when a step's
// output drifts.
//
// A new schema version adds a step at the end of the table (ProjectMigrations.cpp) with its own
// writer and constants, raises kLastMigrationTarget, and never edits an earlier step.

#pragma once

#include <json.hpp>

#include <string>
#include <vector>

namespace ve::serialize {

// The version the last step produces; ProjectJSON.cpp asserts it is kProjectSchemaVersion.
inline constexpr int kLastMigrationTarget = 10;

// Upgrades `document` from schema version `fromVersion` to `toVersion` (1 <= fromVersion <=
// toVersion <= kLastMigrationTarget) in place, setting "schemaVersion" after each step, and appends
// what the steps adjusted to `warnings`. `toVersion` is also the version the caller will save the
// project as, which a warning about newer content in an older file names. Throws ParseError
// (naming the JSON path of what a step cannot convert) or nlohmann::json::exception.
void runProjectMigrations(nlohmann::json &document, int fromVersion, int toVersion,
                          std::vector<std::string> &warnings);

} // namespace ve::serialize
