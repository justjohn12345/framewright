# Export sharpness for high-resolution sources (plan, 2026-09-29, agreed in outline)

## Why
The user cut a demo from 3832x2154 macOS screen recordings and the 1080p export's text was soft. Measured
(the lead, 2026-09-29, same frame from the source and the export, the Effects panel cropped and compared):

- Every new project's sequence is hard-coded to 1920x1080 at 30 fps (`Engine/Facade/VEEngine.mm`,
  `project.addSequence("Sequence 1", CMTimeMake(1, 30), 1920, 1080, 2, 2)`). There is no Sequence Settings UI
  and no "match the first clip" logic, although PLAN.md promised it. A retina recording loses half its text
  resolution before the encoder runs.
- The compositor's downscale is not the problem: sources below 0.75 output pixels per texel get a Lanczos
  pre-scale (`MPSImageLanczosScale`, `kMinifyThreshold` in `Engine/Render/Compositor.mm`) and are sampled at ~1:1.
- The hardware H.264 encoder at the default quality 0.7 blurs fine text; at 0.95 it is nearly transparent. The
  same downscaled frame encoded outside the app at 0.7 looked like the export; at 0.95 like the downscale.
- The export sheet's Quality picker shows blank because the default 0.7 is not one of its choices (0.95, 0.8,
  0.65, 0.45; `ExportModel.qualityChoices` in `App/Views/Export/ExportSheet.swift`); the user cannot see what
  quality is in effect.
- ffmpeg `scale=1920:1080:flags=lanczos,unsharp=5:5:0.6` on the same six seconds was clearly crisper than a plain
  Lanczos downscale at any encoder setting (edge measure 0.022 against 0.011-0.015); the sharpen, not the x264
  encoder, made the difference (plain Lanczos + x264 crf 16 looked like the hardware encoder at 0.95).

## Items
1. **Sharpen after downscale.** In the compositor's minification path, after the Lanczos pre-scale, an unsharp
   mask (amount about 0.5, radius about 2 output pixels, threshold small enough to leave flat areas alone),
   applied only to sources that were minified. The monitor and the export share the path so parity holds
   (`ExportParityTests`). A per-project setting (Sequence Settings, item 2) "Sharpen scaled-down sources", default
   on; the export sheet shows the setting. Off for sources that are not minified. Tests: a synthetic text card
   at 2x downscaled with and without the sharpen (edge measure up, no ringing beyond a bound, flat areas
   unchanged to 1/255), parity, and the redraw budget unchanged.
2. **Sequence settings.** New sequences adopt the first imported clip's size and frame rate (PLAN.md's promise;
   stills and audio do not count; a VFR source uses its nominal rate rounded to a standard one); a Sequence
   Settings sheet (Sequence menu) edits size, frame rate and audio sample rate with a confirmation naming what
   changes for existing clips (placements are in sequence pixels: scale them with the size so the picture
   stays the same; transitions and spans keep their frame counts on a frame-rate change, or the sheet says
   what moves). Export "Resolution: Sequence size" then gives 4K from a 4K timeline; add "Source size" only
   if it is cheap. Tests: adoption rules, the sheet's rewrite of placements, JSON round trip, export at 4K
   parity.
3. **Export quality.** Default High (0.8); the picker always shows a choice (a value not in the list shows as
   "Custom n %"); the sheet notes "Maximum keeps fine text sharp" when the sequence holds a source larger
   than the output. `bitsPerPixel` estimates re-checked at 0.8.

## Order
Item 3 (small), then 2, then 1. One implementer round; the lead verifies with the demo project's export
(the same crop comparison as above, expected: the 1080p export of a 4K sequence with the sharpen reads like the
ffmpeg reference).

## Also queued from the same session (not part of this plan)
- Re-export the demo (`~/Movies/Framewright Demo/demo1.framewright`) at Maximum quality for the upload; the
  YouTube description is in `docs/demo/youtube-description.md`; the README's Download section gets the link
  and a poster frame (a candidate at 100 s, the speed sheet over the timeline).
- The paused-seek fix landed (729fcbd..537b69a): by-hand check in the demo project still owed by the user.
- Open findings unchanged: D1 compact rows, D3 window frame restore, J-from-pause late frames, per-project
  Ken Burns mode memory. The MCP server plan (`2026-09-29-mcp-server.md`) is proposed, not scheduled.
