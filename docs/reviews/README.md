# Reviews

Adversarial read-only reviews are run after each implementation phase; findings are fixed in a follow-up round.

- `open-findings.md`: findings not yet fixed. The next fix round works from this file.
- `integration-notes.md`: API changes other layers must adopt, collected from the fix agents.

History (full reports are removed once every finding is fixed and remain in git history; the latest full review is kept):

| Date | Scope | Findings | Fixed in |
|---|---|---|---|
| 2026-09-22 | Model, edit, undo, JSON, scheduler | 15 (exact time math, slow-motion flash frame, dissolve mix, linked-pair ripple, locked tracks, undo depth, fades/transitions, JSON v2) | 5df3a0a..cb91b36 |
| 2026-09-22 | Render, preview view, scaffold | 14 (collapse blackout, rotation, minification, straight alpha, ring-slot desync, drawable under lock, chroma siting, 10-bit drawable) | bb35d56..20de40e; scaffold items still open |
| 2026-09-22 | Media backends, router, cache, pool, thumbs | 18 (VFR durations, cache slot mapping, budgeted windows, decodability routing, measured hardware flags, interruptible decode, dav1d AV1) | 14c6e73, 49a2ffd, 2342cda |
| 2026-09-22 | Playback engine | 6 of 14 (blocking transport, non-monotonic display clock, seek-back dropout, device-change race, polling producers, HUD) | dcccd1d..a4e2d00 |
| 2026-09-22 | Facade + Swift UI (from the playback review) | 11 (import mid-drag, id reuse after undo, vertical multi-move, snapping, close prompt, redraw split, source monitor, focus) | a450b83..fe4e859 (phase 5b) |
| 2026-09-23 | Phase 7 export (report in history at 2dde40e) | 10 (destroys pre-existing output on cancel/failure, fails on video shorter than container, silent audio on decode error, sandbox URL extension) | phase 7 fix round (working file + atomic replace, videoDuration + end-of-video hold, audio read failures, container re-choose, lows); test gaps 7-9 open |
| 2026-09-23 | Phase 6 effects/transitions UI (report in history at f4a3b7f) | 11 (linked crossfade length, layer-missing flash on seek, preference refresh, status line, and lows) | 7e803a5..d9bb42e |
| 2026-09-23 | Full pass after phase 5b (report removed once fixed; in git history at f5190ea) | 12 new (cross-project id aliasing, coalescing group absorbs edits, bin Delete, dual playback, cache poisoning, keyboard focus) + 4 scaffold; all earlier groups Held or Partially | 4ef9c15..56ed151 (media epochs, coalescing tokens, monitor exclusivity, Distribution signing, LGPL notices, warnings as errors); two test gaps open |
| 2026-09-23 | UX round: engine edit ops, play start, layout, output display, drop delegate (report in history at 95f445d) | 8, none above MEDIUM (VFR pictures by nominal slot start, editing keys in the output window, output window on deactivate / unknown editor display, source lookahead while hidden, battery idle timeout, divider cursor, latency flake, context-menu filtering) + 5 test gaps | 5659075..0753cbe; fix round read by the lead: all eight held, gaps 1-5 closed, no new findings |
| 2026-09-24 | Keyframed Motion, Ken Burns, Photos drops (`2026-09-24-motion-photos-review.md`, kept until fixed) | 26 (keyframe insert reshapes segments, cross-item Live Photo pairing deletes media, Ken Burns preview floods the thumbnail cache and freezes, nudges into undisplayed keyframes, next-tick keyframes a frame late, late placement overwrites, quit ignores arriving media, bookmark survives Save As, and lows) + 5 test-gap groups | open |
