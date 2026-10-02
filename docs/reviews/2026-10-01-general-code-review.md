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
| 0. Bugs and test hygiene | **Done** in 0.1.8 (dfd9b24..bde9dd9) except B7 (open, with 2.4) |
| 1. Before colour grading | **Done** except 1.11 (Swift tables): two prerequisite rounds, bedbb1b..7b1b1ad and 74de129..d4c385d; decision note approved (70bfd65, ae6283e). Grading slices 1 and 2 shipped since (0.1.9) |
| 2. Before nested sequences | 2.5 done with 1.7 (d77e2e7); the rest not started |
| 3. Before the MCP server | Not started |
| 4. Structural, any time | Not started |
| 5. Tests and docs | Partly done in 0.1.8 (hygiene, slow tests moved); 5.1-5.10 not started |
| 6. Smaller open items | Open; tracked in `open-findings.md` |

---

## 0. Bugs and test hygiene
**Done in 0.1.8** (dfd9b24..bde9dd9) except B7: B1-B6 and B8-B12 fixed with regression tests that fail on the old
code, a user report added (Space after a reverse shuttle kept playing in reverse: 42c1d54), the `~/Movies`
demo-project test and the 61 s soak moved to StressTests, the dead doc links fixed. The bug table and the round's
status notes are in git history (this file and `open-findings.md` at 400ded1).

Open:

| # | Bug | Where | Status |
|---|---|---|---|
| B7 | Ids reused after undo, contrary to `Ids.h` (only the facade's `FreshIds` keeps the promise) | `Ids.h:3-5`, `Command.cpp:145` | **open:** see 2.4 |

---

## 1. Unblocks colour grading
Colour grading means a Colour span kind (exposure, contrast, temperature, tint, saturation; later wheels, curves,
LUTs), applied per clip in linear light, with scopes.

**Done:** 1.1-1.10 in two prerequisite rounds, bedbb1b..7b1b1ad and 74de129..d4c385d (the items' full text is in
this file at 400ded1, the rounds' status notes in `open-findings.md` at 400ded1):
- 1.1 Preserve unknown span content on save: bedbb1b.
- 1.2 Descriptor tables for span kinds and parameters: eda4028.
- 1.3 Parameters indexed by enum: a813c32.
- 1.4 Named shader uniforms: c59028e.
- 1.5 Where grading sits in the pipeline: decided in `2026-10-01-grading-pipeline-decision.md` (df53988), approved
  2026-10-01 (70bfd65, ae6283e).
- 1.6 Float working buffer on monitors: 47f0dc9 (RGBA16Float, kept by the user's decision of 2026-10-02).
- 1.7 High-precision decode: d77e2e7 (with 2.5, the decode format in the frame cache key).
- 1.8 One owner for transition and fade rules: 1c70af7 (`TransitionRules`); the disagreements D1 and D2 made one
  rule (the fade gives way) in 96e2cd5.
- 1.9 `EffectSpan` split from `TransitionSpan`: 4da7893, 520e7c0.
- 1.10 Frozen migrations with golden files per version: 74de129.

Beyond the list, the transition kinds gained a descriptor table with typed parameters (f8361eb). Colour grading
itself shipped in slices 1 and 2 (0.1.9): the base grade is a property of the clip, not a span kind (decision
section 7).

Open:

**1.11 Swift kind and parameter tables.** M. (app #5, #6)
- **Today:**
  - `InspectorParameter` and `SpanParameter` repeat each other's tables;
  - there are two span-range editors and two formatters;
  - per-kind metadata is spread over about 10 switches.
- **Status:** item B11 started a single kind table (`SpanKindDisplay.swift`), and the Colour rows read their names,
  units, neutral values and ranges from the engine's grade table (8d16b30); `InspectorParameter`
  (`InspectorModel.swift`) and `SpanParameter` (`SpanEditing.swift`) still repeat each other.
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

**2.5 Frame cache key.** **Done** with 1.7 (d77e2e7): `FrameKey{asset, decode format}`. (media #7)

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
  - **Today:** `integration-notes.md` is a 2,000-line chronological log. (`open-findings.md` no longer carries
    done rounds since 2026-10-02.)
  - **Fix:** `docs/architecture-rules.md` (edited in place), `docs/testing.md`, round logs moved to
    `docs/reviews/rounds/`.
- **5.10 Release script guard rails.** S.
  - **Today:** it has no clean-tree check, prints `--target main` whatever was built, never asserts the hardened
    runtime, and doesn't check the FFmpeg build stamp.

---

## 6. Smaller open items
Tracked in `open-findings.md` ("Left open by the 2026-09-30 to 2026-10-02 rounds" and the post-lanes review):
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
