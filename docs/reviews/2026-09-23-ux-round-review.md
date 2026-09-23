# UX round review (2026-09-23)

Reviewer: Claude (lead), full read of the three UX-round commits b5310ba..b24df12 (41 files, +3422/−167): engine (edit ops,
facade, playback controller, export retarget), app (layout model, panes, output display, context menu, inspector,
gesture controller, drop delegate, keyboard), and every new test. Independently verified: full Framewright scheme green
(421 EngineTests incl. 157 doctest cases, 105 AppTests), zero warnings under -Werror, no TODO markers, app launches.

## Summary
No critical or high findings. The linked-transition commands, the through-edit detection, the layout model, the output
display controller and the drop-delegate refactor are correct and well tested; the play-start work found and fixed a real
VFR bug and the tests measure what they claim. The one design-level issue is that the VFR "fix" codified a bias: pictures
for variable-frame-rate sources are chosen by the start of their nominal frame slot, which can be the frame before the one
under the exact source time, and the new tests assert that early frame. The cache already offers a time-based lookup that
removes the bias. The rest are small UX and robustness items.

## Ranked findings

1. MEDIUM: VFR picture selection is biased early by up to one nominal frame. The frame source pins pictures by nominal slot
   (`PlaybackController.mm:308-310` `slotFor` → `acquire(asset, index)`), and the new `frameSlotTimeFor` (`:655`) makes the
   decode requests and pool targets fetch the frame containing the slot's start rather than the frame containing
   `layer.sourceTime`. `testPlayStartsPromptlyOnAVariableFrameRateSource` and the VFR dissolve test assert
   `vfrFrameAt(slotStart)` for the displayed picture, i.e. they lock the bias in. Scenario: an iPhone clip at 31.58 fps
   nominal with short/long frame pairs; whenever a long frame is followed by a short one the monitor and the export show the
   long frame one sequence frame too long and skip into the short one late; visible as periodic judder against the exact
   time mapping. Playback and export agree, so parity tests cannot see it. Fix: for assets flagged VFR (or simply always),
   look pictures up by time with the existing `FrameCache::acquire(asset, CMTime)` / `get(asset, CMTime)` / `contains(asset,
   CMTime)` containment API and request decodes at `layer.sourceTime`; keep `frameSlotFor` only as the CFR fast path or drop
   it. `ExportJob` uses the same helper, so it follows. Update the two VFR tests to assert the frame containing the source
   time (`vfrFrameAt(source)`), keeping the millisecond tolerance for Matroska. Re-measure the VFR play-start latency after.

2. MEDIUM-LOW: every editing key works in the second-display output window. `KeyboardController.handle` accepts events
   from `store.outputDisplay.window` for all actions, so Delete, Shift+Delete, Cmd+A, I/O and zoom act on the timeline while
   the user is looking at the output display. Fix: when the event window is the output window, handle only transport keys
   (Space, J/K/L, arrows, Home/End) and Escape; ignore the rest. Test in `OutputDisplayTests`.

3. LOW-MEDIUM: output window behaviour at the edges. It sits above the menu bar on every Space with
   `hidesOnDeactivate = false`, so it stays on top of other apps on that display after Cmd-Tab (Premiere's transmit hides
   with the app); and `targetScreen` falls back to the first screen when `editorWindow` is nil, which can be the editor's
   own screen (the window then covers the editor). Fix: hide on `NSApplication.didResignActiveNotification` and reshow on
   activate (or make it a preference), and refuse `show()` when the editor's screen is unknown.

4. LOW: the source monitor's controller keeps its stopped lookahead while the monitor is hidden and during an export
   (`beginExport` only pauses `_sourcePlayback`; `setSourceMonitorVisible(false)` only pauses it). Its pool then holds
   decoders and ~0.5 s of frames for nothing, and its audio device stays warm for the 5-minute idle timeout. Fix: call
   `setIdleLookahead(false)` on the source controller when the monitor is hidden and while an export runs, `true` again
   when shown / the export ends.

5. LOW: `outputIdleTimeout` of 5 minutes keeps `AVAudioEngine` and the output device running after any transport activity.
   Right for a desktop editor; on battery it costs power for idle sessions. Consider 60 s on battery
   (`IOPSCopyPowerSourcesInfo`) or document the choice in Preferences.

6. LOW: `PaneDivider` uses `NSCursor.push()/pop()` while the timeline uses `NSCursor.set()`; a drag that ends with the
   pointer outside the divider leaves the resize cursor until the next hover cycle (the `!dragging` guard skips the pop),
   and a push/pop stack mixed with `set()` can restore the wrong cursor. Fix: use `set()` with change detection on the
   divider too, and reset the cursor in the drag's `onEnded` when the pointer is outside.

7. LOW: `testPlayStartLatencyThroughTheFacade` asserts < 50 ms wall clock against the real audio device (measured 17-27 ms
   cached, 36 ms under TSan). It is the right assertion but will flake on a loaded machine. Keep it, but skip it under TSan
   and mark it as a performance test (or widen to 80 ms with the measured value logged).

8. LOW: `ContextMenuCatcher` installs an application-local monitor for every left mouse down to detect Control-click; it
   converts and hit-tests on every click in the app. Cheap, but it should filter on `modifierFlags.contains(.control)`
   before converting coordinates, and it should not install when the view has no window (it already removes on move).

## Done properly (do not redo)
- `RemoveTransitions` / `SetTransitionDurations` as single `SequenceCommand`s (Accumulate merging works; tested),
  `linkedTransition` both ways, locked-partner handling with notes, `isThroughEdit` with the still and speed cases; the
  facade's `includingLinked` variants fit the partner to its own cut and explain refusals; handle drags and nudges coalesce.
- The VFR slot bug diagnosis (1005 ms → ~10 ms) and the measurement method (host time of the first clock-driven frame
  minus the playing time it stands for), cached and cold, controller and facade, plus the mirror-source design (decode once,
  map per view, counters untouched; tested for parity and non-counting).
- Stopped lookahead: forward window from a still playhead after 100 ms, never while the playhead moves (tested with
  arrow-key repeat), cleared for exports via `setIdleLookahead(false)` and restored after, within the pool's budget share
  (tested with a 24 MB cache); audio warm on any transport activity.
- Layout model: clamped, persisted, in-memory for tests, fitted timeline height with min/max, split drags relative to the
  start size, source-monitor fraction, empty-track collapse keyed into the timeline cache, redraw budget preserved (0
  rebuilds on layout toggles; tested).
- Output display controller over an injectable screen list: availability, cover the other display, Escape, display gone
  with a status message, editor window close, transport keys; engine attach/detach with the mirror role; play refused
  during export.
- Drop delegate over a `TimelineDropInfo` protocol with tests for validate/hover/drop/refusal and an async asset drop; the
  drag source's exported UTTypes verified as declared and non-dynamic.
- Context menu items built by the gesture controller (select under the pointer, transition and clip actions) and tested.

## Test gaps
1. VFR: after finding 1, a test that the displayed picture is the frame containing the exact source time for both backends,
   and that export shows the same frames (extend `ExportParityTests` with a VFR clip).
2. Output window: only transport keys are handled (finding 2); hide/reshow on app deactivate/activate (finding 3).
3. Source controller lookahead off while hidden and during export (finding 4): assert its pool has no streams.
4. `ContentView` narrowing order (inspector first, then the bin) at a 1100-pt window; the source-monitor fraction clamp
   while dragging past the bounds.
5. The through-edit note through the Effects tab drop path (only the "+" path is covered at the store level).

## Deviations
Single `SequenceCommand`s instead of a composite (justified: Accumulate merging), SwiftUI dividers instead of `NSSplitView`
autosave (justified: fit-to-content and testability), 5-minute output idle timeout (see finding 5), only empty tracks
collapse (as specified), an extra Reset Window Layout menu item. All acceptable.
