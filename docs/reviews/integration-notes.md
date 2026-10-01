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

## UX round fixes (report in git history at c55f96a)
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

## Motion/Photos review fix round (2026-09-24 review; report in git history at 3fcd6ac)
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


## Effect lanes round 1 (engine; plan `docs/plans/2026-09-24-effect-lanes-done.md`)
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
- Activity (superseded by the hold-after rule of "Effect lanes round 1b" below; `spanActiveAt` is gone): a span
  acts where the frame's evaluation time (`spanEvaluationTime`: the exact source time, or the
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
- App spots changed mechanically (round 2 replaced them; see "Effect lanes round 2"): the inspector's Video
  rows edit static values and its keyframe controls are inert (`InspectorModel.keyframesMovedMessage`); Add Motion Keyframe (Control-K,
  Clip menu, timeline context menu) is disabled or refuses with that message; no keyframe markers are drawn
  and a marker drag starts nothing; the Ken Burns helper applies to the clip's Motion span over exactly its
  range, or adds one on the first lane with room (`addSpan` then `applyKenBurns(span:)` in one Accumulate
  group, whose undo step is named after its first edit, "Add Motion Span"), reads an existing move's
  framings from the span's edges, and its caption for a move ending before the clip says the clip returns to
  its own framing (spans act over their range only; round 1b changed both: the end framing holds).
- Round 2 needs: lanes in the timeline (`laneCount(forTrack:)`, `spans(forTrack:)`), selection, drag, trim
  and Delete of spans with coalescing groups and `freeRange` for refusals, the inspector's span section
  (start / end values, interpolation, match), the Ken Burns editor on a lane range, transitions on lane 0
  with independently draggable edges (`setTransitionRange`), fades on video clips (the engine and exports
  support them; the app has no control yet).

## Effect lanes round 1b (engine: hold after)
- The rule (the user's decision; always on, no toggle, no model field, schema unchanged): an effect span (lanes
  1-3: Motion, Opacity, Gain) contributes nothing before its start, animates over `[start, end)` and holds its
  end value from its end until the clip's end, also in a tail transition handle (the evaluation time is held at
  the out bound there). A later span on the same lane does not end the hold: its relative values apply on top of
  the held value (chained spans are cumulative; one that starts neutral continues without a jump, one that starts
  elsewhere jumps by its start values). Lane-0 transitions are unchanged. Reference case (tested frame by frame
  and exported): a 30 s clip with a 5 s Ken Burns move from 5 s to 10 s shows its own framing for 0-5 s, the move
  over 5-10 s and exactly the end framing for 10-30 s.
- Composition (`Clip.h` "Composition"; `composeMotion`, `composeGainDb`, `motionValuesAt`, `gainDbAt`): at
  evaluation time t every effect span with `start <= t` (`spanActsAt`) contributes its value at `min(t, end)`
  (`spanContributionAt`: `spanValueAt` inside, `spanEdgeValue(atEnd)` from the end on); the contributions are
  applied to the static values one after another, lanes 1, 2, 3 and within a lane in start order: Position X/Y
  and Rotation offsets add, Scale and Opacity factors multiply, Gain decibels add to the static gain. "On top of"
  means exactly this, across spans of one lane as across lanes. Evaluation stays exact-time
  (`spanEvaluationTime`). New in `EffectSpan.h`: `spanActsAt`, `spanContributionAt`, `spanContributionFromLeft`
  (the limit from the left: neutral up to the start, the ramp up to the end, the hold after it).
  `spanActiveAt(clip, span, time)` is removed; use `spanActsAt(span, time)` (a span now acts from its start on,
  with no special case for the out bound).
- Audio (`Scheduler::audioGraphFor`): a segment's `level` adds each started Gain span's contribution at the
  segment start and its limit from the left at the segment end, so a held level is a flat segment and a chained
  span ramps from the held level. Segments are still cut at span edges and keyframes; `kEasedGainStep` steps only
  inside eased segments (a held part is one segment). Playback and the offline renderer share it (parity tests).
- Trims and splits (`Clip::fitSpans`): a span left wholly before a clip's new start (`end <= in bound`: a head
  trim past it, the right piece of a split or an overwrite) used to vanish, which would now change the frames
  after it. Its held value is folded into the clip's static values (`video` / `audio.gainDb`, composed in the
  composition's order, so a single lane's hold is kept to the bit) and the span goes (still reported in
  `EditResult::droppedSpanIds` / `VEEditResult.droppedSpanIDs`, like before). No remaining frame changes; a later
  head extension shows the held framing, not the old move (extending never restores spans). New
  `RetimeResult::HeldValuesOverflow` (non-finite folded values, only from pathological files) refuses the edit
  with InvalidArgument. Round 2 must expect a clip's static values to change after such an edit (the inspector's
  Video section shows them) and may want to name it in the note it shows for dropped spans.
- Ken Burns edges (`spanEdgeFrameTime`, `spanEdgeMotion`, `planKenBurns`, facade
  `getMotion(_:atEdgeOfSpan:atEnd:frameDuration:)` and `applyKenBurns(span:...)`): unchanged code, but "the rest
  of the composition" at an edge now includes held values, of the span's own lane too. So the start edge of a
  span that follows another on its lane reads that span's held end framing, and a Ken Burns move from that
  framing gets neutral start values (continues without a jump). The plan and the read-back use the same
  `composeMotion(except: span)` at the same times, so they remain exact inverses (tested for a lone move, a move
  over another lane's held zoom, and two chained moves on one lane). The end framing is reached at the span's end
  and is what every later frame shows while nothing else changes (on those frames `motionValuesAt` equals
  `spanEdgeMotion(atEnd)` bit for bit).
- Consequence for editing (round 2's Ken Burns editor and inspector): span values are relative and cumulative,
  so changing an earlier span's end values (or removing it, or moving it past another) moves the picture of every
  later span on the clip, which keeps its own relative values: a second Ken Burns move applied on top of a held
  zoom of 2 stores scale 0.75 for a 1.5 end framing, and still shows 0.75 x the new held value after the first
  move is edited. The editor should re-read `getMotion(_:atEdgeOfSpan:...)` for the later spans' rectangles after
  such an edit rather than cache framings.
- Matching (`planMatchSpanEdge`, `matchSpanEdge(_:toAdjacentClipAt:)`): a span now contributes at an edge frame
  when it has started there. At the tail, a span that ended before the clip's last frame holds its end value
  there, so matching the next clip sets that end value and the last frame shows the neighbour's exactly (before,
  this was refused). Refused (InvalidArgument) only for a span that starts after the frame ("starts after the
  first/last frame of clip N"); at the head that is any span not starting on the clip's first frame.
- `matchMotion(clip:toAdjacentAt:)` (static values) composes the spans onto neutral static values through
  `motionValuesAt`, so it takes held values into account without change.
- Migration: v4 migrated spans cover the clip's whole source range, so nothing is ever held inside a clip and
  the tail handle already showed the end value: `MigrationRenderTests` passes against the unchanged goldens.
  JSON is unchanged (schema 5).
- App (minimal; round 2 rebuilds it): `KenBurnsModel.holdCaption` is "After the move its end framing holds until
  the clip ends or the next move starts"; the Move menu's help and the model's doc say the same. The helper's
  default rectangles come from `motion(at:)`, so after a move they show the held framing, and a second move
  applied from the playhead starts there (AppTests updated).

## Effect lanes round 2 (app; plan `docs/plans/2026-09-24-effect-lanes-done.md`)
- Facade addition (engine): `VEClipInfo getBaseValues(_:underSpan:atEnd:frameDuration:)` (`VESpanValues`): what the
  rest of the clip composes to under an edge of an effect span, at the instants `getMotion(_:atEdgeOfSpan:)` reads
  (`composeMotion` / `composeGainDb` with the span left out at `spanEdgeFrameTime`), the fields of the span's kind set,
  the others NaN; NO for a transition, an unknown span or a non-positive frame duration. It exists because the
  composed value alone cannot be inverted for a factor at 0 (a fade from 0 shows 0 whatever the base).
  `VEEngineSpanTests.testBaseValuesUnderASpanEdgeInvertTheComposition`.
- Absolute and relative (app, `App/State/SpanEditing.swift`): the inspector, the readout and the Ken Burns editor show
  what an edge shows, never the stored value: absolute = base + relative for Position X/Y, Rotation and Gain, base x
  relative for Scale and Opacity (`SpanValueMath`, `SpanEdge`, `ProjectStore.spanEdge`); a typed or dragged value goes
  back as relative = absolute - base, or absolute / base (`ProjectStore.relativeValue`, `setSpanValue`,
  `relativeFraming` for a Ken Burns framing). Limits: a factor is at least 0; an Opacity span is a factor 0...1, so its
  absolute value is limited to the base (the note says so); a factor over a base of 0 is refused. Everything is read
  from the clip on every use (the views observe the store; the editor re-reads on every model change), since span
  values are relative and cumulative (round 1b): an edit of an earlier span, an undo or a trim changes what a later
  span shows while its stored values stay.
- Selection: `ProjectStore.selectedSpanID` (effect spans and transitions; `selectedTransitionID` is now computed: the
  selected span when it is a transition, and setting it selects that span). Exclusive with the clip selection:
  selecting a span empties `selection`, selecting a clip clears the span; a click on an empty lane clears both.
  `select(span:)`, `selectedSpan`, `selectedEffectSpan`. Delete removes the selected span (`removeSpan`: one undo step; a
  transition with its linked one as before); `canDelete` counts it. A span that disappears is deselected in
  `refreshModel`.
- Timeline model: `TimelineViewModel.Span` (id, clip, track, lane, kind, timeline start/end, transition style and cut),
  `model.spans`, `Track.lanes` / `lanesCollapsed`, `TrackLayout.rowHeight` (the clips' row; `height` is the row plus its
  lanes), `laneY(_:)`, `lane(atContentY:)`, `laneRect`, `rect(forSpan:)` (effect spans clipped to their clip,
  transitions across their cut). `lanes(hasClips:spans:collapsed:revealTransitionLane:)`: none for an empty track or
  collapsed lanes; lane 0 with a transition or while a transition is dragged over the timeline
  (`ProjectStore.revealTransitionLane`); effect lanes 1 up to the highest used plus one, at most 3; `laneHeight` 14.
  Hits: `.span`, `.spanHead`, `.spanTail`, `.lane(track:lane:)` (the transition strip, `.transition*`, `.fadeIn/Out`
  and `.keyframe` are gone). Snapping: `snap(_:excluding:excludingSpans:)`; span edges are candidates only when
  `excludingSpans` is given (span drags), so clip drags snap as before. The model cache key is the change count, the
  collapsed tracks, `WindowLayoutModel.collapsedLaneTracks` and the revealed transition lane
  (`TimelineRedrawTests.testWithLanesAPlayheadTickBuildsNoModelAndASpanEditOne`: 0 builds for 60 playhead ticks, 1 for a
  span edit). Lane collapse is remembered by the track's kind and number ("V1", `WindowLayoutModel.laneKey`), not by
  id (ids restart per project); the header's disclosure collapses an empty track's row or a track's lanes
  (`ProjectStore.toggleDisclosure`).
- Gestures and group keys (`TimelineGestureController`): `timeline.span.move` (body), `timeline.span.trim` (edges),
  `timeline.transition` (a transition's edges or its bar, `setTransitionRange` with `includingLinked` from
  `resizesLinkedTransitions`), each a Replace group, one undo step, Escape/Undo cancel through `cancelActiveGesture`,
  the status line showing the range, the shares ("Cross Dissolve: 5f before / 11f after the cut (31% / 69%)") or the
  refusal with the engine's `freeRange` (`ProjectStore.spanRefusalText`). A range drag on an empty effect lane is
  drawn by the controller (`creation`) and added on release (`ProjectStore.addSpan`, an Accumulate group `span.add`:
  the span and its defaults are one undo step named after the add); under two frames nothing. Option on a lane means
  an Opacity span, not the playhead. A fade in's start stays on its clip's start (its bar and left edge do not drag).
- Defaults (`ProjectStore.addSpan`): Motion: the Ken Burns push in, relative start neutral (the framing the clip has
  there: no jump at the span's start) and end scale 1.25 (80 % of the start framing around the same point), Ease In
  and Out; Opacity: 1 -> 0 touching the clip's end, 0 -> 1 at its start, else 1 -> 1; Gain: 0 -> 0 dB. Without a
  lane the first with room is used ("No effect lane of “x” has room there: ..." otherwise).
- Commands: Control-K and Clip > Add Motion Span at Playhead (`addMotionSpanAtPlayhead`: the selected video clip, the
  selected span's clip, else the top-most video clip under the playhead; 5 s or to the clip's end; at least two
  frames; refused with the reason; `KeyboardController.Action.addMotionSpan`, repeat ignored). The span context menu:
  Set Interpolation and Move to Lane (submenus: `ContextMenuItem.submenu`, `isChecked`), Remove. The clip menu adds
  Add Motion Span at Playhead. `moveSpan(_:toLane:)`, `setSpanInterpolation`, `matchSpanEdge`, `canMatchSpan` (a clip
  touches that edge; for the start the span starts on its clip's first frame), `setSpanRange(_:start:end:typed:)`
  (limited to the clip and to the free space of its lane around it, `spanLimits`; the typed edge gives way when the
  span would be shorter than a frame; the note says what was limited), `setTransitionRange`, `addFade(at:of:frames:)`
  (a fade on that clip only, not its linked partner). All refuse during `isGestureActive`.
- Drops: transitions from the Effects tab land on the nearest cut or free clip edge within 40 pt (a cross dissolve /
  crossfade per the linked preference, or `addFade`), lane 0 shown while dragging (`transitionDragUpdated` reveals,
  `transitionDragExited`/`dropTransition` hide). New drag types `com.justjohn12345.framewright.effect.fade` and
  `...effect.gain` (`EffectKind`, `EffectReference`, declared in project.yml): a span of the default transition length
  from the drop point (moved back to end on the clip's end when it would run past it) on the lane under the pointer, or
  the first free lane when dropped on the clip or lane 0 (`effectDragUpdated`, `dropEffect`, `EffectDropTarget`).
- Inspector (`InspectorModel`, `SpanInspector`): the span section replaces the keyframe controls (removed with
  `KeyframeControlState`, `keyframesMovedMessage` and the playhead-following Video rows): kind, clip and lane, Start /
  End / Duration (timeline times in the duration format; the end is where the end values are reached), interpolation
  (Custom shown, not choosable), lane, per parameter Start and End values (absolute; typed with or without the unit,
  nudged in Accumulate bursts `inspector.span.<id>.<parameter>.<edge>`), Match Previous Clip's End / Match Next Clip's
  Start, Ken Burns… (Motion) and Remove. A transition shows what it does (cross dissolve / crossfade, fade in from or
  out to black / silence) and, for a cross dissolve, the share of each side in percent (`commitShare`, `nudgeShare`:
  the duration stays; `transitionShares`). The Video section keeps the static values with a note when spans compose
  onto them.
- Ken Burns editor (`KenBurnsModel`, now per span): opens when a Motion span is selected (`ProjectStore.syncKenBurns`,
  run on every selection and model change; pauses playback), switches with the selection, closes when the selection
  is no Motion span, and on Escape without a drag or its Close button (`closeKenBurns`; the span stays selected, a
  click on it or Ken Burns… reopens: `showKenBurns(span:)`). Live contract: `applyDrag` opens the Replace group
  `kenBurns.drag` on the first movement (`beginDrag`, refused during another gesture), sets
  `cancelActiveGesture` (Escape and Undo cancel through the group), converts each step's rectangle to a framing and
  that to relative values over the base read when the drag began, and writes `setSpanValues`; `endDrag` ends the
  group (one undo step "Change Span Values"); the overlay reverts a drag the system abandons. No Apply or Cancel.
  The range fields go through `setSpanRange`; Smoothing through `setSpanInterpolation`; Swap is one `setSpanValues`;
  the neighbour toggles are derived from the framings (on: `matchSpanEdge`; off: that edge neutral), "Continue from
  previous clip" only for a span starting on its clip's first frame. The picture is clamped to the span's range
  (`pictureFrame`). The rectangles are re-read from `getMotion(_:atEdgeOfSpan:)` on every model change (never cached).
  The caption is `KenBurnsModel.holdCaption` when the span ends before its clip. Removed: the range menu, existing-move
  detection, Duration/From-playhead logic, `hasUncommittedText`, the timeline band (`KenBurnsTimelineBand`,
  `KenBurnsBandView`), `beginKenBurns`/`applyKenBurns`/`cancelKenBurns`. An Opacity or Gain span shows `SpanReadout`
  on the program monitor instead (start -> end, absolute, and its range).
- Test plumbing: `VEEnginePlaybackTests.testPlayStartLatencyThroughTheFacade` logs its measurement and skips when the
  default output device is Bluetooth (CoreAudio `kAudioDevicePropertyTransportType`) or `stats.outputLatency` is above
  40 ms (`kLatencyTestMaximumOutputLatency`); EngineTests links CoreAudio. The keyframe-era app test files are
  replaced: `EffectLanesTimelineTests`, `KenBurnsEditorTests`, `InspectorSpanTests`, `StaticMotionTests`.

## Effect lanes review fix round (report in git history at fea82c0)
Closed: C1 (app side only), H1-H4, M1-M8, L1-L11, D2 and test gaps 1-6 (except re-recording the render goldens:
their tool needed the schema-4 engine; test gap 3's two cases are checked against version 4's rule computed
independently instead). Not started, per the brief: D1 (compact rows), D3 (window frame restore), the engine crop.
- C1, the crop caveat (user decision pending). The Ken Burns editor now frames a clip placed smaller, off centre or
  turned inside its own window: `KenBurnsModel.windowFraming(_:in:)` expresses an edge's composed motion M relative to
  the clip's static framing S (Φ = (R(-θs)(xm - xs, ym - ys) / ss, sm / ss, θm - θs)), the rectangles come from
  `rect(for: Φ)`, and a dragged rectangle goes back through `absoluteFraming(_:in:)` (M' = (xs + ss R(θs) Φ'.xy,
  ss Φ'.scale)) and `ProjectStore.relativeFraming`. `clipWindow` / `clipWindowCorners` / `windowCaption` ("Inside the
  clip's framing: 30 %, lower right") draw the dashed outline and its caption; `startFraming` / `endFraming` are the
  on-screen framings (S included); `startRotation` / `endRotation` are the rotation inside the window. Identity statics
  give the old math. The engine still has no crop: a zoom in on a picture in picture enlarges it about its centre
  (the default push in grows a 0.3 clip to 0.375) instead of cropping inside its box. A true crop needs a window quad
  on `VideoLayer` from `Scheduler::motionAt` that the compositor scissors to, motion spans composing in window space,
  the v4 migration dividing animated positions by ss on non-neutral statics (with a render test) and a static crop
  field for `fitSpans` (schema 6).
- `KenBurnsModel.span`, `clip`, `staticFraming` are published from `update` (L2). `dragCancelled`: set by
  `cancelDrag` (and when an edit ends the drag's group), honoured by `applyDrag` until `endDrag` (the release) or
  `gestureAbandoned` (the overlay calls it when its `@GestureState` resets) (H2). `KenBurnsModel.problem(span:clip:
  asset:sequence:)` says why the editor cannot open; the store remembers the span it failed on
  (`kenBurnsOpenFailures` counts) and tries again only when the selection changes or `showKenBurns` asks (L8).
- Migration (H1): a v4 fade out with an incoming crossfade is limited to duration - ceil(n/2) of that crossfade's
  frames (or dropped), with a warning, as the fade in already was. Loading (M8): `projectFromJson` repairs before
  `validateProject`, each with a warning: clips and spans sorted; a transition off lane 0 put on lane 0; an effect span
  off lanes 1-3 or overlapping an earlier span of its lane (file order) moved to the first effect lane where it
  overlaps nothing (the composition's operations commute, so the picture is unchanged); invalid transitions pruned
  (`pruneInvalidTransitions`, Validation.h, shared with `normalizeSequence`, with a sentence per removal). Refused:
  no effect lane with room, any inexact time in the sequence (then nothing is repaired), a keyframe without a value.
  The app shows the load warnings also when media is missing (L11).
- Edits (engine): `SequenceCommand::apply` records every dissolve's partner before `perform` and, before normalizing,
  removes one whose partner changed (a ripple delete, an insert or an overwrite at the cut); it is reported in
  `droppedTransitionIds` and undo restores it; a split keeps the left piece's id, so a split partner keeps its dissolve
  (M2). `incomingTransitionInside(track, clip)` (Sequence.h): the part of an incoming dissolve inside a clip;
  `setClipFade` refuses a fade out longer than the clip less its fade in and that part, `fadeLimitFrames` (now with
  the track; `addTransitionAtEdge`, `transitionLimitForTransition`, `setRangeOfTransition`'s offsets) and the
  inspector's limit (`ProjectStore.incomingTransitionFrames(of:)`) stop there, and normalizing shortens a fade out
  that meets an incoming dissolve (removes it when nothing is left, reported) instead of dropping the dissolve (M3).
- Drop notes (M1): the facade no longer appends its generic sentences for dropped ids to `VEEditResult.note` (they
  were sometimes wrong, "its cut no longer exists" for a touched fade in); the app words each one
  (`ProjectStore.notes(of:)` = note + `dropNote(for:)`), from `SpanMemory` (every span with its clip as they were the
  last time it was there, refreshed with the model, so a coalesced drag still finds them): "Removed the fade in on
  “B”: “A” now touches its start.", "Removed the cross dissolve between “A” and “B”: “C” now follows “A”.", "The
  Motion span before the new start of “B” was folded into the clip's values." (when the static values changed),
  "Removed the ... span on “B”: nothing of it is left inside the clip.", and for a split inside a dissolve "“A” was
  split inside it". Transitions of a deleted clip get no sentence. Every app path that showed a result's note goes through `notes(of:)` (report, moves, transition drags,
  the inspector, the speed sheet, Ken Burns).
- Drops (H3, H4, M6): transitions and effects are always offered as `.copy` (the red preview says a drop will be
  refused; the drop clears it); a hover or press in the track area clears a stale preview and reveal. Lane 0 is
  revealed on the row under the pointer only (`revealTransitionLane(onTrack:)`, `revealedTransitionTrack`), after
  targeting by the geometry as shown. A dissolve on a free edge: preview labelled "Fade" (`previewLabel`) in the
  transitions' colour, note "No clip follows: this adds a fade to black." (from black / silence); a clip that already
  fades: "“x” already fades out: drag the fade's edge to lengthen it, or delete it."; a refused free edge falls back to
  the next free edge in reach (a refused cut never becomes a fade).
- Timeline scrolling (M4, M5, L1): `TimelineScrolling.action(for:headerWidth:rulerHeight:)` (a notched wheel scrolls
  time, Shift or the headers the tracks; `ScrollWheelCatcher.Scroll.isPrecise` from `hasPreciseScrollingDeltas`
  scrolls both axes; Option/Command zoom). `ScrollBarGeometry` drives both bars; the vertical one overlays the track
  area's trailing edge while the rows are taller. `ProjectStore.timelineViewportHeight` and `clampTimelineScroll()`
  (model changes except mid-drag, lane and row collapses, the reveal ending, zoom, scroll, resize). The line between
  headers and tracks is an overlay on the headers, so the track area starts at `headerWidth` like the ruler
  (`TimelineDiagnostics.rulerFrame` / `trackAreaFrame` measure it).
- D2: `WindowLayoutModel.timelineHeight` is non-optional; `adoptInitialTimelineHeight(rowsHeight:)` (the store, at
  init, with `TimelineViewModel.rowsHeightWithoutLanes`; a stored nil migrates the same way),
  `setTimelineHeight(_:windowHeight:)` (drags: up to window - 240 - divider), `fitTimeline(contentHeight:
  windowHeight:)` (the divider's double-click through `ProjectStore.fitTimelineHeight(windowHeight:)`: at most 60 % of
  the window, stored), `timelineHeight(windowHeight:)` (shown); Reset Window Layout returns to the launch's fit.
  `ContentView` no longer reads `timelineContentHeight`. `PaneDivider(showsGrip:)` shows a grip on hover.
- Redraws (M7, L9): the timeline content model is rebuilt only when the drawn content (tracks and lanes, clips, span
  ranges) changes (compared after each model change; `timelineBuildCount` counts real builds); the canvas is
  `TrackAreaCanvas`, an Equatable view over `TimelineRenderer.drawsLike` and the redraw token. `ClipIndex` (EditOps.h)
  gives snapshots of all clips one lookup table for linked transitions (`makeClipInfo` / `makeEffectSpan` take it);
  `selectedTransitionID` and `selectedSpan` read `ProjectStore.spansByID`; the inspector reads the selected transition
  and its limit once per model change (`engineTransitionReads`).
- Scheduler (L10, verified first with a failing test): a Gain span whose timeline start has no CMTime is active over
  the piece from the rounded cut (decided at the piece's middle, starting at the span's start value); the eased-gain
  steps are enumerated only within the plan window (`Scheduler::stepsWithin`).
- Smaller: shares keep a dissolve a frame after its cut (L3, `InspectorModel.lastFrameAfterCutNote`); span drags are
  limited to the lane's free space (L4); a fade out's bar is refused up front (L5); Control-K skips locked and hidden
  tracks, asks for one clip when several are selected, and selects the span it added instead of stacking another on
  the same frame (L6); lane collapse follows its track when tracks are removed or added (not across New/Open), and
  selecting a span on collapsed lanes opens them (L7, `WindowLayoutModel.setCollapsedLaneTracks`).
- By hand only (the test host cannot drive these): real drags of the Ken Burns rectangles and corners on a picture in
  picture, an offset clip and a turned clip (the dashed window outline and caption, the program monitor following);
  Escape and Cmd-Z in the middle of a real Ken Burns drag, then moving the mouse before releasing; a real transition
  drag from the Effects tab onto a locked track, a cut without handles and a lone clip's end (the pill clears on
  release; lane 0 opens only under the pointer; the "Fade" preview); the wheel on a notched mouse (time; Shift and the
  headers: tracks) and on a trackpad (both axes); the vertical scroll bar's knob; dragging the divider above the
  timeline (the grip on hover, the monitors keeping 240 pt) and its double-click fit; the 1 pt alignment of clips
  under the ruler at several zooms; Control-K on a locked or hidden top track.

## Ken Burns editor round (2026-09-25; user feedback on the C1 fix)
Replaces the fix round's crop model of the Ken Burns editor (the window outline, `windowFraming`, the picture loader)
with the placement-box model the user asked for. No engine change, no schema change; the "engine crop / schema 6"
idea in the review's C1 text is dropped.
- The model: the program monitor keeps showing the composed program at the playhead (every track, live through each
  drag step). A box is the clip's placement at a span edge: the asset's picture (display size) fitted into the frame
  as the compositor places a clip with identity values, scaled about its centre by the edge's composed scale, moved by
  its x/y (sequence pixels from the frame's centre), turned clockwise by its rotation about its centre. Start is what
  `getMotion(_:atEdgeOfSpan:atEnd: false)` composes to, End what it composes to at the end. A body drag moves the box
  (its centre within 20 % of the frame beyond each edge, `KenBurnsModel.reachFraction`, or where it already was); a
  corner drag scales it about its centre by the grabbed corner's movement along its (turned) diagonal, between 2 % and
  10 frame widths (`minimumBoxFraction`, `maximumBoxFrames`); the rotation is the inspector's (there was and is no
  rotation handle). The dragged box goes back as absolute values (`motion(for:picture:sequence:)`) and those through
  `ProjectStore.relativeFraming` over the base read at the drag's start, so the inspector's absolute Start/End values
  are what the box shows. The default new span is unchanged (Start the clip's placement, End 1.25 times larger about
  the same centre: for a full-frame clip a box larger than the frame).
- API (app): `KenBurnsModel.box(for:picture:sequence:) -> KenBurnsBox`, `motion(for:picture:sequence:) -> (framing,
  rotationDegrees)`, `fittedSize(picture:sequence:)`; `KenBurnsBox` (centre, size, rotation; `corner(_:)`, `corners`,
  `local(_:)`, `point(local:)`, `scaled(by:)`); `KenBurnsModel.start` / `end` are boxes (sequence pixels),
  `box(_:)`, `startFraming` / `endFraming` the absolute placement, `pictureSize`; `applyDrag(_:origin:translation:)`
  (no location; the origin is a box), `moved(_:by:)`, `resized(_:corner:by:)`, `reach(including:)`.
  `KenBurnsModel.outlines` (`Outline`: clip, track name, box) lists every other video clip under the playhead on a
  track that is not hidden (muted), at `clip.motion(at:)`, bottom track first; read on `setPlayhead(_:)` (the overlay
  feeds it the program playhead) and on every model change (`update`), published only when it changes (a drag step
  republishes nothing). `KenBurnsHit.target(at:start:end:)` takes boxes and tests corners, labels, edges and the inside
  in each box's own axes. `KenBurnsModel.init` takes `playhead` (the outlines' time) and no picture loader.
- The margin: `KenBurnsViewport(sequence:monitor:margin:)` fits the frame inside the monitor less 15 % of its width
  and height on each side (`marginFraction`) and maps points both ways (`view(_:)`, `sequence(_:)`). The program
  monitor is laid out by `ProgramMonitorLayout` (observes the store): closed, the picture fills the area as before;
  open, the same `VEPreviewView` (same place in the tree, only its frame changes) is sized to the viewport's frame on a
  dimmed margin, `KenBurnsOverlay` draws the frame's edge, the dashed outlines with track names, the arrow and the two
  boxes over the whole area, and `KenBurnsControls` (the bar) sits under the picture. The HUD and a Fade or Gain span's
  readout (`SpanReadout`) are overlays of the picture area. `ProgramMonitorHost` wraps the layout; `KenBurnsOverlayHost`
  is gone.
- Removed: `KenBurnsPictureLoader` (and its memory-pressure hook; it never used `ThumbnailCache`, so `MediaCaches` is
  unchanged), `pictureBounds`, `pictureFrame`, `pictureSeconds`, the picture following the playhead, `staticFraming`,
  `clipWindow`, `clipWindowCorners`, `windowCaption`, `windowFraming`, `absoluteFraming`, `rect(for:)`, `framing(for:)`,
  `fittedPicture`, `largestRect`, `scaled`, `constrained`, `startRotation` / `endRotation`. Kept: the L8 failure memory
  (`kenBurnsFailedSpan`): the editor can still fail to open (media not in the project, no picture) and would otherwise
  rewrite the status line on every model change; its message now says Ken Burns does not know the picture's size.
- Control-K (`ProjectStore.motionSpanTarget()`, `canAddMotionSpanAtPlayhead`, `MotionSpanRefusal`): Add Motion Span at
  Playhead acts only on the selected video clip (a linked pair counts as its video clip) or the selected span's clip,
  never another clip under the playhead. Nothing selected: "Select a clip first."; audio only: "Select a video clip
  first: ..."; two video clips: "Select one video clip ... (2 are selected)."; its track locked: "“V2” is locked.". The
  Clip menu item is disabled in those states (and during a gesture); where the playhead is is not part of that (a press
  with the playhead off the clip says so). The clip context menu acts on the clicked clip, disabled on a locked track.
  `motionSpanClip()` is gone.
- Dividers (`PaneDivider`): the grab area is an AppKit view, `DividerHandleView` (via the private `DividerHandle`
  representable): `mouseDown` / `mouseDragged` / `mouseUp` (the drag starts after a point, the translation is along
  the axis since the press, positive right or down), a double-click on the second press, `acceptsFirstMouse`, a
  tracking area for hover (the grip) and `cursorUpdate` for the pointer shape (`DividerCursor.cursorUpdate()` sets the
  resize cursor even when it set it last). A drag cut off by the view leaving the window ends silently. The tooltip is
  `PaneDivider(help:)` (a SwiftUI `.help` does not reach the AppKit view); `DividerCursor.frame` is the handle's bounds.
  Cause of the user's report, as far as the test host shows it: the divider was a SwiftUI `DragGesture` with `onHover`
  and `NSCursor.set()`; during source playback it was neither re-rendered nor replaced (0 body evaluations, 0
  appear/disappear, hit testing of the gap unchanged, no cursor-rect invalidations, measured with a temporary probe),
  while the source monitor beside it and the transport re-render at the display rate in the same hosting view. Real
  mouse events cannot be posted to SwiftUI gestures in the test host (no accessibility trust; synthetic events do not
  reach them), so the SwiftUI failure itself was not reproduced; the AppKit handle takes the press, drag and pointer
  shape out of SwiftUI's event handling, and `PaneDividerTests` drives it through `NSWindow.sendEvent` while the source
  and then the program plays.
- Tests: `KenBurnsEditorTests` rewritten around boxes (the loader tests and the crop and window tests deleted);
  `EffectLanesTimelineTests.testControlKActsOnlyOnTheSelectedClip` replaces
  `testControlKSkipsALockedOrHiddenTopTrackAndAsksForOneClip`; `PaneDividerTests` (new);
  `TimelineRedrawTests.testKenBurnsOutlinesFollowingThePlayheadRedrawNeitherTheTimelineNorTheBin` replaces the
  landing-pictures test (0 timeline builds, 0 canvas draws, 0 tile bodies for 9 playhead steps with the editor open).
- By hand: see `open-findings.md`, "Ken Burns editor round: by hand".

## Ken Burns and Transform modes (2026-09-25; user feedback on the Ken Burns editor round)
The Motion span editor has two modes that choose the same values (where the clip sits at the span's start and end:
the edge's composed Motion M = static values with every started span applied, `VEClipInfo.getMotion(_:atEdgeOfSpan:)`),
so switching writes nothing. No model or schema change.
- Geometry (`KenBurnsModel`, sequence pixels, +y down, F the frame's centre, R(θ) clockwise on screen; the compositor
  draws a fitted picture point p at F + (x, y) + s R(θ)(p - F)):
  - Transform (`box(for:picture:sequence:)`, unchanged): the fitted picture scaled by s about its centre, centred at
    F + (x, y), turned by θ. Inverse `motion(for:picture:sequence:)`: s = box width / fitted width, (x, y) = centre - F.
  - Ken Burns (`rect(for:sequence:)`): the part of the unplaced picture that fills the frame, the frame's preimage:
    size = frame / s, centre = F - R(-θ)(x, y) / s, turned by -θ (so its corners map exactly onto the frame's). With
    θ = 0 the centre is F - (x, y) / s, the original editor's `rect(for:)` (history before 666143e), whose centre already
    used R(-θ) but which drew the rectangle unturned. Inverse `motion(forRect:sequence:)`: s = frame width / rect width,
    θ = -rect rotation (kept), (x, y) = -s R(θ)(centre - F); nil for an empty rectangle (an edge at scale 0).
  - `KenBurnsModesTests.testTheTwoGeometriesDescribeTheSamePlacement` checks both against the compositor's map, each
    round trip and each into the other through the values to 1e-9.
- Deviation from the brief: it gave the rectangle's centre as F - (x, y) / s "drawn turned by M.rotation". That holds
  only without rotation; the exact preimage has the centre F - R(-θ)(x, y) / s and turns by -θ (the frame turned
  clockwise inside the picture shows a rectangle turned the other way). Implemented the exact form.
- Ken Burns drags: a body drag pans (`panned`), a corner drag zooms about the centre by the corner's movement along the
  diagonal (`zoomed`), the frame's aspect kept; a rectangle stays inside the frame box (`frameBox`: the frame at
  identity, what the monitor shows at 100 %, the bars of a letterboxed or pillarboxed source included; with a turned
  rectangle, its axis-aligned half extents) and is at least `minimumRectFraction` (a tenth) of the frame wide; a zoom
  out stops at `maximumRectWidth(rotationDegrees:)`, the widest turned rectangle the frame box holds (the whole frame,
  100 %, unturned), and a rectangle grown against the frame's edge moves in to stay inside (so "about the centre" gives
  way at the edge). Fix after the user's report: it was held to the fitted picture's pixels, so on a source of another
  aspect (Sintel 2048x872, a portrait still) the identity rectangle was out of reach and a zoom out stopped at the
  picture's height or width (about 132 % on 2.35:1); a pan may now show the bars, as 100 % does
  (`KenBurnsModesTests.testALetterboxedSourcesRectanglesReachTheWholeFrame`, `...PillarboxedStills...`,
  `testASecondSpanAfterAPushInZoomsBackOutToTheWholeFrame`). A rectangle already outside the frame box (typed values,
  values made in Transform mode) is not pulled in by a drag's first step and moves back in freely (`keptInFrame`); one
  wider than the frame on an axis stays on the frame's centre there. Escape mid-drag (H2), one undo step per drag, the
  zero-scale refusal (the edge at scale 0 has an empty rectangle: the note says the base is 0, or that the edge shows
  nothing) and the redraw budget hold in both modes (`checkCancelledDrag(in:)`,
  `InspectorSpanTests.testAScaleOverABaseOfZeroIsRefusedWithTheReason`,
  `TimelineRedrawTests.testAKenBurnsDragBuildsNoTimelineModelAndRedrawsNoClips` loop over the modes).
- Engine, the program preview solo: `Scheduler::soloGraphAt(sequence, project, clip, time, identityMotion)` (the clip's
  layer alone, any track visibility, no transition, the time held on its first frame before it and its last from its
  end, identity VideoParams with opacity 1 or its own Motion); `PlaybackController::setPreviewSolo(optional<PreviewSolo>)`
  / `previewSolo()`: the primary frame source (the program view) resolves the solo graph, a Mirror source (the output
  window) keeps the program; the paused picture's requests, the stopped lookahead and pre-roll targets add the solo
  layer when the program does not show it (`layersToDecodeLocked`); cleared by `setSequence` (New/Open) and by
  `modelChanged` when the clip is gone or off the video tracks; refused (cleared) for a clip that is not a video clip.
  Export never uses a controller. Facade: `-setProgramPreviewSoloClip:identityMotion:` (NO when refused),
  `-clearProgramPreviewSolo`, `programPreviewSoloClipID` (0: the program), `programPreviewSoloIdentityMotion`. Tests:
  `SchedulerTests` ("a solo graph shows one clip alone ..."), `PlaybackPreviewSoloTests` (pixels equal to the clip alone
  at identity, the mirror, held/scrubbed/played frames, removal, New), `VEEngineProgramSoloTests` (an export made while
  it is set renders the program).
- App: `KenBurnsMode` (.kenBurns, .transform; `title`, `caption`); `KenBurnsModel.mode`, `setMode(_:)` (refused
  mid-drag; re-reads the shapes and the outlines, calls `ProjectStore.kenBurnsModeDidChange`), `modeCaption`,
  `automaticMode(start:picture:sequence:)` (Ken Burns when the Start placement box spans the frame on at least one axis,
  left edge to right or top to bottom somewhere on the frame, to within `automaticModeTolerance` (1 px): a full-frame or
  zoomed-in clip, or a letterboxed or pillarboxed picture at identity; Transform when it spans neither, a picture in
  picture, scaled down, or moved or turned off the frame; it used to require the frame's four corners, which sent a
  letterboxed or pillarboxed clip to Transform), `frameBox`, `fitsInFrame`, `maximumRectWidth`, `panned`, `zoomed`;
  `start` / `end` are the current mode's shapes (`KenBurnsBox` either way, so `KenBurnsHit` and the overlay are shared);
  `outlines` are empty in Ken Burns mode. `KenBurnsModel.init(... mode:)` (nil: automatic). The store: `kenBurnsModes`
  (span id -> mode), `kenBurnsMode` (the open editor's, published for the layout), `rememberKenBurnsMode(_:for:)`,
  `syncProgramPreview()` (sets or clears the engine's solo from the editor; run after every `syncKenBurns`,
  `closeKenBurns`, a mode switch and New/Open). `ProgramMonitorLayout`: no margin in Ken Burns mode,
  `KenBurnsViewport.marginFraction` in Transform mode. The bar has the mode's caption and the Ken Burns | Transform
  segmented control next to Smoothing.
- Mode memory: the only persisted UI state is the app-wide window layout (`WindowLayoutModel` in the standard defaults,
  keyed by track kind and number, not per project), and span ids restart per project, so the map lives in the store for
  the session of the project (cleared on New and Open, kept across undo). An asked mode (an entry point) is remembered;
  the automatic outcome is not (it is recomputed when the span is opened).
- Entry points (`ProjectStore.addSpan(... motionMode:)`, `addMotionSpanAtPlayhead(clip:mode:)`): `EffectKind.kenBurns`
  and `.move` (Effects tab tiles, `motionMode` .kenBurns / .transform, exported types
  `com.justjohn12345.framewright.effect.ken-burns` / `.effect.move` in project.yml and Info.plist) drop on an effect
  lane as a 5 s span from the drop point (or to the clip's end) or add at the playhead with "+"; Ken Burns is the push
  in (End rectangle 1 / 1.25 of the frame), Move ends where it starts (no end scale). Clip menu and the clip context
  menu: "Add Ken Burns…" (.kenBurns) and "Add Motion Span" (.transform) replace "Add Motion Span at Playhead", with the
  Control-K rules (selected clip only; disabled without one or on a locked track; the context menu acts on the clicked
  clip). Control-K: the push in, automatic mode. Asked again on a frame where a Motion span starts, the span is
  selected in the asked mode. Range-drag creation on a lane uses the automatic mode.
- By hand: a full-frame clip with Ken Burns from the Effects tab (drag onto a lane, or "+"): the monitor shows the clip
  alone, the End rectangle smaller; shrink it and see the composite (close the editor, or switch to Transform) zoom in
  accordingly; drag a rectangle to the frame's edge (it stops there) and a corner out (it stops at the whole frame); on
  a letterboxed or pillarboxed source the same, the bars included. The same span switched to Transform and back: the
  inspector's values do not change, the rectangles come back the same. A picture in picture with Control-K: it opens in
  Transform mode over the program. A turned clip (rotation 30°, scale 2) in Ken Burns mode: the rectangles are turned
  the other way. Playing and scrubbing with the editor in Ken Burns mode (the clip alone; off the clip its first or last
  frame). The output window on a second display while the editor is in Ken Burns mode: it shows the program.

## The frame in the monitors (2026-09-25, same round)
- `MonitorFrame` (KenBurnsOverlay.swift): `fitted(_:in:)` (the frame's aspect fitted into an area, `KenBurnsViewport`
  with no margin; the whole area without a size), `outsideColor` (white 0.16, the Ken Burns margin's shade),
  `programArea` (where the program's picture area was laid out, for tests). `ProgramMonitorLayout` always sizes the
  picture view to the sequence's frame (closed and in Ken Burns mode fitted into the whole area, in Transform mode inside
  the margin) over the outside shade; `SourceMonitorView` sizes it to the asset's picture (its display size), black
  without a picture. The output window is unchanged (its content view is the preview view, the compositor clears to
  black). Why a shade and not a hairline: a line at the frame's edge sits exactly where a placed picture's own edge is and
  reads as part of it (or as the Ken Burns editor's frame edge), while two tones read at a glance, also where the frame is
  empty.
- Tests: `MonitorFrameTests` (the fit in 10:7, tall, wide and exact monitors; the hosted program monitor's picture view
  and shaded bands, and its size in both editor modes; the source monitor's pillarboxed still and letterboxed movie),
  `OutputDisplayTests.testTheOutputWindowStaysBlackOutsideTheFrame` (16:9 on a 16:10 display, black bands; the program,
  not the solo picture), `MainWindowSmokeTests` now measures the monitor's area (`MonitorFrame.programArea`) and checks
  the picture view is the fitted frame.
- By hand: a window whose program monitor is not 16:9: the bands are a lighter grey than the frame's black, so a clip
  placed short of the frame's edge shows the black of the frame beside it; the source monitor with a portrait photo; the
  output window on a second display stays black outside the frame.

## Wipe and iris transitions (2026-09-27; plan `docs/plans/2026-09-27-reverse-speed-wipes-done.md`, item 1)
- Model: `TransitionKind` (Transition.h) is `CrossDissolve`, `WipeLeft`, `WipeRight`, `WipeUp`, `WipeDown`, `Iris`
  (`kTransitionKinds`; names `crossDissolve` ... `iris`, `displayNameOf`, `transitionKindNamed`). A wipe is named for
  the way the edge travels: Wipe Left brings the incoming picture in from the right edge. The kind is a video
  property: a transition span on an audio track is always `CrossDissolve` (`checkTransitionSpan` refuses another, a
  project file's is repaired to a cross dissolve with a warning). An unknown name keeps the existing path (a warning
  naming it, a cross dissolve; forward compatible), not a load failure: the plan's "refused" is that warning.
- Edit: `SetTransitionKind(sequence, span, kind)` ("Change Transition Kind"): refused `TransitionNotFound` (an effect
  span or no span), `TrackKindMismatch` (audio), `TrackLocked`; the range, the role and the linked audio transition
  are unchanged. `TransitionSpanRequest::kind` is honoured by `AddTransitionSpans` (and refused on audio).
- Rendering: `LayerTransition::kind` reaches the compositor. `VEDrawUniforms.reserved` = (shape = the kind's value,
  feather `kTransitionFeather` = 2 sequence pixels, 1 when a lone layer is the incoming side, 0); `mix.x` is the
  progress (pair draws as before, lone shaped draws too). All zero for a dissolve, whose uniforms and shader branch are
  unchanged (`CompositorTests.testDissolveMix` and the export parity tests hold as they were). The reveal (RenderGraph.h,
  `Shaders.metal transitionReveal`): d = W - x, x, H - y, y or |p - centre|, L = W, W, H, H or half the diagonal,
  r = p (L + 2f) - f, m = 1 - smoothstep(r - f, r + f, d). At p = 0 the soft band lies before every d >= 0 and at p = 1
  past every d <= L, so the frames are exactly the outgoing and the incoming picture (the plan's unshifted edge would
  leave a feathered strip at both ends; a run with it failed at 0 and 1 on every kind, 12 to 192 pixels). Pair draws
  are mix(A, B, m) per pixel; a lone layer (a fade role, or a partner not decoded yet) is drawn times m (incoming /
  fade in) or 1 - m (outgoing / fade out) instead of the uniform weight. At a free edge the other side is black: an
  Iris fade out grows black from the centre, as its fade in grows the picture.
- Facade: `VETransitionKind`; `VEEffectSpan.transitionKind`, `VETransitionInfo.kind`;
  `addTransitionFromClip:toClip:duration:options:kind:`, `addTransitionAtEdge:ofClip:duration:options:kind:` (the kind
  goes to video tracks only; a shaped fade's note is "Wipe Right from black."), `setKind:forTransition:`.
- App: `TransitionKind` has the six video kinds and `audioCrossfade` (`videoKinds`, `engineKind`,
  `init(engineKind:trackKind:)`, `glyph` ◁ ▷ △ ▽ ◯), each with its exported drag type (`...transition.wipe-left` etc.,
  project.yml / Info.plist). The Effects tab lists them; a drop or "+" passes the kind (`ProjectStore.addTransition`,
  `addFade(at:of:frames:kind:)`); a video transition's linked crossfade question is asked for every video kind. The
  transition inspector has a Kind popup (`InspectorModel.setTransitionKind`, `ProjectStore.setTransitionKind`) and an
  Edge row for a fade role; the lane-0 bar's title is the kind's ("Wipe Left", "Iris In" / "Iris Out" at a free edge)
  after its glyph (`TimelineViewModel.Span.transitionKind`, `glyph`, `isShaped`). Deviation: the plan listed the
  glyphs "▷ ◁ △ ▽ ◯" in kind order; the glyphs here point the way the edge travels (Wipe Left ◁).
- Tests: `TransitionShapeTests` (every kind against the C++ reference at 0, 0.25, 0.5, 0.75, 1 on a cut and at a free
  edge, a missing partner, opacity), `ProjectJSONTests` (the round trip of every kind; the unknown kind's warning; the
  audio repair and validation), `TransitionFadeEditTests` (SetTransitionKind and its refusals),
  `SchedulerTests` (the kind reaches the layers; the audio graph is identical for every kind),
  `ExportParityTests.testAWipeAndAnIrisExportTheMonitorsPictures`, `VEEngineEffectsTests.testATransitionsKindIs
  AddedAndChangedOnVideoOnly`, `TimelineDropTests.testEveryVideoKindDropsOnACutAndOnAFreeEdgeWithItsKind`,
  `InspectorSpanTests.testTheKindPopupChangesAVideoTransitionsKind`.
- By hand: each wipe and the iris dragged onto a cut and onto a clip's free start and end (the preview label, the
  picture while playing and scrubbing), the Kind popup on a selected transition (one Cmd-Z back), a wipe exported.

## Speed in the inspector (same plan, item 2)
- The inspector already had a Speed section (a typed field and a slider for one non-still clip or the video clip of a
  linked pair, ripple per Settings > Editing's ripple scope, the same parser as the sheet). Added: a Presets menu
  (`InspectorModel.speedPresets` 25 ... 800 %, `applySpeedPreset`, one "Change Speed" step, the linked audio
  following), a help line naming Speed/Duration… (⌘R) for the duration and the ripple choice, and the refusal of a
  typed speed outside 1 % to 10000 % with the range in the status line (`speedRangeProblem(_:)` exact on the fraction,
  `speedRangeProblem(multiplier:)` for a speed too small to store as a fraction: "0.01" was called "not a valid
  speed"). The engine refused the others already with its own sentence, which has the range too. The row's ripple is
  the ripple scope preference (all or synced tracks); "don't ripple" stays the sheet's.
- Test: `InspectorModelTests.testTheSpeedRowAppliesPercentsRatiosAndPresetsAndRefusesOutsideTheRange`.
- By hand: the presets menu and a typed "2x", "1/3" and "20000" on a clip with linked audio; a still shows no row.

## Reverse (same plan, item 3)
- Model (Clip.h "Reverse"; schema 6, `"reversed": true` written only when true, the 5 -> 6 migration changes only the
  version; a still cannot be reversed). Deviation from the plan's wording, same intent: the plan mirrors clip time u
  about the clip's own range (sourceIn + sourceOut - u). That mirror moves with every trim, so a head trim would keep
  the first frame's picture and cut media from the start of the range, a split's pieces would each mirror inside
  themselves (not "show the pictures they showed") and a Motion span would slide off its pictures, contrary to the
  plan's own consequences and tests. Here the mirror is fixed: a reversed clip's times are counted back from E, the end
  of the media its track uses (`mediaEndFor`: videoEnd on video, duration on audio), clip time u stands for media
  E - u, and `SetClipReversed` re-expresses the clip (sourceIn' = E - source out; its effect spans moved by the same
  amount so they keep their timeline frames). So trims, splits, speed changes, spans, validation and every media bound
  stay the forward code, and the plan's consequences hold (a head trim removes media from the end of the range).
  Relinking to a file of another length would move a reversed clip's pictures by the difference; the app has no
  relink.
- The mirror rule, by frame index: the picture of the sequence frame [F, F + fd) is the forward mapping's pick for media
  time E - u(F + fd), the mirror of the frame's END (`mediaTimeOfFrame`, `mediaRangeOf`). Reversing an n-frame clip of
  in point A makes frame k read A + (n - 1 - k) d exactly, then the same asset frame grid and clamps, so frame k shows
  what forward frame n - 1 - k showed on NTSC grids and VFR sources too (`ReverseTests`: 30 fps, 2x, 1/3, 3/4, 23.976 at
  999/1000 on 29.97 with an off-grid in point, VFR at 1/2, the media's last frame). The mirror of the frame's start was
  one frame off everywhere (the before-fix run).
- Edits: `SetClipReversed(sequence, clip, reversed, includeLinked = true)` ("Reverse Clip" / "Play Clip Forward"): the
  linked partner follows on its own media end; a clip already in the state is left alone; refused: a still
  (InvalidArgument), unknown media length (OutOfSourceRange), locked tracks, inexact times. A dissolve whose handles
  are gone on the new side is dropped and reported as every edit does. Times moved by it keep their timescale where
  they are whole ticks of it (`exactTimeOn`), so reversing twice gives the same numbers. `isThroughEdit` requires the
  same direction on both sides.
- Engine: `Scheduler::sourceFrameTime(clip, asset, time, frameDuration)` (the frame duration is new: the rule needs the
  frame's end); `VideoLayer::reversed`; `AudioSegment::reversed` / `mediaEnd`. The decode direction of a layer's
  target is `layer.reversed XOR (rate < 0)` in `PlaybackController::retargetLocked` (so the stopped lookahead and the
  pre-roll decode the frames before the picture in the media), and Backward in export for a reversed layer.
  `AudioSourceMapping::reversed` / `mirror`: sample n reads media at mirror - u(t of sample n + 1); the producer decodes
  a forward block of at least `kReverseBlockSeconds` (0.5 s) ending at the mirrored position (one seek per block) and
  delivers it back to front, at speed 1 bit-exactly the forward samples on PCM sources (on AAC within 1e-7: each
  block is its own decode, 6.0e-8 measured by the post-lanes review), resampled after the mirror otherwise (pitch
  follows speed). Reverse playback stays silent as before; a reversed clip in forward playback sounds reversed.
- Facade: `VEClipInfo.reversed`, `mediaIn` / `mediaOut` (the media shown), `mediaEnd`; `sourceIn` / `sourceOut` stay the
  model's clip times. `setReversed:forClips:` (one undo step, linked partners follow; a still refused).
- App: Clip > Reverse Clip (a checked toggle when every selected non-still clip plays backwards, ⌥⌘R;
  `ProjectStore.toggleReverseSelection`, `setReversed(_:)`, `selectionIsReversed`, `reversibleSelection`), the clip
  context menu's Reverse Clip (checked), the inspector Speed row's Reverse box (`InspectorModel.setReversed`) and the
  Speed/Duration sheet's (speed and direction one undo step through an accumulate group). The timeline draws "◀" before
  a reversed clip's name (`TimelineViewModel.Clip.title`), asks thumbnails for the mirrored media time
  (`mediaTime(atClipTime:)`, cache keys stay media times) and draws a reversed audio clip's waveform tiles mirrored. The
  inspector's Source In / Out show the media range with "(reversed)" (`InspectorModel.sourceRangeTexts`). There is no
  copy and paste of clips in the app, so the plan's "survives copy" has nothing to act on.
- Tests: `ReverseTests` (the mirror, SetClipReversed, spans and dissolves, split / trims / speed / move, a Motion span
  across a trim, the audio graph), `ProjectJSONTests` (the v5 golden loads forward, the v6 golden byte for byte, the
  round trip and the still refusal), `ClipAudioSourceTests.testAReversedSourceIsTheForwardSourceSampleReversed`,
  `PlaybackLookaheadTests.testAReversedClipsLookaheadRunsBackwardAndPlaysTheMirroredFrames`,
  `ExportParityTests.testAReversedClipExportsTheForwardExportBackwards` (pixel-exact frame k == forward n - 1 - k, burn-in,
  the monitor, the sound sample-reversed within 1e-6 at speed 1 and 3/2) and `testAReversedClipPlaysTheSoundTheExport
  Writes`, `VEEngineEffectsTests.testReversingAClipIsOneUndoStepWithItsLinkedAudio`, `ReverseClipTests` (app).
- By hand: reverse a clip with sound (Option-Cmd-R) and play it (the picture runs backwards, the sound too; J plays it
  forwards silently), scrub it, look at its thumbnails and waveform, split it and trim its head (the pictures stay on
  their frames), check the inspector's Source rows and its Reverse box, the Speed/Duration sheet's box, export it.

## Hands-on round 2026-09-27 (Unlink, reversed neighbours, Continue on Next Clip, selection, smooth wipes)
From the user's hands-on testing of the reverse, speed and wipes round.
- A. Unlink left both clips selected. Root cause: `ProjectStore.select(clip:extend:)` expands a click to the linked
  pair (so a pair moves, trims and deletes together) and `linkOrUnlinkSelection` unlinked without touching the
  selection, so after Unlink the selection still held both clips: a drag moved both, Delete removed both, and the
  undo of that delete brought them back as two unlinked clips, which read as "Unlink does nothing". Fix:
  `linkOrUnlinkSelection(keeping:)` reduces the selection to the clip the action was invoked for (the inspector's
  clip, the clicked clip of the context menu; for Clip > Link / Unlink the clip the selection was made for by a
  click, `ProjectStore.selectionAnchor`, else the first selected clip) and says "Unlinked “a” from “b”." in the
  status line. Links are expanded only when the user picks a clip (a click, a marquee); nothing re-expands them
  later, and `refreshModel` drops clips that no longer exist (as before). `selectedClips` breaks start-time ties
  video first, then track and id, so "the first selected clip" is stable. Deviation: the brief said the first
  selected clip for the menu item; the clicked clip is used when there is one (a click on the sound of a pair then
  keeps the sound), the first selected clip otherwise. Tests: `UnlinkSelectionTests` (a click, Unlink, one clip
  selected; a drag through `TimelineGestureController` moves it alone; Delete removes it alone; the context menu
  and the inspector keep their clip; no re-expansion).
- B. Continue from previous clip on a reversed clip. Not reproduced: the specified reproduction (forward clip, the
  same clip reversed and touching, Control-K on the reversed clip's first frame, `matchSpanEdge(.start)`) succeeds on
  a3e656b and the first frame then shows the forward clip's last framing; so do Lead into next clip, the forward
  clip after it, a reversed clip on either side, linked sound, 50 %, spans added before the reverse, a split
  reversed clip and media ends on odd timescales (FFmpeg nanoseconds, 1/600, 90 kHz, 1/44 s). Why it holds by
  construction: the reverse round's fixed mirror keeps spans in clip time (`sourceIn + (t - start) * speed`), and
  the mirror is applied only where media is read, so `spanEvaluationTime`, `spanActsAt`, `touchingClip` and the
  facade's timeline span range are the forward code for a reversed clip; the candidates in the brief do not differ
  for it. What the app did hide: Continue from previous clip vanished from the Ken Burns bar whenever the move
  started after the clip's first frame (a span added with the playhead a frame in, or dragged there), with no
  word why. It is now shown disabled with the reason and the time to set as Start
  (`KenBurnsModel.continueFromPreviousProblem`). Tests: `ReverseTests` ("a Motion span matches its neighbour across a
  cut between a forward and a reversed clip", "... whatever the media's end and the order of the edits"),
  `ReversedNeighbourMotionTests` (app, Control-K and the toggles), `KenBurnsEditorTests` (the reason).
- B. The first frame at a forward -> reversed cut. Measured
  (`PlaybackLookaheadTests.testAForwardToReversedCutPresentsEveryFrameOnTime`, the long-GOP 1080p file, a keyframe
  every 5 s, paused 1 s and 1/3 s before the cut, the same range reversed and another range): every presentation
  from the start to a second past the cut shows its own frame, and the controller counts no late frame. The
  lookahead already starts the reversed clip's backward window a second ahead (`retargetLocked`, direction
  `reversed XOR rate < 0`), and in the user's case the first reversed frames are the forward clip's last ones,
  already in the cache. So the jank is not a late frame: when the reversed clip shows the same range, the last
  frame of A and the first of reversed A are the same picture by construction (the motion turns round on a held
  frame, two frame times of one picture), and Continue from previous clip adds the same framing on both frames
  (matching makes the first frame show what the last frame shows). Continue on Next Clip (below) avoids the second
  part: its first frame is a frame further along the move.
- C. Continue on Next Clip (Ken Burns bar button, Clip menu). The rule (EditOps.h `planContinueMotion`,
  `ContinueMotionSpan`, one undo step "Continue on Next Clip"): S the selected Motion span of clip C, N the clip
  touching C's end on its track. S must be C's last move (no other Motion span of C ends after it). The new span
  starts on N's first frame and lasts as long as S on the timeline, shortened to N and to the free part of a lane
  (S's lane when that lane of N is free from its first frame, else the first such lane). Start = C's Motion at the
  cut (`motionValuesAt(C, end of C)`: S's end placement with the rest held), so the picture goes on without a jump.
  End = S's own rate over the new length T (S lasting T_S): x, y, rotation + (end - start) T / T_S, scale
  x (end / start)^(T / T_S) (1.0 -> 1.5 over 2 s continued over 2 s ends at 2.25). The values are relative, over
  what the rest of N composes to at the new span's first and last frames (as `planKenBurns`), so N's own placement
  and other spans are respected; the interpolation is S's (Linear for a custom curve); a still takes it; the editor
  opens on the new span in the mode S's editor was in. Refusals (sentences naming the clips): not a Motion span, not
  the clip's last move, no clip touching the end, every lane of N taken on its first frame, S starting at scale 0,
  N at scale 0, a locked track. Facade: `continueMotionSpanOnNextClip:`, `problemContinuingMotionSpanOnNextClip:`
  (the menu's and the button's enabled state and help). Deviation: the brief put Start at "the same values
  matchSpanEdge would give"; that is the last frame's framing, a frame short of the end placement while S still
  moves on it, which would hold the framing for two frames at the cut. Start is the placement at the cut instead (the
  same as matching when S ended before the clip's last frame), which is what the brief's own tests describe (the
  continued start equals the previous end on screen; 1.5 continued to 2.25). Tests: `ContinueMotionTests` (engine:
  the rate, relative values over N's placement, shortening to N and to a lane, another lane, a move that ended
  before the cut, undo, every refusal, a still, A | reversed A | A with the scale growing every frame across both
  cuts), `ContinueOnNextClipTests` (app: one undo step, selection and mode, refusals in the status line and the
  bar's note, a still, the reversed middle clip).
- D. Selection style. `TimelineItemStyle` (TimelineRenderer.swift), one rule for clips, span bars and transition
  bars: unselected, the kind's fill at 0.85 with the thin dark outline on the edge and a white label (as before);
  selected, the fill 20 % lighter (mixed a fifth of the way to white), opaque, a 2 pt border in `Color.accentColor`
  inset by 1 pt so it lies wholly inside the item (the hit geometry is unchanged), and the label and icon in white or
  black, whichever has the better WCAG contrast on that fill (at least 4.5:1 for every kind). The transition fill
  is now a fixed purple (0.58, 0.34, 0.80) instead of the system purple, so it has components to lighten.
  `TimelineRenderer.style(for:selected:)` is the lookup. Test: `TimelineSelectionStyleTests`.
- E. Smooth wipes and iris (RenderGraph.h `kTransitionFeather`, Shaders.metal `transitionReveal`). The edge
  moved tens of pixels per frame with a 2 px feather, so it stepped. Now the reveal is the soft edge averaged over
  the frame's exposure: frame k of n stands for the progress interval [p0, p1] = [k / n, (k + 1) / n]
  (`LayerTransition::progressStart` / `progressEnd`, set by the Scheduler; `mix` stays the frame's centre for the
  dissolve and the audio law), the edge at progress p is e(p) = p (L + 2f) - f, and with e0 = e(p0), e1 = e(p1),
  D = e1 - e0 and G the integral of the soft edge S(x) = smoothstep(-f, f, x),
  m(d) = 1 - (G(d - e0) - G(d - e1)) / D (G(x) = 0 below -f, 2f (t^3 - t^4 / 2) in the band, x above f); for D
  under 1/1000 px the instant at the interval's middle. Away from the feather this is exactly the hard edge
  box-filtered over the exposure, clamp((e1 - d) / D, 0, 1); the feather rounds its ends and the wider of the two
  dominates. The shader computes G(x) as max(x, 0) plus a band-limited excess so the difference stays small in
  float. Uniforms: `VEDrawUniforms.mix` = (mix, p0, p1, 0) for a shape; a dissolve's uniforms and shader branch are
  unchanged (bit-identical, `CompositorTests.testDissolveMix` and the export parity tests hold). [0, 0] (the frame
  before) is exactly A and [1, 1] (the frame after) exactly B; the first and last frames show the entering sliver
  partly revealed. A transition built without its interval (NaN) is the instant at its mix, as before. Tests:
  `TransitionShapeTests` (every shape across a cut and at a free edge against the 32-sub-step average of the soft
  edge everywhere and against the box-filtered hard edge away from the feather, both within 1/255 of the reveal
  plus the output's rounding, 1.5 codes; exactness at [0, 0] and [1, 1]; a 4-frame wipe ramps across its 25 px
  sweep with no pixel-to-pixel jump beyond 1/25; the unset interval), `SchedulerTests` (the interval per frame),
  `ExportParityTests.testAWipeAndAnIrisExportTheMonitorsPictures` (unchanged, passes). Deviation: the brief's
  reference integrates the hard edge over 32 sub-steps; a 32-sample average of a hard edge is a staircase up to
  1/64 (4 codes) off the box filter it approximates, so it cannot be held to 1/255. The test holds the shader to the
  exact box filter away from the feather and to the 32-sub-step average of the soft edge (which 32 sub-steps do
  integrate to well under 1/255 at these sweeps) everywhere.
- F. Fades start and end on black; the iris closes at a clip's end (follow-up to E). A user's frame 0 of an iris
  fade in showed a small circle of picture: its exposure was [0, 1/n]. The Scheduler (`exposureSteps`) now sets
  the interval by role: across a cut [k / n, (k + 1) / n] as before; a fade in [(k - 1) / n, k / n] (frame 0 is
  [0, 0], exactly black; the picture is whole on the frame after the fade); a fade out [(k + 1) / n, (k + 2) / n]
  (the picture starts leaving one frame in; frame n - 1 is [1, 1], exactly black), the time mirror of the fade in.
  `mix` stays the frame's centre in every role, so the cross dissolve kind (and a dissolve fade) is bit-identical.
  The iris of a fade out now closes on the picture (Transition.h: "Iris opens on a cut or a fade-in and closes on
  a fade-out"): the picture stays inside a disc of radius (1 - p) L that shrinks to the centre, black coming in
  from the corners. The compositor draws it as the opening iris over the mirrored interval [1 - p1, 1 - p0], the
  single layer times m (`isClosingIris`, `progressUniforms`, `shapeUniforms`), so the feather and the exposure
  averaging are the same and no shader changed; wipes at a fade out keep their direction. The Effects tab's Iris
  tile reads "Video: a circle opening from the centre; closes at a clip's end". Tests: `SchedulerTests` (the
  interval per role, [0, 0] and [1, 1] at the ends), `TransitionShapeTests.testAScheduledFadeStartsAndEndsOnAWhollyBlackFrame`
  (every shape, from a sequence through the Scheduler and the compositor over a white still: the first and last
  frames black pixel for pixel, every fade frame against the reference for its role's interval, the frames between
  untouched), `testAnIrisAtAFadeOutClosesOnThePicture` (centre the picture, corners black, pixel-identical to the
  fade in's iris over the mirrored interval), the free-edge test (the closing iris against its mirror),
  `ExportParityTests.testAWipeAndAnIrisExportTheMonitorsPictures` (now with a Wipe Right fade in at the start: its
  frame 0 and the iris's last frame black on the monitor and in the export; mid-iris the centre keeps the picture
  and the corners are black, where before black grew from the centre).
- By hand: select a linked pair by a click, Link / Unlink (Cmd-L), drag the clip (its sound stays), Delete (the
  sound stays); the same from the inspector's button and the context menu on the sound. A | reversed A | A with a
  Control-K span on each: Continue from previous clip on the reversed clip; play across both cuts (the held picture
  at the forward -> reversed cut is the content, not a late frame). Continue on Next Clip from the first clip's
  span, twice: one zoom through three clips; Cmd-Z removes one continuation at a time; the button disabled with its
  reason on the last clip. Clips, spans and transitions selected in light and dark appearance (accent border,
  brighter fill, readable label). A 10-frame wipe and iris played and stepped frame by frame: the edge moves
  smoothly, the frame before and after are clean; export one. An iris and a wipe fade in and fade out stepped
  frame by frame: the fade in's first frame and the fade out's last are black; the iris closes at the clip's end.

## Post-lanes review fix round (review `docs/reviews/2026-09-29-post-lanes-review.md`)
Closed: M1, M2, L1-L9 and test gaps 1-6 and 10. Left open: test gap 7 (reversed long-GOP 4K throughput), 8 (the mode
switch's own builds and draws, Continue on Next Clip from Ken Burns mode) and 9 (the parity tolerance, kept on
purpose); see `open-findings.md`.
- M1, the Speed/Duration sheet's Reverse box is three-state. `SpeedDurationModel.reversed: Bool?` starts as the
  chosen clips' common direction, nil (mixed) when they differ (`direction(of:)`); the checkbox is
  `Toggle(sources: reverseSources, isOn: \.self)`, one binding per clip reading the direction it will have and
  setting the box for all (a click on a mixed box turns it on). Apply changes the direction only of the clips whose
  direction differs from a set box (`setReversed` on those clips alone), so a mixed box left alone keeps each
  clip's own; the status line says "Reversed n clips." / "Played n clips forward." when it changes. Speed and
  direction stay one undo step also for several clips: an Accumulate coalescing group now keeps commands that
  cannot merge (`Command::mergeWith` false: the facade's `CompositeCommand` of a multi-clip speed change) in the
  group's one step (`UndoStack` `AccumulatedSteps`: undone backwards, redone forwards, cancelled together). Before
  this the second command of such a group became its own step (found by the M1 test: two clips, speed then
  direction, undo left the speed). Tests: `ReverseClipTests.testTheSpeedSheetOnAMixedSelectionChangesDirectionOnly
  WhenTheBoxIsSet`, `UndoStackTests` ("accumulate mode keeps commands that cannot merge in one step").
- M2, Add Ken Burns… on a clip placed inside the frame. `ProjectStore.rememberAskedKenBurnsMode(_:for:)` (every entry
  point with an intent: the Effects tab's tiles and "+", the Clip and context menus, a press on a frame where a
  Motion span starts): Ken Burns asked on a span whose automatic mode is Transform
  (`KenBurnsModel.automaticMode(span:clip:asset:sequence:)`) is not remembered (so it opens in Transform, the
  automatic mode, unless the user switched that span to Ken Burns before) and the status line says "“x” is placed
  inside the frame: opened in Transform mode; switch to Ken Burns on the bar to crop." Ken Burns mode on such a clip
  is usable: `KenBurnsModel.monitorExtent` is the frame with every corner of both rectangles when one is outside the
  frame box (nil otherwise), re-read with the rectangles but never during a drag (the monitor does not rescale under
  the pointer), republished as `ProjectStore.kenBurnsExtent`; `KenBurnsViewport.editor(mode:extent:sequence:
  monitor:)` (the layout's viewport) fits that extent with `extentPadding` (12 pt) to spare and never shows the frame
  larger than Transform mode does; closed, Transform and an in-frame Ken Burns keep their viewports. A corner drag
  then zooms the rectangle back toward the frame (the existing rules for a rectangle already outside the frame box).
  Test: `KenBurnsModesTests.testAddKenBurnsOnAPictureInPictureOpensInTransformAndKenBurnsModeReachesItsCorners` (a
  30 % clip: Transform with the note, 4 reachable corners on each box; switched, 4 on each rectangle, a corner drag
  zooms and stays reachable; the tile dropped on a lane the same; a full-frame clip still Ken Burns, no extent).
  `OutputDisplayTests.testTheOutputWindowStaysBlackOutsideTheFrame` asked Add Ken Burns… on a half-size clip for
  the solo picture; it now switches to Ken Burns mode on the bar, as a user would.
- L1, reversing media whose end is stated to the nanosecond. Root cause at import: Matroska's per-track DURATION tag
  (`FFProber` `durationTagNanoseconds`, now read exactly instead of through a double) is the length rounded to the
  nanosecond, on which few clip ends combine exactly. `tagDurationOnGrid` puts it on the track's own grid: an audio
  track's nearest whole number of samples; a constant-rate video track's nearest whole number of frames when within
  the container's timestamp resolution (1 ms in Matroska), else rounded up to that resolution. In the engine
  (existing projects keep their stored ends): `SetClipReversed` puts the new in point on the old one's timescale, else
  the sequence's frame grid, else the media end's timescale, else its smallest exact one; when E - out has no CMTime
  form on any timescale (a nanosecond end against a third of a second) it is refused `NotRepresentable` with a
  sentence ("“odd.mkv” cannot be reversed: its media's length as the file states it (10.123456789 s) does not line
  up exactly with this clip's frames, so they cannot be mirrored frame for frame. Trimming 1 frame off its end makes
  it reversible.", the trim found by trying up to 30 frames). Deviation: the brief asked to compute the in point
  exactly on a representable timescale "instead of refusing"; there is none for the review's case (the exact value's
  reduced denominator is 3 x 10^9, and every exact representation needs a multiple of it), so the engine refuses
  in words and the import stops such ends arising. Tests: `ReverseTests` ("a media end on a nanosecond timescale":
  exact on the media's timescale for 30 frames, refused with "Trimming 1 frame" for 31 and "2 frames" for 32, the
  trim then reverses frame for frame), `FFmpegBackendConformanceTests.testMatroskaWriterRoundTrip` (the tags of a
  written Matroska file: the video 45 x 1001/30000 exactly, the sound whole 48 kHz samples, both less 31/30 s exact;
  its tag says 1.501 s).
- L2: `SetClipReversed` skips a still among the linked partners (only a still asked for is refused); the facade's
  note: "“photo.heic” is a still image, which has no direction: its linked “tone.wav” was reversed on its own."
  Tests: `ReverseTests` ("the sound linked to a still is reversed on its own"),
  `ReverseClipTests.testReversingSoundLinkedToAStillReversesTheSoundAlone`.
- L3: `repairSequence` clears `"reversed": true` on a still with a warning ("a still has no direction to reverse;
  \"reversed\" was cleared"); validation still refuses it in the model. A clip "with no media length" cannot reach
  it (validation requires a positive length of a non-still asset and a clip's still flag to match its asset's), so
  only the still is repaired. Test: `ProjectJSONTests` ("\"reversed\" on a still is cleared with a warning").
- L4: Unlink with several linked pairs selected unlinks every pair in one undo step (an Accumulate group) and keeps
  one clip of each: the clicked one (`keeping`, else `selectionAnchor`) for its pair, the one selected when only one
  is, else the picture; "Unlinked 2 pairs of clips." The anchor is now cleared when the selection no longer holds it
  and by Select All. Test: `UnlinkSelectionTests.testUnlinkWithSeveralPairsUnlinksEveryPairAndKeepsOneClipOfEach`.
- L5: `KenBurnsModel.continueOnNextClipProblem` is published, read once per model change (`update`) and held during
  a drag (re-read at its end); `ProjectStore.continueMotionProblem` caches the engine's answer by span and engine
  change count (`continueMotionProblemReads` counts the engine calls). `LaneEffectsPanel` observes
  `LaneEffectsAvailability` (the "+" state, re-read on the main queue after store changes and when a gesture starts
  or ends, published only when it changes) instead of the store, and `EffectsPanel` no longer observes the store.
  Measured by `TimelineRedrawTests.testAKenBurnsDragBuildsNoTimelineModelAndRedrawsNoClips` with the bar and the
  Effects tab hosted: 0 engine reads during 20 drag steps, 1 at the release, 2 tile redraws per drag (the "+"
  disabled and enabled again) in both modes; a positive control redraws the tiles when "+" changes.
- L6: `SplitClip::dividedSpans()` (from `splitClipAt`'s new `divided` list) and `VEEditResult.dividedSpanIDs` (right
  part -> original, set by `splitClip:` and `splitClips:`); `ProjectStore.splitAtPlayhead` gives each part the Ken
  Burns mode chosen for its span (`inheritKenBurnsModes`). Only splits: an insert or overwrite in the middle of a
  clip also divides spans, and their right part opens in the automatic mode. Tests: `ClipOpsTests` ("SplitClip
  reports each span it divided"), `KenBurnsModesTests.testASplitKeepsTheChosenModeOnBothPieces`.
- L7: README says a wipe or iris fade starts and ends on black and a cross-dissolve fade's first frame shows
  1/(2n) of the picture; reversed sound is sample for sample on PCM, within 1e-7 on AAC (also in the Reverse notes
  above).
- L8: `migrateV5ToV6` warns for each clip with `"reversed": true` and each wipe or iris kind in a version 5 file ("...
  is a version 6 feature in a project of an earlier version: kept, and the project is saved as version 6"); every
  project is saved as version 6. An unknown transition kind (a newer version's) loads as a cross dissolve with
  `EffectSpan::unknownTransitionName` holding the file's name, which saving writes back ("unknown transition kind
  \"clockWipe\" (from a newer version of Framewright?); shown as a cross dissolve and saved as \"clockWipe\"");
  `SetTransitionKind` replaces it. The legacy (version 1-4) transition list keeps its old handling. Tests:
  `ProjectJSONTests` (the round trip of an unknown kind and its replacement; a version 5 file with a reversed clip
  and a Wipe Left).
- L9: `SetTransitionKind` Cross Dissolve on an audio transition succeeds and changes nothing; `checkTransitionSpan`
  names the kind by its display name ("not a Wipe Left"); `setClipFade` refuses a fade out meeting the incoming
  dissolve and fades that together overlap with `Overlap`, as `fadeLimitFrames` does (longer than the clip stays
  `InvalidTime`). Tests: `TransitionFadeEditTests` ("Refusal wording and codes"), updated codes in
  `EffectsEditTests`, `SchedulerTests`, `SpanEditTests`.
- Test gaps: the H1 migration with an 11-frame crossfade (54 frames and one warning; the floor mutation gives two
  warnings and fails), `ReverseClipTests.testAnAsymmetricRangeShowsItsMediaInTheSourceRowsAndMirrorsAboutTheMediaEnd`,
  `TimelineRedrawTests.testASelectedClipIsDrawnWithTheSelectionBorderAndFill` (rendered offscreen; a renderer passed
  `selected: false` fails it), `PlaybackLookaheadTests.testAReversedClipPlaysBackwardFastAndScrubsFrameExact` (-1x,
  -2x and 2x over a reversed clip and ten scrub positions: every sample the mirrored picture, no late frame), and a
  doctest filter: `TEST_RUNNER_DOCTEST_TEST_CASE='*pattern*'` (also `_TEST_CASE_EXCLUDE`, `_SUBCASE`) with
  `-only-testing:EngineTests/DoctestRunnerTests` runs a subset; a filter that matches nothing fails.
- Observation, not changed: J (-1x) from a pause on a FORWARD clip presents 2 to 5 late first frames in the harness
  (the stopped lookahead decodes toward forward play only); a reversed clip at J is exact once the lookahead has
  settled. Reverse playback from a pause on forward media would need a lookahead in both directions.
- By hand: the Speed/Duration sheet on a reversed and a forward clip (the box shows the dash; 50 % alone keeps both
  directions; a click on the box and Apply reverses both, one Cmd-Z undoes speed and direction); Add Ken Burns… on
  a picture in picture (Transform, the note; switch to Ken Burns on the bar: the monitor zooms out, both rectangles'
  corners on it, a corner drag zooms in and the monitor follows at the release); reversing a clip of a Matroska file
  imported now (it reverses; an older project's clip with a nanosecond end is refused with the trim to make); Unlink
  with two pairs selected by a marquee and by Cmd-A (both pairs unlinked, one clip each selected, one Cmd-Z).

## Notarized releases (2026-09-29)
`Scripts/release.sh` builds the Distribution configuration (a real identity, the hardened runtime, every embedded
dylib re-signed with the app's Team ID by CodeSignOnCopy), verifies the signature, submits the zip to Apple's notary
service, staples the ticket, checks it with `spctl`, and writes `build/release/Framewright-<version>-macOS.zip` for
the GitHub release. `--skip-notarize` stops after the signed build. Per machine, once: the team in
`Config/Signing.local.xcconfig` (gitignored; `FRAMEWRIGHT_DEVELOPMENT_TEAM = <team id>`), a Developer ID Application
certificate for that team in the keychain (Xcode > Settings > Accounts > Manage Certificates), and notarytool
credentials stored as the keychain profile `framewright-notary` (an app-specific password from appleid.apple.com).
Debug and Release stay ad hoc signed without the hardened runtime, so tests and local runs need none of this.

## Paused seeks on VFR sources (2026-09-29; user report "sometimes clicking to move the playhead the program output doesn't update")
- Reproduced on the user's demo project (3832x2154 H.264 screen recordings: variable frame rate with static gaps up to
  5.9 s, keyframes up to 7.3 s apart; clips at 3/5, 3/2, 5/4, 1/10 and 1): 61 of 200 ruler clicks left the monitor on
  another picture for good (every miss "presented without its picture"), and 52 of 200 on generated media of the same
  shape. `PausedSeekTests` drives a PlaybackController the way the app does (`PausedSeekRig`: scrubTo on mouse down,
  endScrub on mouse up, the frame source called only on needsDisplay, as the paused VEPreviewView renders only on
  renderOnce) and checks each click within 2 s against the file's own sample table (the pts of the frame containing
  each layer's picture time, read without decoding), so a wrong cache lookup cannot agree with itself.
- Root cause: eviction, not decoding or VFR lookup. The decode pool declares its streams' targets as the FrameCache
  focus; after a click they stay at the previous place until the stopped lookahead follows (100 ms after the playhead
  stops). A picture the scrub path decoded far from there (behind it, or on a cold part of a busy asset) ranked first
  to go and was evicted as it was put (`FrameCache::insert` enforced the budget with the new entry unprotected; the
  first run's diagnostics found it gone already when its request completed), or later by the previous lookahead's
  puts before the redraw looked it up. The request had completed, so the redraw found nothing with nothing
  in flight and presented the frame with the clip's previous picture (`exact` false); the stopped lookahead decoded the
  picture again later, but stream puts never ask for a redraw, so the monitor stayed on the old picture. The warm path
  had the same gap (`requestDisplayFramesLocked` checked `contains()`, then the redraw looked the picture up later).
- Fix: the paused picture is pinned from its insertion until the playhead moves on. `FrameCache::putPinned` pins the
  entry before the budget is enforced (no hit counted); `DecodePool::requestFrame` puts its frame pinned (and pins a
  cache hit) and hands the pin over in `ScrubFrame::pin` (ScrubFrame is now move-only; a receiver that ignores the pin
  releases it with the result, e.g. the source monitor's ProgramFrameProvider, which keeps only the image); the
  playback controller keeps the pins of the current display target (`Core::displayPins`, also for pictures found in
  the cache) until the next target (`beginDisplayRequests`, now also when there is no sequence). The frame sources pin
  what they present, as before. At most one extra frame per layer stays pinned (the cache may exceed its budget by the
  pinned bytes, reported in its stats).
- Ruled out with the harness and the first run's diagnostics: coalescing (every final request completed; the only
  cancellations were superseded ones), the VFR time lookup (no presented picture ever had the wrong pts; gaps are
  answered by the frame before them), a missing needsDisplay (every completion posted one), long-GOP decode time (the
  reported files: click-to-picture median 79 ms, p95 185 ms, max 320 ms; the 11.6 s-GOP take measured separately:
  max 218 ms), and the app side (ProjectStore.scrub/endScrub forward every click; no debounce). No solo preview or
  reversed clip in the project; the fix covers their layers too (layersToDecodeLocked feeds the same requests).
- After: 0 of 200 on the demo project and 0 of 200 on the generated media. Tests: `PausedSeekTests` (the demo
  project, skipped where `~/Movies/Framewright Demo/demo1.framewright` or its media are absent, or
  `FRAMEWRIGHT_DEMO_PROJECT` names another; the generated `screencast_vfr_h264.mov` project with a 40-frame cache; two
  deterministic cases, a picture decoded far behind the lookahead and an already decoded picture whose redraw comes
  after the cache filled up), `FrameCacheTests.testPutPinnedKeepsAFrameTheEvictionOrderWouldDropAtOnce`,
  `DecodePoolTests.testAScrubbedFrameStaysCachedWhileItsReceiverHoldsIt`. `PresentedLayer::shownPts` (the pts of the
  picture shown) is new for diagnostics. EngineTests now links AVFoundation (the sample table).
- Observations, not changed: endScrub right after a click re-requests the same picture while the click's request is
  still decoding, which supersedes and restarts it (the latencies above include it; letting a request for the time
  already being decoded take over the decode in flight would save the restart on long GOPs). J from a pause on a forward clip still shows 3 to 5 late first
  frames (unrelated: reverse playback needs frames the forward stopped lookahead does not decode).
- By hand in the demo project: click around the ruler (especially back into earlier clips, into the 1/10 clip on V2
  and the 3/2 and 5/4 clips, and into long static stretches) with the monitor visible: each click shows its frame at
  once; also right after an edit and while clicking quickly.

## Export sharpness (plan `docs/plans/2026-09-29-export-sharpness-done.md`; items 3, 2, 1)
- Item 3, export quality (a7a161f). The default constant quality of every preset is 0.8 (High): `VEExport.mm`
  `kDefaultExportQuality` is the only default site (the export sheet takes `defaultSettingsForPreset:`; nothing
  remembers a quality). The Quality picker lists the quality in effect as "Custom n %" (rounded) when it is none
  of `ExportModel.qualityChoices`, so it always shows a selection; the entry goes when a choice is picked. With a
  video clip (not a still, not sound) whose asset's displayed size (after its rotation) is larger than the output
  on either axis, quality mode shows "Maximum keeps fine text sharp" (`ExportModel.hasSource(in:largerThan:)`).
  The size estimate's bits per pixel were anchored at 0.7 (0.15, exp(4 (q - 0.7))) and put Maximum at half its
  real rate: now measured tables, interpolated in log space (per 1080p frame, the mean of two ten-second Sintel
  scenes; hardware H.264 and HEVC with the writer's settings, SVT-AV1 preset 8 at `av1Crf`):
  H.264 0.45 0.027, 0.65 0.065, 0.7 0.092, 0.8 0.166, 0.95 0.844; HEVC 0.017, 0.046, 0.067, 0.126, 0.793;
  AV1 0.026, 0.050, 0.062, 0.084, 0.146. A 4K screen recording exported at 1080p makes about a fifth of that
  (H.264 0.032 at 0.8): it is an estimate for camera-like content.
- Item 2, sequence settings (da3ea48). Rule chosen: the first video clip PLACED on the timeline (an insert or an
  overwrite with a picture track) sets an unconfigured sequence, not the first import: the sequence takes what it
  shows (a clip imported and never used, or the order a multi-file import happens to probe in, never decides),
  as Premiere's "new sequence from clip" and FCP's automatic project settings do; placing a still, a sound file or
  only a movie's sound never counts; with stills or sound already on it they are conformed like a settings
  change. The facade wraps `SetSequenceFormat` and the placement in one `CompositeCommand` (the settings first,
  so the placement lands on the new frame grid); the edit's note (and the status line) says "The sequence takes
  “x.mov”'s settings: 3840×2160 at 29.97 fps." Rates (`standardFrameDurationFor`): the nearest of the eight
  standard rates on a log scale; a VFR source's rate is the one of its shortest frame interval (the prober's
  frameDuration: AVAssetTrack minFrameDuration / FFmpeg r_frame_rate), not its average (a screen recording that
  averages 11 fps is captured at 60); above 60 fps the standard rate it is a whole multiple of (100 -> 50,
  119.88 -> 59.94, 120 and 240 -> 60), else 60 (monitors and export are paced for 60); below 23.976 the slowest
  standard rate that shows each frame a whole number of times (15 -> 30, 12.5 -> 25, else 30). Sizes: displayed
  size, odd sides rounded up to even; a size out of 16...16384 keeps the current one. A new project's sequence is
  `configured: false`; loading never changes a sequence; version 6 files migrate as configured (and sharpening
  on); a version 7 file saved while still unconfigured (only a still on it) keeps that state, and its first video
  clip then sets it, as in a new project.
  `SetSequenceFormat` (EditOps.h) conforms clips: positions (static x/y and Motion span X/Y keyframes) scale by
  k = min(W'/W, H'/H) and a clip's static scale by k x fit_old / fit_new, so every picture keeps its place and
  size in the old frame fitted into the new one (the whole frame for the same shape); scale/rotation/opacity spans
  are factors and degrees: unchanged. Grepped for other sequence-pixel state: the Ken Burns/Transform boxes are
  derived from those values (the app's `KenBurnsModel` holds the sequence size, so an open editor now reopens
  after a size or rate change); `kTransitionFeather` is a constant 2 sequence pixels (thinner relative to a 4K
  frame; left, it only anti-aliases). Frame rate: each clip edge to the nearest new frame (touching clips stay
  touching), inward where the media ends there, a clip shorter than a frame keeps one frame or the change is
  refused (no room); media in points move with the starts; effect spans stay on their pictures (source time; a
  still's spans keep their timeline frames, as for any head trim of a still); transitions keep their frame counts
  on each side, cross dissolves fitted with `transitionSideLimits` (now also over a working sequence), fades
  shortened while too long, a transition with not one frame left removed; each shortening/removal is a sentence
  in `SequenceConformReport` and in the sheet. Locked tracks are conformed too (refusing would leave no way to
  change the settings). `SequencePatch` carries the settings (`formatBefore/After`), so any command's undo and
  coalescing restore them. The sequence's audio sample rate is what the export writes (`makeEncodeSettings`
  takes it; `VEExportSettings.audioSampleRate` is gone). Sheet: Sequence > Sequence Settings… (and the size/fps
  label under the program monitor): six size presets or a custom even size, the eight rates (a sequence's own
  non-standard rate shown as "Custom n fps"), 44.1/48 kHz (plus the sequence's own), the preview's sentences
  live, a confirmation alert before a size or rate change reaches clips; one undo step "Sequence Settings".
  Applying unchanged values to an unconfigured sequence configures it ("the first video clip placed on it will
  not change them"). "Source size" was not added: with the sequence adopting its first clip, Sequence size is it
  for the common case, and "the source" of a multi-clip sequence has no single answer.
  Schema 7: sequence "configured", project "sharpenScaledDownSources" (always written; missing reads as true);
  golden `project-v7.json`; the v5 -> v6 warning now names the version saved ("saved as version 7").
  Existing tests that measure in a 1080p30 sequence configure it first (`StoreFixture.configureSequence`, the
  Ken Burns suites; the VFR dissolve test in VEEnginePlaybackTests); two App tests now expect the adopted 320x180.
- Item 1, sharpen after downscale (a1a4b3d). `RenderGraph::sharpenMinified` (the Scheduler copies
  `Project::sharpenScaledDownSources` into every graph: `renderGraphAt`, `soloGraphAt`); the source monitor's
  private project follows the setting (`syncSourceSharpening`, and its still path). So the program monitor, its
  solo preview, the output display, the source monitor and the export all sharpen; thumbnails are not compositor
  renders (VTPixelTransferSession) and are not sharpened. Compositor: after the Lanczos pre-scale of the luma
  plane (YCbCr; chroma is never sharpened) or the premultiplied RGBA plane, `ve_unsharp` writes a second pooled
  texture which the draw samples: out = c + 0.6 g(c - blur), blur the binomial [1 4 6 4 1]/16 in both directions
  (sigma 1 texel, the kernel of ffmpeg's unsharp=5:5), g(d) = d smoothstep(t, 2t, |d|), t = 2/255; the luma result
  within the nominal range or the texel's own value; RGBA colour within
  [0, alpha], alpha untouched. `RenderResult::sharpenedPlanes`. No per-frame allocation after warm-up (two pooled
  textures per sharpened plane). Amount: 0.5 measured x1.186 on the export crop against ffmpeg's x1.217 (before the
  exact export pre-scale below), 0.6 (ffmpeg's own amount) x1.206, 0.7 x1.227; chose 0.6: with the exact pre-scale it
  gives x1.214. An earlier version read the luma taps clamped to the nominal range to keep Lanczos overshoot from
  making halos; measured at 1:1 it made no halo difference (0 codes either way) and cost some sharpness (x1.238 vs
  x1.246 on 420v), so it was dropped.
  Found while measuring and fixed (deviation from "the downscale is not the problem"): a pixel-buffer target (an
  export) pre-scaled to the monitor's pooled 1/32 steps, e.g. 1920x1088 for 1080 rows, then bilinear-resampled
  onto 1080, softening fine text in bands (the edge measure 0.140 against ffmpeg lanczos's 0.151). Exports now
  pre-scale to the drawn size (`quantizeScratchSize(..., quantize: false)` for pixel-buffer targets); monitors
  keep the pooled steps for live resizing.
  Numbers (edge measure = mean gradient magnitude of the grey levels, central differences, 0...1; the 1080p export
  of a generated 3840x2160 screen-like text clip, 22 px Helvetica, crop 1200x600 at (200, 200), frame 15, decoded by
  ffmpeg to grey, mean of its 30 frames): app plain 0.1515, app sharpened 0.1839 (H.264 at quality 0.95); ffmpeg
  `scale=1920:1080:flags=lanczos` 0.1514, `...,unsharp=5:5:0.6` 0.1843 (x264 crf 16; ffv1 lossless gives the same to 4
  digits). Before the exact pre-scale sizes the app gave 0.140 plain and 0.166 sharpened (amount 0.5). The plan's
  0.022 / 0.011-0.015 were measured on the demo's real recording with another crop and measure, so only the ratios
  compare: ffmpeg x1.22, the app x1.21.
  Redraw budget (`testPreviewOf4KSourceTiming`, a 4K 4:2:0 frame in a 1080p preview): 0.61 ms GPU per frame
  without sharpening, 0.88 ms with it, inside the existing 4 ms / 5 ms / 6 ms bounds.
  Tests: `CompositorSharpenTests` (text at half size black on white and white on black, BGRA and 420v: edge measure
  x1.24, measured at 960x512, where the monitor's pooled pre-scale is exactly 1:1 (at 960x540 its 544-row plane
  resampled onto 540 rows put 8 to 9 codes of grey beside strokes: the same banding as the export's, see above);
  no pixel beyond the local extremes by more than amount x (1 - 36/256) of the local contrast, the range kept,
  no halo (0 codes); flat grey, a slow ramp and +-1 code noise changed by 0; 1:1, 0.8, 0.76 and magnified pictures
  bit-identical with the setting on and off; straight alpha: colour within alpha, alpha unchanged; the pool stops
  growing; exports pre-scale to the drawn size), `VEEngineSharpenTests` (program monitor, output display, source
  monitor and solo preview each sharper with the setting, the same picture again after off/undo; the 4K recording
  exported at 1080p at quality 0.95 x1.21 sharper, files kept in the test's scratch directory for the ffmpeg
  comparison), `ExportParityTests.testAMinifiedSharpenedSourceExportsTheMonitorsPictures` (luma block means within
  0.74 on average, 2.1 at most; 4.9 against the unsharpened export), the Scheduler carrying the setting
  (SequenceFormatTests), the export sheet's toggle and the Sequence Settings toggle (AppTests).
  Observation, not changed: decoded to 32BGRA by VideoToolbox, the ProRes export's mid-greys come out about 3 codes
  darker than the compositor's own RGB of the same luma (white and black match), so the new parity case compares
  luma codes; the other parity tests' pictures are mostly saturated and do not show it.
- By hand: a new project, drag a 4K screen recording to the timeline: the label under the program monitor reads
  3840×2160 · 60 fps (or its rate), the status line names it, Cmd-Z takes clip and settings back. Sequence >
  Sequence Settings… on a sequence with clips: change 4K -> 1080p and 60 -> 30: the confirmation lists the rescale,
  the moved edges and any transition that changes; Apply, the pictures look the same; one Cmd-Z. Export the demo at
  1080p Maximum with sharpening on and off and compare the Effects panel crop against the source (the plan's
  check); open the export sheet on the demo project: the Quality picker shows High, and "Maximum keeps fine text
  sharp" shows at 1080p; the sharpening toggle there and in Sequence Settings is one setting (Cmd-Z undoes it).

## Facade layout (VEEngine split, 2026-09-29)
- `VEEngine.h` declares the class (versions, lifetime, observers) and one category per area; each category is
  implemented in `Engine/Facade/VEEngine+<Area>.mm`: Project (with SequenceSettings), Snapshots, Media, Edits
  (with `VEClipParamsBatch`), EffectSpans, Transitions, Undo, Playback (program monitor), SourceMonitor, Export;
  `VEEngine.mm` keeps init/dealloc, the notification constants and the notify helpers (`VE_ASSERT_MAIN`'s failure
  is `VEFacadeSupport.mm`'s, 2026-09-30). Put a new public method in the category of its area. A category method
  that takes a completion block must be marked `NS_SWIFT_UI_ACTOR` itself, or Swift imports the block as
  `@Sendable` (the class attribute does not reach it; see the comment above `@interface VEEngine`).
- `VEEngine+Internal.h` (private, excluded from the framework's headers by the `*+Internal.h` rule) holds the
  engine's state and the cross-file private API: `_project` (the model), `MediaServices _services` (init),
  `DocumentState _document` (Project), `UndoState _undo` (Undo), `_rippleScope`, VEEngine.mm's observers, and one
  instance of each class below. Only the owning file writes a struct's fields; other files go through that area's
  private methods (declared in the header's `<Area>Internal` category and implemented in an `@implementation
  VEEngine (<Area>Internal)` block of the owning file, so the compiler checks them), e.g. `startUndoHistory`,
  `deferUntilCoalescingEnds:`, `publishPlaybackSnapshot`, `handRoutingToMonitors:forAsset:path:`. New/Open
  (`forgetProjectMedia`) is the one place that resets every area, in the order its comments give.
- Update 2026-09-30: the areas with real state and lifecycle are classes of their own, each with its state in
  ivars of its own `.mm` and a facade-private `VE<Name>+Internal.h` header (excluded by the same rule; included
  by path, never public). None holds a reference to `VEEngine`, includes `VEEngine.h` or `VEEngine+Internal.h`,
  or knows another class; the engine owns one of each and coordinates them, and the rules between areas stay in
  the engine (playback refused during an export, one monitor playing at a time, both muted together, the stopped
  lookahead given up during an export, New/Open's order). They get their collaborators through the constructor
  or per call and report through return values and data-only blocks the engine supplies:
  - `VEExporter` (running export, output URL access): `beginExportOfProject:settings:outputURL:services:options:
    progress:finish:refusal:`; `VEExporterProgressBlock` `void (^)(VEExportProgress *)` and
    `VEExporterFinishBlock` `void (^)(const media::Result<exporting::ExportSummary> &, BOOL endedRunningExport)`
    per start. A refusal is an `ExportRefusal` (reason and sentence) that the engine turns into its NSError. One
    refusal is new and unreachable through the engine (the model always has an active sequence): a project without
    one is refused as unsupported with "The project has no sequence to export."
  - `VEMediaLibrary` (routing, probe details, missing assets, bookmarks and their resolution on Open, the files'
    security-scoped access, thumbnail and waveform services, probe queue): per-call completions
    (`VEMediaProbeCompletion`, `VEMediaDetailsCompletion`, `VEMediaAssetReady`, `VEMediaThumbnailCompletion`,
    `VEMediaWaveformCompletion`). After `forgetProjectAssets` (New/Open) the library drops what it requested
    before: a thumbnail or waveform completion gets `nullptr`, a poster, waveform or details probe is not reported.
    An import probe always completes; the engine drops a stale one through the document generation. `routing` and
    `missingAssets` return const references to the library's containers (read or copy them at once), and
    `detailsForAsset:` a `std::optional`. The engine still adds imports to the model, checks a re-probed asset is
    current and hands routing to the monitors.
  - `VESourceMonitor` (pool, still provider, lazily created controller, private one-clip project, view,
    visibility, whether the engine allows the stopped lookahead) and `VEProgramMonitor` (pool, controller,
    published generation, program and output views): the model per call (`const Project &`, and the document
    generation for `publishProject:generation:`); one status block each, `void (^)(VEPlaybackStatus *)`, given at
    construction, from which the engine posts the playback notifications.
  - The router and frame cache are not owned by any class: `MediaServices` keeps them and the media epoch as a
    shared dependency injected into the classes (the library's probes and thumbnails, both monitors' pools and
    controllers, each export), and `beginMediaEpoch` (VEEngine.mm) starts an epoch across the cache and both
    monitors' pools.
  - Put new state in the class of its area, not in `VEEngine+Internal.h`; a new cross-area rule goes in the
    engine. The classes check the main thread themselves (`VE_ASSERT_MAIN`, now in `VEFacadeSupport+Internal.h`
    with `VE_FACADE_HIDDEN` and `isRunning`; its failure, in `VEFacadeSupport.mm`, raises "must be used on the main
    thread (<function> called on <thread>)"), except the methods the engine's dealloc calls (`cancel`,
    `stopAccessingURLs`, `disconnectView(s)`). They can be constructed without an engine: `VEExporterTests`,
    `VEMediaLibraryTests`, `VESourceMonitorTests`, `VEProgramMonitorTests`, which import each class's header first
    and no engine header, so a class header that starts needing the engine fails to compile there. A monitor decodes
    only assets registered with it (`registerAsset:path:[routing:]`), as the engine does on import and Open.
- Functions the facade's files share are declared `VE_FACADE_HIDDEN` (hidden visibility) in
  `VEEngine+Internal.h`: shared between the facade's files, not exported from the framework. Use it for any new
  one (file-local helpers stay in an anonymous namespace).
- Every edit goes through `pushCommand:` / `push:created:note:` / `pushRipple:` (Undo); span edits through
  `pushSpanCommand:` / `pushSpanEdit:` (EffectSpans); notifications through
  `postNotification:userInfo:observerMethod:notify:`. Id conversions: `toClipId`, `toTrackId`, `toSpanId`,
  `toAssetId`; `clampToInt` for NSInteger lanes and steps.
- Rules moved out of the facade: the transition limits, offsets, range fitting, fade planning and their
  sentences are in `Engine/Edit/TransitionFitting.h`; placements, split and speed/reverse targets and matching a
  neighbour's Motion in `Engine/Edit/EditPlans.h`; the source monitor's one-asset project and asset frame times in
  `Engine/Model/SourceProject.h`; `numericRange` (TimeUtil), `requestedSequenceFormat` (Sequence),
  `assetUseCounts` (Project) and `laneCount` (Track) in the model. They have doctest coverage (TransitionFitting,
  EditPlans, SourceProject and ModelQuery tests); new rules go there too, with the facade only converting (toNS,
  toVE, `makeEditResult`) and managing threads. Still inline in `VEEngine+Transitions.mm`, and the next extraction
  candidate (a `planCutTransition` in TransitionFitting.h): `addTransitionFromClip`'s refuse-or-fit decision and
  the fitting of the linked partners' cut, the linked transition's limit in `setDuration:...includingLinked:`,
  and the linked clip's fade in `addTransitionAtEdge:` (the per-clip fade itself is `planFade`).
- Fixed in the 2026-09-30 fix round (item 8; they were kept as they were by the split): the note on a clip's
  own fitted fade read "Shortened to shortened to ..." (`planFade`; now "Shortened to ...", as the facade notes
  its own fitted transitions), and a linked fade in whose range fit is refused first got the note "The linked
  transition was shortened to 0 frames (0.00 s): ..." before "The linked transition was not changed: ..."
  (`fitTransitionRange`'s head-fade path now refuses before noting anything).

## Fix round 2026-09-30 (group A of the lead's brief; status in `open-findings.md`)
- Media identity (supersedes nothing, adds to "Media identity"): WaveformService keys running jobs and the
  memory cache by (asset, track, path) and `cached()` takes the path; ThumbnailService's memory and coalescing
  key includes the path. `-[VEMediaLibrary cachedWaveformOfAsset:]` takes the asset (its current path);
  `-[VEEngine cachedWaveformForAsset:]` answers only for an asset of the project with sound. The library
  tracks its waveform request ids per asset and cancels them in `forgetThumbnailsAndWaveformsOfAssets:` and
  (any left, of removed assets) in `forgetProjectAssets`. Test media: `ve::test::writeToneAudioFile` writes an
  AAC tone of any length at test time.
- Frame-rate conform (supersedes "each clip edge to the nearest new frame ... inward where the media ends" in
  "Export sharpness"): `EdgeConform` in EditOps.cpp groups the edges that must stay together (a clip's end and
  the start touching it; the same edges of linked clips that were aligned) and gives each group one grid
  time: the nearest where every clip allows it, else the other side; at a cut between two whole clips the cut
  goes to the frame before and the clips starting there move with their media (in point kept), linked clips
  with them. `SequenceConformReport::clipsMoved`/`largestMove` and a sentence report the moves. A clip that
  would have to move against a linked clip conformed earlier is refused (OutOfSourceRange, "unlink them or
  trim it first"). Touching clips stay touching, so a cross dissolve keeps its partner. (Changed by the
  review fixes R1/R2, see "Fix round 2026-09-30, groups B and C": linked clips decided earlier move along
  when their edges keep their media, an end that rounded up alone comes back to the cut, a sub-frame linked
  sound clip keeps a frame; the refusal remains for a clip moved by another cut by a different amount.)
- Sizes (supersedes "odd sides rounded up to even"): `formatAdoptedFrom` rounds odd sides down; `placeSource`
  draws a picture with no clip transform that covers the frame with under 2 px to spare per axis at exactly
  1:1, top-left anchored. `fitRect` fills an axis whose bars would be under a pixel each. 1080p/720p of a
  sequence within 0.5 % of 16:9 are exactly 1920x1080 / 1280x720 (`widthForRows` in VEExport.mm).
- Sharpening (supersedes the decision part of "Export sharpness" item 1): decided at the picture's scale in
  the sequence for texture targets (monitors, solo preview, output display) and in the target for pixel-buffer
  targets (exports), never at a monitor's viewport scale; the source monitor (its sequence is the source's
  size) therefore never sharpens. The amount is `Compositor::sharpenAmountAt(scale)`: 0.6 at 0.6 and below,
  none at 0.75, smoothstep between. (Corrected by review fix R5, see "Fix round 2026-09-30, groups B and
  C": the pre-scale is decided by the drawn scale again, and the amount is sharpenAmountAt(max(drawn scale,
  that scale)).)
- Frame rates above 240 fps (`kMaxFramesPerSecond`, Sequence.h) are a time base: `makeMediaAsset` takes the
  track's nominal rate instead (as n/120000), `standardFrameDurationFor` returns nullopt.
- VEExporter: the job's completion ends the output URL's security-scoped access (after a cancelled job
  deleted its partial file), also when the exporter is gone; the exporter no longer holds the URL.
- By hand in the app: (1) import a 3832x2154 screen recording into a new project and place it: the label
  reads 3832×2154; export at 1080p: the file is 1920x1080 with no black column or row. Place a 1273x815
  window recording in a new project: 1272×814, and the picture at 100 % is sharp (no half-pixel blur).
  (2) A Ken Burns zoom from about 0.5 to 1.0 of a 4K source in a 1080p sequence: the text sharpens and
  softens gradually through 0.6-0.75, no pop; the program monitor at half size shows a 1080p source in a
  1080p sequence unsharpened (toggle "Sharpen scaled-down sources": no change). (3) New/Open waveforms:
  import a long sound file, New at once, import a short one: its waveform is its own (short), also after
  Open of a saved project. (4) Sequence Settings on whole clips back to back (for example 30 -> 25 fps): the
  confirmation says clips move earlier with their media; after Apply no black frame or audio gap at the
  cuts, picture and sound still in sync.
