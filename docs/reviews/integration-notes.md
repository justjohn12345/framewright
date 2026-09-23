# Integration notes for the next round (from the 2026-09-23 fix round)

State after the fix round for `2026-09-23-full-review.md`: full Framewright scheme green with
`-Wall -Wextra` and warnings as errors (C/ObjC/C++ and Swift); Audio, Playback, Facade, DecodePool
and FrameCache suites clean under ThreadSanitizer. Unfixed items are in `open-findings.md`; this
file lists what later phases (6: transitions/effects UI, 7: export, 8: persistence) must adopt.

## Edits and gestures (phase 6 inspector, transition handles)
- Every continuous gesture: `beginCoalescingWithKey:`, then make each of its edits inside
  `performInCoalescingGroup(key) { ... }`, then `endCoalescing` / `cancelCoalescing`. An edit
  made outside the block while the group is open ends the group first (the gesture becomes its
  own undo step) and the gesture's later steps return `VEEditErrorBusy`: handle that (stop
  issuing steps). `removeAsset:` is still refused with Busy while a group is open.
- App side: `ProjectStore.isGestureActive` (timeline drag or an open engine group) guards every
  edit command reachable from keys and menus; add the guard to new edit commands (transition
  duration, fades, effect presets...). The inspector's sliders keep their group key in `@State`
  and end the group in `onDisappear`; copy that pattern for new sliders/handles.
- `MoveClips` re-homes a transition whose two clips land on the same track; a move that breaks
  the cut still drops it (reported in `droppedTransitionIDs`).
- `FreshIds` forwards `mergeWith`, so `CoalesceMode::Accumulate` works through the facade (e.g.
  repeated nudges or an effect parameter scrubbed by keys).

## Media identity (any code that decodes or caches by asset id)
- Asset ids restart per project. `FrameCache` has media epochs (`beginEpoch()`, `put(epoch, ...)`
  refuses older epochs); `DecodePool::beginEpoch(epoch)` forgets assets, targets, scrub requests
  and decoders; `PlaybackController::forgetMedia()` forgets registrations and routing. The facade
  does all three in `forgetProjectMedia` (New/Open). An `ExportJob` (phase 7) that owns a pool on
  the shared cache must register its assets itself and tag its puts with the current epoch.
- Several pools share the cache: each has its own `FrameCache` focus client (merged for
  eviction) and its own `Config::budgetFraction` (program 0.5, source 0.25). Give an export pool
  its own share (the shares should add up to at most 1).
- A decoded frame is published only if its stream still exists and its asset slot was not
  replaced (relink, invalidate, epoch): after those calls return nothing older reaches the cache.
  `waitUntilIdle` now also waits for steps of removed streams and for scrub decoder cleanup.
- `PlaybackController::setSequence` drops the pictures a frame source holds (clip ids repeat
  across projects); `modelChanged` keeps them.

## Playback and monitors
- One monitor plays at a time: starting the program pauses the source monitor and vice versa
  (in the facade).
- `modelChanged` posts a status when the clamp moves a stopped/scrubbing playhead (UI playheads
  follow edits that shorten the sequence).
- `VEPlaybackStats` has `presentedFrameIndex`, `presentedTime`, `presentedClockDriven` (the HUD
  shows the presented frame against the clock).
- `AutomaticAudioOutput` listens for the default output device (CoreAudio); a device appearing
  makes a retry due at once. Tests can pass `watchDefaultDevice = false` and call
  `defaultOutputDeviceDidChange()`.

## Swift and app rules
- `VEEngine` and `VEPreviewView` are `NS_SWIFT_UI_ACTOR` (@MainActor in Swift); release the last
  reference on the main thread. `ProjectStore.init()` is a convenience init (default arguments
  are evaluated outside the main actor).
- `KeyboardController` takes keys only from `ProjectStore.editorWindow` (set by `ContentView`);
  new windows (export sheet, preferences) keep their own keys. Clicks in editor panels call
  `store.reclaimKeyboardFocus()`; new panels with text fields should do the same on their
  background taps.
- UI caches (`ThumbnailCache`, `WaveformCache`) have generations and ignore completions of a
  closed project; `VEEngineErrorProjectClosed` is not a failure. Both take an injectable `now`.
- The playhead can be dragged in the track area (empty space within 4 pt of it, or Option-drag).
  Bare =/+ and - zoom like Cmd+=/-.

## Build and signing
- Warnings are errors (`WARNING_CFLAGS = -Wall -Wextra`, `GCC_TREAT_WARNINGS_AS_ERRORS`,
  `SWIFT_TREAT_WARNINGS_AS_ERRORS`). Aggregates without default member initializers need every
  field (`-Wmissing-field-initializers`); give new struct fields defaults.
- Configurations: Debug and Release are ad hoc without the hardened runtime (launch headless);
  Distribution (the Archive action) has the hardened runtime and the identity/team from
  `Config/Distribution.xcconfig` (`FRAMEWRIGHT_CODE_SIGN_IDENTITY`, `FRAMEWRIGHT_DEVELOPMENT_TEAM`,
  optional gitignored `Config/Signing.local.xcconfig`). Anything new embedded in the app must
  be signed on copy (CodeSignOnCopy) or library validation rejects it under Distribution.
- `App/Resources/Acknowledgements.md` and `COPYING.LGPLv2.1` ship in the app; update the notice
  when a dependency or its version changes (and `ThirdParty/VERSIONS.md`).

## ExportJob (phase 7) notes carried over
- Create the compositor with `Compositor::create(device, {MTLPixelFormatRGBA16Float})`; `renderAndWait` into a pooled
  420v/BGRA `PixelBufferTarget`; `RenderResult` has `prescaledPlanes`, `gpuStartTime`, `gpuEndTime`, `skippedLayers`;
  call `releaseScratchMemory()` under memory pressure. Use `IMediaWriter::runPull` (pull mode) rather than push mode;
  `endStream(TrackKind)` when one stream ends early. Hardware encoders are size-dependent (H.264 hw not used at 8192x4320);
  the writer reports which it used.

## Phase 6 (effects, transitions, inspector) additions
- Facade: `beginCoalescingWithKey:mode:` (VECoalescingModeAccumulate for keyboard nudge bursts:
  each edit applies on top of the last and merges into one step; only SequenceCommands merge,
  so a CompositeCommand, e.g. a multi-clip speed change, is a step of its own even inside an
  Accumulate group) and `coalescingKey` (end only your own group: check it before
  `endCoalescing`). `ProjectStore.nudgeGroup` marks an open nudge burst, which
  `isGestureActive` does not count as a gesture (the next command commits it first).
- `VEClipParamsBatch` + `applyClipParams:` set several clips' parameters in one step (video
  parameters only on video tracks, audio only on audio tracks; refused as a whole).
- `transitionLimitFromClip:toClip:` / `transitionLimitForTransition:` (VETransitionLimit): the
  longest centred transition a cut takes and a user-facing reason; transition add/resize
  refusals now carry that reason and the longest allowed duration.
  `addTransitionFromClip:toClip:duration:options:` fits to the cut and/or adds the linked
  partners' transition in the same undo step.
- `setSpeedNumerator:denominator:forClips:ripple:scope:`: several clips, explicit ripple choice.
- App preferences (Settings > Editing, `EditingPreferences`): default transition duration,
  linked crossfade (always/never/ask), duration display (timecode/frames/seconds; also what
  `DurationFormat.parseFrames` assumes for a bare number). Export (phase 7) should show
  durations through `ProjectStore.durationString` for consistency.
- In-app drag types: `com.justjohn12345.framewright.transition.cross-dissolve` and
  `...audio-crossfade` (declared in project.yml / Info.plist, like the asset reference). The
  timeline's drops go through `TimelineDropDelegate` (assets and transitions).

## Phase 6 review fix round (`2026-09-23-phase6-review.md`)
- Linked transitions: with `FitToCut | IncludeLinked` each transition is fitted to its own cut
  (the dissolve and the crossfade can differ in length); the note names each shortening
  ("Shortened to …" for the requested one, "The linked clips' transition was shortened to …").
  `ProjectStore.addTransition` always passes IncludeLinked for "Always" (and for "Ask" when there
  is nothing to ask) and shows the engine's note, e.g. why the audio got no crossfade.
- Paused/stepping/scrubbing monitors (`PlaybackController::frameSource`): a frame whose pictures
  are still being decoded is held back ("unchanged") while the display's scrub request is in
  flight, so the previous complete picture stays up; the first frame after `setSequence`, or a
  frame whose request failed, is presented with what is available. `PresentedFrame` has
  `heldBackFrameIndex`; test harnesses that wait for "exact" must also wait for it to be -1.
  `VEPreviewView.missingLayerCount` is now set when a render takes a frame (it always describes
  the frame `-snapshot` composites). `ProgramFrameProvider` (source monitor scrubbing) already
  published only complete frames.
- Editing preferences are observable: `ProjectStore.preferences` (`EditingPreferencesModel`,
  mirrors of the three keys, re-read on `UserDefaults.didChangeNotification`; `revision` is a
  redraw token) and its changes are forwarded to the store's `objectWillChange`. Read
  `store.editingPreferences` (a snapshot) and format with `durationString` /
  `shortDurationString`; a model object that shows durations outside a view observing the store
  (like `SpeedDurationModel`) forwards `store.preferences.objectWillChange` itself. The export
  sheet (phase 7) gets this for free if it observes the store.
- The inspector sets the status line only for a note or a refusal (a plain success leaves it).
- `VEClipParamsBatch` is `NS_SWIFT_UI_ACTOR` and asserts the main thread.
- Removing a transition goes through `ProjectStore.removeTransition(_:)` (focus independent).

## Phase 7 (export) additions
- Engine: `Engine/Export/ExportJob.{h,mm}` (one export: validate, then a private DecodePool on the
  shared FrameCache with its own 0.25 budget share and lanes = clip ids, a Compositor created for
  RGBA16Float, an `OfflineAudioRenderer`, a writer from `BackendRouter::makeWriter`, all driven by
  `IMediaWriter::runPull`). Pictures are looked up with `playback::frameSlotFor` (shared with the
  program monitor), so an export shows exactly what the monitor shows. A layer that cannot be
  decoded fails the export ("Frame N (t s) cannot be exported: “name” could not be decoded ...");
  it is never drawn black or stale. Cancel completes in about 70 ms (measured), deleting the working
  file (see "Phase 7 review fix round" below: the output path is only written when complete).
- Audio: `Engine/Audio/OfflineAudioRenderer.{h,mm}` is the render thread of a private AudioMixer
  (same plans, envelopes, crossfade law, speed resampling and clipping as playback); it waits with
  `AudioMixer::isRangeReady` before each block, turns a failed source into an error
  (`failedSourceIn`) and treats any underrun as an error. Keyframed Motion (open finding 8) must be
  evaluated in the Scheduler / RenderGraph so export and playback keep sharing one path.
- Media: `VideoCodec::AV1` (FFmpeg writer only: libsvtav1 preset 8, CRF from quality, VBR from a bit
  rate; 8-bit input to yuv420p, 10-bit to yuv420p10le) and `ContainerFormat::MKV` (FFmpeg only);
  `BackendRouter::writerBackendFor/makeWriter` ("apple" first); `IMediaWriter::videoEncoderName()`;
  `HardwareCaps::encoderAvailability(codec, w, h, tenBit)` (VideoToolbox asked at the frame size,
  cached). AppleWriter encodes HEVC Main10 from 'x420' input; the compositor renders 'x420'/'xf20'
  targets (whole 10-bit codes). ProRes is fed 32BGRA (8-bit): a 10-bit 4:2:2 target ('x422' or
  'v210') is a phase 8 candidate for 10-bit sources.
- Fixed on the FFmpeg writer path: `ComposedMediaWriter::runPull` now ends (flushes) a stream as
  soon as its callback reports the end (the muxer no longer holds the other stream back), and
  `FFAudioEncoder` trims the silence that padded the last AAC frame (aac_at has no small last
  frame): packets are shortened/dropped at the real end, which ends the MP4 edit list exactly and
  becomes Matroska DiscardPadding (`EncodedPacket::trailingDiscard`). Before, an FFmpeg-written
  file's audio ran up to 1023 samples long.
- `DecodePool::waitForProgress(timeout)` (block until a step finished, instead of polling) and
  `refresh()` (restep settled streams: re-decodes a target frame evicted by memory pressure,
  retries a failed decode).
- Progress `bytesWritten` is the working file's size; AVAssetWriter stages MP4 (index up front)
  elsewhere, so it stays 0 for Apple MP4 until the end (MOV and FFmpeg files grow as they go).
- Facade: `VEExport.h` (VEExportPreset/Container/Resolution/RateControl/AudioCodec with explicit
  Swift names, `VEExportSettings` value object with `validationMessage` and
  `outputSizeForSequenceWidth:height:`, `VEExportFormat`, `VEExportProgress`, `VEExportSummary`,
  `VEExportHandle` with `cancel` / `cancelAndWaitWithTimeout:`); on VEEngine
  `exportFormatsForWidth:height:[completion:]`, `exportSizeForSettings:`,
  `estimatedFileSizeForSettings:` (bit rate, or a bits-per-pixel heuristic for quality mode: an
  estimate, labelled "≈" in the UI), `beginExportWithSettings:outputURL:progress:completion:error:`,
  `activeExport`, `isExporting`, `VEEngineExportDidProgressNotification` /
  `VEEngineExportDidFinishNotification`, error codes 6-11. New/Open cancels a running export (its
  asset ids are about to name other media); memory pressure is forwarded to the job.
- App: `App/Views/Export/ExportSheet.swift` (`ExportModel` + `ExportSheet`, `ExportFolderMemory`,
  `ProgressThrottle`); File > Export… (Cmd+E) via `ProjectStore.showExportSheet()`; the store
  republishes `isExporting` (also on `VEEngineExportDidFinish`); `DocumentController`
  `confirmStoppingExport(because:)` runs before New, Open, window close and quit (Stop Export
  cancels and waits up to `DocumentController.exportStopTimeout`, 10 s, for the export to end). The sheet stays up (modal on the editor
  window) while exporting; Close is disabled and Escape cancels the export.
- For the pending UX round (open findings 4-7): the sheet is 480 pt wide and self-contained; a
  pop-out program monitor (finding 7) must be paused by `beginExport...` like the two monitors are
  now (`_playback->pause()`, `_sourcePlayback->pause()`). WebM is not offered: the LGPL build's only
  Opus/Vorbis encoders are FFmpeg's experimental ones (AV1 goes to MP4 or MKV with AAC).

## Phase 7 review fix round (`2026-09-23-phase7-review.md`)
- Atomic export. `ExportJob` renders into a working file: the output's name inside a fresh
  directory from `-[NSFileManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask
  appropriateForURL:<output> create:YES error:]` (the output's volume; writable by the sandboxed app
  for a URL the save panel granted). On success it is moved to the output (`moveItemAtURL:` when
  nothing is there, else `replaceItemAtURL:withItemAtURL:backupItemName:options:resultingItemURL:`,
  which keeps the replaced file's attributes); on cancel or failure only the working directory is
  deleted. `ExportJob::workingPath()` names it (kept after the end so tests can check it is gone).
  `ExportProgress::bytesWritten` stats the working file (0 for Apple MP4 until `finish()`).
- Writer contract (`Interfaces.h`): `IMediaWriter::open` / `IMuxer::open` create a new file and
  refuse an existing path (`InvalidArgument`); `AppleWriter` no longer deletes the destination and
  `FFMuxer` creates the file with `O_EXCL` before `avio_open`. Anything else that writes media
  (phase 8: render caches, proxies, a "replace" flow) must write a new file and move it into place.
  `IMediaWriter::setFinishCancellation(check)` (pure virtual: new writers and test doubles implement
  or forward it) makes `finish()` poll `check` (AppleWriter: before `finishWriting` and every 20 ms
  while it completes, then `cancelWriting`; ComposedMediaWriter: before each flushed packet and the
  trailer) and return `Cancelled` with the partial file deleted.
- `MediaAsset::videoDuration` (schema 3): where the video track ends on the container timeline,
  at most `duration`; invalid for stills, audio-only assets and hand-built test assets, and then
  `videoEnd()` is `duration`. `mediaEndFor(asset, trackKind)` (Validation.h) is the media end for a
  clip on a track of that kind: use it wherever a video clip's source range is checked or set.
  Validation, `buildClip` (placements: an out point past the video's end is cut there, an in point
  at or after it is refused), `TrimClipTail`, `SetClipSpeed`, transition handles
  (`checkTransition`, so `transitionLimit` too), `Scheduler::sourceFrameTime` and the source
  monitor's project all use it. Linked A/V pairs placed over the whole media therefore get a video
  clip shorter than the audio; the facade adds a note (`VEEditResult.note`) when a placement is cut.
  Schema 2 files are migrated with `videoDuration = duration`. Keyframes (open finding 8) are now
  schema 4.
- End-of-video hold (`DecodePool.h`): at the end of a stream the last frame is put again with an
  infinite duration (`FrameCache::put` extends an entry re-put with a later end, pinned or not), so
  playback and export show the last picture past the end of the video instead of a missing layer; a
  target past the end searches back for the last frame (doubling steps from the track end); the
  scrub path does the same. `DecodePool::StreamStats` has `eof` and `videoEnd`; a stream's published
  `rangeEnd` is +infinity once the tail is held.
- Audio read failures: `ClipAudioSource::Stats::readFailed` / `readFailedAt` (the earliest sequence
  sample produced as silence because a read or seek failed after the decoder opened). Playback keeps
  playing (silence there); `AudioMixer::failedSourceIn` reports such a source for ranges reaching
  that sample (`SourceInfo::failedAt`), and the offline renderer fails the export with "The audio of
  “name” on A1 could not be decoded at 0.512 s in the sequence: ...".
- Export validation: the output may not be any file of `project.assets` (compared by inode, else
  canonical path), used or not; unreadable media is `FileNotFound` (facade: `VEEngineErrorMissingMedia`).
  A layer with no picture fails only after three refreshes in a row made no progress (no frame
  decoded, no seek), and the message says where the media's video ends when the stream hit it.
- Playback during an export: `play`, `togglePlay` (from paused), `setRate:` with a rate, the
  shuttles and the source monitor's equivalents do nothing while `isExporting`; the app disables the
  transport buttons and Playback menu items and `EnginePlaybackActions` sets the status line
  (`EnginePlaybackActions.exportingMessage`). Pause, stepping and scrubbing still work. A pop-out
  monitor (open finding 7) must refuse the same way.
- Export sheet: a container change after a file was chosen clears the choice
  (`ExportModel.outputNotice` explains it, the panel reopens on the same folder and name with the
  new extension); the sandbox-granted URL is never renamed.
- Tests to reuse: `ExportRegressionTests.mm` has `FailingWriter`/`FailingWriterBackend` (wrap a
  real backend under its own name so the router prefers it; fail after N frames, in `finish()`, or
  run a hook in `finish()`); `ExportParityTests.mm` composites the `PlaybackController` frame
  source's frame (`PlaybackHarness::frame()` / `device()`) for pixel comparisons and compares the
  playback mix with `OfflineAudioRenderer` sample by sample (1.2e-7 measured). Missing encoders fail
  `ExportJobTests` unless `FRAMEWRIGHT_ALLOW_MISSING_ENCODERS=1`.

## UX round (open findings 1-7 from hands-on testing)
- Play start (finding 3). The cause of the lag on the iPhone clip was not the lookahead: on a
  variable-frame-rate source a layer's picture is looked up by its nominal frame slot, whose start
  can lie in the frame before the one containing the layer's source time, but the paused picture's
  scrub request and the pool targets asked for the source time. The slot was never filled, the paused
  picture kept its previous frame and `play()` waited for the first frame until the pre-roll timeout
  (measured 1004.7 ms before the fix). Superseded by the UX round fixes below: pictures are now looked
  up and requested at the layer's exact source time (`playback::pictureTimeFor`); `frameSlotFor` and
  `frameSlotTimeFor` are gone.
- Stopped lookahead (`PlaybackController.h`): while stopped and once the playhead has been still for
  `PlaybackConfig::idleLookaheadDelay` (100 ms), the tick thread retargets the pool at the paused
  frame with `stoppedLookahead` (0.5 s, forward) and warms the audio (`audioWarmDelay`, now 100 ms;
  the sources then buffer about 2 s). A moving playhead (step repeat, J/K/L taps, scrubbing, edit
  drags) never retargets the pool; the immediate stopped retarget (`pendingRetarget_`) is gone.
  `setIdleLookahead(false)` clears the targets while stopped; the facade does it while an export runs.
  Any transport activity keeps the audio output warm for `outputIdleTimeout`, now 5 minutes (the old
  10 s let the device stop between edits, so the next Space paid for AVAudioEngine's start).
- Measured press-to-first-presented-frame (the start frame is already on screen, so the latency is
  the first new frame's presentation minus the playing time it stands for; three runs): controller
  with a null output 2-14 ms cached, 17-20 ms cold; the VFR source 9-12 ms (was up to 1004.7 ms);
  facade with the real AVAudioEngine output 17-27 ms cached, 37-49 ms cold. Tests assert < 50 ms
  cached (`PlaybackLookaheadTests`; `VEEnginePlaybackTests.testPlayStartLatencyThroughTheFacade`: see
  "UX round fixes" for its current bounds). `PresentedFrame::hostNanos` /
  `VEPlaybackStats.presentedHostTime` report when a frame was handed out.
- Frame sources: `PlaybackController::frameSource(SourceRole::Mirror)` shows the same frames as the
  primary one without touching the counters or `lastPresented()`. `VEEngine attachOutputView:` /
  `detachOutputView` / `outputView` mirror the program in a second view (decoded once, textures per
  view); unlike the program view the engine runs and pauses the output view's render loop from the
  program's status and renders it on `needsDisplay`; it follows export refusal like the monitors.
- Linked transitions (finding 2): `linkedTransitionForTransition:`, `removeTransition:includingLinked:`
  (a locked partner is kept, with a note), `setDuration:forTransition:includingLinked:` (the partner
  gets the same length fitted to its own cut; the note names a shortening). The engine commands are
  `RemoveTransitions` and `SetTransitionDurations` (EditOps), single SequenceCommands rather than a
  CompositeCommand so a keyboard-nudge Accumulate group merges them. `linkedTransition()` and
  `isThroughEdit()` are plain functions in EditOps.
- Through edits (finding 1a): `addTransition...` adds "Both sides show the same frames here; trim or
  move one side to see the dissolve" (audio: "...play the same audio here...") to the note when both
  clips play one asset contiguously with the same speed and parameters.
- App: `WindowLayoutModel` (App/State/WindowLayout.swift, `store.layout`) owns the source monitor's
  visibility, the right panel's tab (`InspectorTab`) and the split positions (UserDefaults keys
  `layout.*`; a store made with `ProjectStore(engine:)` keeps them in memory so tests never touch the
  app's saved layout; the app's `ProjectStore()` persists them). The splits are SwiftUI views with
  `PaneDivider`, not NSSplitView. The timeline pane is `fittedTimelineHeight(contentHeight:)` until
  the divider is dragged (double-click fits again). `store.collapsedTrackIDs` collapses empty tracks
  (a track that gets a clip shows full height); the timeline model cache is keyed by it too.
  `store.setSourceMonitorVisible(_:)` pauses source playback when hiding; `showInSourceMonitor` shows it.
- App: Transitions live in `EffectsPanel` (the right panel's Effects tab); the "+" and the drag source
  are unchanged. `TimelineDropDelegate`'s logic takes any `TimelineDropInfo` (DropInfo conforms), so
  new drop kinds (Photos file promises, open finding 9) can be tested with a double. Right-clicks in
  the track area go through `ContextMenuCatcher` + `TimelineGestureController.contextMenuItems(at:)`.
  Delete on a transition removes its linked one; Option-Delete (`KeyboardController.Action
  .deleteTransitionOnly`, Clip > Delete Transition Only) removes one. `store.resizesLinkedTransitions`
  (Editing preference `resizeLinkedTransitions`, default on) drives the inspector and handle drags.
- App: `OutputDisplayController` (`store.outputDisplay`, View > Program Monitor on Second Display) over
  `ScreenProviding` (`SystemScreens`, or a test double); the output window is an `OutputWindow`
  (borderless, can become key, Escape closes); `KeyboardController` takes transport keys from it too.
- For keyframed Motion (finding 8): its controls belong in the Inspector tab (per clip, with the
  playhead), presets in the Effects tab; evaluate it in the Scheduler so both frame sources, the
  mirror and export share it; keyframe markers on collapsed rows need no room (only empty rows collapse).
- For Photos drops (finding 9): accept file promises in `TimelineDropDelegate.types` and the media
  bin's drop, test them with a `TimelineDropInfo` double whose providers carry the promise types;
  slow-motion and iPhone VFR media rely on `pictureTimeFor` (see "UX round fixes").

## UX round fixes (2026-09-23 UX round review; report in git history at 95f445d)
State: full Framewright scheme green (428 EngineTests, 115 AppTests, one known skip: gap 9 below in
`open-findings.md`), zero warnings; all 428 EngineTests clean under ThreadSanitizer
(`-enableThreadSanitizer YES`; three timing/allocation tests skip themselves there).
- Pictures by time (finding 1). `playback::pictureTimeFor(layer, asset)` (PlaybackController.h) is the
  source time of a layer's picture: the layer's source time (on the asset's grid for CFR media, exact for
  VFR), 0 for stills. Look it up with FrameCache's containment lookup (`acquire/get/contains(asset, CMTime)`:
  the frame whose display interval contains it, the frame a decoder's `seek()` returns) and request decodes
  and pool targets at the same time. The frame source, the paused picture's request, the pool targets,
  `firstFramesReadyLocked` and `ExportJob` all do; `frameSlotFor`/`frameSlotTimeFor` are removed (they
  showed the frame under the nominal slot's start, up to one nominal frame early on VFR media). The slot
  API stays on FrameCache for diagnostics; do not use it for pictures. There is no separate CFR fast
  path: for CFR media the scheduler's source time already is the slot start, so the time lookup returns
  the same frame, and it is cheaper (one map search instead of two; Debug build, 1M lookups over 4 assets
  x 300 frames: `acquire` by time 669-672 ns vs by slot 774-778 ns, `contains` 275-291 vs 354 ns).
  `PresentedLayer::wantedIndex` is the slot containing the picture time and `shownIndex` the slot the
  shown frame starts in (they differ for VFR). VFR play-start latency after the change (controller, eight
  off-grid starts on the Matroska VFR clip, three runs): median 4.3-6.3 ms, worst 11.0-13.2 ms (before,
  same machine: median 4.9, worst 10.4 ms; 1004.7 ms before the original UX-round fix).
- Output window keys (finding 2). `KeyboardController.handle` takes only `Action.isTransportOrCancel`
  (Space, J/K/L, arrows, Home/End, Escape) from `store.outputDisplay.window`; everything else is passed on
  (the window ignores it). A new transport action must be added to `isTransportOrCancel`; any other new
  action is editor-only automatically.
- Output window edges (finding 3). `OutputDisplayController` hides on
  `NSApplication.didResignActiveNotification` (detached from the engine, `resumesOnActivation` set) and
  shows again on `didBecomeActiveNotification`, only if it was up; if its display went away meanwhile the
  status line says so. Both come through the injected `center`. `targetScreen` is nil (not available, `show()`
  refused) while the editor window's display is unknown; `ProjectStore.editorWindow`'s didSet calls
  `outputDisplay.screensChanged()` so availability follows the editor window.
- Source monitor lookahead (finding 4). `VEEngine.sourceMonitorVisible` (default YES): the source controller
  keeps its stopped lookahead only while visible and no export runs (`setIdleLookahead` is re-applied on
  change, on export start/end and when the controller is created). `ProjectStore` forwards
  `layout.$showsSourceMonitor` to it (so every path: menu, bin double-click, Reset Window Layout, the saved
  layout at launch). New diagnostics: `VEEngine.sourceMonitorPlaybackStats`, `VEPlaybackStats.decodeStreams`
  / `PlaybackStats::decodeStreams` (streams the pool keeps, busy or idle).
- Power-aware audio idle (finding 5). `audio::PowerSource` (Engine/Audio/PowerSource.h): `onBattery()`,
  `observe()` (RAII `Observation`), `systemPowerSource()` (IOKit `IOPSGetProvidingPowerSourceType`, refreshed
  on `kIOPSNotifyPowerSource`; process-lifetime) and `ManualPowerSource`. `PlaybackConfig::outputIdleTimeout`
  (AC, 5 min), `outputIdleTimeoutOnBattery` (60 s), `powerSource` (default: the system's);
  `PlaybackController::outputIdleTimeout()` is the one that applies now; a power change re-evaluates the
  deadline at once (measured from the last transport activity). `PlaybackHarness` and `ToneRig` inject
  `ManualPowerSource(false)` so tests never depend on the machine's power; do the same in new harnesses that
  rely on idle timing. IOKit is linked into the engine and EngineTests (project.yml). Preferences > Media
  and the README state the behaviour.
- Dividers and the context menu (findings 6, 8). `DividerCursor` (PaneDivider.swift) owns a divider's
  cursor like `TimelineGestureController` does (set, change detection, arrow on leave or on a drag ending
  outside the divider's global frame; `apply` injectable). `ContextMenuCatcher.CatcherView` filters on the
  button and Control before any coordinate work (`isContextClick`, `handle(_:window:)`), installs its monitor
  exactly while in a window (`isMonitoring`) and shows the menu through an injectable `popUp`.
- Layout arithmetic (gap 4). `ContentView.sideWidths(windowWidth:binWidth:inspectorWidth:)` and
  `WindowLayoutModel.dragSourceMonitorDivider(from:by:areaWidth:)` are what the view uses; test layout
  changes there.
- Latency test (finding 7). `testPlayStartLatencyThroughTheFacade` is skipped under ThreadSanitizer and
  asserts the median of the cached starts < 50 ms and the worst < 80 ms (the values are logged).
