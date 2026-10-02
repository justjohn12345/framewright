// VEEngine (Grade): a clip's colour grade. The edit rules are in Engine/Edit/GradeEdits.h
// (SetClipGrade, summarizeGrades, gradeTargets); this file converts and keeps what Copy Grade copied.

#import "VEEngine+Internal.h"

#include "../Edit/GradeEdits.h"

#include <cmath>
#include <memory>

using namespace ve;
using namespace ve::facade;

@implementation VEEngine (Grade)

// MARK: - Grade

/// The clips of `clipIDs` a grade edit applies to: every id but those of clips on audio tracks (an id
/// that names no clip stays, so the command refuses it). Empty, with `refusal` set, when nothing is left.
- (std::vector<ClipId>)gradeEditClips:(NSArray<NSNumber *> *)clipIDs refusal:(VEEditResult *__autoreleasing *)refusal {
    const Sequence &sequence = [self activeSequence];
    std::vector<ClipId> clips;
    clips.reserve(clipIDs.count);
    for (NSNumber *number : clipIDs) {
        const ClipId id = toClipId(number.longLongValue);
        const Track *track = sequence.trackOfClip(id);
        if (track == nullptr || track->kind == TrackKind::Video) {
            clips.push_back(id);
        }
    }
    if (clips.empty()) {
        *refusal = clipIDs.count == 0
                       ? [VEEditResult failureWithMessage:@"Nothing selected."]
                       : [VEEditResult failureWithCode:VEEditErrorTrackKindMismatch
                                               message:@"A grade applies to pictures: select a clip on a video track."];
    }
    return clips;
}

- (VEEditResult *)pushGradeChange:(GradeChange)change
                         forClips:(NSArray<NSNumber *> *)clipIDs
                             name:(std::string)name {
    VEEditResult *refusal = nil;
    std::vector<ClipId> clips = [self gradeEditClips:clipIDs refusal:&refusal];
    if (clips.empty()) {
        return refusal;
    }
    return [self push:std::make_unique<SetClipGrade>([self sequenceId], std::move(clips), std::move(change),
                                                     std::move(name))
              created:nil];
}

- (VEEditResult *)setGradeValues:(VEGradeParams)values forClips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    GradeChange change;
    for (const GradeParameter parameter : kGradeParameters) {
        const double value = gradeValueIn(values, parameter);
        if (!std::isnan(value)) {
            change[parameter] = value;
        }
    }
    if (change.count() == 0) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"No grade values to set."];
    }
    return [self pushGradeChange:std::move(change) forClips:clipIDs name:{}];
}

- (VEEditResult *)setGradeValue:(double)value
                   forParameter:(VEGradeParameter)parameter
                          clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    const auto gradeParameter = fromVE(parameter);
    if (!gradeParameter) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"Unknown grade parameter."];
    }
    if (std::isnan(value)) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"No grade value to set."];
    }
    return [self pushGradeChange:GradeChange::of(*gradeParameter, value) forClips:clipIDs name:{}];
}

- (VEEditResult *)setGradeWheel:(VEGradeWheelValue)value
                       forWheel:(VEGradeWheel)wheel
                          clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    const auto gradeWheel = fromVE(wheel);
    if (!gradeWheel) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"Unknown grade wheel."];
    }
    WheelChange change;
    if (!std::isnan(value.level)) {
        change.level = value.level;
    }
    if (!std::isnan(value.cb)) {
        change.cb = value.cb;
    }
    if (!std::isnan(value.cr)) {
        change.cr = value.cr;
    }
    if (change.isEmpty()) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"No wheel setting to set."];
    }
    return [self pushGradeChange:GradeChange::of(*gradeWheel, change) forClips:clipIDs name:{}];
}

- (VEEditResult *)setGradeCurvePoints:(NSArray<NSValue *> *)points
                             forCurve:(VEGradeCurve)curve
                                clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    const auto gradeCurve = fromVE(curve);
    if (!gradeCurve) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"Unknown grade curve."];
    }
    return [self pushGradeChange:GradeChange::of(*gradeCurve, fromVE(points)) forClips:clipIDs name:{}];
}

- (VEEditResult *)resetGradeCurvesOfClips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    GradeChange change;
    for (const GradeCurve curve : kGradeCurves) {
        change[curve] = CurvePoints{};
    }
    return [self pushGradeChange:std::move(change) forClips:clipIDs name:"Reset Curves"];
}

- (VEEditResult *)resetGradeWheelsOfClips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    GradeChange change;
    for (const GradeWheel wheel : kGradeWheels) {
        change[wheel] = WheelChange::whole(WheelValue{});
    }
    return [self pushGradeChange:std::move(change) forClips:clipIDs name:"Reset Wheels"];
}

- (VEGradeSelection *)gradeOfClips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    std::vector<ClipId> ids;
    ids.reserve(clipIDs.count);
    for (NSNumber *number : clipIDs) {
        ids.push_back(toClipId(number.longLongValue));
    }
    return makeGradeSelection(summarizeGrades([self activeSequence], ids));
}

- (BOOL)copyGradeOfClip:(VEClipID)clipID {
    VE_ASSERT_MAIN();
    const Sequence &sequence = [self activeSequence];
    const ClipId id = toClipId(clipID);
    const Track *track = sequence.trackOfClip(id);
    if (track == nullptr || track->kind != TrackKind::Video) {
        return NO;
    }
    _copiedGrade = track->find(id)->grade;
    return YES;
}

- (BOOL)hasCopiedGrade {
    VE_ASSERT_MAIN();
    return _copiedGrade.has_value();
}

- (VEGradeParams)copiedGrade {
    VE_ASSERT_MAIN();
    return toVE(_copiedGrade.value_or(ClipGrade{}));
}

- (VEEditResult *)pasteGradeOntoClips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    if (!_copiedGrade) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"No grade has been copied."];
    }
    return [self pushGradeChange:GradeChange::whole(*_copiedGrade) forClips:clipIDs name:"Paste Grade"];
}

- (VEEditResult *)resetGradeOfClips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    return [self pushGradeChange:GradeChange::whole(ClipGrade{}) forClips:clipIDs name:"Reset Grade"];
}

@end
