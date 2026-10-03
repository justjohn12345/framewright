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

## Left open by the 2026-09-30 to 2026-10-02 rounds
Every item of those rounds' briefs is done and verified by the lead (see the README history table). Their full
status notes (commits, tests, measurements, verification) are in this file at 400ded1. What they left open:

Frame-rate conform (the lead's review of groups B and C, 2026-10-01; the reviewer's reproducers and fuzzer,
fa-Repro.cpp cases 2-4, fa-Alt.cpp and fa-Fuzz.cpp, were in the lead's scratchpad, not in the repository):
- A linked component already moved by one amount is never re-decided to a larger move that would work
  (Engine/Edit/EditOps.cpp ~3102: only a component decided at zero takes a move), so in-sync dual-system
  sound with a short head handle is refused at some rate pairs (23.976 -> 60 fps reproduces it; a shift of
  -0.016917 s conforms validly). The SequenceFormatTests case "refused: the sound moved with its picture at
  one cut would have to move again at another" pins a refusal for which a valid conform exists (both clips
  shifted -1/75 s). The 2026-09-30 round's claim that this refusal "in practice needs a pair slipped out of
  sync" is false (5 of 74 such refusals in the fuzzer involve no slipped pair).
- A start takes the grid time on the far side without checking that a clip starting there still has a grid
  end inside its media (EditOps.cpp ~2985-2995): a one-frame picture from its media's start, linked to sound
  ending on its media's end, is refused at 23.976 -> 24 fps although moving the pair by -0.0000834 s fits.
- Linked pairs that share no edge are conformed edge by edge, so an overlap under about a frame can round
  away (373 mixed and 3 sub-frame sequences in the fuzzer after c5a93b2; also on 6864cc0).
- A clip of about a frame or less whose start the grid or its media trims, or that moves with a whole clip
  at a cut, can play none of what it played (fuzzer `content`: 1,447 mixed and 2,819 sub-frame sequences
  after c5a93b2). The test "a one-frame clip whose start moves up keeps a frame after it" pins one such case
  (an unlinked clip).
- The property test's generator is narrow (same-file pairs, sound starting 0-2 frames later, one track each);
  the dual-system generator added in c5a93b2 covers part of it.
- The conform refusal that names both clips names one file twice for a camera clip ("“b.mov” ..., and
  “b.mov”, which ends with it, ..."); name the track when both come from one asset.
- A cascaded move can stretch a clip without a word (a one-frame picture became three frames at 24 ->
  23.976 fps); consider a note or a refusal.

Export and audio (review of groups B and C):
- Nothing pins that 44.1 and 48 kHz AAC exports still go through Apple's writer (they do, measured); assert
  the writer backend at both rates for the four bit rates, MP4 and MOV.
- The FFmpeg AAC fallback uses `aac_at`, which clamps an unusable bit rate silently: a 32 kHz sequence at the
  default 256 kb/s exports through FFmpeg (video included) at 192 kb/s, and the size estimate is off. The
  comments and notes that say Apple takes "22.05-48 kHz at most bit rates" overstate it (22.05/24 kHz take at
  most 128 kb/s, 32 kHz at most 192).

Render and playback:
- The remaining step at the 0.75 threshold (6.9 % of the edge measure between scales 1/240 apart) is the
  resampling filter (Lanczos pre-scale below 0.75, bilinear above), not sharpening. Pre-scaling every minified
  picture (threshold 1.0) would remove it at some GPU cost in the monitors. (Fix round 2026-09-30, found
  while doing item 2.)
- Known gap, documented in Compositor.h: an export smaller than the sequence (a 4K sequence at 1080p)
  sharpens while the monitors show the sequence's scale unsharpened. (Fix round 2026-09-30, R5.)
- Each presented frame costs about 2 + log2(layers) heap allocations on the render thread since the
  presented-frame buffer became immutable (PlaybackController.mm ~157-165); reuse the swapped-out buffer.
  (Review of groups B and C.)
- Stale comments: Compositor.h ~25-27 (the 1:1 rule), Compositor.mm ~310-317 (`quantize`) and ~423-424
  (`exactPrescaleSizes`). VEExport.h ~108-111 promises "never a black line", but the fallback branch can still
  leave one (1080x2408 at 720p; a 2700x1080 sequence at custom width 1002). (Review of groups B and C.)
- The Ken Burns overlay (App/State/KenBurns.swift ~932-951) assumes a fitted, centred picture; with the 1:1
  base for pictures within 2 px of the frame it is off by under a pixel. (Review of groups B and C.)

Facade and model:
- `VE_ENGINE_HEADER_INCLUDED` is defined as 1 in the public VEEngine.h, so Swift imports it as a global Int32;
  define it without a value. (Review of groups B and C.)
- `UndoStack::redo` reports the redone step's dropped ids, but the facade's `redo` does not read them (nothing
  reported them on redo before either). (Fix round 2026-10-01, item 6.)
- Unknown keys a newer version writes on the project, a sequence, track, clip or keyframe are still ignored and
  lost on save; only spans (and, since slice 1, a clip's grade) keep them. (Colour grading prerequisites, item 1,
  scoped to spans by its brief.)
- Transitions: kinds as presets (one Wipe kind by angle, the old names as file aliases) and the facade's
  parameter API (`VETransitionInfo` carrying the parameters, a coalescable `SetTransitionParameter` edit) are
  for the round that shows transition parameters in the UI. (Colour grading prerequisites round 2, item 6.)
- Stills: the probers still report a still's bit depth as 8 (Apple) and its colour as sRGB (both), since
  nothing reads them for decoding; HDR (PQ, HLG) stills are not tone mapped. (Prerequisites round 2, item 3.)

Colour grading, not in slices 1 and 2 (next): P3/BT.2020 primaries (a separate decision), HDR export, HLG tone
mapping, grades that change over time, match colour.

Tests and tooling:
- ThreadSanitizer does not see `CMTime` struct copies in this build (a 24-byte `CMTime` written from two threads
  without ordering is not reported; an `int` is), so the "0 reports" TSan runs do not cover races on `CMTime`
  fields; a field-wise proof build is needed to show one. (Fix round 2026-10-01, item 3.)
- Flaky: `ExportJobTests testMemoryIsFlatOver1800FramesAt720pSurvivesPressureAndProgressIsPaced`, a wall-clock
  pacing bound (failed once in five full runs of 2026-10-01 and once in prerequisites round 2; passes alone).
- Flaky: `ExportParityTests testAReversedClipPlaysTheSoundTheExportWrites`, an audio-timing comparison (failed
  once in the slice 2 final run; passed 3 of 3 alone and in every other full run).
- Flaky: `VEExporterTests testAnExportRunsToItsEndAndClearsTheRunningExportBeforeFinish` failed twice with no
  progress delivered, in runs of several facade classes together (the job drops a progress delivery that finds
  it finished, so a main queue busy for the whole short export sees none); not investigated further.
  (Integration notes, fix round 2026-09-30 groups B and C.)
- Each test run (also a partial one) leaves one empty per-process temporary directory (`<UUID>-<pid>-<hex>`) at
  the app container's root (probably an item-replacement or temporary directory the test host asks Foundation
  for and never removes); not fixed, cleared by hand. (Prerequisites round 2.)
- Xcode's Thread Performance Checker logs a QoS inversion in the media probe's AVFoundation key loading in every
  StressTests run (also before slice 1); not changed. (Colour grading slice 1, verification.)
- Playback > Mute Audio's check mark is checked by hand: the hosted app's SwiftUI menu did not update its item's
  state in the test host. (Fix round 2026-10-01, item 2 (B2).)

## Titles slice 1 (2026-10-02): status
The slice of `docs/plans/2026-10-02-titles-design.md` (owner approved all eleven decisions), one commit per item
in the note's order. Nothing was cut: the colour matte and the lower-third preset shipped. Not pushed.

Done (engine):
1. c996a93 the picture drawing set-up of `StillDrawing` in a shared helper (`PictureDrawing`; pure extraction).
2. abb717e generated pictures through the decode pool (`GeneratedPictureSource`, the decoder adapter,
   `DecodeTarget::generated`, `FrameKey`/`Focus` with the generated key), proved with a checkerboard test source.
3. 8b10479 the model: generator assets and `isFileBacked()` at the URL sites, `Clip::generated`, the
   `TitleParameterInfo` table, the content id, `maxMotionScale`, the validation rules.
4. 7b62a72 schema 10: writer and parser (unknown title keys kept), the frozen 9 -> 10 step, the v10 goldens and the
   writer golden `project-v10.json`.
5. f7083a2 the title and matte renderers (Core Text layout and glyph outlines, outline, shadow scaled by k, box,
   font resolution and fallback, raster limits).
6. 77d529f the compositor (`placeCanvas`, no sharpening of generated layers; `VideoLayer` carries the content,
   anchor and the clip's largest Motion scale).
7. 915c5dd playback and export compute k and build the sources (the monitor follows its drawable size).
8. a0681f1 the facade (placement rule, setters, `VEClipInfo` title fields, missing fonts, font observation).
   f4557f4 (found while doing the app): a sequence size change skipped generated clips (their asset has no size),
   leaving their Motion offsets in the old frame's pixels; they now scale with the frame.

Done (app): efc63f7 the Clip menu items and Control-T / Shift-Control-T; 89e12ef the Effects tab's tiles;
74c247f the inspector's Text, Font, Outline, Shadow and Background sections and the matte's colour row; d2789ec the
program monitor's title box; a9b0947 the timeline's look; b7498eb the Colour tab's note (Copy and Paste Grade skip
titles); e5abda0 the export sheet's missing-font confirmation.

Deviations from the note, and why:
- `CanvasGeometry` travels as a buffer attachment and is relative to the layer's anchor (the title's position is
  not in its content id, so moving a title renders nothing and its picture is shared).
- The content id is one true 128-bit FNV-1a hash (not two 64-bit lanes), with the canvas size folded in
  (`contentIdOnCanvas`). `maxMotionScale` takes the bezier's exact extremes rather than samples.
- Layout uses `CTTypesetter` with Framewright's own line placement: `CTFrame` rounds line heights, which broke the
  linear scaling with k (and the shadow-scale test).
- The compositor snaps a reduced or 1:1 still title's corner to a whole target pixel; an animated one is not
  snapped, keeping smooth motion at some edge sharpness (69 % of the snapped title's edge measure at a half-pixel
  phase in a half-size monitor, against 98-100 % snapped).
- The monitor's output scale is quantised (up to 1.25 -> 1, up to 2 -> 2, else 4), so a window resize does not
  re-render titles on every step; `VEPreviewView` reports its drawable size for it.
- Titles stay 8-bit BGRA: their colour is exact to its 8-bit value (mattes are exact in 10-bit).
- The export wait of generated sources is tested through ExportJob (item 7), not in item 2's pool tests.
- The placement rule (above the target) applies to colour mattes too; a matte for a backdrop is dragged under.
- The engine follows font activation (`VEEngineTitleFontsDidChangeNotification`): titles re-render when Font Book
  activates or removes a font, and the timeline's badge follows.
- The title's Position X/Y and Box Width rows read "Text Centre X/Y" and "Wrap Width" in the inspector, so they are
  not confused with the Video rows' Position X/Y below them.
- `KenBurnsModel` reads the picture size from `VEClipInfo.pictureWidth/Height` (its `asset:` parameter is gone; one
  existing test changed with it, `KenBurnsEditorTests` "the reason for a clip without a picture").
- The name of a title on the timeline is its first line that has text ("Title" when none has).

Measured (Debug build, this Mac; estimates written down, not asserted):
- A 1080p lower third renders in 0.66-0.72 ms (median); a full 4K page with outline and a soft shadow in
  104-106 ms, above the note's estimate of tens of ms (typing on such a title shows about ten pictures a second;
  a 4K title over 16384 pixels a side lowers k, measured at k 0.284 for an oversized page).
- Keystroke to picture, paused (engine: set the text, render, present): 2.0-2.6 ms.
- Real-time playback with two titles over video: 125 frames, 90 with a title, all exact, 0 late, 0 dropped, 0 audio
  underruns.
- Sharpness: a 1:1 export, a Motion zoom x2 at k 2 and a 1.5x export at k 1.5 match the renderer's picture with a
  worst difference of 0 codes; parity titles worst block 8.10 (bound 12); mattes exact in 10-bit (940/512, 64).

Open:
- Slice 2 items as planned: typing on the picture, safe-area guides, Copy and Paste Style.
- A 4K full-page title with a soft shadow takes about 0.1 s to render (above).
- What needs a person (the test host's events never reach SwiftUI gestures): dragging the box with the mouse,
  typing feel and Undo in the real text area, the font popups with the user's own fonts (and the sandboxed font
  list), text edges over real footage at full screen, a project opened without its font or with it deactivated.
- Flaky in a batch: `CurveEditorTests testTheEditorKeepsTheCurveAfterTheDrag` (a drawing comparison) failed once
  when run with other Colour tab suites; passed twice alone.

Version 9 tests changed only by the schema number (as 63d23c7 did for version 8): ProjectJSONTests (the format
details' version 10; the v5 and v6 expected documents' `schemaVersion` 10; the v7 and v8 byte-for-byte tests' version
replaced by 10; the v6-content warnings "saved as version 10"); MigrationGoldenV9Tests (the v8 LUT file test's
warnings and saved version through `kProjectSchemaVersion`; the version 9 byte-for-byte test renamed "...but for
its version"); ClipGradeLutTests (`== 10`); VEEngineGradeTests and VEEngineGradeLutTests (`"schemaVersion": 10`).
No existing golden file changed.

Tests (full `Framewright` scheme run at e5abda0): EngineTests 678 (3 skipped: the display-link tests, the display
asleep or locked), doctest 475 cases, AppTests 339 (1 known skip); baseline 629 / 439 / 311. Failures in that run:
`ExportParityTests testAReversedClipPlaysTheSoundTheExportWrites` (the known flake; passed alone), and
`ScopePanelTests testTheWindowShowsTheScopesWideAtThePicturesAspect` and `WaveformPanelTests
testTheShownPanelIsDrawnWithTheProgramMonitorsFramesAndLetGoWhenHidden`, which fail the same way at b3f8c4e (before
this round) in this session: a windowed program view does not render while the display is asleep or locked (the
same condition skips the display-link tests). They need a run with the display awake.

Review fix round (2026-10-03; an adversarial review of b3f8c4e..c7feff8: 4 MEDIUM, 1 MEDIUM to confirm, 10 LOW).
Each finding has a test that fails without its fix (those of 1 and 4, 3, 5, 7, 8 and 11 were run against the code
before the fix, or with it reverted, and failed; the others assert the symptom itself):
1. MEDIUM, a font change could leave a title in the fallback for good (a worker publishing the fallback picture
   under the unchanged key after the purge): bd96f79. Every title's key holds the font generation
   (media::titleFontGeneration), advanced once per change before the engines drop the pictures; the program
   monitor's pool retires its title streams before the cache purge.
2. MEDIUM, a typing run left open blocked Export (and held back imports, refused Remove Media): c335cf8.
   `ProjectStore.commitOpenEdits` before the Export sheet, exporting, importing and removing media; a run also
   ends after 2 s without a keystroke (a pause in typing is then two undo steps).
3. MEDIUM, an animated title drawn texel for pixel snapped to whole pixels on every frame (stepping, and a jump at
   the end of a zoom that ends at k): dec51f6. Only a title whose Motion does not change is snapped.
4. MEDIUM, no test proved a font change redraws a title: bd96f79. A box font the tests make (TestFont.h, no font
   file in the repository) registered for the process: the program monitor's title changes to it and back; it
   fails with the key change and the invalidation removed.
5. MEDIUM to confirm, the raster scale changing the system font's optical size: confirmed and fixed, 7119f42.
   Measured on 1920x1080 with the system font Regular, a wrap width that just fits one line at k = 1: at 0.012 of
   the frame (13 px) the line's ink was 141 px wide at k = 1 and 129 at k = 2 (halved), and the k = 2 picture
   box-downsampled differed from the k = 1 picture by 35.5 alpha codes on average (worst 255); at 0.06 (65 px),
   630 against 625 px and 29.4 on average. The text is now laid out at k = 1 and magnified k times: 141 against 142
   and 0.23 on average (worst 7.8) at 13 px, 630 against 629 and 0.08 (worst 13) at 65 px; the line breaks are
   those of k = 1 by construction. (Pinning the optical size alone would not do: the system font's tracking also
   follows the point size; a font matrix scales the glyphs but not the typesetter's advances.)
6. LOW, hidden video tracks: b4560da (the placement rule and the missing-font question pass them over).
7. LOW, a held picture after a size change placed wrong: e13dee3 (the anchor is taken to the canvas's pixels).
8. LOW, line spacing below 1 lifted the first line out of the box: 9911424 (the first line keeps its ascent, the
   spacing scales the distance between lines; spacing 1 is unchanged, spacing above 1 no longer adds space above
   the first line).
9. LOW, a nudge of a "Mixed" field collapsed the titles to one value: bb3efa7 (each from its own value).
10. LOW, one font change redrew every title twice (two notifications, more than once each): bd96f79 (one advance
    and one redraw per change, whatever the number of engines).
11. LOW, an edited still title rendered twice while paused: 7e64ff7 (a stream opening on a still generated picture
    the cache holds takes it; the typing test checks one picture per keystroke, and a pool test the render count).
12. LOW, a font change during an export: f13a394. Chosen: the export keys every title with the generation it
    started with and its summary says the fonts changed (`ExportSummary::titleFontsChanged`,
    `VEExportSummary.titleFontsChanged`, the export sheet's message: export again). Titles are drawn with the fonts
    the Mac has when each renders: a consistent font for the whole file cannot be had once a font is gone.
13. LOW, Ken Burns outlined titles and mattes as frame-sized rectangles: ce91aa3 (a title's text block, no matte).
14. LOW, Add Title disabled without video tracks: 29b94a2 (only a project file can have none; the app keeps one).
15. LOW, messages: 74a95a7 (`Project::clipName` names a title by its first line in the refusals that quoted the
    generator asset's name; the shape-change report says titles and mattes fill the new frame; the source monitor
    shows and times no generator asset).

Fix round tests (full `Framewright` scheme run at 74a95a7, the screen locked): EngineTests 686 (3 skipped: the
display-link tests), doctest 476 cases, AppTests 345 (1 known skip). Failures in that run: `ScopePanelTests
testTheWindowShowsTheScopesWideAtThePicturesAspect` and `WaveformPanelTests
testTheShownPanelIsDrawnWithTheProgramMonitorsFramesAndLetGoWhenHidden` (the locked screen, as above), and once
`LumaWaveformTests testTheViewDrawsTheProgramMonitorsGradedPicture` (a draw counted after the waveform view was
detached: 10 against 9; it passed three times alone; not seen before, not touched by this round: a new flake to
watch).

## Title box drag latency (2026-10-03)
The owner saw the text lag the pointer while dragging a title's box. Measured with `TitleDragLatencyTests` (new
`Measurements` scheme: the whole editor window, a 1080p sequence, a movie under a lower third and a title, 60 steps
per drag at 60 Hz, made through the overlays' models and by pointer events through the window; medians, ms):

| Drag (pointer events) | picture handed out, before | after (Debug) | after (Release) | window updated (SwiftUI), Debug / Release |
|---|---|---|---|---|
| Transform box move (Motion span on the movie), the baseline | 11.8 | 0.6 | 0.2 | 11.2 / 10.2 |
| Lower third move | 8.9 | 0.6 | 0.2 | 9.1 / 7.8 |
| Title move | 9.1 | 0.6 | 0.2 | 9.3 / 8.2 |
| Lower third wrap width | 9.5 | 9.8 | 8.4 | 9.7 / 8.3 |
| Title wrap width | 9.7 | 10.0 | 8.7 | 9.9 / 8.6 |

(Release before: Transform 10.6, lower third 7.6, title 7.9, the wrap widths 8.2 and 8.6.)

- **Where the time went.** Not the engine: a step's edit, snapshot publish and the store's re-read take 0.3 ms
  (Release) to 1 ms (Debug), and a move renders nothing (no cache miss in any move step: position is not in the
  content id). The picture waited for the main thread: the playback controller asked for the paused redraw through
  the main queue (`PlaybackController::ObserverHub::postNeedsDisplay`, then `VEProgramMonitor`'s `needsDisplay`,
  then `renderOnce`), and that block ran only after the rest of the main thread's turn, which during a drag is
  SwiftUI updating the whole window for the edit (every panel observes `ProjectStore`). The Ken Burns drag had the
  same delay; nothing in it was title-specific.
- **Fix: 1364d79.** `VEProgramMonitor -presentChange` asks its views to draw the moment the paused picture may have
  changed (a published model, a seek, a step, a scrub, the preview solo), on their render threads; the
  controller's later request draws nothing more (`VEPreviewView -renderIfChanged`: only a new frame or a pending
  redraw is drawn; a `renderOnce` coalesced with it still draws). Tests: `TitleBoxTests
  testAMoveStepIsDrawnAtOnceFromTheCachedPicture` (each move step is drawn once with the main thread held, with no
  cache miss, and the later requests draw nothing; fails before the fix),
  `testAWidthStepKeepsThePreviousPictureUntilTheNewOneLands`, `CompositorPreviewViewTests
  testRenderIfChangedDrawsOnlyWhatChanged`. Harness: ac318c0.
- **Wrap width** re-renders the title every step (the width is in the content id), in the pool's scrub path off
  the main thread; the previous picture stays until it lands. Its landing still reaches the views through the main
  queue, so the new width shows when the window's update ends, with the box.
- **Left open.** The box itself is SwiftUI: it moves when the window's update for the step is committed, 8-10 ms
  after the step (the inspector is about 2-3 ms of it, the timeline 1-2, the rest is spread over the window). The
  picture now leads the box by that much instead of trailing it. Making the box faster means narrowing what a
  model change invalidates (panels observing smaller models than `ProjectStore`), which is larger work. The
  measurement skips itself when the test window is covered or the screen is locked (the monitor does not draw then).
- **For the owner, by hand:** drag a title, a lower third and a Ken Burns box on the program monitor while paused
  over video; the text should stay with the pointer, the box at most a frame behind it. Widening a title shows the
  old width for a moment, never a frame without the title.

Tests (full `Framewright` scheme at 1364d79, the screen unlocked): EngineTests 687, doctest 476 cases, AppTests 347
(1 known skip), 0 failures. An earlier run under load failed once in `GeneratedSourceTests
testAPictureRenderedForAnEarlierEpochIsNotPublished` (`pool.waitUntilIdle` timed out after 10 s; a decode pool test
that does not involve the views; it passed three times alone): a flake to watch.

## Titles slice 2 (2026-10-03): status
The slice of `docs/plans/2026-10-02-titles-design.md` ("### Slice 2", sections 6, 9 and 10), one commit per item. Nothing
was cut. Not pushed; awaiting the lead's review.

Done (engine):
1. 6f6b480 point text and the vertical anchor in the model, schema 11 (`pointText`, `anchor`; the frozen 10 -> 11
   step; v11 goldens and the writer golden `project-v11.json`; no existing golden changed).
2. d97218f the renderer: point text, the anchor and `TitleTextLayout` (the renderer's own lines: carets, the index at a
   point, selection rectangles).
3. 8d888ba the facade: `VETitleTextLayout` through the clip's Motion, keeping text in place for point text, the
   anchor and the alignment, Copy Style and Paste Style.
4. f528a31 the Title Card (a matte with its title above: two clips) and Caption presets.

Done (app): 9bcfe79 the Add Title Card and Add Caption items and tiles; abfad08 point text and the anchor in the
inspector, the box following them; ea6cb03 the font popup's recent fonts; cb9ff05 the safe-area guides (View menu,
Settings > Editing); f42d243 snapping a dragged box; fb706d9 Copy Style and Paste Style (Clip menu, context menu);
1b7c3df typing on the program monitor; 70ee691 the typing measurement; ed1b396 the program monitor's picture with its
overlays checked offscreen (and PNG files of it).

Deviations from the note, and why:
- **A text ending with a line break (or empty) has an empty last line in its block**, as tall as a line of its font:
  the caret's line after Return, which the box and the background box take in at once (Premiere and Final Cut do the
  same). A slice 1 title whose text ends with a line break is therefore drawn half a line higher (centre anchor) and
  its background box a line taller; `titleBlockSizeOfClip:` of an empty title is one line, not 0 (one slice 1 test
  changed with it: `VEEngineTitleTests testTheBoxSizeIsTheTitlesBlockInSequencePixels`, and
  `TitleRendererTests testAnEmptyTextGivesATransparentPicture`'s block height).
- **Point text's x follows its alignment** (its left edge, centre or right edge), as Premiere's and Final Cut's point
  text do, so typing grows the text away from that point; area text keeps x at its centre. Turning point text on or
  off, changing the anchor, and changing a point text's alignment move the position so the text stays where it is
  (the inspector's controls and the facade's setters; a plain `setTitlePosition` does not).
- **Paste Style leaves out point text and the anchor** besides the text, position and box width: they say where the
  text is, and pasting them would move it.
- **The anchor is part of the content id** (it places the picture relative to the position).
- **The safe-area percentages are a choice of two pairs** (SMPTE ST 2046-1, the default, and the classic 90/80), not
  free numbers, as the note's "the classic pair as a preference".
- **Snapping is disabled with Command** (Ken Burns boxes do not snap, so there was no convention to follow), and it
  snaps to the safe-area lines whether or not the guides are shown (the line it snapped to is drawn); a box's edge
  snaps only when the box is not turned. Copy Style and Paste Style have no keyboard shortcuts.
- **Return starts typing on the picture with all the text selected** (as Finder's Return on a name), a double-click
  with the caret where it was clicked. Playback pauses when typing starts. Clip > Edit Title on Picture shows Return.
- **A title card is two clips** (a black matte and a bold title on the track above), added or dropped as one undo
  step, rather than one clip.

Measured (Debug build, this Mac, the screen locked: the editor window could not be shown):
- Keystroke to the picture handed out, typing on the picture with the program drawn by a view in no window and the
  typing surface in a hidden window (`TitleDragLatencyTests testMeasureTypingWithAnOffscreenMonitor`, a lower third
  over a movie, 40 keys at 12 a second): median 11.8 ms, p90 15.3 ms (the first key 123 ms: fonts and caches warming).
  The same through the engine alone (no app, a typing run's coalescing group): 0.9-1.5 ms median. The whole-window
  measurement (`testMeasureTypingOnThePicture`, Measurements scheme) skips while the window cannot be shown: run it
  with the screen unlocked. An earlier version of the offscreen measurement inside the drag harness's own loop gave
  44-48 ms (and wrap-width drags 26 ms against the 9.8 ms measured in the window); a stand-alone probe in the same
  host gave 9-15 ms for the same keys, so that harness path was left out; why it was slower is not known.
- The caret and selection are drawn by Core Animation layers at the keystroke (the surface's own redraw), not after
  SwiftUI's update of the window; the new picture lands when the pool has rendered it.

Open:
- What needs a person: the double-click on the box by hand (the test of it skips when the window cannot be shown, as
  it could not this session), typing feel, input methods (marked text is not drawn on the picture: the title shows
  the committed text; the candidate window is placed at the caret), the font popup's recent fonts with the user's
  fonts, snapping by hand.
- The caret follows the title's Motion at the playhead; typing during playback is possible from the menu (Play) and
  the caret then follows the moving title.

Tests changed with the slice (each for a behaviour it changed): the schema-number tests listed in 6f6b480's message
(as 7b62a72 did for version 10), the version 10 writer test ("but for its version and the version 11 title keys"),
the two empty-block tests above, `GeneratorTilesTests` and `TimelineDropTests` (five presets: d094acb).

Tests (full `Framewright` scheme at ed1b396, the screen locked; the two preset-list tests were fixed in
d094acb and pass): EngineTests 701 (baseline 687), doctest 487 cases (476), AppTests 372 with 2 skipped (347, 1): the
known skip and `TitleTypingTests testADoubleClickOnTheBoxStartsTypingWithTheCaretThere`, which needs a visible window.
Failures in that run: `ScopePanelTests testTheWindowShowsTheScopesWideAtThePicturesAspect` and `WaveformPanelTests
testTheShownPanelIsDrawnWithTheProgramMonitorsFramesAndLetGoWhenHidden` (the locked screen, as before), and
`FFmpegBackendConformanceTests testMemoryIsStableAcrossLongDecodesAndSeeks` (footprint grew 73 MB against 24; it
passed alone; another agent was building and testing in its worktree at the time: a flake under load to watch).

## Where things stand (handover, 2026-10-03)
- **Released and pushed:** 0.1.11 (built from 221ad31) is the last release; everything is pushed. It adds titles
  slice 1 (c996a93..e5abda0, docs c7feff8) and its review fix round (bd96f79..74a95a7, docs 9927acd), accepted by
  the lead with the full suite passing with the screen unlocked; the owner tried it ("seems ok"). The full hand-test
  list is in integration-notes ("Titles slice 1"). Open for the owner: the typing run's 2 s idle commit, no extra
  space above the first line at line spacing above 1, and an export reporting (not freezing) a mid-export font
  change. Earlier: colour grading and scopes in 0.1.9, their hand-test fixes in 0.1.10 (left from that test: the
  curve editor's hue strip still uses the old pastel hues).
- **Next, in the order the user has leaned towards:**
  1. The user finishes the hand tests of grading slices 1 and 2 and titles slice 1 (lists in integration-notes).
  2. Titles slice 2 (typing on the picture, safe areas, Copy/Paste Style), per `docs/plans/2026-10-02-titles-design.md`.
  3. Autosave and backups (the app has none).
  4. HLG display (tone map) and the P3/BT.2020 primaries decision.
  5. The transition library and the Effects browser (plan items 28-29).
  6. The safety-and-basics round from `docs/plans/2026-10-01-premiere-lite-feature-gap.md` (autosave, relink,
     copy/paste, markers, Export Frame, meters, bins).
- **Open small items:** the empty per-process directory each test run leaves at the app container's root; the
  flaky tests and the other leftovers above ("Left open by the 2026-09-30 to 2026-10-02 rounds"); B7 and the
  general review's groups 2-6 and item 1.11 (`2026-10-01-general-code-review.md`).

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
