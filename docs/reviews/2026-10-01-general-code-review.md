# General code review, 2026-10-01

## Scope and method
The whole repository at 80e2aff (0.1.7), about 128,000 lines. Five read-only reviewers each took one area:

| Area | Size |
|---|---|
| Engine/Model, Edit, Serialize | 13k |
| Engine/Media, Thumbs, Audio | 21k |
| Engine/Render, Playback, Export, Facade | 18k |
| App | 16.5k |
| EngineTests, AppTests, build and docs | 60k plus tooling |

They read the large files in full and looked for bad design decisions, poor abstractions, duplication, sloppiness and
inconsistency, and for anything that would make the planned work harder. The lead verified the claims marked
**(verified)** in the code or on disk; the rest are the reviewers' evidence with file:line references. References
in brackets (core #3, media #2, …) point to the reviewers' numbering.

This document is grouped by **what each item unblocks**. That is the order in which the work pays off.

## Overall assessment
The individual algorithms are careful and unusually well documented:
- exact time arithmetic;
- a validate-then-commit undo model;
- a careful Metal slot ring;
- a robust export job;
- a realtime audio path that neither locks nor allocates on the render thread;
- precise backend contracts;
- tests that check frames and samples exactly.

The debt is structural and comes from growth, not carelessness:
- rules written in several places;
- no descriptor tables for kinds and parameters;
- a few objects doing several jobs;
- one-sequence and file-only assumptions.

All three planned features (colour grading, nested sequences, the MCP server) land on these seams. Fixing them first
is cheaper than fixing them alongside the features.

## Status at a glance

| Group | State |
|---|---|
| 0. Bugs and test hygiene | **Done** (0.1.8, fecb2a2..bde9dd9) |
| 1. Before colour grading | **Done** except 1.11 (Swift tables, with the grading UI): two prerequisite rounds, bedbb1b..7b1b1ad and ae6283e..d4c385d; decision note approved |
| 2. Before nested sequences | Not started |
| 3. Before the MCP server | Not started |
| 4. Structural, any time | Not started |
| 5. Tests and docs | Partly done (hygiene, slow tests moved); the rest not started |
| 6. Smaller open items | Open; tracked in `open-findings.md` |

---

## 0. Bugs and test hygiene (done in 0.1.8)
All fixed with regression tests that fail on the old code. Status and commits are in `open-findings.md`, "Fix round
2026-10-01 (general review)".

| # | Bug | Where | Status |
|---|---|---|---|
| B1 | Speed/Duration sheet's model rebuilt on every window re-render: a refused Apply lost the typed speed and the reason | `App/Views/ContentView.swift:66-71` | fixed: the model lives on the store |
| B2 | Mute button kept its own state, out of step with Playback > Mute Audio | `TransportBar.swift:56`, `FramewrightApp.swift:186` | fixed: one state, menu check mark |
| B3 | Data race: `DecodePool::refresh()` wrote a worker-owned field (`repairedAt`) | `Engine/Media/DecodePool.mm:1136` | fixed (verified): mutex-guarded re-arm flag |
| B4 | FFmpeg encoder converted BT.2020/240M with BT.709 coefficients | `FFVideoEncoder.mm:194` | fixed: shared `swsColorspace` |
| B5 | Thumbnails and waveforms ignored "Prefer FFmpeg" | `VEMediaLibrary.mm:160-171` | fixed: follow the router's policy at run time |
| B6 | Undo stack ignored a failed re-apply; `AccumulatedSteps` dropped children's ids | `Engine/Edit/UndoStack.cpp:87,25-36` | fixed |
| B7 | Ids reused after undo, contrary to `Ids.h` (only the facade's `FreshIds` keeps the promise) | `Ids.h:3-5`, `Command.cpp:145` | **open:** see 2.4 |
| B8 | Tests leaked about 7 GB in `$TMPDIR`, plus about 3,000 defaults suites and 11,000 temp directories in the real app's container | `TestMedia.mm:459`, `StoreFixtures.swift:36` | fixed: a full run leaves no files; leftovers deleted |
| B9 | AV1/VP9 VideoToolbox decoder registration was a side effect the prober never triggered | `HardwareCaps.mm:185` | fixed: explicit `call_once` at every entry point |
| B10 | Thumbnails found a clip's last frame with one seek (no search) | `ThumbnailService.mm:552` | fixed: one shared `LastFrameSearch` |
| B11 | Span and transition titles disagreed (a Wipe edge read "Cross Dissolve") | `SpanEditing.swift:193` | fixed: `SpanKindDisplay.swift` |
| B12 | M4A with PCM: Apple refused it, FFmpeg's validation accepted it, and the export failed at open | `AppleWriter.mm`, `FFmpegBackend.mm` | fixed: one `ContainerRules.h` table |
| — | Space after a reverse shuttle kept playing in reverse (user report) | `PlaybackController.mm:1339` | fixed: play from stopped is forward at 1x |

Also done:
- **Moved to StressTests:** the `~/Movies` demo-project test and the 61 s random soak (EngineTests run time 410 s →
  290 s).
- **Dead doc links:** fixed.

---

## 1. Unblocks colour grading
Colour grading means a Colour span kind (exposure, contrast, temperature, tint, saturation; later wheels, curves,
LUTs), applied per clip in linear light, with scopes.

**Status (2026-10-02):** 1.1-1.10 done; 1.11 goes with the grading UI. Details and test evidence are in
`open-findings.md` ("Colour grading prerequisites" and "… round 2"). The pipeline decisions are in
`2026-10-01-grading-pipeline-decision.md` (approved). Beyond this list, the transition kinds also gained a
descriptor table with typed parameters (f8361eb), the groundwork for the transition library.

**1.1 Preserve unknown span content on save.** S. **Done** (bedbb1b). (core #9)
- **Today:** an unknown transition kind is kept by name, but unknown span kinds, parameters and fields are dropped
  and lost on save (`ProjectJSON.cpp:455-496`).
- **Why first:** a project with grades opened and saved in a pre-grading build would silently lose them.

**1.2 Descriptor tables for span kinds and parameters.** M. **Done** (eda4028). (core #2)
- **Today:** one new kind or parameter touches about 15 C++ sites. The track-kind rule is written three times
  (`EditOps.cpp:1028`, `Validation.cpp:205`, `Clip.cpp:528`). Whether a parameter adds or multiplies is spelled out in
  six places, inverted in four planners (`planKenBurns`, `planMatchSpanEdge`, `planContinueMotion`,
  `planMatchMotion`). The parser keeps its own kind list (`ProjectJSON.cpp:450`); a kind missing from it is silently
  dropped on load.
- **Fix:** one table per kind (name, track kind, parameters) and per parameter (neutral value, range, additive or
  multiplicative), with `compose`/`decompose` helpers derived from it.

**1.3 Parameters indexed by enum.** M. **Done** (a813c32).
- **Today:** `SpanTracks` holds six named `KeyframeTrack` fields reached through switches. On the facade side,
  `VESpanValues` is a flat public struct mirrored by `spanValueIn`/`setSpanValueIn` and kind switches (render #9).
- **Fix:** storage indexed by `SpanParameter`; facade accessors keyed by parameter.

**1.4 Named shader uniforms.** S-M. **Done** (c59028e). (render #5)
- **Today:** `VEDrawUniforms::reserved` is fully used (shape, feather, a flag), and enums travel as floats
  (`int(x + 0.5)`). Straight alpha hides in `params.y`, 10-bit in `VEConvertUniforms::size.z`, and three buffer
  indices alias 0.
- **Fix:** named sub-structs with real int fields, and a `VEGradeUniforms` slot per source.

**1.5 Decide where grading sits in the pipeline.** Decision. **Done**: approved 2026-10-01 (df53988, 70bfd65, ae6283e).
(render #3)
- **The questions:**
  - grading in linear light or gamma, relative to today's deliberately gamma-encoded blend (`Compositor.h:31-34`);
  - where the decode-time `saturate` clamp (`Shaders.metal:72`) moves;
  - what working format monitors need;
  - which colour tags to honour.

**1.6 Float working buffer on monitors.** M. **Done** (47f0dc9): RGBA16Float, kept by decision on 2026-10-02. (render #3)
- **Today:** monitors blend straight into a framebuffer-only BGR10A2 drawable (`VEPreviewView.mm:217,342`), while
  export blends into an `RGBA16Float` intermediate. Scopes cannot read the drawable, and the two paths blend at
  different precision.
- **Fix:** composite into a pooled float intermediate, then add an output stage.

**1.7 High-precision decode.** M-L. **Done** (d77e2e7), with the decode format in the frame cache key (2.5 done with it). (media #2)
- **Today:** alpha, RGB and still sources come out as 8-bit `32BGRA`, 12-bit ProRes 4444 included
  (`AppleSupport.mm:348`, `FFFrameConverter.mm:227`), against the converter's own "never truncate" rule. Stills are
  flattened to 8-bit sRGB: P3 HEIC is gamut-clipped, and FFmpeg ignores ICC profiles. Transfer and primaries tags are
  attached but never read.

**1.8 One owner for transition and fade rules.** L. **Done** (1c70af7): `TransitionRules::edgeRoom`/`fadeRoom`.
The two remaining disagreements (D1, D2) are decided: the fade gives way everywhere, and the frame-rate
conform changes to match in the first grading round. (core #3)
- **Today:** the rules live in at least six places: `checkTransitionSpan`, `pruneInvalidTransitions`,
  `Clip::fitSpans`, `setClipFade`, `transitionSideLimits`, `fadeLimit`, a trial-and-error loop in
  `SetSequenceFormat`, and a copy in the v4→v5 migration. The copies have already disagreed once (review L9).
- **Why it matters here:** a Colour span shares lanes and limits with these rules.
- **Fix:** one `TransitionRules::edgeRoom` that all of them call.

**1.9 Split `EffectSpan` into effect and transition types.** L. **Done** (4da7893, 520e7c0): `TransitionSpan` in `Clip::transitions`. (core #1)
- **Today:** one struct with two time bases and dummy fields, and every span routine forks on `isTransition()`.
- **Why it matters here:** grading adds non-scalar parameters (wheels, curves, LUT references) that should not live
  next to transition fields.

**1.10 Freeze the migrations.** M. **Done** (74de129): `ProjectMigrations`, with golden fixtures per version. (core #8)
- **Today:** the migrations use the live writer and model helpers (`ProjectJSON.cpp:1143`, `rebasedTrack`,
  `migrateClipV1`), so the first schema change for colour spans would silently alter how a v4 file loads.
- **Fix:** freeze each step, with golden JSON per version.

**1.11 Swift kind and parameter tables.** M. (app #5, #6)
- **Today:**
  - `InspectorParameter` and `SpanParameter` repeat each other's tables;
  - there are two span-range editors and two formatters;
  - per-kind metadata is spread over about 10 switches.
- **Status:** item B11 started a single kind table (`SpanKindDisplay.swift`).
- **Fix:** extend it with parameters and defaults so grading rows come from one place.

---

## 2. Unblocks nested sequences
A nested sequence is a sequence used as a clip in another, live, trimmed and stacked like any clip.

**2.1 Project-level edits.** L. (core #4)
- **Today:** `SequencePatch`/`SequenceCommand` cover exactly one existing sequence. Import, asset removal, composite,
  `FreshIds` and even `MoveClips` live in the Obj-C++ facade.
- **Why it blocks:** "Nest" (add a sequence, then replace clips in another) and revalidating parents after an edit
  inside a nest are not expressible.
- **Fix:** a `ProjectPatch`; the commands moved into `Engine/Edit`; dependents revalidated.

**2.2 Non-file audio and video sources.** L. (media #8)
- **Today:** the mixer holds concrete `ClipAudioSource*`, which opens a file decoder and starts a thread per source.
  Pool streams are built from file URLs.
- **Fix:** an `IAudioSampleSource`, a non-file video frame source, and a bounded shared producer pool.

**2.3 Re-entrant compositor and one layer-to-picture module.** L. (render #2, #4)
- **Today:** the compositor keeps per-frame state in members and cannot render a nested graph inside an outer frame.
  Layer to picture to decode target is written four times (playback, export, the leftover `ProgramFrameProvider`),
  and the priority formula `10000 - k*10 + i` is copied verbatim; it inverts at 10 or more layers.
- **Fix:** a stack-local `FrameBuild` plus `encodeGraph(...)` into a texture inside an existing command buffer, and a
  `LayerPictures` module.

**2.4 One id policy.** S-M. (B7, core #5)
- **Today:** undo restores the id generator, so ids can be reused unless the facade's wrapper intervenes.
- **Fix:** a stack-level high-water mark, or move `FreshIds` into `Engine/Edit`.

**2.5 Frame cache key.** S-M. **Done** with 1.7 (d77e2e7): `FrameKey{asset, decode format}`. (media #7)
- **Today:** frames are keyed by (epoch, asset) only. Two video tracks of one asset, or different decode options,
  would cross-serve frames. This also matters for 1.7's higher-precision decode.

**2.6 One sequence format, one validity rule.** S-M. (core #6)
- **Today:** `Sequence` repeats `SequenceFormat`'s fields. Load-time validation only checks positivity, so a file can
  hold a 1000 fps or odd-sized sequence that Sequence Settings would refuse and the exporter cannot encode.

**2.7 Per-sequence UI state.** M. (app #12)
- **Today:** the snapshot is a single sequence. Viewport, collapse, targets, selection and Ken Burns modes are
  global; lane collapse is persisted under "V1"/"A2" strings.

**2.8 Shared model snapshot.** S-M. (render #14)
- **Today:** the whole `Project` is deep-copied on every edit and again by export.
- **Fix:** keep it as `shared_ptr<const Project>`, replaced copy-on-write.

**2.9 Indexed lookups in the edit pipeline.** M. (core #14)
- **Today:** lookups by id are linear scans; after each edit, a dropped-span diff and transition validation are
  quadratic. These costs multiply with several sequences.

---

## 3. Unblocks the MCP server
An MCP server lets an AI agent drive the app: the facade's edits as tools, one undo step per call, named batches.

**3.1 Edit commands with explicit arguments.** L. (app #3)
- **Today:** store commands read UI state implicitly (selection, focus area, anchor, playhead). Views and models call
  the engine directly in about 45 places, some skipping the gesture guard. "Finish the current drag first." is copied
  20 times.
- **Fix:** an `EditCommands` service that takes ids, times and tracks and returns a typed outcome, with
  selection-based wrappers for menus and keys.

**3.2 One edit-session owner.** M. (app #4)
- **Today:** coalescing groups are keyed by ad hoc strings across 6 files, with three slightly different "can edit"
  gates, and the nudge burst lives in an inspector view model.
- **Fix:** one `EditSession` (drag, slider, nudge, batch, agent batch) with a single `canEdit`. MCP's batch begin/end
  plugs into it.

**3.3 One transport shape and one event channel in the facade.** M. (render #8)
- **Today:** the program and source monitors have different APIs (no play or seek on the source monitor). Export and
  memory-pressure events bypass the observer protocol. `showProgramFrameAtTime:` duplicates `seekToTime:`.

**3.4 Typed outcomes from the engine.** M. (core #10)
- **Today:** five result shapes and four note channels; messages mix developer and user text.
- **Fix:** one `Outcome<T>` (code, user message, diagnostic, notes, limiting clip, free range), which an MCP tool can
  return directly.

**3.5 Command registry.** M. (app #13)
- **Today:** menus, keys and context menus each declare commands, with different enabling rules.
- **Fix:** one registry (title, shortcut, `isEnabled`, `perform`) that MCP's `tools/list` also reads.

**3.6 `@Observable` and splitting `ProjectStore`.** L. (app #2, #8, #9)
- **Today:** 33 `@Published` properties, observed whole by 18 views. `refreshModel` fires about 12 notifications per
  edit. `didSet` observers pause playback and write UserDefaults, and the Ken Burns mode is mirrored by hand.
- **Fix:** split into snapshot, selection, edit commands, Ken Burns session, presentation and timeline state; make
  selection an explicit command.

**3.7 Concurrency checking.** M. (app #11)
- **Today:** strict concurrency is `minimal`, with 28 `MainActor.assumeIsolated`. Some main-thread facade callbacks
  are not annotated.
- **Fix:** annotate them, turn on complete checking, and make the MCP entry an actor that hops to the main actor.

**3.8 One notice policy.** S-M. (app #10)
- **Today:** five reporting channels with no policy; load warnings are shown twice; the status line is never
  cleared.
- **Fix:** a `Notice` type and one `report` path, which can also become an MCP tool result.

---

## 4. Structural, any time
These don't block a specific feature but make every change cheaper.

**4.1 Split `PlaybackController`** (1,720 lines). L. (render #1)
- **Seams:** `ProgramFrameSource`, `AudioOutputLifecycle`, the decode planner.
- **Pasted idioms:** "stop the mixer" ×4, the fade test ×3, the "move the display" epilogue ×7,
  `Playing || Prerolling` ×8. `stepFrames` issues a wasted decode request.

**4.2 Split `EditOps`** (3,580 lines). M. (core #13, #7)
- **Split by concern:** clip edits, span edits, transitions, tracks and links, sequence format with conform.
- **The conform:** move it (630 lines) to its own file, with a post-check over every clip and its report prose
  separated out.

**4.3 Split `VETypes.mm`.** M. (render #9)
- **Today:** a grab bag of snapshot classes, enum bridges, model evaluation, waveform maths and forwarders.
- **Fix:** split by area and drop the forwarders.

**4.4 One decoder core for both backends.** L. (media #1)
- **Today:** `seek`/`next`, the hold-back, still handling and the audio `read()` loops are written per backend, and
  the copies are already drifting.

**4.5 Backend seam and routing.** M-L. (media #3, #5, #6)
- **Today:**
  - the router knows "apple" by name;
  - container tokens are strings from two sniffers;
  - every service probes on its own;
  - `open(path, track)` re-derives what the prober knew.
- **Fix:** backend-declared preferences, a container enum, one `RoutingCache`, and `open(path, TrackInfo)`.

**4.6 Shared job/cache skeleton** for the thumbnail and waveform services. M. (media #13)

**4.7 `DecodePool::step()` as explicit states.** M. (media #14)
- **Today:** a 275-line function driven by ten flags.

**4.8 The source monitor's frame sources.** M. (render #6)
- **Today:** `ProgramFrameProvider` is a misnamed leftover built on a stale premise, and the source monitor switches
  between it and a controller behind a flag used 18 times.

**4.9 Shared render context.** M. (render #11)
- **Today:** every preview view owns a whole compositor.

**4.10 A paused frame crosses five threads before it is drawn.** M. (render #10)
- **Why it matters:** the item 9 race came from this path.
- **Fix:** a direct wake to the render thread.

**4.11 Validation and normalisation.** M. (core #11, #15)
- **Today:** predicates are duplicated, and `normalizeSequence` silently repairs links. Edit and load repair
  different sets.

**4.12 Small duplications and dead code.**
- **Engine core:** `exactTimeOn` ×2, mirror-image trims, four decimal formatters, `kMinSpeed`/`kMaxSpeed` unused,
  bool/options overload pairs.
- **Render and playback:** `SeekMode::NearestKeyframeFast`, `isRenderOnce` and `rgbToYCbCr8Rows` unused;
  `countAssetUses` duplicating `assetUseCounts`; `PlaybackController.h` doubling as a utility header; `MediaAsset::url`
  normalised inconsistently.
- **Media:** CF/VT lifetimes managed by hand; the export audio path polls every 1 ms.
- **App:** test hooks in production state; bookmark resolution copied three times.

---

## 5. Tests and docs

**Done in 0.1.8:**
- leak-free test runs;
- a "wait until media work is idle" facade method;
- `makeTestDefaults` and `scratchDirectory()` helpers;
- the soak and demo-project tests moved to StressTests.

**Still open:**
- **5.1 A facade test base class and one shared wait helper.** M.
  - **Today:** `spinUntil` is copied in 9 files, `mediaURL` in 8 and `makeEngine` in 7. There are five different
    `shownIndex` variants and 28 open-coded deadline loops.
- **5.2 An injectable steady clock in `PlaybackConfig`.** M.
  - **Today:** the controller reads `steady_clock` at 13 sites, so its tests run in real time with fixed sleeps.
- **5.3 Test plans.** S-M.
  - **Today:** absolute wall-clock thresholds run in the default scheme with coverage on, and TSan's class list
    lives in prose.
  - **Fix:** `.xctestplan` files: Default, Timing (no coverage), TSan, Stress/Soak.
  - **Note:** TSan cannot see races on `CMTime` struct copies in this build (found while fixing B3).
- **5.4 Display-link coverage.** S-M.
  - **Today:** the three display-link tests skip in every recorded run.
  - **Fix:** make the tick source injectable.
- **5.5 A command-line doctest target.** S.
  - **Today:** the 331 doctest cases run only inside the full XCTest bundle.
- **5.6 A minimal app mode for AppTests.** S-M.
  - **Today:** the tests run inside the fully launched app, with a live store, real preferences and a global key
    monitor.
  - **Fix:** a minimal launch mode and a separate bundle id.
- **5.7 Coverage gaps.** S-M.
  - **Today:** swscale colour mapping is 0-43 % covered, the colour tag tables partly covered, and the test-only
    `FFRemux` is compiled into the product.
- **5.8 Large tests.** M.
  - **Today:** 28 test methods are over 100 lines; ExportParityTests repeats a 25-line block nine times; tests are
    filed by review id instead of feature.
- **5.9 Docs restructure.** M.
  - **Today:** `integration-notes.md` is an 1,849-line chronological log, and `open-findings.md` carries done items.
  - **Fix:** `docs/architecture-rules.md` (edited in place), `docs/testing.md`, round logs moved to
    `docs/reviews/rounds/`.
- **5.10 Release script guard rails.** S.
  - **Today:** it has no clean-tree check, prints `--target main` whatever was built, never asserts the hardened
    runtime, and doesn't check the FFmpeg build stamp.

---

## 6. Smaller open items
Tracked in `open-findings.md`:
- two kinds of frame-rate change refused although a valid result exists;
- short linked clips that share no cut can lose their overlap by under a frame;
- a 32 kHz AAC export written at 192 kb/s;
- the `VE_ENGINE_HEADER_INCLUDED` macro visible to Swift;
- a few fallback export sizes that can still get a black line;
- the Ken Burns overlay off by under a pixel for 1:1 pictures;
- per-frame allocations in the presented-frame buffer;
- flaky timing bounds (export progress pacing, J from a pause).

## What is good
- Exact time and span maths.
- A validate-then-commit undo model that cannot corrupt a project.
- A plain-value model with typed ids.
- Precise backend contracts, with one conformance suite for both backends.
- A careful realtime audio path.
- Measured hardware routing.
- A Metal slot ring with an abandon path and fault injection.
- A robust export job.
- A facade whose four classes are compiler-enforced to know nothing of the engine.
- Pure, testable interaction logic in the app.
- One undo step per action everywhere.
- Tests:
  - self-generating, versioned media;
  - purpose-built harnesses;
  - honest skips;
  - mutation testing of fixes;
  - opt-in hour-long stress tests.
- Warnings are errors, with no suppressions.
- A pinned, verified FFmpeg build.
- Comments that explain why.
