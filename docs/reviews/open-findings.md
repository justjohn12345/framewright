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
dangling links), from fecb2a2, items 1-13 in this order. A done item names the subject of its commit
until a later status update gives the hash. Each fix has a regression test that fails with the
production change reverted (named in the commit message).

Done:
- 1, B1, the Speed/Duration sheet lost its input: dfd9b24. Root cause: ContentView built the sheet's model inside the sheet closure, so every store publish
  (the refusal's own status line) redrew the window and replaced it. `ProjectStore.speedSheetModel` is
  created once by `showSpeedSheet()` (like `exportModel`); `speedSheetClipIDs` is now read-only (derived).
  `SpeedDurationSheetTests` (the window test fails with the old closure: the field shows "100" again).

- 2, B2, the mute button out of step with the menu: "Mute Audio: one state for the menu and the
  transport button". Root cause: the button kept its own `@State`, read only on appear, while the menu
  toggled the engine. `ProjectStore.isAudioMuted` reads and writes the engine's state (the only copy) and
  publishes; the button and the menu (now a Toggle, with a check mark) both use it. `MuteAudioTests`
  (the button test fails with the old `@State`: the click after a menu mute muted again). The menu's
  check mark itself is checked by hand: the hosted app's SwiftUI menu did not update its item's state
  in the test host.

Not started (key facts):
- 3, B3, `DecodePool::refresh()` writes the worker-owned `repairedAt` under the pool mutex.
- 4, B4, `FFVideoEncoder` converts BT.2020/240M with BT.709 coefficients (`FFFrameConverter::swsColorspace`
  has the right mapping).
- 5, B5, `VEMediaLibrary` builds the thumbnail and waveform services without the router's policy.
- 6, B6, `UndoStack::push` ignores a failed re-apply; `AccumulatedSteps::apply` drops its children's
  dropped ids.
- 7, B8, test hygiene (EngineTests scratch directories, AppTests defaults suites, media work outliving
  `StoreFixture.cleanUp()`).
- 8, the `~/Movies` demo-project test and the 200-click soak out of the default run.
- 9, B9, AV1/VP9 decoder registration only through `HardwareCaps::get()`.
- 10, B10, `ThumbnailService` finds a clip's last frame with one seek.
- 11, B11, span and transition titles in two places.
- 12, B12, M4A with PCM: the backends' validation disagrees.
- 13, the dangling links to `2026-09-29-post-lanes-review.md`.

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
