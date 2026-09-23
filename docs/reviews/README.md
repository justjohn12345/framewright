# Reviews

Adversarial read-only reviews are run after each implementation phase; findings are fixed in a follow-up round.

- `open-findings.md`: findings not yet fixed. The next fix round works from this file.
- `integration-notes.md`: API changes other layers must adopt, collected from the fix agents.

History (full reports are in git history under `docs/reviews/2026-09-22-*-review.md`, removed once fixed):

| Date | Scope | Findings | Fixed in |
|---|---|---|---|
| 2026-09-22 | Model, edit, undo, JSON, scheduler | 15 (exact time math, slow-motion flash frame, dissolve mix, linked-pair ripple, locked tracks, undo depth, fades/transitions, JSON v2) | 5671f68..f8e1d1e |
| 2026-09-22 | Render, preview view, scaffold | 14 (collapse blackout, rotation, minification, straight alpha, ring-slot desync, drawable under lock, chroma siting, 10-bit drawable) | 913fc78..4a0d1ba; scaffold items still open |
| 2026-09-22 | Media backends, router, cache, pool, thumbs | 18 (VFR durations, cache slot mapping, budgeted windows, decodability routing, measured hardware flags, interruptible decode, dav1d AV1) | e595d1f, ca41f40, 9d72a84 |
| 2026-09-22 | Playback engine | 6 of 14 (blocking transport, non-monotonic display clock, seek-back dropout, device-change race, polling producers, HUD) | d46c2c5..5325cd9; facade/UI items still open |
