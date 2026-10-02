// C++ hooks of VEPreviewView for the engine (playback controller, facade) and tests. Kept out
// of the public header so Swift sees a plain Objective-C NSView.

#pragma once

#import "../Facade/VEPreviewView.h"

#include "Compositor.h"
#include "PreviewFrame.h"

NS_ASSUME_NONNULL_BEGIN

@interface VEPreviewView (Internal)

/// Installs (or clears, with an empty function) the frame source. The source is invoked on the
/// render thread (see PreviewFrameSource for the contract); this call waits until any render in
/// progress has finished, so the previous source is no longer running when it returns. The
/// current frame is kept; call -renderOnce to show the new source's frame.
- (void)setFrameSource:(ve::render::PreviewFrameSource)source;

/// The view's texture cache (same device as its compositor). Nil-safe: nullptr if Metal setup
/// failed.
- (const ve::render::TextureCache *_Nullable)textureCache;

/// Installs (or clears, with an empty function) a reader of every frame the view presents, as
/// composited in the RGBA16Float working texture before the output pass writes the drawable: the
/// place a scope will read the picture (grading decision, section 4). Called on the render thread
/// while the frame is encoded; see ve::render::WorkingFrameReader for what it may do. Snapshots do not
/// call it.
- (void)setWorkingFrameReader:(ve::render::WorkingFrameReader)reader;

/// Whether the output pass tints clipped pixels (TextureTarget::clippingOverlay) from the next frame on:
/// the program monitor's clipping overlay. Any thread; call -renderOnce to show it on a paused picture.
/// Snapshots never show it.
@property (atomic) BOOL clippingOverlay;

// MARK: Diagnostics and tests

/// Render requests and ticks that found every frame slot on the GPU (the frame was deferred).
@property (atomic, readonly) NSUInteger busyCount;
/// Times the layer gave no drawable (the frame was deferred).
@property (atomic, readonly) NSUInteger drawableFailureCount;
/// Whether the display link is running: not paused, window not occluded, Metal set up.
@property (atomic, readonly, getter=isRenderLoopRunning) BOOL renderLoopRunning;

/// Applies a window visibility change (what the occlusion notification does): an invisible
/// window stops the display link; becoming visible restarts it (if not paused) and redraws a
/// frame that could not be presented meanwhile.
- (void)applyWindowVisible:(BOOL)visible;

/// Replaces -[CAMetalLayer nextDrawable] (nil restores it), e.g. to simulate a window server
/// that has no drawable. Called on the render thread.
- (void)setDrawableProviderForTesting:(nullable id<CAMetalDrawable> _Nullable (^)(CAMetalLayer *layer))provider;

/// The compositor (for fault injection and slot holding in tests); nullptr if setup failed.
- (ve::render::Compositor *_Nullable)compositorForTesting;

/// The render thread (to check it exits after the view is released).
- (NSThread *)renderThreadForTesting;

@end

NS_ASSUME_NONNULL_END
