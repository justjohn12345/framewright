// A clip's colour grade: its base colour correction, a property of the clip as its Motion is
// (docs/reviews/2026-10-01-grading-pipeline-decision.md, section 7's decision). Five basic parameters,
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
// Slice 2 adds the colour wheels (GradeWheel), the curves (GradeCurve) and the LUTs (CubeLut.h), below.
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
#include <vector>

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

// A grade's values, indexed by GradeParameter (what the renderer needs of a clip's grade).
using GradeValues = std::array<double, kGradeParameterCount>;

// Whether every value is its parameter's neutral value (no grade).
bool isNeutralGrade(const GradeValues &values);

// The lift / gamma / gain colour wheels (colour grading slice 2): shadows, midtones and highlights. A table
// of their own (not rows of the parameter table above: each wheel is a point and a level, edited together),
// in the same descriptor style. Applied per source picture in linear light (ColorGrade.h), after
// saturation and before contrast, in the standard formulation out = (gain * (in + lift * (1 - in)))^(1/gamma)
// per channel, where each wheel's channel values come from its level and its colour:
//   - lift = 0.1 * (level + 0.5 * w): an offset of the blacks that fades out toward white (level 1 lifts
//     black to linear 0.1, about 38 % encoded);
//   - gain = 2^(level + 0.5 * w): a gain (level +-1 is a stop);
//   - gamma = 2^(level + 0.5 * w), applied as the power 1 / gamma about linear 1 (level 1 brings linear 0.18
//     to 0.42; below 2^-14 the curve continues as the straight line through the origin, as contrast does);
// with w the wheel's colour as a zero-luminance RGB direction: the point (cb, cr) taken as BT.709 chroma
// (Cb toward blue, Cr toward red, as a vectorscope shows them), converted to R, G and B with Y' = 0 and
// divided by 1.8556 (the blue axis's length), so a colour at the rim tilts its channel by about half a stop.
enum class GradeWheel {
    Lift,
    Gamma,
    Gain,
};

inline constexpr std::size_t kGradeWheelCount = 3;

inline constexpr std::array<GradeWheel, kGradeWheelCount> kGradeWheels{GradeWheel::Lift, GradeWheel::Gamma,
                                                                        GradeWheel::Gain};

struct GradeWheelInfo {
    GradeWheel wheel;
    const char *name;        // the key in the file's "wheels": "lift", "gamma", "gain"
    const char *displayName; // "Lift", "Gamma", "Gain"
    const char *tonalRange;  // what it moves most: "shadows", "midtones", "highlights"
};

// A wheel's level lies in [-kWheelLevelLimit, kWheelLevelLimit]; its colour (cb, cr) in the disk of radius
// kWheelColourRadius (a point slightly outside it, within kWheelColourSlack, counts as on the rim: the
// rounding of a point dragged to the rim).
inline constexpr double kWheelLevelLimit = 1.0;
inline constexpr double kWheelColourRadius = 1.0;
inline constexpr double kWheelColourSlack = 1e-9;

// The row describing `wheel` (the first row for a value outside the enum).
const GradeWheelInfo &infoOf(GradeWheel wheel);
const char *nameOf(GradeWheel wheel);
const char *displayNameOf(GradeWheel wheel);
// The wheel named `name` (nameOf), or nullopt.
std::optional<GradeWheel> gradeWheelNamed(std::string_view name);

// One wheel's setting: its level and its colour point. All zero is neutral.
struct WheelValue {
    double level = 0.0;
    double cb = 0.0;
    double cr = 0.0;

    bool isNeutral() const {
        return level == 0.0 && cb == 0.0 && cr == 0.0;
    }
    friend bool operator==(const WheelValue &, const WheelValue &) = default;
};

using GradeWheels = std::array<WheelValue, kGradeWheelCount>;

// Whether every value of `value` is finite, its level within its limit and its colour within the disk.
bool isValidWheel(const WheelValue &value);
// `value` made valid: NaN as 0, the level limited, a colour outside the disk moved onto its rim (same hue).
WheelValue clampWheel(const WheelValue &value);
// Whether every wheel is neutral.
bool isNeutralWheels(const GradeWheels &wheels);

// The curves (colour grading slice 2): tone curves over the encoded R'G'B' the scopes show, a luma curve
// and one per channel, each through at most kMaxCurvePoints points the user placed (x the input, y the
// output, both in [0, 1], x strictly increasing), interpolated by a monotone cubic (Fritsch-Carlson: the
// curve never overshoots its points, so a rising set of points gives a rising curve) and flat beyond the
// first and last points. No points (or points all on the diagonal from (0, 0) to (1, 1)) is the identity,
// stored as no points. Applied after the re-encoding (ColorGrade.h): the luma curve moves each pixel's
// BT.709 luma (adding the same amount to R', G' and B', so chroma is kept), then the red, green and blue
// curves map their channels. A curve in use limits its channel to its range on [0, 1] (super-whites are not
// kept through it).
enum class GradeCurve {
    Luma,
    Red,
    Green,
    Blue,
};

inline constexpr std::size_t kGradeCurveCount = 4;
inline constexpr std::array<GradeCurve, kGradeCurveCount> kGradeCurves{GradeCurve::Luma, GradeCurve::Red,
                                                                        GradeCurve::Green, GradeCurve::Blue};
// The most points a curve has.
inline constexpr std::size_t kMaxCurvePoints = 16;

struct GradeCurveInfo {
    GradeCurve curve;
    const char *name;        // the file's key: "curveLuma", "curveRed", ...
    const char *displayName; // "Luma", "Red", "Green", "Blue"
};

const GradeCurveInfo &infoOf(GradeCurve curve);
const char *nameOf(GradeCurve curve);
const char *displayNameOf(GradeCurve curve);
std::optional<GradeCurve> gradeCurveNamed(std::string_view name);

struct CurvePoint {
    double x = 0.0;
    double y = 0.0;
    friend bool operator==(const CurvePoint &, const CurvePoint &) = default;
};

using CurvePoints = std::vector<CurvePoint>;
using GradeCurves = std::array<CurvePoints, kGradeCurveCount>;

// Whether `points` is the identity: none, or every point on the diagonal with the first at (0, 0) and the
// last at (1, 1).
bool isIdentityCurve(const CurvePoints &points);
// Why `points` is not a valid curve (not 0 or 2..kMaxCurvePoints points, a value not finite or outside
// [0, 1], x not strictly increasing), or nullopt.
std::optional<std::string> curveProblem(const CurvePoints &points);
// `points` made valid (what a project file's curve becomes): values limited to [0, 1] (NaN dropped), sorted
// by x, a point at the same x as the one before dropped, at most kMaxCurvePoints kept (the first ones);
// a single point left is dropped; the identity becomes no points.
CurvePoints sanitizedCurve(const CurvePoints &points);
// The curve through `points` at `x` (the identity for no points).
double evaluateCurve(const CurvePoints &points, double x);
// The curve through `points` at `samples` evenly spaced x from 0 to 1 (sample i at x = i / (samples - 1)).
std::vector<float> sampleCurve(const CurvePoints &points, std::size_t samples);
// Whether every curve is the identity.
bool isIdentityCurves(const GradeCurves &curves);

struct ClipGrade {
    // The values, indexed by GradeParameter; every one neutral by default.
    GradeValues values = neutralValues();
    // The colour wheels, indexed by GradeWheel; every one neutral by default.
    GradeWheels wheels{};
    // The curves, indexed by GradeCurve: their points (none: the identity, the default; an identity curve is
    // always stored as none).
    GradeCurves curves{};
    // The LUTs (slice 2), by content id in Project::luts ("" for none): the input conversion, applied to the
    // source's R'G'B' before the grade (a camera's log to Rec. 709, say), and the look, applied after the grade
    // and the curves, mixed with what it changes by `lookStrength` (0 to 1; 1 without a look).
    std::string inputLut;
    std::string lookLut;
    double lookStrength = 1.0;
    // The entries of the file's "grade" this version does not read (a newer version's parameters), as
    // compact JSON text of an object, written back on save ("" when there are none; the foreign-content
    // rule of review core #9). They change nothing here.
    std::string foreign;

    static constexpr GradeValues neutralValues() {
        return {0.0, 1.0, 0.0, 0.0, 1.0};
    }

    double operator[](GradeParameter parameter) const {
        return values[static_cast<std::size_t>(parameter)];
    }
    double &operator[](GradeParameter parameter) {
        return values[static_cast<std::size_t>(parameter)];
    }
    const WheelValue &operator[](GradeWheel wheel) const {
        return wheels[static_cast<std::size_t>(wheel)];
    }
    WheelValue &operator[](GradeWheel wheel) {
        return wheels[static_cast<std::size_t>(wheel)];
    }
    const CurvePoints &operator[](GradeCurve curve) const {
        return curves[static_cast<std::size_t>(curve)];
    }
    CurvePoints &operator[](GradeCurve curve) {
        return curves[static_cast<std::size_t>(curve)];
    }

    // Every value at its neutral value, every wheel neutral, every curve the identity and no LUT (the foreign
    // entries do not count: this version does not apply them). A neutral grade renders exactly as no grade.
    bool isNeutral() const;
    // Neutral and without foreign entries: nothing for the project file to keep.
    bool isEmpty() const {
        return isNeutral() && foreign.empty();
    }

    // Equality of every value (as doubles) and of the foreign text.
    friend bool operator==(const ClipGrade &, const ClipGrade &) = default;
};

// Why `grade` is not valid (a value not finite or outside its range, naming the parameter and the
// range; a wheel's level outside its limit or its colour outside the disk; a curve that is not valid or an
// identity curve stored with points; a look strength outside [0, 1], or not 1 without a look), or nullopt.
// (Whether the LUTs exist is the project's question: validateClip.)
std::optional<std::string> gradeProblem(const ClipGrade &grade);

} // namespace ve
