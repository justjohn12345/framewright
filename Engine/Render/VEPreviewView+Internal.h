// C++ hooks of VEPreviewView for the engine (playback controller, facade) and tests. Kept out
// of the public header so Swift sees a plain Objective-C NSView.

#pragma once

#import "../Facade/VEPreviewView.h"

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

@end

NS_ASSUME_NONNULL_END
