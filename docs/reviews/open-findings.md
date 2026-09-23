# Open findings

Unfixed items from the 2026-09-22 reviews. Severity as assessed by the reviewer; line numbers refer to commit 223ab80 and
may have drifted. Items 1, 2, 3 were reproduced with probe tests.

## Facade (Engine/Facade)

1. HIGH (verified): an import finishing during a timeline drag breaks the drag. `finishImport` calls `closeCoalescingIfOpen`
   (VEEngine.mm ~800, defined ~1026), clearing `_coalescingKey`/`_coalescingBase` mid-gesture; `removeAsset` does the same.
   TimelineView keeps sending the total offset from the gesture origin, so `moveClips` adds it to the current position on every
   event. Probe: drag 1.0 s, import completes, drag to 2.0 s → clip at 4.5 s, drag split into three undo steps, Escape no-op.
   Also `importMediaAtURLs` never captures `_projectGeneration`, so an import started before New/Open lands in the next project.
   Fix: never close a user coalescing group from async completions (push uncoalesced, or queue until endCoalescing); capture the
   generation and drop stale results.

2. HIGH (verified): undoing an import reuses the asset id; id-keyed caches serve the old media. `ImportAssets::revert` restores
   `project.ids = idsBefore_` (VEFacadeCommands.mm ~43), contradicting VETypes.h ("never reused"). Probe: import wav (id 6) →
   undo → import mp4 → id 6 again; `waveformForAsset:6` returns the WAV peaks. Caches keyed by id and never purged: FrameCache,
   ThumbnailService memory cache, Swift MediaCaches. Worst case: `_bookmarks[id]` keeps the old bookmark when creating the new
   one fails → save writes A's bookmark for B. Clip ids roll back the same way. Fix: monotonic id generator across undo (restore
   the asset list, never roll back `ids`), or purge every id-keyed cache and bookmark on remove/re-add.

3. HIGH (verified, data loss): multi-clip move with a track offset overwrites the selection's own clips. `moveClips` orders by
   timelineStart only (VEEngine.mm ~1180) and applies each MoveClip with overwrite semantics. Probe: X on V1 [0,2), Y on V2
   [1,3), move both up → X cuts Y; Y ends on V3 as [1,2) with sourceIn 5 s; success reported. Fix: lift all selected clips
   first then place them as one command, or order by destination track and refuse when a destination overlaps another selected
   clip's source slot. Regression test.

4. LOW: `VE_ASSERT_MAIN` is NSAssert (compiled out in Release) and is missing on `hardwareCaps`, `backendNames` and the
   `frameCacheBudgetBytes` getter; `VEAssetInfo.useCount` goes stale (no assets notification on edits); memory pressure purges
   only the FrameCache (forward to the preview view, thumbnail and waveform caches, compositor scratch).

5. Adoption of the fix-round API changes (see `integration-notes.md`): surface `droppedTransitionIds`, `NotRepresentable`,
   `InsideTransition`, `ProjectLoadResult::warnings`; `Ratio` speed; ripple-scope preference; scrub lanes; rotation in
   `VEAssetInfo`.

## Swift app (App)

6. MEDIUM: snapping during a move uses the live previewed model (TimelineView.swift ~267), which already contains the previous
   step's overwrite; crossed clips are split at the dragged clip's previous edges and those edges are not excluded → the clip
   advances in ~8 pt jumps with a flickering snap line. Fix: candidates from the pre-gesture snapshot captured at startDrag.

7. MEDIUM: closing with unsaved changes asks twice (windowShouldClose confirms, then the last window closing terminates the app
   and `applicationShouldTerminate` prompts again; Cancel leaves the app running with no window); Finder-open at cold launch is
   dropped because `appDelegate.documents` is set only in the window's onAppear. Fix: a confirmed/discarded flag or mark clean
   after Don't Save; set `documents` in App.init or buffer pending URLs.

8. MEDIUM (perf): one ObservableObject drives the whole window. ProjectStore publishes ~25 properties; every change rebuilds
   `timelineModel` (also per drag event), `assetsByID`, and redraws the whole Canvas with waveforms recomputed every 2 px;
   `layout(forTrack:)` recomputes per clip rect. Wiring the playhead at 30-60 Hz will redraw the window per frame. Fix: split
   playhead/scroll/zoom into separate observables; cache `timelineModel` per changeCount; pre-render waveform strips; playhead in
   an overlay layer. Do this BEFORE phase 5b wires playback.

9. MEDIUM: the source monitor is a stand-in: thumbnails up to 1920 px, each scrubbed frame written to the disk cache as a
   1-3 MB PNG; in/out points stored at timescale 600 off the frame grid and shown with the sequence's timecode rate. Fix: a
   VEPreviewView-based source monitor through a DecodePool scrub lane; snap in/out to the asset frame grid.

10. LOW-MEDIUM: Cmd+Z during a drag cancels the drag AND undoes the previous edit (ProjectStore.undo). Stop after cancelling.

11. LOW: Swift caches' `failed` sets are permanent (MediaCaches.swift); ruler scrub snapping blocked by the playhead's own
    candidate; the video row's trackOffset is applied to selected unlinked audio clips; `drag` state leaks if the gesture is
    cancelled without onEnded; the key monitor takes arrows/space from focused non-text controls; pass
    `attachID: ObjectIdentifier(store)` to `ProgramMonitorView`.

## Scaffold (project.yml, README, scripts)

12. `ENABLE_HARDENED_RUNTIME` is off with no stated reason; notarisation needs it. Add hardened runtime plus Developer ID in a
    Release/Archive configuration (CodeSignOnCopy already re-signs the dylibs).
13. LGPL compliance is claimed but not backed: bundle `COPYING.LGPLv2.1` and a notice in Resources; README source offer and
    build-script reference.
14. No `-Wall -Wextra`, `GCC_TREAT_WARNINGS_AS_ERRORS`, `SWIFT_TREAT_WARNINGS_AS_ERRORS`; the build is warning-clean, so enable.
15. `.gitignore` lacks `.swiftpm/`, `.build/`; README omits `make_test_media.swift`, the ffmpeg tools build (`BUILD_TOOLS=1`,
    `ENABLE_SVTAV1=1`) and the Metal Toolchain download. Add `CoreAudio.framework` to enable a device-appeared listener.

## Test gaps

- Facade: multi-clip move with track offset; undo import then import; import completing mid-coalescing; open after moving a
  media file (bookmark follows the move); save/open/missing-asset flows under a real sandbox (the Debug test host has an
  injected read-only-`/` entitlement, so the current sandbox test is vacuous).
- AppTests: the smoke test triggers the thumbnail/waveform fetches it then asserts and never checks timeline drawing; no tests
  for TimelineView gesture states (drag, trim, Escape, cancel), DocumentController close/quit/save-failure, or the
  WindowAccessor close guard.
