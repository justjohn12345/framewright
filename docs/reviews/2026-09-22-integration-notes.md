# Integration notes for the next round (collected from the 2026-09-22 fix agents)

State at 5325cd9: full suite green (327 EngineTests incl. 140 doctest cases, 17 AppTests), zero warnings, app launches.
All four review docs' findings are fixed EXCEPT the facade/Swift items in `2026-09-22-playback-facade-ui-review.md`
(findings 1, 2, 3, 8, 9, 10, 11, 12 and the facade/Swift parts of 14, plus test gaps 5 (facade), 6). Those are the next round,
together with phase 5b (wiring PlaybackController into VEEngine/ProjectStore) and a scaffold pass.

## Facade (VEEngine) must adopt
- Model: `insertAsset` now ripples all unlocked tracks; `rippleDeleteClips`/`setSpeed` default to all tracks and can return
  `Overlap` (offer `RippleScope::SyncedTracks` as fallback/preference); `splitClips` can return `InsideTransition`
  (`SplitOptions::allowBreakingTransitions`); new `EditError::NotRepresentable`; `EditResult::droppedTransitionIds` must be
  surfaced (and `CompositeCommand` must merge its children's lists); `ProjectLoadResult::warnings` must be shown on open;
  clip speed is a `Ratio` (`speedValue()` for display, `speedFromDouble` for input); no-op edits add no undo step;
  files are schema v2. `MediaAsset::rotationDegrees` must be 0/90/180/270 (validation).
- Media: pass a lane per monitor/scrubber to `DecodePool::requestFrame`; `route.hardwareDecode` is now measured;
  `TrackInfo` has `decodable`/`hardwareDecode`; router falls back at runtime on decode failure; FrameCache has time-based
  `get/acquire/contains(asset, CMTime)` (preferred over slot index for VFR); `DecodeOptions::interrupt`.
- Render: pass `attachID: ObjectIdentifier(store)` to `ProgramMonitorView` or a monitor kept across a project change will
  not re-attach; forward memory pressure to `-[VEPreviewView handleMemoryPressure]`; `lastError`, `missingLayerCount`,
  `skippedLayerCount` available for the HUD; `Compositor::create(device, preparedFormats)`.
- Playback: `play()`/seek-during-play/direction change return in `Prerolling`, `Playing` follows asynchronously via the
  observer; `PlaybackStatus` has `audioActive` and `lastError` (`AudioOutputUnavailable` | `AudioDeviceLost`);
  `controller->status()`; `PlaybackStats` has `mapFailures`, `monotonicHolds`, `outputRunning`, `outputLatency`;
  pass `CADisplayLink.targetTimestamp` in `PreviewFrameRequest::targetTimestamp`; the frame source must set
  `frame.status` from `TextureCache::textures()` errors and reset it to ok on every fresh frame; `PlaybackConfig::makeOutput`
  is `unique_ptr<IAudioOutput>(AudioMixer&)`; `AutomaticAudioOutput(mixer, EngineFactory, retryInterval)`; audio device starts
  when a sequence opens and stops after `outputIdleTimeout` (10 s); `setMuted` keeps the audio clock.
- Facade fixes still open (from the playback/facade/UI review): async import must not close a user coalescing group and must
  capture `_projectGeneration`; asset/clip ids must never be reused after undo (or purge every id-keyed cache and bookmark);
  multi-clip vertical move must lift-then-place; snapping candidates from the pre-gesture snapshot; double close prompt and
  Finder-open-at-launch; split ProjectStore observables and cache `timelineModel` per changeCount before playhead is wired;
  source monitor via VEPreviewView + scrub lane; Cmd+Z during drag; VE_ASSERT_MAIN in Release; stale useCount; memory
  pressure to all caches; Swift cache `failed` sets; ruler snap; unlinked audio trackOffset; drag state leak; key monitor focus.

## Scaffold items still open (render review 10, 13)
- `ENABLE_HARDENED_RUNTIME` off with no stated reason; add hardened runtime + Developer ID in a Release/Archive config.
- LGPL compliance: bundle `COPYING.LGPLv2.1` and a notice in Resources; README source offer / build-script reference.
- `-Wall -Wextra`, `GCC_TREAT_WARNINGS_AS_ERRORS`, `SWIFT_TREAT_WARNINGS_AS_ERRORS` (build is warning-clean).
- `.gitignore`: `.swiftpm/`, `.build/`; README: mention `make_test_media.swift`, the ffmpeg tools build (`BUILD_TOOLS=1`,
  `ENABLE_SVTAV1=1`), Metal Toolchain download. Add `CoreAudio.framework` to enable a real device-appeared listener.

## ExportJob (phase 7) notes
- Create the compositor with `Compositor::create(device, {MTLPixelFormatRGBA16Float})`; `renderAndWait` into a pooled
  420v/BGRA `PixelBufferTarget`; `RenderResult` has `prescaledPlanes`, `gpuStartTime`, `gpuEndTime`, `skippedLayers`;
  call `releaseScratchMemory()` under memory pressure. Use `IMediaWriter::runPull` (pull mode) rather than push mode;
  `endStream(TrackKind)` when one stream ends early. Hardware encoders are size-dependent (H.264 hw not used at 8192x4320);
  the writer reports which it used.
