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
/// A transition: the id of its lane-0 span (VESpanID).
typedef int64_t VETransitionID;
typedef int64_t VESequenceID;
/// An effect span (transitions included: a transition is a lane-0 span).
typedef int64_t VESpanID;

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

/// A Motion parameter (a field of VEVideoParams).
typedef NS_ENUM(NSInteger, VEMotionParameter) {
    VEMotionParameterPositionX = 0, ///< VEVideoParams.x (sequence pixels)
    VEMotionParameterPositionY = 1, ///< VEVideoParams.y (sequence pixels, +y down)
    VEMotionParameterScale = 2,     ///< VEVideoParams.scale (1 = fitted size)
    VEMotionParameterRotation = 3,  ///< VEVideoParams.rotationDegrees (clockwise)
    VEMotionParameterOpacity = 4,   ///< VEVideoParams.opacity (0...1)
};

/// How an effect span moves from its start values to its end values. The ease names follow
/// Premiere Pro and Final Cut Pro.
typedef NS_ENUM(NSInteger, VEKeyframeInterpolation) {
    /// The start values hold until the span's end, then the end values apply.
    VEKeyframeInterpolationHold = 0,
    /// Constant rate (the default for a new span).
    VEKeyframeInterpolationLinear = 1,
    /// Leaves the start values slowly, then speeds up.
    VEKeyframeInterpolationEaseOut = 2,
    /// Slows down to arrive at the end values.
    VEKeyframeInterpolationEaseIn = 3,
    /// Both (the Ken Burns default).
    VEKeyframeInterpolationEaseInOut = 4,
    /// The exact part of an eased curve left on a span that a split divided, or segments that
    /// differ (a span migrated from keyframes); read only: set one of the others to replace it.
    VEKeyframeInterpolationCustom = 5,
};

/// What an effect span changes (see VEEffectSpan).
typedef NS_ENUM(NSInteger, VESpanKind) {
    /// Lane 0: a cross dissolve / crossfade across a cut, or a fade to or from black / silence.
    VESpanKindTransition = 0,
    /// Video, lanes 1-3: position X/Y, scale and rotation, composed onto the clip's values.
    VESpanKindMotion = 1,
    /// Video, lanes 1-3: opacity, a factor on the clip's opacity (a video fade).
    VESpanKindOpacity = 2,
    /// Audio, lanes 1-3: gain in dB added to the clip's gain.
    VESpanKindGain = 3,
};

/// A parameter an effect span animates (a field of VESpanValues).
typedef NS_ENUM(NSInteger, VESpanParameter) {
    VESpanParameterPositionX = 0, ///< pixels added to the clip's x
    VESpanParameterPositionY = 1, ///< pixels added to the clip's y (+y down)
    VESpanParameterScale = 2,     ///< factor on the clip's scale
    VESpanParameterRotation = 3,  ///< degrees added to the clip's rotation
    VESpanParameterOpacity = 4,   ///< factor on the clip's opacity (0...1)
    VESpanParameterGain = 5,      ///< dB added to the clip's gain
};

/// Values of an effect span's parameters at one of its ends. A field the span's kind does not
/// animate is NaN when read; when passed to an edit, NaN means "unchanged" (and a number for a
/// parameter of another kind is refused).
typedef struct {
    double x;
    double y;
    double scale;
    double rotationDegrees;
    double opacity;
    double gainDb;
} VESpanValues;

/// Every field NaN (nothing to change).
FOUNDATION_EXPORT VESpanValues VESpanValuesUnchanged(void);

/// What a transition span does where it sits.
typedef NS_ENUM(NSInteger, VETransitionStyle) {
    /// Across the cut at its clip's end into the clip touching it (video: cross dissolve; audio:
    /// constant-power crossfade).
    VETransitionStyleCrossDissolve = 0,
    /// To black (video) or silence (audio) at its clip's end.
    VETransitionStyleFadeOut = 1,
    /// From black / silence at its clip's start (only where no clip touches that start).
    VETransitionStyleFadeIn = 2,
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

/// Clip audio settings: gain in dB and the lengths of the clip's linear fades. The fades are the
/// clip's lane-0 transition spans (a fade in at its head, a tail span ending on the cut): reading
/// reports their lengths (0 when there is none; a crossfade at the tail is not a fade), setting
/// them adds, changes or removes those spans (a fade in is refused on a clip whose start another
/// clip touches, a fade out on a clip that ends in a crossfade).
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

/// An effect span of a clip (a snapshot, like VEClipInfo): a range on one of the clip's lanes with
/// start and end values for what it changes. Lane 0 holds transitions (cross dissolves / crossfades
/// and fades), lanes 1-3 Motion and Opacity spans (video) or Gain spans (audio), which compose onto
/// the clip's static values: position and rotation add, scale and opacity multiply, gain adds (dB).
/// An effect span does nothing before its start, moves over its range and holds its end values from
/// its end to the clip's end; a later span on the same lane applies on top of what it holds.
@interface VEEffectSpan : NSObject
@property (nonatomic, readonly) VESpanID spanID;
@property (nonatomic, readonly) VEClipID clipID;
@property (nonatomic, readonly) VETrackID trackID;
/// 0 (transitions) to 3.
@property (nonatomic, readonly) NSInteger lane;
@property (nonatomic, readonly) VESpanKind kind;
/// The range clip-relative: for an effect span the source times of the clip it covers (for a
/// still, the time into the clip; spans stay on their pictures through trims and speed changes);
/// for a transition the offsets from its edge (a tail span [-before, after] around the cut at the
/// clip's end, a head span [0, length]).
@property (nonatomic, readonly) CMTime clipRelativeStart;
@property (nonatomic, readonly) CMTime clipRelativeEnd;
/// The timeline range it covers (exact when representable, else rounded).
@property (nonatomic, readonly) CMTime start;
@property (nonatomic, readonly) CMTime end;
/// Values at its start and end (NaN for parameters of other kinds; all NaN for a transition).
@property (nonatomic, readonly) VESpanValues startValues;
@property (nonatomic, readonly) VESpanValues endValues;
/// How it moves from start to end (Linear for a transition).
@property (nonatomic, readonly) VEKeyframeInterpolation interpolation;
/// Transitions: what it does (else CrossDissolve), its length, its share before and after the cut
/// (a fade out lies before its cut, a fade in after its clip's start), the clip on the other side
/// of a cross dissolve (0 for a fade) and the linked transition (the dissolve's audio crossfade or
/// the other way round; 0 when none).
@property (nonatomic, readonly) VETransitionStyle transitionStyle;
@property (nonatomic, readonly) CMTime duration;
@property (nonatomic, readonly) CMTime shareBeforeCut;
@property (nonatomic, readonly) CMTime shareAfterCut;
@property (nonatomic, readonly) VEClipID partnerClipID;
@property (nonatomic, readonly) VESpanID linkedSpanID;
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
/// The static Motion values: what the clip shows before its first span starts (its Motion and
/// Opacity spans compose onto them; see videoParamsAtTime:).
@property (nonatomic, readonly) VEVideoParams videoParams;
/// The static gain and the lengths of the clip's lane-0 fades (see VEAudioParams).
@property (nonatomic, readonly) VEAudioParams audioParams;
/// The clip's spans: lane 0 (transitions) first, then lanes 1-3, each in time order.
@property (nonatomic, readonly, copy) NSArray<VEEffectSpan *> *spans;
/// Whether the clip has spans on lanes 1-3.
@property (nonatomic, readonly) BOOL hasEffectSpans;
/// The Motion the picture has at timeline time `time` (the static values with every span that has
/// started composed onto them: the moving value inside its range, its end value after it; evaluated
/// at the frame's exact source time), as the monitors and export draw it.
- (VEVideoParams)videoParamsAtTime:(CMTime)time NS_SWIFT_NAME(motion(at:));
/// The clip's audio level in dB at timeline time `time` (the static gain plus its Gain spans, each
/// holding its end level after its end).
- (double)gainDbAtTime:(CMTime)time NS_SWIFT_NAME(gainDb(at:));
/// The Motion an edge of the clip's Motion span `spanID` shows, as applyKenBurns(span:) sets it:
/// at its start (`atEnd` NO) everything composed at the span's first instant (including the end
/// framing an earlier move on its lane holds there); at its end the clip's other spans composed at
/// the span's last frame (the sequence frame, `frameDuration` long, before its end) with the span at
/// its end values. So the framings a Ken Burns move applied read back exactly (motion(at:) of the
/// last frame shows the move one frame short of its end; from its end on the end framing holds).
/// Returns NO, leaving `motion` unchanged, for an unknown span, one of another kind or a time with
/// no exact form.
- (BOOL)getMotion:(VEVideoParams *)motion
     atEdgeOfSpan:(VESpanID)spanID
            atEnd:(BOOL)atEnd
    frameDuration:(CMTime)frameDuration NS_SWIFT_NAME(getMotion(_:atEdgeOfSpan:atEnd:frameDuration:));
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

/// A transition: a lane-0 span of the clip that owns it (see VEEffectSpan for the full detail).
@interface VETransitionInfo : NSObject
@property (nonatomic, readonly) VETransitionID transitionID;
@property (nonatomic, readonly) VETrackID trackID;
/// A cross dissolve: the outgoing clip (the owner) and the incoming one. A fade out: the owner and
/// 0; a fade in: 0 and the owner.
@property (nonatomic, readonly) VEClipID fromClipID;
@property (nonatomic, readonly) VEClipID toClipID;
@property (nonatomic, readonly) VETransitionStyle style;
@property (nonatomic, readonly) CMTime duration;
/// Timeline range covered, and how much of it lies before and after the cut.
@property (nonatomic, readonly) CMTime start;
@property (nonatomic, readonly) CMTime end;
@property (nonatomic, readonly) CMTime shareBeforeCut;
@property (nonatomic, readonly) CMTime shareAfterCut;
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
/// The cross dissolves / crossfades (transitions across a cut), in track order then time order.
/// Fades are spans of their clips (VEClipInfo.spans; for audio also VEAudioParams).
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
    /// No effect span with that id.
    VEEditErrorSpanNotFound,
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
/// the media they need, or a fade in whose clip's start another clip now touches). Undo restores them.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *droppedTransitionIDs;
/// Effect spans (lanes 1-3) a successful edit removed as a side effect: a trim or overwrite left
/// nothing of them inside their clip. Undo restores them.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *droppedSpanIDs;
/// A span edit refused for overlapping another span of the lane (VEEditErrorOverlap): the free
/// range of that lane nearest the requested one, in timeline time (kCMTimeRangeInvalid otherwise).
@property (nonatomic, readonly) CMTimeRange freeRange;
/// A successful span edit: the span as it is after the edit (nil otherwise).
@property (nonatomic, readonly, nullable) VEEffectSpan *span;
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
