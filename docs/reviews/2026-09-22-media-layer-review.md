# Media layer review (2026-09-22)

Reviewer: Opus 5.5 read-only pass over Engine/Media (interfaces, Apple, FFmpeg, router, FrameCache, DecodePool, AssetImport), Engine/Thumbs, Scripts, and tests at HEAD 6fc6ae4. Finding 3 and the finding 4 cache miss were verified by compiling the FFmpeg decoder/prober/writer/FrameCache into a scratch program that writes a VFR clip as MKV and MOV and seeks.

## Ranked findings

1. HIGH: display rotation dropped between probe and render. AssetImport.mm:67-77 swaps width/height for 90/270 but stores the rotation nowhere (MediaAsset has no rotation field); decoders return storage orientation; only ThumbnailService rotates (ThumbnailService.mm:539). Portrait iPhone clip becomes a 1080x1920 asset drawn sideways. Fix: add rotationDegrees to MediaAsset (serialize), carry on the RenderGraph layer / ScrubFrame, apply in the compositor transform. (Same as render review finding 2.)

2. HIGH: lookahead window not bounded by cache budget and LRU evicts the playhead frame first (DecodePool.mm:524-548; FrameCache.mm:94-107, 218). 4K x420 frame ≈ 24.9 MB → 1 s at 30 fps ≈ 750 MB vs 512 MB budget; 4K 8-bit dissolve (two streams) also ≈ 750 MB. Frames inserted t, t+1, … so LRU evicts slot t first; lost(t) repairs once per seek (repairUsed) then settles with the playhead frame missing; evicted frames inside [t, rangeEnd) never re-decoded. Fix: cap each stream's window in bytes (budget × fraction / (streams × frameBytes)); evict frames behind the playhead or farthest ahead before recent lookahead; re-arm lost() whenever the target moves.

3. HIGH (verified): FFmpeg VFR in Matroska/WebM gets invented durations so seek returns the wrong frame (FFVideoDecoder.mm:402-406, 708-710; FFProber.mm:74-90). Duration set to nominal/fallback, not the real display interval; drop test pts+dur <= target skips the on-screen frame; VFR undetected because FFMuxer's DefaultDuration makes r_frame_rate and avg_frame_rate agree. Run: MKV probe isVFR 0, every dur 0.0333, seek(0.50) → burn-in 30 (should be 2), cache.get(0.50) MISS; MOV correct. Fix: derive duration from the next frame's pts (hold back one frame) or trusted pkt->duration; detect VFR from observed timestamp deltas.

4. MEDIUM-HIGH: FrameCache slot mapping disagrees with the decoder's "frame containing t" rule on VFR/off-grid sources (FrameCache.mm:142-155 Round for keys and lookups, span = round(dur/fd); DecodePool.mm:526, 692; FrameCacheTests.mm:144 locks it in). Jittery VFR leaves slots uncovered; offset sources give different frames cold vs warm. Fix: span = frameIndex(pts+dur) − frameIndex(pts); answer lookups by containment with stored pts/duration and Floor-based query indices.

5. MEDIUM-HIGH: router never asks AVFoundation whether a track is decodable; fallback only on open() failure (BackendRouter.mm:348-364; AppleBackend.mm:44-61 allowlist only; AppleSupport.mm:150-153 loads neither playable nor decodable). AppleVideoDecoder::open never decodes a frame, so VT-rejected profiles (H.264 High 10, 4:4:4 in MP4) fail at first next() after fallback is impossible; DecodePool marks the stream failed with no FFmpeg retry. Fix: load decodable/playable and reject in canHandle; decode one frame in open() or add runtime fallback on first next() error.

6. MEDIUM: hardware use predicted, not measured, and tests are circular. Apple sequential path reports HardwareCaps (AppleVideoDecoder.mm:198, 569); route.hardwareDecode (BackendRouter.mm:384) → MediaAsset.hardwareDecode → UI badge (AssetImport.mm:112); AppleWriter::usesHardwareVideoEncoder (AppleWriter.mm:722-728) predicted. Tests compare against the same HardwareCaps (MediaBackendConformanceTests.mm:679-685, 948-949). Fix: create a VTDecompressionSession from the format description at open() and read UsingHardwareAcceleratedVideoDecoder; writer requires hardware first then retries allowing software; update route/asset from the real decoder.

7. MEDIUM: DecodePool re-target/cancellation claim (DecodePool.h:28-32) fails for real decoders: one next() after a far seek decodes a whole GOP; a close-ahead seek decodes up to 2 s. Latency test uses an instant fake (DecodePoolTests.mm:161-196). Scrub cannot cancel an in-flight preroll. Fix: interrupt flag/deadline checked inside preroll/drop loops.

8. MEDIUM: DecodePool failure state sticks. workerMain only sets failed = true (DecodePool.mm:385-387); invalidate()/registerAsset() during an in-flight failing open leaves the stream failed and setTargets never bumps generation (line 260). AssetSlot::resolve caches probe errors forever (53-72): one transient Timeout breaks lookahead and scrub until invalidate. Fix: failed = openFailed after every step; don't cache Timeout/Cancelled/I/O errors.

9. MEDIUM: no AV1 decode in MKV/WebM on any Mac and no software AV1 (FFmpegSupport.mm:418-423; AppleBackend.mm:66-68 rejects mkv/webm; no dav1d). Fix: --enable-libdav1d. (Same as render review finding 3.)

10. MEDIUM (unverified): lock-order risk in AppleWriter push mode. waitUntilReady reads input.readyForMoreMediaData and writer.status under readyMutex (AppleWriter.mm:224-241); KVO handler on AVFoundation's thread locks the same mutex (463-466). Fix: atomic generation counter; never call AVFoundation under the mutex.

11. MEDIUM-LOW: Opus/Vorbis in MKV/WebM seek only to ~1 ms (up to 48 samples); Interfaces.h:111-113 promises sample accuracy; exception documented only in FFAudioDecoder.h:21-22; no test media. Fix: snap to packet-duration grid, or document in the interface.

12. LOW-MEDIUM: stills have no size clamp (AppleStillImage.mm:136-155; FFStillImage.mm:145-180). maxDimension=0 with a 16000x4000 panorama → 256 MB BGRA IOSurface; > 16384 px fails pool creation. Fix: clamp to Metal texture limit or sequence-derived size.

13. LOW: Apple decoder rare error paths: seek failure leaves stale target (AppleVideoDecoder.mm:646-650); if both startSequential and startRandomAccess fail (681-691) mode stays RandomAccess with nil cursors and next() reports EOS silently; frames that never arrive skipped with no log (436-448).

14. LOW: malformed timestamps can fill unbounded silence into staged (AppleAudioDecoder.mm:159-161; FFAudioDecoder.mm:309-310). Cap gap size.

15. LOW: FFProber.mm:166-169 fails the whole probe (CorruptData) if any stream lacks a duration (crash-truncated OBS MKVs). Skip/flag that track instead.

16. LOW: build-ffmpeg.sh stamp keyed only on version (29, 46); no .asc check; SHA provenance unrecorded. LGPL flags, GPL check, @rpath rewrite, arm64 check are correct.

17. LOW: AppleWriter::finish ends the session at lastVideoPts+fd (AppleWriter.mm:686-689), cutting audio past the last video frame; FFmpeg writer keeps it.

18. LOW: FLAC four-cc 'fLaC' vs CoreAudio 'flac' (MediaTypes.mm:114, AppleBackend.mm:59); ADTS AAC sniffed as mp3 (AppleSupport.mm:470); thumbnail/waveform disk caches and routes_ unbounded; in-memory thumb/waveform caches keyed by asset not file identity; ThumbnailService std::thread workers lack @autoreleasepool.

## Done properly (do not redo)
Result/Status discipline ([[nodiscard]], VE_MEDIA_TRY; no ignored statuses, no unchecked .value()). CFRef/PixelBuffer adopt/retain correct; FFmpeg RAII deleters right; VT and av_buffer release callbacks balance; decoded frames outlive their decoder (tested). Apple random-access decoder: presentation order via cursor, open-GOP/RASL, edit lists, session-loss retry, handover to AVAssetReader, tested with B-frames. FFmpeg hw path: get_format zero-copy passthrough with re-tag, software fallback, exact per-frame hardware flag, hw-vs-sw bit-identity test. FFmpeg seeking: keyframe verification with back-off, open-GOP gate. Audio: resampler phase alignment; priming via edit lists, iTunSMPB, Matroska CodecDelay; sequential-vs-seek test tight enough for 1-sample shifts. FrameCache pin design, releasing dead buffers outside the lock, byte accounting, stress test. DecodePool shutdown ordering and exactly-once scrub callbacks (tested). Disk caches: atomic writes, file-identity keys, header validation, corrupt-file recovery. Deterministic test media cached by script hash; truncation/noise/garbage tests.

## Test gaps
1. VFR media for both backends (MP4; MKV/WebM with and without DefaultDuration): seek into a long frame returns it; every FrameCache slot covered; DecodePool window has no misses.
2. Rotated sources (MP4 preferredTransform, MKV display matrix): probed rotation and end-to-end orientation through MediaAsset and the compositor.
3. Production router with both backends registered (no test does this): MKV → FFmpeg with hardware; MP4 with Opus/VP9 track routed per track by ordinal; a profile that fails to decode falling back to FFmpeg.
4. Cross-backend equivalence on the same file: identical pts and burn-ins; PCM sample-aligned (exact for WAV, zero-lag cross-correlation for AAC).
5. Tighter tolerances: beep onset 1 ms → a few samples (MediaBackendConformanceTests.mm:820, 870, 894); PCM frame count ±1024 → exact.
6. 44.1 kHz source with seeks; 5.1 and mono sources.
7. Hard seek geometry: GOPs > 2 s; leading empty edit (track start > 0); MPEG-TS non-zero start.
8. DecodePool with real 4K frame sizes vs budget; re-target latency with a real decoder after a far seek; failed-flag race; transient probe failure recovery.
9. Hardware-flag checks against VideoToolbox's answer, not HardwareCaps; Apple software decode with random-access seeks.
10. Thumbnail cache: corrupt PNG recovery, mtime change forces re-decode, unicode paths.
11. Huge panorama still with maxDimension=0.
12. Steady-state leak test over DecodePool, FrameCache, ThumbnailService (footprint tests catch only ≥ ~20 KB/frame).
13. Replace wall-clock thresholds (DecodePoolTests.mm:192, 457) that will flake under parallel builds.
14. testTenBitHEVCRoundTripKeepsX420 skips via NSLog; use XCTSkip.
15. AppleWriter: audio longer than video; pull mode with a failing callback (deadlock check).
