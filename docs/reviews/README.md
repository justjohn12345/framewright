# Reviews

Adversarial read-only reviews are run after each implementation phase; findings are fixed in a follow-up round.

- `open-findings.md`: findings not yet fixed. The next fix round works from this file.
- `integration-notes.md`: API changes other layers must adopt, collected from the fix agents.

History (full reports are removed once every finding is fixed and remain in git history; the latest full review is kept):

| Date | Scope | Findings | Fixed in |
|---|---|---|---|
| 2026-09-22 | Model, edit, undo, JSON, scheduler | 15 (exact time math, slow-motion flash frame, dissolve mix, linked-pair ripple, locked tracks, undo depth, fades/transitions, JSON v2) | 5671f68..f8e1d1e |
| 2026-09-22 | Render, preview view, scaffold | 14 (collapse blackout, rotation, minification, straight alpha, ring-slot desync, drawable under lock, chroma siting, 10-bit drawable) | 913fc78..4a0d1ba; scaffold items still open |
| 2026-09-22 | Media backends, router, cache, pool, thumbs | 18 (VFR durations, cache slot mapping, budgeted windows, decodability routing, measured hardware flags, interruptible decode, dav1d AV1) | e595d1f, ca41f40, 9d72a84 |
| 2026-09-22 | Playback engine | 6 of 14 (blocking transport, non-monotonic display clock, seek-back dropout, device-change race, polling producers, HUD) | d46c2c5..5325cd9 |
| 2026-09-22 | Facade + Swift UI (from the playback review) | 11 (import mid-drag, id reuse after undo, vertical multi-move, snapping, close prompt, redraw split, source monitor, focus) | 802da3b..1b490bb (phase 5b) |
| 2026-09-23 | Phase 6 effects/transitions UI (report in history at 17f13d8) | 11 (linked crossfade length, layer-missing flash on seek, preference refresh, status line, and lows) | cb439b4..cb326d9 |
| 2026-09-23 | Full pass after phase 5b (report removed once fixed; in git history at 75d5e35) | 12 new (cross-project id aliasing, coalescing group absorbs edits, bin Delete, dual playback, cache poisoning, keyboard focus) + 4 scaffold; all earlier groups Held or Partially | 9240dc9..263863b (media epochs, coalescing tokens, monitor exclusivity, Distribution signing, LGPL notices, warnings as errors); two test gaps open |
