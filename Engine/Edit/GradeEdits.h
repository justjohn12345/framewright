// Edits of clips' grades (ClipGrade.h) and the questions the colour panel asks about a selection.
//
// - SetClipGrade sets grade parameters on one or several clips as one undo step. It sets only the
//   parameters its change gives and leaves the others, so moving one control over a multi-selection
//   sets that parameter on every clip and keeps what differs between them. A whole grade (Paste Grade)
//   and the neutral grade (Reset Grade) are changes that give every parameter and the foreign entries.
//   In a coalescing group (ReplacePrevious, a control drag) each step replaces the last: every step
//   says "set exposure to 1.2 on these clips", relative to the state before the gesture.
// - summarizeGrades tells, per parameter, the value the clips of a selection agree on, or that they
//   differ ("mixed"), and whether their whole grades are identical (Copy Grade of several clips).
// - gradeTargets picks the clips of a selection that can have a grade (those on video tracks, titles and colour
//   mattes left out: they are not graded, titles design section 5): a selection of linked picture and sound
//   grades the pictures, and Paste Grade over a selection that includes titles never changes their colours.
//
// Plain C++ (CoreMedia's CMTime only): unit-testable without media.

#pragma once

#include "Command.h"

#include <array>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace ve {

// What SetClipGrade sets of one wheel on each clip: its level, its colour (cb and cr, always given
// together), or both; nullopt keeps the clip's own. So moving a wheel's colour over several clips keeps each
// clip's level, as a slider keeps the other values.
struct WheelChange {
    std::optional<double> level;
    std::optional<double> cb;
    std::optional<double> cr;

    static WheelChange whole(const WheelValue &value) {
        return WheelChange{value.level, value.cb, value.cr};
    }
    bool isEmpty() const {
        return !level && !cb && !cr;
    }
    // `value` with the change applied.
    WheelValue appliedTo(WheelValue value) const;
    friend bool operator==(const WheelChange &, const WheelChange &) = default;
};

// What SetClipGrade sets on each clip: the values given (nullopt: the clip keeps its own) and, for a
// whole grade, the foreign entries (nullopt: the clip keeps its own).
struct GradeChange {
    std::array<std::optional<double>, kGradeParameterCount> values{};
    // What to set of each wheel (WheelChange; empty: the clip keeps its own).
    std::array<WheelChange, kGradeWheelCount> wheels{};
    // The curves to set, each its whole list of points (nullopt: the clip keeps its own; an identity curve is
    // stored as no points).
    std::array<std::optional<CurvePoints>, kGradeCurveCount> curves{};
    // The hue curves to set, likewise (an identity is stored as no points).
    std::array<std::optional<CurvePoints>, kGradeHueCurveCount> hueCurves{};
    // The LUTs to set (an id of Project::luts, or "" for none) and the look's strength; nullopt keeps each
    // clip's own. Removing the look sets its strength back to 1; a clip without a look keeps strength 1.
    std::optional<std::string> inputLut;
    std::optional<std::string> lookLut;
    std::optional<double> lookStrength;
    std::optional<std::string> foreign;

    // One parameter.
    static GradeChange of(GradeParameter parameter, double value);
    // One wheel, whole (its level and colour).
    static GradeChange of(GradeWheel wheel, const WheelValue &value);
    // Part of one wheel.
    static GradeChange of(GradeWheel wheel, const WheelChange &change);
    // One curve.
    static GradeChange of(GradeCurve curve, CurvePoints points);
    // One hue curve.
    static GradeChange of(GradeHueCurve curve, CurvePoints points);
    // Every parameter and the foreign entries of `grade` (Paste Grade; the neutral grade: Reset Grade).
    static GradeChange whole(const ClipGrade &grade);

    std::optional<double> &operator[](GradeParameter parameter) {
        return values[static_cast<std::size_t>(parameter)];
    }
    const std::optional<double> &operator[](GradeParameter parameter) const {
        return values[static_cast<std::size_t>(parameter)];
    }
    WheelChange &operator[](GradeWheel wheel) {
        return wheels[static_cast<std::size_t>(wheel)];
    }
    const WheelChange &operator[](GradeWheel wheel) const {
        return wheels[static_cast<std::size_t>(wheel)];
    }
    // The number of values given (of the basic parameters).
    std::size_t count() const;
    std::optional<CurvePoints> &operator[](GradeCurve curve) {
        return curves[static_cast<std::size_t>(curve)];
    }
    const std::optional<CurvePoints> &operator[](GradeCurve curve) const {
        return curves[static_cast<std::size_t>(curve)];
    }
    std::optional<CurvePoints> &operator[](GradeHueCurve curve) {
        return hueCurves[static_cast<std::size_t>(curve)];
    }
    const std::optional<CurvePoints> &operator[](GradeHueCurve curve) const {
        return hueCurves[static_cast<std::size_t>(curve)];
    }
    // The number of wheels with something to set.
    std::size_t wheelCount() const;
    // The number of curves given (tone and hue).
    std::size_t curveCount() const;
    // The number of LUT settings given (input, look, strength).
    std::size_t lutCount() const {
        return (inputLut ? 1 : 0) + (lookLut ? 1 : 0) + (lookStrength ? 1 : 0);
    }
    // Nothing given at all.
    bool isEmpty() const {
        return count() == 0 && wheelCount() == 0 && curveCount() == 0 && lutCount() == 0 && !foreign;
    }
    // `grade` with the change applied.
    ClipGrade appliedTo(ClipGrade grade) const;
};

// Sets grade parameters on clips (see the header). Refused as a whole, changing nothing, when the list
// or the change is empty, a clip is missing or listed twice, a clip lies on an audio track
// (TrackKindMismatch: a grade is for pictures) or a locked track, a clip is a title or a colour matte
// (InvalidArgument: not graded), or a value is not finite or outside its
// parameter's range (InvalidArgument, naming the range), a wheel's level outside [-1, 1], its colour outside
// the unit disk or given without both cb and cr, a curve that is not valid (curveProblem), a LUT the project
// does not hold, or a look strength outside [0, 1] (a clip without a look keeps strength 1). A change that
// leaves every clip as it was records no undo step.
class SetClipGrade final : public SequenceCommand {
  public:
    // `name` is the Undo menu's name; empty: "Change <parameter>" for one parameter, "Change <wheel>" for
    // one wheel, "Change <curve> Curve" for one curve ("Change Luma Curve", "Change Hue vs Saturation Curve"),
    // "Change Input LUT", "Change Look" or "Change Look
    // Strength" for one LUT setting, else "Change Grade".
    SetClipGrade(SequenceId sequenceId, std::vector<ClipId> clipIds, GradeChange change, std::string name = {});
    std::string name() const override;

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    std::vector<ClipId> clipIds_;
    GradeChange change_;
    std::string name_;
};

// A grade change that uses LUTs the project may not hold yet (a LUT just imported, a pasted grade from
// another project): adds the ones it lacks to Project::luts, then applies `grade` (a SetClipGrade), as one
// undo step; undo removes the LUTs it added. Refused (the project left as it was) when `grade` is refused or a
// LUT is not valid. A grade that changes nothing adds nothing.
class SetClipGradeWithLuts final : public Command {
  public:
    SetClipGradeWithLuts(std::vector<std::shared_ptr<const CubeLut>> luts, std::unique_ptr<SetClipGrade> grade);
    EditResult apply(Project &project) override;
    void revert(Project &project) const override;
    bool canRevert(const Project &project) const override;
    bool isNoOp() const override;
    std::string name() const override;

  private:
    std::vector<std::shared_ptr<const CubeLut>> luts_;
    std::vector<std::string> ids_;   // the LUTs' content ids
    std::vector<std::string> added_; // the ones the last apply added
    std::unique_ptr<SetClipGrade> grade_;
};

// What a selection's clips have for each grade parameter.
struct GradeSummary {
    // The clips of the selection that have a grade (on video tracks), in the order given.
    std::vector<ClipId> clips;
    // Per parameter: the value every one of `clips` has, or nullopt when they differ or there are none.
    std::array<std::optional<double>, kGradeParameterCount> values{};
    // Per parameter: whether the clips differ.
    std::array<bool, kGradeParameterCount> mixed{};
    // Per wheel: the setting every one of `clips` has (nullopt when they differ or there are none), and
    // whether they differ.
    std::array<std::optional<WheelValue>, kGradeWheelCount> wheels{};
    std::array<bool, kGradeWheelCount> wheelMixed{};
    // Per curve: the points every one of `clips` has (nullopt when they differ or there are none), and
    // whether they differ.
    std::array<std::optional<CurvePoints>, kGradeCurveCount> curves{};
    std::array<bool, kGradeCurveCount> curveMixed{};
    std::array<std::optional<CurvePoints>, kGradeHueCurveCount> hueCurves{};
    std::array<bool, kGradeHueCurveCount> hueCurveMixed{};
    // The LUTs and the look's strength every one of `clips` has (nullopt when they differ or there are none).
    std::optional<std::string> inputLut;
    std::optional<std::string> lookLut;
    std::optional<double> lookStrength;
    // Whether any of `clips` has a grade (not neutral).
    bool anyGraded = false;
    // Whether every one of `clips` has the same whole grade: each value and the entries a newer version
    // wrote (ClipGrade::foreign), which Copy Grade copies too. False when there are no clips; true for
    // one clip.
    bool identical = false;

    const std::optional<double> &valueOf(GradeParameter parameter) const {
        return values[static_cast<std::size_t>(parameter)];
    }
    bool isMixed(GradeParameter parameter) const {
        return mixed[static_cast<std::size_t>(parameter)];
    }
    const std::optional<WheelValue> &valueOf(GradeWheel wheel) const {
        return wheels[static_cast<std::size_t>(wheel)];
    }
    bool isMixed(GradeWheel wheel) const {
        return wheelMixed[static_cast<std::size_t>(wheel)];
    }
    const std::optional<CurvePoints> &valueOf(GradeCurve curve) const {
        return curves[static_cast<std::size_t>(curve)];
    }
    bool isMixed(GradeCurve curve) const {
        return curveMixed[static_cast<std::size_t>(curve)];
    }
    const std::optional<CurvePoints> &valueOf(GradeHueCurve curve) const {
        return hueCurves[static_cast<std::size_t>(curve)];
    }
    bool isMixed(GradeHueCurve curve) const {
        return hueCurveMixed[static_cast<std::size_t>(curve)];
    }
};

// The summary of the clips of `clipIds` in `sequence` that can have a grade; ids that name no clip,
// and clips on audio tracks, are left out.
GradeSummary summarizeGrades(const Sequence &sequence, const std::vector<ClipId> &clipIds);

// The clips of `clipIds` that can have a grade (on video tracks, not titles or colour mattes), in the order
// given, each once; ids that name no clip are left out (the edit then refuses nothing for them).
std::vector<ClipId> gradeTargets(const Sequence &sequence, const std::vector<ClipId> &clipIds);

} // namespace ve
