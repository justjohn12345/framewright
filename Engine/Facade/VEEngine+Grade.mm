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

/// The clips of `clipIDs` a grade edit applies to: every id but those of clips on audio tracks and of titles and
/// colour mattes, which have no grade (an id that names no clip stays, so the command refuses it). Empty, with
/// `refusal` set, when nothing is left.
- (std::vector<ClipId>)gradeEditClips:(NSArray<NSNumber *> *)clipIDs refusal:(VEEditResult *__autoreleasing *)refusal {
    const Sequence &sequence = [self activeSequence];
    std::vector<ClipId> clips;
    clips.reserve(clipIDs.count);
    bool generated = false;
    for (NSNumber *number : clipIDs) {
        const ClipId id = toClipId(number.longLongValue);
        const Track *track = sequence.trackOfClip(id);
        const Clip *clip = track != nullptr ? track->find(id) : nullptr;
        if (clip != nullptr && clip->generated) {
            generated = true;
            continue;
        }
        if (track == nullptr || track->kind == TrackKind::Video) {
            clips.push_back(id);
        }
    }
    if (clips.empty()) {
        *refusal = clipIDs.count == 0 ? [VEEditResult failureWithMessage:@"Nothing selected."]
                   : generated        ? [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                                       message:@"Titles and colour mattes are not graded."]
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

// MARK: - LUTs

- (nullable VELUTInfo *)importLUTAtURL:(NSURL *)url error:(NSError **)error {
    VE_ASSERT_MAIN();
    NSError *readError = nil;
    NSData *data = url.isFileURL ? [NSData dataWithContentsOfURL:url options:0 error:&readError] : nil;
    if (data == nil) {
        if (error != nullptr) {
            *error = makeError(VEEngineErrorImportFailed,
                               [NSString stringWithFormat:@"“%@” cannot be read: %@", url.lastPathComponent,
                                                          readError.localizedDescription ?: @"not a file"]);
        }
        return nil;
    }
    CubeParseResult parsed =
        parseCube(std::string_view(static_cast<const char *>(data.bytes), static_cast<std::size_t>(data.length)));
    if (!parsed.lut) {
        if (error != nullptr) {
            *error = makeError(VEEngineErrorImportFailed,
                               [NSString stringWithFormat:@"“%@” is not a LUT Framewright can use: %@",
                                                          url.lastPathComponent, toNS(parsed.error)]);
        }
        return nil;
    }
    CubeLut lut = std::move(*parsed.lut);
    lut.fileName = url.lastPathComponent.UTF8String ?: "";
    lut.sourcePath = url.path.UTF8String ?: "";
    const std::string lutId = cubeContentId(lut);
    if (const CubeLut *held = _project.findLut(lutId)) {
        return makeLUTInfo(lutId, *held);
    }
    auto [entry, inserted] = _importedLuts.emplace(lutId, std::make_shared<const CubeLut>(std::move(lut)));
    return makeLUTInfo(lutId, *entry->second);
}

/// The LUT of `lutId`: the project's, else one imported this session (nullptr for neither).
- (std::shared_ptr<const CubeLut>)heldLut:(const std::string &)lutId {
    if (const auto found = _project.luts.find(lutId); found != _project.luts.end()) {
        return found->second;
    }
    if (const auto found = _importedLuts.find(lutId); found != _importedLuts.end()) {
        return found->second;
    }
    return nullptr;
}

- (nullable VELUTInfo *)lutWithID:(NSString *)lutID {
    VE_ASSERT_MAIN();
    const std::string lutId = lutID.UTF8String ?: "";
    const std::shared_ptr<const CubeLut> lut = [self heldLut:lutId];
    return lut ? makeLUTInfo(lutId, *lut) : nil;
}

/// Sets the input LUT (`input`) or the look of the clips: a SetClipGrade, wrapped to add the LUT to the
/// project when it holds it not yet.
- (VEEditResult *)setLut:(nullable NSString *)lutID input:(BOOL)input clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    const std::string lutId = lutID.UTF8String ?: "";
    GradeChange change;
    (input ? change.inputLut : change.lookLut) = lutId;
    std::shared_ptr<const CubeLut> lut;
    if (!lutId.empty()) {
        lut = [self heldLut:lutId];
        if (!lut) {
            return [VEEditResult failureWithCode:VEEditErrorInvalidArgument
                                         message:@"That LUT is not in the project; import it first."];
        }
    }
    VEEditResult *refusal = nil;
    std::vector<ClipId> clips = [self gradeEditClips:clipIDs refusal:&refusal];
    if (clips.empty()) {
        return refusal;
    }
    auto grade = std::make_unique<SetClipGrade>([self sequenceId], std::move(clips), std::move(change));
    if (!lut) {
        return [self push:std::move(grade) created:nil];
    }
    return [self push:std::make_unique<SetClipGradeWithLuts>(std::vector<std::shared_ptr<const CubeLut>>{lut},
                                                              std::move(grade))
              created:nil];
}

- (VEEditResult *)setGradeInputLUT:(nullable NSString *)lutID clips:(NSArray<NSNumber *> *)clipIDs {
    return [self setLut:lutID input:YES clips:clipIDs];
}

- (VEEditResult *)setGradeLook:(nullable NSString *)lutID clips:(NSArray<NSNumber *> *)clipIDs {
    return [self setLut:lutID input:NO clips:clipIDs];
}

- (VEEditResult *)setGradeLookStrength:(double)strength clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    GradeChange change;
    change.lookStrength = strength;
    return [self pushGradeChange:std::move(change) forClips:clipIDs name:{}];
}

- (VEEditResult *)setGradeHueCurvePoints:(NSArray<NSValue *> *)points
                             forHueCurve:(VEGradeHueCurve)curve
                                   clips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    const auto hueCurve = fromVE(curve);
    if (!hueCurve) {
        return [VEEditResult failureWithCode:VEEditErrorInvalidArgument message:@"Unknown hue curve."];
    }
    return [self pushGradeChange:GradeChange::of(*hueCurve, fromVE(points)) forClips:clipIDs name:{}];
}

- (VEEditResult *)resetGradeCurvesOfClips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    GradeChange change;
    for (const GradeCurve curve : kGradeCurves) {
        change[curve] = CurvePoints{};
    }
    for (const GradeHueCurve curve : kGradeHueCurves) {
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
    if (track == nullptr || track->kind != TrackKind::Video || track->find(id)->generated) {
        return NO; // sound, titles and colour mattes have no grade
    }
    _copiedGrade = track->find(id)->grade;
    _copiedLuts.clear();
    for (const std::string *lut : {&_copiedGrade->inputLut, &_copiedGrade->lookLut}) {
        if (!lut->empty()) {
            if (const auto found = _project.luts.find(*lut); found != _project.luts.end()) {
                _copiedLuts.push_back(found->second);
            }
        }
    }
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
    if (_copiedLuts.empty()) {
        return [self pushGradeChange:GradeChange::whole(*_copiedGrade) forClips:clipIDs name:"Paste Grade"];
    }
    // The copied grade's LUTs go with it, into another project too.
    VEEditResult *refusal = nil;
    std::vector<ClipId> clips = [self gradeEditClips:clipIDs refusal:&refusal];
    if (clips.empty()) {
        return refusal;
    }
    auto grade = std::make_unique<SetClipGrade>([self sequenceId], std::move(clips), GradeChange::whole(*_copiedGrade),
                                                "Paste Grade");
    return [self push:std::make_unique<SetClipGradeWithLuts>(_copiedLuts, std::move(grade)) created:nil];
}

- (VEEditResult *)resetGradeOfClips:(NSArray<NSNumber *> *)clipIDs {
    VE_ASSERT_MAIN();
    return [self pushGradeChange:GradeChange::whole(ClipGrade{}) forClips:clipIDs name:"Reset Grade"];
}

@end
