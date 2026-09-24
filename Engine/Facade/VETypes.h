// Value types the engine facade hands to Swift.
//
// Rules:
// - Every object here is an immutable snapshot copied out of the model at the moment it was
//   requested. None of them points into the engine; holding one never keeps model state alive
//   and it never changes after an edit. Ask VEEngine again after VEEngineModelDidChange.
// - Ids are plain 64-bit integers (0 = none/invalid). They are stable for the lifetime of the
//   object they name and are never reused within a project: undo/redo restores the same ids,
//   and objects created after an undo get ids no undone object ever had.
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

/// A keyframeable Motion parameter (a field of VEVideoParams).
typedef NS_ENUM(NSInteger, VEMotionParameter) {
    VEMotionParameterPositionX = 0, ///< VEVideoParams.x (sequence pixels)
    VEMotionParameterPositionY = 1, ///< VEVideoParams.y (sequence pixels, +y down)
    VEMotionParameterScale = 2,     ///< VEVideoParams.scale (1 = fitted size)
    VEMotionParameterRotation = 3,  ///< VEVideoParams.rotationDegrees (clockwise)
    VEMotionParameterOpacity = 4,   ///< VEVideoParams.opacity (0...1)
};

/// How a parameter moves from a keyframe to the next one (the interpolation belongs to the
/// segment that starts at the keyframe). The ease names follow Premiere Pro and Final Cut Pro.
typedef NS_ENUM(NSInteger, VEKeyframeInterpolation) {
    /// The value stays until the next keyframe, then jumps.
    VEKeyframeInterpolationHold = 0,
    /// Constant rate (the default for new keyframes).
    VEKeyframeInterpolationLinear = 1,
    /// Leaves the keyframe slowly, then speeds up.
    VEKeyframeInterpolationEaseOut = 2,
    /// Slows down to arrive at the next keyframe.
    VEKeyframeInterpolationEaseIn = 3,
    /// Both (the Ken Burns default).
    VEKeyframeInterpolationEaseInOut = 4,
    /// The exact part of an eased curve a split left on this segment (read only: set one of the
    /// others to replace it).
    VEKeyframeInterpolationCustom = 5,
};

/// A framing of the picture for the Ken Burns helper: the position and scale that make a chosen
/// rectangle of the picture fill the frame.
typedef struct {
    double x;
    double y;
    double scale;
} VEMotionFraming;

/// An end of a clip on the timeline.
typedef NS_ENUM(NSInteger, VEClipEdge) {
    /// Its first frame (where the previous clip on its track ends).
    VEClipEdgeStart = 0,
    /// Its last frame (where the next clip on its track starts).
    VEClipEdgeEnd = 1,
};

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
/// Container display rotation in degrees clockwise (0, 90, 180 or 270); zero for audio.
@property (nonatomic, readonly) NSInteger rotationDegrees;
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
/// Number of clips using this asset in every sequence of the project (the count removeAsset:
/// checks: the asset can be removed only at 0).
@property (nonatomic, readonly) NSInteger useCount;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A Motion keyframe of a clip (a snapshot, like VEClipInfo).
@interface VEKeyframe : NSObject
@property (nonatomic, readonly) VEMotionParameter parameter;
/// The keyframe's time: a source time of the clip (for a still, the time into the clip). Keyframes
/// stay with the pictures they were set on when the clip is trimmed, its speed changes or it is
/// split (see the engine's Keyframes.h).
@property (nonatomic, readonly) CMTime sourceTime;
/// Where it plays on the timeline with the clip's current start and speed (exact when
/// representable, else rounded); may lie outside the clip when a trim cut it off.
@property (nonatomic, readonly) CMTime timelineTime;
/// The sequence frame that shows it: the frame whose source span contains the keyframe (the
/// clip's last frame also owns a keyframe on the clip's out point, where a split leaves one).
/// Meaningful when isInsideClip.
@property (nonatomic, readonly) CMTime frameTime;
/// A frame of the clip shows the keyframe (false for keyframes a trim cut off).
@property (nonatomic, readonly) BOOL isInsideClip;
/// In VEVideoParams units (pixels, scale factor, degrees, opacity 0...1).
@property (nonatomic, readonly) double value;
@property (nonatomic, readonly) VEKeyframeInterpolation interpolation;
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
/// Playback speed for display (1 = normal; stills: 1). The exact value is
/// speedNumerator / speedDenominator (reduced, denominator 1...1000).
@property (nonatomic, readonly) double speed;
@property (nonatomic, readonly) int64_t speedNumerator;
@property (nonatomic, readonly) int64_t speedDenominator;
@property (nonatomic, readonly) BOOL isStill;
/// Linked partner, or 0.
@property (nonatomic, readonly) VEClipID linkedClipID;
/// The static Motion values: what a parameter without keyframes shows (an animated parameter's
/// static value is not used; see videoParamsAtTime:).
@property (nonatomic, readonly) VEVideoParams videoParams;
@property (nonatomic, readonly) VEAudioParams audioParams;
/// Whether any Motion parameter has keyframes.
@property (nonatomic, readonly) BOOL hasKeyframes;
/// Every keyframe of every parameter, in time order (then parameter order).
@property (nonatomic, readonly, copy) NSArray<VEKeyframe *> *allKeyframes;
/// Whether `parameter` has keyframes.
- (BOOL)isAnimated:(VEMotionParameter)parameter;
/// The keyframes of `parameter` in time order (keyframes a trim cut off included).
- (NSArray<VEKeyframe *> *)keyframesForParameter:(VEMotionParameter)parameter;
/// The Motion the picture has at timeline time `time` (keyframes evaluated at the exact source
/// time; the static value where a parameter has none), as the monitors and export draw it.
- (VEVideoParams)videoParamsAtTime:(CMTime)time NS_SWIFT_NAME(motion(at:));
/// The keyframe of `parameter` shown by the sequence frame containing `time` (see
/// VEKeyframe.frameTime), or nil.
- (nullable VEKeyframe *)keyframeForParameter:(VEMotionParameter)parameter atTime:(CMTime)time;
- (instancetype)init NS_UNAVAILABLE;
@end

/// The keyframes a keyframe marker in the timeline stands for: every Motion parameter's keyframe
/// that one sequence frame of a clip shows (VEEngine keyframeGroupOfClip:atTime:), and the frames
/// they can be moved to together (moveKeyframeGroupOfClip:fromTime:toTime:). A snapshot.
@interface VEKeyframeGroup : NSObject
@property (nonatomic, readonly) VEClipID clipID;
/// The sequence frame that shows them (its start, a timeline time).
@property (nonatomic, readonly) CMTime frameTime;
/// The Motion parameters with a keyframe on that frame (VEMotionParameter values), in parameter
/// order.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *parameters;
/// The first and last frames (timeline times, frame starts) they can move to: after the frame
/// showing the previous keyframe and before the frame showing the next one of each of those
/// parameters (keyframes stay in order, a frame apart), within the clip's frames. Both are
/// frameTime when they cannot move.
@property (nonatomic, readonly) CMTime earliestFrame;
@property (nonatomic, readonly) CMTime latestFrame;
/// Whether they can be moved (not on a locked track, not several keyframes of one parameter on
/// the frame); `reason` says why not ("" when they can).
@property (nonatomic, readonly) BOOL canMove;
@property (nonatomic, readonly, copy) NSString *reason;
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

/// Why an edit was refused (mirrors the engine's EditError).
typedef NS_ENUM(NSInteger, VEEditErrorCode) {
    VEEditErrorNone = 0,
    VEEditErrorSequenceNotFound,
    VEEditErrorTrackNotFound,
    VEEditErrorClipNotFound,
    VEEditErrorTransitionNotFound,
    VEEditErrorAssetNotFound,
    VEEditErrorTrackLocked,
    VEEditErrorTrackKindMismatch,
    VEEditErrorInvalidTime,
    VEEditErrorInvalidArgument,
    /// The result would overlap another clip or transition (e.g. an all-tracks ripple blocked by
    /// a clip on another track).
    VEEditErrorOverlap,
    VEEditErrorOutOfSourceRange,
    VEEditErrorInsufficientHandles,
    VEEditErrorNotAdjacent,
    VEEditErrorAlreadyExists,
    VEEditErrorAlreadyLinked,
    VEEditErrorNotLinked,
    /// The edit point lies inside a transition (splitClips:atTime:breakingTransitions: can
    /// remove it instead).
    VEEditErrorInsideTransition,
    /// An exact result time has no CMTime form; nothing is ever rounded, so the edit is refused.
    VEEditErrorNotRepresentable,
    VEEditErrorInvariantViolation,
    /// Refused by the facade itself (e.g. an edit while another gesture's edit is in progress).
    VEEditErrorBusy,
    /// The parameter has no keyframe at that time.
    VEEditErrorKeyframeNotFound,
};

/// Outcome of an edit. A refused edit changes nothing; `message` says why.
@interface VEEditResult : NSObject
@property (nonatomic, readonly) BOOL ok;
@property (nonatomic, readonly) VEEditErrorCode errorCode;
@property (nonatomic, readonly, copy) NSString *message;
/// Ids created by the edit (new clips of an insert/overwrite/split, a new track or
/// transition), in the order the engine reports them.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *createdIDs;
/// Transitions a successful edit removed as a side effect (their cut no longer exists or lacks
/// the media they need). Undo restores them.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *droppedTransitionIDs;
/// Something the user should know about a successful edit ("" when nothing): a ripple that fell
/// back to the synced tracks, removed transitions.
@property (nonatomic, readonly, copy) NSString *note;
+ (instancetype)success;
+ (instancetype)successWithCreatedIDs:(NSArray<NSNumber *> *)createdIDs;
+ (instancetype)failureWithMessage:(NSString *)message;
+ (instancetype)failureWithCode:(VEEditErrorCode)code message:(NSString *)message;
- (instancetype)init NS_UNAVAILABLE;
@end

/// The longest transition a cut can take (see VEEngine -transitionLimitFromClip:toClip:).
@interface VETransitionLimit : NSObject
/// Whole sequence frames; kCMTimeZero when no transition fits the cut.
@property (nonatomic, readonly) CMTime maximumDuration;
@property (nonatomic, readonly) int64_t maximumFrames;
/// What stops a longer transition (VEEditErrorInsufficientHandles: media beyond the cut;
/// VEEditErrorInvalidArgument: longer than the clips; VEEditErrorOverlap: a neighbouring
/// transition; or, with maximumFrames 0, a structural reason such as VEEditErrorNotAdjacent,
/// VEEditErrorAlreadyExists or VEEditErrorTrackLocked).
@property (nonatomic, readonly) VEEditErrorCode limitingError;
/// The same as a sentence for the user ("“a.mov” has no more media after its out point.").
@property (nonatomic, readonly, copy) NSString *reason;
/// For VEEditErrorInsufficientHandles: the clip that lacks media (else 0).
@property (nonatomic, readonly) VEClipID limitingClipID;
- (instancetype)init NS_UNAVAILABLE;
@end

// MARK: - Playback

typedef NS_ENUM(NSInteger, VEPlaybackState) {
    VEPlaybackStateStopped = 0,    ///< Paused, showing currentTime.
    VEPlaybackStatePrerolling = 1, ///< play() is waiting for the first frames and audio.
    VEPlaybackStatePlaying = 2,
    VEPlaybackStateScrubbing = 3,  ///< scrubToTime: in progress (ends with endScrub).
};

typedef NS_ENUM(NSInteger, VEClockMode) {
    VEClockModeStopped = 0,
    VEClockModeAudioSamples = 1, ///< The audio sample clock is master (1x, 2x).
    VEClockModeHostTime = 2,     ///< Host time (reverse, above 2x, or no audio output).
};

/// A playback state change, as delivered with VEEnginePlaybackDidChangeNotification.
@interface VEPlaybackStatus : NSObject
@property (nonatomic, readonly) VEPlaybackState state;
/// Playhead on the sequence frame grid.
@property (nonatomic, readonly) CMTime time;
/// Signed rate (1, 2, 4, 8, -1, ...); meaningful while playing or pre-rolling.
@property (nonatomic, readonly) double rate;
/// The audio clock drives playback (audible or muted).
@property (nonatomic, readonly) BOOL audioActive;
/// The most recent audio problem ("" when none): no output device, or the device went away.
@property (nonatomic, readonly, copy) NSString *errorMessage;
/// Playing or pre-rolling (the monitor's render loop should run).
@property (nonatomic, readonly) BOOL isRunning;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A clip under the playhead and how it is decoded (debug HUD).
@interface VEActiveClipInfo : NSObject
@property (nonatomic, readonly) VEClipID clipID;
@property (nonatomic, readonly) VEAssetID assetID;
@property (nonatomic, readonly) BOOL isAudio;
/// Decoder backend ("apple", "ffmpeg"; "" until a decoder opened).
@property (nonatomic, readonly, copy) NSString *backendName;
@property (nonatomic, readonly) BOOL hardware;
@property (nonatomic, readonly) BOOL failed;
- (instancetype)init NS_UNAVAILABLE;
@end

/// Playback counters for the debug HUD (a snapshot).
@interface VEPlaybackStats : NSObject
/// Presented frames per second (0 once nothing was presented for half a second).
@property (nonatomic, readonly) double fps;
@property (nonatomic, readonly) uint64_t presentedFrames;
/// Sequence frames skipped beyond what the rate explains.
@property (nonatomic, readonly) uint64_t droppedFrames;
/// Presentations missing a frame (the previous picture was held).
@property (nonatomic, readonly) uint64_t lateFrames;
@property (nonatomic, readonly) uint64_t cacheHits;
@property (nonatomic, readonly) uint64_t cacheMisses;
@property (nonatomic, readonly) double cacheHitRate;
@property (nonatomic, readonly) NSInteger decodeQueueDepth;
/// Decode streams the monitor's pool keeps (busy or idle: each holds a decoder and its lookahead).
@property (nonatomic, readonly) NSInteger decodeStreams;
@property (nonatomic, readonly) uint64_t audioUnderruns;
@property (nonatomic, readonly) uint64_t audioUnderrunFrames;
/// Decoded frames that could not be mapped to Metal textures.
@property (nonatomic, readonly) uint64_t mapFailures;
/// Presentations whose clock read was held so the picture never stepped backwards.
@property (nonatomic, readonly) uint64_t monotonicHolds;
@property (nonatomic, readonly) VEClockMode clockMode;
@property (nonatomic, readonly) CMTime clockTime;
/// Sequence frame index of the most recently presented program frame (-1: none yet); compare
/// with clockTime to see how far the picture is from the (audio) clock.
@property (nonatomic, readonly) int64_t presentedFrameIndex;
/// The clock (or paused) time that frame was chosen for.
@property (nonatomic, readonly) CMTime presentedTime;
/// The frame was chosen by the running clock (playing) rather than the paused position.
@property (nonatomic, readonly) BOOL presentedClockDriven;
/// When the program monitor's frame source handed that frame out, in seconds of the host time
/// base (CACurrentMediaTime()); 0 before the first frame. Play-start latency diagnostics.
@property (nonatomic, readonly) double presentedHostTime;
@property (nonatomic, readonly) BOOL audioActive;
@property (nonatomic, readonly) BOOL outputRunning;
/// Output latency the clock subtracts, in seconds.
@property (nonatomic, readonly) double outputLatency;
/// Kind of audio output ("avaudioengine", "null", ...).
@property (nonatomic, readonly, copy) NSString *audioOutputKind;
/// Frame cache bytes in use.
@property (nonatomic, readonly) uint64_t cacheBytes;
@property (nonatomic, readonly, copy) NSString *errorMessage;
@property (nonatomic, readonly, copy) NSArray<VEActiveClipInfo *> *activeClips;
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
