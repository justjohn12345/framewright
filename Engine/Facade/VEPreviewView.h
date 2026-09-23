#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

/// Program/source monitor surface: a CAMetalLayer-backed view that shows the compositor's
/// output for the current frame, letterboxed (black bars) to the sequence aspect ratio.
///
/// Rendering runs on a dedicated render thread owned by the view:
/// - While not paused, the view's display link (NSView.displayLink, follows the view's screen)
///   fires on the render thread every vsync; each tick asks the frame source for the current
///   frame and, if it changed, composites it into the next drawable and presents it. A tick
///   never blocks: when every frame slot is still on the GPU it is skipped (before asking the
///   source or taking a drawable) and the frame is drawn at the next vsync.
/// - While paused (the default) the display link is stopped and nothing renders until
///   -renderOnce is called (after a seek, an edit or a parameter change) or the view is resized.
///   A paused view does no GPU work. Pausing also releases unused texture-cache entries.
/// - While the window is fully occluded (minimised, hidden, covered) the display link is stopped
///   as well, and renderOnce is deferred; the current frame is redrawn when the window becomes
///   visible again (NSWindowDidChangeOcclusionStateNotification).
/// - A frame that could not be presented (no drawable from the window server, GPU busy) is not
///   lost: it is redrawn at the next vsync, or, while the loop is stopped, retried shortly after
///   (backing off, up to 8 times; then lastError says so).
///
/// Output: the drawable is 10-bit (MTLPixelFormatBGR10A2Unorm, tagged ITU-R BT.709) so 10-bit
/// sources, opacity and dissolves do not band; it costs the same 4 bytes per pixel as 8-bit
/// BGRA. -snapshot returns 8-bit.
///
/// The frame source is C++ and set by the engine (see Engine/Render/VEPreviewView+Internal.h):
/// VEEngine -attachProgramView: installs a still-frame source for the frame at the playhead;
/// the playback controller installs its own while playing. Without one the view shows black.
///
/// Threading: all methods must be called on the main thread except -snapshot, which may be
/// called from any thread other than the view's render thread. Swift sees the class as
/// @MainActor (NS_SWIFT_UI_ACTOR). Release the last reference on the main thread (it stops the
/// display link and the render thread).
NS_SWIFT_UI_ACTOR
@interface VEPreviewView : NSView

/// Uses the system default Metal device. If Metal setup fails the view stays black and
/// `lastError` says why.
- (instancetype)initWithFrame:(NSRect)frameRect;

/// Uses `device` (nil: system default). Returns nil and sets `error` if Metal setup fails.
- (nullable instancetype)initWithFrame:(NSRect)frameRect
                                device:(nullable id<MTLDevice>)device
                                 error:(NSError *_Nullable *_Nullable)error;

/// Unarchived views use the system default device (like -initWithFrame:).
- (nullable instancetype)initWithCoder:(NSCoder *)coder;

/// The device the view renders with (nil if setup failed).
@property (nonatomic, readonly, nullable) id<MTLDevice> device;

/// Stops (YES, the default) or runs (NO) the display-link driven render loop.
@property (nonatomic, getter=isPaused) BOOL paused;

/// Asks the frame source for the current frame once and renders it (re-renders the previous
/// frame if the source reports no change). Asynchronous; coalesces with pending requests.
- (void)renderOnce;

/// -renderOnce, then calls `completion` on the main queue when the GPU has finished the frame
/// (error nil) or rendering failed (error set).
- (void)renderOnceWithCompletion:(nullable void (^)(NSError *_Nullable error))completion;

/// Number of frames rendered and completed on the GPU since the view was created (for the
/// debug HUD and tests).
@property (atomic, readonly) NSUInteger renderCount;

/// Layers drawn without their picture (not decoded yet, or failed): `skippedLayerCount` sums
/// them over every completed frame; `missingLayerCount` is the number in the frame the view
/// shows (set when a render takes the frame, so it always matches what -snapshot composites).
/// A frame source that keeps the previous picture while a layer decodes (the program monitor
/// while paused) keeps it 0. For the debug HUD and tests.
@property (atomic, readonly) NSUInteger skippedLayerCount;
@property (atomic, readonly) NSUInteger missingLayerCount;

/// Pixel size of the drawable (bounds x backing scale).
@property (atomic, readonly) CGSize drawableSize;

/// The error behind what is on screen: Metal setup, an invalid frame, a GPU failure, or the
/// frame source's report of a picture it could not produce (decode or texture mapping). Nil
/// once a frame completes without one. Transient conditions (no drawable, GPU busy) are
/// retried instead and only reported here when retrying gives up.
@property (atomic, readonly, nullable) NSError *lastError;

/// Releases memory that is only a cache (pooled pre-scale textures, unused texture-cache
/// entries). Call on memory pressure; the next frames re-create what they need.
- (void)handleMemoryPressure;

/// The last rendered frame at drawable size (letterbox included), or NULL if nothing has been
/// rendered yet. Re-composites the current frame into an offscreen texture and blocks until
/// the GPU finished (a few milliseconds).
- (nullable CGImageRef)snapshot CF_RETURNS_NOT_RETAINED NS_SWIFT_NONISOLATED;

@end

NS_ASSUME_NONNULL_END
