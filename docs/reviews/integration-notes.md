# Integration notes

API changes and rules that other layers must adopt, collected from each implementation and fix round
(oldest first). What is still open is in `open-findings.md`; the state of the tree after each round is
in the history table of `README.md`.

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
  does all three in `forgetProjectMedia` (New/Open). Anything that owns a pool on the shared cache
  (`ExportJob` does) must register its assets itself and tag its puts with the current epoch.
- Several pools share the cache: each has its own `FrameCache` focus client (merged for
  eviction) and its own `Config::budgetFraction` (program 0.5, source 0.25, export 0.25; the
  shares should add up to at most 1).
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
- `KeyboardController` takes keys only from `ProjectStore.editorWindow` (set by `ContentView`) and
  the transport keys from the output window; new windows (export sheet, preferences) keep their own keys. Clicks in editor panels call
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
  `DurationFormat.parseFrames` assumes for a bare number). Show durations through
  `ProjectStore.durationString` for consistency (the export sheet does).
- In-app drag types: `com.justjohn12345.framewright.transition.cross-dissolve` and
  `...audio-crossfade` (declared in project.yml / Info.plist, like the asset reference). The
  timeline's drops go through `TimelineDropDelegate` (assets and transitions).

## Phase 6 review fix round (report in git history at f4a3b7f)
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
  (like `SpeedDurationModel`) forwards `store.preferences.objectWillChange` itself; a view that
  observes the store (the export sheet) gets it for free.
- The inspector sets the status line only for a note or a refusal (a plain success leaves it).
- `VEClipParamsBatch` is `NS_SWIFT_UI_ACTOR` and asserts the main thread.
- Removing a transition goes through `ProjectStore.removeTransition(_:)` (focus independent).

## Phase 7 (export) additions
- Engine: `Engine/Export/ExportJob.{h,mm}` (one export: validate, then a private DecodePool on the
  shared FrameCache with its own 0.25 budget share and lanes = clip ids, a Compositor created for
  RGBA16Float, an `OfflineAudioRenderer`, a writer from `BackendRouter::makeWriter`, all driven by
  `IMediaWriter::runPull`). Pictures are looked up at `playback::pictureTimeFor` with the cache's
  time lookup (shared with the program monitor), so an export shows exactly what the monitor shows.
  Hardware encoders are size-dependent (H.264 hw not used at 8192x4320); the writer reports which it used. A layer that cannot be
  decoded fails the export ("Frame N (t s) cannot be exported: “name” could not be decoded ...");
  it is never drawn black or stale. Cancel completes in about 70 ms (measured), deleting the working
  file (see "Phase 7 review fix round" below: the output path is only written when complete).
- Audio: `Engine/Audio/OfflineAudioRenderer.{h,mm}` is the render thread of a private AudioMixer
  (same plans, envelopes, crossfade law, speed resampling and clipping as playback); it waits with
  `AudioMixer::isRangeReady` before each block, turns a failed source into an error
  (`failedSourceIn`) and treats any underrun as an error. Keyframed Motion is evaluated in the
  Scheduler (`Scheduler::motionAt`), so export and playback share one path (see "Keyframed Motion").
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
- WebM is not offered: the LGPL build's only Opus/Vorbis encoders are FFmpeg's experimental ones
  (AV1 goes to MP4 or MKV with AAC).

## Phase 7 review fix round (report in git history at 2dde40e)
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
  Schema 2 files are migrated with `videoDuration = duration`. Schema 4 added Motion keyframes (see
  "Keyframed Motion").
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
  (`EnginePlaybackActions.exportingMessage`). Pause, stepping and scrubbing still work; the output
  view on a second display follows the same refusal.
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
- Play start (finding 3). The lag on the iPhone clip (1004.7 ms measured) was a picture lookup and
  its decode request disagreeing on a variable-frame-rate source, so `play()` waited for a frame
  nobody decoded until the pre-roll timeout. Both now use the layer's exact source time
  (`playback::pictureTimeFor`, see "UX round fixes").
- Stopped lookahead (`PlaybackController.h`): while stopped and once the playhead has been still for
  `PlaybackConfig::idleLookaheadDelay` (100 ms), the tick thread retargets the pool at the paused
  frame with `stoppedLookahead` (0.5 s, forward) and warms the audio (`audioWarmDelay`, now 100 ms;
  the sources then buffer about 2 s). A moving playhead (step repeat, J/K/L taps, scrubbing, edit
  drags) never retargets the pool; the immediate stopped retarget (`pendingRetarget_`) is gone.
  `setIdleLookahead(false)` clears the targets while stopped; the facade does it while an export runs.
  Any transport activity keeps the audio output warm for the idle timeout (5 minutes on AC, 60 s on
  battery; the old 10 s let the device stop between edits, so the next Space paid for AVAudioEngine's start).
- Measured press-to-first-presented-frame (the start frame is already on screen, so the latency is
  the first new frame's presentation minus the playing time it stands for; three runs): controller
  with a null output 2-14 ms cached, 17-20 ms cold; the VFR source 9-12 ms (was up to 1004.7 ms);
  facade with the real AVAudioEngine output 17-27 ms cached, 37-49 ms cold. Tests assert < 50 ms
  cached (`PlaybackLookaheadTests`; the facade test asserts the median, worst < 80 ms, and skips
  under ThreadSanitizer). `PresentedFrame::hostNanos` /
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

## UX round fixes (report in git history at 95f445d)
- Pictures by time (finding 1). `playback::pictureTimeFor(layer, asset)` (PlaybackController.h) is the
  source time of a layer's picture: the layer's source time (on the asset's grid for CFR media, exact for
  VFR), 0 for stills. Look it up with FrameCache's containment lookup (`acquire/get/contains(asset, CMTime)`:
  the frame whose display interval contains it, the frame a decoder's `seek()` returns) and request decodes
  and pool targets at the same time. The frame source, the paused picture's request, the pool targets,
  `firstFramesReadyLocked` and `ExportJob` all do; `frameSlotFor`/`frameSlotTimeFor` are removed (they
  showed the frame under the nominal slot's start, up to one nominal frame early on VFR media). The slot
  API stays on FrameCache for diagnostics; do not use it for pictures. There is no separate CFR fast
  path: for CFR media the scheduler's source time already is the slot start, so the time lookup returns
  the same frame, and it is slightly cheaper (one map search instead of two). `PresentedLayer::wantedIndex`
  is the slot containing the picture time and `shownIndex` the slot the shown frame starts in (they differ
  for VFR). VFR play-start latency is unchanged by the fix (controller, off-grid starts: median about 5 ms,
  worst about 12 ms).
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

## Keyframed Motion (feature request 8)
Superseded by "Effect lanes round 1" below: keyframes now live inside effect spans; the keyframe edits, facade
calls and app controls described here are gone. Kept for the history of the evaluation and split rules spans reuse.
- Model (`Engine/Model/Keyframes.{h,cpp}`, `Clip.h`): `VideoParams` has `MotionKeyframes keyframes`
  (tracks `x`, `y`, `scale`, `rotation`, `opacity`; `MotionParameter`). A keyframe's time is a source
  time of its clip (`Clip::exactSourceTimeAt`; for a still, the time into the clip), so trims leave
  keyframes alone (cut-off ones stay, hidden, and return when the clip is extended), speed changes move
  them with their pictures, and `splitClipAt` divides each track (`splitTrack`: a keyframe on the cut
  for both pieces, an eased segment's curve divided exactly into `Bezier` curves, a piece with nothing
  on its side made static): a split changes no frame. `Clip::setTimelineStartKeepingEnd` shifts a
  still's keyframes so they keep their timeline positions (head trims, the right piece of a split,
  overwrites). A parameter without keyframes shows its static value; with keyframes the static value
  is unused and the ends hold the first/last keyframe's value (Premiere). Interpolation belongs to the
  segment after the keyframe: `Hold`, `Linear` (the default for a new keyframe outside any segment),
  `EaseOut` (leaves slowly), `EaseIn` (arrives slowly), `EaseInOut` (both; the Ken Burns default),
  with Core Animation's curves; the names follow Premiere/FCP, not CSS. `Bezier` comes from dividing
  an eased segment: a split, or (since the Motion/Photos review fix round) a keyframe added inside it.
  `VideoParams` gained constructors (`VideoParams()` and the five static values), `staticValue`,
  `setStaticValue`, `valueAt`, `valuesAt` (values only, no keyframes) and `staticValues()`.
- Frames and keyframes (`Clip.h`): `frameShowingSourceTime`, `keyframeIndexForFrame` (the frame whose
  source span contains the keyframe; the clip's last frame also owns a keyframe on the out point, where
  a split leaves one) and `keyframeTimeForFrame` (the exact source time, or the next kPreciseTimescale
  tick when it has no CMTime form). Use these for "the keyframe under the playhead".
- Evaluation: `Scheduler::motionAt(clip, time)` evaluates at the frame's exact source time (not the
  source frame grid; the next precise tick when it has no CMTime form, see "Motion/Photos review fix
  round") into `VideoLayer::transform` / `opacity`; the program monitor, the output view and
  export all get it from `renderGraphAt`. `ExportParityTests.testAnAnimatedClipExportsTheMonitorsPictures`
  proves the export matches the monitor over moving pictures.
- Edits (`EditOps.h`, all single `SequenceCommand`s, so Accumulate groups merge them): `AddKeyframe`,
  `SetMotionValue` (keyframe upsert at a time, or the static value), `RemoveKeyframe` (the last one
  leaves its value static), `MoveKeyframe`, `SetKeyframeInterpolation` (not `Bezier`), `SetMotionTracks`
  (whole tracks; Ken Burns, "Remove Animation"). New `EditError::KeyframeNotFound`. `SetVideoParams`
  and `SetClipsParams` set keyframes too; the facade keeps a clip's keyframes when it sets static values.
  Keyframes only on clips of video tracks (validation).
- Facade: `VEMotionParameter`, `VEKeyframeInterpolation` (`Custom` = `Bezier`, read only),
  `VEMotionFraming`, `VEKeyframe` (sourceTime, timelineTime, frameTime, isInsideClip, value,
  interpolation); `VEClipInfo` `hasKeyframes`, `allKeyframes`, `isAnimated:`, `keyframesForParameter:`,
  `motion(at:)` (`videoParamsAtTime:`) and `keyframeForParameter:atTime:`; `VEEngine`
  `addKeyframe(clip:parameter:at:)`, `removeKeyframe`, `setMotionValue(_:parameter:clip:at:)` (static,
  or the keyframe under the playhead, or a new one when animated: Premiere's stopwatch behaviour),
  `setKeyframeInterpolation`, `moveKeyframe(clip:parameter:from:to:)`, `removeAnimation` and
  `applyKenBurns(clip:start:end:interpolation:)`, all taking timeline times (the playhead) and refusing
  with reasons (`VEEditErrorKeyframeNotFound` is new, at the end of the enum).
  `VEClipParamsBatch setVideoParams:clearingKeyframesForClip:` is the Video reset.
  `VEClipInfo.videoParams` stays the static values: read `motion(at:)` for what a frame shows.
- JSON schema 4: `"keyframes"` inside a clip's `"video"` object (only when animated; per parameter a
  list of `{time, value, interpolation, curve (bezier only)}`); v3 -> v4 changes nothing but the
  version (golden `project-v4.json`; `project-v3.json` loads unchanged). Unknown interpolations load
  as linear with a warning.
- App: `InspectorModel` (single video clip = `motionTarget`: values at the playhead, keyframe toggle,
  previous/next, interpolation, remove animation; several clips cannot change a parameter one of them
  animates), `KeyframeControls` in the Video rows (the rows observe the playhead only while the clip is
  animated), `KenBurnsModel` (`App/State/KenBurns.swift`: rect <-> framing, limits, swap) with
  `KenBurnsOverlay` on the program monitor (`store.beginKenBurns/applyKenBurns/cancelKenBurns`; closes on
  selection change, clip removal, New/Open), timeline markers (`TimelineViewModel.Clip.keyframes`,
  `Hit.keyframe`, a click seeks; a drag moves the marker's keyframes since "Ken Burns editing" below).
  New edit commands that reach keyframes from
  keys or menus must keep the `isGestureActive` guard.

### Ken Burns range and neighbour matching
- Range: `applyKenBurns(clip:start:end:interpolation:from:duration:)` (timeline start, duration rounded to
  whole frames; the old call is the whole clip). Keyframes on the range's first and last frames; refused
  (InvalidTime) when the range starts outside the clip or runs past its end, (InvalidArgument) under two
  frames. The plan is plain C++ (`planMotionMove` in EditOps, applied with `SetMotionTracks`, one
  SequenceCommand, "Ken Burns"): x/y/scale keyframes the range's frames show are replaced, the rest kept;
  keyframes a trim hid are kept unless the range reaches that end of the clip (so Whole clip replaces
  everything, as before). A kept keyframe whose value differs from the move's adjacent framing
  (`motionValuesMatch`, 1e-6 relative) makes the picture move instead of hold between it and the move:
  the note names the parameters and the keyframe's timecode. The end keyframe is Linear.
  `SetMotionTracks` now accepts a keyframe outside the clip's source range only if the clip already has
  that exact keyframe (hidden ones kept); new ones there are still refused.
- App: `KenBurnsModel.range` (`MoveRange`: whole clip, from playhead, from clip start), `durationText` /
  `commitDuration()` (`DurationFormat.parseFrames`, 2 frames to what is left, `durationNote`, now `rangeNote`),
  `rangeStart`, `rangeDuration`, `rangeTimecodes`, `rangeCaption` ("Holds the end framing until the clip
  ends", or `rangeProblem`). `store.applyKenBurns()` commits a duration being typed first (Return also
  presses Apply; since "Ken Burns editing", Return with text still being typed only commits the field).
  Rectangles the user moved keep their place when the range changes; the others show the
  clip's framing at the range's ends (or the push in). `store.refreshModel()` passes clip changes to the
  open helper (`update(clip:)`).
- Picture: follows the playhead, as in FCP (this replaced "the picture at the range start" from the
  brief): the clip's unanimated frame under the playhead, clamped to its first/last frame
  (`pictureFrame`, `pictureSeconds`, through the clip's speed; 0 for a still). `KenBurnsPictureLoader`
  (`model.picture`) keeps one fetch of its own in flight and fetches the latest wanted time when it
  lands. Since the Motion/Photos review fix round it has its own small cache and no longer uses
  `store.thumbnails` (`cachedImage`/`isFetching(asset:)` are gone): see that section. The overlay
  observes the model, the playhead model and the loader (`.onChange(of: playhead.time)` feeds the model).

- Neighbours: `adjacentClip(of:at:)` (`VEClipEdge` `.start`/`.end`: the clip on the same track ending
  exactly where it starts / starting where it ends; 0 for a gap; plain C++ `adjacentClip` in EditOps) and
  `matchMotion(clip:toAdjacentAt:)`: the neighbour's five Motion values on its boundary frame
  (`Scheduler::motionAt`, what the monitors draw) onto this clip's first/last frame, planned by
  `planMotionAtFrame` and applied as one `SetMotionTracks` ("Match Previous Clip" / "Match Next Clip").
  An animated parameter gets a keyframe on the frame's start (keyframes that frame showed, such as one on
  the out point, give way and lend it their interpolation, so the frame shows the value exactly); a static
  one gets the static value. The note names which. Nothing to change: success, no undo step, "This clip
  already matches ...". Refused: NotAdjacent, TrackKindMismatch, TrackLocked (also for the no-op).
- App: `store.adjacentClip(to:at:)`; `InspectorModel.canMatch(_:)` / `matchAdjacent(_:)` (single video
  clip, `isGestureActive` guard with "Finish the current drag first.", commits a nudge burst first) behind
  the Video section's "Match" menu. `KenBurnsModel.previous` / `next` (`Neighbour`: framing at the cut,
  animated in position/scale), `continuesFromPrevious` / `leadsIntoNext` (on by default when that
  neighbour animates position or scale or its framing there is not the identity; toggling resets that
  rectangle), `neighbourNote` when the framing had to be kept inside this picture. Rotation is not taken
  from the neighbour by the helper (the rectangle is drawn with this clip's rotation); Match copies it.

### Keyframe controls fix and Add Motion Keyframe
- Stale inspector controls (hands-on bug: a diamond that would not toggle off, an interpolation that did not
  stick): `KeyframeControls` held only `let inspector` and `let parameter`, which compare equal after every
  edit, so SwiftUI never re-ran its body. It now draws only from `KeyframeControlState` (Equatable, from
  `InspectorModel.keyframeControlState(_:)`); the model reference is kept for actions. Rule for new views: a
  subview that reads model state must either observe an ObservableObject that publishes the change
  (`@ObservedObject var store`, the playhead model, ...) or take the derived values as stored properties;
  a bare class reference does not redraw it. `InspectorModel` publishes only `message`: views that show
  model values observe the store. Checked: `ParameterRow`, `AnimatedParameterRows` (now `VideoParameterRows`), `ParameterSection`,
  `ClipInfoSection`, `TransitionInspector` and `KenBurnsOverlay` observe what they draw.
- Add Motion Keyframe: `toggleMotionKeyframes(clip:at:)` (`planMotionKeyframeToggle`, one `SetMotionTracks`,
  "Add Keyframes" / "Remove Keyframes"; note "Keyframes added on N parameters" / "Keyframes removed"): keys
  every Motion parameter without a keyframe on the frame (values unchanged), or removes all five when all are
  there (a track left empty keeps the frame's value). App: `store.toggleMotionKeyframes(clip:)`
  (`isGestureActive` guard, single video clip or the clip under the pointer), `KeyboardController.Action
  .toggleMotionKeyframes` on Control-K (handled by the key monitor, so a text field keeps the key; the Clip
  menu item shows "⌃K" in its title like Delete does), and the timeline's clip context menu (disabled
  when the playhead is not over the clip; the title says Add or Remove).

### Ken Burns editing
- Reopening edits the existing move (app only). `KenBurnsModel.detectMove(in:frameDuration:)` (`MoveDetection`:
  `.none`, `.hiddenOnly`, `.move(ExistingMove)`) takes the frames that show the clip's position X, position Y and
  scale keyframes (`VEKeyframe.frameTime`, keyframes a trim hid ignored): two or more frames are a move from the
  earliest to the latest (`first`/`last` counted from the clip's first frame, `hasKeyframesBetween`, and the first
  keyframe's `interpolation` when the helper offers it, else nil and the smoothing stays Ease In and Out). The helper
  then opens with `range == .existingMove` ("Existing move", offered in the Move menu only while the clip has one,
  `rangeChoices`), the rectangles on the framing at the move's first and last frames (`motion(at:)`, the default
  rectangles of a placed clip) and the caption "Editing the move from HH:MM:SS:FF to HH:MM:SS:FF" (+ "; keyframes in
  between are replaced" when position/scale keyframes lie between). Apply goes through the ranged
  `applyKenBurns(clip:start:end:interpolation:from:duration:)` as before, so the move is replaced in place (keyframes
  on its frames replaced, the others kept) and a move made by the helper keeps its keyframe times. Keyframes all on one
  frame, or only rotation/opacity keyframes, are no move (Whole clip, push in or the clip's framing, as before); when a
  trim hid every position/scale keyframe the range is Whole clip and the caption is `hiddenMoveCaption` (Apply then
  replaces them: the whole clip reaches both ends). With an existing move a neighbour toggle is on only where the move
  already continues it (the move reaches that end of the clip with the neighbour's framing), so the rectangles show the
  clip's own framing. `update(clip:)` re-runs the detection on every model change: the Existing move range follows its
  keyframes (a timeline drag, an undo) and falls back to Whole clip when the move is gone. Rotation is kept as before.

- Custom range (app only). `MoveRange.custom` ("Custom", always offered): `startText` / `endText` show the range's
  first and last frames as timeline times (the ruler's: absolute sequence frames) in the user's duration format
  (`durationString`: timecode by default, "150f", "5.00 s"), for every range; `commitStart()` / `commitEnd()` parse
  with `DurationFormat.parseFrames` (the Duration field's parsing: timecode, "4:15", "150f", "5s", a bare number in
  the display's unit). Unchanged text changes nothing; otherwise the range becomes Custom with that end moved and the
  other kept (decision: the fields are always editable, also in Whole clip, From playhead, From clip start and
  Existing move, rather than read-only), limited to the clip's frames and to at least two frames (the engine's
  minimum: the start a frame before the end, or the end a frame after the start); `rangeNote` (was `durationNote`,
  now for all three fields) says what was limited or why text was refused. Choosing Custom in the menu keeps the
  current span; a typed Duration in Custom or Existing move moves the end (the range becomes Custom); the Duration is
  editable in every range but Whole clip. The span is kept in clip frames (`FrameSpan`, from the clip's first frame)
  and clamped when the clip changes. `hasUncommittedText`: a field's text differs from its committed value; the
  overlay then drops Apply's default-button shortcut, so Return commits the field only, and once committed Return
  presses Apply. `store.applyKenBurns()` commits all three fields first (`commitFields()`), so the Apply button takes a
  value still being typed and refuses text that is not a time with the note.

- The range on the timeline (app only). `KenBurnsModel.bandRange` (`KenBurnsBandRange`: clip id, timeline seconds from
  the range's first frame's start to its last frame's end; nil while `rangeProblem` is set) changes only with the
  range; the store forwards it to `store.kenBurnsBand` (`KenBurnsTimelineBand`, `show(_:)` publishes only a change)
  while a helper is open and clears it when `kenBurns` becomes nil (Apply, Cancel, selection change, clip removal,
  New/Open). `KenBurnsBandView` (TimelineView.swift, an overlay of the track area under the playhead line, no hit
  testing) observes the band alone and takes the timeline model as a value from `TimelineView`'s body: a translucent
  accent band over the clip's row, green start edge and flag, red end edge and flag (the overlay's colours);
  `KenBurnsBandView.rect(for:in:)` is its geometry (`x(forTime:)`, the clip's row). A range moving with the playhead
  or with typing redraws that overlay only (`TimelineDiagnostics.kenBurnsBandUpdates`; measured over 21 range changes:
  0 model builds, 0 canvas draws, 21 band updates, `TimelineRedrawTests.testAKenBurnsRangeChangeRedrawsOnlyItsBand`).
  The picture loader no longer goes through the shared `ThumbnailCache` (Motion/Photos review fix round), so pictures
  landing redraw neither the canvas nor the bin (`testKenBurnsPicturesLandingRedrawNeitherTheTimelineNorTheBin`).

- Draggable keyframe markers (engine + app). Engine (`EditOps.h`): `motionKeyframeGroupAt(clip, frameDuration, frame,
  group)` (`MotionKeyframeGroup`: each parameter's keyframe that the frame shows, `keyframeIndexForFrame`, with its
  index; `earliestFrame` / `latestFrame`: a frame after the frame showing the previous keyframe and a frame before
  the one showing the next keyframe of each of those parameters, within the clip's frames; a neighbour a trim hid does
  not limit beyond the clip); refused with InvalidArgument and `crowdedParameter` when a parameter has several
  keyframes on the frame (a sped-up clip), KeyframeNotFound, InvalidTime. `planMotionKeyframeGroupMove` moves each to
  the destination frame's start (`keyframeTimeForFrame`) keeping value, interpolation and curve. `MoveKeyframeGroup`
  (one SequenceCommand, "Move Keyframe"/"Move Keyframes") plans inside `perform`, so in a ReplacePrevious group every
  step is planned against the model before the drag (a plan made in the facade from the live model would find the
  keyframes already moved by the previous step). Facade: `keyframeGroup(clip:at:)` (`VEKeyframeGroup`: frameTime,
  parameters, earliestFrame, latestFrame, `canMove`/`reason`: a locked track, or several keyframes of one parameter
  on the frame; read it before the drag) and `moveKeyframeGroup(clip:from:to:)` (pass the drag's original frame as
  `from` on every step). `MoveKeyframe` (one parameter, source times) is unchanged.
- App: `TimelineGestureController.DragState.movingKeyframes` (group key `timeline.keyframes`, `isGestureActive` via
  `cancelActiveGesture`, Escape/abandon cancel the group): a drag that starts on a marker moves its keyframes (the
  shared frame of a Ken Burns move moves x, y and scale together; a marker with only some parameters moves those),
  horizontally, in whole sequence frames, clamped to the group's frames (only the frames change: no step is pushed
  while the target frame stays the same), with the status line "Keyframe(s) at HH:MM:SS:FF" (+ "as far as it goes"
  when clamped). A click without movement still seeks to the marker and selects the clip. Decision: dragging a
  marker no longer moves the clip; the clip is moved by its body above the markers (the marker zone is the bottom
  11 pt of the row), and Option keeps its meaning (the playhead), so there is no Option-drag clip move from a marker.
  Hovering a marker shows the left-right cursor. The Ken Burns helper's Existing move range follows the dragged
  keyframes (`update(clip:)` re-runs the detection on every step), and so does the band.

## Photos drops (feature request 9)
- Drop types: `MediaDrop.types` = public.file-url plus `UTType.filePromiseTypes` (every
  `NSFilePromiseReceiver.readableDraggedTypes` entry and kPasteboardTypeFileURLPromise, made with
  `UTType(importedAs:)`; the app's imported declarations were removed in the Motion/Photos review fix
  round, see there for the metadata type, which is not a system UTI).
  `TimelineDropDelegate.types` adds them to the in-app types; the media bin uses
  `MediaBinDropDelegate` (replacing `.dropDestination(for: URL.self)`). Both take any
  `TimelineDropInfo`; `handlePerform(_:pasteboardPromises:)` gets the drag pasteboard's
  `NSFilePromiseReceiver`s for a real drop (`PasteboardFilePromise.fromDragPasteboard`) and falls back
  to item providers that carry promise types (`ItemProviderPromise`, what tests and PHPicker use).
- `PromisedFile` (App/State/IncomingMedia.swift): `receive(into:completion:)` (main-actor completion
  with the arrived files, never after `cancel()`), `onProgress`. `IncomingMedia` (`store.incoming`)
  receives a batch into the Media folder, lists it in the bin (`IncomingMediaList`: progress, per-item
  Cancel, Cancel All), imports the batch through `ProjectStore.importMedia` once every item has
  settled, and for a timeline drop places the items where they were dropped, one after another in drop
  order (`ProjectStore.place(imported:from:at:)`, skipped with a message while a gesture is active).
  Receiving starts on the main-queue turn after the drop (the folder question is modal). New/Open
  call `discardAll()` (nothing arriving late reaches the next project).
- Media folder: `ImportedMediaFolder` (`store.mediaFolder`): the stored bookmark, else "Media" next to
  the project file when the app can create it, else (and always for an untitled project) a folder
  panel asked once (`chooseFolder`, injectable). The choice is `VEEngine.mediaFolderBookmark` (new
  facade property, saved in the project file under "mediaFolderBookmark" beside "assetBookmarks";
  setting a different value is an unsaved change, not an undo step; New/Open reset it). The rules
  changed in the Motion/Photos review fix round (only a chosen folder is stored; see there).
- Live Photos: `LivePhotos.pairs(in:)` (a still and a movie with one name) within what one promise
  delivered (since the Motion/Photos review fix round never across the items of a batch); the user
  picks video or still (`askLivePhoto`, "Remember my choice" stored under `livePhotoImport`, shown in
  Settings > Media > Live Photos); the other part, our own copy, is deleted.
- File > Import from Photos… (Shift-Cmd-I): `PhotosImportPicker` (`store.photosPicker`), a
  `PHPickerViewController` sheet (no Photos library entitlement; selection unlimited, images, videos
  and Live Photos, `.current` representation so HEIC/HEVC arrive as they are); results go through
  `ItemProviderPromise` into `store.incoming` like a drop.
- Finder file drops on the timeline are now imported and placed like a Photos drop (they used to be
  refused); `TimelineGestureController.placement(at:insert:)` computes the row and time;
  `TimelineGestureController.store` is no longer private.
- Media: HEIC stills and HEVC video import through the existing Apple paths; slow motion (VFR) pictures
  come from `playback::pictureTimeFor`. Test media gained `slowmo_hevc_portrait.mov` (HEVC, rotated 90,
  30 fps around a 240 fps section; `slowmoFrameTime` / `slowmoFrameAt` in TestMedia.h), which
  regenerates the generated test media once.

## Motion/Photos review fix round (2026-09-24 review; report in git history at b9add9f)
- Keyframe inserts (engine). `insertKeyframeKeepingValues(track, staticValue, time)` (Keyframes.h) adds a
  keyframe that changes no value: inside a segment it divides it exactly like a split (`splitTrack`, the
  boundary once): a hold stays a hold, a linear segment linear, an eased or custom segment becomes its two
  exact `Bezier` parts (the inspector shows "Custom"); before the first keyframe, after the last or on an empty
  track it is `Linear`. `AddKeyframe` (its interpolation is now optional), `SetMotionValue`'s add path,
  `planMotionKeyframeToggle` and `planMotionAtFrame` insert through it and apply an explicit value or
  interpolation afterwards. A keyframe whose inherited value is outside the parameter's range (a custom curve
  from a file that overshoots) is refused with InvalidArgument, as is a split through it. Use it for any new
  way of adding keyframes.
- Values on frames. `planMotionValueAtFrame(clip, fd, frame, parameter, value, change)` (one SetMotionTracks
  change) puts a value on the frame's start, the frame's other keyframes giving way and lending the last one's
  interpolation (`planMotionAtFrame` now lends the last one's too). The facade's `setMotionValue` uses it when
  the keyframe the frame shows is not on the frame's start (a split's out point, a sped-up clip), so a nudge
  shows exactly what was typed.
- Evaluation time. `motionTimeAt(clip, t)` (Clip.h) is the exact source time, or the next kPreciseTimescale
  tick when it has no CMTime form (where `keyframeTimeForFrame` puts a keyframe); `motionValuesAt(clip, t)` is
  what `Scheduler::motionAt`, `VEClipInfo motion(at:)`, Remove Animation and the toggle evaluate. Evaluate
  Motion only through these.
- Validation. `TimingCurve::isValid` requires x1 <= x2 (a few ulps); non-custom keyframes must carry the
  default curve. SetVideoParams, SetClipsParams and placements refuse keyframes on an audio clip
  (TrackKindMismatch) and new ones outside the clip's used source range (InvalidTime), like AddKeyframe.
  `isThroughEdit` is false for two pieces of an animated still. JSON warns on an unknown Motion parameter and
  on a curve on a non-custom keyframe; an unreadable "mediaFolderBookmark" loads with a warning.
- Facade. An out-of-range `VEMotionParameter` is refused (InvalidArgument); `VEClipInfo` returns NO/empty/nil
  for it. The Motion refusals include NotRepresentable (its message says where). `moveKeyframeOfClip` is not
  for drags (use `moveKeyframeGroupOfClip`).
- Ken Burns picture loader (app). `KenBurnsPictureLoader(assetID:engine:capacity:)` (or `fetch:` for tests)
  calls `engine.thumbnail` itself and keeps at most `capacity` (6) pictures, least recently shown out; only the
  overlay observes it. Each landed picture is shown before the latest wanted time is fetched; a failed fetch
  re-drives it; memory pressure keeps the picture on screen only. Large or transient images belong in a cache
  of their own, never in `ThumbnailCache` (whose landings redraw the timeline and every bin tile).
  `MediaBinDiagnostics.tileBodies` counts bin tile bodies for redraw tests.
- Pasteboard promise contract (app). `PasteboardFilePromise` works over `FilePromiseReceiving`
  (`NSFilePromiseReceiver` conforms; tests use a double). Every receiver of one drag delivers into one hidden
  staging folder (`PromiseDropSession`, AppKit requires one destination); each reader call settles on its own
  (`FilePromiseDelivery`: the file is moved into the Media folder at once, or deleted when the delivery was
  stopped); completion comes at `fileTypes.count` calls, later calls are handed over (`onLateFiles`, imported
  into the bin, deleted when the project changed); cancel, and releasing a promise that is still receiving,
  delete what arrived at once. `PromisedFile` gained `onRename`, `onLateFiles` and `securityScope` (defaults in
  an extension). A real drop is partitioned once from the drag pasteboard's items (`DragContents`: a file URL
  wins, promises of non-media types are refused); providers are partitioned once each otherwise.
  `ReceivedFiles.adopt` is thread safe (one lock, retry on a taken name) and sanitizes names; `adoptItem`
  unpacks a Live Photo bundle into its parts. `com.apple.NSFilePromiseItemMetaData` is a pasteboard type,
  not a system UTI (`UTType("com.apple.NSFilePromiseItemMetaData")` is nil once no bundle declares it): the app
  must never rely on `UTType(identifier)` for it, only on `UTType.filePromiseItemMetadata` (`importedAs`);
  conversely `UTType(importedAs: "com.apple.live-photo-bundle")` returns a private system type
  ("com.apple.private.live-photo-bundle", not equal to the public one), so `UTType.livePhotoBundle` is the
  system lookup (falling back to `importedAs: ..., conformingTo: .package`) and registered identifiers are
  compared with `UTType.livePhotoBundleIdentifier`.
- Media folder rules (app). `ImportedMediaFolder` makes "Media" (with a `.framewright-media` marker) next to
  the project or inside a folder the user chose; an existing Media folder is adopted only with the marker
  ("Media 2" otherwise). Only a chosen folder is stored (`VEEngine.mediaFolderBookmark`); the one next to the
  project is derived from `projectURL` every time. `ProjectStore.save(to:)` calls `projectWillMove(to:)`, which
  drops a stored folder that is the Media folder next to the old location on a Save As elsewhere. A stored
  folder in the Trash is forgotten, a stale bookmark rewritten. Its security scope is a `SecurityScopeLease`
  that promises still receiving keep alive past New/Open.
- Arriving media (app). `IncomingMedia.Placement.changeCount` is recorded at the drop (and again after the
  folder question); `ProjectStore.place(imported:from:at:timelineChanged:emptyRangeOnly:)` leaves the media in
  the bin with a message when the timeline changed, a gesture or nudge burst is open, the track is gone or the
  engine refuses it; Photos items (`emptyRangeOnly`) insert when the drop point is no longer empty. Live Photo
  questions queue (one at a time) and wait while `isGestureActive`. A received file the import refuses is
  deleted. `IncomingMedia.isReceiving` also covers batches waiting for their question; `arrivingCount`.
- Documents (app). `DocumentController.confirmStoppingIncomingMedia(because:)` ("Media from Photos is still
  arriving": Stop / Keep Waiting) runs in `confirmDiscardingChanges(because:)` (New, Open, Open Recent, window
  close) and `shouldTerminate`; Stop calls `incoming.discardAll()`.
- Settings for Live Photos (app). Settings > Media > Live Photos (`LivePhotoImportSetting`: ask, video, still)
  is bound to the `livePhotoImport` key "Remember my choice" writes; `LivePhotos.makeAlert` names it.
- PHPicker (app). `PhotosImportPicker` is observable (`isPresenting`; File > Import from Photos… is disabled
  while it shows); a picker whose sheet went away without its delegate no longer blocks it; picks are received
  on the next main-queue turn (`finishPicking`), after the sheet has gone.
- Ken Burns UI (app). The Start/End/Duration fields keep what is being typed through model changes
  (`KenBurnsModel` remembers each field's committed text); `hasUncommittedText` compares trimmed text; equivalent
  text keeps the range; a duration typed with the playhead off the clip is refused. Presses on the overlay go
  to one drag layer (`KenBurnsHit.target(at:start:end:)`: corners, labels, edges, inside; coinciding rectangles
  share their handles) with a `@GestureState`; `applyDrag` ignores a drag that has not moved. The helper stays
  open when Ken Burns… is pressed again on its clip, closes on a multi-selection and follows the duration
  display preference (`durationDisplay` is now settable).
- Motion UI (app). Control-K ignores auto-repeat. The Clip menu's Add/Remove Motion Keyframe item is its own
  view observing the playhead (`MotionKeyframeMenuItem`, `store.motionKeyframeMenuState(at:)`). The inspector's
  Video rows are one view (`VideoParameterRows`) whatever the clip's animation. In the marker zone a trim edge
  nearer than the marker keeps the press.
- Test media. Generated media directories hold the script's hash (`.script-hash`); `FRAMEWRIGHT_TEST_MEDIA_DIR`
  is regenerated when incomplete or outdated (`testMediaIsComplete`); older versions are pruned
  (`pruneTestMediaVersions`); the slow-motion clip's frame times are in the manifest (`frameTicks960`).


## Effect lanes round 1 (engine; plan `docs/plans/2026-09-24-effect-lanes.md`)
- Model (schema 5; `Engine/Model/EffectSpan.{h,cpp}`, `Clip.h`, `Transition.h`, `Sequence.h`). A clip's
  `spans` are `EffectSpan { id (SpanId), lane 0-3, kind (Transition, Motion, Opacity, Gain), start, end, edge,
  transition, tracks }`, sorted lane 0 (head, tail) then lanes 1-3 by start. Effect spans (lanes 1-3; Motion
  and Opacity on video clips, Gain on audio clips) cover `[start, end)` in the clip's source-time base (a
  still's: time into the clip), so trims cut them (`clipSpan`, the value at a new edge evaluated exactly;
  extending does not restore), speed changes carry them with their pictures and a split divides them exactly
  (`splitSpan`: the left part keeps the id, the right part gets a new one; a span wholly on one side keeps
  its id). Their `tracks` hold keyframes of their kind's parameters only, times relative to `start`
  (normally one at 0 and one at the length). Values are relative: x, y and rotation add to the clip's static
  values, scale and opacity multiply, gain adds dB; neutral values (0, 1, 0 dB) change nothing.
  `VideoParams` is the static values only; `AudioParams` is `gainDb` only (fades are lane-0 spans).
- Activity: a span acts where the frame's evaluation time (`spanEvaluationTime`: the exact source time, or the
  first kPreciseTimescale tick after it; held at the clip's edges in transition handles) is in `[start, end)`,
  plus the out bound itself for a span ending there (a tail handle keeps its end value). The end value is
  reached at the span's end: the span's last frame shows the move a frame short, so a move ending on a cut
  continues into a span starting there without repeating a framing. Composition (`composeMotion`,
  `motionValuesAt`, `composeGainDb`, `gainDbAt`) applies lanes 1, 2, 3 in order; `Scheduler::motionAt` and
  the facade's `motion(at:)` return `motionValuesAt`.
- Transitions (lane 0, kind Transition; `TransitionRole` CrossDissolve / FadeOut / FadeIn from
  `placeTransition`): offsets in sequence time from their edge. A tail span `[-before, after]` around its
  clip's end: `after > 0` crosses into the clip touching that end (a cross dissolve / constant-power
  crossfade, shares = the split at the cut), `after == 0` is a fade out to black / silence. A head span
  `[0, length]` is a fade in, allowed only where no clip touches the start (the cut belongs to the outgoing
  clip). At most one per edge; a head fade and the tail span may touch but not overlap; `transitionLimit`
  and `transitionSideLimits` bound each side by the handles, the clips' lengths and the neighbouring
  transitions. Linked A/V dissolves keep the same range relative to their cuts (`linkedTransition`). The
  mix is sampled at frame centres (`frameCentreFraction`); fades are one layer weighted `mix` / `1 - mix`
  over black. Audio: `AudioSegment::level` (a `DecibelRamp`, linear in dB; eased Gain spans are followed in
  steps of at most `Scheduler::kEasedGainStep`, 5 ms), `fade` (linear gain) and `crossfade` (progress,
  constant power in the mixer).
- Validation (`effectSpanProblem`, `checkTransitionSpan`, `validateClip`): lanes and kinds, one transition
  per edge, no overlap within a lane, spans inside `spanBounds()`, lane and time order, unique span ids.
- Migration v4 -> v5 (`migrateV4ToV5`): Motion keyframes become a Motion span on lane 1 (x, y, scale,
  rotation) and opacity keyframes an Opacity span on lane 2 (lane 1 when there is no Motion span), each over
  the clip's whole source range with the tracks re-based and cut exactly at the clip's edges (a hold before
  the first or after the last keyframe then renders as before); the animated static values become neutral.
  Audio fades become lane-0 spans (dropped with a warning when another clip touches the start; dropped
  silently on an edge with a crossfade, which version 4 ignored; a fade in shortened, with a warning, to leave
  room for a crossfade at the clip's end; video fades never sounded and are dropped). Transitions keep their
  ids as centred tail spans of their outgoing clip. New span ids come from `nextId`. Proven by
  `MigrationRenderTests.cpp`: every frame's layers and every 1/240 s's gains of the golden v4 project and
  `project-v4-render.json` equal what the schema-4 engine recorded (`*.expected.json`).
- Edit ops (`EditOps.h`; single `SequenceCommand`s, coalescing keys `spanRange:<id>`, `spanValues:<id>`,
  `spanInterpolation:<id>`, `spanLane:<id>`, `transitionRanges:<ids>`): `AddSpan` (neutral values, so no frame
  changes), `SetSpanRange` (a move keeps keyframes, a trim stretches them), `SetSpanValues` (optionally with
  an interpolation: the Ken Burns step), `SetSpanInterpolation`, `MoveSpanLane`, `RemoveSpans`,
  `AddTransitionSpans`, `SetTransitionRanges` (`durationChange` names it "Change Transition Duration(s)");
  refusals carry `EditError` and a reason; an overlap sets `EditResult::freeRange` (`nearestFreeRange`).
  `planKenBurns` / `spanEdgeMotion` (Clip.h) are inverses; `planMatchSpanEdge`; `setClipFade` /
  `clipFadeLength` for the audio fades. `EditResult::droppedSpanIds` lists effect spans an edit removed as a
  side effect; `droppedTransitionIds` transitions.
- Facade: `VEEffectSpan` (`spanID`, `clipID`, `trackID`, `lane`, `kind`, clip-relative and timeline ranges,
  `startValues` / `endValues` (`VESpanValues`, NaN where not animated), `interpolation`, transition style,
  shares and partner, `linkedSpanID`); `spans(forClip:)`, `spans(forTrack:)`, `spanInfo`,
  `laneCount(forTrack:)` (highest used lane + 1, at least 1), `addSpan(kind:lane:clip:range:)`,
  `setSpanRange(_:range:)`, `setSpanValues(_:start:end:)`, `setSpanInterpolation(_:interpolation:)`,
  `moveSpan(_:toLane:)`, `removeSpan(_:)`, `matchSpanEdge(_:toAdjacentClipAt:)`,
  `applyKenBurns(span:start:end:interpolation:)`, `addTransition(at:of:duration:options:)`,
  `setTransitionRange(_:range:includingLinked:)`; `VEClipInfo.spans`, `hasEffectSpans`, `motion(at:)`,
  `gainDb(at:)`, `getMotion(_:atEdgeOfSpan:atEnd:frameDuration:)` (the framings a Ken Burns move set);
  `VEEditResult.span`, `freeRange`, `droppedSpanIDs`; `VEEditErrorSpanNotFound`. Every call asserts the main
  thread and pushes one command. The keyframe API (`VEKeyframe`, `VEKeyframeGroup`, add/remove/move
  keyframe, `setMotionValue`, the ranged Ken Burns call) is gone.
- App spots changed mechanically (round 2 replaces them): the inspector's Video rows edit static values and
  its keyframe controls are inert (`InspectorModel.keyframesMovedMessage`); Add Motion Keyframe (Control-K,
  Clip menu, timeline context menu) is disabled or refuses with that message; no keyframe markers are drawn
  and a marker drag starts nothing; the Ken Burns helper applies to the clip's Motion span over exactly its
  range, or adds one on the first lane with room (`addSpan` then `applyKenBurns(span:)` in one Accumulate
  group, whose undo step is named after its first edit, "Add Motion Span"), reads an existing move's
  framings from the span's edges, and its caption for a move ending before the clip says the clip returns to
  its own framing (spans act over their range only).
- Round 2 needs: lanes in the timeline (`laneCount(forTrack:)`, `spans(forTrack:)`), selection, drag, trim
  and Delete of spans with coalescing groups and `freeRange` for refusals, the inspector's span section
  (start / end values, interpolation, match), the Ken Burns editor on a lane range, transitions on lane 0
  with independently draggable edges (`setTransitionRange`), fades on video clips (the engine and exports
  support them; the app has no control yet).
