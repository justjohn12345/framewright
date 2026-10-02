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

GradeChange GradeChange::whole(const ClipGrade &grade) {
    GradeChange change;
    for (const GradeParameter parameter : kGradeParameters) {
        change[parameter] = grade[parameter];
    }
    change.foreign = grade.foreign;
    return change;
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
    for (const ClipId id : clipIds_) {
        key += ":" + std::to_string(id.value());
    }
    setCoalescingKey(std::move(key));
}

std::string SetClipGrade::name() const {
    if (!name_.empty()) {
        return name_;
    }
    if (change_.count() == 1 && !change_.foreign) {
        for (const GradeParameter parameter : kGradeParameters) {
            if (change_[parameter]) {
                return std::string("Change ") + displayNameOf(parameter);
            }
        }
    }
    return "Change Grade";
}

EditResult SetClipGrade::perform(const Project &, Sequence &sequence, IdGenerator &) {
    if (clipIds_.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "No clips to grade.");
    }
    if (change_.count() == 0 && !change_.foreign) {
        return EditResult::failure(EditError::InvalidArgument, "No grade values to set.");
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
    for (std::size_t n = 0; n < summary.clips.size(); ++n) {
        const ClipGrade &grade = sequence.findClip(summary.clips[n])->grade;
        summary.anyGraded = summary.anyGraded || !grade.isNeutral();
        for (const GradeParameter parameter : kGradeParameters) {
            const auto i = static_cast<std::size_t>(parameter);
            if (n == 0) {
                summary.values[i] = grade[parameter];
            } else if (summary.values[i] && *summary.values[i] != grade[parameter]) {
                summary.values[i] = std::nullopt;
                summary.mixed[i] = true;
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
