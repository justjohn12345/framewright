#import <AppKit/AppKit.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// A luma waveform of the program monitor's picture: across, the frame's width; up, luma from 0 IRE
/// (black, the bottom edge) to 100 IRE (white, the top edge), each pixel's luma the BT.709 weighting of
/// the R'G'B' the monitor shows (graded, letterbox bars left out). The trace is green, brighter where
/// more pixels share a level; a graticule marks every 10 IRE (brighter at 0, 50 and 100).
///
/// Attach it with -[VEEngine attachWaveformView:]. It is drawn by the program monitor's render thread
/// with every frame the program monitor shows, playing or paused, from the frame as composited (the
/// working texture, before the monitor's output pass), into this view's own drawable in the same command
/// buffer; while it is not attached it does nothing. Detach it (attachWaveformView:nil) when it is
/// hidden, so it costs nothing.
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

/// Waveforms drawn and completed on the GPU since the view was created (tests, the debug HUD).
@property (atomic, readonly) NSUInteger drawCount;

/// Why Metal setup failed, or nil.
@property (nonatomic, readonly, nullable) NSError *lastError;

@end

NS_ASSUME_NONNULL_END
