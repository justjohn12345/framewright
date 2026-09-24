# Framewright: a simple Premiere-style video editor for macOS

## Context

Goal: a native macOS non-linear video editor with the core of Premiere's workflow: import media, arrange clips on a multi-track timeline, trim/split/move, preview with synced audio, apply a few basic effects and transitions, and export to H.264/HEVC. The repo is empty (the repo directory), machine has Xcode 26.6 on macOS 26.6 (Apple silicon), no CMake/Ninja.

Language split:
- **Objective-C++ (.mm)** for the engine. One language holds `std::` containers, `CMTime`, `CVPixelBufferRef`, `id<MTLTexture>` and FFmpeg's C API in the same file, so no bridging layer is needed between "the model" and "the platform". Hot loops (mixing, scheduling, cache) are plain C++ inside those files, so nothing is lost on performance. Model and edit code that has no Apple dependency is still written as plain C++ classes so it stays trivially unit-testable.
- **Swift + SwiftUI** (AppKit where SwiftUI is weak) for all UI, talking to the engine through `@objc` classes exported from the engine framework.
- **Open source** where it saves work: FFmpeg (LGPL build) as the second media backend, nlohmann/json for the project file, and a few others listed below.

## Hardware acceleration inventory

Every stage has a hardware path; the software path exists only as a fallback.

| Stage | Hardware path | Fallback |
|---|---|---|
| Demux | AVAssetReader (Apple containers) | libavformat (MKV, WebM, AVI, TS, FLV, anything else) |
| Video decode | VideoToolbox via `VTDecompressionSession`: H.264, HEVC, ProRes (media engine), AV1 (M3+), VP9 (M1+) after `VTRegisterSupplementalVideoDecoderIfAvailable` | libavcodec software decode, delivered as `CVPixelBuffer` through FFmpeg's `videotoolbox` hwaccel when the codec is VT-capable, else CPU frames uploaded to a pool |
| Pixel format / scale | Frames stay in decoder-native biplanar YUV (`420v`/`420f`, `P010`) and are converted to RGB in the Metal shader. `VTPixelTransferSession` for the rare forced conversion | vImage |
| Compositing, transitions, transforms | Metal compute/render pipelines; Metal Performance Shaders for scale/blur | none needed |
| Zero-copy | IOSurface-backed `CVPixelBuffer` → `CVMetalTextureCache` → `MTLTexture` with no readback | |
| Audio decode | AudioToolbox (AAC, ALAC, MP3) via AVAssetReader | libavcodec (Opus, Vorbis, FLAC in MKV etc.) |
| Audio mix / resample | Accelerate vDSP for sums and gain ramps, `AVAudioConverter` for sample-rate conversion | |
| Video encode | VideoToolbox via `VTCompressionSession` through `AVAssetWriter`: H.264, HEVC, ProRes | libavcodec software (SVT-AV1 or libaom for AV1, both BSD; no x264/x265 to stay LGPL) |
| Audio encode | AudioToolbox AAC via `AVAssetWriter` | libavcodec |
| Thumbnails / waveform peaks | VT decode at reduced resolution + vDSP peak finding | |

Detection at launch: probe `VTIsHardwareDecodeSupported(codec)` and `VTCopySupportedPropertyDictionaryForEncoder` per codec, cache the result, show it in a Preferences pane. Route AV1/VP9 through VT only when the hardware flag is true, otherwise FFmpeg software.

## Media backend abstraction

The engine never talks to AVFoundation or FFmpeg directly. It talks to these interfaces (C++ abstract classes in Obj-C++ headers, `CMTime` is the time type throughout):

```
IMediaProber     probe(url) -> MediaInfo {tracks[{kind, codec, size, fps, isVFR, sampleRate, channels, duration, colorPrimaries}], container, backendHint}
IVideoDecoder    open(url, trackIndex, DecodeOptions) ; seek(CMTime) ; next() -> VideoFrame {pts, duration, CVPixelBufferRef} ; supportsRandomAccess()
IAudioDecoder    open(...) ; seek(CMTime) ; read(frames, float* interleaved) -> count
IVideoEncoder    open(settings) ; encode(CVPixelBufferRef, pts) ; finish()
IAudioEncoder    open(settings) ; encode(pcm) ; finish()
IMuxer           addTrack(...) ; write(packet) ; finish()
```

Two implementations of each:
- **AppleBackend** (`Engine/Media/Apple/`): `AVAssetReader`/`AVSampleBufferGenerator` + `VTDecompressionSession` for decode, `AVAssetWriter` (which drives `VTCompressionSession`) for encode and mux.
- **FFmpegBackend** (`Engine/Media/FFmpeg/`): `libavformat` demux, `libavcodec` decode with `AV_HWDEVICE_TYPE_VIDEOTOOLBOX` hwaccel (frames arrive as `AV_PIX_FMT_VIDEOTOOLBOX`, `data[3]` is the `CVPixelBufferRef`, so the rest of the pipeline is identical), software decode otherwise; `libavcodec` + `libavformat` for encode and mux of non-Apple outputs.

`BackendRouter` decides per asset and per track:
1. Ask both probers. If AVFoundation reports the track as playable and the codec is in the VT-supported set, choose Apple. This is the fast path for .mov/.mp4/.m4a/.wav.
2. Otherwise choose FFmpeg. If FFmpeg reports the codec is VT-capable (H.264/HEVC in an MKV, for example), it uses the hwaccel path and still costs zero copies.
3. A per-asset override in the Inspector and a global preference ("Prefer FFmpeg for decode") for debugging.
4. The decision, the codec, and whether hardware was used are shown in the asset's info panel and the debug HUD.

Both backends must pass the same conformance test suite (`MediaBackendTests`) on the same synthesized files, which is what makes the router safe.

## Assumptions (change any of these and the plan adjusts)

| Decision | Choice |
|---|---|
| Min macOS | 14 (Sonoma), Apple silicon primary. x86_64 builds allowed but FFmpeg is built arm64-only until needed. |
| Build system | XcodeGen (`project.yml` checked in, `.xcodeproj` generated, gitignored). Builds and tests from CLI via `xcodebuild`. Requires `brew install xcodegen`. |
| Time type | `CMTime` everywhere in the engine; Swift sees `CMTime` too (it bridges natively). No custom rational type. |
| Working pixel format | Decoder-native biplanar YUV in IOSurface-backed `CVPixelBuffer`s. RGB only exists inside the Metal pipeline and at export in the encoder's preferred format. |
| Color | BT.709 SDR. Primaries/transfer are carried through as metadata and tagged on export. HDR tone mapping out of scope. |
| Sequence settings | Fixed fps and size per sequence (default 1080p30, matched to first clip added). Sources are conformed (nearest frame, letterbox). |
| Project file | JSON, single `.framewright` file, media referenced by path + security-scoped bookmark. |
| FFmpeg licensing | LGPL 2.1+ build only: `--disable-gpl --disable-nonfree`, `--enable-videotoolbox --enable-audiotoolbox`. Dynamic libs bundled in the app for LGPL compliance. |

## Open source dependencies

| Library | Purpose | License | How it is brought in |
|---|---|---|---|
| FFmpeg 7.x (libavformat, libavcodec, libavutil, libswresample, libswscale) | second media backend | LGPL | `Scripts/build-ffmpeg.sh` builds an arm64 dylib set into `ThirdParty/ffmpeg/` from a pinned tag; Homebrew `ffmpeg` is acceptable for local dev only |
| SVT-AV1 (optional, phase 7) | AV1 software encode | BSD-3 | built into the FFmpeg script when enabled |
| nlohmann/json | project file | MIT | vendored single header |
| doctest | C++ unit tests | MIT | vendored single header (XCTest also usable from Obj-C++; doctest keeps pure-model tests framework-free) |
| SwiftFormat, clang-format | formatting | MIT / Apache | dev tools only |
| KeyboardShortcuts (sindresorhus) | user-customizable shortcuts | MIT | SPM, phase 8 |
| Sparkle (optional, later) | app updates | MIT | SPM, out of MVP |

Not used: OpenTimelineIO (heavier than needed, but the JSON schema is kept close to its clip/track model so an exporter is easy later), MLT/GStreamer (would replace the engine, defeats the purpose).

## MVP feature list

1. Import media (drag/drop, Open dialog) into a Project bin with thumbnails, metadata, and backend/codec/hardware badge.
2. Source monitor: scrub and set in/out on a bin clip.
3. Timeline: N video tracks and N audio tracks, linked A/V clips. Move, trim (edge drag), split at playhead (Cmd+K), delete, ripple delete, snapping to clip edges and playhead, multi-select, zoom/scroll.
4. Program monitor: real-time playback with audio, JKL shuttle, arrow-key frame step, space to play/pause, scrubbing by dragging playhead.
5. Inspector: per-clip position/scale/rotation/opacity, audio gain, constant clip speed.
6. Transitions: cross dissolve (video), constant-power crossfade (audio). Audio fade in/out handles on clips.
7. Undo/redo for every edit.
8. Save/open project, autosave, recent projects.
9. Export dialog with codec/resolution/bitrate presets, hardware/software indicator, progress, cancel.

Explicitly deferred: titles/text, keyframed effects, color correction, nested sequences, multicam, proxies, HDR, plugin effects, audio effects beyond gain.

## Repo layout

```
framewright/
  project.yml                      # XcodeGen
  Scripts/  build-ffmpeg.sh  make_test_media.swift  format.sh
  ThirdParty/  ffmpeg/ (built output, gitignored)  json.hpp  doctest.h
  Engine/                          # framework "FramewrightEngine", Objective-C++
    Model/     Project, Sequence, Track, Clip, MediaAsset, Transition, EffectParams   (plain C++ classes, CMTime)
    Edit/      Command, UndoStack, EditOps (trim/move/split/ripple/link as reversible commands)
    Serialize/ ProjectJSON (nlohmann)
    Media/     Interfaces.h (IMediaProber, IVideoDecoder, IAudioDecoder, IVideoEncoder, IAudioEncoder, IMuxer)
               BackendRouter.mm, HardwareCaps.mm (VT capability probe)
               FrameCache.mm (LRU of CVPixelBuffer by asset+frame, byte-bounded), DecodePool.mm (lookahead workers)
               Apple/   AppleProber.mm  AppleVideoDecoder.mm  AppleAudioDecoder.mm  AppleWriter.mm (AVAssetWriter encoder+muxer)
               FFmpeg/  FFProber.mm  FFVideoDecoder.mm (videotoolbox hwaccel + sw)  FFAudioDecoder.mm  FFWriter.mm
    Render/    RenderGraph.h (per-frame layer list), Scheduler.mm (Sequence + time → RenderGraph)
               Compositor.mm (Metal), Shaders.metal (YUV→RGB, transform, dissolve, letterbox), TextureCache.mm
               PreviewView.mm (NSView + CAMetalLayer + display link)
    Audio/     AudioMixer.mm (lock-free, vDSP), AudioOutput.mm (AVAudioEngine + AVAudioSourceNode), Clock.h
    Playback/  PlaybackController.mm (play/pause/seek/rate, preroll, drop policy, scrub coalescing)
    Export/    ExportJob.mm (offline render loop driving IVideoEncoder/IAudioEncoder/IMuxer)
    Facade/    VEEngine.h/.mm (@objc API for Swift), VETypes.h (@objc snapshots: VEAssetInfo, VEClipInfo, VETrackInfo)
    Thumbs/    ThumbnailService.mm, WaveformService.mm
  EngineTests/                     # XCTest target in Obj-C++: model/edit tests (doctest wrapped), MediaBackendTests (both backends), compositor pixel tests, export round trip
  App/                             # Swift app target "Framewright"
    FramewrightApp.swift, AppDelegate.swift
    State/   ProjectStore.swift (ObservableObject over VEEngine), Selection.swift, TimelineViewModel.swift
    Views/   MediaBin/, SourceMonitor/, ProgramMonitor/, Timeline/, Inspector/, Export/, Transport/, Preferences/
    Bridging/ PreviewViewRepresentable.swift
    Resources/ Assets.xcassets, Info.plist, Framewright.entitlements
  AppTests/                        # Swift view-model tests
  .clang-format, .swiftformat, .gitignore
```

## Architecture

### Threads
- **Main**: SwiftUI, all model mutations. Engine calls are synchronous and cheap; the model is guarded by one mutex and the UI is the only writer.
- **Audio render thread** (realtime, owned by AVAudioEngine): `AudioMixer::render()` pulls PCM from per-clip ring buffers with vDSP. No locks, no allocation, no Obj-C messaging. Its sample count is the **master clock** during playback.
- **Video render thread**: driven by `NSView.displayLink`; asks `Scheduler` for the `RenderGraph` at the clock's current time, pulls `CVPixelBuffer`s from `FrameCache`, maps them through `CVMetalTextureCache`, runs `Compositor`, presents.
- **Decode pool**: one worker per active clip decoding ahead of the playhead (~1 s video, ~2 s audio) into `FrameCache` / audio ring buffers. Workers are cancelled and re-seeked on scrub or edit. Each worker owns one `IVideoDecoder`, whichever backend the router chose.

### Data flow (playback)
```
Sequence --Scheduler--> RenderGraph{time, layers[{assetId, sourceTime, transform, opacity, transition}]}
   layer → FrameCache.get(assetId, sourceTime) → CVPixelBuffer (native YUV, IOSurface)
   → CVMetalTextureCache (Y + CbCr planes as two textures) → Compositor (Metal) → CAMetalLayer drawable
AudioMixer ← ring buffers ← IAudioDecoder workers; AVAudioSourceNode pulls from mixer
```

### Data flow (export)
Same `Scheduler` + `Compositor`, rendering into a `CVPixelBufferPool` in the encoder's requested format, handed to `IVideoEncoder` (Apple: `AVAssetWriterInputPixelBufferAdaptor`, which keeps the buffer on the GPU side for VideoToolbox; FFmpeg: `av_frame` wrapping the pixel buffer for `h264_videotoolbox`/`hevc_videotoolbox`, or a CPU copy for software encoders). Audio mixed offline. Runs on its own queue with a cancel token and progress callbacks.

### Seeking strategy
- Playback: one sequential decoder per active clip, positioned near the playhead.
- Scrub: decode from the nearest keyframe on a scrub queue with coalescing (only the latest request survives); show the last frame until the new one lands. Apple backend uses `AVSampleBufferGenerator` + `VTDecompressionSession` for true random access; FFmpeg backend uses `av_seek_frame` to the keyframe then decodes forward.
- `FrameCache` is LRU keyed by (assetId, frame index), bounded by bytes (default 512 MB, IOSurface memory), purged on memory pressure.

### Model and undo
- All edits are `Command` subclasses with `apply()`/`revert()` (`MoveClip`, `TrimClip`, `SplitClip`, `InsertClip`, `RemoveClip`, `RippleDelete`, `SetEffectParam`, `AddTransition`). `UndoStack` coalesces continuous drags into one command.
- Model objects are plain structs with stable integer IDs. Swift receives `VEClipInfo` snapshots, never pointers into the model.
- `modelVersion` increments per command; `ProjectStore` republishes derived timeline state when it changes.

### Swift ↔ engine facade (keep it small)
`VEEngine`: `openProject/save`, `importMedia(urls) -> [VEAssetInfo]`, sequence snapshot, edit ops (`moveClip`, `trimClip`, `splitClipAt`, `deleteClips`, `setClipParam`), `undo/redo`, `play/pause/seek/setRate`, `currentTime` + `VEEngineObserver` for time/state callbacks (delivered on main), `beginExport(settings, progress, completion)`, `thumbnail(asset, time)`, `waveformPeaks(asset)`, `hardwareCapabilities()`.

## Phases

Each phase ends with something runnable and its tests green. Playback and A/V sync, the riskiest part, land in phase 4 before UI polish.

### Phase 0: Scaffold
- `brew install xcodegen`; `project.yml` with targets `FramewrightEngine` (framework, Obj-C++17/C++20), `EngineTests` (XCTest, Obj-C++), `Framewright` (macOS app, Swift/SwiftUI), `AppTests` (XCTest, Swift).
- Vendor `json.hpp` and `doctest.h`. Write `Scripts/build-ffmpeg.sh` (pinned FFmpeg tag, LGPL flags, `--enable-videotoolbox --enable-audiotoolbox`, arm64, install to `ThirdParty/ffmpeg/`); the engine links it and a copy-files phase bundles the dylibs into the app.
- Entitlements: app sandbox on, user-selected read/write, bookmarks. `.clang-format`, `.swiftformat`, `.gitignore`, `git init`.
- Verify: `xcodebuild -scheme Framewright build` and `xcodebuild -scheme EngineTests test` succeed; empty window launches.

### Phase 1: Core model (plain C++ inside the engine)
- Model structs with `CMTime`; `EditOps` as `Command`s; `UndoStack`; `ProjectJSON` round trip with schema version.
- `Scheduler::renderGraphAt(time)`: active clips per track top-down, source time with clip speed, transition layers.
- Tests: every edit op has an apply/revert round-trip test; graph resolution tests for overlaps, transitions, gaps.

### Phase 2: Media backends and router
- `HardwareCaps`: VT decode/encode capability probe per codec, registers AV1/VP9 supplemental decoders.
- Apple backend: prober, video decoder (native YUV, IOSurface pool), audio decoder (float32 interleaved at 48 kHz), AVAssetWriter-based encoder+muxer.
- FFmpeg backend: prober, video decoder with `videotoolbox` hwaccel and software fallback wrapping CPU frames into pooled `CVPixelBuffer`s, audio decoder via `libswresample`, writer.
- `BackendRouter` with the rules above; `FrameCache`, `DecodePool`, thumbnail and waveform services.
- `Scripts/make_test_media.swift`: clips with per-frame burn-in codes, sine audio with a per-file frequency, a mid-clip beep; also remuxed into MKV (via the freshly built ffmpeg) so both backends get exercised.
- Tests: `MediaBackendTests` runs the same conformance suite against both backends: frame N decode accuracy, seek accuracy within one frame, audio sample alignment, hardware flag reported correctly.

### Phase 3: Metal compositor and preview
- `Compositor`: `RenderGraph` + texture lookup → output texture. Shaders: YUV→RGB (BT.709, full/video range from buffer attachments), affine transform, opacity, letterbox, dissolve mix.
- `PreviewView`: `NSView` with `CAMetalLayer`, display link, Retina and resize handling; Swift `NSViewRepresentable` wrapper; program monitor shows the frame at the playhead.
- Tests: composite two synthesized clips at 50 % opacity into a `CVPixelBuffer` and check pixel values.

### Phase 4: Playback engine
- `AudioMixer` (lock-free, vDSP gain ramps and sums) reporting rendered samples to `Clock`; `AudioOutput` via `AVAudioEngine` + `AVAudioSourceNode`, device-change handling.
- `PlaybackController`: play/pause/seek/rate (JKL ±1/±2/±4, audio muted above 2×, reverse plays video only), pre-roll before starting audio, drop-frame policy (present the frame nearest the clock, never block the render thread), scrub coalescing.
- Verify: sync test clip with a debug HUD (presented frame index vs audio clock, backend, hw flag, cache bytes, queue depth); drift under one frame over 60 s for both backends; Instruments Metal System Trace and Time Profiler show no main-thread stalls over 16 ms.

### Phase 5: Timeline UI (Swift)
- `TimelineViewModel`: clip rects from the engine snapshot, zoom, scroll, snapping candidates, selection, hit testing.
- `TimelineView` in SwiftUI `Canvas` (clips, thumbnail strips, waveforms, transitions, playhead, ruler) with gestures for select, drag-move, edge-trim, playhead scrub, marquee. Continuous drags preview through the engine and commit one undoable command on release. Falls back to an `NSView` with the same view model if `Canvas` stutters.
- Track headers (mute/solo/lock, add/remove), media bin grid with `Transferable` drag to timeline, source monitor with in/out and Insert/Overwrite.
- Keyboard: space, J/K/L, ←/→, Cmd+K, Delete, Shift+Delete, I/O, Cmd+Z/Shift+Cmd+Z, +/- zoom.
- Tests: view-model snapping, hit testing, rect layout.

### Phase 6: Effects, transitions, inspector
- Inspector bound to the selection: position/scale/rotation/opacity, gain, speed, fade durations, backend override.
- Cross dissolve drag-to-cut with duration handles; scheduler emits both clips with a mix factor; audio crossfade and fades via mixer gain envelopes. All undoable, re-render current frame on change.

### Phase 7: Export
- `ExportJob` iterates sequence frames through `Compositor` into a pool sized for the encoder's format, pushes to `IVideoEncoder`/`IAudioEncoder`/`IMuxer` using the pull model (`requestMediaDataWhenReady` on the Apple side).
- Presets: H.264/HEVC hardware (default), ProRes 422 hardware, AV1 software via SVT-AV1 if enabled, resolution and bitrate/quality options; the sheet shows whether the chosen path is hardware.
- Tests: export the sync sequence, re-decode with the phase-2 decoders, check burn-in codes and beep alignment.

### Phase 8: Persistence and polish
- Open/save/save-as, autosave, dirty state, recent projects, relink-missing-media dialog, security-scoped bookmarks.
- Memory: `FrameCache` budget, compositor `CVPixelBufferPool`, purge on `DispatchSource.makeMemoryPressureSource`.
- Preferences: hardware capability table, backend preference, cache size.
- Instruments profiling pass; HUD kept behind a debug menu.

### Effect lanes (2026-09-24; plan in `docs/plans/2026-09-24-effect-lanes.md`)
- Effects become spans on lanes under each clip: lane 0 holds transitions (cross dissolve / crossfade across a
  cut with any split of its sides, fades to and from black or silence), lanes 1-3 Motion, Opacity and Gain spans
  with start and end values that compose onto the clip's static values; a span holds its end value from its end
  to the clip's end, and a later span on its lane applies on top (hold after). Replaces per-parameter keyframes.
- Round 1 (engine): schema v5 with the v4 migration (v4 files render identically), Scheduler and mixer on spans,
  span edit ops and facade, parity tests. The app keeps working with its keyframe controls inert.
- Round 1b (engine): hold after: composition, audio levels, Ken Burns edges, matching, and trims/splits past a
  span keep the held value; the migration still renders identically.
- Round 2 (app): lanes in the timeline, the inspector's span section, the Ken Burns editor on a lane range,
  transitions dragged on lane 0.

## Key risks and mitigations
- **A/V drift**: audio clock is master; video never blocks; burn-in media tests in phase 4.
- **Two backends diverging**: one conformance suite run against both; router decisions are visible in the UI and HUD.
- **FFmpeg build and bundling**: pinned tag, LGPL-only flags, dylibs bundled with `@rpath`, codesigned in the app's copy phase. Solved once in phase 0.
- **Seek latency** on long-GOP sources: keyframe-based decode with coalescing; random-access path via `AVSampleBufferGenerator` on the Apple side.
- **Obj-C++ engine leaking Apple types into the model**: model/edit/scheduler files include only CoreMedia (`CMTime`) so they still compile and test without media, Metal, or FFmpeg.
- **SwiftUI timeline performance**: `Canvas` draws only visible clips with pre-rendered thumbnail and waveform images; `NSView` fallback planned.
- **Variable frame-rate sources**: prober flags VFR; scheduler picks the nearest source frame.
- **Sandbox file access**: bookmarks in the project; relink flow in phase 8.

## Verification summary
- `EngineTests`: model/edit/scheduler tests (no media), `MediaBackendTests` conformance on synthesized files for both backends, compositor pixel tests, export round trip.
- `AppTests`: Swift view-model tests.
- Manual: sync test project with the debug HUD; Instruments passes for playback and export.
- CLI: `xcodegen generate && xcodebuild -scheme Framewright -configuration Debug build && xcodebuild -scheme EngineTests test && xcodebuild -scheme AppTests test`.

## First implementation step after approval
Phase 0: install XcodeGen, write `project.yml`, vendor the two headers, write and run `build-ffmpeg.sh`, create the targets with placeholder sources, confirm the app launches and both test targets run from the command line.
