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

## Effect lanes round 2 (app; plan `docs/plans/2026-09-24-effect-lanes.md`)
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
