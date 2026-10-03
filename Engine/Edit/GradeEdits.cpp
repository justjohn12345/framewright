#include "GradeEdits.h"

#include "EditPrimitives.h"

#include <cmath>
#include <cstdio>
#include <unordered_set>

namespace ve {

namespace {

std::string numberText(double value) {
    char text[32];
    std::snprintf(text, sizeof text, "%g", value);
    return text;
}

} // namespace

GradeChange GradeChange::of(GradeParameter parameter, double value) {
    GradeChange change;
    change[parameter] = value;
    return change;
}

WheelValue WheelChange::appliedTo(WheelValue value) const {
    if (level) {
        value.level = *level;
    }
    if (cb) {
        value.cb = *cb;
    }
    if (cr) {
        value.cr = *cr;
    }
    return value;
}

GradeChange GradeChange::of(GradeWheel wheel, const WheelValue &value) {
    return of(wheel, WheelChange::whole(value));
}

GradeChange GradeChange::of(GradeWheel wheel, const WheelChange &wheelChange) {
    GradeChange change;
    change[wheel] = wheelChange;
    return change;
}

GradeChange GradeChange::of(GradeCurve curve, CurvePoints points) {
    GradeChange change;
    change[curve] = std::move(points);
    return change;
}

GradeChange GradeChange::of(GradeHueCurve curve, CurvePoints points) {
    GradeChange change;
    change[curve] = std::move(points);
    return change;
}

GradeChange GradeChange::whole(const ClipGrade &grade) {
    GradeChange change;
    for (const GradeParameter parameter : kGradeParameters) {
        change[parameter] = grade[parameter];
    }
    for (const GradeWheel wheel : kGradeWheels) {
        change[wheel] = WheelChange::whole(grade[wheel]);
    }
    for (const GradeCurve curve : kGradeCurves) {
        change[curve] = grade[curve];
    }
    for (const GradeHueCurve curve : kGradeHueCurves) {
        change[curve] = grade[curve];
    }
    change.inputLut = grade.inputLut;
    change.lookLut = grade.lookLut;
    change.lookStrength = grade.lookStrength;
    change.foreign = grade.foreign;
    return change;
}

std::size_t GradeChange::curveCount() const {
    std::size_t n = 0;
    for (const auto &curve : curves) {
        n += curve ? 1 : 0;
    }
    for (const auto &curve : hueCurves) {
        n += curve ? 1 : 0;
    }
    return n;
}

std::size_t GradeChange::wheelCount() const {
    std::size_t n = 0;
    for (const WheelChange &wheel : wheels) {
        n += wheel.isEmpty() ? 0 : 1;
    }
    return n;
}

std::size_t GradeChange::count() const {
    std::size_t n = 0;
    for (const auto &value : values) {
        n += value ? 1 : 0;
    }
    return n;
}

ClipGrade GradeChange::appliedTo(ClipGrade grade) const {
    for (const GradeParameter parameter : kGradeParameters) {
        if (const auto &value = (*this)[parameter]) {
            grade[parameter] = *value;
        }
    }
    for (const GradeWheel wheel : kGradeWheels) {
        grade[wheel] = (*this)[wheel].appliedTo(grade[wheel]);
    }
    for (const GradeCurve curve : kGradeCurves) {
        if (const auto &points = (*this)[curve]) {
            grade[curve] = isIdentityCurve(*points) ? CurvePoints{} : *points;
        }
    }
    for (const GradeHueCurve curve : kGradeHueCurves) {
        if (const auto &points = (*this)[curve]) {
            grade[curve] = isIdentityHueCurve(*points) ? CurvePoints{} : *points;
        }
    }
    if (inputLut) {
        grade.inputLut = *inputLut;
    }
    if (lookLut) {
        grade.lookLut = *lookLut;
    }
    if (lookStrength) {
        grade.lookStrength = *lookStrength;
    }
    if (grade.lookLut.empty()) {
        grade.lookStrength = 1.0; // a strength belongs to a look
    }
    if (foreign) {
        grade.foreign = *foreign;
    }
    return grade;
}

SetClipGrade::SetClipGrade(SequenceId sequenceId, std::vector<ClipId> clipIds, GradeChange change, std::string name)
    : SequenceCommand(sequenceId), clipIds_(std::move(clipIds)), change_(std::move(change)), name_(std::move(name)) {
    std::string key = "grade";
    for (const GradeParameter parameter : kGradeParameters) {
        key += change_[parameter] ? ":" + std::string(nameOf(parameter)) : "";
    }
    for (const GradeWheel wheel : kGradeWheels) {
        const WheelChange &part = change_[wheel];
        key += part.level ? ":wheel-" + std::string(nameOf(wheel)) + "-level" : "";
        key += part.cb || part.cr ? ":wheel-" + std::string(nameOf(wheel)) + "-colour" : "";
    }
    for (const GradeCurve curve : kGradeCurves) {
        key += change_[curve] ? ":" + std::string(nameOf(curve)) : "";
    }
    for (const GradeHueCurve curve : kGradeHueCurves) {
        key += change_[curve] ? ":" + std::string(nameOf(curve)) : "";
    }
    key += change_.inputLut ? ":inputLut" : "";
    key += change_.lookLut ? ":lookLut" : "";
    key += change_.lookStrength ? ":lookStrength" : "";
    for (const ClipId id : clipIds_) {
        key += ":" + std::to_string(id.value());
    }
    setCoalescingKey(std::move(key));
}

std::string SetClipGrade::name() const {
    if (!name_.empty()) {
        return name_;
    }
    if (change_.count() == 0 && change_.wheelCount() == 0 && change_.curveCount() == 0 && change_.lutCount() == 1 &&
        !change_.foreign) {
        return change_.inputLut ? "Change Input LUT" : change_.lookLut ? "Change Look" : "Change Look Strength";
    }
    if (change_.count() == 0 && change_.wheelCount() == 0 && change_.curveCount() == 1 && change_.lutCount() == 0 &&
        !change_.foreign) {
        for (const GradeCurve curve : kGradeCurves) {
            if (change_[curve]) {
                return std::string("Change ") + displayNameOf(curve) + " Curve";
            }
        }
        for (const GradeHueCurve curve : kGradeHueCurves) {
            if (change_[curve]) {
                return std::string("Change ") + displayNameOf(curve) + " Curve";
            }
        }
    }
    if (change_.count() == 1 && change_.wheelCount() == 0 && change_.curveCount() == 0 && change_.lutCount() == 0 &&
        !change_.foreign) {
        for (const GradeParameter parameter : kGradeParameters) {
            if (change_[parameter]) {
                return std::string("Change ") + displayNameOf(parameter);
            }
        }
    }
    if (change_.count() == 0 && change_.wheelCount() == 1 && change_.curveCount() == 0 && change_.lutCount() == 0 &&
        !change_.foreign) {
        for (const GradeWheel wheel : kGradeWheels) {
            if (!change_[wheel].isEmpty()) {
                return std::string("Change ") + displayNameOf(wheel);
            }
        }
    }
    return "Change Grade";
}

EditResult SetClipGrade::perform(const Project &project, Sequence &sequence, IdGenerator &) {
    if (clipIds_.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "No clips to grade.");
    }
    if (change_.isEmpty()) {
        return EditResult::failure(EditError::InvalidArgument, "No grade values to set.");
    }
    for (const GradeWheel wheel : kGradeWheels) {
        const WheelChange &part = change_[wheel];
        if (part.isEmpty()) {
            continue;
        }
        // The parts given, checked on their own (the level and the colour are independent).
        const WheelValue given{part.level.value_or(0.0), part.cb.value_or(0.0), part.cr.value_or(0.0)};
        const bool halfColour = part.cb.has_value() != part.cr.has_value();
        if (halfColour || !isValidWheel(given)) {
            const auto text = [](const std::optional<double> &v) { return v ? numberText(*v) : std::string("-"); };
            return EditResult::failure(EditError::InvalidArgument,
                                       std::string("The ") + displayNameOf(wheel) +
                                           " wheel's level must be a number from -1 to 1 and its colour (both cb and "
                                           "cr) must lie within the wheel (not level " +
                                           text(part.level) + ", colour " + text(part.cb) + ", " + text(part.cr) + ").");
        }
    }
    for (const GradeParameter parameter : kGradeParameters) {
        if (const auto &value = change_[parameter]; value && !isValidGradeValue(parameter, *value)) {
            const GradeParameterInfo &info = infoOf(parameter);
            return EditResult::failure(EditError::InvalidArgument,
                                       std::string(info.displayName) + " must be a number from " +
                                           numberText(info.minimum) + " to " + numberText(info.maximum) + " (not " +
                                           numberText(*value) + ").");
        }
    }
    for (const GradeCurve curve : kGradeCurves) {
        if (const auto &points = change_[curve]) {
            if (auto problem = curveProblem(*points)) {
                return EditResult::failure(EditError::InvalidArgument, std::string("The ") + displayNameOf(curve) +
                                                                           " curve is not valid: " + *problem + ".");
            }
        }
    }
    for (const GradeHueCurve curve : kGradeHueCurves) {
        if (const auto &points = change_[curve]) {
            if (auto problem = hueCurveProblem(*points)) {
                return EditResult::failure(EditError::InvalidArgument, std::string("The ") + displayNameOf(curve) +
                                                                           " curve is not valid: " + *problem + ".");
            }
        }
    }
    for (const std::optional<std::string> *lut : {&change_.inputLut, &change_.lookLut}) {
        if (*lut && !(*lut)->empty() && project.findLut(**lut) == nullptr) {
            return EditResult::failure(EditError::InvalidArgument,
                                       "The project holds no LUT " + **lut + " (import it first).");
        }
    }
    if (change_.lookStrength &&
        (!std::isfinite(*change_.lookStrength) || *change_.lookStrength < 0.0 || *change_.lookStrength > 1.0)) {
        return EditResult::failure(EditError::InvalidArgument, "The look strength must be a number from 0 to 1 (not " +
                                                                   numberText(*change_.lookStrength) + ").");
    }
    std::unordered_set<ClipId> seen;
    for (const ClipId id : clipIds_) {
        if (!seen.insert(id).second) {
            return EditResult::failure(EditError::InvalidArgument,
                                       "Clip " + std::to_string(id.value()) + " is listed twice.");
        }
        Track *track = nullptr;
        Clip *clip = nullptr;
        if (EditResult r = findEditableClip(sequence, id, track, clip); !r) {
            return r;
        }
        if (track->kind != TrackKind::Video) {
            return EditResult::failure(EditError::TrackKindMismatch,
                                       "Clip " + std::to_string(id.value()) + " is on audio track “" + track->name +
                                           "”: a grade applies to pictures.");
        }
        if (clip->generated) {
            return EditResult::failure(EditError::InvalidArgument, "Clip " + std::to_string(id.value()) + " is a " +
                                                                       displayNameOf(clip->generated->kind()) +
                                                                       ": titles and colour mattes are not graded.");
        }
        clip->grade = change_.appliedTo(clip->grade);
    }
    return EditResult::success();
}

SetClipGradeWithLuts::SetClipGradeWithLuts(std::vector<std::shared_ptr<const CubeLut>> luts,
                                           std::unique_ptr<SetClipGrade> grade)
    : luts_(std::move(luts)), grade_(std::move(grade)) {
    for (const auto &lut : luts_) {
        ids_.push_back(lut ? cubeContentId(*lut) : std::string());
    }
    setCoalescingKey(grade_->coalescingKey() + ":luts");
}

EditResult SetClipGradeWithLuts::apply(Project &project) {
    added_.clear();
    for (std::size_t i = 0; i < luts_.size(); ++i) {
        if (!luts_[i]) {
            return EditResult::failure(EditError::InvalidArgument, "No LUT to add.");
        }
        if (auto problem = cubeProblem(*luts_[i])) {
            return EditResult::failure(EditError::InvalidArgument, "The LUT is not valid: " + *problem + ".");
        }
    }
    for (std::size_t i = 0; i < luts_.size(); ++i) {
        if (project.luts.find(ids_[i]) == project.luts.end()) {
            project.luts.emplace(ids_[i], luts_[i]);
            added_.push_back(ids_[i]);
        }
    }
    EditResult result = grade_->apply(project);
    if (!result.ok() || grade_->isNoOp()) {
        for (const std::string &id : added_) {
            project.luts.erase(id);
        }
        added_.clear();
    }
    return result;
}

void SetClipGradeWithLuts::revert(Project &project) const {
    if (!canRevert(project)) {
        return;
    }
    grade_->revert(project);
    for (const std::string &id : added_) {
        project.luts.erase(id);
    }
}

bool SetClipGradeWithLuts::canRevert(const Project &project) const {
    for (const std::string &id : added_) {
        if (project.luts.find(id) == project.luts.end()) {
            return false;
        }
    }
    return grade_->canRevert(project);
}

bool SetClipGradeWithLuts::isNoOp() const {
    return grade_->isNoOp();
}

std::string SetClipGradeWithLuts::name() const {
    return grade_->name();
}

GradeSummary summarizeGrades(const Sequence &sequence, const std::vector<ClipId> &clipIds) {
    GradeSummary summary;
    summary.clips = gradeTargets(sequence, clipIds);
    summary.identical = !summary.clips.empty();
    const ClipGrade *firstGrade = nullptr;
    for (std::size_t n = 0; n < summary.clips.size(); ++n) {
        const ClipGrade &grade = sequence.findClip(summary.clips[n])->grade;
        summary.anyGraded = summary.anyGraded || !grade.isNeutral();
        if (n == 0) {
            firstGrade = &grade;
        } else if (grade != *firstGrade) {
            summary.identical = false;
        }
        for (const GradeParameter parameter : kGradeParameters) {
            const auto i = static_cast<std::size_t>(parameter);
            if (n == 0) {
                summary.values[i] = grade[parameter];
            } else if (summary.values[i] && *summary.values[i] != grade[parameter]) {
                summary.values[i] = std::nullopt;
                summary.mixed[i] = true;
            }
        }
        for (const GradeWheel wheel : kGradeWheels) {
            const auto i = static_cast<std::size_t>(wheel);
            if (n == 0) {
                summary.wheels[i] = grade[wheel];
            } else if (summary.wheels[i] && *summary.wheels[i] != grade[wheel]) {
                summary.wheels[i] = std::nullopt;
                summary.wheelMixed[i] = true;
            }
        }
        for (const GradeCurve curve : kGradeCurves) {
            const auto i = static_cast<std::size_t>(curve);
            if (n == 0) {
                summary.curves[i] = grade[curve];
            } else if (summary.curves[i] && *summary.curves[i] != grade[curve]) {
                summary.curves[i] = std::nullopt;
                summary.curveMixed[i] = true;
            }
        }
        for (const GradeHueCurve curve : kGradeHueCurves) {
            const auto i = static_cast<std::size_t>(curve);
            if (n == 0) {
                summary.hueCurves[i] = grade[curve];
            } else if (summary.hueCurves[i] && *summary.hueCurves[i] != grade[curve]) {
                summary.hueCurves[i] = std::nullopt;
                summary.hueCurveMixed[i] = true;
            }
        }
        if (n == 0) {
            summary.inputLut = grade.inputLut;
            summary.lookLut = grade.lookLut;
            summary.lookStrength = grade.lookStrength;
        } else {
            if (summary.inputLut && *summary.inputLut != grade.inputLut) {
                summary.inputLut = std::nullopt;
            }
            if (summary.lookLut && *summary.lookLut != grade.lookLut) {
                summary.lookLut = std::nullopt;
            }
            if (summary.lookStrength && *summary.lookStrength != grade.lookStrength) {
                summary.lookStrength = std::nullopt;
            }
        }
    }
    return summary;
}

std::vector<ClipId> gradeTargets(const Sequence &sequence, const std::vector<ClipId> &clipIds) {
    std::vector<ClipId> targets;
    std::unordered_set<ClipId> seen;
    for (const ClipId id : clipIds) {
        const Track *track = sequence.trackOfClip(id);
        if (track != nullptr && track->kind == TrackKind::Video && !track->find(id)->generated &&
            seen.insert(id).second) {
            targets.push_back(id);
        }
    }
    return targets;
}

} // namespace ve
