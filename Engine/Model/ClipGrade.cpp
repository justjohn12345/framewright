#include "ClipGrade.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <iterator>
#include <string>

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

bool isNeutralGrade(const GradeValues &values) {
    for (const GradeParameter parameter : kGradeParameters) {
        if (values[static_cast<std::size_t>(parameter)] != neutralValue(parameter)) {
            return false;
        }
    }
    return true;
}

bool ClipGrade::isNeutral() const {
    return isNeutralGrade(values) && isNeutralWheels(wheels) && isIdentityCurves(curves);
}

namespace {

constexpr GradeCurveInfo kCurveTable[] = {
    {GradeCurve::Luma, "curveLuma", "Luma"},
    {GradeCurve::Red, "curveRed", "Red"},
    {GradeCurve::Green, "curveGreen", "Green"},
    {GradeCurve::Blue, "curveBlue", "Blue"},
};

constexpr bool curveTableInOrder() {
    std::size_t i = 0;
    for (const GradeCurveInfo &row : kCurveTable) {
        if (static_cast<std::size_t>(row.curve) != i || kGradeCurves[i] != row.curve) {
            return false;
        }
        ++i;
    }
    return i == kGradeCurveCount;
}
static_assert(curveTableInOrder(), "kCurveTable must describe GradeCurve in order");

// The monotone cubic's tangent at each point (Fritsch-Carlson): the harmonic-style limit of the secants that
// keeps every segment monotonic between its points.
std::vector<double> curveTangents(const CurvePoints &p) {
    const std::size_t n = p.size();
    std::vector<double> secant(n - 1);
    for (std::size_t i = 0; i + 1 < n; ++i) {
        secant[i] = (p[i + 1].y - p[i].y) / (p[i + 1].x - p[i].x);
    }
    std::vector<double> m(n);
    m[0] = secant[0];
    m[n - 1] = secant[n - 2];
    for (std::size_t i = 1; i + 1 < n; ++i) {
        m[i] = secant[i - 1] * secant[i] <= 0.0 ? 0.0 : (secant[i - 1] + secant[i]) / 2.0;
    }
    for (std::size_t i = 0; i + 1 < n; ++i) {
        if (secant[i] == 0.0) {
            m[i] = 0.0;
            m[i + 1] = 0.0;
            continue;
        }
        const double a = m[i] / secant[i];
        const double b = m[i + 1] / secant[i];
        const double h = a * a + b * b;
        if (h > 9.0) {
            const double t = 3.0 / std::sqrt(h);
            m[i] = t * a * secant[i];
            m[i + 1] = t * b * secant[i];
        }
    }
    return m;
}

} // namespace

const GradeCurveInfo &infoOf(GradeCurve curve) {
    const auto index = static_cast<std::size_t>(curve);
    return index < std::size(kCurveTable) ? kCurveTable[index] : kCurveTable[0];
}

const char *nameOf(GradeCurve curve) {
    return infoOf(curve).name;
}

const char *displayNameOf(GradeCurve curve) {
    return infoOf(curve).displayName;
}

std::optional<GradeCurve> gradeCurveNamed(std::string_view name) {
    for (const GradeCurveInfo &row : kCurveTable) {
        if (name == row.name) {
            return row.curve;
        }
    }
    return std::nullopt;
}

bool isIdentityCurve(const CurvePoints &points) {
    if (points.empty()) {
        return true;
    }
    if (points.front() != CurvePoint{0.0, 0.0} || points.back() != CurvePoint{1.0, 1.0}) {
        return false;
    }
    for (const CurvePoint &point : points) {
        if (point.x != point.y) {
            return false;
        }
    }
    return true;
}

std::optional<std::string> curveProblem(const CurvePoints &points) {
    if (points.size() == 1 || points.size() > kMaxCurvePoints) {
        return "a curve has 2 to " + std::to_string(kMaxCurvePoints) + " points (not " + std::to_string(points.size()) +
               ")";
    }
    for (std::size_t i = 0; i < points.size(); ++i) {
        const CurvePoint &point = points[i];
        if (!std::isfinite(point.x) || !std::isfinite(point.y) || point.x < 0.0 || point.x > 1.0 || point.y < 0.0 ||
            point.y > 1.0) {
            return "a curve's point (" + numberText(point.x) + ", " + numberText(point.y) + ") is outside [0, 1]";
        }
        if (i > 0 && !(point.x > points[i - 1].x)) {
            return "a curve's points must go from left to right (" + numberText(point.x) + " after " +
                   numberText(points[i - 1].x) + ")";
        }
    }
    return std::nullopt;
}

CurvePoints sanitizedCurve(const CurvePoints &points) {
    CurvePoints kept;
    for (const CurvePoint &point : points) {
        if (std::isnan(point.x) || std::isnan(point.y)) {
            continue;
        }
        kept.push_back(CurvePoint{std::clamp(point.x, 0.0, 1.0), std::clamp(point.y, 0.0, 1.0)});
    }
    std::stable_sort(kept.begin(), kept.end(), [](const CurvePoint &a, const CurvePoint &b) { return a.x < b.x; });
    CurvePoints unique;
    for (const CurvePoint &point : kept) {
        if ((unique.empty() || point.x > unique.back().x) && unique.size() < kMaxCurvePoints) {
            unique.push_back(point);
        }
    }
    if (unique.size() < 2 || isIdentityCurve(unique)) {
        return {};
    }
    return unique;
}

namespace {

// The monotone cubic through `points` (at least 2), with its tangents computed once.
class CurveEvaluator {
  public:
    explicit CurveEvaluator(const CurvePoints &points) : points_(points), tangents_(curveTangents(points)) {}

    double operator()(double x) const {
        const CurvePoints &p = points_;
        if (!(x > p.front().x)) {
            return p.front().y; // NaN too: the first point
        }
        if (x >= p.back().x) {
            return p.back().y;
        }
        std::size_t i = 0;
        while (i + 2 < p.size() && x >= p[i + 1].x) {
            ++i;
        }
        const CurvePoint &a = p[i];
        const CurvePoint &b = p[i + 1];
        const double h = b.x - a.x;
        const double t = (x - a.x) / h;
        const double t2 = t * t;
        const double t3 = t2 * t;
        const double y = (2 * t3 - 3 * t2 + 1) * a.y + (t3 - 2 * t2 + t) * h * tangents_[i] + (-2 * t3 + 3 * t2) * b.y +
                         (t3 - t2) * h * tangents_[i + 1];
        // Within the segment's values (the monotone tangents keep it there up to rounding).
        return std::clamp(y, std::min(a.y, b.y), std::max(a.y, b.y));
    }

  private:
    const CurvePoints &points_;
    std::vector<double> tangents_;
};

} // namespace

double evaluateCurve(const CurvePoints &points, double x) {
    if (points.size() < 2) {
        return x;
    }
    return CurveEvaluator(points)(x);
}

std::vector<float> sampleCurve(const CurvePoints &points, std::size_t samples) {
    std::vector<float> table(samples);
    if (samples == 0) {
        return table;
    }
    const double last = samples > 1 ? double(samples - 1) : 1.0;
    if (points.size() < 2) {
        for (std::size_t i = 0; i < samples; ++i) {
            table[i] = float(double(i) / last);
        }
        return table;
    }
    const CurveEvaluator curve(points);
    for (std::size_t i = 0; i < samples; ++i) {
        table[i] = float(curve(double(i) / last));
    }
    return table;
}

bool isIdentityCurves(const GradeCurves &curves) {
    for (const CurvePoints &points : curves) {
        if (!isIdentityCurve(points)) {
            return false;
        }
    }
    return true;
}

namespace {

constexpr GradeWheelInfo kWheelTable[] = {
    {GradeWheel::Lift, "lift", "Lift", "shadows"},
    {GradeWheel::Gamma, "gamma", "Gamma", "midtones"},
    {GradeWheel::Gain, "gain", "Gain", "highlights"},
};

constexpr bool wheelTableInOrder() {
    std::size_t i = 0;
    for (const GradeWheelInfo &row : kWheelTable) {
        if (static_cast<std::size_t>(row.wheel) != i || kGradeWheels[i] != row.wheel) {
            return false;
        }
        ++i;
    }
    return i == kGradeWheelCount;
}
static_assert(wheelTableInOrder(), "kWheelTable must describe GradeWheel in order");

double finiteOrZero(double v) {
    return std::isfinite(v) ? v : 0.0;
}

} // namespace

const GradeWheelInfo &infoOf(GradeWheel wheel) {
    const auto index = static_cast<std::size_t>(wheel);
    return index < std::size(kWheelTable) ? kWheelTable[index] : kWheelTable[0];
}

const char *nameOf(GradeWheel wheel) {
    return infoOf(wheel).name;
}

const char *displayNameOf(GradeWheel wheel) {
    return infoOf(wheel).displayName;
}

std::optional<GradeWheel> gradeWheelNamed(std::string_view name) {
    for (const GradeWheelInfo &row : kWheelTable) {
        if (name == row.name) {
            return row.wheel;
        }
    }
    return std::nullopt;
}

bool isValidWheel(const WheelValue &value) {
    if (!std::isfinite(value.level) || !std::isfinite(value.cb) || !std::isfinite(value.cr)) {
        return false;
    }
    return std::fabs(value.level) <= kWheelLevelLimit &&
           std::hypot(value.cb, value.cr) <= kWheelColourRadius + kWheelColourSlack;
}

WheelValue clampWheel(const WheelValue &value) {
    WheelValue out{finiteOrZero(value.level), finiteOrZero(value.cb), finiteOrZero(value.cr)};
    out.level = std::clamp(out.level, -kWheelLevelLimit, kWheelLevelLimit);
    const double radius = std::hypot(out.cb, out.cr);
    if (radius > kWheelColourRadius) {
        out.cb *= kWheelColourRadius / radius;
        out.cr *= kWheelColourRadius / radius;
    }
    return out;
}

bool isNeutralWheels(const GradeWheels &wheels) {
    for (const WheelValue &wheel : wheels) {
        if (!wheel.isNeutral()) {
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
    for (const GradeCurve curve : kGradeCurves) {
        const CurvePoints &points = grade[curve];
        if (auto problem = curveProblem(points)) {
            return std::string("grade ") + displayNameOf(curve) + " curve: " + *problem;
        }
        if (!points.empty() && isIdentityCurve(points)) {
            return std::string("grade ") + displayNameOf(curve) + " curve: an identity curve is stored without points";
        }
    }
    for (const GradeWheel wheel : kGradeWheels) {
        const WheelValue &value = grade[wheel];
        if (!isValidWheel(value)) {
            return std::string("grade ") + displayNameOf(wheel) + " wheel (level " + numberText(value.level) +
                   ", colour " + numberText(value.cb) + ", " + numberText(value.cr) +
                   ") is outside its range (level -1 to 1, colour within the wheel)";
        }
    }
    return std::nullopt;
}

} // namespace ve
