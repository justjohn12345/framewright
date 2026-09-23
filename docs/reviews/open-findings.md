# Open findings

Unfixed items as of the 2026-09-23 full review (commit 1b490bb). Full detail, probes and evidence are in
`2026-09-23-full-review.md`; numbers below match its "Ranked findings".

## Facade / app (from the full review)
1. HIGH (verified): cross-project asset-id aliasing. After Open, the source-monitor DecodePool (and in-flight workers) still
   decode the previous project's files under reused ids into the shared FrameCache; both monitors can show the wrong media.
   Fix on both pools in `forgetProjectMedia`, register every new asset synchronously on open, re-check slot identity before
   `cache_->put`, and long term key cache/pool slots by (media epoch, asset id).
2. MEDIUM (verified): an open coalescing group absorbs unrelated edits (Cmd+K refused during a drag; Delete during a slider
   drag loses the slider change and can resurrect the clip). Tag only the gesture's own edits; refuse or end the group otherwise.
3. MEDIUM (verified): Delete with the media bin focused deletes the timeline selection. Branch on `focusArea` first.
4. MEDIUM (verified): both monitors can play at once; two DecodePools fight over one FrameCache's focus and budget. Pause the
   other monitor; per-client focus; split the budget.
5. MEDIUM (verified): ThumbnailCache/WaveformCache poisoned across Open/New by stale in-flight completions. Add a generation.
6. MEDIUM: keyboard focus rules (first responder never reclaimed from text fields; any key window accepted; no `isARepeat`;
   Escape swallowed; ruler scrub does not focus the timeline).
7. MEDIUM-LOW: UI playhead stale after an edit shortens the sequence (`modelChanged` clamps without posting status).
8. MEDIUM-LOW (verified): moving both clips of a transition to another track drops the transition (`MoveClips` never updates
   `Transition::trackId`).
9. LOW (verified): the redraw-budget test is vacuous (canvas never draws in the test host; no positive control).
10. LOW: `VE_ASSERT_MAIN` raising in Release needs `NS_SWIFT_UI_ACTOR` annotations and a documented main-thread dealloc rule.
11. LOW: synchronous bookmark resolution on main without `NSURLBookmarkResolutionWithoutMounting`; `FreshIds` does not forward
    `mergeWith`; `isImporting` shared by concurrent imports.
12. LOW: PLAN deviations to call out or fix: HUD lacks presented index vs audio clock; zoom keys; playhead draggable only in
    the ruler; `useCount` doc.

## Scaffold (project.yml, README, scripts)
13. `ENABLE_HARDENED_RUNTIME` off with no stated reason; add hardened runtime plus Developer ID in a Release/Archive config.
14. LGPL compliance: bundle `COPYING.LGPLv2.1` and a notice in Resources; README source offer and build-script reference.
15. Enable `-Wall -Wextra`, `GCC_TREAT_WARNINGS_AS_ERRORS`, `SWIFT_TREAT_WARNINGS_AS_ERRORS` (build is warning-clean).
16. `.gitignore`: `.swiftpm/`, `.build/`; README: `make_test_media.swift`, `BUILD_TOOLS=1`, `ENABLE_SVTAV1=1`; add
    `CoreAudio.framework` for a device-appeared listener.

## Test gaps
See §5 of `2026-09-23-full-review.md` (13 items, including the cross-project aliasing regression, edits during an open group,
keyboard focus cases, monitor exclusivity, cache generations, a positive control for the redraw test, and the real SwiftUI
gesture path).
