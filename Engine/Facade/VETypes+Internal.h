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
/// The clip's gain and the lengths of its lane-0 fades.
VEAudioParams audioParamsOf(const Clip &clip);
/// The static gain of `params` (its fades are lane-0 spans: see ClipParamsChange).
AudioParams fromVE(const VEAudioParams &params);
VEMotionParameter toVE(MotionParameter parameter);
/// Nullopt for a value outside the enumeration.
std::optional<MotionParameter> fromVE(VEMotionParameter parameter);
VEKeyframeInterpolation toVE(KeyframeInterpolation interpolation);
/// Nullopt for a value outside the enumeration.
std::optional<KeyframeInterpolation> fromVE(VEKeyframeInterpolation interpolation);
VESpanKind toVE(SpanKind kind);
/// Nullopt for a value outside the enumeration.
std::optional<SpanKind> fromVE(VESpanKind kind);
VETransitionStyle toVE(TransitionRole role);
/// The value of `parameter` in `values`.
double spanValueIn(const VESpanValues &values, SpanParameter parameter);

VEAssetInfo *makeAssetInfo(const MediaAsset &asset, const AssetDetails *details, bool missing, NSInteger useCount);
// `index` (optional): the sequence's clips by id, when many snapshots are made at once (review L9).
VEClipInfo *makeClipInfo(const Clip &clip, const Track &track, const Project &project, const Sequence &sequence,
                         const ClipIndex *index = nullptr);
VETrackInfo *makeTrackInfo(const Track &track, NSInteger index);
VEEffectSpan *makeEffectSpan(const EffectSpan &span, const Clip &clip, const Track &track, const Sequence &sequence,
                             const ClipIndex *index = nullptr);
VETransitionInfo *makeTransitionInfo(const TransitionPlacement &transition);
VESequenceInfo *makeSequenceInfo(const Sequence &sequence);
VEHardwareCaps *makeHardwareCaps();
VEWaveform *makeWaveform(AssetId asset, const std::shared_ptr<const thumbs::WaveformPeaks> &peaks);

VEEditErrorCode toVE(EditError error);
/// The facade's result for an engine edit result (`note` may be nil, `span` the span after a
/// successful span edit). Dropped transitions and spans are listed and mentioned in the note; a
/// refusal's free range is passed on.
VEEditResult *makeEditResult(const EditResult &result, NSArray<NSNumber *> *created, NSString *note,
                             VEEffectSpan *span = nil);
VETransitionLimit *makeTransitionLimit(const TransitionLimit &limit);
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
