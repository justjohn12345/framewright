// The C++ contract between VEPreviewView and whoever supplies its pictures (the playback
// controller in phase 4, wired by the facade in phase 5). Project-private (not in the
// framework's public headers).

#pragma once

#include "../Media/Result.h"
#include "RenderGraph.h"
#include "TextureCache.h"

#import <QuartzCore/QuartzCore.h>

#include <functional>
#include <vector>

namespace ve::render {

/// What the view asks for.
struct PreviewFrameRequest {
    /// Display-link tick: CADisplayLink.targetTimestamp (host time, seconds) of the vsync the
    /// frame will be presented at. renderOnce: CACurrentMediaTime() at the request.
    CFTimeInterval targetTimestamp = 0;
    /// True for renderOnce requests (playback stopped; the owner said the frame changed).
    bool isRenderOnce = false;
    /// The view's texture cache (same MTLDevice as its compositor), for mapping frame-cache
    /// CVPixelBuffers to textures.
    const TextureCache *textureCache = nullptr;
};

/// The frame to show: the graph and one TextureSet per layer (index-aligned with
/// graph.layers; an empty TextureSet means the picture is not decoded yet and the layer is
/// skipped, which the view counts in skippedLayerCount). The view keeps one PreviewFrame and
/// hands the same object to every call so its vectors keep their capacity: update it in place
/// (assign/resize), avoid rebuilding it.
struct PreviewFrame {
    RenderGraph graph;
    std::vector<TextureSet> textures;
    /// Why a picture of this frame is missing, when it is an error rather than "not decoded
    /// yet": a decode failure, or TextureCache::textures() failing. The view reports it as its
    /// lastError once the frame is on screen (and clears lastError with the next frame whose
    /// status is ok). Set it together with the frame (reset it when the problem is gone).
    media::Status status;
};

/// Called on the view's render thread (never the main thread), one call at a time.
/// Update `frame` and return true to render it; return false, leaving `frame` untouched, when
/// nothing changed since the previous call (a display-link tick then renders nothing; a
/// renderOnce re-renders the previous frame). Must not block (no locks held by the main thread
/// for long, no dispatch_sync to the main queue, no disk I/O or decoding).
using PreviewFrameSource = std::function<bool(const PreviewFrameRequest &request, PreviewFrame &frame)>;

} // namespace ve::render
