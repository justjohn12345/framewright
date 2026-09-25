#import "VETypes+Internal.h"

#include "../Media/HardwareCaps.h"
#include "../Media/MediaTypes.h"

#include "../Edit/EditOps.h"

#include <algorithm>
#include <cmath>
#include <limits>

VEVideoParams VEVideoParamsIdentity(void) {
    return ve::facade::toVE(ve::VideoParams{});
}

VEAudioParams VEAudioParamsDefault(void) {
    return VEAudioParams{0.0, kCMTimeZero, kCMTimeZero};
}

VESpanValues VESpanValuesUnchanged(void) {
    const double nan = std::numeric_limits<double>::quiet_NaN();
    return VESpanValues{nan, nan, nan, nan, nan, nan};
}

// MARK: - Class extensions (writable for the factories below)

@interface VEAssetInfo ()
@property (nonatomic, readwrite) VEAssetID assetID;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite, copy) NSString *path;
@property (nonatomic, readwrite) VEAssetKind kind;
@property (nonatomic, readwrite) CMTime duration;
@property (nonatomic, readwrite) NSInteger width;
@property (nonatomic, readwrite) NSInteger height;
@property (nonatomic, readwrite) NSInteger rotationDegrees;
@property (nonatomic, readwrite) CMTime frameDuration;
@property (nonatomic, readwrite, copy) NSString *fpsString;
@property (nonatomic, readwrite) BOOL isVFR;
@property (nonatomic, readwrite) NSInteger sampleRate;
@property (nonatomic, readwrite) NSInteger channels;
@property (nonatomic, readwrite, copy) NSString *backendName;
@property (nonatomic, readwrite) BOOL hardwareDecode;
@property (nonatomic, readwrite, copy) NSString *codecName;
@property (nonatomic, readwrite, copy) NSString *audioCodecName;
@property (nonatomic, readwrite, copy) NSString *container;
@property (nonatomic, readwrite, copy) NSString *routingReason;
@property (nonatomic, readwrite) BOOL isMissing;
@property (nonatomic, readwrite) BOOL hasVideo;
@property (nonatomic, readwrite) BOOL hasAudio;
@property (nonatomic, readwrite) BOOL isStill;
@property (nonatomic, readwrite) NSInteger useCount;
- (instancetype)initInternal;
@end

@interface VEEffectSpan ()
@property (nonatomic, readwrite) VESpanID spanID;
@property (nonatomic, readwrite) VEClipID clipID;
@property (nonatomic, readwrite) VETrackID trackID;
@property (nonatomic, readwrite) NSInteger lane;
@property (nonatomic, readwrite) VESpanKind kind;
@property (nonatomic, readwrite) CMTime clipRelativeStart;
@property (nonatomic, readwrite) CMTime clipRelativeEnd;
@property (nonatomic, readwrite) CMTime start;
@property (nonatomic, readwrite) CMTime end;
@property (nonatomic, readwrite) VESpanValues startValues;
@property (nonatomic, readwrite) VESpanValues endValues;
@property (nonatomic, readwrite) VEKeyframeInterpolation interpolation;
@property (nonatomic, readwrite) VETransitionStyle transitionStyle;
@property (nonatomic, readwrite) CMTime duration;
@property (nonatomic, readwrite) CMTime shareBeforeCut;
@property (nonatomic, readwrite) CMTime shareAfterCut;
@property (nonatomic, readwrite) VEClipID partnerClipID;
@property (nonatomic, readwrite) VESpanID linkedSpanID;
- (instancetype)initInternal;
@end

@interface VEClipInfo () {
  @public
    ve::Clip _clip; // the clip as it was (for the evaluations)
}
@property (nonatomic, readwrite) VEClipID clipID;
@property (nonatomic, readwrite) VEAssetID assetID;
@property (nonatomic, readwrite) VETrackID trackID;
@property (nonatomic, readwrite) VETrackKind trackKind;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite) CMTime timelineStart;
@property (nonatomic, readwrite) CMTime duration;
@property (nonatomic, readwrite) CMTime timelineEnd;
@property (nonatomic, readwrite) CMTime sourceIn;
@property (nonatomic, readwrite) CMTime sourceOut;
@property (nonatomic, readwrite) double speed;
@property (nonatomic, readwrite) int64_t speedNumerator;
@property (nonatomic, readwrite) int64_t speedDenominator;
@property (nonatomic, readwrite) BOOL isStill;
@property (nonatomic, readwrite) VEClipID linkedClipID;
@property (nonatomic, readwrite) VEVideoParams videoParams;
@property (nonatomic, readwrite) VEAudioParams audioParams;
@property (nonatomic, readwrite, copy) NSArray<VEEffectSpan *> *spans;
- (instancetype)initInternal;
@end

@interface VETrackInfo ()
@property (nonatomic, readwrite) VETrackID trackID;
@property (nonatomic, readwrite) VETrackKind kind;
@property (nonatomic, readwrite) NSInteger index;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite) BOOL muted;
@property (nonatomic, readwrite) BOOL solo;
@property (nonatomic, readwrite) BOOL locked;
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *clipIDs;
- (instancetype)initInternal;
@end

@interface VETransitionInfo ()
@property (nonatomic, readwrite) VETransitionID transitionID;
@property (nonatomic, readwrite) VETrackID trackID;
@property (nonatomic, readwrite) VEClipID fromClipID;
@property (nonatomic, readwrite) VEClipID toClipID;
@property (nonatomic, readwrite) VETransitionStyle style;
@property (nonatomic, readwrite) CMTime duration;
@property (nonatomic, readwrite) CMTime start;
@property (nonatomic, readwrite) CMTime end;
@property (nonatomic, readwrite) CMTime shareBeforeCut;
@property (nonatomic, readwrite) CMTime shareAfterCut;
- (instancetype)initInternal;
@end

@interface VESequenceInfo ()
@property (nonatomic, readwrite) VESequenceID sequenceID;
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite) CMTime frameDuration;
@property (nonatomic, readwrite) NSInteger width;
@property (nonatomic, readwrite) NSInteger height;
@property (nonatomic, readwrite) NSInteger audioSampleRate;
@property (nonatomic, readwrite) CMTime duration;
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *videoTrackIDs;
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *audioTrackIDs;
@property (nonatomic, readwrite, copy) NSArray<VETransitionInfo *> *transitions;
- (instancetype)initInternal;
@end

@interface VEEditResult ()
- (instancetype)initWithCode:(VEEditErrorCode)code
                     message:(NSString *)message
                  createdIDs:(NSArray<NSNumber *> *)createdIDs
                     dropped:(NSArray<NSNumber *> *)dropped
                droppedSpans:(NSArray<NSNumber *> *)droppedSpans
                   freeRange:(CMTimeRange)freeRange
                        span:(nullable VEEffectSpan *)span
                        note:(NSString *)note;
@end

@interface VETransitionLimit ()
@property (nonatomic, readwrite) CMTime maximumDuration;
@property (nonatomic, readwrite) int64_t maximumFrames;
@property (nonatomic, readwrite) VEEditErrorCode limitingError;
@property (nonatomic, readwrite, copy) NSString *reason;
@property (nonatomic, readwrite) VEClipID limitingClipID;
- (instancetype)initInternal;
@end

@interface VEPlaybackStatus ()
@property (nonatomic, readwrite) VEPlaybackState state;
@property (nonatomic, readwrite) CMTime time;
@property (nonatomic, readwrite) double rate;
@property (nonatomic, readwrite) BOOL audioActive;
@property (nonatomic, readwrite, copy) NSString *errorMessage;
- (instancetype)initInternal;
@end

@interface VEActiveClipInfo ()
@property (nonatomic, readwrite) VEClipID clipID;
@property (nonatomic, readwrite) VEAssetID assetID;
@property (nonatomic, readwrite) BOOL isAudio;
@property (nonatomic, readwrite, copy) NSString *backendName;
@property (nonatomic, readwrite) BOOL hardware;
@property (nonatomic, readwrite) BOOL failed;
- (instancetype)initInternal;
@end

@interface VEPlaybackStats ()
@property (nonatomic, readwrite) double fps;
@property (nonatomic, readwrite) uint64_t presentedFrames;
@property (nonatomic, readwrite) uint64_t droppedFrames;
@property (nonatomic, readwrite) uint64_t lateFrames;
@property (nonatomic, readwrite) uint64_t cacheHits;
@property (nonatomic, readwrite) uint64_t cacheMisses;
@property (nonatomic, readwrite) double cacheHitRate;
@property (nonatomic, readwrite) NSInteger decodeQueueDepth;
@property (nonatomic, readwrite) NSInteger decodeStreams;
@property (nonatomic, readwrite) uint64_t audioUnderruns;
@property (nonatomic, readwrite) uint64_t audioUnderrunFrames;
@property (nonatomic, readwrite) uint64_t mapFailures;
@property (nonatomic, readwrite) uint64_t monotonicHolds;
@property (nonatomic, readwrite) VEClockMode clockMode;
@property (nonatomic, readwrite) CMTime clockTime;
@property (nonatomic, readwrite) int64_t presentedFrameIndex;
@property (nonatomic, readwrite) CMTime presentedTime;
@property (nonatomic, readwrite) BOOL presentedClockDriven;
@property (nonatomic, readwrite) double presentedHostTime;
@property (nonatomic, readwrite) BOOL audioActive;
@property (nonatomic, readwrite) BOOL outputRunning;
@property (nonatomic, readwrite) double outputLatency;
@property (nonatomic, readwrite, copy) NSString *audioOutputKind;
@property (nonatomic, readwrite) uint64_t cacheBytes;
@property (nonatomic, readwrite, copy) NSString *errorMessage;
@property (nonatomic, readwrite, copy) NSArray<VEActiveClipInfo *> *activeClips;
- (instancetype)initInternal;
@end

@interface VECodecCapability ()
@property (nonatomic, readwrite, copy) NSString *name;
@property (nonatomic, readwrite, copy) NSString *codecType;
@property (nonatomic, readwrite) BOOL hardwareDecode;
@property (nonatomic, readwrite) BOOL hardwareEncode;
@property (nonatomic, readwrite) BOOL softwareEncode;
@property (nonatomic, readwrite, copy) NSArray<NSString *> *hardwareEncoderIDs;
- (instancetype)initInternal;
@end

@interface VEHardwareCaps ()
@property (nonatomic, readwrite, copy) NSArray<VECodecCapability *> *codecs;
@property (nonatomic, readwrite, copy) NSString *summary;
- (instancetype)initInternal;
@end

@interface VEWaveform () {
    std::shared_ptr<const ve::thumbs::WaveformPeaks> _peaks;
}
@property (nonatomic, readwrite) VEAssetID assetID;
@property (nonatomic, readwrite) NSInteger bucketsPerSecond;
@property (nonatomic, readwrite) NSInteger bucketCount;
@property (nonatomic, readwrite, copy) NSData *minMaxPairs;
- (instancetype)initWithAsset:(VEAssetID)asset peaks:(std::shared_ptr<const ve::thumbs::WaveformPeaks>)peaks;
@end

// MARK: - Implementations

static NSString *describeTime(CMTime t) {
    if (!CMTIME_IS_NUMERIC(t)) {
        return @"-";
    }
    return [NSString stringWithFormat:@"%.3fs", CMTimeGetSeconds(t)];
}

@implementation VEAssetInfo
- (instancetype)initInternal {
    return [super init];
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<VEAssetInfo %lld %@ %@ %@ %@>", self.assetID, self.name,
                                      describeTime(self.duration), self.backendName, self.codecName];
}
@end

@implementation VEEffectSpan
- (instancetype)initInternal {
    return [super init];
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<VEEffectSpan %lld clip %lld lane %ld kind %ld [%@, %@)>", self.spanID,
                                      self.clipID, (long)self.lane, (long)self.kind, describeTime(self.start),
                                      describeTime(self.end)];
}
@end

namespace {

/// Nullopt for a value outside the enumeration.
std::optional<ve::MotionParameter> motionParameterFrom(VEMotionParameter parameter) {
    switch (parameter) {
    case VEMotionParameterPositionX:
        return ve::MotionParameter::X;
    case VEMotionParameterPositionY:
        return ve::MotionParameter::Y;
    case VEMotionParameterScale:
        return ve::MotionParameter::Scale;
    case VEMotionParameterRotation:
        return ve::MotionParameter::Rotation;
    case VEMotionParameterOpacity:
        return ve::MotionParameter::Opacity;
    }
    return std::nullopt;
}

} // namespace

@implementation VEClipInfo
- (instancetype)initInternal {
    return [super init];
}
- (BOOL)hasEffectSpans {
    return _clip.hasEffectSpans();
}
- (VEVideoParams)videoParamsAtTime:(CMTime)time {
    return ve::facade::toVE(ve::motionValuesAt(_clip, time));
}
- (double)gainDbAtTime:(CMTime)time {
    return ve::gainDbAt(_clip, time);
}
- (BOOL)getMotion:(VEVideoParams *)motion
     atEdgeOfSpan:(VESpanID)spanID
            atEnd:(BOOL)atEnd
    frameDuration:(CMTime)frameDuration {
    const ve::EffectSpan *span = _clip.findSpan(ve::SpanId(static_cast<ve::SpanId::ValueType>(spanID)));
    if (span == nullptr || motion == nullptr || !ve::isPositive(frameDuration)) {
        return NO;
    }
    const auto values = ve::spanEdgeMotion(_clip, *span, frameDuration, atEnd);
    if (!values) {
        return NO;
    }
    *motion = ve::facade::toVE(*values);
    return YES;
}
- (BOOL)getBaseValues:(VESpanValues *)values
            underSpan:(VESpanID)spanID
                atEnd:(BOOL)atEnd
        frameDuration:(CMTime)frameDuration {
    const ve::EffectSpan *span = _clip.findSpan(ve::SpanId(static_cast<ve::SpanId::ValueType>(spanID)));
    if (span == nullptr || values == nullptr || span->kind == ve::SpanKind::Transition ||
        !ve::isPositive(frameDuration)) {
        return NO;
    }
    const auto time = ve::spanEdgeFrameTime(_clip, *span, frameDuration, atEnd);
    if (!time) {
        return NO;
    }
    VESpanValues base = VESpanValuesUnchanged();
    switch (span->kind) {
    case ve::SpanKind::Motion: {
        const ve::VideoParams rest = ve::composeMotion(_clip, *time, span->id);
        base.x = rest.x;
        base.y = rest.y;
        base.scale = rest.scale;
        base.rotationDegrees = rest.rotationDegrees;
        break;
    }
    case ve::SpanKind::Opacity:
        base.opacity = ve::composeMotion(_clip, *time, span->id).opacity;
        break;
    case ve::SpanKind::Gain:
        base.gainDb = ve::composeGainDb(_clip, *time, span->id);
        break;
    case ve::SpanKind::Transition:
        return NO;
    }
    *values = base;
    return YES;
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<VEClipInfo %lld asset %lld track %lld [%@, %@)>", self.clipID, self.assetID,
                                      self.trackID, describeTime(self.timelineStart), describeTime(self.timelineEnd)];
}
@end

@implementation VETrackInfo
- (instancetype)initInternal {
    return [super init];
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<VETrackInfo %lld %@ clips %@>", self.trackID, self.name,
                                      [self.clipIDs componentsJoinedByString:@","]];
}
@end

@implementation VETransitionInfo
- (instancetype)initInternal {
    return [super init];
}
@end

@implementation VESequenceInfo
- (instancetype)initInternal {
    return [super init];
}
@end

@implementation VEEditResult
- (instancetype)initWithCode:(VEEditErrorCode)code
                     message:(NSString *)message
                  createdIDs:(NSArray<NSNumber *> *)createdIDs
                     dropped:(NSArray<NSNumber *> *)dropped
                droppedSpans:(NSArray<NSNumber *> *)droppedSpans
                   freeRange:(CMTimeRange)freeRange
                        span:(nullable VEEffectSpan *)span
                        note:(NSString *)note {
    if ((self = [super init])) {
        _ok = code == VEEditErrorNone;
        _errorCode = code;
        _message = [message copy];
        _createdIDs = [createdIDs copy];
        _droppedTransitionIDs = [dropped copy];
        _droppedSpanIDs = [droppedSpans copy];
        _freeRange = freeRange;
        _span = span;
        _note = [note copy];
    }
    return self;
}
+ (instancetype)success {
    return [self successWithCreatedIDs:@[]];
}
+ (instancetype)successWithCreatedIDs:(NSArray<NSNumber *> *)createdIDs {
    return [[self alloc] initWithCode:VEEditErrorNone
                              message:@""
                           createdIDs:createdIDs
                              dropped:@[]
                         droppedSpans:@[]
                            freeRange:kCMTimeRangeInvalid
                                 span:nil
                                 note:@""];
}
+ (instancetype)failureWithMessage:(NSString *)message {
    return [self failureWithCode:VEEditErrorInvalidArgument message:message];
}
+ (instancetype)failureWithCode:(VEEditErrorCode)code message:(NSString *)message {
    const VEEditErrorCode failure = code == VEEditErrorNone ? VEEditErrorInvalidArgument : code;
    return [[self alloc] initWithCode:failure
                              message:message
                           createdIDs:@[]
                              dropped:@[]
                         droppedSpans:@[]
                            freeRange:kCMTimeRangeInvalid
                                 span:nil
                                 note:@""];
}
- (NSString *)description {
    return self.ok ? @"<VEEditResult ok>" : [NSString stringWithFormat:@"<VEEditResult failed: %@>", self.message];
}
@end

@implementation VETransitionLimit
- (instancetype)initInternal {
    return [super init];
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<VETransitionLimit %lld frames: %@>", (long long)self.maximumFrames, self.reason];
}
@end

@implementation VEPlaybackStatus
- (instancetype)initInternal {
    return [super init];
}
- (BOOL)isRunning {
    return self.state == VEPlaybackStatePlaying || self.state == VEPlaybackStatePrerolling;
}
- (NSString *)description {
    return [NSString stringWithFormat:@"<VEPlaybackStatus state %ld at %@ rate %g>", long(self.state),
                                      describeTime(self.time), self.rate];
}
@end

@implementation VEActiveClipInfo
- (instancetype)initInternal {
    return [super init];
}
@end

@implementation VEPlaybackStats
- (instancetype)initInternal {
    return [super init];
}
@end

@implementation VECodecCapability
- (instancetype)initInternal {
    return [super init];
}
@end

@implementation VEHardwareCaps
- (instancetype)initInternal {
    return [super init];
}
@end

@implementation VEWaveform
- (instancetype)initWithAsset:(VEAssetID)asset peaks:(std::shared_ptr<const ve::thumbs::WaveformPeaks>)peaks {
    if ((self = [super init])) {
        _peaks = std::move(peaks);
        _assetID = asset;
        _bucketsPerSecond = _peaks ? NSInteger(_peaks->bucketsPerSecond) : 0;
        _bucketCount = _peaks ? NSInteger(_peaks->bucketCount()) : 0;
        static_assert(sizeof(ve::thumbs::PeakBucket) == 2 * sizeof(float), "PeakBucket must be two packed floats");
        _minMaxPairs = _peaks ? [NSData dataWithBytes:_peaks->mono.data()
                                              length:_peaks->mono.size() * sizeof(ve::thumbs::PeakBucket)]
                              : [NSData data];
    }
    return self;
}

- (VEPeakRange)peakRangeFromSeconds:(double)startSeconds toSeconds:(double)endSeconds {
    VEPeakRange range{0, 0};
    if (!_peaks || _peaks->bucketCount() == 0 || _peaks->bucketsPerSecond == 0 || !std::isfinite(startSeconds) ||
        !std::isfinite(endSeconds)) {
        return range;
    }
    const double bps = _peaks->bucketsPerSecond;
    const auto count = static_cast<int64_t>(_peaks->bucketCount());
    int64_t first = static_cast<int64_t>(std::floor(std::min(startSeconds, endSeconds) * bps));
    int64_t last = static_cast<int64_t>(std::ceil(std::max(startSeconds, endSeconds) * bps));
    if (last <= first) {
        last = first + 1;
    }
    first = std::clamp<int64_t>(first, 0, count);
    last = std::clamp<int64_t>(last, 0, count);
    if (first >= last) {
        return range;
    }
    float lo = _peaks->mono[size_t(first)].min;
    float hi = _peaks->mono[size_t(first)].max;
    for (int64_t i = first + 1; i < last; ++i) {
        lo = std::min(lo, _peaks->mono[size_t(i)].min);
        hi = std::max(hi, _peaks->mono[size_t(i)].max);
    }
    range.minimum = lo;
    range.maximum = hi;
    return range;
}
@end

// MARK: - Factories

namespace ve::facade {

VEVideoParams toVE(const VideoParams &p) {
    return VEVideoParams{p.x, p.y, p.scale, p.rotationDegrees, p.opacity};
}

VideoParams fromVE(const VEVideoParams &p) {
    VideoParams v;
    v.x = p.x;
    v.y = p.y;
    v.scale = p.scale;
    v.rotationDegrees = p.rotationDegrees;
    v.opacity = p.opacity;
    return v;
}

VEAudioParams audioParamsOf(const Clip &clip) {
    return VEAudioParams{clip.audio.gainDb, clipFadeLength(clip, ClipEdge::Head), clipFadeLength(clip, ClipEdge::Tail)};
}

AudioParams fromVE(const VEAudioParams &p) {
    AudioParams a;
    a.gainDb = p.gainDb;
    return a;
}

NSString *fpsString(CMTime frameDuration) {
    if (!isPositive(frameDuration)) {
        return @"";
    }
    const double fps = double(frameDuration.timescale) / double(frameDuration.value);
    if (std::fabs(fps - std::round(fps)) < 0.001) {
        return [NSString stringWithFormat:@"%.0f", std::round(fps)];
    }
    NSString *s = [NSString stringWithFormat:@"%.3f", fps];
    while ([s hasSuffix:@"0"]) {
        s = [s substringToIndex:s.length - 1];
    }
    return s;
}

static VEAssetKind toVE(AssetKind kind) {
    switch (kind) {
    case AssetKind::Video:
        return VEAssetKindVideo;
    case AssetKind::Audio:
        return VEAssetKindAudio;
    case AssetKind::Still:
        return VEAssetKindStill;
    case AssetKind::AudioVideo:
        return VEAssetKindAudioVideo;
    }
    return VEAssetKindVideo;
}

VEAssetInfo *makeAssetInfo(const MediaAsset &asset, const AssetDetails *details, bool missing, NSInteger useCount) {
    VEAssetInfo *info = [[VEAssetInfo alloc] initInternal];
    info.assetID = static_cast<VEAssetID>(asset.id.value());
    info.name = toNS(asset.name);
    info.path = toNS(asset.url);
    info.kind = toVE(asset.kind);
    info.duration = asset.isStill() ? kCMTimeInvalid : asset.duration;
    info.width = asset.hasVideo() ? asset.width : 0;
    info.height = asset.hasVideo() ? asset.height : 0;
    info.rotationDegrees = asset.hasVideo() ? asset.rotationDegrees : 0;
    info.frameDuration = asset.frameDuration;
    info.fpsString = asset.isStill() ? @"" : fpsString(asset.frameDuration);
    info.isVFR = asset.isVFR;
    info.sampleRate = asset.audioSampleRate;
    info.channels = asset.audioChannels;
    info.backendName = toNS(asset.backendHint);
    info.hardwareDecode = asset.hardwareDecode;
    info.codecName = details ? toNS(details->codecName) : @"";
    info.audioCodecName = details ? toNS(details->audioCodecName) : @"";
    info.container = details ? toNS(details->container) : @"";
    info.routingReason = details ? toNS(details->routingReason) : @"";
    info.isMissing = missing;
    info.hasVideo = asset.hasVideo();
    info.hasAudio = asset.hasAudio();
    info.isStill = asset.isStill();
    info.useCount = useCount;
    return info;
}

VEMotionParameter toVE(MotionParameter parameter) {
    switch (parameter) {
    case MotionParameter::X:
        return VEMotionParameterPositionX;
    case MotionParameter::Y:
        return VEMotionParameterPositionY;
    case MotionParameter::Scale:
        return VEMotionParameterScale;
    case MotionParameter::Rotation:
        return VEMotionParameterRotation;
    case MotionParameter::Opacity:
        return VEMotionParameterOpacity;
    }
    return VEMotionParameterPositionX;
}

std::optional<MotionParameter> fromVE(VEMotionParameter parameter) {
    return motionParameterFrom(parameter);
}

VEKeyframeInterpolation toVE(KeyframeInterpolation interpolation) {
    switch (interpolation) {
    case KeyframeInterpolation::Hold:
        return VEKeyframeInterpolationHold;
    case KeyframeInterpolation::Linear:
        return VEKeyframeInterpolationLinear;
    case KeyframeInterpolation::EaseOut:
        return VEKeyframeInterpolationEaseOut;
    case KeyframeInterpolation::EaseIn:
        return VEKeyframeInterpolationEaseIn;
    case KeyframeInterpolation::EaseInOut:
        return VEKeyframeInterpolationEaseInOut;
    case KeyframeInterpolation::Bezier:
        return VEKeyframeInterpolationCustom;
    }
    return VEKeyframeInterpolationLinear;
}

VESpanKind toVE(SpanKind kind) {
    switch (kind) {
    case SpanKind::Transition:
        return VESpanKindTransition;
    case SpanKind::Motion:
        return VESpanKindMotion;
    case SpanKind::Opacity:
        return VESpanKindOpacity;
    case SpanKind::Gain:
        return VESpanKindGain;
    }
    return VESpanKindMotion;
}

std::optional<SpanKind> fromVE(VESpanKind kind) {
    switch (kind) {
    case VESpanKindTransition:
        return SpanKind::Transition;
    case VESpanKindMotion:
        return SpanKind::Motion;
    case VESpanKindOpacity:
        return SpanKind::Opacity;
    case VESpanKindGain:
        return SpanKind::Gain;
    }
    return std::nullopt;
}

VETransitionStyle toVE(TransitionRole role) {
    switch (role) {
    case TransitionRole::CrossDissolve:
        return VETransitionStyleCrossDissolve;
    case TransitionRole::FadeOut:
        return VETransitionStyleFadeOut;
    case TransitionRole::FadeIn:
        return VETransitionStyleFadeIn;
    }
    return VETransitionStyleCrossDissolve;
}

double spanValueIn(const VESpanValues &values, SpanParameter parameter) {
    switch (parameter) {
    case SpanParameter::X:
        return values.x;
    case SpanParameter::Y:
        return values.y;
    case SpanParameter::Scale:
        return values.scale;
    case SpanParameter::Rotation:
        return values.rotationDegrees;
    case SpanParameter::Opacity:
        return values.opacity;
    case SpanParameter::Gain:
        return values.gainDb;
    }
    return std::numeric_limits<double>::quiet_NaN();
}

static void setSpanValueIn(VESpanValues &values, SpanParameter parameter, double value) {
    switch (parameter) {
    case SpanParameter::X:
        values.x = value;
        break;
    case SpanParameter::Y:
        values.y = value;
        break;
    case SpanParameter::Scale:
        values.scale = value;
        break;
    case SpanParameter::Rotation:
        values.rotationDegrees = value;
        break;
    case SpanParameter::Opacity:
        values.opacity = value;
        break;
    case SpanParameter::Gain:
        values.gainDb = value;
        break;
    }
}

std::optional<KeyframeInterpolation> fromVE(VEKeyframeInterpolation interpolation) {
    switch (interpolation) {
    case VEKeyframeInterpolationHold:
        return KeyframeInterpolation::Hold;
    case VEKeyframeInterpolationLinear:
        return KeyframeInterpolation::Linear;
    case VEKeyframeInterpolationEaseOut:
        return KeyframeInterpolation::EaseOut;
    case VEKeyframeInterpolationEaseIn:
        return KeyframeInterpolation::EaseIn;
    case VEKeyframeInterpolationEaseInOut:
        return KeyframeInterpolation::EaseInOut;
    case VEKeyframeInterpolationCustom:
        return KeyframeInterpolation::Bezier;
    }
    return std::nullopt;
}

VEClipInfo *makeClipInfo(const Clip &clip, const Track &track, const Project &project, const Sequence &sequence,
                         const ClipIndex *index) {
    VEClipInfo *info = [[VEClipInfo alloc] initInternal];
    info->_clip = clip;
    info.clipID = static_cast<VEClipID>(clip.id.value());
    info.assetID = static_cast<VEAssetID>(clip.assetId.value());
    info.trackID = static_cast<VETrackID>(track.id.value());
    info.trackKind = track.kind == TrackKind::Video ? VETrackKindVideo : VETrackKindAudio;
    const MediaAsset *asset = project.findAsset(clip.assetId);
    info.name = asset ? toNS(asset->name) : @"";
    info.timelineStart = clip.timelineStart;
    info.duration = clip.duration();
    info.timelineEnd = clip.timelineEnd();
    info.sourceIn = clip.sourceIn;
    info.sourceOut = clip.sourceOut();
    info.speed = clip.speedValue();
    info.speedNumerator = clip.speedRatio().num;
    info.speedDenominator = clip.speedRatio().den;
    info.isStill = clip.isStill;
    info.linkedClipID = clip.linkedClipId ? static_cast<VEClipID>(clip.linkedClipId->value()) : 0;
    info.videoParams = toVE(clip.video);
    info.audioParams = audioParamsOf(clip);
    NSMutableArray<VEEffectSpan *> *spans = [NSMutableArray arrayWithCapacity:clip.spans.size()];
    for (const EffectSpan &span : clip.spans) {
        [spans addObject:makeEffectSpan(span, clip, track, sequence, index)];
    }
    info.spans = spans;
    return info;
}

VEEffectSpan *makeEffectSpan(const EffectSpan &span, const Clip &clip, const Track &track, const Sequence &sequence,
                             const ClipIndex *index) {
    VEEffectSpan *info = [[VEEffectSpan alloc] initInternal];
    info.spanID = static_cast<VESpanID>(span.id.value());
    info.clipID = static_cast<VEClipID>(clip.id.value());
    info.trackID = static_cast<VETrackID>(track.id.value());
    info.lane = span.lane;
    info.kind = toVE(span.kind);
    info.clipRelativeStart = span.start;
    info.clipRelativeEnd = span.end;
    const std::optional<TimeRange> range = spanTimelineRange(clip, span, track);
    info.start = range ? range->start : kCMTimeInvalid;
    info.end = range ? range->end : kCMTimeInvalid;
    info.duration = range ? range->duration() : kCMTimeInvalid;
    VESpanValues startValues = VESpanValuesUnchanged();
    VESpanValues endValues = VESpanValuesUnchanged();
    for (const SpanParameter parameter : parametersOf(span.kind)) {
        setSpanValueIn(startValues, parameter, spanEdgeValue(span, parameter, false));
        setSpanValueIn(endValues, parameter, spanEdgeValue(span, parameter, true));
    }
    info.startValues = startValues;
    info.endValues = endValues;
    info.interpolation = span.isTransition() ? VEKeyframeInterpolationLinear : toVE(spanInterpolation(span));
    info.transitionStyle = VETransitionStyleCrossDissolve;
    info.shareBeforeCut = kCMTimeZero;
    info.shareAfterCut = kCMTimeZero;
    if (span.isTransition()) {
        if (const auto placement = placeTransition(track, clip, span)) {
            info.transitionStyle = toVE(placement->role);
            info.partnerClipID = placement->partner ? static_cast<VEClipID>(placement->partner->id.value()) : 0;
            info.shareBeforeCut = placement->cut - placement->range.start;
            info.shareAfterCut = placement->range.end - placement->cut;
        }
        const auto linked = index != nullptr ? index->linkedTransition(track, clip, span)
                                             : linkedTransition(sequence, span.id);
        info.linkedSpanID = linked ? static_cast<VESpanID>(linked->value()) : 0;
    }
    return info;
}

VETrackInfo *makeTrackInfo(const Track &track, NSInteger index) {
    VETrackInfo *info = [[VETrackInfo alloc] initInternal];
    info.trackID = static_cast<VETrackID>(track.id.value());
    info.kind = track.kind == TrackKind::Video ? VETrackKindVideo : VETrackKindAudio;
    info.index = index;
    info.name = toNS(track.name);
    info.muted = track.muted;
    info.solo = track.solo;
    info.locked = track.locked;
    NSMutableArray<NSNumber *> *ids = [NSMutableArray arrayWithCapacity:track.clips.size()];
    for (const Clip &clip : track.clips) {
        [ids addObject:@(static_cast<VEClipID>(clip.id.value()))];
    }
    info.clipIDs = ids;
    return info;
}

VETransitionInfo *makeTransitionInfo(const TransitionPlacement &transition) {
    VETransitionInfo *info = [[VETransitionInfo alloc] initInternal];
    const VEClipID owner = static_cast<VEClipID>(transition.owner->id.value());
    info.transitionID = static_cast<VETransitionID>(transition.span->id.value());
    info.trackID = static_cast<VETrackID>(transition.track->id.value());
    info.style = toVE(transition.role);
    switch (transition.role) {
    case TransitionRole::CrossDissolve:
        info.fromClipID = owner;
        info.toClipID = transition.partner ? static_cast<VEClipID>(transition.partner->id.value()) : 0;
        break;
    case TransitionRole::FadeOut:
        info.fromClipID = owner;
        info.toClipID = 0;
        break;
    case TransitionRole::FadeIn:
        info.fromClipID = 0;
        info.toClipID = owner;
        break;
    }
    info.start = transition.range.start;
    info.end = transition.range.end;
    info.duration = transition.range.duration();
    info.shareBeforeCut = transition.cut - transition.range.start;
    info.shareAfterCut = transition.range.end - transition.cut;
    return info;
}

VESequenceInfo *makeSequenceInfo(const Sequence &sequence) {
    VESequenceInfo *info = [[VESequenceInfo alloc] initInternal];
    info.sequenceID = static_cast<VESequenceID>(sequence.id.value());
    info.name = toNS(sequence.name);
    info.frameDuration = sequence.frameDuration;
    info.width = sequence.width;
    info.height = sequence.height;
    info.audioSampleRate = sequence.audioSampleRate;
    info.duration = sequence.duration();
    NSMutableArray<NSNumber *> *video = [NSMutableArray array];
    for (const Track &t : sequence.videoTracks) {
        [video addObject:@(static_cast<VETrackID>(t.id.value()))];
    }
    NSMutableArray<NSNumber *> *audio = [NSMutableArray array];
    for (const Track &t : sequence.audioTracks) {
        [audio addObject:@(static_cast<VETrackID>(t.id.value()))];
    }
    NSMutableArray<VETransitionInfo *> *transitions = [NSMutableArray array];
    for (const auto *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (const Track &track : *list) {
            for (const Clip &clip : track.clips) {
                const EffectSpan *tail = clip.transitionAt(ClipEdge::Tail);
                const auto placement = tail ? placeTransition(track, clip, *tail) : std::nullopt;
                if (placement && placement->role == TransitionRole::CrossDissolve && placement->partner) {
                    [transitions addObject:makeTransitionInfo(*placement)];
                }
            }
        }
    }
    info.videoTrackIDs = video;
    info.audioTrackIDs = audio;
    info.transitions = transitions;
    return info;
}

VEHardwareCaps *makeHardwareCaps() {
    const media::HardwareCaps &caps = media::HardwareCaps::get();
    NSMutableArray<VECodecCapability *> *codecs = [NSMutableArray array];
    for (const media::CodecCapabilities *c : {&caps.h264, &caps.hevc, &caps.prores, &caps.av1, &caps.vp9}) {
        VECodecCapability *cap = [[VECodecCapability alloc] initInternal];
        cap.name = @(media::toString(c->codec));
        cap.codecType = toNS(media::fourCCToString(c->codecType));
        cap.hardwareDecode = c->hardwareDecode;
        cap.hardwareEncode = c->hardwareEncode;
        cap.softwareEncode = c->softwareEncode;
        NSMutableArray<NSString *> *ids = [NSMutableArray array];
        for (const std::string &encoderID : c->hardwareEncoderIDs) {
            [ids addObject:toNS(encoderID)];
        }
        cap.hardwareEncoderIDs = ids;
        [codecs addObject:cap];
    }
    VEHardwareCaps *result = [[VEHardwareCaps alloc] initInternal];
    result.codecs = codecs;
    result.summary = toNS(caps.description());
    return result;
}

VEWaveform *makeWaveform(AssetId asset, const std::shared_ptr<const thumbs::WaveformPeaks> &peaks) {
    return [[VEWaveform alloc] initWithAsset:static_cast<VEAssetID>(asset.value()) peaks:peaks];
}

} // namespace ve::facade

namespace ve::facade {

VEEditErrorCode toVE(EditError error) {
    switch (error) {
    case EditError::None: return VEEditErrorNone;
    case EditError::SequenceNotFound: return VEEditErrorSequenceNotFound;
    case EditError::TrackNotFound: return VEEditErrorTrackNotFound;
    case EditError::ClipNotFound: return VEEditErrorClipNotFound;
    case EditError::TransitionNotFound: return VEEditErrorTransitionNotFound;
    case EditError::AssetNotFound: return VEEditErrorAssetNotFound;
    case EditError::TrackLocked: return VEEditErrorTrackLocked;
    case EditError::TrackKindMismatch: return VEEditErrorTrackKindMismatch;
    case EditError::InvalidTime: return VEEditErrorInvalidTime;
    case EditError::InvalidArgument: return VEEditErrorInvalidArgument;
    case EditError::Overlap: return VEEditErrorOverlap;
    case EditError::OutOfSourceRange: return VEEditErrorOutOfSourceRange;
    case EditError::InsufficientHandles: return VEEditErrorInsufficientHandles;
    case EditError::NotAdjacent: return VEEditErrorNotAdjacent;
    case EditError::AlreadyExists: return VEEditErrorAlreadyExists;
    case EditError::AlreadyLinked: return VEEditErrorAlreadyLinked;
    case EditError::NotLinked: return VEEditErrorNotLinked;
    case EditError::InsideTransition: return VEEditErrorInsideTransition;
    case EditError::NotRepresentable: return VEEditErrorNotRepresentable;
    case EditError::InvariantViolation: return VEEditErrorInvariantViolation;
    case EditError::SpanNotFound: return VEEditErrorSpanNotFound;
    }
    return VEEditErrorInvariantViolation;
}

VEEditResult *makeEditResult(const EditResult &result, NSArray<NSNumber *> *created, NSString *note,
                             VEEffectSpan *span) {
    if (!result.ok()) {
        NSString *message = toNS(result.message);
        const CMTimeRange free = result.freeRange ? result.freeRange->toCMTimeRange() : kCMTimeRangeInvalid;
        return [[VEEditResult alloc] initWithCode:toVE(result.error)
                                          message:message.length > 0 ? message : @(nameOf(result.error))
                                       createdIDs:@[]
                                          dropped:@[]
                                     droppedSpans:@[]
                                        freeRange:free
                                             span:nil
                                             note:@""];
    }
    NSMutableArray<NSNumber *> *dropped = [NSMutableArray arrayWithCapacity:result.droppedTransitionIds.size()];
    for (SpanId id : result.droppedTransitionIds) {
        [dropped addObject:@(static_cast<VETransitionID>(id.value()))];
    }
    NSMutableArray<NSNumber *> *droppedSpans = [NSMutableArray arrayWithCapacity:result.droppedSpanIds.size()];
    for (SpanId id : result.droppedSpanIds) {
        [droppedSpans addObject:@(static_cast<VESpanID>(id.value()))];
    }
    // What the edit removed as a side effect is in droppedTransitionIDs / droppedSpanIDs, not in the
    // note: the app says what each one was and why (it knows the spans as they were before the edit).
    NSString *text = note ?: @"";
    return [[VEEditResult alloc] initWithCode:VEEditErrorNone
                                      message:@""
                                   createdIDs:created ?: @[]
                                      dropped:dropped
                                 droppedSpans:droppedSpans
                                    freeRange:kCMTimeRangeInvalid
                                         span:span
                                         note:text];
}

VETransitionLimit *makeTransitionLimit(const TransitionLimit &limit) {
    VETransitionLimit *info = [[VETransitionLimit alloc] initInternal];
    info.maximumDuration = limit.maximum;
    info.maximumFrames = limit.maximumFrames;
    info.limitingError = limit.limitError == EditError::None ? VEEditErrorNone : toVE(limit.limitError);
    info.reason = toNS(limit.reason);
    info.limitingClipID = static_cast<VEClipID>(limit.limitingClip.value());
    return info;
}

static VEPlaybackState toVE(playback::PlaybackState state) {
    switch (state) {
    case playback::PlaybackState::Stopped: return VEPlaybackStateStopped;
    case playback::PlaybackState::Prerolling: return VEPlaybackStatePrerolling;
    case playback::PlaybackState::Playing: return VEPlaybackStatePlaying;
    case playback::PlaybackState::Scrubbing: return VEPlaybackStateScrubbing;
    }
    return VEPlaybackStateStopped;
}

VEPlaybackState playbackStateToVE(playback::PlaybackState state) {
    return toVE(state);
}

VEPlaybackStatus *makePlaybackStatus(const playback::PlaybackStatus &status) {
    VEPlaybackStatus *info = [[VEPlaybackStatus alloc] initInternal];
    info.state = toVE(status.state);
    info.time = status.time;
    info.rate = status.rate;
    info.audioActive = status.audioActive;
    info.errorMessage = status.lastError ? toNS(status.lastError->message) : @"";
    return info;
}

VEPlaybackStats *makePlaybackStats(const playback::PlaybackStats &stats, const playback::PresentedFrame &presented) {
    VEPlaybackStats *info = [[VEPlaybackStats alloc] initInternal];
    info.fps = stats.fps;
    info.presentedFrames = stats.presentedFrames;
    info.droppedFrames = stats.droppedFrames;
    info.lateFrames = stats.lateFrames;
    info.cacheHits = stats.cacheHits;
    info.cacheMisses = stats.cacheMisses;
    info.cacheHitRate = stats.cacheHitRate;
    info.decodeQueueDepth = stats.decodeQueueDepth;
    info.decodeStreams = stats.decodeStreams;
    info.audioUnderruns = stats.audioUnderruns;
    info.audioUnderrunFrames = stats.audioUnderrunFrames;
    info.mapFailures = stats.mapFailures;
    info.monotonicHolds = stats.monotonicHolds;
    switch (stats.clockMode) {
    case audio::ClockMode::Stopped: info.clockMode = VEClockModeStopped; break;
    case audio::ClockMode::AudioSamples: info.clockMode = VEClockModeAudioSamples; break;
    case audio::ClockMode::HostTime: info.clockMode = VEClockModeHostTime; break;
    }
    info.clockTime = stats.clockTime;
    info.presentedFrameIndex = presented.frameIndex;
    info.presentedTime = presented.time;
    info.presentedClockDriven = presented.clockDriven;
    info.presentedHostTime = static_cast<double>(presented.hostNanos) * 1e-9;
    info.audioActive = stats.audioActive;
    info.outputRunning = stats.outputRunning;
    info.outputLatency = stats.outputLatency;
    info.audioOutputKind = toNS(stats.audioOutput);
    info.cacheBytes = stats.cacheBytes;
    info.errorMessage = stats.lastError ? toNS(stats.lastError->message) : @"";
    NSMutableArray<VEActiveClipInfo *> *clips = [NSMutableArray arrayWithCapacity:stats.activeClips.size()];
    for (const playback::ActiveClipInfo &active : stats.activeClips) {
        VEActiveClipInfo *clip = [[VEActiveClipInfo alloc] initInternal];
        clip.clipID = static_cast<VEClipID>(active.clip.value());
        clip.assetID = static_cast<VEAssetID>(active.asset.value());
        clip.isAudio = active.isAudio;
        clip.backendName = toNS(active.backend);
        clip.hardware = active.hardware;
        clip.failed = active.failed;
        [clips addObject:clip];
    }
    info.activeClips = clips;
    return info;
}

} // namespace ve::facade
