# The demo: Framewright cutting its own demo

A screen recording of Framewright building this video, with a narrator, assembled and exported in
Framewright. About two and a quarter minutes.

Files here:
- `segments.json`: the script. Ten segments, each with the narration line, the on-screen action, and the
  slot length in seconds (the narration's length plus two seconds of room). Edit the words here.
- `tts.py`: generates the narration with Gemini text-to-speech (`gemini-3.1-flash-tts-preview`, voice
  Charon), one WAV per segment into `~/Movies/Framewright Demo/narration/`. Needs `GEMINI_API_KEY`.
  `--only <id>` regenerates one line after a script change.
- `record.sh`: the take. A teleprompter prints each segment's action and plays its narration while
  `screencapture` records the display; writes `take-<time>.mov` and `take-<time>.txt` (each segment's start
  time in the recording) to `~/Movies/Framewright Demo/`. `--rehearse` runs it without recording.

Media: the Sintel clips and stills in `~/Movies/Framewright Demo/clips` and `stills` (Blender Foundation,
CC BY 3.0; credit "Sintel, Blender Foundation" in the video description). Nothing under `~/Movies` is in
the repository.

## Making it

1. **Narration**: `docs/demo/tts.py`. Listen to each WAV once; regenerate any line that reads oddly.
2. **Set the stage**: display at 1920×1080 or a 16:9 scaled resolution (System Settings > Displays) so the
   recording is clean at 1080p. Framewright open with an empty untitled project, the window filling the
   display. A Finder window on `clips` and `stills` positioned so you can drag from it. The browser on
   the GitHub README behind everything. Quit other apps. Turn off notifications (Focus).
3. **Rehearse**: `docs/demo/record.sh --rehearse`. Do each action as its line plays; you have the slot
   length. If an action does not fit, lengthen its `seconds` in `segments.json` (the narration still
   starts at the segment's start; the extra time is silence for the action).
4. **Record**: `docs/demo/record.sh`. macOS asks for Screen Recording permission for Terminal the first
   time; grant it and run again. Do the actions as rehearsed. The recording stops on its own 5 s after the
   last segment.
5. **Assemble in Framewright** (a new project, 1080p30): import `take-<time>.mov` and the ten narration
   WAVs. The recording on V1 from 0. Each narration WAV on A1 at the start time in `take-<time>.txt`
   (the file has `id<TAB>seconds`). Trim the head of the recording to the first segment's start and the
   tail after the export progress bar completes. A one-second fade in and out on V1, a Gain span on A1
   if the room tone needs it. Optional: a title still for the first second.
6. **Export**: File > Export, H.264 1080p, quality high, to `~/Movies/Framewright Demo/Framewright-demo.mp4`.
   The exported file is the demo; it was made in the editor it demonstrates.
7. **Publish**: the README's Download section and the release page get the video (upload to YouTube,
   unlisted is fine, and embed the link; a GIF of the first 10 s in the README if you want motion there).
