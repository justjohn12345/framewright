# Open findings

Only what is still open. Fixed findings are in the history table of `README.md` (fix commits and regression tests);
the full reports are in git history at the commits the table names.

## Design items (effect lanes review, 2026-09-24; report in git history at fea82c0)
- D1, compact rows as in Resolve: a "Compact Tracks" toggle (View menu, timeline corner) and per-track compact rows
  when lanes are collapsed: about 22 pt video / 20 pt audio with the clip name only, a 3 pt strip at the clip's
  bottom marking spans and transitions in their kind colours (click expands the lanes), a one-line header (name,
  eye/mute, lock; solo and target in the context menu). Files: `TimelineViewModel` (a `Track.compact` flag, row
  heights, `lanes()` empty when compact), `TimelineRenderer` (compact clip + marker strip), `TrackHeaderView`,
  `WindowLayout` (persist next to `collapsedLaneTracks`), `ProjectStore` (cache key), `TimelineGestureController`
  (trim zones on 20 pt rows; no span hits when collapsed), redraw and lane tests.
- D3, restore the window frame, clamped to the displays present: nothing persists the frame today (SwiftUI `Window`,
  `FramewrightApp.swift`, no autosave). Save the frame and its screen's frame under a `WindowLayoutModel` key on
  resize/move (debounced, through `WindowAccessor.CloseGuard`) and on close. Restore once on first attach: the screen
  containing the saved centre, else main; width/height = min(saved, visible), not below 1100×640 unless the display
  is smaller; shift inside the visible frame; `setFrame`. Re-clamp on `didChangeScreenParametersNotification`. Set
  `isRestorable = false` so SwiftUI restoration does not fight it. A pure
  `restoredFrame(saved:savedScreen:screens:minimum:)` unit-tested for external-monitor → laptop.

## Post-lanes review (2026-09-29; report in git history at f486a6a)
All findings (M1, M2, L1-L9) and test gaps 1-6 and 10 were fixed in 47b1a45..eb4d3d5 and verified by the lead (see the
README history table). Still open:
- Test gap 7, the throughput of a reversed long-GOP 4K clip in playback and export (each backward window decodes
  forward from its keyframe; unmeasured, the test media has no 4K long-GOP source).
- Test gap 8, the Ken Burns mode switch's own timeline builds and canvas draws, and Continue on Next Clip from Ken
  Burns mode.
- Test gap 9, the export parity tolerance, kept on purpose (the wipe edge is held by `TransitionShapeTests`).
- Found in the fix round: J (-1x) from a pause on a forward clip presents 2 to 5 late first frames in the playback
  harness (the stopped lookahead decodes toward forward play only); a reversed clip at J is exact.
- Known limit: an insert or overwrite in the middle of a clip divides its Motion spans too; their right parts open
  in the automatic Ken Burns mode (only a split passes the chosen mode on, L6).

## Facade class extraction review (2026-09-30; commits be13a90..6435e24)
- Fixed in the fix round below: the export's security-scoped output URL access leaked when its exporter
  went away first (2407b2a).

## Fix round 2026-09-30: status
Brief: the lead's fix round from 84d9e20 (items 1-18). Scope was cut to group A mid-round (quota); the rest
is not started. Each done item has regression tests that fail on 84d9e20 (see the commit messages).

Done (group A):
- 12, wrong waveform after New/Open: beb0969. The file is part of WaveformService's and ThumbnailService's
  identity; VEMediaLibrary cancels its waveform requests on New/Open.
- 1, frame-rate change opened a frame gap at cuts: 5479b1b. `EdgeConform` (EditOps.cpp) conforms each cut
  once for both clips; whole clips move with their media; linked clips move together.
- 5, odd sizes and 3832x2154: 246ae5c. Odd sides round down on adoption and placeSource draws a covering
  picture 1:1; 1080p/720p of a near-16:9 sequence are exact; fitRect fills sub-pixel bars.
- 6, the monitor sharpened what the export would not: 5d8fc6e. Decided at the sequence's scale (texture
  targets) or the output's (pixel-buffer targets).
- 2, sharpness popped at 0.75: 573cc63. `Compositor::sharpenAmountAt` ramps the amount (smoothstep, full at
  0.6, none at 0.75).
- 7, a 1000 fps time base adopted 50 fps: 1f11f18. Import takes the nominal rate for an interval over 240
  fps; standardFrameDurationFor refuses rates above 240.
- 18, the exporter's output URL access leak: 2407b2a. The job's completion owns and ends the access.

Done (groups B and C, from 6864cc0; the commit subjects are named until the next status update gives
the hash):
- 9, stuck paused seek under load: 193c3dd. Root cause: the frame source published lastPresented() (and the held-back frame) with a
  try-lock and dropped the update when a reader held the lock; the renders after it found nothing new, so
  presentedFrameIndex named the previous frame for good while the view showed the new one (reproduced: 1
  failure in 75 loops under CPU load; 0 in 300 after). Now an immutable buffer swapped under the lock.
  `PlaybackDisplayPathTests testConfigurationChangesOnTheRealOutputRaceTransport`: a test timing
  dependency (the changes stopped after the transport's 800 ms, so a slow device restart made fewer than
  six; all twelve are made now). `ProgramFrameProviderTests testCancelledScrubRequestIsMadeAgain`: a test
  timing dependency (its other client shares the provider's lane, where the newest request wins; the main
  thread is now held until that client's frame came).
- 11, `laneCount` overflow: 5df5ae0. Loading
  already bounded lanes (repairSequence moves a span off lanes 0-3 with a warning, the parser refuses a
  lane beyond 32 bits; now pinned with crafted JSON at INT32_MAX/MIN, -1 and beyond); the overflow was
  reachable only on an unvalidated in-memory track: `laneCount` clamps each lane to 0...kLastLane.

Review of group A (84d9e20..6864cc0), regressions R1-R7, fixed before the rest of group B:
- R1 (item 1), a false "shorter than a frame ... the next clip leaves no room" refusal: b8a0656. A clip's end decided alone (a linked sound
  clip one source frame shorter than its picture) rounded up past the frame the cut between two whole
  clips takes; the separate previous clip's whole end group now comes back to the cut (its ends keep a
  frame, a start going back if need be; a cut it shares on another track comes back too when its next
  clip has media from there). The Overlap refusal is left for a clip that truly cannot keep a frame.
- R2 (item 1), in-sync linked clips refused as out of sync, and sub-frame linked sound refused: 7e2335b. A start
  decided first (dual-system sound rolling before the camera) fixed its component's move at zero, so the
  picture's move with its media was refused; the component now moves when every decided edge keeps its
  media with the move. A linked sound clip shorter than a frame whose start rounded up to the cut's frame
  starts a frame earlier into its media (when it still shows part of its sound) or ends a fraction of a
  frame after its picture (when nothing on its track starts there), instead of a refusal naming the
  picture as "shorter than a frame".
- R3 (item 5), the exact-HD snap added black lines: "Export: snap to exact HD only when the picture fills
  it". `widthForRows` snapped any sequence within 0.5 % of 16:9, but fitRect fills only bars under a pixel
  each, so 1918x1080 exported 1920x1080 with a black column on each side (1916x1080: 2 px pillars,
  1920x1076: rows). It now snaps only when fitRect of the sequence fills the snapped frame, else keeps the
  aspect (1918x1080, 1916x1080, 1928x1080 at 1080p).

Found while doing them (open):
- The remaining step at the 0.75 threshold (6.9 % of the edge measure between scales 1/240 apart) is the
  resampling filter (Lanczos pre-scale below 0.75, bilinear above), not sharpening. Pre-scaling every
  minified picture (threshold 1.0) would remove it at some GPU cost in the monitors.
- Item 1's refusal of a clip that would have to move against its linked clip: the claim made here ("only
  out-of-sync linked pairs reach it") was false for 5479b1b: in-sync dual-system sound
  starting before its picture reached it (R2). Since R2 the linked clips move together whenever their
  decided edges keep their media; the refusal is left for a linked clip already moved by another cut by a
  different amount, which in practice needs a pair slipped out of sync.

Not started (groups B and C), with what a fresh implementer needs:
- Nit (a): the adoption composite (Engine/Facade/VEEngine+Edits.mm:142, `withAdoption`) drops
  SetSequenceFormat's report; keep a pointer to the child and add its sentences to the note when it
  conformed clips (the note is built before the push: it needs the result after apply). Nit (b):
  `sequenceFormatProblem` accepts up to 192 kHz (Engine/Model/Sequence.h:74 kMaxSequenceSampleRate) but AAC
  export tops out at 96 kHz: validate consistently or refuse clearly at export. Nit (c):
  `CompositeCommand::canRevert` (Engine/Facade/VEFacadeCommands.mm:123-126) checks only the last child:
  check all.
- 3, per-frame texture allocation under animated scale: the pre-scale takes exact sizes per frame for
  pixel-buffer targets (`quantizeScratchSize(..., !exactPrescaleSizes)`, `acquireScratch(format, w, h)` at
  Engine/Render/Compositor.mm ~505/513), so a Ken Burns export misses the pool every frame. Hand out a
  texture at least as large and render into a sub-region (MPS destination region, sampling uv scaled), or
  similar; test no pool growth after warm-up with a changing scale into a pixel-buffer target.
- 4, the parity test compares the export path with itself: EngineTests/Export/ExportParityTests.mm ~232
  renders the "monitor" into a PixelBufferTarget. Render it through a texture target as ProgramView does
  and read it back (or give monitors exact sizes with item 3's pooling); tighten the loose bound (max block
  14.0 against a measured 2.1). Note: since 5d8fc6e sharpening differs by target kind by design only in
  its deciding scale (equal at the sequence's size).
- 8, garbled transition notes: "Shortened to shortened to ..." (Engine/Edit/TransitionFitting.cpp:230-231,
  `planFade`) and the refused linked fade-in range fit that first notes "was shortened to 0 frames" (the
  head-fade path adds the note at ~148 before the `length < 1` refusal at ~150). Fix both and update the
  pinning cases in EngineTests/Edit/TransitionFittingTests.cpp (allowed: they pin the wrong text).
- 13, ownership breaches: Engine/Facade/VEEngine+Project.mm:171 calls `_undo.stack->markClean()` and :273
  `_lastUseCounts.clear()`: route through methods of the owners (Undo, VEEngine.mm). Drop unused includes
  from Engine/Facade/VEEngine+Internal.h (`PlaybackController.h`, `<map>`, `<optional>`, `<set>` if unused);
  optionally stop exposing the class pointers to categories that never use them.
- 14, enforce "no engine dependency": define a marker macro in VEEngine.h and VEEngine+Internal.h and add
  `#ifdef ... #error` after the includes of VEExporter.mm, VEMediaLibrary.mm, VESourceMonitor.mm and
  VEProgramMonitor.mm; prove it fires by including the engine header temporarily; correct the integration
  notes' claim (a class header that includes the engine header itself compiles in its test).
- 15, untested rules and weak tests: the mutation list in the brief (VESourceMonitor setMuted:, pauseController,
  the lookahead update at controller creation, `_asset &&` in resetIfAssetLeft:, the size < 2 export refusal,
  the routing forward to the source controller, the `_missing` skip in the details probe, the numeric-scrub
  guard in VEProgramMonitor ~230; TransitionFitting.cpp ~115/146/150/162/175/180/197/223; EditPlans.cpp
  ~100-101 `- fd`; SourceProject.cpp ~38 `max(1, width)` and ~57 `videoLength > 0`). Replace the fixed
  sleeps at VEMediaLibraryTests.mm:293, VESourceMonitorTests.mm:260 and 327-330, VEProgramMonitorTests.mm:161
  and 295 with completion signals where possible. Report a before/after mutation table.
- 16, `fadeLimit`'s dead `excluded` parameter: Engine/Edit/TransitionFitting.cpp:42-48 (and
  TransitionFittingTests.cpp ~113-115 asserts 60 with and without it): remove it and the copy, or show a
  case where it matters.
- 17, small items: `__attribute__((objc_subclassing_restricted))` on the four extracted classes;
  `describeFrames` (TransitionFitting.cpp:8-15) needs a larger buffer or an snprintf fallback when to_chars
  fails or the value is not finite; the stale comment in EngineTests/Playback/PausedSeekRig.h:5 (it is
  VEProgramMonitor that observes the controller now); document or guard the nil receiver of
  `-[VEMediaLibrary routing]` and `missingAssets` (C++ references through ObjC messaging).
- Finishing work not done this round (the lead runs them): ThreadSanitizer over the facade, playback and the
  new tests, and the StressTests scheme (items 1, 2, 5 and 6 touch rendering, export and the conform).

## Known limits, with reasons
- The render goldens cannot be re-recorded (their tool needed the schema-4 engine); new migration cases are checked
  against version 4's rule computed independently instead.
- The Ken Burns editor's mode per span (Ken Burns or Transform) is remembered for the session of the project only:
  the only persisted UI state is the app-wide window layout, span ids restart per project, and a project-side store
  would be a schema change (out of scope for the Ken Burns and Transform round). A reopened project opens every span
  in the automatic mode.
- `VEEditErrorNotRepresentable` from the span calls needs a 128-bit overflow of a clip's source time: no facade input
  reaches it, so its message is covered by reading only.
- What the real Photos drag hands over (one listed type per file for a Live Photo? a rename or an overwrite when two
  promised files share a name in the staging folder?) is not observable in the test host; the double of the
  receiver's contract covers both counts, errors and collisions.

## Test gaps that need a UI-test target (XCUITest) or a person
The xctest host is not sandboxed and its synthesised NSEvents never reach SwiftUI's gesture system or the window
server's drag session, so these are covered at the model level only:
- Real SwiftUI gesture path: `TimelineGestureTests.testARealDragThroughSwiftUIIsCommittedAndNotReverted` drives the
  hosted TimelineView through `NSWindow.sendEvent` and skips with that reason. The same applies to the timeline's lane
  drags (ranges, spans, transition edges), the Ken Burns overlay's box and rectangle drags and its mode switch, and the
  Effects-tab drags onto a cut or a lane; the controllers and models behind them are tested with synthetic points.
- Sandbox-hosted export round trip (phase 7 gap 7): choose a file in the real save panel, switch the container, export.
  The model side (a container change clears the choice and asks again) is tested in `ExportModelTests`.
- A real-sandbox save/open round trip, and a main-window smoke test that triggers the thumbnail/waveform fetches it
  asserts.
- The program output on a physical second display: window, engine attachment, Escape, screen removal, key scoping and
  hide/reshow on deactivate are tested over an injected screen list and posted notifications (`OutputDisplayTests`);
  that the picture reaches the display, covers it, follows a hot-unplug and a real Cmd-Tab needs a person.
- The timeline's right-click menu (Set Interpolation, Move to Lane) is built and tested as items; the NSMenu pop-up from
  a real right-click is by hand.
- Photos drops: a real drag from Photos.app (the window server's promise session and `NSFilePromiseReceiver` reading
  the drag pasteboard), an iCloud original downloading during a drop, the PHPicker sheet itself, the folder panel in
  the real sandbox, and a security-scoped Media folder bookmark going stale (a plain bookmark's rewrite is tested).
- `VEEnginePlaybackTests.testPlayStartLatencyThroughTheFacade` on AirPods or another Bluetooth output: it skips and
  its message and log line give the measured latency (the decision is read from CoreAudio at run time).
- The divider between the source and program monitors while the source plays: the AppKit handle's drag is tested
  through `NSWindow.sendEvent` during playback, and the user confirmed the grab by hand on 2026-09-25; the original
  SwiftUI failure was never reproduced in the test host.

## Stress test observations (StressTests scheme, 2026-09-29; numbers in the test logs, Debug build)
- The timeline's minimum zoom is 2 pt/s (`TimelineViewModel.minPixelsPerSecond`), so Zoom to Fit cannot show a
  two-hour sequence: it needs 14,400 pt (`TwoHourProjectStressTests` pages through it in 11 widths of 1429 pt). A
  minimum derived from the sequence's length would let a long project fit the window.
- Footprint not explained by the frame cache: on the two-hour project the thumbnail and waveform pass adds about 230 MB
  (198 thumbnails fetched; the frame cache stays at 48 MB), and the edits and a reopen add 24 to 149 MB each, varying
  between runs, while the frame cache is full (512 MB, of which the footprint shows far less) or, after the reopen,
  nearly empty (3 MB). Everything stays under the test's bound (growth after the build under the frame cache budget
  plus 131 MB: measured +283 to +375 MB after the edits); an Instruments allocation pass over the thumbnail service
  and the reopen would say whether anything is kept that should not be.
- A cold play start (caches purged, a jump, play at once) measured 34 to 60 ms; the one at 1:40:00 was 51 to 60 ms in
  every run. The product's 50 ms target is for a cached start (`testPlayStartLatencyThroughTheFacade`); a cold start
  has no target yet.

## Test gaps that need media or a performance scheme (phase 7)
- Gap 8, size estimate against a real export in quality mode: the estimate is a bits-per-pixel heuristic (labelled "≈");
  the synthetic burn-in media compresses far better than camera footage, so a tolerance tight enough to mean something
  would only hold for that media. Needs a set of representative camera clips (not in the repository) to calibrate.
- Gap 9, long-export memory: now in the opt-in `StressTests` scheme (README, "Stress tests").
  `HourExportStressTests` exports 107,892 frames (one hour at 29.97 fps) three times, sampling the footprint at every
  progress delivery (about 700 samples): the trend stays within 0.25 KB per frame and the peak within 96 MB of the first
  warm sample (measured over four runs: +0.1 to +31.2 MB, trend -0.32 to +0.01 KB per frame). It renders at 640x360, so the hour takes
  about 80 s; a 4K soak would need 4K source media, which the generator does not make, and is still not covered (the
  per-frame buffers scale with the size, the flatness over time is what the hour shows).
- Not deterministic to unit-test: AVAssetWriter's cancel in the middle of `finishWritingWithCompletionHandler`
  (`cancelWriting` while the MP4 index rewrite runs). The early check and the FFmpeg writer's per-packet check are tested
  (`testFinishIsCancellableOnBothWriters`, `testCancelWhileFinishingKeepsTheExistingFile`); the 20 ms polling loop
  around the completion is exercised only when finishing takes longer than one slice.
