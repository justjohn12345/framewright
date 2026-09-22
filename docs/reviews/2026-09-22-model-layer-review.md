# Model layer review (2026-09-22)

Reviewer: Opus 5.5 read-only pass over Engine/Model, Engine/Edit, Engine/Serialize, Scheduler at HEAD 06d740b.
Verified with standalone doctest probes (clang++ -std=c++20, CoreMedia). All findings below were reproduced.

## Ranked findings

1. HIGH: time math not exact. `TimeUtil.h:22-27` global +/- use CMTimeAdd/CMTimeSubtract; when the common timescale exceeds 2^31-1 CoreMedia rounds to 1e-9 and sets HasBeenRounded. Affects Clip.cpp:29,33, EditOps.cpp:123,768,776, setTimelineStartKeepingEnd/setTimelineEnd. Repro: 29.97 sequence, 44.1 kHz asset, in point 44101/44100, speed 0.999 → InsertClip gives rounded sourceOut; 24/72 SplitClip points refused as InvariantViolation ("not on the sequence frame grid"); fuzz on 1001/30000 grid with 44.1 kHz in points and speeds {0.123,0.37,0.999} over 40 seeds: 196 refused edits, 6957 states with rounded source times, 1 ns false overlaps. Fix: exact Int128 add/sub helpers (like scaleTime) used in Clip/EditOps; make timeline duration (whole sequence frames) authoritative and derive sourceOut; validateClip rejects kCMTimeFlags_HasBeenRounded; keep the NTSC/44.1k fuzz as a permanent test.

2. HIGH: Scheduler shows frames outside the clip at slow speed. `Scheduler.mm:54` snaps source time with SnapMode::Round. Clip source [0,30) frames at 0.5x → timeline frame 59 maps to source frame 30 == sourceOut (flash frame past the edit). SchedulerTests.cpp:142-144 locks this in. Fix: SnapMode::Floor; clamp inside the clip body to the last frame starting before sourceOut; only transition handles may go past.

3. MEDIUM-HIGH: dissolve mix sampled at frame start, off by one. `Scheduler.mm:89` mix = fractionThrough(range, t) → frame k of n gets k/n; first frame 100% outgoing, incoming never reaches 1; 1-frame dissolve renders outgoing at 1.0 with source exactly at A's exclusive out point. Video runs half a frame behind the audio crossfade. Fix: mix = (k+0.5)/n; update SchedulerTests.cpp:91,112.

4. MEDIUM-HIGH: Insert, speed-ripple and single-track RippleDelete desync linked pairs downstream. InsertClip::perform (EditOps.cpp:374-384) shifts only target tracks; SetClipSpeed ripple (:790) only own track; RippleDelete defaults allTracks=false. Repro: insert video-only clip on V1 at frame 10 → next A/V pair video at 80, audio at 60. Fix: "all unlocked tracks" mode for Insert (default on) and speed ripple: split clips spanning `at` on other tracks and shift them; at minimum carry linked partners along.

5. MEDIUM: locked-track contract violated by normalizeSequence (EditPrimitives.cpp:149-164) clearing links on locked tracks. Repro: A/V pair with A1 locked; OverwriteClip on V1 covering the video → succeeds and clears A1 clip's linkedClipId. Same for RemoveClips(includeLinked=false) and RemoveTrack. Fix: in SequenceCommand::apply, after normalize, refuse if the diff touches a locked track (except SetTrackFlags).

6. MEDIUM: UndoStack::setMaxDepth with a redo tail corrupts history (UndoStack.cpp:67-73): erases applied commands from the front, keeps redo, sets index_=0; redo then applies a patch onto the wrong base; applyPatch pool.at() (Command.cpp:98) can throw. Fix: drop redo commands first (from the back); evict only applied commands from the front; applyPatch verifies current tracks equal snapshot.before and redo fails cleanly otherwise.

7. MEDIUM: split/insert/overwrite silently lose transitions and fade continuity. SplitClip inside a tail transition [50,70) at 55 succeeds and the transition is dropped by normalizeSequence. Split of a 300-frame clip with 90-frame fade-in at 30 leaves fadeIn=90 on a 30-frame piece (audio ramps 0→0.333 then jumps to 1.0), validateProject says ok. Overlapping fades (20 in + 20 out on 30 frames): segment [10,20) reported 0.5→0.5 but true product peaks at 0.5625, contradicting RenderGraph.h:72 "every ramp is exactly linear". normalizeSequence dropping invalid transitions means validateSequence's transition checks can never fire for edits. Fix: refuse split inside a transition range (or explicit option); clamp fades to piece length on split/trim; validateClip enforces fadeIn ≤ duration, fadeOut ≤ duration, fadeIn+fadeOut ≤ duration; report dropped transitions in EditResult.

8. MEDIUM: no-op commands recorded. MoveClip with delta 0 returns success with empty patch (EditOps.cpp:468); UndoStack::push never checks patch.isEmpty() → undoCount=1, dirty=true; a drag returning to start leaves an undo step. Fix: drop empty patches in both push paths; in ReplacePrevious mode revert and pop the group when the composed patch is empty.

9. LOW-MEDIUM: failed redo leaves stale clean index (UndoStack.cpp:101-105). After two new pushes isDirty()==false though content differs. Fix: reset cleanIndex_ when > index_.

10. LOW-MEDIUM: epoch and rounded flags accepted in model times (ProjectJSON.cpp:242-244 accepts "epoch"); CMTimeCompare orders by epoch first so an overlapping clip with epoch 1 loads fine. Fix: require epoch==0 and no rounded flag for all model times.

11. LOW: audio crossfade docs stale. Transition.h:18 "audio linear crossfade", RenderGraph.h:73 gain·fade·crossfade; AudioMixer applies sin(c·π/2). Fix: document crossfade as a parameter or add a curve enum to AudioSegment.

12. LOW: JSON. serializeProject can throw nlohmann type_error 316 on invalid UTF-8 (also VEEngine.mm:560 json.dump(2)) → use error_handler_t::replace. No migration hooks (only version 1 accepted). Unknown enum value rejects the whole file. Invalid CMTime with non-zero fields round-trips as kCMTimeInvalid. No golden-file test.

13. LOW: TimeUtil nits. Unary minus (TimeUtil.h:28-30) drops flags/epoch and is UB for INT64_MIN. Possible Int128 overflow in scaleTime (value*kPreciseTimescale, 2*n in roundDivAwayFromZero) and approximateRatio p2 for large inputs (unreachable today). Analyzer warning TimeUtil.cpp:44 is a false positive (d ≥ 1 by construction); add assert(d > 0).

14. LOW: speed stored as double; applied speed is approximateRatio(speed,1000) (0.3337 → 303/908); SetClipSpeed rounds length with Round (EditOps.cpp:767) and can extend sourceOut past the out point while InsertClip uses Floor. Fix: store a Ratio; use Floor.

15. LOW: validation gaps: asset width/height/sampleRate/channels unchecked per kind; non-VFR video asset may have non-numeric frameDuration; empty URL accepted.

## Done properly (do not redo)
Int128 frame-grid math with correct floor/ceil/round for negatives, tested at 23.976/29.97/30/60. SequenceCommand edits a working copy then normalize/validate/diff; refused edits are bit-identical no-ops; patches restore tracks, order, transitions, IdGenerator; redo recreates identical ids. Undo/redo bit-exact under 40-seed NTSC fuzz. composePatches correct; ReplacePrevious restores last good state on refusal; clean index invalidated on branch/trim. Partner's locked track honoured by Move/Trim/Split/Remove/Speed. Transition validation checks handles both sides, centring, neighbour overlap. JSON loading never throws, reports errors by path, range-checks ints, keeps flags/epoch/nextId, validates after load.

## Test gaps
1. Edit ops on 29.97 and 23.976 grids; NTSC + 44.1 kHz + speed-denominator-1000 fuzz with many seeds (permanent).
2. Scheduler: last frame at 0.5x and 0.4x stays inside sourceOut; 1-, 2-, 3-frame dissolves; transition on muted/solo track; overlapping fades; fades longer than clip after split.
3. Overwrite/Insert inside a clip with a tail transition; Split inside a transition range; Split with fades longer than the piece.
4. Locked partner track with RemoveClips(includeLinked=false), Overwrite, RemoveTrack: track unchanged or edit refused.
5. UndoStack: setMaxDepth with redo tail; Accumulate then cancel; group whose first push is refused; no-op/return-to-start drag; redo failure then dirty state; markClean mid-drag then cancel.
6. validateProject negatives: negative start/sourceIn; still with speed≠1 or sourceIn≠0; non-finite video params or negative fades; link to self/same track; transition not adjacent/too long/bad duration/duplicate on a cut; non-positive frame duration or zero size; non-positive asset durations; track in wrong list; duplicate clip id; epoch/rounded flags.
7. JSON: checked-in golden v1 file; epoch/rounded rejection; invalid UTF-8 on save; transition referencing a missing clip.
8. TimeUtil extremes (INT64_MAX value, kCMTimeMaxTimescale); flags/epoch on unary minus.
9. Revise tests that lock in wrong behaviour: SchedulerTests.cpp:142-144 (round-up tie), :91 and :112 (mix 0 on first frame), :294-298 (linear sum as proxy for constant power).
