# Phase 6 review (2026-09-23)

Reviewer: Claude (lead), full read of the four phase 6 commits f8231a3..65746a4 (35 files, +4372/-308): engine edit ops
and facade, InspectorModel/View/NumericField, TimelineGestureController/Renderer/ViewModel/View, SpeedDurationSheet,
TransitionsPanel, EditingPreferences, and every new test. Independently verified: full VidEdit scheme green (365 EngineTests
incl. 146 doctest cases, 66 AppTests), zero warnings under -Werror, no TODO markers, app launches.

## Summary
No critical or high findings. The engine side (`SetClipsParams`, `transitionLimit` bisection, linked crossfade as one
CompositeCommand, multi-clip speed) is correct and the tests are real (before/after values, undo counts, refusal codes).
The inspector and gesture code honour the coalescing contract (tokens, Busy handling, Accumulate bursts) and every refusal
reaches the user. The items below are behaviour and UX gaps plus a few robustness details.

## Ranked findings

1. MEDIUM: a linked crossfade shortens the video dissolve to the audio cut's limit. `VEEngine.mm`
   `addTransitionFromClip:toClip:duration:options:` (the `IncludeLinked` block): when `FitToCut` is set and the partners'
   cut allows fewer frames than the main cut, `frames` is reduced for BOTH transitions ("Shortened to N to fit the linked
   clips"). Scenario: A|B video has 30 frames of handles each side, the audio under it was trimmed tight with 3 frames; the
   user drops a 1 s dissolve and gets a 3-frame video dissolve. Premiere adds each transition at its own maximum. Fix: fit
   each transition to its own cut independently (main at `min(frames, limit.max)`, partner at
   `min(frames, linked.max)`), note both shortenings; if matching lengths are wanted, make it an explicit option. Update
   `testADissolveWithItsLinkedCrossfadeIsOneUndoStep` with an asymmetric-handles case asserting the two lengths.

2. MEDIUM: the paused program monitor can present a frame with the layer missing before the decoded picture lands; the
   flaky-test change hid it rather than fixing it. Commit 4e719d3 added an extra `renderOnceWithCompletion` before the
   `missingLayerCount == 0` assertion in `EngineTests/Facade/VEEngineTests.mm` `testProgramViewShowsTheFrameAtTheRequestedTime`,
   with the explanation that a render "had drawn the layer without it". That is a visible flash (black or partial frame) on
   every seek/step when the frame is not yet cached, then a redraw. Fix in `VEProgramFrameProvider`/the controller's frame
   source: while a scrub request for the current show() is in flight, keep presenting the previous complete picture (or
   return "unchanged") instead of drawing the layer missing; only count `missingLayerCount` for frames that were actually
   presented incomplete. Then restore the original strict assertion (no extra render) and add a test that steps through
   10 uncached frames and asserts `missingLayerCount` stays 0 while every presented burn-in matches.

3. MEDIUM: Editing preference changes do not refresh open views. `TimelineView` captures
   `store.editingPreferences.durationDisplay` in the `formatFrames` closure at body time, `InspectorModel.text`/`format`
   and `ProjectStore.durationString` read `UserDefaults` outside SwiftUI observation. Changing "Show durations as" or the
   default transition duration in Settings leaves the timeline bands and inspector fields showing the old format until an
   unrelated model change. Fix: mirror the three keys as `@Published` on a small `EditingPreferencesModel` observed by the
   store (or `@AppStorage` in the views) and include a preferences token in the canvas redraw dependencies; test that
   toggling the display re-formats `inspector.text(.fadeIn)` and the timeline label without a model change.

4. MEDIUM-LOW: `InspectorModel.handle` writes `store.statusMessage = message` on every successful edit, including `nil`,
   so a successful inspector edit wipes whatever the status line was showing (a timeline drag's "Transition: 12f", a
   refusal from a menu command). Fix: only set `statusMessage` when the note is non-nil; let the timeline own its status.

5. LOW: the user is not told why a linked crossfade was skipped. `ProjectStore.addTransition` calls
   `linkedCutAcceptsTransition` first and, when false, passes no `IncludeLinked` option, so the engine's note ("The linked
   clips got no transition: …") is never produced. Fix: always pass `IncludeLinked` for `.always`/answered-yes and surface
   `result.note` in the status line (the engine already handles the not-adjacent and no-room cases).

6. LOW: `ProjectStore.nearestCut` has no distance bound, so Shift+Cmd+D with the playhead far from any cut adds a
   transition at a distant, possibly off-screen cut and selects it. Fix: prefer the cut at either edge of the clip under
   the playhead on that track; otherwise refuse with "Move the playhead near a cut" (or bound to a few seconds).

7. LOW: `TimelineGestureController.hover(at:)` calls `NSCursor.*.set()` on every pointer move (SwiftUI's
   `onContinuousHover` fires per event). It only republishes `hover` on change; do the same for the cursor (set on hit
   change only) and consider `NSCursor.pop()`/restoring the arrow when the pointer leaves the track area so the split-view
   divider cursor is not fought.

8. LOW: `SpeedRatio.parse` silently approximates percentages with more than one decimal ("33.33" → 1/3 = 33.333…%,
   "12.345" → nearest denominator ≤ 1000). The field then shows the applied value, but no message says it was adjusted.
   Fix: when the applied ratio differs from the typed value by more than 1e-9, add a note "Applied as 1/3 (33.33 %)".

9. LOW: `TransitionsPanel` combines `.draggable` with `.onTapGesture(count: 2)` on the same row. SwiftUI drag sources can
   swallow the second click on macOS; the context-menu path exists as a fallback, but the double-click path is untestable
   headless. Verify by hand; if it fails, move the double-click to a separate button/overlay.

10. LOW: on audio clips the fade handles and the transition strip both live in the top 16 pt, which is also the clip's
    label row. Clicking the first ~6 pt of an audio clip's label grabs the fade-in handle instead of selecting. Acceptable
    Premiere-like behaviour, but document it in the `TimelineView` header and consider a smaller `fadeHandleZoneHeight`
    when the clip is narrower than ~40 pt.

11. LOW: `VE_ASSERT_MAIN` is missing on `-[VEEngine coalescingKey]`'s siblings? No: present. But
    `VEClipParamsBatch` is a plain NSObject with a C++ vector and no thread annotation; document it as main-thread-only
    (it is only ever built on main) or make it `NS_SWIFT_UI_ACTOR` like the engine.

## Done properly (do not redo)
- `transitionLimit`: correct monotone bisection over whole frames, upper bound justified, reasons name the limiting clip
  and media; refusal text includes the longest allowed length; tested for every limit kind including neighbours and locked
  tracks.
- `SetClipsParams`: refused as a whole, track-kind checks, Accumulate merging; `VEClipParamsBatch` de-duplicates per clip.
- Linked crossfade as one `CompositeCommand` with `createdIDs` order documented; `setSpeedNumerator:…forClips:` covers
  linked partners once and reuses `pushRipple` fallback.
- `InspectorModel`: single-value/burst/slider modes with correct group handling, `sliderInterrupted` stops a drag after
  Busy, burst idle timer checks the group identity, per-clip fade clamping, mixed-value display, reset per parameter and
  section, unit parsing with clamping and messages; `NumericField` commits on Return/focus loss, nudges from the field,
  Escape reverts, commits pending text before a nudge.
- Gesture controller: transition edge drag symmetric about the cut, bounded with the reason; fade drags bounded by the
  other fade; gain drag with fine mode and tooltip; drop feedback with reason; all as Replace groups ended/cancelled
  correctly; `endGroup` only ends its own drag groups.
- Tests: nudge coalescing (engine + view model), typed units, multi-selection batches, slider one-step, Busy interruption,
  refusal messages, hit testing of bands/handles/gain line, all three drag kinds with undo counts, drop feedback and
  refusal, linked-crossfade preference (always/never/ask/cancel), speed sheet incl. refusal, program re-render paused and
  playing with pixel checks.

## Test gaps
1. Inspector `.transitionDuration` field: typed value beyond the limit, nudges (Accumulate) up to the limit, reset to the
   preference default; and the Transition section's "Delete Transition" button with `focusArea == .mediaBin`.
2. `NumericField` AppKit behaviour (commit on focus loss, Escape revert, Shift+Up = +10, pending text committed before a
   nudge) via a hosted window and `control(_:textView:doCommandBy:)`.
3. A transition duration change re-renders the program frame inside the dissolve (extend `ProgramRerenderTests`).
4. Asymmetric linked handles (finding 1) and skipped-partner note (finding 5).
5. Preference change re-formats views without a model change (finding 3).
6. Speed slider drag (Replace) over a clip followed by others with ripple: one undo step and later clips restored.

## Deviations recorded
- Per-asset backend override (PLAN phase 6 mention) not built; global preference exists. Fine for MVP.
- Refusal text goes in `message`, `note` carries "shortened to fit" explanations.
- A one-frame transition needs media only after the outgoing clip's out point (documented in the engine).
