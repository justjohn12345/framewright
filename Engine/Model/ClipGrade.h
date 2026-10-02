// A clip's colour grade: its base colour correction, a property of the clip as its Motion is
// (docs/reviews/2026-10-01-grading-pipeline-decision.md, section 7's decision). Five parameters,
// each a row of the grade parameter table (GradeParameterInfo, in the descriptor style of
// SpanParameterInfo and TransitionParameterInfo): a name for the project file, a display name, a
// unit, the neutral value and the valid range. A grade whose every value is neutral is "no grade":
// the clip renders exactly as an ungraded one (the compositor skips the grade), the project file
// leaves it out, and a project from before grading (schema 7 and older) loads with neutral grades.
//
// What the values mean (applied per source picture in linear light, ColorGrade.h):
//   - exposure: a gain of 2^stops;
//   - contrast: the exponent of a power curve about linear 0.18 (1 changes nothing, above 1 steeper);
//   - temperature: warm (+) or cool (-), a red/blue gain pair, -100...100 (100: red over blue by one
//     stop), normalised to keep luminance;
//   - tint: magenta (+) or green (-), a green gain, -100...100 (100: green down half a stop),
//     normalised to keep luminance;
//   - saturation: a mix toward BT.709 luminance (0 grey, 1 unchanged, 2 twice as saturated).
//
// Grades apply to pictures: only a clip on a video track may have one (validateSequence).
//
// Plain C++: unit-testable without Metal or media.

#pragma once

#include <array>
#include <cstddef>
#include <optional>
#include <string>
#include <string_view>

namespace ve {

enum class GradeParameter {
    Exposure,
    Contrast,
    Temperature,
    Tint,
    Saturation,
};

inline constexpr std::size_t kGradeParameterCount = 5;

inline constexpr std::array<GradeParameter, kGradeParameterCount> kGradeParameters{
    GradeParameter::Exposure, GradeParameter::Contrast, GradeParameter::Temperature, GradeParameter::Tint,
    GradeParameter::Saturation};

struct GradeParameterInfo {
    GradeParameter parameter;
    const char *name;        // the project file's key: "exposure", "contrast", "temperature", "tint", "saturation"
    const char *displayName; // messages and the colour panel: "Exposure", "Contrast", ...
    const char *unit;        // "stops", "×", or "" for the relative scales of temperature and tint
    double neutral;          // the value that changes nothing
    double minimum;          // the valid range, [minimum, maximum] (finite)
    double maximum;
};

// The row describing `parameter` (the first row for a value outside the enum).
const GradeParameterInfo &infoOf(GradeParameter parameter);

const char *nameOf(GradeParameter parameter);
const char *displayNameOf(GradeParameter parameter);
const char *unitOf(GradeParameter parameter);
// 0 for exposure, temperature and tint, 1 for contrast and saturation.
double neutralValue(GradeParameter parameter);
// The parameter named `name` (nameOf), or nullopt.
std::optional<GradeParameter> gradeParameterNamed(std::string_view name);
// Whether `value` is finite and within the parameter's range.
bool isValidGradeValue(GradeParameter parameter, double value);
// `value` limited to the parameter's range (the neutral value for NaN).
double clampGradeValue(GradeParameter parameter, double value);

struct ClipGrade {
    // The values, indexed by GradeParameter; every one neutral by default.
    std::array<double, kGradeParameterCount> values = neutralValues();
    // The entries of the file's "grade" this version does not read (a newer version's parameters), as
    // compact JSON text of an object, written back on save ("" when there are none; the foreign-content
    // rule of review core #9). They change nothing here.
    std::string foreign;

    static constexpr std::array<double, kGradeParameterCount> neutralValues() {
        return {0.0, 1.0, 0.0, 0.0, 1.0};
    }

    double operator[](GradeParameter parameter) const {
        return values[static_cast<std::size_t>(parameter)];
    }
    double &operator[](GradeParameter parameter) {
        return values[static_cast<std::size_t>(parameter)];
    }

    // Every value at its neutral value (the foreign entries do not count: this version does not apply
    // them). A neutral grade renders exactly as no grade.
    bool isNeutral() const;
    // Neutral and without foreign entries: nothing for the project file to keep.
    bool isEmpty() const {
        return isNeutral() && foreign.empty();
    }

    // Equality of every value (as doubles) and of the foreign text.
    friend bool operator==(const ClipGrade &, const ClipGrade &) = default;
};

// Why `grade` is not valid (a value not finite or outside its range, naming the parameter and the
// range), or nullopt.
std::optional<std::string> gradeProblem(const ClipGrade &grade);

} // namespace ve
