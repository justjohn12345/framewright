#import <AppKit/AppKit.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// What a scope view (VEWaveformView) shows.
typedef NS_ENUM(NSInteger, VEScopeMode) {
    /// Luma per column of the picture: across, the frame's width; up, 0 to 100 IRE.
    VEScopeModeWaveform = 0,
    /// How many pixels have each level, from black (left) to white (right), in a VEHistogramStyle.
    VEScopeModeHistogram = 1,
    /// Each pixel's chroma (Cb across, blue to the right; Cr up, red up) in a square, over a graticule with the
    /// 75 % colour bars' targets and the skin tone line.
    VEScopeModeVectorscope = 2,
};

/// How the histogram is drawn (VEScopeModeHistogram).
typedef NS_ENUM(NSInteger, VEHistogramStyle) {
    /// R, G and B overlaid (where they overlap their mixtures show, all three as grey), with the luma bars'
    /// tops as a white line: as Lightroom shows it.
    VEHistogramStyleRGBAndLuma = 0,
    /// The luma bars only, in grey.
    VEHistogramStyleLuma = 1,
    /// R, G and B side by side (a parade), on one scale.
    VEHistogramStyleParade = 2,
};

/// The program monitor's scope: a luma waveform, a histogram or a vectorscope of the picture the program monitor
/// shows
/// (graded, as composited, letterbox bars left out), and the share of its pixels that are clipped. (The
/// class kept its slice 1 name; `mode` chooses the scope.)
///
/// Waveform: across, the frame's width (with as many columns as the view has pixel columns, up to 2048, so
/// a view of the picture's aspect maps its columns to the picture's); up, luma from 0 IRE (black, the bottom
/// edge) to 100 IRE (white, the top edge), each pixel's luma the BT.709 weighting of the R'G'B' the monitor
/// shows. The trace is green, brighter where more pixels share a level; a graticule marks every 10 IRE
/// (brighter at 0, 50 and 100). Histogram: every pixel's R, G, B and luma, black at the left, white at the
/// right, in `histogramStyle`, scaled so the tallest bar between the end levels fills the height (a spike of
/// clipped black or white reaches the top without flattening the rest), with lines at 25, 50 and 75 %.
/// Vectorscope: each pixel's BT.709 chroma of up to 540 evenly spaced rows, in a square centred in the view
/// (chroma -0.5 to 0.5 on each axis), with the ring at chroma 0.5, boxes at the 75 % colour bars' chroma and the
/// skin tone line (123 degrees from the Cb axis).
///
/// Clipping: a pixel counts as clipped white when one of its channels is at or above 100 % and as clipped
/// black when one is at or below 0 % (within a quarter of a 10-bit code): a channel there has lost its
/// detail, as a photo app's clipping warning shows (a saturated colour can be both). Counted on the pixels
/// the scope reads (the waveform samples up to 360 evenly spaced rows of every column, the vectorscope up to 540,
/// the histogram every pixel), so it costs no extra read of the frame.
///
/// Attach it with -[VEEngine attachWaveformView:]. It is drawn by the program monitor's render thread with
/// every frame the program monitor shows, playing or paused, from the frame as composited (the working
/// texture, before the monitor's output pass), into this view's own drawable in the same command buffer;
/// while it is not attached it does nothing. Detach it (attachWaveformView:nil) when it is hidden, so it
/// costs nothing.
///
/// Threading: main thread only (Swift sees it as @MainActor); release the last reference on the main
/// thread.
NS_SWIFT_UI_ACTOR
@interface VEWaveformView : NSView

/// Uses the system default Metal device. If Metal setup fails the view stays black and `lastError`
/// says why.
- (instancetype)initWithFrame:(NSRect)frameRect;
- (nullable instancetype)initWithCoder:(NSCoder *)coder;

/// The device the view draws with (nil if setup failed).
@property (nonatomic, readonly, nullable) id<MTLDevice> device;

/// Scopes drawn and completed on the GPU since the view was created (tests, the debug HUD).
@property (atomic, readonly) NSUInteger drawCount;

/// Why Metal setup failed, or nil.
@property (nonatomic, readonly, nullable) NSError *lastError;

/// The scope shown (VEScopeModeWaveform by default). Changing it asks the program monitor for a frame, so
/// a paused picture's new scope shows at once.
@property (nonatomic) VEScopeMode mode;

/// How the histogram is drawn (VEHistogramStyleRGBAndLuma by default); also asks for a frame.
@property (nonatomic) VEHistogramStyle histogramStyle;

/// The share (0 to 1) of the last drawn frame's counted pixels with a channel at or above white, and at or
/// below black; 0 before the first frame. Updated on the main thread at most ten times a second, always
/// with the latest frame's counts (playback does not queue updates).
@property (nonatomic, readonly) double clippedHighlightFraction;
@property (nonatomic, readonly) double clippedShadowFraction;

/// Called on the main thread after `clippedHighlightFraction` or `clippedShadowFraction` changed.
@property (nonatomic, copy, nullable) void (^clippingHandler)(double highlights, double shadows);

@end

NS_ASSUME_NONNULL_END
