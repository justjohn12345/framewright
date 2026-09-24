// Obj-C++ constructors of the facade's snapshot types (VETypes.h) from model values.
// Private to the facade implementation: excluded from the framework's headers (project.yml).

#pragma once

#import "VETypes.h"

#include "../Edit/EditOps.h"
#include "../Edit/EditResult.h"
#include "../Model/Project.h"
#include "../Playback/PlaybackController.h"
#include "../Thumbs/WaveformService.h"

#include <memory>
#include <optional>
#include <string>

namespace ve::facade {

/// Probe details kept by the facade per asset (not stored in the project file).
struct AssetDetails {
    std::string codecName;
    std::string audioCodecName;
    std::string container;
    std::string routingReason;
};

VEVideoParams toVE(const VideoParams &params);
VideoParams fromVE(const VEVideoParams &params);
VEAudioParams toVE(const AudioParams &params);
AudioParams fromVE(const VEAudioParams &params);
VEMotionParameter toVE(MotionParameter parameter);
MotionParameter fromVE(VEMotionParameter parameter);
VEKeyframeInterpolation toVE(KeyframeInterpolation interpolation);
/// Nullopt for a value outside the enumeration.
std::optional<KeyframeInterpolation> fromVE(VEKeyframeInterpolation interpolation);

VEAssetInfo *makeAssetInfo(const MediaAsset &asset, const AssetDetails *details, bool missing, NSInteger useCount);
/// `frameDuration`: the sequence's (keyframe queries map frames to source spans).
VEClipInfo *makeClipInfo(const Clip &clip, const Track &track, const Project &project, CMTime frameDuration);
VETrackInfo *makeTrackInfo(const Track &track, NSInteger index);
VETransitionInfo *makeTransitionInfo(const Transition &transition, const Sequence &sequence);
VESequenceInfo *makeSequenceInfo(const Sequence &sequence);
VEHardwareCaps *makeHardwareCaps();
VEWaveform *makeWaveform(AssetId asset, const std::shared_ptr<const thumbs::WaveformPeaks> &peaks);

VEEditErrorCode toVE(EditError error);
/// The facade's result for an engine edit result (`note` may be nil). Dropped transitions are
/// listed and mentioned in the note.
VEEditResult *makeEditResult(const EditResult &result, NSArray<NSNumber *> *created,
                             NSString *note);
VETransitionLimit *makeTransitionLimit(const TransitionLimit &limit);
/// A keyframe group snapshot; `refusal` (nil or "" when the group can move) makes it fixed on `frame`.
VEKeyframeGroup *makeKeyframeGroup(ClipId clipId, CMTime frame, const std::vector<MotionParameter> &parameters,
                                   CMTime earliestFrame, CMTime latestFrame, NSString *refusal);
VEPlaybackState playbackStateToVE(playback::PlaybackState state);
VEPlaybackStatus *makePlaybackStatus(const playback::PlaybackStatus &status);
VEPlaybackStats *makePlaybackStats(const playback::PlaybackStats &stats, const playback::PresentedFrame &presented);

/// "29.97", "25", "23.976" for a frame duration; "" when not positive.
NSString *fpsString(CMTime frameDuration);

inline NSString *toNS(const std::string &s) {
    NSString *string = [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding];
    return string ?: @"";
}
inline std::string toStd(NSString *s) {
    const char *utf8 = s.UTF8String;
    return utf8 != nullptr ? std::string(utf8) : std::string();
}

} // namespace ve::facade
