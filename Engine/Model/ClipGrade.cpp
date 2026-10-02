#include "ClipGrade.h"

#include <cmath>
#include <cstdio>
#include <iterator>

namespace ve {

namespace {

constexpr GradeParameterInfo kGradeTable[] = {
    {GradeParameter::Exposure, "exposure", "Exposure", "stops", 0.0, -5.0, 5.0},
    {GradeParameter::Contrast, "contrast", "Contrast", "×", 1.0, 0.0, 2.0},
    {GradeParameter::Temperature, "temperature", "Temperature", "", 0.0, -100.0, 100.0},
    {GradeParameter::Tint, "tint", "Tint", "", 0.0, -100.0, 100.0},
    {GradeParameter::Saturation, "saturation", "Saturation", "×", 1.0, 0.0, 2.0},
};

// Row i describes enumerator i, kGradeParameters lists them in order, the bounds are finite and the
// neutral value lies within them and is ClipGrade's default.
constexpr bool gradeTableInOrder() {
    constexpr auto neutral = ClipGrade::neutralValues();
    std::size_t i = 0;
    for (const GradeParameterInfo &row : kGradeTable) {
        if (static_cast<std::size_t>(row.parameter) != i || kGradeParameters[i] != row.parameter) {
            return false;
        }
        if (!(row.minimum < row.maximum && row.minimum <= row.neutral && row.neutral <= row.maximum)) {
            return false;
        }
        if (row.minimum < -1e6 || row.maximum > 1e6 || neutral[i] != row.neutral) {
            return false;
        }
        ++i;
    }
    return i == kGradeParameterCount;
}
static_assert(gradeTableInOrder(), "kGradeTable must describe GradeParameter in order, neutral within a finite range");
static_assert(std::size(kGradeTable) == kGradeParameterCount);

std::string numberText(double value) {
    char text[32];
    std::snprintf(text, sizeof text, "%g", value);
    return text;
}

} // namespace

const GradeParameterInfo &infoOf(GradeParameter parameter) {
    const auto index = static_cast<std::size_t>(parameter);
    return index < std::size(kGradeTable) ? kGradeTable[index] : kGradeTable[0];
}

const char *nameOf(GradeParameter parameter) {
    return infoOf(parameter).name;
}

const char *displayNameOf(GradeParameter parameter) {
    return infoOf(parameter).displayName;
}

const char *unitOf(GradeParameter parameter) {
    return infoOf(parameter).unit;
}

double neutralValue(GradeParameter parameter) {
    return infoOf(parameter).neutral;
}

std::optional<GradeParameter> gradeParameterNamed(std::string_view name) {
    for (const GradeParameterInfo &row : kGradeTable) {
        if (name == row.name) {
            return row.parameter;
        }
    }
    return std::nullopt;
}

bool isValidGradeValue(GradeParameter parameter, double value) {
    const GradeParameterInfo &info = infoOf(parameter);
    return std::isfinite(value) && value >= info.minimum && value <= info.maximum;
}

double clampGradeValue(GradeParameter parameter, double value) {
    const GradeParameterInfo &info = infoOf(parameter);
    if (std::isnan(value)) {
        return info.neutral;
    }
    return value < info.minimum ? info.minimum : value > info.maximum ? info.maximum : value;
}

bool ClipGrade::isNeutral() const {
    for (const GradeParameter parameter : kGradeParameters) {
        if ((*this)[parameter] != neutralValue(parameter)) {
            return false;
        }
    }
    return true;
}

std::optional<std::string> gradeProblem(const ClipGrade &grade) {
    for (const GradeParameter parameter : kGradeParameters) {
        const double value = grade[parameter];
        if (!isValidGradeValue(parameter, value)) {
            const GradeParameterInfo &info = infoOf(parameter);
            return std::string("grade ") + info.displayName + " " + numberText(value) + " is outside its range [" +
                   numberText(info.minimum) + ", " + numberText(info.maximum) + "]";
        }
    }
    return std::nullopt;
}

} // namespace ve
