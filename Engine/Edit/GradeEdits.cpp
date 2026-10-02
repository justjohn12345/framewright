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
    change.foreign = grade.foreign;
    return change;
}

std::size_t GradeChange::curveCount() const {
    std::size_t n = 0;
    for (const auto &curve : curves) {
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
    for (const ClipId id : clipIds_) {
        key += ":" + std::to_string(id.value());
    }
    setCoalescingKey(std::move(key));
}

std::string SetClipGrade::name() const {
    if (!name_.empty()) {
        return name_;
    }
    if (change_.count() == 0 && change_.wheelCount() == 0 && change_.curveCount() == 1 && !change_.foreign) {
        for (const GradeCurve curve : kGradeCurves) {
            if (change_[curve]) {
                return std::string("Change ") + displayNameOf(curve) + " Curve";
            }
        }
    }
    if (change_.count() == 1 && change_.wheelCount() == 0 && change_.curveCount() == 0 && !change_.foreign) {
        for (const GradeParameter parameter : kGradeParameters) {
            if (change_[parameter]) {
                return std::string("Change ") + displayNameOf(parameter);
            }
        }
    }
    if (change_.count() == 0 && change_.wheelCount() == 1 && change_.curveCount() == 0 && !change_.foreign) {
        for (const GradeWheel wheel : kGradeWheels) {
            if (!change_[wheel].isEmpty()) {
                return std::string("Change ") + displayNameOf(wheel);
            }
        }
    }
    return "Change Grade";
}

EditResult SetClipGrade::perform(const Project &, Sequence &sequence, IdGenerator &) {
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
        clip->grade = change_.appliedTo(clip->grade);
    }
    return EditResult::success();
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
    }
    return summary;
}

std::vector<ClipId> gradeTargets(const Sequence &sequence, const std::vector<ClipId> &clipIds) {
    std::vector<ClipId> targets;
    std::unordered_set<ClipId> seen;
    for (const ClipId id : clipIds) {
        const Track *track = sequence.trackOfClip(id);
        if (track != nullptr && track->kind == TrackKind::Video && seen.insert(id).second) {
            targets.push_back(id);
        }
    }
    return targets;
}

} // namespace ve
