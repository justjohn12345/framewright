// Value types the engine facade hands to Swift.
//
// Rules:
// - Every object here is an immutable snapshot copied out of the model at the moment it was
//   requested. None of them points into the engine; holding one never keeps model state alive
//   and it never changes after an edit. Ask VEEngine again after VEEngineModelDidChange.
// - Ids are plain 64-bit integers (0 = none/invalid). They are stable for the lifetime of the
//   object they name and are never reused within a project (undo/redo restores the same ids).
// - Times are CMTime (bridges to Swift's CMTime).
// Plain Objective-C only: this header is part of the framework's public module.

#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef int64_t VEAssetID;
typedef int64_t VEClipID;
typedef int64_t VETrackID;
typedef int64_t VETransitionID;
typedef int64_t VESequenceID;

typedef NS_ENUM(NSInteger, VEAssetKind) {
    VEAssetKindVideo = 0,      ///< Video only.
    VEAssetKindAudio = 1,      ///< Audio only.
    VEAssetKindStill = 2,      ///< A single image; no intrinsic duration.
    VEAssetKindAudioVideo = 3, ///< Video with audio.
};

typedef NS_ENUM(NSInteger, VETrackKind) {
    VETrackKindVideo = 0,
    VETrackKindAudio = 1,
};

/// Placement of a clip's picture (see the engine's VideoParams): x/y offset the clip centre from
/// the frame centre in sequence pixels (+y down); scale 1 = fitted size; opacity 0...1.
typedef struct {
    double x;
    double y;
    double scale;
    double rotationDegrees;
    double opacity;
} VEVideoParams;

/// Clip audio settings: gain in dB and linear fade durations at the clip's ends.
typedef struct {
    double gainDb;
    CMTime fadeInDuration;
    CMTime fadeOutDuration;
} VEAudioParams;

/// Identity video parameters (centred, scale 1, no rotation, opaque).
FOUNDATION_EXPORT VEVideoParams VEVideoParamsIdentity(void);

/// Unity gain, no fades.
FOUNDATION_EXPORT VEAudioParams VEAudioParamsDefault(void);

/// An imported media file.
@interface VEAssetInfo : NSObject
@property (nonatomic, readonly) VEAssetID assetID;
@property (nonatomic, readonly, copy) NSString *name;
/// File-system path as stored in the project.
@property (nonatomic, readonly, copy) NSString *path;
@property (nonatomic, readonly) VEAssetKind kind;
/// Media duration; kCMTimeInvalid for stills.
@property (nonatomic, readonly) CMTime duration;
/// Display size in pixels (rotation applied); zero for audio.
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
/// Nominal frame duration; invalid for stills and audio.
@property (nonatomic, readonly) CMTime frameDuration;
/// "29.97", "25", ... ("" for stills and audio).
@property (nonatomic, readonly, copy) NSString *fpsString;
@property (nonatomic, readonly) BOOL isVFR;
@property (nonatomic, readonly) NSInteger sampleRate;
@property (nonatomic, readonly) NSInteger channels;
/// Decoder backend the router chose ("apple", "ffmpeg").
@property (nonatomic, readonly, copy) NSString *backendName;
@property (nonatomic, readonly) BOOL hardwareDecode;
/// Codec of the visual track ("H.264", "HEVC", "PNG"...) or the audio track for audio-only
/// assets; "" until the media has been probed (e.g. right after opening a project).
@property (nonatomic, readonly, copy) NSString *codecName;
/// Audio codec name ("" when none or not probed yet).
@property (nonatomic, readonly, copy) NSString *audioCodecName;
/// Container token ("mov", "mp4", "mkv", "png"...), "" until probed.
@property (nonatomic, readonly, copy) NSString *container;
/// Why the router picked the backend (one line per track), "" until probed.
@property (nonatomic, readonly, copy) NSString *routingReason;
/// True if the file could not be found when the project was opened.
@property (nonatomic, readonly) BOOL isMissing;
@property (nonatomic, readonly) BOOL hasVideo;
@property (nonatomic, readonly) BOOL hasAudio;
@property (nonatomic, readonly) BOOL isStill;
/// Number of clips of the active sequence using this asset.
@property (nonatomic, readonly) NSInteger useCount;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A clip on a track of the active sequence.
@interface VEClipInfo : NSObject
@property (nonatomic, readonly) VEClipID clipID;
@property (nonatomic, readonly) VEAssetID assetID;
@property (nonatomic, readonly) VETrackID trackID;
@property (nonatomic, readonly) VETrackKind trackKind;
/// Name of the asset (clips have no own name).
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) CMTime timelineStart;
@property (nonatomic, readonly) CMTime duration;
@property (nonatomic, readonly) CMTime timelineEnd;
/// Used source range (for stills measured in timeline time from zero).
@property (nonatomic, readonly) CMTime sourceIn;
@property (nonatomic, readonly) CMTime sourceOut;
@property (nonatomic, readonly) double speed;
@property (nonatomic, readonly) BOOL isStill;
/// Linked partner, or 0.
@property (nonatomic, readonly) VEClipID linkedClipID;
@property (nonatomic, readonly) VEVideoParams videoParams;
@property (nonatomic, readonly) VEAudioParams audioParams;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A track of the active sequence.
@interface VETrackInfo : NSObject
@property (nonatomic, readonly) VETrackID trackID;
@property (nonatomic, readonly) VETrackKind kind;
/// Position within its kind's list (video: 0 = bottom).
@property (nonatomic, readonly) NSInteger index;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) BOOL muted;
@property (nonatomic, readonly) BOOL solo;
@property (nonatomic, readonly) BOOL locked;
/// Clip ids (VEClipID) in timeline order.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *clipIDs;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A cross dissolve between two adjacent clips of one track.
@interface VETransitionInfo : NSObject
@property (nonatomic, readonly) VETransitionID transitionID;
@property (nonatomic, readonly) VETrackID trackID;
@property (nonatomic, readonly) VEClipID fromClipID;
@property (nonatomic, readonly) VEClipID toClipID;
@property (nonatomic, readonly) CMTime duration;
/// Timeline range covered (centred on the cut).
@property (nonatomic, readonly) CMTime start;
@property (nonatomic, readonly) CMTime end;
- (instancetype)init NS_UNAVAILABLE;
@end

/// The active sequence.
@interface VESequenceInfo : NSObject
@property (nonatomic, readonly) VESequenceID sequenceID;
@property (nonatomic, readonly, copy) NSString *name;
@property (nonatomic, readonly) CMTime frameDuration;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) NSInteger audioSampleRate;
/// End of the last clip.
@property (nonatomic, readonly) CMTime duration;
/// Video track ids, bottom to top.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *videoTrackIDs;
/// Audio track ids, first (A1) to last.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *audioTrackIDs;
@property (nonatomic, readonly, copy) NSArray<VETransitionInfo *> *transitions;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Outcome of an edit. A refused edit changes nothing; `message` says why.
@interface VEEditResult : NSObject
@property (nonatomic, readonly) BOOL ok;
@property (nonatomic, readonly, copy) NSString *message;
/// Ids created by the edit (new clips of an insert/overwrite/split, a new track or
/// transition), in the order the engine reports them.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *createdIDs;
+ (instancetype)success;
+ (instancetype)successWithCreatedIDs:(NSArray<NSNumber *> *)createdIDs;
+ (instancetype)failureWithMessage:(NSString *)message;
- (instancetype)init NS_UNAVAILABLE;
@end

/// VideoToolbox capabilities for one codec.
@interface VECodecCapability : NSObject
/// "h264", "hevc", "prores", "av1", "vp9".
@property (nonatomic, readonly, copy) NSString *name;
/// Four-character codec type probed ("avc1", ...).
@property (nonatomic, readonly, copy) NSString *codecType;
@property (nonatomic, readonly) BOOL hardwareDecode;
@property (nonatomic, readonly) BOOL hardwareEncode;
@property (nonatomic, readonly) BOOL softwareEncode;
@property (nonatomic, readonly, copy) NSArray<NSString *> *hardwareEncoderIDs;
- (instancetype)init NS_UNAVAILABLE;
@end

/// The machine's VideoToolbox capabilities (probed once per process).
@interface VEHardwareCaps : NSObject
@property (nonatomic, readonly, copy) NSArray<VECodecCapability *> *codecs;
/// Multi-line human-readable table.
@property (nonatomic, readonly, copy) NSString *summary;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Minimum and maximum sample value of a span of a waveform.
typedef struct {
    float minimum;
    float maximum;
} VEPeakRange;

/// Audio peaks of an asset: min/max pairs per bucket of the mono mix.
@interface VEWaveform : NSObject
@property (nonatomic, readonly) VEAssetID assetID;
@property (nonatomic, readonly) NSInteger bucketsPerSecond;
@property (nonatomic, readonly) NSInteger bucketCount;
/// bucketCount x (min Float32, max Float32), native endian, values in [-1, 1].
@property (nonatomic, readonly, copy) NSData *minMaxPairs;
/// Minimum and maximum sample over [startSeconds, endSeconds) of source time (both 0 when the
/// range holds no bucket; a range narrower than one bucket uses the bucket containing it).
- (VEPeakRange)peakRangeFromSeconds:(double)startSeconds toSeconds:(double)endSeconds;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
