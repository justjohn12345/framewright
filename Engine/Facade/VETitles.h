// The facade's value types for titles and colour mattes (docs/plans/2026-10-02-titles-design.md): a title or a
// colour matte is a clip of its own on a video track that carries its content (VEClipInfo.title / matteColour) and
// refers to the project's hidden generator asset of its kind. The edits and queries are VEEngine (Titles)
// (VEEngine.h).
//
// Units: a title's positions are fractions of the frame's width and height (x, y: the point its text block is anchored
// at, its centre unless the title is point text or anchored at its top or bottom);
// its sizes (font size, outline width, shadow distance and blur, box padding, corner radius) are fractions of the
// frame's height; the box width a fraction of the frame's width. Colours are sRGB components in [0, 1]. The table
// VETitleParameterInfo gives each parameter's type, unit, default and range.
// Plain Objective-C only: this header is part of the framework's public module.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What a generator asset or a generated clip makes: nothing (media), a title or a colour matte.
typedef NS_ENUM(NSInteger, VEGeneratorKind) {
    VEGeneratorKindNone = 0,
    VEGeneratorKindTitle = 1,
    VEGeneratorKindColourMatte = 2,
};

/// What a new title or matte starts as (section 9 of the titles design): a centred title, a lower third
/// (left-aligned in the lower left inside title-safe, "Name" and "Role" on a 60 % black box) and a black matte.
typedef NS_ENUM(NSInteger, VEGeneratedPreset) {
    VEGeneratedPresetTitle = 0,
    VEGeneratedPresetLowerThird = 1,
    VEGeneratedPresetColourMatte = 2,
};

/// A title's parameter (the engine's TitleParameter, in order).
typedef NS_ENUM(NSInteger, VETitleParameter) {
    VETitleParameterText = 0,
    VETitleParameterFont = 1,
    VETitleParameterSize = 2,
    VETitleParameterFillColour = 3,
    VETitleParameterAlignment = 4,
    VETitleParameterLineSpacing = 5,
    VETitleParameterTracking = 6,
    VETitleParameterOutline = 7,
    VETitleParameterOutlineColour = 8,
    VETitleParameterOutlineWidth = 9,
    VETitleParameterShadow = 10,
    VETitleParameterShadowColour = 11,
    VETitleParameterShadowOpacity = 12,
    VETitleParameterShadowAngle = 13,
    VETitleParameterShadowDistance = 14,
    VETitleParameterShadowBlur = 15,
    VETitleParameterBox = 16,
    VETitleParameterBoxColour = 17,
    VETitleParameterBoxOpacity = 18,
    VETitleParameterBoxPadding = 19,
    VETitleParameterBoxCornerRadius = 20,
    VETitleParameterPositionX = 21,
    VETitleParameterPositionY = 22,
    VETitleParameterBoxWidth = 23,
    VETitleParameterPointText = 24,
    VETitleParameterAnchor = 25,
};

/// The kind of value a title parameter takes.
typedef NS_ENUM(NSInteger, VETitleValueType) {
    VETitleValueTypeText = 0,   ///< NSString (Return makes a line)
    VETitleValueTypeFont = 1,   ///< VETitleFont
    VETitleValueTypeNumber = 2, ///< double, within the parameter's range
    VETitleValueTypeColour = 3, ///< VEColour
    VETitleValueTypeChoice = 4, ///< VETitleAlignment
    VETitleValueTypeToggle = 5, ///< BOOL
    VETitleValueTypeAnchor = 6, ///< VETitleAnchor
};

/// What a title parameter's number is measured in.
typedef NS_ENUM(NSInteger, VETitleUnit) {
    VETitleUnitNone = 0,
    VETitleUnitFrameHeight = 1,   ///< a fraction of the frame's height (the inspector shows sequence pixels)
    VETitleUnitFrameWidth = 2,    ///< a fraction of the frame's width
    VETitleUnitMultiple = 3,      ///< a multiple of the font's line height
    VETitleUnitThousandthsEm = 4, ///< thousandths of an em
    VETitleUnitDegrees = 5,       ///< where the light comes from, counter-clockwise from the right
    VETitleUnitFraction = 6,      ///< 0 to 1 (an opacity)
};

/// How a title's lines align in its box.
typedef NS_ENUM(NSInteger, VETitleAlignment) {
    VETitleAlignmentLeft = 0,
    VETitleAlignmentCentre = 1,
    VETitleAlignmentRight = 2,
};

/// Where a title's y lies on its text block, and so which way the block grows as lines are added: its top (it grows
/// down), its centre (both ways) or its bottom (it grows up).
typedef NS_ENUM(NSInteger, VETitleAnchor) {
    VETitleAnchorTop = 0,
    VETitleAnchorCentre = 1,
    VETitleAnchorBottom = 2,
};

/// The weights of the system font (a title stores the system font by weight, never by a private name).
typedef NS_ENUM(NSInteger, VESystemFontWeight) {
    VESystemFontWeightUltraLight = 0,
    VESystemFontWeightThin = 1,
    VESystemFontWeightLight = 2,
    VESystemFontWeightRegular = 3,
    VESystemFontWeightMedium = 4,
    VESystemFontWeightSemibold = 5,
    VESystemFontWeightBold = 6,
    VESystemFontWeightHeavy = 7,
    VESystemFontWeightBlack = 8,
};

/// An sRGB colour, each component 0 to 1.
typedef struct {
    double red;
    double green;
    double blue;
} VEColour;

/// A row of the title parameter table (the engine's TitleParameterInfo): what the inspector shows for it.
@interface VETitleParameterInfo : NSObject
@property (nonatomic, readonly) VETitleParameter parameter;
/// The project file's key ("text", "fillColour", ...).
@property (nonatomic, readonly, copy) NSString *name;
/// "Text", "Fill Colour", ...
@property (nonatomic, readonly, copy) NSString *displayName;
@property (nonatomic, readonly) VETitleValueType type;
@property (nonatomic, readonly) VETitleUnit unit;
/// A number's default and range (a toggle's default is 0 or 1; unused for the other types).
@property (nonatomic, readonly) double defaultValue;
@property (nonatomic, readonly) double minimum;
@property (nonatomic, readonly) double maximum;
/// Every parameter, in VETitleParameter order.
@property (class, nonatomic, readonly, copy) NSArray<VETitleParameterInfo *> *allParameters NS_SWIFT_NONISOLATED;
/// The row of `parameter` (the first row for a value outside the enum).
+ (VETitleParameterInfo *)infoForParameter:(VETitleParameter)parameter NS_SWIFT_NONISOLATED NS_SWIFT_NAME(info(for:));
- (instancetype)init NS_UNAVAILABLE;
@end

/// A title's font: the system font at a weight, or a font installed on the Mac by its PostScript name (with the
/// family and style names it was chosen as). Immutable; equal when every field is.
@interface VETitleFont : NSObject <NSCopying>
+ (instancetype)systemFontWithWeight:(VESystemFontWeight)weight NS_SWIFT_NAME(system(weight:));
+ (instancetype)fontWithPostScriptName:(NSString *)postScriptName
                                family:(NSString *)family
                                 style:(NSString *)style NS_SWIFT_NAME(named(_:family:style:));
@property (nonatomic, readonly) BOOL isSystem;
/// The system font's weight (Regular for an installed font).
@property (nonatomic, readonly) VESystemFontWeight weight;
/// An installed font's names ("" for the system font).
@property (nonatomic, readonly, copy) NSString *postScriptName;
@property (nonatomic, readonly, copy) NSString *family;
@property (nonatomic, readonly, copy) NSString *style;
/// "System Semibold", "Helvetica Bold" (the PostScript name when the family and style are empty).
@property (nonatomic, readonly, copy) NSString *displayName;
/// Whether this Mac has the font (always for the system font); a missing font is drawn in the system font at the
/// weight its style names, and keeps its name.
@property (nonatomic, readonly, getter=isAvailable) BOOL available;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A title's content, as a snapshot (every parameter; see the units above).
@interface VETitleInfo : NSObject
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly) VETitleFont *font;
@property (nonatomic, readonly) double size;
@property (nonatomic, readonly) VEColour fillColour;
@property (nonatomic, readonly) VETitleAlignment alignment;
@property (nonatomic, readonly) double lineSpacing;
@property (nonatomic, readonly) double tracking;
@property (nonatomic, readonly) BOOL outline;
@property (nonatomic, readonly) VEColour outlineColour;
@property (nonatomic, readonly) double outlineWidth;
@property (nonatomic, readonly) BOOL shadow;
@property (nonatomic, readonly) VEColour shadowColour;
@property (nonatomic, readonly) double shadowOpacity;
@property (nonatomic, readonly) double shadowAngle;
@property (nonatomic, readonly) double shadowDistance;
@property (nonatomic, readonly) double shadowBlur;
@property (nonatomic, readonly) BOOL box;
@property (nonatomic, readonly) VEColour boxColour;
@property (nonatomic, readonly) double boxOpacity;
@property (nonatomic, readonly) double boxPadding;
@property (nonatomic, readonly) double boxCornerRadius;
/// The text block's centre, as fractions of the frame's width and height.
@property (nonatomic, readonly) double x;
@property (nonatomic, readonly) double y;
/// The text block's width (the lines wrap inside it), a fraction of the frame's width. Kept but unused for point
/// text.
@property (nonatomic, readonly) double width;
/// Point text: the lines break only at line breaks and the block is as wide as its widest line; x is then the block's
/// left edge, centre or right edge as the lines align. Area text (NO): the lines wrap at `width` and x is the block's
/// centre.
@property (nonatomic, readonly) BOOL pointText;
/// Where y lies on the block: its top, centre or bottom.
@property (nonatomic, readonly) VETitleAnchor anchor;
/// The first line of the text ("Title" when it has none): the clip's name on the timeline.
@property (nonatomic, readonly, copy) NSString *displayName;
/// A number parameter's value (NaN for a parameter that is not a number).
- (double)numberForParameter:(VETitleParameter)parameter NS_SWIFT_NAME(number(_:));
/// A colour parameter's value (black for a parameter that is not a colour).
- (VEColour)colourForParameter:(VETitleParameter)parameter NS_SWIFT_NAME(colour(_:));
/// A toggle's value (NO for a parameter that is not a toggle).
- (BOOL)toggleForParameter:(VETitleParameter)parameter NS_SWIFT_NAME(toggle(_:));
- (instancetype)init NS_UNAVAILABLE;
@end

/// What the titles and mattes of a selection have (the inspector's "Mixed").
@interface VETitleSelection : NSObject
/// The title clips and the colour matte clips of the selection, in the order given.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *titleClipIDs;
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *matteClipIDs;
/// The first title's content (nil without titles): its value of a parameter is every title's where they agree.
@property (nonatomic, readonly, nullable) VETitleInfo *firstTitle;
/// Whether the titles differ in `parameter` (NO with fewer than two titles or for a value outside the enum).
- (BOOL)isMixed:(VETitleParameter)parameter NS_SWIFT_NAME(isMixed(_:));
/// The first matte's colour (black without mattes), and whether the mattes differ in it.
@property (nonatomic, readonly) VEColour matteColour;
@property (nonatomic, readonly, getter=isMatteColourMixed) BOOL matteColourMixed;
- (instancetype)init NS_UNAVAILABLE;
@end

/// A caret on the frame: the segment from its top to its bottom, in sequence pixels (origin at the frame's top-left, +y
/// down), turned and scaled with the title.
typedef struct {
    CGPoint top;
    CGPoint bottom;
} VETitleCaret;

/// A rectangle of a title's canvas placed on the frame through the clip's Motion: its four corners, clockwise from the
/// rectangle's own top-left, in sequence pixels.
typedef struct {
    CGPoint topLeft;
    CGPoint topRight;
    CGPoint bottomRight;
    CGPoint bottomLeft;
} VETitleQuad;

/// A title's text laid out as it is drawn (the renderer's own lines), placed on the frame through the clip's composed
/// Motion at one time (VEEngine titleTextLayoutOfClip:atTime:): what the program monitor draws its caret and selection
/// with and maps clicks through, so they line up with the glyphs at any monitor size, Motion zoom and rotation.
/// Indices are UTF-16 offsets into `text` (NSString's), from 0 to `length`. "Canvas" coordinates are the title's
/// frame-sized canvas before Motion; "frame" coordinates are where that lands on the frame. Both in sequence pixels,
/// origin at the top-left, +y down. Immutable; made on the main thread.
@interface VETitleTextLayout : NSObject
/// The text it was laid out for.
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly) NSInteger length;
@property (nonatomic, readonly) NSInteger lineCount;
/// The title's font size in sequence pixels (the canvas's).
@property (nonatomic, readonly) double fontSize;
/// Canvas to frame: the clip's Motion at the time (scaled about the frame's centre, turned clockwise, moved).
@property (nonatomic, readonly) CGAffineTransform canvasToFrame;
/// The text block on the canvas, and on the frame.
@property (nonatomic, readonly) CGRect canvasBlock;
@property (nonatomic, readonly) VETitleQuad frameBlock;
/// The characters of line `line` (0 ..< lineCount; the empty last line after a final line break is {length, 0}).
- (NSRange)rangeOfLine:(NSInteger)line NS_SWIFT_NAME(range(ofLine:));
/// The line the caret at `index` is on (a caret at a line the box wrapped is at the start of the next line).
- (NSInteger)lineOfIndex:(NSInteger)index NS_SWIFT_NAME(line(ofIndex:));
/// The caret at `index` on the canvas (a zero-width rectangle from the line's top to its bottom) and on the frame.
- (CGRect)canvasCaretAtIndex:(NSInteger)index NS_SWIFT_NAME(canvasCaret(at:));
- (VETitleCaret)caretAtIndex:(NSInteger)index NS_SWIFT_NAME(caret(at:));
/// The caret index nearest a frame point (a click): through the inverse of the Motion, on the line whose band holds
/// it (else the nearest line), never past a line's break or inside a character. 0 when the clip is scaled to nothing.
- (NSInteger)indexAtFramePoint:(CGPoint)point NS_SWIFT_NAME(index(atFramePoint:));
/// The caret index on `line` nearest the canvas x `x` (moving up and down a line keeps the caret's x).
- (NSInteger)indexOnLine:(NSInteger)line nearCanvasX:(double)x NS_SWIFT_NAME(index(onLine:nearCanvasX:));
/// The canvas rectangles covering the characters in `range` (one or more per line: right-to-left runs select where
/// their glyphs are), as NSValue (rectValue); `frameQuadOfCanvasRect:` places one on the frame.
- (NSArray<NSValue *> *)canvasSelectionRectsForRange:(NSRange)range NS_SWIFT_NAME(canvasSelectionRects(for:));
- (VETitleQuad)frameQuadOfCanvasRect:(CGRect)rect NS_SWIFT_NAME(frameQuad(ofCanvasRect:));
- (instancetype)init NS_UNAVAILABLE;
@end

/// A font titles use that this Mac does not have (VEEngine.missingTitleFonts).
@interface VEMissingTitleFont : NSObject
@property (nonatomic, readonly) VETitleFont *font;
/// How many title clips use it.
@property (nonatomic, readonly) NSInteger clipCount;
- (instancetype)init NS_UNAVAILABLE;
@end

NS_ASSUME_NONNULL_END
