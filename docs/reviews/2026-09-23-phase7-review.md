# Phase 7 (export) review (2026-09-23)

Reviewer: Opus 5.5 read-only pass over the phase 7 commits (ExportJob, OfflineAudioRenderer, media writer changes, facade
export API, Export sheet, tests) at the phase 7 tip (rename commit 79e6cf9 in the rewritten history). Verified in a
scratch extraction with probe tests; three defects reproduced; TSan run on the cancel, memory-pressure, H.264, AV1/MKV and
facade paths with 0 warnings; every phase 7 test class passes with nothing skipped on this machine.

## 1. Summary
The export path is mostly sound: it uses the same `Scheduler::renderGraphAt`, `playback::frameSlotFor`, compositor and
`AudioMixer` code as playback; cancel is prompt, progress is paced, refusals happen before writing. Three reproduced
defects: a cancelled or failed export destroys a file the user chose to replace; an export fails whenever a video track is
shorter than its container duration; an audio decode error mid-stream is written as silence and reported as success. The
sheet also rewrites the save-panel URL's extension, which breaks under the sandbox (inferred from code).

## 2. Ranked findings

1. HIGH (verified, probe P1): a cancelled or failed export deletes the user's existing file. `AppleWriter.mm:513-518`
   removes the existing output in `open()` before any frame is written; `ExportJob.mm:364,381,389,394` `removeFile(path)`
   on every failure or cancel; the FFmpeg path truncates via `avio_open`. No temp file, no atomic replace. Scenario:
   re-export over `final.mp4`, confirm Replace, press Cancel (or the export fails, or the disk fills): old and new file
   both gone. Probe: `cancelled=1, pre-existing file still exists: 0`. Fix: render into a temp URL from
   `URLForDirectory:NSItemReplacementDirectory…appropriateForURL:outputURL` (same volume, sandbox-allowed); on success
   `replaceItemAtURL:withItemAtURL:`; on cancel/failure delete only the temp; `AppleWriter::open` must not delete the
   destination; `bytesWritten` stats the temp file. Tests: old file intact after cancel and after a forced failure,
   replaced after success, both writer backends.

2. HIGH (verified, probe P2): export fails when a video track ends before the asset's container duration.
   `AssetImport.mm:96-109` sets `asset.duration` to the container duration (longest track, usually audio);
   `Validation.cpp:81` lets a clip run to it; at EOF the pool settles with no picture and `ExportJob.mm:257-262` refreshes
   twice then fails. Scenario: screen recordings / files trimmed elsewhere whose audio runs past the video, used full
   length: the monitor plays with the layer missing at the tail, the export aborts at the tail frame. Probe:
   `validateProject: valid`, then `DecodeFailed: Frame 60 (2.000 s) cannot be exported: … no picture at source time
   2.000 s`. Fix (either or both): DecodePool extends the last frame's cache coverage to +infinity at EOF (playback and
   export hold the last frame); or record the video track duration on `MediaAsset` at import and clamp video clips to it
   in validation and edit ops. Add an `eof` flag to `StreamStats` so `waitForPicture` can say "the media's video ends at X".

3. MEDIUM (verified, probe P3): an audio decode/seek error mid-stream is exported as silence and reported as success.
   `ClipAudioSource.mm:283-298` `readSource` only sets `error_` and fills silence; `failed_` is set only in `openDecoder`
   (241); `AudioMixer::failedSourceIn` (466) checks only `st.failed`. Contradicts the header and integration notes. Probe:
   fake with `failAudioAtSample = 24000` → `ok=1`. Fix: record a read failure (flag + sequence sample) in
   `ClipAudioSource::Stats`; `failedSourceIn` reports it for ranges at or after that sample; playback may keep playing
   silence; add the P3 test.

4. MEDIUM (inferred): changing the container rewrites the chosen file's extension (`ExportSheet.swift:329-335`
   `updateOutputExtension`; `testFolderBookmarkRoundTrip` asserts it). The save panel grants sandbox access only to the
   exact URL chosen and Info.plist has no `NSIsRelatedItemType`: sandboxed, `checkWritable`/the writer is refused with
   "Operation not permitted"; unsandboxed, an existing `movie.mov` is silently deleted without the Replace prompt. Fix: on a
   container change clear `outputURL` (or re-open the panel), or let the panel accept all types and derive the container
   from the chosen extension; update the test.

5. LOW: overwrite protection covers only assets on exported tracks (`ExportJob.mm:477-509` skips inactive tracks and
   audio tracks when audio is None). Compare the output against every `project.assets` path.

6. LOW: unreadable media reported as an unwritable output (`ExportJob.mm:499-501` returns `PermissionDenied`, mapped to
   `VEEngineErrorOutputNotWritable` at `VEEngine.mm:2759`). Use `FileNotFound` / map to `MissingMedia`.

7. LOW: cancel not honoured during `finish()` (`ExportJob.mm:387-396`; AppleWriter's MP4 network-optimise rewrite can be
   long); `DocumentController.confirmStoppingExport` waits only 2 s then lets the app quit, leaving a partial file. Fix:
   check cancel around `finish()`, bound the quit wait; the temp-file fix removes the partial-file risk.

8. LOW: the facade does not refuse `play` during an export (`beginExport` pauses at `VEEngine.mm:2768` but nothing stops a
   restart; monitors then compete for decoders/GPU). Refuse `play` while `isExporting` or disable transport.

9. LOW (not verified): two refreshes per frame (`ExportJob.mm:259`) may fail under repeated critical memory purges between
   a decode and `acquire`. Count refreshes only when the pool made no progress, or allow more under pressure.

10. LOW: the memory test is weak: 300 frames at 233 fps last 1.3 s (~13 samples; `baseline 1006.5 MB, peak 1006.6 MB`);
    says nothing about a multi-minute or 4K export.

## 3. Done properly (do not redo)
Shared picture path with the program monitor (`renderGraphAt` at `timeForFrame(index)`, `frameSlotFor`); a missing,
undecodable or skipped layer fails the export with a clear message, never drawn black; stills registered. Offline audio
is a private `AudioMixer`: probe P5 (speed 3/2, fade, crossfade) one plan vs replan every 0.15 s max |diff| 2.98e-07 over
240000 frames; unit-speed region vs decoded source 6.71e-08. One-frame sequences export correctly (P7). Cancel completion
67.5 ms; new file removed; progress ≤ 10 Hz, coalesced, never after completion, on main. TSan clean on the racy paths.
Media: 10-bit x420/xf20 targets with whole-code quantisation; HEVC Main10 via AVAssetWriter; `encoderAvailability` per
size with the hardware flag matching VideoToolbox; AV1 via SVT-AV1 with colour tags; AAC end trimming (MP4 audio within 1
sample) and MKV DiscardPadding; early-stream flush in `runPull`. Facade: Busy/invalid/empty/missing/unwritable refusals
with no file created; monitors pause; New/Open cancels; close/quit ask. All phase 7 test classes pass with nothing skipped.

## 4. Test gaps
1. Export vs monitor pixels: composite a frame through the `PlaybackController` frame source and through `ExportJob` and
   compare, including a rotated incoming clip in a transition, a still with alpha, letterboxing.
2. Audio vs the playback mixer sample by sample (P5 style): constant-power crossfade, speed ≠ 1, multi-track sum, clipping.
3. VFR export on `vfr_h264_*` media with burn-in checks.
4. Regression tests for P1 (both writers: success, cancel, forced failure), P2, P3.
5. MKV beep alignment within 1 ms (`fullAudio:NO` currently skips it).
6. Writer failure mid-file (disk-full image or a fake writer returning `WriteFailed`): error text, no file left.
7. Sandbox-hosted test of choosing a file, switching the container, exporting.
8. Size estimate vs a real export's size in quality mode.
9. Long export memory (≥ 2 min at 4K).
10. Make encoder XCTSkips visible (fail on configurations expected to have HEVC 10-bit, ProRes, AV1).
11. Audio-only sequences (black video) and sequences with no audio (silent track written).

## 5. Deviations
| Deviation | Acceptable? |
|---|---|
| ProRes 422 fed 8-bit BGRA from the RGBA16F compositor (10-bit sources lose precision) | Yes for now; phase 8 |
| No WebM (LGPL build has only experimental Opus/Vorbis encoders) | Yes |
| FFmpeg VideoToolbox H.264/HEVC export path unused (router prefers the Apple writer; FFmpeg writes AV1 and MKV) | Yes |
| 10-bit AV1 exists in the engine but the facade never offers it | Yes; not called out |
| Whole-sequence export only (no in/out range); audio fixed at 48 kHz stereo | Yes for PLAN scope; note for later |
| No temp-file/atomic replace (finding 1); "failed audio source becomes an error" holds only for open failures (finding 3) | No: fix both |
