# What a Premiere-lite still lacks (research, 2026-10-01, not scheduled)

**Status: research, not scheduled.** Nothing here is agreed. It lists the features professional and
semi-professional editors would expect of a "simple Premiere" that Framewright does not have, says why each
matters, and proposes an order that fits around the work already planned in `docs/plans/README.md` and the
prerequisites in `docs/reviews/2026-10-01-general-code-review.md` (cited below as "review 1.2", "review 2.2" and
so on). Sizes are relative to the rounds so far: **S** a small item in a round, **M** a round's main item, **L** a
whole round, **XL** several rounds. They are estimates from reading the code, not measurements.

## Summary
Framewright plays, scrubs and exports like a professional editor: exact time, synced audio, hardware decode
and encode, monitor and export that match pixel for pixel, a careful Ken Burns and motion editor, and good
transitions. Where it falls short is the everyday editorial toolkit. A working editor sitting down at it would
find no titles, no copy and paste, no markers, no ripple or roll trims and almost no keyboard editing beyond
JKL and split, no audio meters or pan, no autosave, and a media bin with no folders or search. Those are
the things even iMovie, Shotcut, Kdenlive and LumaFusion ship (table below), so their absence makes the app
look like a toy more than any missing high-end feature does.

Most of Tier 1 needs little new architecture: it is app work plus small engine commands
on the existing model. The larger items (titles, captions, audio effects, proxies) land on the same seams the
code review already names for nested sequences and colour grading (non-file sources, project-level edits,
the float pipeline, descriptor tables), so the order below interleaves them with that work instead of adding a
separate track.

## What Framewright has today

| Area | Has | Notably absent |
|---|---|---|
| Timeline | Multi-track video and audio; move, edge trim, split (Cmd+K), delete, ripple delete, link/unlink, snapping, marquee, select all, zoom; track add/remove/rename, mute/solo/lock; target track indicators; undo of every edit | Ripple, roll, slip and slide trims; copy/paste; markers; timeline in/out; lift/extract; nudge; clip enable/disable; per-track sync locks (a preference sets the ripple scope for all tracks) |
| Source and three-point | Source monitor with I/O, Insert and Overwrite at the playhead onto the target tracks (source in, out, record in) | Timeline in/out (four-point, back-timed), replace, fit to fill, match frame, source patching per channel |
| Keyboard | Space, JKL, arrows, Home/End, I/O, Cmd+K, Delete variants, [ ] gain, zoom, Control-K | Previous/next edit (Up/Down), Shift+arrow steps, trim and nudge keys, typed timecode jumps, customisable shortcuts |
| Motion and effects | Position, scale, rotation, opacity; Motion, Fade and Gain spans on effect lanes (start and end values, easing, chained spans); Ken Burns and Transform editors | More than two keyframes per span, crop, blend modes, chroma key, masks, blur and other filters, stabilisation, adjustment layers |
| Transitions | Cross dissolve, wipes, iris, fades to/from black, audio crossfades, asymmetric splits | Push/slide and other common transitions (minor) |
| Speed | Exact constant speed, reverse, Speed/Duration sheet | Freeze frame, speed ramps, frame blending or optical flow |
| Audio | Clip gain, Gain spans, fades and crossfades, track mute/solo, waveforms, an exact mixer | Meters, pan, track volume, mixer panel, EQ, compression, noise reduction, loudness, voice-over, channel mapping |
| Titles and graphics | None | Text, lower thirds, shapes, solid colour mattes |
| Colour | Per-source YUV matrix, BT.709 SDR | Correction, scopes, LUTs, HDR or HLG handling (planned: colour grading) |
| Media | Import of most codecs via AVFoundation or FFmpeg, Photos import, thumbnails, bookmarks, automatic locate on open, "File not found" in the inspector | Bins or folders, list view, metadata columns, search, subclips, manual relink, proxies, collect files |
| Project | JSON with migrations, Save/Save As, recent projects, one sequence, Sequence Settings | Autosave and backups (PLAN.md phase 8 listed autosave; none in the code), multiple sequences, nesting (planned) |
| Captions | None | SRT/VTT, caption track, burn-in, transcription |
| Export | H.264, HEVC 8/10-bit, ProRes 422, AV1; MP4/MOV/MKV; AAC/PCM; quality, size, sharpening; atomic write | Export a range, saved or social presets, audio-only, still frame, queue or background export, XML/EDL/OTIO |
| Monitoring | Program monitor, source monitor, second-display output, playback HUD | Safe-area guides, scopes, audio meters |

### The floor: what light editors ship

| Feature | iMovie | Shotcut | Kdenlive | LumaFusion | Framewright |
|---|---|---|---|---|---|
| Titles | yes | yes | yes | yes | no |
| Copy/paste clips | yes | yes | yes | yes | no |
| Markers | no | yes | yes | yes | no |
| Audio meters | no | yes | yes | yes | no |
| Keyframes beyond start/end | no | yes | yes | yes | spans only |
| Chroma key | yes | yes | yes | yes | no |
| Colour correction | basic | yes | yes | yes | planned |
| Voice-over recording | yes | ? | yes | yes | no |
| Proxies | no | yes | yes | ? | no |
| Subtitles | no | yes | yes | ? | no |

The entries come from the sources below and general knowledge of these apps; "?" means neither settled it.

## The gaps

### Tier 1: expected by any working editor
Each entry: what it is, why editors need it, how others do it, its size, what it needs, and whether it is planned.

**1. Titles and text.** L. Not planned (PLAN.md deferred it).
- *What and why:* a clip that draws text (font, size, colour, outline, drop shadow, background box, position),
  with fades and Motion spans like any clip; a lower-third preset; a solid colour matte from the same machinery.
  Names in interviews, chapter cards, credits: without text, every real project goes through another app.
- *Elsewhere:* Premiere's Type tool and Properties panel with Motion Graphics templates; Final Cut's title
  generators; Resolve's Text+.
- *Needs:* a non-file video source (review 2.2) or a generated-asset kind; Core Text rendered to a texture;
  parameter tables (review 1.2) and forward-compatible saving (review 1.1); a schema bump.

**2. Copy, cut, paste, paste attributes.** M. Not planned.
- *What and why:* Cmd+C/X/V of clips with their spans and transitions at the playhead on the target tracks,
  paste insert, and pasting one clip's motion, opacity, gain or spans onto others. Repeating a shot, reusing a
  graphic, giving twenty clips the same framing.
- *Elsewhere:* Premiere's Cmd+V, Shift+Cmd+V and Option+Cmd+V (Paste Attributes); Final Cut's Paste Attributes.
- *Needs:* fresh ids for pasted content (review 2.4); best built on the edit-command service (review 3.1).

**3. Markers.** M. Not planned.
- *What and why:* named, coloured points or ranges with notes, on the sequence and on clips; M to add, Shift+M
  and Shift+Cmd+M to jump, a list, snapping, export as YouTube chapters. The editor's notebook: client notes,
  music beats to cut on, chapters; review tools such as Frame.io round-trip comments as markers.
- *Elsewhere:* Premiere's Markers panel; Final Cut's to-do and chapter markers; Avid locators.
- *Needs:* model and schema, after the migration freeze (review 1.10); clip markers follow trims and splits as
  spans do.

**4. Trimming: ripple, roll, slip, slide, trim to playhead.** L. Not planned.
- *What and why:* ripple moves an edge and shifts everything after it; roll moves a cut without changing the
  total length; slip changes which part of the source a clip shows; slide moves a clip between its neighbours,
  trimming them. Plus trim to playhead, one- and five-frame keyboard trims, and a view of both sides of the cut.
  Today an edge drag leaves a gap or refuses an overlap. Trimming is where editing time goes; without ripple and
  roll, tightening a cut takes three operations and risks sync.
- *Elsewhere:* Premiere's B, N, Y and U tools, Q/W, Control+T and Option+arrows; Avid's two-monitor trim mode;
  Resolve's trim mode with JKL trimming.
- *Needs:* one owner for the transition and fade rules (review 1.8), since roll and slide move cuts that carry
  transitions; commands through review 3.1.

**5. Timeline in/out, three- and four-point editing, lift, extract, replace.** M. Not planned.
- *What and why:* I/O on the timeline as well as the source, so an insert or overwrite fills whichever three
  points are set (back-timing from an out point); Lift removes a range leaving a gap, Extract closes it; Replace
  swaps a clip for the source keeping its place; Fit to Fill changes speed to fit; deleting a gap; an edit across
  all tracks. The classic keyboard way of building a cut from selects.
- *Elsewhere:* Premiere's comma/period and semicolon/apostrophe; Final Cut's Q, W, E, D and Shift+R; Avid's
  splice, overwrite, lift and extract.
- *Needs:* visible source patching (which source channel goes to which track) over today's target tracks;
  review 3.1.

**6. Keyboard navigation and customisable shortcuts.** M. Not planned (PLAN.md listed the KeyboardShortcuts
package for phase 8; not adopted).
- *What and why:* Up/Down to the previous or next edit, Shift+arrows, typed timecode jumps, nudging clips a frame,
  selecting the clip at the playhead, enabling and disabling clips, match frame; a shortcuts editor with presets.
  Editors keep a hand on the keyboard and bring their keys from other editors.
- *Elsewhere:* Premiere's Keyboard Shortcuts editor; Final Cut's Command Editor.
- *Needs:* the command registry (review 3.5) makes menus, keys and the editor one table; MCP's tool list reads
  the same registry, so the work pays twice.

**7. Audio meters, pan and track volume.** M. Not planned.
- *What and why:* stereo peak meters with a clip indicator; pan per clip and per track; a track fader; a small
  mixer panel. Without meters nobody can tell whether a mix clips or is far too quiet; pan places mono
  recordings.
- *Elsewhere:* Premiere's Audio Meters and Audio Track Mixer; Final Cut's meters and pan modes.
- *Needs:* lock-free meter taps in the mixer (an atomic peak per block); pan as a span parameter (review 1.2);
  track gain in the model and the mixer.

**8. Autosave, backups and crash recovery.** S-M. PLAN.md phase 8 listed autosave; not built.
- *What and why:* a copy every few minutes in a backup folder, the last N kept, offered after a crash. Losing an
  afternoon's work once is enough to abandon an editor.
- *Elsewhere:* Premiere's Auto Save; Final Cut saves continuously; Resolve's Live Save and backups.
- *Needs:* nothing new; the project is a JSON write.

**9. Relink missing media.** S-M. PLAN.md phase 8 listed a relink dialog; only automatic locate exists.
- *What and why:* a list of offline media on open; locating one file finds the rest in its folder by name;
  Replace Footage for a used clip. Projects move between drives and machines.
- *Elsewhere:* Premiere's Link Media; Final Cut's Relink Files.
- *Needs:* the media identity rules (epochs, `forgetProjectMedia`) already describe how to swap an asset's file.

**10. Bins, list view and search.** M. Not planned.
- *What and why:* folders in the media bin, a list view with columns (duration, size, rate, codec), search, sort,
  a "used in sequence" mark. A bin of 300 unsorted thumbnails is unusable; organising selects is half of
  preparing an edit.
- *Elsewhere:* Premiere's Project panel; Final Cut's events, keywords and smart collections; Resolve's bins.
- *Needs:* folders in the project model (schema); app work in `MediaBinView`.

**11. Freeze frame and Export Frame.** S each. Not planned.
- *What and why:* hold the frame at the playhead for a duration; save the frame as a PNG or JPEG. Freeze frames
  are a common device; stills make thumbnails and client stills.
- *Elsewhere:* Premiere's Frame Hold and Export Frame (Shift+E); Final Cut's Add Freeze Frame and Save Current
  Frame.
- *Needs:* Export Frame reuses the compositor's frame render (the MCP plan's `frame_at`). A freeze is one source
  frame held in time: speed zero as a special case, or a generated still (item 1's generated assets).

**Already planned, belongs here:** basic colour correction with a waveform (colour grading slice 1). Every light
editor has exposure, white balance and saturation.

### Tier 2: important for real projects

**12. Nested sequences and several sequences per project.** XL. Planned (item 1). A sequence used as a clip;
also what multicam and "compound clips" build on. Needs review 2.1-2.9.

**13. Colour slice 2 and scopes.** L. Planned (item 2, slice 2): wheels, curves, LUTs, vectorscope, histogram.
LUTs matter early for log footage (many cameras, and iPhone 15 Pro and later, record log).

**14. iPhone HDR (HLG) sources shown correctly.** M. Partly covered by review 1.5 ("which colour tags to
honour"). iPhones record 10-bit HLG by default; the compositor carries the transfer and primaries tags but does
not read them, so HLG is probably drawn as if it were SDR (not checked by hand for this note). A correct tone map
to SDR is the minimum; HDR delivery is Tier 3. Premiere and Final Cut convert HLG, PQ and log through their
colour management. Needs review 1.5-1.7.

**15. Audio effects: EQ, compression and limiting, noise reduction.** L. Not planned. Almost every recording
made outside a studio needs EQ and noise reduction, and music needs a limiter; a "dialogue" preset covers most
uses. Premiere's Essential Sound panel (Enhance Speech, DeNoise, EQ presets), Final Cut's Voice Isolation,
LumaFusion's EQs. Needs an audio source interface (review 2.2) so effects sit between decoder and mixer. Hosting
Apple's built-in Audio Units (N-band EQ, dynamics processor, peak limiter) is the cheap route, provided the
realtime mixer stays lock-free and export renders the same samples.

**16. Loudness metering and normalisation.** M. Not planned. An integrated loudness (LUFS) and true-peak meter,
and "normalise to -14 LUFS" (streaming) or -23 (EBU R128); platforms turn down or reject mixes far from their
target. Premiere's Loudness Meter, Auto-Match and loudness normalisation on export. Needs an offline analysis of
the mix (the export path already mixes offline) and the meters of item 7.

**17. Keyframes beyond start and end.** M-L. Not planned. More than two points in a span (the model allows it),
drawn on the clip and clicked to add points; for audio, the classic rubber band for riding dialogue under music.
Chained spans approximate it today. Premiere's clip keyframes and Effect Controls; Final Cut's animation editors;
Resolve 20's curve view. Needs review 1.2, 1.3 and 1.9.

**18. Voice-over recording.** M. Not planned. Record from a microphone onto an audio track at the playhead, with
a countdown; for narration and scratch tracks. Premiere's record button in the track header, Final Cut's Record
Voiceover, Resolve 20's voice-over tool. Needs an AVAudioEngine input path, the sandbox microphone entitlement
and files written to the project's Media folder; no model change.

**19. Sync by audio, and channel handling.** M. Not planned. Line up a camera clip and a separate recorder's
sound by their waveforms and link them; use a stereo source's left, right or mono sum, or split its channels
(lavalier and camera mic often arrive as the two channels of one file). Premiere's Synchronize and Merge Clips,
Final Cut's Synchronize Clips, Resolve's sync bin. Needs a cross-correlation over the existing waveform peaks,
refined on samples; channel mapping is a clip property the mixer reads.

**20. Crop, blend modes, chroma key.** M together. Not planned. Crop with feather and blend modes (multiply,
screen, overlay, add) are everyday picture-in-picture and graphics tools; a green-screen key is expected even in
iMovie. Premiere's Crop, Ultra Key and opacity blend modes; Final Cut's Crop and Keyer. Needs named uniforms
(review 1.4) and the float working buffer (review 1.6) so blends match on monitors and in export.

**21. Captions and subtitles.** L. Not planned. A caption track; SRT and WebVTT import and export; burn-in or a
subtitle stream; later, transcription that writes the captions. Most social video plays muted, and clients and
accessibility rules require captions. Premiere's captions and Speech to Text, Final Cut 11's Transcribe to
Captions, Kdenlive's Whisper subtitles. Needs item 1's text renderer for burn-in; transcription can use Apple's
on-device SpeechAnalyzer on macOS 26 (an older recogniser on macOS 14-15; quality to check).

**22. Export ranges, presets, audio-only, queue.** M. Not planned. Export the timeline in/out range, saved presets
(YouTube 4K, a 9:16 size, a ProRes master), WAV or AAC alone, several exports queued while editing continues.
Premiere's presets and Media Encoder queue; Final Cut's share destinations and background share. Needs item 5
for the range; background export means revisiting the decode pool shares and "playback waits while an export
runs".

**23. Interchange: FCPXML, OTIO and EDL export.** M each. Not planned. Hands a cut to Resolve for grading, to
Final Cut, or to audio post, and gives users a way out. Premiere writes XML, EDL, AAF and (in beta) OTIO;
Resolve reads all of them; LumaFusion writes FCPXML. PLAN.md kept the JSON close to OTIO's model for this; spans
and transitions map only roughly, so the export must say what it drops.

**24. Proxies.** L. Not planned. Low-resolution copies made in the background, a toggle, originals always used for
export; for 8K, RAW, many layers or network drives. Less urgent on Apple silicon with hardware decode, but
expected. Premiere's ingest settings and Toggle Proxies; Final Cut's and Resolve's proxy and optimised media.
Needs a cache key with the decode format (review 2.5), one routing cache (review 4.5) and a background transcode
job.

**25. Collect files.** S-M. Not planned. Copy the project and its media to one folder (later, only the used parts
with handles) to hand over or archive a job. Premiere's Project Manager; Final Cut's Consolidate Library Media.

**26. Accessibility.** M. Not planned. VoiceOver labels and a navigable timeline, full keyboard operation, Reduce
Motion and Increase Contrast; part of being a credible Mac app. Needs the command registry (review 3.5).

### Tier 3: nice to have, or pro-only

| Feature | What, briefly | Elsewhere | Size | Needs |
|---|---|---|---|---|
| Speed ramps and time remapping | Speed that changes within a clip | Premiere Time Remapping; FCP speed ramps; LumaFusion | L | A speed span kind (review 1.2, 1.9); variable-rate audio in the mixer |
| Optical flow, frame blending | Smooth slow motion from too few frames | Premiere Optical Flow; FCP Smooth Slo-Mo; Resolve Speed Warp | L | Apple's VTFrameProcessor may do the work on recent macOS (to verify); speed ramps first |
| Stabilisation | Remove camera shake | Premiere Warp Stabilizer; FCP Stabilization; iMovie | L | Vision image registration, an analysis pass and a cache |
| Masks | Shapes or tracked regions limiting an effect | Premiere masks with tracking; FCP 11 Magnetic Mask | L-XL | Grading and the float pipeline; the iris shape code is a start |
| Adjustment layers | One effect applied to everything below | Premiere adjustment layer; Resolve adjustment clip | M | Generated clips (item 1) and grading |
| Multicam | Several synced angles, switched live | Premiere multicam; FCP multicam clips; Resolve sync bin | XL | Nested sequences, audio sync (item 19) |
| Auto ducking | Music dips under dialogue automatically | Premiere Essential Sound; LumaFusion | M | Gain spans written from speech detection; item 15 |
| Text-based editing | Edit by deleting words in a transcript | Premiere Text-Based Editing; Resolve | L | Transcription (item 21) |
| Subclips, ratings, keywords | Named ranges and tags in the bin | Premiere subclips; FCP keywords and favourites | M | Bins (item 10) |
| Safe-area guides, overlays | Title and action safe, aspect guides | Premiere and FCP monitor overlays | S | None |
| Shapes and templates | Rectangles, arrows, reusable title designs | Premiere Motion Graphics templates; FCP generators | M-L | Item 1 |
| HDR delivery and colour management | PQ/HLG output, Rec. 2020 projects | Premiere colour management; FCP wide-gamut HDR | L | Item 14, review 1.5-1.7 |
| Background render and smart rendering | Pre-rendered previews; copying unchanged frames on export | Premiere render bar and smart rendering; FCP background render | L-XL | Not needed until effects are heavy |
| Audio Unit plug-ins | Third-party audio effects | FCP, Logic, Resolve on Mac | M | Item 15 |
| MCP server | Driving the app from an AI agent | (no equivalent in the others) | L | Planned (item 3); review 3.1-3.8 |

Also small and useful later: showing and clearing the thumbnail, waveform and proxy caches (S), and browsing
earlier saves once backups exist (S-M, with item 8).

## Recommended order
Each round below is roughly one lead-and-implementers round as the recent ones were. The colour prerequisites
round (review 1.1-1.5) is under way now; the order starts beside it.

1. **Safety and everyday basics** (beside the colour prerequisites; app-heavy, little engine). Autosave and
   backups (8), relink (9), copy and paste (2), markers (3; after the migration freeze, review 1.10), Export Frame
   (11), peak meters (7, meters only), bins with list view and search (10). These carry no architectural risk
   and remove the most visible gaps. Markers and bin folders change the schema, so the migration freeze (review
   1.10) should join the current prerequisites round and land first. If the round is too large, bins and markers
   move to round 3.
2. **Colour slice 1 and the picture tools that share its pipeline.** The rest of the colour prerequisites
   (review 1.6-1.11, including the transition rules owner 1.8), then colour grading slice 1 (planned), HLG
   sources drawn correctly (14), and crop, blend modes and chroma key (20). One shader and uniform rework serves
   all of them.
3. **The editing core, built on the MCP prerequisites.** First review 3.1 (edit commands), 3.2 (edit session),
   3.4 (typed outcomes) and 3.5 (command registry); then trimming (4), timeline in/out with three-point
   editing, lift, extract and replace (5), keyboard navigation and the shortcuts editor (6), freeze frame (11).
   The MCP server (planned item 3) becomes a small follow-on: its tools are these commands and its tool list is
   the registry.
4. **Generated and nested clips.** Review 2.1-2.7, then nested sequences (planned item 1), titles and colour
   mattes (1), captions with SRT/VTT import, export and burn-in (21, without transcription). Titles and nests
   both need "a clip whose pictures are not a file"; building them in one round avoids designing it twice.
5. **Audio.** Pan and track volume with a mixer panel (7), multi-point volume keyframes (17), Audio Unit effects
   for EQ, dynamics and noise reduction (15), loudness metering and normalisation (16), voice-over (18), sync by
   audio and channel handling (19). Needs review 2.2's audio source interface, which round 4 delivers.
6. **Delivery and growth.** Export ranges, presets, audio-only and a queue (22); FCPXML and OTIO export (23);
   collect files (25); colour slice 2 with scopes (13); transcription for captions (21); proxies (24) if users
   report heavy footage. Accessibility (26) is best done alongside round 3 and checked again here.

**Deferred or skipped on purpose, for a lite product:** collaboration and shared projects, video plug-in hosting,
AAF/OMF, background render and smart rendering (real-time GPU playback makes them unnecessary until effects get
heavy), generative AI features, multicam (revisit after nested sequences and audio sync), and HDR delivery. Speed
ramps, optical flow, stabilisation and masks are worth doing eventually but each is a round of its own with
little effect on whether the app feels complete.

**Uncertainties.** The tiers reflect what the cited editors and guides emphasise and the author's reading of
common workflows, not a survey of users. The HLG behaviour (14), the macOS 14 transcription quality (21) and the
availability of Apple's frame-processing API (for optical flow) need checking before they are
planned. Sizes assume the review prerequisites are done first; without them, items 1, 15 and 21 each grow by
about a size.

## Sources
- Premiere Pro: Larry Jordan, "Five hidden keyboard shortcuts to faster trimming" (larryjordan.com); ProVideo
  Coalition, "New ripple trim behavior in Premiere 26"; Adobe, "Automatic audio ducking" (adobe.com/learn); Adobe
  blog, "New AI-powered features and workflow enhancements in Premiere Pro" (25.2, 2025); Adobe community, "Now in
  beta: OTIO import and export"; Frame.io workflow guide, "Premiere Pro proxies".
- Premiere Rush end of life (September 2025, replaced by Premiere on iPhone): helpx.adobe.com/premiere-rush/kb/end-of-life.
- Final Cut Pro: Frame.io blog, "How the magnetic timeline keeps you focused on the story"; Newsshooter, "Final
  Cut Pro 11 features Magnetic Mask, Transcribe to Captions".
- DaVinci Resolve: Blackmagic Design, Cut page (source tape, sync bin); Newsshooter, "DaVinci Resolve 20 final
  release".
- Avid Media Composer: LinkedIn Learning, "Media Composer Essential Training" (sync locks, patching, lift and
  extract, match frame).
- LumaFusion App Store listing; docs.kdenlive.org, "What's new"; TechRadar, Shotcut review; addpipe.com, "A quick
  look at Apple's SpeechAnalyzer API".
- Framewright: `README.md`, `PLAN.md`, `docs/plans/`, `docs/reviews/2026-10-01-general-code-review.md`,
  `Engine/Facade/VEEngine.h`, `Engine/Facade/VEExport.h`, `App/FramewrightApp.swift`,
  `App/State/KeyboardController.swift`.
