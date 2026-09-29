# Post-lanes review (2026-09-29)

Reviewer: Claude Opus 5.5 (lead reviewer, read-only), with two read-only Opus helpers in isolated worktrees (one on
the engine model, edit and serialization code, one on the app); the lead took the scheduler, the mirror, audio,
playback, the solo preview and rendering, and re-ran both MEDIUM findings in the main tree. Scope: every commit since
the effect lanes review, `666143e^..8328ff8` (65 commits): the effect lanes fix round (C1 app side, H1-H4, M1-M8, D2,
L1-L11), the Ken Burns editor rounds (placement boxes, Ken Burns | Transform modes, the engine solo preview, the frame
box, the automatic mode, AppKit dividers, the monitor shade, Control-K), reverse (schema 6), the Speed row, wipes and
the iris, Continue on Next Clip, the selection style and Unlink. "(verified)" means reproduced with a scratch test or a
run (the lead's, or a helper's where it says so); "(reading)" rests on reading only. Tree state: clean at 8328ff8
(main == origin/main). Full scheme green: 467 EngineTests (including 255 doctest cases, 193898 assertions) and 257
AppTests (1 skipped, the known `TimelineGestureTests.testARealDragThroughSwiftUIIsCommittedAndNotReverted`), zero
warnings in project code. ThreadSanitizer clean over 79 tests in 9 suites (playback, solo preview, audio, export
parity); its one skip is `AudioMixerTests.testRenderPathDoesNotAllocate`, which skips under any sanitizer by design.

## Summary
No CRITICAL and no HIGH. Two MEDIUM, both in the app. First, the Speed/Duration sheet on a selection mixing reversed
and forward clips opens with Reverse unchecked, and applying only a new speed makes the reversed clips play forward,
silently. Second, Add Ken Burns… (and the Ken Burns tile) on a picture in picture opens Ken Burns mode, whose
rectangles are the frame's preimage: 3.3 frames wide for a 30 % clip, with no corner on the monitor, so the editor
cannot zoom until the user switches to Transform. Nine LOW findings. Reverse refuses a clip whose media end is on an
odd nanosecond timescale, and refuses audio linked to a still. A reversed still in a hand-edited file refuses to
open, which M8's repair policy should handle. Unlink collapses a multi-pair selection. There is per-drag-step work in
the Ken Burns bar and the Effects tab. A split forgets the right piece's editor mode. README's "a fade in starts and
a fade out ends on a black frame" does not hold for the default cross-dissolve fade. v5 files are accepted with v6
content. A few refusal messages are odd.

The core of the round holds under attack, each point verified:
- The mirror rule is frame exact. A mutation to the frame's start fails the export parity and lookahead tests.
- Reversed audio shows no seam at its 0.5 s block reads on AAC, 44.1 kHz-resampled and PCM sources with mirrors on
  1/1, 1/44100 and nanosecond timescales (worst 4.8e-7 at 3/2 speed).
- Reversed clips present every frame exactly under J, -2x, 2x and -4x shuttle and scrubbing.
- The solo preview is TSan-clean and stays out of the mirror window and export.
- Wipe and iris fades start and end on exactly black frames. A mutation of the exposure steps fails three test files.
- H1, M2, M3 and M8 hold against odd-n, split, insert, overwrite, lift and speed-ripple cases.

Three existing tests are weaker than they look: a mutation survives each. Details are under test gaps.

## Ranked findings

### CRITICAL
None.

### HIGH
None.

### MEDIUM
M1 (verified, helper and lead). The Speed/Duration sheet changes the direction of clips when only the speed was
asked for. `App/Views/Speed/SpeedDurationSheet.swift:71` initialises `reversed = !chosen.isEmpty &&
chosen.allSatisfy(\.reversed)`, so a mixed selection opens with the box unchecked; `apply()` (`:154-155`) computes
`changesDirection = clips.contains { $0.reversed != wantsReversed }`, which is true for every reversed clip, and calls
`setReversed(false, ...)` inside the same undo group. Scenario: reverse clip A, select A and a forward clip B, Cmd-R,
type 50, Apply: A now plays forward. The status line does not mention direction, and the only trace is the missing
"◀" in the timeline. It is one Cmd-Z back, but easily saved unnoticed. Scratch test (run in the main tree):
`sheet.entry = .percent; sheet.text = "50"; XCTAssertTrue(sheet.apply());
XCTAssertTrue(store.clips[a]?.reversed == true)` fails with "only the speed was asked for: a stays reversed"; the
sheet printed "opens with reversed = false".
Fix: make the box three-state (`reversed: Bool?`, nil for a mixed selection, the mixed checkbox state), change
direction only when the user set the box, and say "Reversed n clips" / "Played n clips forward" in the status line
when the direction changes. Add the test above.

M2 (verified, helper and lead). Add Ken Burns… on a picture in picture opens an editor that cannot zoom. Asked
modes are remembered whatever the clip's placement (`App/State/SpanEditing.swift:256`,
`rememberKenBurnsMode(motionMode, for:)`). Ken Burns mode has no margin (`App/Views/ProgramMonitor/
KenBurnsOverlay.swift:46`). Its rectangles are the frame's preimage, size = frame / scale. Scenario: a clip at x 690,
y 324, scale 0.3, then Clip > Add Ken Burns… (or the context menu, the Ken Burns tile, its "+"). The probe on a 960 x
540 monitor printed "start rect centre (-1340, -540) size (6400, 3600), reachable corners 0" and "end rect centre
(-880, -324) size (5120, 2880), reachable corners 0". A body drag grabs the End rectangle, but `keptInFrame` only lets
it move toward the frame. The user has to discover the Transform segment on the bar. No data is harmed; it is a dead
end from a named menu item. Fix: when the asked mode is Ken Burns and `automaticMode(start:picture:sequence:)` says
Transform, open in Transform with a bar note ("This clip is placed smaller than the frame: its move is edited as
boxes"); or give Ken Burns mode the margin viewport while a rectangle exceeds the frame box. Test: Add Ken Burns… on
a 0.3 clip yields a mode whose shapes have reachable corners.

### LOW
L1 (verified, helper). `SetClipReversed` refuses a clip whose media end does not combine with the frame grid inside
a 32-bit timescale. `Engine/Edit/EditOps.cpp:2038` (`exactTimeOn(E - out, ...)` falls back to the reduced form,
which needs timescale 3e9 for E = 10123456789/1e9 and out = 31/30). Such an E comes from FFProber's Matroska
DURATION tag with sub-millisecond digits (FFProber.mm:39), and it is the audio mirror (`duration`), so a linked MKV
pair is refused as a whole. The user sees the raw "has no CMTime form (its timescale would exceed 2^31 - 1)".
`ReverseTests`' odd-end case uses 10010000000/1e9, which reduces to 1001/100. Fix: store probed ns-scale durations
reduced (or snapped to the sample or frame grid of the track they describe) at import; at least word the refusal.

L2 (verified, helper). Reversing an audio clip linked to a still is refused with "a still image has no motion to
reverse" (`EditOps.cpp:2017-2018`: every target of `clipAndPartner` is checked, the partner included). A still +
music pair selected by a click and Option-Cmd-R is refused although the app's `reversibleSelection` already dropped
the still. Fix: skip stills among the linked partners; refuse only when `clipId_` itself is a still.

L3 (verified, helper). `"reversed": true` on a still refuses the whole project ("sequence 6: clip 11: a still cannot
be reversed", `Engine/Model/Validation.cpp:69`); `repairSequence` does not repair it, contrary to M8's policy of
repairing what has one safe reading (a still has no direction). Fix: clear the flag on stills in `repairSequence`
with a warning; a loading test.

L4 (reading). Unlink with several linked pairs selected (marquee, Cmd-A) unlinks one pair and reduces the selection
to that one clip (`App/State/ProjectStore.swift:1242-1256`); a second Cmd-L then says "Select two unlinked clips...".
Fix: unlink every selected pair in one undo step (keeping the anchor rule for which clip stays selected), or refuse
with a sentence when more than one pair is selected.

L5 (reading). Work on every drag step. `KenBurnsControls` evaluates `model.continueOnNextClipProblem`
(`KenBurnsOverlay.swift:316`, `KenBurns.swift:804`), which runs the engine's `planContinueMotion`, on every body
evaluation, and the bar re-renders on every drag step because `start` / `end` are published; the Clip menu's
`canContinueMotionOnNextClip` already skips this during a gesture. `LaneEffectsPanel`
(`App/Views/Inspector/InspectorPanel.swift:76-77`) observes the whole store, so the visible Effects tab re-renders on
each store change including drag steps. Fix: cache the answer by `changeCount` (or skip it while `isDragging`); give
the panel only the flag it reads. Extend `TimelineRedrawTests` with body counts for the bar.

L6 (reading). Splitting a clip inside a Motion span gives the right piece's span a new id
(`Engine/Edit/EditPrimitives.cpp:90-93`), so the mode the user picked for it (`kenBurnsModes`) is lost and it opens
in the automatic mode. Fix: copy the entry for the new id after a split (the result's created ids), or document it
under "Known limits".

L7 (verified, lead). Docs claims stronger than the code. First, README.md:50 says a fade in starts and a fade out
ends on a black frame, but only for the shaped kinds. The default fade (the Cross Dissolve kind at a free edge) keeps
the frame-centre mix, so its first frame shows 1/(2n) of the picture. `SchedulerTests` pins `mix == (k + 0.5) / 12` on
the fade in and `weight()` is `mix`. This is deliberate (dissolve bit identity) and integration-notes F says so, but
README reads as general. Second, integration-notes.md:1232 ("at speed 1 bit-exactly the forward samples") and
README's "sample for sample" hold on PCM. On AAC the lead's scratch run measured 6.0e-8 at speed 1 (the 0.5 s blocks
are separate decodes). Fix: scope the README sentence to wipes and the iris (or make dissolve fades start on black
too, as a product decision). Say "within 1e-7 on compressed audio".

L8 (reading). A v5 file is accepted with v6-only content: `migrateV5ToV6` (`Engine/Serialize/ProjectJSON.cpp:1149`)
changes only the version, `parseClip` reads `reversed` (`:509`) and the kind parser accepts wipe and iris names at any
version, with no warning. Harmless (nothing older wrote them) and arguably friendly; recorded so it is a choice. An
unknown kind (a future one) loads as a cross dissolve with a warning and is saved as `crossDissolve`, so opening and
saving a newer file in this version loses the kind; acceptable for forward compatibility, worth one line in the notes.

L9 (reading). Refusal wording: `SetTransitionKind` on an audio transition refuses even a request for Cross Dissolve,
a no-op, with "... it cannot be a Cross Dissolve" (`EditOps.cpp:2082`); a shaped kind on audio (through
`AddTransitionSpans`) is refused by `checkTransitionSpan` with the file name ("... not a wipeLeft",
`Validation.cpp:299-300`); `setClipFade` refuses an over-long fade out against an
incoming dissolve with `InvalidTime` while `fadeLimitFrames` reports `Overlap` for the same condition. Fix: treat
Cross Dissolve on audio as a no-op success, use `displayNameOf`, one error code.

## Done properly (do not redo)
- Reverse model: the fixed mirror at the media end (`mediaEndFor` per track), `SetClipReversed` moving the in point
  and every span by one exact shift (spans cannot leave the clip or overlap), reversing twice restoring the numbers,
  handle checks in clip time, linked pairs with different video and audio ends showing the same media. The mirror of
  the frame's END: the lead's mutation to the frame's start fails
  `ExportParityTests.testAReversedClipExportsTheForwardExportBackwards` ("reversed frame 1 == forward frame 28",
  burn-in 59 vs 58) and the helper's fails every `ReverseTests` subcase.
- Reversed audio: the lead ran forward vs reversed on audio_only.wav/.m4a, audio_44k.wav/.m4a and audio_mono.m4a at
  speeds 1 and 3/2 with mirrors of 4/1, 176401/44100 and 3999999937/1e9. Worst differences: 0 on PCM, at most 6e-8
  on AAC at speed 1 and 4.8e-7 at 3/2. The largest sample-to-sample jump equals the forward signal's in every case,
  so the block seams add no discontinuity. The parity tests hold playback to the offline mix within 1e-5 with 0
  underruns.
- Playback direction: `layer.reversed XOR (rate < 0)` in `retargetLocked` and Backward in export. The lead's
  mutation (ignore `reversed`) fails both reversed lookahead tests (57 of 72 samples wrong; 11 to 70 late frames at a
  forward-to-reversed cut). A scratch run at rates -1, -2, 2 and -4 showed 90 of 90 samples exact with 0 late
  frames. Scrubbing over a reversed clip showed the mirrored frame at every probed position.
- Solo preview: the primary source only (the output window is always a Mirror source), export never uses the
  controller, cleared by `setSequence` and by `modelChanged` when the clip leaves the video tracks. The app re-reads
  the engine's state in `syncProgramPreview` rather than caching it, and span ids are never reused after undo
  (`_idFloor`), so the mode map cannot reach another span. ThreadSanitizer is clean over the solo, lookahead,
  transport, display-path, controller, audio and parity suites.
- Rendering: the reveal gives exactly A at [0, 0] and exactly B at [1, 1] (band placement). The dissolve's
  uniforms and shader branch are unchanged, so it is bit-identical by construction and `CompositorTests` hold. The
  closing iris is the fade in over the mirrored interval. `reserved` and `mix.yz` are read only by the layer fragment.
  The lead's mutation of the fade-in exposure back to [k/n, (k+1)/n] fails
  `TransitionShapeTests.testAScheduledFadeStartsAndEndsOnAWhollyBlackFrame`, the Scheduler doctest and the wipe export
  parity test. The reference in `TransitionShapeTests` (32 sub-step average) is independent of the shader's closed
  form.
- Fix round: H1 odd n (n = 11 against a 57-frame fade out: 54, one warning), a clip too short for both drops the fade
  with a warning. M2 is patch based with exact undo; Replace drags take partners from the pre-drag state; splits keep
  the partner; a lift is pruned and reported. The helper's mutation of `removeDissolvesWithNewPartners` fails 9
  assertions. M3 is timeline based (speed and reverse do not matter), and normalizing shortens rather than drops;
  its mutation fails 6+ assertions. M8's lane moves commute; no repair turns an openable file into a refused one
  except L3.
- Continue on Next Clip on a 29.97 sequence with a reversed next clip at 999/1000 and an off-grid in point: the new
  span covers exactly frames [47, 87), starts at C's value at the cut, and ends on the T/T_S exponent. It is one undo
  step.
- `SetTransitionKind` leaves the range, role and linked audio span unchanged, with exact undo.
- App: the redraw digest (`drawsLike`) covers everything drawn: the "◀" title, kind glyphs, selection, assets, drop
  feedback. Mutations of the content compare and of `TrackAreaCanvas ==` each fail
  `testAKenBurnsDragBuildsNoTimelineModelAndRedrawsNoClips` (20 builds, 20 draws per mode).
- More app work that holds:
  - The timeline height migration handles nil, NaN, infinity, 0, negatives and huge values.
  - The speed sheet's undo group closes on every path, and a direction-only apply is one step named "Reverse Clip".
  - Unlink's selection rule: two mutations each fail `UnlinkSelectionTests`.
  - The Ken Burns geometry: a +θ mutation fails `testTheTwoGeometriesDescribeTheSamePlacement`.
  - Wipe glyphs match `Transition.h`, and a mode switch mid-drag is refused.

## Test gaps
1. H1 with odd n: the committed test uses n = 10, and a floor-instead-of-ceil mutation of the migration passes it (M8's
   pruning re-shortens the fade; only the warning count differs). Add n = 11 and assert the warnings.
2. `ReverseClipTests` uses a symmetric range (0.5-1.5 s of a 2 s movie, so mediaIn == sourceIn and sourceIn + sourceOut
   == mediaEnd): showing clip times in the Source rows and mirroring about the clip's own range (the plan's rejected
   moving mirror) both survive. The helper's asymmetric test (0.2-0.8 s reversed: rows 0.2 / 0.8 "(reversed)", the
   timeline's media 0.8 at the clip's start and 0.2 at its end) passes on the code and fails on both mutations; add it.
3. Selection drawing: passing `selected: false` to the renderer survives `TimelineSelectionStyleTests` and
   `TimelineRedrawTests` (they restate the style struct). Add a pixel check of a selected clip's border and fill.
4. The mixed-direction speed sheet (M1) and Add Ken Burns… on a picture in picture (M2).
5. Reverse at a genuinely odd nanosecond media end with a clip length that is not a multiple of 3 frames (L1);
   reversing audio linked to a still (L2); `reversed` on a still in a file (L3).
6. Reverse playback (J, -2x, -4x), fast forward and scrubbing over a reversed clip: no committed test (the lead's
   scratch run passes at every rate).
7. Throughput of a reversed long-GOP 4K clip (playback and export): each backward window seeks to its keyframe and
   decodes forward, and the cache budget gives two 4K streams about 7-frame windows, so a 1-2 s GOP is decoded
   several times per window. Unmeasured; the only long-GOP reversed test is 1080p.
8. The Ken Burns mode switch's own builds and canvas draws are not counted (the drag test reads its counters after the
   switch); Continue on Next Clip is tested from Transform mode only.
9. The export parity tolerance (a 16 x 16 block mean within 14 codes, mean within 1) cannot see a wipe edge placed
   less than about a pixel off; the edge's placement is held by `TransitionShapeTests` at the compositor, so the
   parity tests guard only the plumbing. Keep it that way deliberately.
10. Test infrastructure: `DoctestRunnerTests.mm` runs all 255 doctest cases with no filter; the engine helper had to
    add an environment filter (`TEST_RUNNER_DT_TC` to `context.setOption("test-case", ...)`) to run a subset. Worth
    checking in.

## Deviations from the plans
- Reverse: the mirror is fixed at the media end instead of the plan's `sourceIn + sourceOut - u`. Justified: the
  plan's own consequences (a head trim removes media from the end, split pieces keep their pictures, spans stay on
  their pictures) need it; relinking to a file of another length would move a reversed clip's pictures, and the app
  has no relink. The mirror of the frame's end is the exact rule (the start was one frame off).
- An unknown transition kind loads as a cross dissolve with a warning instead of being refused. Justified (forward
  compatibility), with the round-trip loss noted in L8.
- Glyphs point the way the edge travels instead of the plan's order. Justified and consistent with the engine.
- The Speed row existed; presets, the help line and the range refusal were added. "Survives copy" has nothing to act
  on (no clip copy and paste).
- Ken Burns editor: the placement-box model replaced the fix round's crop window (the user's decision; the engine
  crop and schema-6 crop field were dropped). The Ken Burns rectangle is the exact preimage (centre F - R(-θ)(x, y) /
  s, turned by -θ) instead of the brief's formula, which holds only without rotation. Justified.
- Continue on Next Clip starts at the placement at the cut, not the brief's `matchSpanEdge` value (which would hold
  the framing two frames). Justified.
- Unlink keeps the clicked clip rather than the first selected. Justified; L4 is about multi-pair selections, not
  this choice.
- Smooth wipes: the test holds the shader to the exact box filter away from the feather and to a 32-sub-step average
  of the soft edge, instead of the brief's 32-sub-step hard edge (which is itself 4 codes off). Justified.
- Fades on black: only the shaped kinds; dissolve fades keep the frame-centre mix for bit identity. Justified as a
  choice, but README overstates it (L7).
- M8 moves an overlapping span to a free lane instead of refusing the file. Justified (composition commutes).

## Method and runs
- `xcodegen generate; caffeinate -d -u -i xcodebuild -scheme Framewright -destination 'platform=macOS'
  -derivedDataPath /private/tmp/fw-review-dd test`: "EngineTests.xctest ... Executed 467 tests, with 0 failures";
  "[doctest] test cases: 255 | 255 passed"; "AppTests.xctest ... Executed 257 tests, with 1 test skipped and 0
  failures"; "** TEST SUCCEEDED **"; no `warning:` in project sources.
- `xcodebuild ... -derivedDataPath /private/tmp/fw-review-tsan-dd -enableThreadSanitizer YES test` over
  PlaybackPreviewSoloTests, PlaybackLookaheadTests, VEEngineProgramSoloTests, ClipAudioSourceTests, AudioMixerTests,
  PlaybackControllerTests, PlaybackTransportTests, PlaybackDisplayPathTests, ExportParityTests: "Executed 79 tests,
  with 1 test skipped and 0 failures"; no ThreadSanitizer report.
- Scratch tests (all reverted; the tree was clean after each): reversed audio on five sources, three mirrors and two
  speeds (ClipAudioSourceTests); reversed clip under shuttle and scrub (PlaybackLookaheadTests); the helpers' app
  scratch tests re-run in the main tree (the M1 test fails, the M2 probe prints 0 reachable corners). Mutations: the
  mirror of the frame's start (Clip.cpp), the fade-in exposure (Scheduler.mm), the decode direction
  (PlaybackController.mm); the helpers' mutations are listed under "Done properly" and "Test gaps".
