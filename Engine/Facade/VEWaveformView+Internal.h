// C++ hooks of VEWaveformView for the program monitor and tests. Private to the facade
// implementation: excluded from the framework's headers (project.yml).

#pragma once

#import "VEWaveformView.h"

#include "../Render/Compositor.h"
#include "../Render/Histogram.h"
#include "../Render/LumaWaveform.h"
#include "../Render/ScopeStats.h"

#include <cstdint>
#include <vector>

NS_ASSUME_NONNULL_BEGIN

@interface VEWaveformView (Internal)

/// A reader of the program view's working frame (VEPreviewView+Internal.h) that draws this view's
/// scope from it: counts the frame's pixels in the mode's scope (LumaWaveform or Histogram, with the
/// frame's clipping counters) and draws them into this view's next drawable, presented with the frame's
/// command buffer; when the command buffer completes, the clipping counts are published to the main thread
/// (at most every 0.1 s, the latest counts). It does nothing once the view is gone, while the view has no
/// size, or when no drawable is free (the next frame draws it).
- (ve::render::WorkingFrameReader)workingFrameReader;

/// Called on the main thread when the view needs a frame to draw from (its size changed): the program
/// monitor renders its view once. Nil clears it.
- (void)setNeedsFrameHandler:(nullable dispatch_block_t)handler;

/// Draws into the textures `provider` returns instead of the layer's drawables (nil restores them);
/// called on the render thread.
- (void)setTargetProviderForTesting:(nullable id<MTLTexture> _Nullable (^)(void))provider;

/// The counts of the last waveform (levels rows of the columns it counted in; see
/// LumaWaveform::countsSnapshot), and its settings with `columns` the columns it counted in; empty before
/// the first.
- (std::vector<std::uint32_t>)countsForTesting;
- (ve::render::WaveformSettings)settingsForTesting;

/// The counts of the last histogram in `channel` (zeros before the first).
- (std::array<std::uint32_t, ve::render::Histogram::kBins>)histogramCountsForTesting:(ve::render::HistogramChannel)channel;

/// The clipping counts of the last completed frame (all zero before the first).
- (ve::render::ClipStats)clipStatsForTesting;

@end

NS_ASSUME_NONNULL_END
