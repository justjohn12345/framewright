# Plans

`PLAN.md` at the repository root is the original master plan (phases 0 to 8, all done). Everything after it is
planned here, one file per plan, named `<date>-<topic>.md`; a completed plan is renamed `<date>-<topic>-done.md`
and keeps a status line at its top saying what landed and where the deviations are recorded.

## Plans

| Plan | Status |
|---|---|
| `2026-09-24-effect-lanes-done.md` | Done. Spans on lanes, transitions on lane 0, hold after, schema v5; reviewed and fixed (see `docs/reviews`). D1 compact rows and D3 window frame restore remain open. |
| `2026-09-29-export-sharpness-done.md` | Done. Export quality High by default with the custom entry and the fine-text note; sequences adopt their first video clip, Sequence Settings sheet (schema 7); sharpening after the minification pre-scale, exports pre-scaled to the drawn size. Deviations in `docs/reviews/integration-notes.md`. |
| `2026-09-29-mcp-server.md` | Proposed, not scheduled: driving the app from an AI agent over MCP. |
| `2026-10-01-premiere-lite-feature-gap.md` | Research, not scheduled: the features working editors expect that Framewright lacks, in three tiers, with a proposed order of rounds around the planned work. |
| `2026-09-27-reverse-speed-wipes-done.md` | Done. Reverse (schema 6), speed in the inspector, wipe and iris transitions; reviewed 2026-09-29 (the post-lanes review; the report is in git history at f486a6a, removed in 50ac8f2), every finding fixed in 47b1a45..eb4d3d5 except the test gaps listed in `docs/reviews/open-findings.md`. |

Rounds that had no plan file (they were briefs to one implementer, recorded in `docs/reviews/integration-notes.md`):
the Ken Burns editor on placement boxes, the Ken Burns | Transform modes with the solo preview, the frame-box
constraint, the hands-on round of 2026-09-27 (Unlink selection, Continue on Next Clip, the selection style, the
exposure-integrated transition edges) and the iris fades on black.

## Planned (not yet scheduled, in the intended order)

0. **D1 compact rows** and **D3 window frame restore**: design items from the effect lanes review, specified in
   `docs/reviews/open-findings.md`.
1. **Nested sequences** (asked 2026-09-29): a sequence used as a clip in another sequence, live (an edit inside
   the nest shows in the parent; nothing is exported), trimmed, sped up, transitioned, stacked and given spans
   like any clip. Engine: a clip whose asset is a sequence; the scheduler renders the nested sequence's frame at
   the mapped time as one layer (the solo-preview path already renders "a sequence, but different" into the
   monitor) and the mixer its sound; a cycle is refused. Model: the project's sequences array in use, a
   sequence-typed asset in the bin, "Nest" on a selection (replaces the selected clips with a new sequence and a
   clip of it, one undo step) and "Open Nested Sequence". Across projects: File > Import Sequences from a
   Framewright project (its sequences and media references come in as bin items).
2. **Colour correction and grading** (asked 2026-09-29). Slice 1 done 2026-10-02 (exposure, contrast,
   temperature, tint and saturation as a property of the clip, per the approved decision
   `docs/reviews/2026-10-01-grading-pipeline-decision.md` section 7, and the luma waveform; history table in
   `docs/reviews/README.md`, status notes in `docs/reviews/open-findings.md` at 400ded1). The original sketch,
   superseded for the base grade by that decision: a Colour span kind on the effect lanes with start and end values, applied per clip in the fragment shader after the source conversion (the per-source colour matrix)
   and before compositing, in a linear-light working space so 8-bit and 10-bit sources grade alike and export
   stays identical to the monitor (the parity tests enforce it). Slice 1: exposure, contrast, temperature, tint,
   saturation, and a waveform scope (a compute pass over the composited frame, drawn in a panel). Slice 2: lift /
   gamma / gain colour wheels, luma and per-channel curves, a hue-versus-saturation secondary, LUT files (.cube)
   as an input conversion or a look, plus vectorscope and histogram. Inspector rows and a live editor on the
   program monitor as the Ken Burns editor is; the audio side is untouched.
3. **MCP server** (asked 2026-09-29; plan written, `2026-09-29-mcp-server.md`): the app hosts a Model Context
   Protocol server on a Unix socket in its container, with a bundled stdio shim so any MCP client can attach; the
   facade's edits, frame reads (PNG), transport and export as tools, every call one undo step with named batches,
   off by default with a Preferences switch and a status-line indicator.
4. **Per-project Ken Burns mode memory** (the mode is remembered per session today).
5. **Notarization** once a Developer ID identity exists (the Distribution configuration is ready for it).

What editors would expect beyond this list (titles, copy and paste, markers, trimming, audio meters, autosave and
more), tiered and interleaved with items 1-3, is in `2026-10-01-premiere-lite-feature-gap.md` (research, not scheduled).

A plan file is written when a feature is scheduled, agreed with the user, and then handed to an implementer.
