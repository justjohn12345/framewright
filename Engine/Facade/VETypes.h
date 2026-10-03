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

#import <FramewrightEngine/VETitles.h>

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
/// The field of `values` that holds `parameter` (NaN for a value outside VESpanParameter).
FOUNDATION_EXPORT double VESpanValuesGetValue(VESpanValues values, VESpanParameter parameter)
    NS_SWIFT_NAME(VESpanValues.value(self:for:));
/// Sets the field of `values` that holds `parameter` to `value` (nothing for a value outside
/// VESpanParameter).
FOUNDATION_EXPORT void VESpanValuesSetValue(VESpanValues *values, double value, VESpanParameter parameter)
    NS_SWIFT_NAME(VESpanValues.setValue(self:_:for:));

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

/// What a video transition does to the picture (ve::TransitionKind; the same at a cut and at a free
/// edge, where the other side is black). Audio transitions are always CrossDissolve (a constant-power
/// crossfade or a fade). The wipes are named for the direction the edge between the pictures travels.
typedef NS_ENUM(NSInteger, VETransitionKind) {
    /// Every pixel mixes linearly from the outgoing picture to the incoming one.
    VETransitionKindCrossDissolve = 0,
    /// The incoming picture enters from the right edge; the edge travels left.
    VETransitionKindWipeLeft = 1,
    /// The incoming picture enters from the left edge; the edge travels right.
    VETransitionKindWipeRight = 2,
    /// The incoming picture enters from the bottom edge; the edge travels up.
    VETransitionKindWipeUp = 3,
    /// The incoming picture enters from the top edge; the edge travels down.
    VETransitionKindWipeDown = 4,
    /// The incoming picture shows inside a circle growing from the frame's centre to its corners.
    VETransitionKindIris = 5,
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

/// A parameter of a clip's colour grade (the engine's ClipGrade.h; names, units, neutral values and
/// ranges in VEGradeParameterInfo). The grade applies to the clip's picture in linear light, after its
/// conversion to RGB and before its Motion, opacity and blending.
typedef NS_ENUM(NSInteger, VEGradeParameter) {
    /// Stops: a gain of 2^value (neutral 0, -5...5).
    VEGradeParameterExposure = 0,
    /// The exponent of a power curve about linear 0.18 (neutral 1, 0...2; above 1 steeper).
    VEGradeParameterContrast = 1,
    /// Warm (+) or cool (-), a red/blue gain pair keeping luminance (neutral 0, -100...100).
    VEGradeParameterTemperature = 2,
    /// Magenta (+) or green (-), a green gain keeping luminance (neutral 0, -100...100).
    VEGradeParameterTint = 3,
    /// 0 grey, 1 unchanged, 2 twice as saturated (neutral 1, 0...2).
    VEGradeParameterSaturation = 4,
};

/// A clip's grade values (a field per VEGradeParameter). When passed to an edit, NaN means
/// "unchanged"; when read from a VEGradeSelection, NaN means the clips differ (or there are none).
typedef struct {
    double exposure;
    double contrast;
    double temperature;
    double tint;
    double saturation;
} VEGradeParams;

/// Every field at its neutral value (no grade).
FOUNDATION_EXPORT VEGradeParams VEGradeParamsNeutral(void);
/// Every field NaN (nothing to change).
FOUNDATION_EXPORT VEGradeParams VEGradeParamsUnchanged(void);
/// The field of `params` that holds `parameter` (NaN for a value outside VEGradeParameter).
FOUNDATION_EXPORT double VEGradeParamsGetValue(VEGradeParams params, VEGradeParameter parameter)
    NS_SWIFT_NAME(VEGradeParams.value(self:for:));
/// Sets the field of `params` that holds `parameter` to `value` (nothing for a value outside
/// VEGradeParameter).
FOUNDATION_EXPORT void VEGradeParamsSetValue(VEGradeParams *params, double value, VEGradeParameter parameter)
    NS_SWIFT_NAME(VEGradeParams.setValue(self:_:for:));

/// One row of the engine's grade parameter table: what a colour control shows for a parameter.
@interface VEGradeParameterInfo : NSObject
/// The row of `parameter`, or nil for a value outside VEGradeParameter.
+ (nullable VEGradeParameterInfo *)infoForParameter:(VEGradeParameter)parameter
    NS_SWIFT_NAME(info(for:));
/// Every parameter (VEGradeParameter values as NSNumbers) in the table's order.
@property (class, nonatomic, readonly, copy) NSArray<NSNumber *> *allParameters;
@property (nonatomic, readonly) VEGradeParameter parameter;
/// The project file's key ("exposure", "contrast", "temperature", "tint", "saturation").
@property (nonatomic, readonly, copy) NSString *name;
/// "Exposure", "Contrast", "Temperature", "Tint", "Saturation".
@property (nonatomic, readonly, copy) NSString *displayName;
/// "stops", "×", or "" for the relative scales of temperature and tint.
@property (nonatomic, readonly, copy) NSString *unit;
/// The value that changes nothing (0 or 1).
@property (nonatomic, readonly) double neutralValue;
/// The valid range, [minimum, maximum].
@property (nonatomic, readonly) double minimum;
@property (nonatomic, readonly) double maximum;
- (instancetype)init NS_UNAVAILABLE;
@end

/// What the clips of a selection have for each grade parameter (-[VEEngine gradeOfClips:]): the value
/// where they agree, "mixed" where they differ.
@interface VEGradeSelection : NSObject
/// The clips of the selection that can have a grade (those on video tracks), in the order given.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *clipIDs;
/// Per parameter, the value every clip has; NaN where they differ, and every field NaN without clips.
@property (nonatomic, readonly) VEGradeParams values;
/// Whether any of the clips has a grade (a value that is not neutral).
@property (nonatomic, readonly) BOOL anyGraded;
/// Whether every clip has the same whole grade: each value and what a newer version wrote that this one
/// keeps (both of which copyGradeOfClip: copies), so copying any of them copies the same grade. YES for
/// one clip, NO without clips. Equal values with different entries of a newer version are not identical.
@property (nonatomic, readonly, getter=isIdentical) BOOL identical;
/// Whether the clips differ in `parameter` (NO without clips or for a value outside the enum).
- (BOOL)isMixed:(VEGradeParameter)parameter NS_SWIFT_NAME(isMixed(_:));
- (instancetype)init NS_UNAVAILABLE;
@end

/// A colour wheel of a clip's grade (colour grading slice 2; the engine's GradeWheel): lift moves the
/// shadows most, gamma the midtones, gain the highlights. Applied in linear light after saturation and before
/// contrast, as out = (gain * (in + lift * (1 - in)))^(1 / gamma) per channel (see VEGradeWheelValue).
typedef NS_ENUM(NSInteger, VEGradeWheel) {
    VEGradeWheelLift = 0,
    VEGradeWheelGamma = 1,
    VEGradeWheelGain = 2,
};

/// A wheel's setting: `level` in [-1, 1] (lift: the blacks raised to linear 0.1 at 1; gain: +-1 stop;
/// gamma: linear 0.18 to 0.42 at 1), and its colour, the point (`cb`, `cr`) in the unit disk, taken as
/// BT.709 chroma as a vectorscope shows it (+cr toward red, +cb toward blue): the channels tilt toward that
/// colour, by about half a stop at the rim, keeping luminance. All zero is neutral. When read from a
/// VEGradeSelection, every field is NaN where the clips differ.
typedef struct {
    double level;
    double cb;
    double cr;
} VEGradeWheelValue;

/// Every field 0 (a neutral wheel).
FOUNDATION_EXPORT VEGradeWheelValue VEGradeWheelValueNeutral(void);

/// The wheels' names and what they move.
@interface VEGradeWheelInfo : NSObject
/// The row of `wheel`, or nil for a value outside VEGradeWheel.
+ (nullable VEGradeWheelInfo *)infoForWheel:(VEGradeWheel)wheel NS_SWIFT_NAME(info(for:));
/// Every wheel (VEGradeWheel values as NSNumbers) in order: lift, gamma, gain.
@property (class, nonatomic, readonly, copy) NSArray<NSNumber *> *allWheels;
@property (nonatomic, readonly) VEGradeWheel wheel;
/// The file's key prefix: "lift", "gamma", "gain".
@property (nonatomic, readonly, copy) NSString *name;
/// "Lift", "Gamma", "Gain".
@property (nonatomic, readonly, copy) NSString *displayName;
/// "shadows", "midtones", "highlights".
@property (nonatomic, readonly, copy) NSString *tonalRange;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface VEGradeSelection (Wheels)
/// The setting every clip has for `wheel`; every field NaN where they differ, without clips, or for a value
/// outside VEGradeWheel.
- (VEGradeWheelValue)valueForWheel:(VEGradeWheel)wheel NS_SWIFT_NAME(wheel(_:));
/// Whether the clips differ in `wheel` (NO without clips or for a value outside the enum).
- (BOOL)isWheelMixed:(VEGradeWheel)wheel NS_SWIFT_NAME(isWheelMixed(_:));
@end

/// A tone curve of a clip's grade (colour grading slice 2; the engine's GradeCurve), over the encoded values
/// the scopes show: Luma moves each pixel's luma (keeping its colour), Red, Green and Blue map their
/// channels. A curve passes through its points (x the input, y the output, both 0 to 1, x increasing, 2 to
/// 16 points; NSValue-wrapped points) as a monotone cubic, flat beyond its first and last points; no points
/// is the identity.
typedef NS_ENUM(NSInteger, VEGradeCurve) {
    VEGradeCurveLuma = 0,
    VEGradeCurveRed = 1,
    VEGradeCurveGreen = 2,
    VEGradeCurveBlue = 3,
};

/// The curves' names.
@interface VEGradeCurveInfo : NSObject
/// The row of `curve`, or nil for a value outside VEGradeCurve.
+ (nullable VEGradeCurveInfo *)infoForCurve:(VEGradeCurve)curve NS_SWIFT_NAME(info(for:));
/// Every curve (VEGradeCurve values as NSNumbers) in order: luma, red, green, blue.
@property (class, nonatomic, readonly, copy) NSArray<NSNumber *> *allCurves;
/// The most points a curve has (16).
@property (class, nonatomic, readonly) NSInteger maximumPointCount;
@property (nonatomic, readonly) VEGradeCurve curve;
/// The file's key: "curveLuma", ...
@property (nonatomic, readonly, copy) NSString *name;
/// "Luma", "Red", "Green", "Blue".
@property (nonatomic, readonly, copy) NSString *displayName;
- (instancetype)init NS_UNAVAILABLE;
@end

/// The curve through `points` (NSValue-wrapped points, as a clip has them) at `count` evenly spaced x from 0
/// to 1 into `samples` (sample i at x = i / (count - 1)): what the renderer applies, for drawing a curve.
/// Points that are not a valid curve are first made valid as a project file's are (limited to [0, 1],
/// sorted, at most 16).
FOUNDATION_EXPORT void VEGradeCurveSample(NSArray<NSValue *> *points, double *samples, NSInteger count)
    NS_SWIFT_NAME(VEGradeCurveInfo.sample(_:into:count:));

/// A hue curve of a clip's grade (the engine's GradeHueCurve): over hue (x, 0 to 1 around the circle, starting
/// at blue's side of the Cb axis and turning toward red, as a vectorscope shows hues; periodic), its output (y,
/// 0 to 1, 0.5 changes nothing) scales the saturation (0 grey, 1 doubled), turns the hue (up to 60 degrees each
/// way) or scales the luminance (up to a stop each way) of the colours of that hue. 1 to 16 points (x in
/// [0, 1), increasing), a periodic monotone cubic (no overshoot between points); no points is the identity.
typedef NS_ENUM(NSInteger, VEGradeHueCurve) {
    VEGradeHueCurveSaturation = 0,
    VEGradeHueCurveHue = 1,
    VEGradeHueCurveLuma = 2,
};

/// The hue curve through `points` at `count` hues i / count into `samples` (made valid first, as a project
/// file's are): what the renderer applies, for drawing.
FOUNDATION_EXPORT void VEGradeHueCurveSample(NSArray<NSValue *> *points, double *samples, NSInteger count)
    NS_SWIFT_NAME(VEGradeCurveInfo.sampleHue(_:into:count:));

@interface VEGradeSelection (Curves)
/// The points every clip has for `curve` (empty for the identity); nil where they differ, without clips, or
/// for a value outside VEGradeCurve.
- (nullable NSArray<NSValue *> *)pointsForCurve:(VEGradeCurve)curve NS_SWIFT_NAME(curve(_:));
/// Whether the clips differ in `curve` (NO without clips or for a value outside the enum).
- (BOOL)isCurveMixed:(VEGradeCurve)curve NS_SWIFT_NAME(isCurveMixed(_:));
/// The same for a hue curve.
- (nullable NSArray<NSValue *> *)pointsForHueCurve:(VEGradeHueCurve)curve NS_SWIFT_NAME(hueCurve(_:));
- (BOOL)isHueCurveMixed:(VEGradeHueCurve)curve NS_SWIFT_NAME(isHueCurveMixed(_:));
@end

/// The kind of a colour LUT (a .cube file).
typedef NS_ENUM(NSInteger, VELUTKind) {
    /// One curve per channel.
    VELUTKind1D = 1,
    /// A cube of colours, interpolated tetrahedrally.
    VELUTKind3D = 3,
};

/// A colour LUT the engine holds (imported from a .cube file; a project keeps a copy of each LUT its clips
/// use, so it opens anywhere).
@interface VELUTInfo : NSObject
/// The LUT's content id (the same table always has the same id).
@property (nonatomic, readonly, copy) NSString *lutID;
/// What to call it: the file's TITLE, else its file name without the extension.
@property (nonatomic, readonly, copy) NSString *displayName;
/// The file's name and where it was imported from ("" when unknown).
@property (nonatomic, readonly, copy) NSString *fileName;
@property (nonatomic, readonly, copy) NSString *sourcePath;
@property (nonatomic, readonly) VELUTKind kind;
/// Entries per channel (1D) or per side (3D).
@property (nonatomic, readonly) NSInteger size;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface VEGradeSelection (LUTs)
/// The input LUT's id every clip has ("" for none); nil where they differ or without clips.
@property (nonatomic, readonly, copy, nullable) NSString *inputLUTID;
/// The look's id every clip has ("" for none); nil where they differ or without clips.
@property (nonatomic, readonly, copy, nullable) NSString *lookLUTID;
/// The look's strength every clip has (0 to 1); NaN where they differ or without clips.
@property (nonatomic, readonly) double lookStrength;
@end

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
/// What a generator asset generates (the project's hidden "Title" and "Colour Matte" assets, which have no file
/// and no size; allAssets leaves them out); VEGeneratorKindNone for media.
@property (nonatomic, readonly) VEGeneratorKind generatorKind;
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
/// Transitions: what it does to the picture (CrossDissolve for an audio transition and for effect
/// spans).
@property (nonatomic, readonly) VETransitionKind transitionKind;
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
/// Name of the asset (clips have no own name); a title's first line ("Title" when it has none), "Colour Matte"
/// for a matte.
@property (nonatomic, readonly, copy) NSString *name;
/// A title or a colour matte (VETitles.h): what the clip generates; VEGeneratorKindNone for a clip of media.
@property (nonatomic, readonly) VEGeneratorKind generatorKind;
/// A title clip's content (nil for any other clip).
@property (nonatomic, readonly, nullable) VETitleInfo *title;
/// A colour matte's colour (black for any other clip).
@property (nonatomic, readonly) VEColour matteColour;
/// The size of the picture the clip shows before its Motion, in pixels: the asset's displayed size (rotation
/// applied), or the sequence's frame for a title or a matte (which stand for a frame-sized canvas); zero for sound.
@property (nonatomic, readonly) NSInteger pictureWidth;
@property (nonatomic, readonly) NSInteger pictureHeight;
@property (nonatomic, readonly) CMTime timelineStart;
@property (nonatomic, readonly) CMTime duration;
@property (nonatomic, readonly) CMTime timelineEnd;
/// Used source range (for stills measured in timeline time from zero). For a reversed clip these are
/// clip times counted back from the media's end (mediaEnd - media time; see `reversed`): edits,
/// spans and limits all use them; mediaIn / mediaOut are the media the clip shows.
@property (nonatomic, readonly) CMTime sourceIn;
@property (nonatomic, readonly) CMTime sourceOut;
/// Plays its media backwards (Clip > Reverse Clip): frame k of an n-frame clip shows what frame
/// n - 1 - k shows forward, and its sound plays backwards.
@property (nonatomic, readonly) BOOL reversed;
/// The media range the clip shows: sourceIn / sourceOut forward, mediaEnd - sourceOut /
/// mediaEnd - sourceIn reversed (a still: sourceIn / sourceOut).
@property (nonatomic, readonly) CMTime mediaIn;
@property (nonatomic, readonly) CMTime mediaOut;
/// Where the media the clip's track uses ends (the video's end on a video track, the media's
/// duration on an audio track): a reversed clip's media time is mediaEnd - its source time.
@property (nonatomic, readonly) CMTime mediaEnd;
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
/// The clip's colour grade (every field neutral when it has none; always neutral on an audio track).
@property (nonatomic, readonly) VEGradeParams grade;
/// Whether the clip has a grade: a value or a wheel that is not neutral.
@property (nonatomic, readonly) BOOL hasGrade;
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
/// What the rest of the clip composes to under an edge of its effect span `spanID`: the values the
/// span's own (relative) values apply onto there. It is the clip's static values with every other
/// span that has started composed on, at the instant getMotion(_:atEdgeOfSpan:atEnd:frameDuration:)
/// reads (the span's start, or its last frame for `atEnd`), what earlier spans hold there included.
/// So an edge shows base + value for Position X/Y, Rotation and Gain and base x value for Scale and
/// Opacity, and a value wanted on screen converts back to the span's value exactly (a fade from 0
/// included, whose edge shows 0 whatever the base). The fields of the span's kind are set (Motion: x,
/// y, scale, rotationDegrees; Opacity: opacity; Gain: gainDb), the others are NaN. Returns NO, leaving
/// `values` unchanged, for an unknown span, a transition, a non-positive frame duration or a time
/// with no exact form.
- (BOOL)getBaseValues:(VESpanValues *)values
            underSpan:(VESpanID)spanID
                atEnd:(BOOL)atEnd
        frameDuration:(CMTime)frameDuration NS_SWIFT_NAME(getBaseValues(_:underSpan:atEnd:frameDuration:));
- (instancetype)init NS_UNAVAILABLE;
@end

@interface VEClipInfo (Wheels)
/// The clip's setting of `wheel` (neutral for a value outside VEGradeWheel).
- (VEGradeWheelValue)gradeWheel:(VEGradeWheel)wheel NS_SWIFT_NAME(gradeWheel(_:));
/// The clip's points of `curve` (NSValue-wrapped points; empty for the identity or a value outside
/// VEGradeCurve).
- (NSArray<NSValue *> *)gradeCurvePoints:(VEGradeCurve)curve NS_SWIFT_NAME(gradeCurvePoints(_:));
/// The clip's points of hue curve `curve` (empty for the identity or a value outside VEGradeHueCurve).
- (NSArray<NSValue *> *)gradeHueCurvePoints:(VEGradeHueCurve)curve NS_SWIFT_NAME(gradeHueCurvePoints(_:));
/// The ids of the clip's input LUT and look ("" for none; -[VEEngine lutWithID:] describes them), and the
/// look's strength (0 to 1; 1 without a look).
@property (nonatomic, readonly, copy) NSString *gradeInputLUTID;
@property (nonatomic, readonly, copy) NSString *gradeLookLUTID;
@property (nonatomic, readonly) double gradeLookStrength;
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
/// What it does to the picture (CrossDissolve for an audio transition).
@property (nonatomic, readonly) VETransitionKind kind;
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
/// The rate the sequence is mixed and exported at (Hz).
@property (nonatomic, readonly) NSInteger audioSampleRate;
/// Whether the settings were chosen: NO only for a new project's sequence until its first video clip
/// is placed (which sets its size and frame rate, see VEEngine insertAsset:...) or the Sequence
/// Settings are applied (-applySequenceSettings:).
@property (nonatomic, readonly, getter=isConfigured) BOOL configured;
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

/// The active sequence's settings as the Sequence Settings sheet edits them (an immutable value).
@interface VESequenceSettings : NSObject <NSCopying>
/// Even, 16...16384 pixels.
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
/// One of VEEngine.standardSequenceFrameDurations (the engine accepts any rate from 1 to 240 fps).
@property (nonatomic, readonly) CMTime frameDuration;
/// Hz, 8000...192000 (the sheet offers 44100 and 48000).
@property (nonatomic, readonly) NSInteger audioSampleRate;
/// The project's "Sharpen scaled-down sources" (VEEngine.sharpenScaledDownSources).
@property (nonatomic, readonly) BOOL sharpenScaledDownSources;
- (instancetype)initWithWidth:(NSInteger)width
                       height:(NSInteger)height
                frameDuration:(CMTime)frameDuration
              audioSampleRate:(NSInteger)audioSampleRate
     sharpenScaledDownSources:(BOOL)sharpenScaledDownSources NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@end

/// What applying VESequenceSettings would do (-[VEEngine previewSequenceSettings:]).
@interface VESequenceSettingsPreview : NSObject
/// Why the settings cannot be applied (a value out of range, a clip that cannot be conformed), or nil.
@property (nonatomic, readonly, copy, nullable) NSString *refusal;
/// Any setting differs from the current one.
@property (nonatomic, readonly) BOOL changesSettings;
/// The size, frame rate or sample rate differ and the sequence has clips: the sheet confirms first.
@property (nonatomic, readonly) BOOL needsConfirmation;
/// Sentences naming what changes, in order: the frame size and what it does to placements, the frame
/// grid and the clips' edges, transitions kept, shortened or removed, effect spans, the sample rate,
/// the sharpening. Empty when nothing changes.
@property (nonatomic, readonly, copy) NSArray<NSString *> *changes;
/// Clips whose placement is rescaled (a size change), clips whose start or end moves (a frame-rate
/// change), transitions shortened or removed to fit.
@property (nonatomic, readonly) NSInteger clipsRescaled;
@property (nonatomic, readonly) NSInteger clipsRetimed;
@property (nonatomic, readonly) NSInteger transitionsShortened;
@property (nonatomic, readonly) NSInteger transitionsRemoved;
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
/// back to the synced tracks, a transition fitted to its cut. What the edit removed as a side
/// effect is not in it: see droppedTransitionIDs and droppedSpanIDs (the app words them).
@property (nonatomic, readonly, copy) NSString *note;
/// A split: the effect spans the cut divided, keyed by the id of the right piece's part (new) with
/// the id of the span it came from (which the left piece keeps) as the value. Empty for every other
/// edit.
@property (nonatomic, readonly, copy) NSDictionary<NSNumber *, NSNumber *> *dividedSpanIDs;
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
