# Full review at 1b490bb (2026-09-23)

Reviewer: Opus 5.5, single read-only pass over the whole codebase after phase 5b, from a `git archive 1b490bb` extraction with
private DerivedData. One full run: EngineTests 341 (3 XCTSkip: no awake display), doctest 140/140, AppTests 35/35, Apple MP4
60 s drift 0 errors, FFmpeg MKV 20 s drift 0 errors, control-call p95 ≤ 0.38 ms. Probes (E1-E4, P1-P2) were added in the
scratch tree only and run with `-only-testing:`.

## 1. Summary
The earlier review fixes are in place and still hold. The engine layers (model, media, render, audio/playback) are in good
shape. The new phase 5b wiring (facade playback, source monitor, gesture controller, redraw split) is mostly correct and much
better tested than 5a. The main new problem is id aliasing between projects: asset ids restart per project, and the source
monitor's DecodePool never forgets the previous project's files, so after an Open both monitors can show the old project's
media under a reused id (verified). Also: an open coalescing group takes in unrelated edits (data loss), both monitors can play
at once over two pools fighting one FrameCache, Delete with the bin focused deletes timeline clips, thumbnail caches are
poisoned across an open, and keyboard focus is never taken back from text fields.

## 2. Ranked findings

1. HIGH (verified, probe E1): after Open, both monitors show the previous project's media for a reused asset id.
   `forgetProjectMedia` (VEEngine.mm:484-505) invalidates only `_decodePool`, and `DecodePool::invalidate` (DecodePool.mm:241-262)
   keeps the old URL; `_sourcePool` only gets `setTargets({})` so its `assets_` slots and scrub decoders still name project A's
   files; the source pool learns new paths only via `registerRouting` (VEEngine.mm:1194-1202) at import or after the async
   re-probe, never for missing assets (646-651, 663-666). Decodes then `cache_->put` under the id (DecodePool.mm:618, 881) and the
   shared FrameCache serves them to the program controller. Separately a worker whose stream was removed can still `put` after
   `purgeAll()`; `step()` never checks `removed`/slot identity. Probe: import mp4 (id 6), open a copy with asset 6 missing,
   `sourceMonitorShowAsset:6` → "source monitor shows burn-in 30 for a MISSING file … lastError (null)"; program monitor same.
   Fix: `DecodePool::forget(asset)`/`clear()` dropping the slot and scrub decoders, called on both pools in `forgetProjectMedia`;
   in `openProjectAtURL` register every asset (missing included) on both pools synchronously; before `cache_->put` re-check the
   slot identity under `mutex_`; long term key FrameCache and pool slots by (media epoch, asset id).

2. MEDIUM (verified, probe E2): an open coalescing group takes in every unrelated edit. `pushCommand` (VEEngine.mm:1212-1221)
   tags every edit with `_coalescingKey`; `UndoStack::push` (UndoStack.cpp:20-38) reverts the group's previous step and applies
   the new edit against the pre-gesture state. Cmd+K during a drag: "split during drag ok=0" (refused, misleading error). Delete
   during an inspector slider drag: "delete ok=1: other clip exists 0, opacity now 1.00 (0.50 if kept)" — slider change lost,
   next slider step would resurrect the deleted clip. A leaked group makes every later edit replace the previous one, holds
   deferred imports (933-941), and makes `removeAsset` Busy. Fix: pass the key only with the gesture's own edits (explicit key or
   per-call token); refuse other edits with Busy or end the group first; KeyboardController/menus skip edit actions while a
   gesture is active.

3. MEDIUM (verified, probe P1): Delete with the media bin focused deletes the timeline selection. `deleteSelection`
   (ProjectStore.swift:377-393) takes the bin branch only when `selection.isEmpty`; Shift+Delete in the bin also routes to asset
   removal. Probe: select a clip, click an asset tile, Delete → "clip exists false, assets 2". Fix: branch on `focusArea` first.

4. MEDIUM (verified, probe E3): both monitors can play at once and their DecodePools compete over one FrameCache. Neither
   `sourceMonitorTogglePlay`/shuttle (VEEngine.mm:2132-2158) nor the program transport pauses the other; J/K/L only reach the
   focused monitor (PlaybackActions.swift:88-105); two AVAudioEngines mix; each pool's `updateFocus` replaces the cache's whole
   focus list (DecodePool.mm:282-290, FrameCache.h:157-159); each pool sizes windows to 75 % of the whole budget from its own
   stream count (DecodePool.mm:478-486) so two playing pools ask for 150 %. Probe: "program state 2, source state 2". Fix: pause
   the other monitor when one starts; per-client focus merged in the cache; split `budgetFraction`.

5. MEDIUM (verified, probe P2): thumbnail/waveform caches poisoned across Open/New. `ThumbnailCache.removeAll` clears
   `inFlight` (MediaCaches.swift:61-67) but old requests still run; the new project's identical key gets its in-flight entry
   removed and a 30 s failure recorded by the old completion ("cancelled"/"project was closed"), then the real image is dropped
   (92-100). `WaveformCache` (164-190, 254-261) same. Probe: "loaded: false (requests started 2)" after 5 s. Fix: generation
   bumped in `removeAll`, captured per request, stale completions dropped; "project was closed" is not a failure.

6. MEDIUM (by reading): keyboard focus. Nothing calls `makeFirstResponder`; after typing in a number field (Return keeps
   focus), clicking the timeline and pressing Space/Delete edits the field. `handle` (KeyboardController.swift:92-106) accepts
   any key window (Settings window key → Space plays, Delete deletes clips). `isARepeat` unchecked (holding L reaches 8× in
   ~0.2 s; holding Space flips play/pause). Escape consumed with no gesture (56). Ruler scrub does not set
   `focusArea = .timeline`. Fix: resign first responder on mouse-down in timeline/monitors; accept only the editor window;
   ignore repeats for Space/J/K/L; pass Escape through when nothing is cancelled.

7. MEDIUM-LOW (by reading): UI playhead stale after an edit shortens the sequence. `PlaybackController::modelChanged`
   (PlaybackController.mm:986-995) clamps `displayTime_` in Stopped/Scrubbing but posts no status; `PlayheadModel` and
   `store.playheadTime` (used by split, insert/overwrite from source, dissolve) disagree with the engine. Fix: `postStatusLocked()`
   when the clamp changes `displayTime_`.

8. MEDIUM-LOW (verified, probe E4): moving both clips of a transition to another track drops the transition.
   `MoveClips::perform` (VEFacadeCommands.mm:238-261) never updates `Transition::trackId`. Probe: "dropped transitions (9) note
   '1 transition was removed because its cut no longer exists.'" Fix: re-home the transition when both clips move to the same
   destination with the same delta.

9. LOW (verified): the redraw-budget test passes vacuously. `TimelineRedrawTests.testPlayheadAtSixtyHertzDoesNotRebuildTheTimeline`
   (AppTests/TimelineRedrawTests.swift:55-67) logged "canvas draws 0": the canvas never draws in this host and there is no
   positive control. Fix: assert a model change increases `canvasDraws` first, XCTSkip otherwise.

10. LOW: `VE_ASSERT_MAIN` raising in Release is defensible but insufficient: VEEngine/VEPreviewView lack `NS_SWIFT_UI_ACTOR`,
    an exception through Swift frames is an uncatchable crash, and `-[VEEngine dealloc]` touches views (VEEngine.mm:378-386) and
    must run on main (undocumented). Fix: annotate both classes; document the dealloc rule.

11. LOW: `openProjectAtURL` resolves bookmarks synchronously on main without `NSURLBookmarkResolutionWithoutMounting`
    (VEEngine.mm:606-618); `FreshIds` does not forward `mergeWith` (VEFacadeCommands+Internal.h:90-105) so Accumulate mode would
    silently stop merging; `isImporting` is one Bool shared by concurrent imports (ProjectStore.swift:543-560).

12. LOW: PLAN deviations not called out: HUD lacks presented frame index vs audio clock (`lastPresented()` not exposed); zoom is
    Cmd+=/- not +/-; playhead draggable only in the ruler; `VEAssetInfo.useCount` documented as active sequence but counts all.

## 3. Previously fixed findings: status

| Group | Status | Evidence for anything not Held |
|---|---|---|
| Model 1-15 | Held | doctest 140/140; exact +/-, Floor snap, (k+½)/n mix, rounded/epoch adopted with warning |
| Render 1-14 | Held | scaffold parts of 10/13 still open (§6) |
| Media 1-17 | Held | |
| Media 18 (caches keyed by asset, not file identity) | Partially | FrameCache/DecodePool slots still keyed by bare id across projects (finding 1) |
| Playback 4, 5, 6, 7, 13 | Held | p95 ≤ 0.38 ms; mHostTime clock + monotonic guard; setGraph repositions; events on tick thread; semaphore producers |
| Playback 14 | Partially | HUD lacks presented index vs clock (finding 12) |
| Facade/UI 1 (import mid-drag) | Held | new side effect of group tagging (finding 2) |
| Facade/UI 2 (id reuse) | Partially | fixed within a project (FreshIds); across projects E1 and P2 |
| Facade/UI 3 (multi-clip move) | Held | new transition drop (finding 8) |
| Facade/UI 4-7, 9, 10 | Held | |
| Facade/UI 8 (redraw split) | Held in design | its test exercises nothing (finding 9) |
| Facade/UI 11 | Partially | key monitor still takes keys from any window and never regains focus from text fields (finding 6) |

## 4. Done properly (do not redo)
FreshIds (monotonic ids across undo, bit-exact redo, works with ReplacePrevious; tested). MoveClips lift-then-place with
pairwise overlap refusal (tested). Imports deferred while a group is open and dropped with ProjectClosed. Gesture controller as
a separate state machine snapping from the pre-drag snapshot, Escape/abandon, Cmd+Z cancels only the drag (tested). Redraw
split: PlayheadModel and TimelineViewport separate, content cached per changeCount, pre-rendered waveform strips, playhead
overlay. Non-blocking transport (measured). Source monitor on its own VEPreviewView and lanes, in/out on the asset grid, no disk
writes while scrubbing (tested). Per-controller scrub lanes (dissolve of one asset shows both layers; tested). Frame status
from mapping failures. Single close prompt, buffered Finder open, save-failure handling (tested). Memory-pressure forwarding,
use-count notifications, edit error codes/notes/dropped transitions, ripple-scope fallback, exact speed field, load warnings.
All audio, render, media and model fixes, with 0-error drift runs on both backends.

## 5. Test gaps
1. Cross-project aliasing regression (E1): missing file, different file, in-flight decode racing `purgeAll` (blocking fake decoder).
2. Edits while a group is open (Delete, Cmd+K, menus) refused or group ended (E2).
3. KeyboardController: Delete with bin focused and a timeline selection (P1); events from a non-editor window; `isARepeat`; text field keeping focus after a timeline click.
4. One monitor starting pauses the other; two pools on one small-budget cache keep both focuses.
5. ThumbnailCache/WaveformCache generations across `removeAll` (P2).
6. `modelChanged` clamp posts a status and PlayheadModel follows.
7. Transition pair moved across tracks keeps its transition (E4).
8. Positive control for the redraw test.
9. Real SwiftUI gesture path (NSEvent drag into the hosted TimelineView) proving `@GestureState` reset never reverts a completed drag via `abandon()`.
10. Import mid-drag: assert the probe finished before the second move (current test can pass without the deferral); deferred import then project close.
11. Carried over: bookmark follows a moved file; real-sandbox save/open; smoke test triggers the fetches it asserts.
12. Timing-dependent: `testFailedThumbnailsAreRetriedAfterTheInterval` (0.1/0.35 s waits); "checked > 30 over 3 s"; "presentedFrames > 30".
13. FreshIds under Accumulate mode.

## 6. Open scaffold items
12 Open: `ENABLE_HARDENED_RUNTIME: NO` (project.yml:32). 13 Open: no LGPL text/notice in App/Resources, no source offer in
README. 14 Open: no -Wall -Wextra / warnings-as-errors (build is at 0 warnings). 15 Partially: README covers Metal Toolchain;
still missing `.swiftpm/`/`.build/` in .gitignore, `make_test_media.swift` in README layout, `BUILD_TOOLS=1`/`ENABLE_SVTAV1=1`
in README, `CoreAudio.framework` for a device-appeared listener. No new scaffold items.
