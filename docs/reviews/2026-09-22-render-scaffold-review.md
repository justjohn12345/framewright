# Render layer and scaffold review (2026-09-22)

Reviewer: Opus 5.5 read-only pass over Engine/Render (Compositor, TextureCache, Shaders, ColorMath, VEPreviewView), Facade preview, App, project.yml, Scripts at HEAD 6fc6ae4. Suspicions verified in a scratch extraction with private DerivedData. Baseline: 19 render tests pass, 0 warnings, 0.116 ms/frame wall.

## Ranked findings

1. HIGH: preview goes permanently black after collapse to zero size and restore (VEPreviewView.mm:359-368). `updateDrawableSize` early-returns when size == layer.drawableSize; when size < 1 px it stores 0 into `_state->drawableWidth/Height` but skips the layer; on restore to the old size the early return fires and state stays 0 → `renderPreviewFrame` bails ("nothing visible"), `snapshot` returns NULL. Verified: 320x180 → 320x0 → 320x180, renderCount stuck, snapshot 0x0. Triggers: split-view collapse, SwiftUI zero-height pass. Fix: always store the computed size before the early return, or compare against stored state.

2. HIGH: container rotation ignored; iPhone portrait renders sideways. Probers read rotationDegrees and MediaAsset stores rotated size, but no decoder applies rotation, VideoLayer/TextureSet have no orientation, `placeSource` (Compositor.mm:76-103, 277) fits the raw buffer. Fix: carry orientation (rotation + flip) into VideoLayer from the Scheduler, compose into the uvFromFrame inverse, fit using the rotated size. Test: 90°-tagged clip with a corner marker.

3. HIGH: FFmpeg cannot decode AV1 at all (build-ffmpeg.sh:79-104). FFmpeg 7.1 native av1 decoder is hwaccel-only; no VideoToolbox AV1 hwaccel in 7.1.5; CONFIG_LIBDAV1D 0. PLAN promised software AV1 fallback. Fix: build dav1d (BSD-2) into the script with --enable-libdav1d; add an AV1 conformance clip.

4. HIGH: no minification filtering → aliasing/moiré in preview and export (Shaders.metal:77-88 single bilinear tap; Compositor.mm:516-545). Verified: 1-px stripe 1920x1080 into 700 and 533 px targets gives row min/max 1/254 (ideal ~128). Fix: mipmapped copies, or MPSImageBilinearScale/Lanczos pre-scale (PLAN lists MPS), or footprint-sized multi-tap filter when fwidth(uv)*texSize > 1.

5. MEDIUM-HIGH: BGRA video frames are straight alpha but the contract treats all BGRA as premultiplied (TextureCache.h:6,13; Shaders.metal:85-88). Producers FFFrameConverter.mm:226-228 (sws_scale, never premultiplied) and AppleSupport.mm:318-319 (ProRes 4444 alpha). Only still decoders premultiply. Fix: premultiply in the converters or carry alphaIsPremultiplied in TextureSet and premultiply in sampleRGBA; test with a 50%-alpha straight source.

6. MEDIUM: uniform-ring slot index desyncs from the semaphore on error paths (Compositor.mm:486-497). nextSlot advanced before ensureCapacity / commandBuffer; on failure the semaphore is signalled but nextSlot not rolled back → next render writes an in-flight slot, replaces its completion (renderAndWait returns before the GPU wrote the export buffer), clears retained textures early. Fix: set im.nextSlot = slotIndex on both failure paths, or use a free-slot list.

7. MEDIUM: render thread can block on `nextDrawable` under renderMutex (VEPreviewView.mm:89-126) before the slot check; main-thread setFrameSource:/snapshot block behind it (up to 1 s with an occluded/minimised window). Fix: check slot availability first; acquire the drawable outside the lock; pause the link on NSWindowDidChangeOcclusionStateNotification.

8. MEDIUM: a fresh frame can be consumed and never shown (VEPreviewView.mm:100-114): source returned fresh and updated st.frame, then nextDrawable nil or render fails, nothing sets forceRedraw; paused view never retries → stale picture after a seek. Fix: set forceRedraw (running) or re-queue renderOnce (paused); treat "no drawable" as transient, not a sticky lastError.

9. MEDIUM: missing pictures silently black, errors swallowed (VEPreviewView.mm:127-139; VEProgramFrameProvider.mm:43-47, 107-110). skippedLayers never inspected outside tests; provider drops TextureCache errors; scrub failures treated as empty layer; lastError never cleared. Latent: DecodePool cancels a scrub when a newer request for the same asset arrives from any client → once the source monitor shares the pool, scrubbing it cancels the program monitor's request and that layer stays black. Fix: re-request on Cancelled while generation is current; surface skipped layers and mapping errors; clear lastError on success.

10. MEDIUM: distribution scaffold. ENABLE_HARDENED_RUNTIME NO with no stated reason (needed for notarisation; CodeSignOnCopy already re-signs dylibs so library validation would pass). LGPL claim in README.md:71-73 unbacked: no LGPL licence text/notice in the bundle, no source offer. No -Werror / -Wall -Wextra / SWIFT_TREAT_WARNINGS_AS_ERRORS (build is warning-clean today, so cheap to enable).

11. LOW-MEDIUM: chroma siting ignored both directions (Shaders.metal:77-80 same uv for luma/chroma = centre siting; 137-162 2x2 box = centre). H.264/HEVC default is left-sited → half-luma-pixel chroma shift in preview. Output not tagged with kCVImageBufferChromaLocationTopFieldKey. Fix: offset chroma uv from the buffer's chroma-location attachment; tag export buffers Center.

12. LOW: TextureCache.mm:149-156 flush only inside textures() (flush on pause and memory pressure). 8-bit BGRA8Unorm drawable bands 10-bit sources (consider bgr10a2Unorm). Compositor.mm:445-449, 519-522: caller viewport not clamped before setScissorRect; nil render encoder unchecked. Each VEPreviewView builds its own Compositor (12 pipelines) on main. Shaders.metal:16-37 passthrough shaders are dead phase-0 code kept by one test.

13. LOW: scaffold housekeeping. build-ffmpeg.sh stamp keyed only on version (flag changes don't rebuild); `rm -rf "$PREFIX"` before build destroys a good install on failure; SHA-256 is trust-on-first-use (FFmpeg publishes GPG .asc); --disable-autodetect side effects undocumented. .gitignore lacks .claude/ (now partially tracked on purpose: agents/), .swiftpm/, .build/. README omits make_test_media.swift.

14. LOW: app code at HEAD. ContentView never passes attach (superseded by phase 5a). PreviewViewRepresentable.swift:7-8 stale comment; `configure` runs only in makeNSView so a changed attach closure is never reapplied. Otherwise clean.

## Done properly (do not redo)
YCbCr→RGB matrices re-derived and correct (video/full range, 10-bit high-bits factor 65535/64, Kr/Kb for 601/709/2020/240M); RGB→YCbCr export is the exact inverse; test reference is an independent formula at 1-LSB tolerance. Premultiplied blending throughout; one-pass dissolve exact over transparency. Inverse affine, clockwise y-down, AA edge coverage, clamp_to_edge, pixel-exact letterbox. Deliberate BGRA8Unorm (not _sRGB) with layer tagged ITU-R 709; RGBA16Float export intermediate; export tags colour and rejects unsupported targets. Texture sets held until command buffer completes; display-link path never blocks on a slot; destructor drains semaphore safely. Autorelease pools cover the tick; display link targets a proxy; setFrameSource serialised by mutex, link path try-locks; pause stops the link (no polling); view deallocates and render thread exits (verified). Scaffold: zero warnings, FFmpeg via system header path, dylibs flattened/@rpath/arm64/no GPL verified before stamp, app embeds each dylib once with CodeSignOnCopy, codesign --verify --deep --strict passes, default.metallib in framework Resources.

## Test gaps
- Matrix tests use uniform fills so chroma misplacement/siting/scaling can't be detected; untested: SMPTE 240M, untagged 709/601 height fallback, 422v, 444v, x444 full, xf20.
- Export: no 420f target, no odd-size 420, no direct chroma-averaging check.
- Perf assertion has 35x headroom and skips the preview path; logged GPU ms sums overlapping intervals (misleading).
- Memory test: 8 MB/600 frames catches only big leaks; export path only. Use more frames, XCTMemoryMetric or leaks, live-object counters.
- Display-dependent tests: testDisplayLinkRendersWhileRunning fails (not skips) when locked/occluded; testPausedViewDoesNotRender passes vacuously when the link can't fire.
- Missing: resize/collapse/restore; teardown; setFrameSource while running; renderOnce coalescing; Busy path; lastError after GPU/pipeline failure; nextDrawable failure; straight-alpha, rotated, minified sources; ring-slot error path.
- Facade/VEEngineTests.mm:758 testProgramViewShowsTheFrameAtTheRequestedTime uses a still (time never checked), depends on a 0.3 s sleep, asserts only "not black".
- AppTests: sandbox test is vacuous in Debug (test host has injected read-only-/ entitlement).
