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
Brief: the lead's fix round from 84d9e20 (items 1-18), then the review of group A (R1-R7). Every item is
done. Each fix has regression tests that fail before it (see the commit messages; R6 corrects one such
claim of 5479b1b).

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
- R3 (item 5), the exact-HD snap added black lines: 7d240a6. `widthForRows` snapped any sequence within 0.5 % of 16:9, but fitRect fills only bars under a pixel
  each, so 1918x1080 exported 1920x1080 with a black column on each side (1916x1080: 2 px pillars,
  1920x1076: rows). It now snaps only when fitRect of the sequence fills the snapped frame, else keeps the
  aspect (1918x1080, 1916x1080, 1928x1080 at 1080p).
- R4 (item 5), the 1:1 placement popped during animation: 3188306. It was decided from the evaluated transform (identity only), so a move
  resting at scale 1 drew that frame 1:1 top-left and the next fitted and centred. The base (fit 1, the
  picture's centre) now depends on the sizes only and the clip transform applies about it.
- R5 (item 6), sharpening lowered the resolution on big displays: 6384a40. A 4K source in a 1080p sequence
  on a 4K display was pre-scaled to 1920x1080, sharpened and magnified. The pre-scale is decided by the
  drawn scale (as before item 6) and the amount is sharpenAmountAt(max(drawn scale, sequence or output
  scale)). Known gap (documented in Compositor.h): an export smaller than the sequence (a 4K sequence at
  1080p) sharpens while the monitors show the sequence's scale unsharpened.
- R6, a claim corrected: 5479b1b's message (and this note's "each done item has regression tests that
  fail on 84d9e20") counted "a one-frame clip whose start moves up keeps a frame after it" as failing on
  84d9e20; it passes there (checked with the doctest harness on an 84d9e20 tree): it is coverage, not a
  regression test.
- R7 (item 12), a cancelled waveform job that finished anyway stored its peaks: 22c9ea8. Stored, it also dropped another path's entry for the asset
  (the new project's file after New/Open, with more than one worker). Now neither stored nor delivered
  (`Stats::discarded` counts it). The 40-minute test AAC stays: with 5 minutes and item 12's production
  change reverted, `testAWaveformAfterNewIsTheNewProjectsFile` passed (the long computation finished
  before project 2's request), so the shorter file no longer proves that case.

Group B, continued:
- Nit (a), the adoption composite dropped SetSequenceFormat's report: 0fc765c. The placement keeps a pointer to the composite's settings
  child; a new `lateNote` block of push/pushRipple (UndoInternal, called after success) adds the report's
  sentences when it rescaled, retimed or moved clips or changed a transition.
- Nit (b), sequence audio rates AAC cannot write: 7531ef5. Measured: Apple's AAC encoder takes 22.05-48 kHz (8-16 kHz
  only at low bit rates; 64-96 kHz not at all), FFmpeg's its standard rates up to 96 kHz, PCM any rate.
  AppleWriter::validate asks AudioToolbox (an AudioConverter and its applicable bit rates), so the router
  writes 8-96 kHz AAC through FFmpeg when Apple cannot; FFAudioEncoder::validate checks the native aac
  encoder's rates; VEExporter refuses a rate no AAC encoder takes (192 kHz, 37 kHz) with what to do. Also:
  an audio rejection no longer retries the writer with the software video encoder (the error named "h264").
- Nit (c), `CompositeCommand::canRevert` checked only the last child: d192c0d. `canRevertSteps` (Command.h) reverts the later steps on a copy and
  checks each earlier one against what they leave; `revert()` is const (it changes only the project). The
  undo stack's accumulated group (AccumulatedSteps) had the same check and uses it too.
- 3, a pool miss per frame under an animated scale: a5ab1de. The plane is resampled at its exact drawn size
  (MPS scaleTransform and clipRect) into a texture pooled at the rounded-up size; the draw samples that
  region (`VESourceUniforms::planeExtent`, clamped half a texel inside it), the unsharp kernel runs over and
  reads within it (`VEUnsharpUniforms::size`). Monitors therefore pre-scale exactly too (they used the 1/32
  steps and resampled, 5 % softer than the export); `Compositor::Stats::scratchAllocations` counts misses.
- 4, the parity tests compared the export path with itself: 20b0225.
  Every ExportParityTests case renders the monitor into a texture of the program view's drawable format
  (BGR10A2) and reads it back; bounds from measured maxima (10.6 beside the coloured still: ProRes 4:2:2
  chroma, bound 12; 2-4 elsewhere, bounds 3-5; were all 14). All comparisons are at the sequence's size,
  where R5's rule makes the monitor and the export sharpen alike. With monitors made never to sharpen, the
  new sharpened case fails (12 failures); the old one passed.
- 8, garbled transition notes: 4e85b44. `planFade`'s own note is "Shortened to N frames (s): reason" (as the facade notes its fitted
  transitions); `fitTransitionRange`'s head-fade path refuses before noting. TransitionFittingTests' two
  pinning cases changed (they pinned the wrong text).
- Group B verification: full suite at 4e85b44 (`xcodebuild -scheme Framewright ... test`): TEST SUCCEEDED,
  EngineTests 533 (3 display-link skips), doctest 324, AppTests 273 (the known skip), no warnings.

Group C:
- 13 and 14, facade ownership: 6ae6323. `markUndoHistoryClean` (Undo), `forgetPostedUseCounts` (VEEngine.mm) and the
  engine's init calling `startUndoHistory` replace the cross-file writes; `VEEngine+Internal.h` no longer
  includes PlaybackController.h, <map>, <optional>, <set>. `VE_ENGINE_HEADER_INCLUDED` (VEEngine.h) and
  `VE_ENGINE_INTERNAL_HEADER_INCLUDED` make the four classes' `.mm` files `#error` (proved: importing
  VEEngine+Internal.h into VEProgramMonitor.mm, and VEEngine.h into VEMediaLibrary+Internal.h, each stop
  the build). The integration notes' claim about the class tests is corrected.
- 16, `fadeLimit`'s `excluded` parameter: 50a1309. It could never matter (a fade in is limited only by the tail transition, a fade out only by
  the fade in and the incoming dissolve: never by the span at its own edge, which is what callers
  excluded): removed with the clip copy; the test that asserted 60 with and without it now checks each
  edge against the other.
- 17, small items: c7233a8.
  `objc_subclassing_restricted` on VEExporter, VEMediaLibrary, VESourceMonitor and VEProgramMonitor (a
  subclass fails to compile, checked); `describeFrames` writes the count alone for a frame duration that is
  not a number of seconds (it wrote "(nan s)") and documents why 64 bytes always hold the seconds (a numeric
  CMTime is at most 2^63 s, so the "( s)" the review computed for >= 1e62 cannot occur); PausedSeekRig.h
  names VEProgramMonitor; `-[VEMediaLibrary routing]`/`missingAssets` document that they must not be sent
  to nil (a null reference).
- 15, untested rules and weak tests: 8a9b6cb. Mutants applied one at a time, each against the Edit and Model doctests (C++) or
  VESourceMonitorTests, VEProgramMonitorTests, VEExporterTests, VEMediaLibraryTests, VEEnginePlaybackTests,
  VEEngineReviewRegressionTests and VEEngineExportTests (Objective-C++):

  | Mutant | Before | After (killed by) |
  |---|---|---|
  | VESourceMonitor setMuted: does nothing | survived | testTheControllerFollowsTheMonitorsStateFromItsCreation |
  | pauseController does nothing | survived | same |
  | no lookahead update when the controller is created | survived | same |
  | resetIfAssetLeft: without `_asset &&` | survived | same |
  | no routing handed to the controller at its creation | survived | testPlayingWithTheRoutingItWasGivenProbesNothing |
  | registerAsset:path:routing: not forwarded to the controller | survived | same |
  | VEExporter without the size < 2 refusal | survived | testRefusalsCreateNoFileAndLeaveNoRunningExport |
  | details probe without the `_missing` skip | survived | testForgettingTheProjectDropsItsStateAndEarlierResults |
  | VEProgramMonitor scrub without the numeric guard | survived | testANewGenerationMovesToTheStartAndAnEditKeepsThePlayhead |
  | TransitionFitting ~115 binary search bound `+ 1` -> `+ 0` | survived | "a cut with 5 frames of handles on each side" |
  | ~146 fade-in length not clamped | killed | (unchanged) |
  | ~150 `length < 1` -> `< 0` | killed | (unchanged) |
  | ~162 `max(0, after)` dropped | survived | "fits a tail transition to both sides" (range ending before the cut) |
  | ~175 before-cut clamp dropped | killed | (unchanged) |
  | ~180 after-cut clamp dropped | survived | "a cut with 5 frames of handles on each side" |
  | ~197 `before > 0 &&` dropped | survived | "fits a tail transition to both sides" (no note on a refusal) |
  | ~223 planFade `>` -> `>=` | survived | "planFade fits a fade ..." (an exact fit) |
  | EditPlans ~100 neighbour frame without `- fd` | survived | "planMatchMotion compares the frames drawn at the cut" |
  | EditPlans ~101 clip frame without `- fd` | survived | same |
  | SourceProject ~38 `max(1, width)` dropped | survived | "makeSourceProject: sound alone, video alone, ..." |
  | SourceProject ~57 `videoLength > 0 &&` dropped | survived | same |

  Before: 3 of 21 killed; after: 21 of 21. The fixed sleeps are gone: VEMediaLibraryTests waits for the
  library's new `requestsInFlight` to reach zero; the "stays off" checks of both monitors read the
  controller's lookahead flag (`controllerIdleLookahead`, new on both); the program monitor's edit check
  asserts at once (publishProject is synchronous); the source monitor's "no redraw for the same setting"
  counts its picture refreshes (`pictureRefreshes`). New, for the mutants: `-[VESourceMonitor
  controllerMuted]`.

Found while doing them (open):
- The remaining step at the 0.75 threshold (6.9 % of the edge measure between scales 1/240 apart) is the
  resampling filter (Lanczos pre-scale below 0.75, bilinear above), not sharpening. Pre-scaling every
  minified picture (threshold 1.0) would remove it at some GPU cost in the monitors.
- Item 1's refusal of a clip that would have to move against its linked clip: the claim made here ("only
  out-of-sync linked pairs reach it") was false for 5479b1b: in-sync dual-system sound
  starting before its picture reached it (R2). Since R2 the linked clips move together whenever their
  decided edges keep their media; the refusal is left for a linked clip already moved by another cut by a
  different amount, which in practice needs a pair slipped out of sync.

Verification at the end of the round (8a9b6cb plus docs):
- Full suite: TEST SUCCEEDED, EngineTests 535 (3 display-link skips), doctest 326, AppTests 273 (the known
  skip), no warnings in project code.
- ThreadSanitizer (`-derivedDataPath build/tsan -enableThreadSanitizer YES`, 28 classes: the facade, its
  classes, playback, the compositor, waveforms, parity, doctest): 223 tests, 0 reports (2 timing tests skip
  under TSan).
- StressTests: passed. One-hour exports: 0 timestamp and 0 picture errors, drift +0.230, +0.400 and +0.408
  samples. Two-hour project: footprint after the edits +322.9 MB (bound 643 MB), after save and reopen
  +444.9 MB; cold starts 42.2-48.0 ms.

## Review of groups B and C (2026-10-01): status
Brief: one finding of the review fixed from 8a9b6cb (the subject of its commit is named until the next
status update gives the hash); the review's other findings are still open, for a later round.

Fixed:
- A sub-frame linked sound clip played wholly after its picture (a regression of R2, 7e2335b): "Frame-rate
  conform: a sub-frame linked sound clip stays under its picture, or the change is refused". When a sequence's
  rate changed, a linked sound clip shorter than a frame whose start shared a cut could not go back a frame,
  so its end went apart from its picture's, a frame after its start; its start being at or after the
  picture's new end, it played none of its own sound, after its picture (50 -> 25 fps: p.mov's sound
  [0.86, 0.88) from source 0.02 went to [0.88, 0.92) from 0.04, under the next clip, and the previous sound
  grew over where it was). The cut its start shares now comes back with it when every clip at that cut keeps
  its media and a frame (the sound plays [0.84, 0.88) from source 0, under its picture). An end goes apart
  only when it still overlaps the clip it is linked to and plays part of what it played; else the change
  is refused, naming the clip and why. The test that pinned [34, 35) and [35, 36) at 23.976 fps ("... ends
  after its picture") now expects the refusal: no conform keeps that sound under its picture playing its
  own sound. New: the regression test from the review's reproducer, and a property test of dual-system,
  slipped and sub-frame linked sound (the review's generators) between all rate pairs. These two and the
  changed test fail on 8a9b6cb (4, 111 and 3 failed checks); the existing property test, which now also
  checks that pairs overlap and clips play part of what they played, passes on both.
- The review's fuzzer (all 56 rate pairs, 128,800 random sequences in each of its two modes, mixed and
  sub-frame): sequences where a linked pair's shared end came apart, 1,165 and 3,981 on 8a9b6cb, 0 now;
  where a linked pair stopped overlapping, 1,546 and 3,983 on 8a9b6cb, 373 and 3 now, all of them pairs
  that shared no edge (older, below). No sequence conformed without a violation on 8a9b6cb is refused now.
  Of the conforms with a violation there, 5,013 are refused now (1,040 mixed, 3,973 sub-frame) and 144
  conform without one; 1,364 refusals there now conform (67 of them with a violation of an older kind
  below, on clips this fix does not move).

Found while doing it (open, older than R2):
- Linked pairs that share no edge are conformed edge by edge, so an overlap under about a frame can round
  away (the 373 and 3 sequences above; also in the review's fuzzer run on 6864cc0).
- A clip of about a frame or less whose start the grid or its media trims, or that moves with a whole
  clip at a cut, can play none of what it played (fuzzer `content`: 1,447 mixed and 2,819 sub-frame
  sequences now, 1,536 and 3,515 on 8a9b6cb; also on 6864cc0). The existing test "a one-frame clip whose
  start moves up keeps a frame after it" pins one such case (an unlinked clip).

The review's other findings (open, for a later round; the reviewer's reproducers and fuzzer were in the
lead's scratchpad as fa-Repro.cpp cases 2-4, fa-Alt.cpp and fa-Fuzz.cpp):
- A linked component already moved by one amount is never re-decided to a larger move that would work
  (Engine/Edit/EditOps.cpp ~3102: only a component decided at zero takes a move), so in-sync dual-system
  sound with a short head handle is refused at some rate pairs (23.976 -> 60 fps reproduces it; a shift of
  -0.016917 s conforms validly). The SequenceFormatTests case "refused: the sound moved with its picture at
  one cut would have to move again at another" pins a refusal for which a valid conform exists (both clips
  shifted -1/75 s). The status note's claim that this "in practice needs a pair slipped out of sync" is false
  (5 of 74 such refusals in the fuzzer involve no slipped pair).
- A start takes the grid time on the far side without checking that a clip starting there still has a grid
  end inside its media (EditOps.cpp ~2985-2995): a one-frame picture from its media's start, linked to sound
  ending on its media's end, is refused at 23.976 -> 24 fps although moving the pair by -0.0000834 s fits.
  Older than this round.
- The property test's generator is narrow (same-file pairs, sound starting 0-2 frames later, one track
  each); the dual-system generator added by the fix above covers part of it.
- Nothing pins that 44.1 and 48 kHz AAC exports still go through Apple's writer (they do, measured); assert
  the writer backend at both rates for the four bit rates, MP4 and MOV.
- The FFmpeg AAC fallback uses `aac_at`, which clamps an unusable bit rate silently: a 32 kHz sequence at the
  default 256 kb/s exports through FFmpeg (video included) at 192 kb/s, and the size estimate is off. The
  comments and notes that say Apple takes "22.05-48 kHz at most bit rates" overstate it (22.05/24 kHz take
  at most 128 kb/s, 32 kHz at most 192).
- `VE_ENGINE_HEADER_INCLUDED` is defined as 1 in the public VEEngine.h, so Swift imports it as a global Int32;
  define it without a value.
- The conform refusal that names both clips names one file twice for a camera clip ("“b.mov” ..., and
  “b.mov”, which ends with it, ..."); name the track when both come from one asset.
- A cascaded move can stretch a clip without a word (a one-frame picture became three frames at 24 ->
  23.976 fps); consider a note or a refusal.
- Each presented frame costs about 2 + log2(layers) heap allocations on the render thread since the
  presented-frame buffer became immutable (PlaybackController.mm ~157-165); reuse the swapped-out buffer.
- Stale comments: Compositor.h ~25-27 (the 1:1 rule), Compositor.mm ~310-317 (`quantize`) and ~423-424
  (`exactPrescaleSizes`). VEExport.h ~108-111 promises "never a black line", but the fallback branch can still
  leave one (1080x2408 at 720p; a 2700x1080 sequence at custom width 1002).
- The Ken Burns overlay (App/State/KenBurns.swift ~932-951) assumes a fitted, centred picture; with the 1:1
  base for pictures within 2 px of the frame it is off by under a pixel.

## Fix round 2026-10-01 (general review): status
Brief: the "Bugs found along the way" table and item 1 ("Now") of "Recommended order" in
`2026-10-01-general-code-review.md` (B1-B6, B8-B12, moving the machine-dependent and soak tests, the
dangling links), from fecb2a2, items 1-13 in this order; item 14 (Space plays forward at 1x) added by
the lead during the round and done after item 6. A done item names the subject of its commit
until a later status update gives the hash. Each fix has a regression test that fails with the
production change reverted (named in the commit message).

Done:
- 1, B1, the Speed/Duration sheet lost its input: dfd9b24. Root cause: ContentView built the sheet's model
  inside the sheet closure, so every store publish (the refusal's own status line) redrew the window and
  replaced it. `ProjectStore.speedSheetModel` is created once by `showSpeedSheet()` (like `exportModel`);
  `speedSheetClipIDs` is now read-only (derived). `SpeedDurationSheetTests` (the window test fails with the
  old closure: the field shows "100" again).
- 2, B2, the mute button out of step with the menu: cfa7e98. Root cause: the button kept its own `@State`,
  read only on appear, while the menu toggled the engine. `ProjectStore.isAudioMuted` reads and writes the
  engine's state (the only copy) and publishes; the button and the menu (now a Toggle, with a check mark) both
  use it. `MuteAudioTests` (the button test fails with the old `@State`: the click after a menu mute muted
  again). The menu's check mark itself is checked by hand: the hosted app's SwiftUI menu did not update its
  item's state in the test host.
- 3, B3, data race in `DecodePool::refresh()`: 15e97e4. Root cause: refresh() wrote `Stream::repairedAt` under
  the pool mutex while the worker stepping that stream owns it without the lock. refresh() now sets
  `rearmRepair` (guarded by the mutex); the worker takes it with `reopen` and clears `repairedAt` itself.
  `DecodePoolTests testRefreshDuringARepairDoesNotTouchWorkerState` (refresh() from another thread inside a
  repair's seek) and `testRefreshReArmsTheRepairOfAnEvictedPlayheadFrame` (coverage). Found doing it:
  ThreadSanitizer does not see `CMTime` struct copies in this build (a 24-byte `CMTime` written from two
  threads without ordering is not reported; an `int` is), so the old race was invisible to TSan as written.
  The proof build made every `repairedAt` access a field-wise scalar access (a temporary transform, not
  committed): TSan reports refresh()'s write against the worker's read in `lost()` on the old code and nothing
  on the fix. Earlier "0 reports" TSan runs did not cover races on `CMTime` fields.
- 4, B4, the FFmpeg encoder's colour matrix: d436644. Root cause: the encoder's CPU conversion chose BT.601 or
  else BT.709 coefficients while tagging the requested matrix. `swsColorspace` moved from FFFrameConverter.mm
  to FFmpegSupport (one mapping for decode and encode). An untagged (Unknown) matrix now follows the decode
  convention (BT.601 below 720 rows) instead of always BT.709; exports always tag BT.709, so no export
  changes. `FFmpegBackendConformanceTests testSoftwareEncodesConvertWithTheTaggedMatrix` (AV1 patches at four
  matrices decoded back: within 1 code; the old line puts BT.2020 up to 12 and 240M up to 4 codes off).
- 5, B5, thumbnails and waveforms ignored "Prefer FFmpeg": 66c4607. Root cause: the preference sets the
  router's default policy, but the services probed with their own `Config::routing` (a default-constructed
  policy). `Config::routing` is now optional; empty (the library's choice) means the router's default policy
  at each decode. The thumbnail service keys its routing memo and idle decoders by file version and policy, so
  a change applies at once. No engine coupling was added. `VEMediaLibraryTests
  testThumbnailsAndWaveformsFollowTheRoutersPolicyAtRunTime` (two fake backends count decoder opens).
- 6, B6, the undo stack ignored a failed re-apply: 6efa7b6. Root causes: `push()` ignored `previous.apply()`'s
  result after a refused ReplacePrevious step; `AccumulatedSteps::apply` returned a bare success. Now the undo
  side is dropped (as `undo()` does) and the change counted; the accumulated step merges its children's ids
  through a shared `mergeDroppedIds` (EditResult.h; `CompositeCommand` uses it too). `UndoStack::redo` takes
  an optional `EditResult *` so the redone step's ids can be read (the facade's `redo` still ignores them;
  nothing reported them on redo before either). Doctests: "a drag step whose last good step cannot be applied
  again drops the history", "an accumulated step reports its steps' dropped transitions and spans on redo"
  (both fail on the old code), "redo reports what a plain step dropped" (coverage).
- Full suite after items 1-6 (6efa7b6): EngineTests 539 (no skips), doctest 331, AppTests 277 with the 1 known
  skip; 0 failures; 612 s wall including the build.
- 14, Space after a shuttle played on in reverse: 42c1d54. Root cause: `PlaybackController::play()` and
  `togglePlay()` reused the rate the last shuttle left (falling back to 1 only at 0), so J (or J J), K, Space
  played backwards (and L L, K, Space at 2x). Both now start at +1 from the playhead; `togglePlay()` still
  stops at any rate and direction; J, K, L and `setRate:` are unchanged. The source monitor uses the same
  controller; the transport button, the Playback menu and the Space key all go through
  `PlaybackActions.togglePlay` to the engine. `PlaybackControllerTests
  testPlayFromStoppedIsForwardAtOneXWhateverTheLastShuttle` (Manual harness) and `VEEnginePlaybackTests
  testSpaceAfterAShuttleAndKPlaysForwardAtOneX` (program monitor play and togglePlay, source monitor
  togglePlay): 13 and 11 failed checks on the old controller.
- 7, B8, test runs leaked disk: 5832198. Root causes: `scratchDirectory()` never removed anything; AppTests
  made persistent `UserDefaults` suites in the app's container (removing a domain does not remove its plist
  reliably: cfprefsd writes the removal as an empty plist, at once, later or at exit); waveform and thumbnail
  jobs outlived `StoreFixture.cleanUp()` and created the cache directories again (and the Photos test double
  put its promise files in the app's tmp). Now: an XCTestObservation removes each test's scratch directories
  when it ends (`bundleScratchDirectory()` for files a run shares; `TEST_RUNNER_
  FRAMEWRIGHT_KEEP_TEST_SCRATCH=1` keeps them); `makeTestDefaults` names each suite by an absolute path in a
  directory of the test's own, removed in teardown (31 sites); `-[VEEngine waitUntilMediaWorkIsIdle:]`
  (VEEngine.h addition, for tests; the services' `waitUntilIdle`) runs before `cleanUp()` removes the fixture.
  Measured over a full default run: new entries in `$TMPDIR/FramewrightEngineTests` 221 before, 0 after; new
  plists in the container's Preferences 24 before, 0 after; new entries in the container's tmp 113 before, 0
  after. Tests: `ScratchDirectoryTests`, `ThumbnailServiceTests
  testWaitUntilIdleWaitsForTheRunningDecodeAndItsDiskCacheFile`, `VEMediaLibraryTests
  testWaitingForTheServicesCoversARunningWaveform`. Existing leftovers on disk were not touched.
- 8, the machine-dependent and soak tests out of the default run: 527751c. `PausedSeekTests
  testClicksOnTheDemoProjectShowTheirFrame` (66 s, reads `~/Movies/Framewright Demo`) and
  `testClicksOnAScreenRecordingShowTheirFrame` (61 s, 200 random real-time clicks) moved to
  `PausedSeekSoakTests` (same file), selected by the StressTests scheme and skipped by name elsewhere (and
  without `FRAMEWRIGHT_STRESS=1`); `PausedSeekTests testTwentyClicksOnAScreenRecordingShowTheirFrame` (20
  seeded clicks, 6 s) stays in the default run. `PlaybackDriftTests` stays. Default suite: 610 s wall
  (EngineTests 410 s, AppTests 182 s) at fecb2a2; 505 s (EngineTests 299 s, AppTests 187 s) with items 7-10.
  Both moved tests ran in the StressTests scheme: 0 misses of 200 each (62 s and 66 s).
- 9, B9, supplemental decoders registered only through `HardwareCaps::get()`: 1eabff9. Checked: on this Mac
  (M4 Pro, macOS 26.6) AV1 needs no registration any more (VTIsHardwareDecodeSupported('av01') is true in a
  fresh process before it), VP9 still does; with the old code a fresh process's AppleProber probe or
  AppleBackend constructor left VP9 unregistered, so a VP9 MP4 probed first was measured as not decodable by
  VideoToolbox (on older systems AV1 too). `registerSupplementalVideoDecoders()` (HardwareCaps.h, `call_once`)
  is called by `HardwareCaps::probe`, the AppleBackend constructor, `AppleProber::probe`,
  `measureHardwareDecode` and both backends' video decoders. `HardwareCapsTests
  testTheProberAndTheBackendRegisterTheSupplementalDecodersInAFreshProcess` runs its child test in three fresh
  xctest processes (prober, backend, decoder); with the old wiring the prober and backend children fail. The
  child is skipped by name in the schemes (it runs only from its parent).
- 10, B10, thumbnails failed at a clip's end: 6c0886e. Root cause: `ThumbnailService` tried one seek a frame
  before the track's end, which finds nothing where the track's duration overstates its pictures.
  `LastFrameSearch` (Engine/Media/LastFrame.h: back two frames, at least 0.25 s, doubling, decoding forward to
  the end) is used by the pool's streams (step by step), its scrub path and the thumbnail service.
  `ThumbnailServiceTests testTheLastFrameIsFoundWhenTheTrackDurationOverstatesThePictures` (a fake track of 2
  s of frames announced as 10 s: 3 failures on the old code); the pool's
  `testTheLastFrameIsHeldPastTheEndOfTheVideo` covers its two paths.
- 11, B11, span and transition titles disagreed: f658892. Root cause: `ProjectStore.title(of:isAudio:)`
  (status lines, inspector, Ken Burns readout, drop notes) knew only the dissolve and fades, while
  `TimelineViewModel.Span.title` also knew the wipes and the iris. App/State/SpanKindDisplay.swift:
  `SpanKind.title/systemImage(style:transitionKind:)`, `TransitionKind.title(style:)` /
  `sentenceTitle(style:)`, `VEEffectSpan.title/systemImage(onTrackKind:)`; used by the timeline's spans,
  `ProjectStore.title`, `timelineSpan`, the drop notes (also the linked partner's name),
  `SpanInspector.systemImage` and the Ken Burns readout's icon. `EffectLanesTimelineTests
  testWipesAndTheIrisAreNamedAlikeEverywhere` (3 failures with the old call sites).
- 12, B12, M4A with linear PCM: bafb725. Checked: libavformat's ipod muxer has no tag for PCM (`ffmpeg -c:a
  pcm_s16le -f ipod` fails writing the header; our FFMuxer refuses it in addStream through
  avformat_query_codec), so with AppleWriter refusing and FFmpegBackend's validation accepting, the router
  chose FFmpeg and the writer failed only when it opened. Not reachable from the app (no M4A export is
  offered). Engine/Media/ContainerRules.h (`checkContainerHolds`, per-stream `checkContainerHoldsVideo/Audio`)
  replaces the three copies of the rules in AppleWriter, FFmpegBackend::validate and FFMuxer::addStream (which
  keeps libavformat's own check); the messages are now the same for both backends ("linear PCM requires .mov,
  .wav or .mkv"). `ExportJobTests testLinearPCMInM4AIsRefusedByEveryWriterUpFront` (5 failures with the old
  FFmpeg validation).
- 13, the dangling links: 5efcc5d. `docs/plans/README.md` and `integration-notes.md` now name the report's
  commit (f486a6a, removed in 50ac8f2); the plan's status says the fix round is done.

- Final verification (5efcc5d): `xcodebuild -scheme Framewright -configuration Debug clean build`, 0 warnings
  in project code; full suite: EngineTests 548 (3 display-link skips), doctest 331, AppTests 278 (1 known
  skip), 0 failures, 513 s wall; no new entries in `$TMPDIR/FramewrightEngineTests`, the container's
  Preferences or its tmp. ThreadSanitizer (`-derivedDataPath build/tsan -enableThreadSanitizer YES`;
  DecodePool, ThumbnailService, WaveformService, VEMediaLibrary, VESourceMonitor, VEProgramMonitor,
  VEExporter, PlaybackController, ExportJob, VEEnginePlayback tests): 138 tests, 0 reports (the 2 timing tests
  skip under TSan). StressTests ran only PausedSeekSoakTests (item 8).

Not done: nothing of the brief. Found along the way and left open: the ThreadSanitizer blind spot for `CMTime`
copies (item 3) and the timing flake of `ExportJobTests
testMemoryIsFlatOver1800FramesAt720pSurvivesPressureAndProgressIsPaced` (see `integration-notes.md`).

## Colour grading prerequisites (2026-10-01): status
Brief: the "Before colour grading" part of the recommended order in `2026-10-01-general-code-review.md`, from
18bb9fd (0.1.8), items 1-6 in this order, one commit per item; grading itself is not in this round. Items 1-4
change no behaviour except item 1's, which the brief asks for; the golden files do not change.

Done:
- 1, preserve unknown span content on save (review core #9): bedbb1b. A span of an unknown kind on an effect lane
  is now `SpanKind::Unknown` with its kind's name and every other key kept as compact JSON text
  (`EffectSpan::foreign`, `ForeignSpanContent`); a known span keeps its unknown keys (`fields`) and its unknown
  parameters' tracks (`tracks`, with the span's length when read). All are written back on save; JSON equality
  round trip. Rules: an Unknown span has no parameters (renders as nothing), every span edit refuses it ("... from
  a newer version of Framewright"), it holds its lane (an overlap refusal says so), a clip edit that would cut it
  drops it (reported in `droppedSpanIds`), one that leaves it whole keeps it; a known span's unknown tracks go when
  its length changes (`SetSpanRange`, `splitSpan`) and the writer also leaves them out when the length differs from
  the one read. Loading drops an unknown kind on lane 0 or outside its clip's source range (with a warning) instead
  of failing the file. The facade never shows an Unknown span (`isShownSpan`: snapshots, `spansForClip/Track`,
  `spanInfo`). Tests: ProjectJSON "a newer version's span kinds, parameters and keys round trip unchanged", "a span
  of an unknown kind is kept only where this version allows a span", `ForeignSpanTests.cpp` (3 cases),
  `VEEngineSpanTests testASpanOfANewerKindIsKeptButNotShown`. Changed existing assertions (they asserted the old
  dropping): ProjectJSONTests "unknown kinds and keys of spans warn instead of failing" (the two subcases on an
  unknown kind and parameter) and "unknown fields are ignored and optional fields default" (a span's unknown key is
  now kept, compared after clearing it). Unknown keys elsewhere (clip, track, sequence, keyframe) are still
  ignored, as the brief scopes the item to spans.

- 2, descriptor tables for `SpanKind` and `SpanParameter` (review core #2): eda4028. `SpanKindInfo` (name, display
  name, track kind as `std::optional<TrackKind>`, parameters as a `std::span`) and `SpanParameterInfo` (name,
  display name, neutral, range, `SpanComposition` additive or multiplicative) in EffectSpan.cpp, indexed by the
  enums and `static_assert`ed in order; `kSpanKinds`, `kSpanParameterCount`, `infoOf`, `spanKindNamed`,
  `spanParameterNamed`, `spanKindFitsTrack`; `nameOf`, `displayNameOf`, `parametersOf`, `kindHasParameter`,
  `neutralValue`, `isValidSpanValue`, `clampSpanValue` read the tables; the parser's kind and parameter lists; the
  track rule (EditOps `checkSpanKind`, Validation `effectSpanProblem`, Clip.cpp's picture/sound tests);
  `composeSpanValue`, `canDecomposeSpanValue`, `decomposeSpanValue`, `extrapolateSpanValue` replace the arithmetic
  in `composeSpanOnto` (now composing every parameter of any kind onto `clipValueOf`'s field), `spanEdgeMotion`,
  `fitSpans`' held gain, `planKenBurns`, `planMatchSpanEdge` (now one loop for every kind), `planContinueMotion`
  and `planMatchMotion`; the refusal texts that named ranges or a parameter at 0 are derived from the tables word
  for word; the conform sentence's "Motion, Opacity and Gain" comes from the table (`effectKindsName`). Proof of no
  change: `SpanDescriptorTests.cpp` compares every derived function with a copy of the switch it replaced over all
  enumerators and a 21-value grid (infinities, NaN, -0 included, bit for bit), the four helpers with the six sites'
  arithmetic over the grid, and the derived refusal sentences with the old literals; the existing span suites
  (checked against the independent references of SpanReference.h) pass unchanged. Full suite after this item:
  EngineTests 549 (0 skips this run), doctest 341, AppTests 278 (1 known skip), 0 failures, no leftovers.

- 3, parameters indexed by enum: a813c32. `SpanTracks` holds
  `std::array<KeyframeTrack, kSpanParameterCount> byParameter` with `track(p)` and `operator[](p)`; the six
  named fields are gone, so a new parameter needs no struct or switch edit (its row in the parameter table
  and an enumerator). Facade: the kind switch in `-[VEClipInfo getBaseValues:...]` is one loop over the
  kind's parameters (`clipValueOf`); `spanValueIn` / `setSpanValueIn` read a table of `VESpanValues` member
  pointers (the one place that names the public struct's fields); `toVE(SpanParameter)` /
  `fromVE(VESpanParameter)` (static_asserted to mirror). Public additions (VETypes.h, additions only):
  `VESpanValuesGetValue(values, parameter)` and `VESpanValuesSetValue(&values, value, parameter)`, in Swift
  `values.value(for:)` and `values.setValue(_:for:)`; the `VESpanValues` struct is unchanged and the app does
  not use the accessors yet (its own parameter table stays, review app #5). JSON and golden files unchanged.
  Tests: SpanDescriptorTests "a span's tracks are indexed by parameter", `VEEngineSpanTests
  testSpanValuesAccessorsReachTheNamedFields`, `AppTests/SpanValuesAccessorTests`. Signature-only changes
  (`tracks.x` -> `tracks[SpanParameter::X]` and the like, made at the compiler's error locations, nothing
  else): AudioMixerTests.mm, ClipOpsTests, EditPlansTests, ForeignSpanTests, ReverseTests,
  SequenceFormatTests, SpanEditTests, SpanPictureTests, UndoStackTests, ExportParityTests.mm,
  EffectSpanTests, KeyframeTests, ModelTests, SchedulerSpanTests, SchedulerTests,
  SequenceFormatRenderTests.mm, ProjectJSONTests.

- 4, named shader uniforms (review render #5): c59028e. `VEDrawUniforms`'
  packed `mix` and `reserved` lanes are a `VETransitionUniforms` sub-struct (mix, progressStart/End, feather,
  `VEInt shape`, `VEUInt incoming`); `VESourceUniforms::params` is `float weight` and `VEUInt straightAlpha`;
  `VEUnsharpUniforms` has amount, threshold, rangeLow/High, width, height and `VEUInt isLuma`;
  `VEConvertUniforms::size` is width, height and `VEUInt tenBitCodes`. The shaders compare integers instead
  of decoding floats (`int(x + 0.5)`, `> 0.5`). ShaderTypes.h now `static_assert`s the size and the offset of
  every scalar group on both sides (C and Metal; checked that the Metal compiler evaluates them), replacing
  the four size checks in Compositor.mm. The sizes are unchanged except `VEUnsharpUniforms` (48 -> 32 bytes).
  The shared buffer index 0 is not a hazard (each index belongs to one pipeline's functions, and an encoder
  binds only its own); kept, with the reason in the header. The place of a future `VEGradeUniforms` is
  marked in `VESourceUniforms`. No pixel change: CompositorTests, TransitionShapeTests, ExportParityTests and
  the rest pass unchanged (no test touched the structs). Full suite after this item: EngineTests 550 (0
  skips), doctest 342, AppTests 279 (1 known skip), 0 failures, no leftovers.

- 5, the grading placement decision note: df53988. Written as
  `docs/reviews/2026-10-01-grading-pipeline-decision.md`, status proposed, for the user and the lead to
  approve. Recommendations: the grade per source in the fragment shader after the YCbCr -> R'G'B' conversion
  and before coverage, weight and blend, behind function constants (ungraded layers unchanged); grade in
  linear light (BT.1886 2.4 / sRGB / linear by transfer tag), keep the gamma-encoded blend (no change to
  existing projects or parity; linear blending only as a later per-sequence option); move `sampleYCbCr`'s
  `saturate` to the end of the grade for graded sources only; monitors composite into a pooled RGBA16Float
  intermediate plus an output pass into the framebuffer-only drawable, scopes read the intermediate;
  measured on an M4 Pro (throwaway XCTest, not committed): the output pass costs 0.024 ms at 1080p and 0.09
  ms at 2160p, compositing into RGBA16F is not slower than into BGR10A2; honour transfer for the
  linearisation and, as a separate decision, P3-D65/BT.2020 primaries by a 3x3 in linear light, not PQ/HLG.
  The lead's two additions are sections 7 (whole-clip effects: a separate ordered per-clip effect stack,
  timed spans stay on lanes) and 8 (transition parameters: a `TransitionKindInfo` / `TransitionParameterInfo`
  table; a generic mask + per-side transform + blend-mode shader model; named rows in
  `VETransitionUniforms` behind function constants).

Not started:
- 6, high-precision decode for alpha, high-bit-depth and still sources (review media #2). Not started for
  lack of room in this round, and its format choice follows item 5's sections 4 and 6. Key facts: alpha
  sources come out as 32BGRA in both backends (`nativePixelFormat` in AppleSupport.mm and
  FFFrameConverter.mm: any alpha, RGB or palette format -> 32BGRA), so 12-bit ProRes 4444 is cut to 8 bits;
  stills are drawn into 8-bit sRGB 32BGRA (AppleStillImage.mm, FFStillImage.mm), which also gamut-clips P3
  HEIC; TextureCache maps only 32BGRA among RGB formats; the compositor premultiplies straight-alpha pictures
  into RGBA8 before a minifying pre-scale (Compositor.h, "Minification"). Approach: (1) a decode option
  `DecodeOptions::highPrecision` (the router passes it for alpha, > 8-bit RGB and still sources), resolving
  to 'l64r' (`kCVPixelFormatType_64RGBALE`, 16-bit unorm; FFmpeg's `AV_PIX_FMT_RGBA64LE` through swscale,
  ImageIO through a 16-bpc `CGBitmapContext`) or, where values above 1 or wide gamut must survive (P3 stills),
  'RGhA' (`64RGBAHalf`, a half-float bitmap context in extended sRGB); first check on the device which of the
  two VideoToolbox's ProRes 4444 decoder delivers natively (else 'y416' would need a packed-AYCbCr shader
  path); (2) TextureCache maps 'l64r' to rgba16Unorm and 'RGhA' to rgba16Float as `SourceClass::RGBA` (the
  fragment shader is unchanged); (3) the pre-scale's premultiply target follows the source's precision
  (RGBA16Float instead of RGBA8); (4) the frame cache key gains the decode format first (review media #7),
  and the memory budget counts 8 bytes per pixel; (5) tests: a 12-bit ProRes 4444 with alpha (AVAssetWriter)
  and a 16-bit PNG (CGImageDestination) holding a shallow gradient decode to the high-precision format and
  keep more than 256 distinct levels through the compositor's RGBA16Float export intermediate.

- Final verification (df53988): `xcodebuild -scheme Framewright -configuration Debug clean build`, 0 warnings
  in project code; full suite: EngineTests 550 (3 display-link skips), doctest 342, AppTests 279 (1 known
  skip), 0 failures; no new entries in `$TMPDIR/FramewrightEngineTests`, the container's Preferences or its
  tmp.

Next after this round (waiting for the user's go after item 5's decision): splitting `EffectSpan` into effect
and transition types; the `TransitionRules` consolidation; the float intermediate on monitors.

## Colour grading prerequisites round 2 (2026-10-01): status
Brief: the second prerequisites round from ae6283e, after the grading decision was approved
(`2026-10-01-grading-pipeline-decision.md`), items 1-6 in this order, each committed when its tests pass;
grading itself is not in this round. Existing golden files and tests unchanged (item 4's signature-only
changes are named there).

Done:
- 1, freeze the migrations (review 1.10, core #8): 74de129. The steps moved out of ProjectJSON.cpp into
  `Engine/Serialize/ProjectMigrations.cpp` (private header `ProjectMigrations.h`), one namespace per target
  version (`toV2` ... `toV7`), each with its own copies of what it used from the model and the current
  parser/writer when frozen: version 1's speed rules (`approximateRatio`, [0.01, 100], denominator 1000) and
  `canonicalProbedTime`; version 2's asset kind names; for 4 -> 5 the keyframe reader (interpolation names,
  curve rules), the keyframe split and curve split (`splitTrack`, `splitCurve`), the exact-time rule, the
  five parameters' names, neutral values, ranges and display names, the lanes, the transition names accepted
  when frozen (the six of today: a version 4 file naming a wipe still keeps it), version 5's span order,
  span bounds and span writer; version 6's transition display names; the time writer and `describe` of
  every version. The steps depend only on TimeUtil's exact arithmetic and the JSON reader `Node`, now in
  `Engine/Serialize/JsonNode.h` (shared with the parser; its time form is that of every version).
  One visitor (`forEachSequence` / `forEachTrack` / `forEachClip`) and one error policy for all steps,
  the parser's: a list that is not an array or an element that is not an object fails with its path; the
  5 -> 6 and 6 -> 7 steps used to skip those silently (raw `json::find`) and leave the parser to fail.
  `migrateProjectJson` gained an overload with a target version (ProjectJSON.h, addition); the warning
  about version 6 content in an older file names the target version (the version the project is saved as),
  as before for a full load. Golden fixtures (additions, `EngineTests/Serialize/golden/*.migrated.json`):
  every checked-in older file migrated to version 7, `{"migratedTo": 7, "warnings", "document"}`, recorded
  with the pre-freeze code at ae6283e; three new inputs exercise every warning a step gives
  (`project-v1-adjusted.json`: rounded times, epochs, a duration off the grid, overlapping fades;
  `project-v4-adjusted.json`: unknown Motion parameter, interpolation and transition kind, a curve on a
  linear keyframe, Scale and Opacity limited at a clip's edge, fades meeting crossfades or a touching clip,
  a video clip's fades, an iris; `project-v5-adjusted.json`: version 6 content). Proof of no change: the
  migrated documents and warnings of all eleven inputs are byte-identical before and after (a scratch tool
  linking the old and the new ProjectJSON); 4,000 randomly damaged copies of the inputs load identically
  (same project, warnings or error) except 11 files with two errors, which now report the structural
  error the visitor meets first instead of the parser's first (both fail). A mutation of one frozen name
  (the iris) fails three of the golden cases. Tests: `MigrationGoldenTests.cpp` (7 cases: each input
  against its golden; the adjusted inputs reach their warnings; a golden document loads as the project its
  older file loads as; every checked-in input has a golden; migrating in parts equals at once; the target
  version is checked; the same malformed track, clip or span fails with the same message in a version 1,
  4, 5, 6 and 7 file). Full suite after this item (`xcodebuild -scheme Framewright -destination
  'platform=macOS' test`): EngineTests 550 (0 display-link skips), doctest 349 (342 + 7), AppTests 279 (1
  known skip); one failure, the known wall-clock pacing assertion of `ExportJobTests
  testMemoryIsFlatOver1800FramesAt720pSurvivesPressureAndProgressIsPaced` (0.0155 s against 0.017 s; noted
  as found-not-changed on 2026-10-01), which passed when run again alone. No files left in
  `$TMPDIR/FramewrightEngineTests`, the container's tmp or Preferences; the run adds one empty
  UUID-named directory at the container's root, as every earlier run did (326 there, the oldest from
  before this round).

- 2, the float working buffer on the monitors (decision section 4, review 1.6): 47f0dc9. Every texture
  target (the monitors' framebuffer-only BGR10A2 drawables, the solo preview, the output display,
  snapshots) is composited into a pooled RGBA16Float working texture of at least the target's size (rounded
  up in the pre-scale pool's steps, so a live resize reuses it: 1920x1080 -> 1920x1088, 16.7 MB; 2160p ->
  3840x2176, 66.8 MB per view), then an output pass (a full-screen render pass, `ve_output_fragment`) writes
  the target, limited to [0, 1] and opaque as `ve_convert_to_bgra` writes the export. The export keeps its
  intermediate. Hook for a future scope (facade-private only): `WorkingFrameReader` on `TextureTarget`, and
  `-[VEPreviewView setWorkingFrameReader:]` in `VEPreviewView+Internal.h`, called on the render thread with
  the frame's command buffer and the working texture between the two passes (snapshots do not call it).
  `TextureTarget` gained a three-field constructor so the existing `TextureTarget{texture, viewport,
  drawable}` initialisations compile unchanged (with the new fields an aggregate would trip
  -Wmissing-field-initializers), and `compositeDirectlyForTesting`, the old path, kept only for the
  comparison tests. `releaseScratchMemory` (memory pressure) releases the working texture; `Stats` reports
  it. Public header: doc comments only (VEPreviewView.h). Measured (`CompositorWorkingBufferTests`, M4 Pro,
  Debug):
  - Pixels, against the old path (both in one run): no sample of nine scenes (1:1 burn-in, a 10-bit
    gradient, three layers at 50 % scaled and rotated, a 4K source pre-scaled and sharpened, straight alpha
    over video, a dissolve, an iris, letterboxing into 1273x815, a viewport outside the target) changes by
    more than one 10-bit code. But many change by one: 30 % of the samples of a 1:1 picture, 0.05-31 % by
    scene. Cause, measured: the GPU stores each blended value in half float rounding towards zero (every
    stored value lies at or below the exact float composite, less than one half-float step below), and the
    output pass rounds that to 10 bits; so a sample lies within 0.84-1.0 codes of a 32-bit float composite
    for one layer (0.49-0.50 straight into 10 bits) and within 0.9-1.31 codes for several (0.78-1.08
    straight). The export's intermediate has always had the same rounding; monitors and export now agree.
    Question for the lead: if half a code of accuracy on the monitors matters more than matching the export,
    an RGBA32Float working texture (twice the memory) would make single layers exact.
  - The reader sees, bit for bit, what an RGBA16Float target composited directly holds, and the target is
    exactly that limited to [0, 1] and rounded to the nearest 10-bit code.
  - GPU time per frame (median of 120 interleaved frames, three runs): the extra pass adds +0.01 to +0.09 ms
    at 1080p (1 layer: 0.12-0.33 ms against 0.09-0.25; 3 layers at 50 %: 0.17-0.19 against 0.16-0.18) and
    +0.06 to +0.09 ms at 2160p (1 layer: 0.28-0.29 against 0.20; 3 layers: 0.64-0.66 against 0.58-0.60),
    against the note's estimate of 0.024 and 0.09 ms. The parity tests (`ExportParityTests`, which render
    the monitor into a BGR10A2 texture target and so now go through the working texture), the compositor,
    sharpen, preview-view, sequence-format, transition-shape and monitor suites pass unchanged, and so do the
    redraw-budget tests in the full run.
  Full suite after this item: EngineTests 555 (0 skips), doctest 349, AppTests 279 (1 known skip), 0
  failures; no files left (again one empty UUID-named directory at the container's root).

- 3, high-precision decode (decision sections 4 and 6, review 1.7 and 2.5): d77e2e7. `DecodeOptions::
  highPrecision` (MediaTypes.h), set by the program monitor's, the source monitor's and the export's decode
  pools (not by thumbnails): alpha and RGB video deeper than 8 bits decodes to 'l64r' (16-bit unorm RGBA,
  straight alpha, `kHighPrecisionRGBAFormat`) on both backends (Apple: `nativePixelFormat(details,
  highPrecision)`, AVAssetReader delivers it natively for ProRes 4444, checked on this Mac: 1024 levels in a
  row against 65 for 'BGRA'; FFmpeg: libswscale to RGBA64LE, or VTPixelTransferSession from 'y416');
  stills deeper than 8 bits decode to 'l64r' (16-bit sRGB) and stills whose colour space is wide gamut to
  'RGhA' (half float in extended-range sRGB, `kExtendedRGBAFormat`: P3 red is (1.09, -0.23, -0.15)), both
  premultiplied, tagged sRGB, drawn by one helper for both backends (`Engine/Media/StillDrawing.h`). The
  FFmpeg still path hands such pictures to CoreGraphics in their ICC profile's space, or in the space their
  cICP tags name (FFmpeg reports a PNG's cICP instead of its ICC profile when both are present, which is
  what ImageIO writes for Display P3; Display P3, BT.2020 and sRGB are mapped). 8-bit sRGB stills and 8-bit
  alpha video keep 'BGRA', bit for bit. TextureCache maps 'l64r' to rgba16Unorm and 'RGhA' to rgba16Float
  (`SourceClass::RGBA`, the fragment shader unchanged but for the clamp below); the pre-scale of deep RGBA
  (and its premultiply) uses RGBA16Float instead of RGBA8; `sampleRGBA` limits samples to [0, 1] as
  `sampleYCbCr` does for ungraded sources (decision section 3), a no-op for unorm textures, so an
  extended-range still renders as its 8-bit decode did (measured: identical 8-bit pixels for a P3 still).
  Frame cache key (review 2.5): entries are keyed by `FrameKey` = (asset, `DecodeFormat`: pixelFormat,
  maxDimension, highPrecision); an `AssetId` converts to the default format's key; `purge`, focus and epochs
  cover every format of an asset; producers and consumers use their pool's format (`DecodePool::
  decodeFormat()` / `frameKey(asset)`; PlaybackController's frame source and prefetch, ExportJob).
  Tests (`HighPrecisionDecodeTests`, 9 cases): a 12-bit ProRes 4444 ramp written at test time decodes to
  'l64r' on both backends with 1024 levels in a row (8-bit: 256), 1024 in the monitors' working texture
  (8-bit: 256) and 831 luma codes in a 10-bit export; a 16-bit PNG ramp gives 1024 / 1024 / 876 on both
  backends; a Display P3 PNG (both backends, within 0.01 of each other) and a P3 HEIC (Apple) decode to 'RGhA'
  with values outside [0, 1]; an Adobe RGB PNG (ICC profile only) likewise through FFmpeg's ICC path; 8-bit
  sources (still.png, H.264) give the same format and the same bytes with or without the option; the
  frame cache keeps formats apart; a pool puts and finds under its own format; a minified straight-alpha
  'l64r' picture keeps 512 levels in 512 columns; the texture cache maps both formats. Changed existing
  test (deviation, in the same commit): `TextureCacheTests testUnsupportedFormatsFailWithTheFormatName`
  used 'RGhA' as its example of an unsupported format, which the brief makes supported; its example is
  now 'b64a' (`kCVPixelFormatType_64ARGB`). Not changed: the probers still report a still's bit depth as 8
  (Apple) and its colour as sRGB (both), since nothing reads them for decoding; HDR (PQ, HLG) stills are not
  tone mapped (as before). Full suite after this item (before the test fix above): EngineTests 563, the
  only failure that test, AppTests 279 (1 known skip), doctest 349.

- 4, split `EffectSpan` into effect and transition types (review 1.9): 4da7893 (step 1, containers) and
  520e7c0 (step 2, types). A clip keeps `transitions` (lane 0, at most one per edge, the head's first) apart
  from `spans` (lanes 1-3). `TransitionSpan` (EffectSpan.h): id, edge, start/end offsets from the edge,
  `kind` (TransitionKind), `unknownKindName` (a newer version's kind kept by name) and `foreignFields`
  (its unknown keys); lane 0 is a constant, so it has no lane, keyframes, effect kind or `ForeignSpanContent`
  of its own. `EffectSpan` lost `edge`, `transition`, `unknownTransitionName` and `isTransition()`;
  `SpanKind::Transition` stays in the kind table (the descriptor tables keep the kinds and parameters) as the
  project file's name of a transition. Lookups by id are per kind (`Clip`/`Sequence::findSpan`,
  `findTransition`, `hasSpan`); `placeTransition`, `checkTransitionSpan`, `linkedTransition`, `ClipIndex::
  linkedTransition`, the conform helpers, `spanTimelineRange` and the facade's `makeEffectSpan` (overloads)
  take a `TransitionSpan`. Where an id of either kind arrives the transition is looked up first, so every
  refusal keeps its text (span edits: "... is a transition; change it with the transition edits"; matching:
  "a transition has no values to match"; Ken Burns: "the Ken Burns move needs a Motion span", now
  `kenBurnsNeedsMotionSpan()`, used by `planKenBurns` too; Continue on Next Clip). The project file keeps one
  "spans" list: the parser reads each element into either type (`ParsedSpan`, with the lane the file gave
  it), the writer writes the transitions first as the sorted list had them, and repairSequence repairs and
  warns in the file's order (a transition's lane comes from the file). Proof of no change: JSON and golden
  files unchanged (the migration goldens and every round trip pass), the facade API unchanged, and the
  full suite green after each step: EngineTests 564 (0 skips), doctest 349, AppTests 279 (1 known skip), no
  files left (one empty UUID-named directory per full run at the container's root, as before this round).
  Tests changed (named; container or type changes only, except the three removals):
  - step 1 (where tests put transitions into, took them out of, or indexed them in `Clip::spans`):
    AudioMixerTests.mm, ClipOpsTests, EditPropertyTests, EffectsEditTests, ReverseTests (transitions
    compared numerically like spans), SequenceFormatTests, TransitionFadeEditTests, TransitionFittingTests,
    TransitionTrackOpsTests, ExportJobTests.mm, ModelFixtures.h, ModelTests, PlaybackTestSupport.mm,
    SchedulerSpanTests, TransitionShapeTests.mm, ProjectJSONTests, HourExportStressTests.mm; where a check
    that a clip "owns nothing" or has "no fade" read `spans.empty()`, it now reads both lists.
  - step 2 (the new type and lookups: `TransitionSpan` declarations, `.kind`/`.unknownKindName`/
    `.foreignFields`, `findTransition`, the fixtures' new `transition(id)`): AudioMixerTests.mm,
    ClipOpsTests, EditPropertyTests, LockedTrackTests, ReverseTests, SequenceFormatTests,
    TransitionFadeEditTests, TransitionFittingTests, TransitionTrackOpsTests (the linked-transition loop
    walks transitions; effect spans are checked to have none), ExportJobTests.mm, ExportParityTests.mm,
    EffectSpanTests, ModelFixtures.h, ModelTests, PlaybackTestSupport.mm, SchedulerSpanTests,
    SchedulerTests, TransitionShapeTests.mm, ProjectJSONTests, HourExportStressTests.mm.
  - removed, as the types can no longer express the state they checked: EffectSpanTests "track
    validation" subcase "a transition with keyframes" (`spanTracksProblem` of a transition), EffectSpanTests
    "lane rules" (a fade moved to lane 2: "a transition lies on lane 0 only") and "hold after" (a fade's
    `spanActsAt`), ModelTests "validateProject catches broken invariants" (a transition on lane 1). The
    file-repair path for a transition on another lane is still covered by ProjectJSONTests.

- 5, one owner for transition and fade rules (review 1.8): 1c70af7. `Engine/Model/TransitionRules.h`:
  `TransitionRules::edgeRoom(project, track, owner, edge, shape, frameDuration)` returns per side (`inside`
  the owner; `beyond` the cut for a cross dissolve, when a clip touches the owner's end) the parts (the
  clip's length, its other transition's part inside it, a dissolve coming in, the next clip's tail span,
  the media beyond the cut in timeline time), the room (exact) and its whole frames, the limit
  (`RoomLimit`: ClipLength, OtherEdge, IncomingDissolve, Media), the limiting clip and the sentence (fade
  or transition wording, as before); `fadeRoom` (a fade's side, no assets needed), `partInside`,
  `incomingPartInside`, `wholeFrames`, `fadeRoomBeside` and `conformFadeFrames`. The callers are thin:
  `fadeLimit` and `transitionSideLimits` copy a side into their structs (`editErrorOf(RoomLimit)` maps the
  limit to the edit error); `checkTransitionSpan` reads the parts in its own order with its own messages;
  `pruneInvalidTransitions`' "a fade out gives way to a dissolve coming in" reads the fade's room (on the
  clip's timescale, as before); `setClipFade` reads `partInside` / `incomingPartInside`; `Clip::fitSpans`
  fits its fades with `fadeRoomBeside`; the frame-rate conform's frame-by-frame trial loop is
  `conformFadeFrames` (the frames a fade keeps), then one check. `Sequence.h`'s
  `incomingTransitionInside`, a copy, is removed. The frozen v4 -> v5 copy is left as it is (item 1).
  Proof of no change: `TransitionRulesTests` (10 cases) compares each caller with a copy of its code from
  before (520e7c0) over 3,000 random tracks each (valid and invalid transitions, sample-length fades,
  wipes on audio, stills, 0.5x/2x, reversed clips, handles at both ends of the media): fadeLimit,
  transitionSideLimits (all fields), checkTransitionSpan (kind, message, clip; 4,386 issues and 2,375 valid
  transitions), pruneInvalidTransitions (sequence and notes), setClipFade (result, message, clip, ids),
  Clip::fitSpans' fades after random trims of either edge, the conform's fade frames at 25, 29.97, 24 and
  60 fps: all equal. One difference, not reachable: a cross dissolve's room before its cut counted a fade
  in at the owner's start or else a dissolve coming in; it now subtracts both, which differs only when a
  clip has both, a fade in on a clip another clip touches (invalid: the cut is the other clip's; pruning
  removes the fade before any caller sees the clip; the test asserts it is invalid wherever it differs).
  Disagreements between the old copies, kept as they are (each shown by a test; question for the lead
  whether to unify them, which would change what users see):
  - D1, a clip's fade in and its tail dissolve no longer fit the clip: a trim shortens the fade in
    (`Clip::fitSpans`, "fades give way to a cross dissolve"), but the frame-rate conform keeps the fade in
    and shortens the dissolve (the dissolve is fitted around the fade in by `transitionSideLimits`;
    `conformFadeFrames` does not count the dissolve). Test: "D1, a fade in beside a tail dissolve: a trim
    shortens the fade, the conform the dissolve" (30 -> 25 fps: the fade keeps 15 frames, the dissolve
    goes from 15 + 15 to 10 + 15).
  - D2, a dissolve into a clip and the clip's fade out no longer fit it: pruning (after every edit, on
    load) shortens the fade out, but the frame-rate conform shortens the dissolve (fitted first around the
    fade out at its wanted length). Test: "D2, a dissolve into a clip that fades out: pruning shortens the
    fade, the conform the dissolve" (pruning: fade out 20 -> 15; conform at 25 fps: dissolve 15 + 15 ->
    15 + 10, fade out keeps 15).
  (The limits the app shows, `fadeLimit` and `transitionSideLimits`, are symmetric on purpose: whichever is
  being sized is limited by the other.)
  Full suite after this item: EngineTests 564, doctest 359 (349 + 10), AppTests 279 (1 known skip) with one
  failure, `TimelineRedrawTests testPlayheadMovesDoNotRedrawTheTimeline` (5 canvas draws during 120
  playhead moves, bound 2; the canvas still settling after its thumbnails), which passed 3 of 3 when run
  again alone (0 draws); this item changes nothing the app's timeline draws.

- 6, transition descriptor tables (decision section 8): f8361eb. `Transition.h`: `TransitionKindInfo` (name,
  display name, track: `nullopt` for either or `TrackKind::Video`, mask family `TransitionMask` None / Linear /
  Radial, parameters) and `TransitionParameterInfo` (name, display name, `TransitionParameterType` Scalar /
  Angle / Point / Colour / Enum, default, range per component, an Enum's choices), each checked by
  `static_assert`s (rows in enum order, defaults valid, only the unmasked kind on either track). A
  `TransitionSpan` carries `TransitionParameters` (static values indexed by the parameter enum, as `SpanTracks`
  is; unset means the table's default) and `foreignParameters`. One parameter, as the decision asks for no new
  transitions: `Softness`, the half width of the shaped kinds' soft edge, default 2 sequence pixels (the
  `kTransitionFeather` every wipe and iris had; now its alias), range 0-1000, honoured end to end (the
  scheduler puts it on `LayerTransition::softness`, the compositor into the existing `feather` uniform; no
  shader change). The table now answers what was written out in several places: the names (`nameOf`,
  `displayNameOf`, `transitionKindNamed`; a value outside the enum is still "unknown"), the track rule
  (`transitionKindFitsTrack`: checkTransitionSpan, the audio repair on load, SetTransitionKind,
  `transitionKindOnTrack`), and the compositor's shaped / closing-iris tests (`isShapedTransition`, the
  Radial mask). File: `"parameters": {"softness": 4}` on a transition, left out when the span sets none, so
  every existing file reads and writes byte for byte as before (the goldens pass unchanged); forms per type in
  `Engine/Serialize/TransitionValueJSON.h` (a number; [x, y]; [r, g, b, a]; a choice's name). Unknown names
  are kept with a warning, an unknown kind's parameters all kept silently, an unknown Enum choice kept with a
  warning (the default plays); a value of the wrong JSON shape fails the load with its path; validation
  refuses a value out of range or a parameter the kind does not have (as it refuses an effect span's
  keyframes of another kind's parameter). Edits: SetTransitionKind to another kind keeps the parameters the
  new kind has (a wipe's softness carries over to the iris) and drops the rest and the foreign ones (they
  described the old kind); the same kind changes nothing. The audio repair on load ("using a cross
  dissolve") drops what a cross dissolve does not have and says so ("(without its Edge Softness)"), keeping
  the foreign ones. Not done (approach): kinds as presets (one Wipe kind by angle, the old names as file
  aliases) changes the facade's `VETransitionKind` and the app's panel, so it belongs with the UI round; the
  facade has no parameter API yet (VETransitionInfo, a coalescable SetTransitionParameter edit); the other
  types have their forms and validity tested but no parameter uses them yet.
  Proof: default output unchanged (the feather uniform is `float(2.0)` as before; TransitionShapeTests,
  ExportParityTests and the migration render tests pass unchanged). New tests: `TransitionParameterTests` (6
  doctest cases: the kind table against the names and rules of before, the parameter table and validity,
  every type's form, errors and round trip, `TransitionParameters`, file round trip / unknown names / unknown
  kind / wrong shape / validation / audio repair, SetTransitionKind with undo) and `TransitionSoftnessTests`
  (3 XCTests: every shape at softness 0, 12 and 40 against the reveal reference with that f, the band 2f
  columns wide at an instant; the scheduler hands both layers of a cut and a fade's layer their span's
  softness or the default, and the scheduled frames draw it; the dissolve ignores it). Mutation check: the
  compositor using the constant again and the scheduler not passing the value fail 2 of the 3 XCTests.
  Full suite after this item: TEST SUCCEEDED, EngineTests 567, doctest 365, AppTests 279 (1 known skip), no
  display-link skips; no files left in `$TMPDIR/FramewrightEngineTests`, the container's tmp and Preferences
  unchanged.

Final verification (f8361eb plus docs):
- `xcodebuild -scheme Framewright -configuration Debug clean build`: 0 warnings in project code. Full suite (the
  run after item 6): TEST SUCCEEDED, EngineTests 567 (baseline 550; no display-link skips), doctest 365
  (baseline 342), AppTests 279 (1 known skip). Every full run of the round adds one empty UUID-named
  directory at the app container's root (349 there now; the pattern predates the round: AppTests' host); no
  other leftovers.
- ThreadSanitizer (`-derivedDataPath build/tsan -enableThreadSanitizer YES`; 33 classes: Compositor,
  CompositorPreviewView, CompositorSharpen, CompositorWorkingBuffer, TransitionShape, TransitionSoftness,
  TextureCache, HighPrecisionDecode, PlaybackController, PlaybackDisplayPath, PlaybackDrift,
  PlaybackLookahead, PlaybackPreviewSolo, PlaybackTransport, PausedSeek, ProgramFrameProvider, the ten
  VEEngine* classes, VEExporter, VEMediaLibrary, VEProgramMonitor, VESourceMonitor, FacadeCommands,
  ExportJob, doctest): 265 tests, 0 reports (the 2 timing tests skip under TSan). TSan does not see `CMTime`
  struct-copy races (round 2026-10-01, item 3).
- StressTests: passed. One-hour exports: 0 timestamp and 0 picture errors in all three, drift +0.230, +0.400
  and +0.408 samples (last round the same). Two-hour project: footprint growth after the edits +286.5 MB
  (last numbers +283 to +375 MB; bound 643 MB), after save and reopen 866.3 MB (+415.9 MB over the built
  project, last round +444.9 MB); cold starts 42.2, 42.8 and 59.4 ms (34-60 ms); 0 dropped, 0 late. Paused
  seeks: 0 misses of 200 on both sources.

Not done: nothing of the brief. Round accepted by the lead 2026-10-02 (full suite EngineTests 567, doctest 365,
AppTests 279; goldens: 14 added, none changed; `VEEngine.h` unchanged) and pushed.

Decisions taken by the user, 2026-10-02:
- **Working texture:** stays RGBA16Float. Half float already carries the display's 10-bit precision;
  RGBA32Float would double the memory for no visible gain.
- **D1 and D2: one rule.** When a fade and a dissolve on the same clip no longer both fit, the fade gives way
  and the dissolve keeps its length, everywhere. Today trims and pruning already do this; the frame-rate
  conform shortens the dissolve instead, so the conform changes to match. Its tests "D1 …" and "D2 …" change
  with it. Implemented in colour grading slice 1, item 1 (status below).

Still open: kinds as presets and the facade's parameter API (item 6, the UI round). Also, each full test run
leaves one empty per-process temporary directory (`<UUID>-<pid>-<hex>`) at the app container's root; 339
were removed by hand on 2026-10-02. The cause (probably an item-replacement or temporary directory the test
host asks Foundation for and never removes) is not fixed.

## Colour grading slice 1 (2026-10-02): status
Brief: the first grading round from 9127327, items 1-7 in this order, each committed when its tests pass:
D1/D2 as one rule, the clip grade in the model (schema 8), its edit commands and facade API, the grade in the
shader, its tests, the colour panel, the luma waveform. Decision followed:
`2026-10-01-grading-pipeline-decision.md` (approved; section 7's decision: the grade is a property of the clip).

Done:
- 1, D1/D2, one rule (the user's decision of 2026-10-02): 96e2cd5. The frame-rate conform
  (`SetSequenceFormat`) now fits the cross dissolves first, with every fade set aside, then each fade in
  what the dissolves leave (`TransitionRules::conformFadeFramesBesideDissolves`: a fade in less its clip's
  tail dissolve's share before the cut, a fade out less its fade in and a dissolve coming into its clip);
  a clip's fade in still comes before its fade out. The sentences keep the order of the transitions on their
  tracks, and a fade shortened or removed by a dissolve says so ("... it gives way to the cross dissolve at
  the clip's end." / "... coming into the clip.", "crossfade" on sound). So when a fade and a dissolve on one
  clip no longer both fit, the fade gives way everywhere (trims, pruning, the conform).
  `TransitionRules::conformFadeFrames` is unchanged (the clip and its other fade; one term of the new rule).
  Found and fixed in the same code: a fade out shorter than half a frame of the new rate was given its one
  frame after the clip's end (`frames.after = 1` for every edge), so the conform left it invalid and the
  pruning after it dropped it unreported; it now keeps its frame inside the clip (a fade in or a dissolve
  after the edge, as before). Tests changed (they pinned the old behaviour, allowed by the brief): "D1, a fade
  in beside a tail dissolve: a trim and the conform both shorten the fade" (conform: the fade 15 -> 10 frames,
  the dissolve keeps 15 + 15) and "D2, a dissolve into a clip that fades out: pruning and the conform both
  shorten the fade" (conform: the fade out 15 -> 10, the dissolve keeps 15 + 15). New: "the frame-rate
  conform fits each fade in what the dissolves leave" (per role: a fade in shortened and one removed, a fade
  out on sound shortened beside a crossfade, a fade out removed while a separate clip keeps its fade in's
  priority over its fade out; each sentence checked, every case through `applyReversible`) and "the
  frame-rate conform keeps a sub-frame fade as one frame at its own edge" (failed before the fix for the
  fade out). Doctests 367 (365 + 2).

- 2, the clip grade in the model (schema 8): f3adc2b. `Engine/Model/ClipGrade.h`: `GradeParameter`
  (Exposure, Contrast, Temperature, Tint, Saturation) and a `GradeParameterInfo` table in the descriptor
  style (name, display name, unit, neutral, range; `static_assert`ed in order, neutral within a finite
  range and equal to `ClipGrade`'s default): exposure 0 stops in [-5, 5], contrast 1× in [0, 2],
  temperature 0 in [-100, 100], tint 0 in [-100, 100], saturation 1× in [0, 2] (temperature and tint are
  relative scales with no unit; their meaning is in the header). `Clip::grade` is a `ClipGrade` (the
  values indexed by parameter, and `foreign`, the newer version's entries as compact JSON text);
  `isNeutral` (every value neutral: no grade) and `isEmpty` (neutral and nothing foreign: nothing to
  write). Clip equality includes it; a split copies it to both pieces; a through edit needs equal grades
  (`isThroughEdit`). Validation (`validateClip`): every value finite and in range (`gradeProblem`:
  "grade Saturation 2.5 is outside its range [0, 2]"), and only a clip on a video track has a grade.
  File: `"grade": {...}` on a clip with the values that are not neutral plus the foreign entries, left out
  when empty, so a project without grades writes exactly what version 7 wrote but the version number.
  Reading: an unknown grade key is kept and written back with a warning; a value out of range is limited
  to it with a warning; a non-number fails the load with its path; a grade on a clip of an audio track is
  dropped with a warning. Schema 8: `toV8` in `ProjectMigrations.cpp` converts nothing (a version 7 file
  that already holds grades keeps them, with a warning per clip, as `toV6` does), `kLastMigrationTarget` 8.
  Goldens (additions only, in `EngineTests/Serialize/golden/v8/`, excluded from the test bundle in
  `project.yml` because their names repeat the version 7 ones; the tests read the source tree): every
  older fixture migrated to 8 (11 files, derived from the frozen version 7 goldens by the step's rule and
  checked against the engine), `project-v7-adjusted.json` (a version 7 file holding grades, an unknown
  grade key, a value out of range, a grade on a sound clip) with its golden, and `project-v8.json` (the
  current writer, byte for byte, with three graded clips). No existing golden changed. Tests:
  `ClipGradeTests.cpp` (6 cases: the table, neutral, validation, writing, foreign keys and bad values,
  split and through edit), `MigrationGoldenV8Tests.cpp` (6 cases: each input against its v8 golden, the
  7 -> 8 step changes only the version (against the v7 goldens), the graded version 7 file, golden loads
  as its older file, in parts, every input has a v8 golden), ProjectJSONTests "the checked-in version 8
  project matches the current writer byte for byte". Existing tests changed by the schema number only
  (named): ProjectJSONTests "format details" (`kProjectSchemaVersion == 8`), "the checked-in version 5
  project loads with every clip forward" and "the checked-in version 6 project opens configured, with
  sharpening on" (expected `"schemaVersion"` 8), "a version 5 file with version 6 content opens with a
  warning naming it" ("saved as version 8"), "the checked-in version 7 project matches the current writer
  byte for byte" (renamed "... but for its version": the golden with its version line set to 8 must equal
  the writer's output, which proves ungraded projects write as before); MigrationGoldenTests "a golden
  document loads as the project its older file loads as" (the expected warnings name the current version as
  the version the project is saved as, as "migrating in parts" already did for its parts). Doctests 380.

- 3, edit commands and the facade API: 139f4ef. Edit rules in `Engine/Edit/GradeEdits.h` (a new file beside
  EditOps, which is 3,600 lines): `GradeChange` (the values to set, nullopt keeps the clip's own; for a whole
  grade the foreign entries too: `of(parameter, value)`, `whole(grade)`), `SetClipGrade` (one or several
  clips, one undo step; sets only the parameters given; refused as a whole for no clips or values, a value out
  of range or not finite ("Saturation must be a number from 0 to 2 (not 2.5)."), a missing, duplicated or
  locked clip, or a clip on an audio track (TrackKindMismatch); a change that changes nothing records no
  step; undo names "Change <parameter>", "Change Grade", or the caller's ("Paste Grade", "Reset Grade")),
  `summarizeGrades` (per parameter the value the selection's picture clips agree on, or mixed) and
  `gradeTargets`. Coalescing is the existing one: a control drag is `setGradeValue` steps in one
  ReplacePrevious group (or Accumulate) and makes one undo step. Facade: `VEEngine (Grade)` in
  `VEEngine+Grade.mm`; the copied grade is `_copiedGrade` (a value; it outlives New and Open). The four
  extracted classes are untouched. Public additions (additions only), VETypes.h: `VEGradeParameter`,
  `VEGradeParams`, `VEGradeParamsNeutral()`, `VEGradeParamsUnchanged()`, `VEGradeParamsGetValue` /
  `VEGradeParamsSetValue` (Swift `value(for:)` / `setValue(_:for:)`), `VEGradeParameterInfo` (the engine's
  table: name, display name, unit, neutral, range; `allParameters`, `info(for:)`), `VEGradeSelection`
  (`clipIDs`, `values` with NaN where mixed, `isMixed(_:)`, `anyGraded`), `VEClipInfo.grade` and
  `.hasGrade`; VEEngine.h: `setGrade(_:forClips:)` (NaN fields unchanged), `setGradeValue(_:for:clips:)`,
  `grade(ofClips:)`, `copyGrade(ofClip:)`, `hasCopiedGrade`, `copiedGrade`, `pasteGrade(ontoClips:)`,
  `resetGrade(ofClips:)`. The calls take a selection: clips on audio tracks are left out (linked sound in
  a selection grades its pictures); none left is refused (TrackKindMismatch). Tests: `GradeEditTests.cpp`
  (5 doctest cases: one and several clips keep what differs, several parameters, whole grades, every
  refusal changing nothing, no-op, a drag in both coalescing modes is one step, mixed and agreeing
  summaries) and `VEEngineGradeTests` (6 XCTests: the table from the engine, a multi-clip set with linked
  sound in the selection and the mixed query, a coalesced control drag, copy/paste/reset with undo and
  across New, refusals, save and open). Full suite after this item: TEST SUCCEEDED, EngineTests 573 (3
  display-link skips), doctest 385, AppTests 279 (1 known skip); no files left in
  `$TMPDIR/FramewrightEngineTests`, the container's tmp or Preferences (one UUID-named directory at the
  container's root, the known pattern).

- 4, the grade in the shader: 2cc418d. `Engine/Render/ColorGrade.h` holds the per-pixel grade, compiled by
  Shaders.metal and by C++ (the CPU reference `gradeReference`, the uniforms `gradeUniformsFor` and the
  transfer choice `gradeTransferFor`). Steps: NaN -> 0 and +-inf -> +-float max by their bits (fast math),
  encoded values limited to +-256 (keeps every later step finite), an encoded value within 2^-20 of 0 is 0
  (see below), linearised by the source's transfer (BT.1886 2.4 for BT.709 / SMPTE 240M / PQ / HLG /
  untagged video, sRGB for sRGB-tagged sources and untagged stills, identity for linear; mirrored for
  negatives), the channel gains (2^exposure times the temperature/tint gains red 2^(t/2), green 2^(-m/2),
  blue 2^(-t/2) for t, m over 100, divided on the CPU in double by their BT.709 luminance kept at least 1e-6;
  exactly 1 when neutral), saturation (a mix toward BT.709 linear luminance), contrast by the section 2
  rule (pivot 0.18, epsilon 2^-14, log2 only of values >= epsilon, the line v * f(epsilon) / epsilon below
  it with the slope computed on the CPU, contrast 1 the identity; its input limited to +-2^60 so the curve is
  finite on its own), re-encoded, then the caller's clamp. Each step at its neutral value returns its input
  bit for bit. `VEGradeUniforms` (gain, saturation, contrast, contrastSlope, transfer; 32 bytes) is the last
  member of `VESourceUniforms` (176 bytes now; offsets `static_assert`ed), filled per source in `fillSource`
  from `VideoLayer::grade` (copied from `Clip::grade` by the scheduler) and the picture's transfer tag
  (`TextureSet::transfer()`, read from kCVImageBufferTransferFunctionKey); a dissolve pair fills A and B from
  their own layers. Function constants `VEFunctionConstantSourceAHasGrade` / `...BHasGrade` select graded
  sources (`PipelineKey` gained the two bits; a compositor made for a monitor prepares all 20 layer pipelines
  instead of 6: 1.1 ms once compiled). A graded source skips `sampleYCbCr`'s clamp and `sampleRGBA`'s colour
  clamp (its alpha stays clamped); straight or premultiplied RGBA is graded unpremultiplied (divided by alpha,
  0 where alpha is 0) and premultiplied again; the grade's result is clamped to [0, 1] before coverage, weight
  and blend. An ungraded layer runs the code it ran before (the graded branches are compile-time false).
  Black residue: the YCbCr matrix leaves 2e-8 to 5e-8 at video black in the ungraded picture too (measured:
  420v 4.8e-8, x420 2.2e-8, 420f 3.5e-8 in red), which exposure +5 lifted to about 1e-6; values within 2^-20
  (a sixteenth of a 16-bit code) count as 0, so a graded black frame is exactly black. Fast math: the curves
  use `metal::fast`; measured against the CPU (libm) the largest difference is 8.08e-6 with either
  `metal::fast` or `metal::precise`, and the GPU cost per graded 1080p layer +0.14 to +0.16 ms with fast
  against +0.53 ms with precise (M4 Pro, median of 60 frames; one ungraded layer 0.10-0.16 ms in the same
  runs); a graded dissolve pair +0.29 to +0.33 ms. Proof of no change for ungraded layers: CompositorTests,
  CompositorWorkingBufferTests, CompositorSharpenTests, TransitionShapeTests, TransitionSoftnessTests,
  ExportParityTests, SequenceFormatRenderTests, HighPrecisionDecodeTests, TextureCacheTests,
  ProgramFrameProviderTests and CompositorPreviewViewTests pass unchanged (3 display-link skips). Not graded:
  the source monitor (it shows the media), thumbnails.

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
