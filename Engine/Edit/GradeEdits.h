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
// - gradeTargets picks the clips of a selection that can have a grade (those on video tracks): a
//   selection of linked picture and sound grades the pictures.
//
// Plain C++ (CoreMedia's CMTime only): unit-testable without media.

#pragma once

#include "Command.h"

#include <array>
#include <optional>
#include <string>
#include <vector>

namespace ve {

// What SetClipGrade sets on each clip: the values given (nullopt: the clip keeps its own) and, for a
// whole grade, the foreign entries (nullopt: the clip keeps its own).
struct GradeChange {
    std::array<std::optional<double>, kGradeParameterCount> values{};
    std::optional<std::string> foreign;

    // One parameter.
    static GradeChange of(GradeParameter parameter, double value);
    // Every parameter and the foreign entries of `grade` (Paste Grade; the neutral grade: Reset Grade).
    static GradeChange whole(const ClipGrade &grade);

    std::optional<double> &operator[](GradeParameter parameter) {
        return values[static_cast<std::size_t>(parameter)];
    }
    const std::optional<double> &operator[](GradeParameter parameter) const {
        return values[static_cast<std::size_t>(parameter)];
    }
    // The number of values given.
    std::size_t count() const;
    // `grade` with the change applied.
    ClipGrade appliedTo(ClipGrade grade) const;
};

// Sets grade parameters on clips (see the header). Refused as a whole, changing nothing, when the list
// or the change is empty, a clip is missing or listed twice, a clip lies on an audio track
// (TrackKindMismatch: a grade is for pictures) or a locked track, or a value is not finite or outside its
// parameter's range (InvalidArgument, naming the range). A change that leaves every clip as it was
// records no undo step.
class SetClipGrade final : public SequenceCommand {
  public:
    // `name` is the Undo menu's name; empty: "Change <parameter>" for one parameter, else "Change Grade".
    SetClipGrade(SequenceId sequenceId, std::vector<ClipId> clipIds, GradeChange change, std::string name = {});
    std::string name() const override;

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    std::vector<ClipId> clipIds_;
    GradeChange change_;
    std::string name_;
};

// What a selection's clips have for each grade parameter.
struct GradeSummary {
    // The clips of the selection that have a grade (on video tracks), in the order given.
    std::vector<ClipId> clips;
    // Per parameter: the value every one of `clips` has, or nullopt when they differ or there are none.
    std::array<std::optional<double>, kGradeParameterCount> values{};
    // Per parameter: whether the clips differ.
    std::array<bool, kGradeParameterCount> mixed{};
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
};

// The summary of the clips of `clipIds` in `sequence` that can have a grade; ids that name no clip,
// and clips on audio tracks, are left out.
GradeSummary summarizeGrades(const Sequence &sequence, const std::vector<ClipId> &clipIds);

// The clips of `clipIds` that can have a grade (on video tracks), in the order given, each once; ids
// that name no clip are left out (the edit then refuses nothing for them).
std::vector<ClipId> gradeTargets(const Sequence &sequence, const std::vector<ClipId> &clipIds);

} // namespace ve
