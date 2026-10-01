# General code review, 2026-10-01

Scope: the whole repository at 80e2aff (0.1.7), about 128,000 lines. The review was split across five read-only
reviewers, one per area:

1. Engine/Model, Edit, Serialize (13k lines).
2. Engine/Media, Thumbs, Audio (21k).
3. Engine/Render, Playback, Export, Facade (18k).
4. App (16.5k).
5. EngineTests, AppTests, build and docs (60k + tooling).

Each read its area's large files in full and looked for:

- bad design decisions and poor abstractions;
- duplication;
- sloppy code;
- inconsistency;
- anything that would make the planned work harder (colour grading, nested sequences, the MCP server).

The lead verified the claims marked **(verified)** in the code (or on disk). The rest are the reviewers' evidence,
with file:line references, and have not been rechecked.

## Overall assessment

The individual algorithms are careful and unusually well documented:

- the engine's time arithmetic is exact (`ExactTime`, checked CMTime operations, "never store a rounded time");
- the undo model is validate-then-commit;
- the Metal slot ring, the export job and the realtime audio path are solid;
- the realtime audio path neither allocates nor locks on the render thread;
- the backend interfaces are precise contracts;
- the tests check frames and samples exactly, compare monitor and export, use fuzzing and mutation testing, and
  skip honestly.

None of the problems below is carelessness inside a function. The debt is structural and comes from growth:

- **Rules are written in several places.** The copies have started to drift.
- **Missing descriptor tables.** No single table describes span kinds, parameters, transition kinds or editor
  commands, so each new kind touches many switch statements across C++, Obj-C++ and Swift.
- **Large objects remain.** `PlaybackController` (1,720 lines), `ProjectStore` (33 `@Published` properties),
  `EditOps` (3,580 lines) and `VETypes.mm` are each doing several jobs.
- **One-sequence and one-file assumptions.** The edit patch, the audio and video sources and the UI state assume
  one sequence and file-backed media.

All three planned features land on these seams. Fixing them first is cheaper than fixing them alongside the
features. The review also found a handful of real bugs (next section). Those should be fixed regardless.

## Bugs found along the way

| # | Bug | Where | Status |
|---|---|---|---|
| B1 | **Speed/Duration sheet loses its input.** The sheet's model is built inside the sheet closure and held as `@ObservedObject`. Any store change (including the refusal's own status message) re-renders the window and replaces the model, so the typed speed and the refusal reason disappear. | `App/Views/ContentView.swift:66-71`, `SpeedDurationSheet.swift:235` | verified in code; reproduce by hand: "Don't ripple", slow a clip with a neighbour, Apply |
| B2 | **Mute button out of step with the menu.** The transport button keeps its own `@State muted`, read only on appear. Playback > Mute Audio toggles the engine directly, so the icon goes wrong and the next click does nothing. The menu item has no check mark. | `App/Views/Transport/TransportBar.swift:56,90-102`, `App/FramewrightApp.swift:186` | verified |
| B3 | **Data race in `DecodePool::refresh()`.** It writes `Stream::repairedAt` under the pool mutex, while the worker reads and writes it without the lock (documented "owned by the worker"). Export calls `refresh()` while other streams step. | `Engine/Media/DecodePool.mm:110,784,801,821,1136`; `ExportJob.mm:385` | verified |
| B4 | **FFmpeg encoder converts BT.2020 (and 240M) with BT.709 coefficients** while tagging the stream with the requested matrix. This affects software encodes (SVT-AV1, `prores_ks`). The correct mapping already exists in `FFFrameConverter::swsColorspace`. | `Engine/Media/FFmpeg/FFVideoEncoder.mm:194` | verified |
| B5 | **Thumbnails and waveforms ignore "Prefer FFmpeg".** Their services are built without `Config::routing`, so they always use the default policy. | `Engine/Facade/VEMediaLibrary.mm:160-171` | verified |
| B6 | **The undo stack ignores a failed re-apply.** After a coalesced replace fails, `previous.apply(project)` ignores its result, so the history can record a step the project does not reflect. Also: `AccumulatedSteps::apply` discards its children's dropped-span ids. | `Engine/Edit/UndoStack.cpp:87`, `:25-36` | verified (first part) |
| B7 | **Ids are reused after undo, contrary to `Ids.h`.** Undo restores the id generator, so only the facade's `FreshIds` wrapper keeps the documented promise. Any future in-engine composite, nest or batch that bypasses the wrapper reuses ids. | `Engine/Model/Ids.h:3-5`, `Engine/Edit/Command.cpp:145` | verified (latent) |
| B8 | **Test runs leak disk.** About 7.1 GB and 28,874 directories in `$TMPDIR/FramewrightEngineTests` (scratch directories are never removed). About 3,000 `UserDefaults` suites and 11,255 temp directories in the **real app's container** (AppTests run in the app with the same bundle id; waveform work outlives `cleanUp()` and recreates directories). | `EngineTests/Media/TestMedia.mm:459-464`, `AppTests/StoreFixtures.swift:36-38`, `project.yml:314` | verified on disk |
| B9 | **AV1/VP9 hardware decoders may not be registered in time.** They are registered only as a side effect of `HardwareCaps::get()`, which the prober never calls. A probe at launch can measure AV1 as not hardware-decodable, and the routing sticks for that asset. | `Engine/Media/HardwareCaps.mm:185`, `AppleProber` | likely; not reproduced |
| B10 | **Thumbnails can fail at a clip's end.** The thumbnail service finds a clip's last frame with one seek, without the search the decode pool uses, so it fails where a track's duration overstates its pictures. | `Engine/Thumbs/ThumbnailService.mm:552-555` vs `DecodePool.mm:674-705` | reviewer evidence |
| B11 | **Span and transition titles disagree.** Dragging a Wipe's edge says "Cross Dissolve…", and a removed iris is reported as "the cross dissolve". | `App/State/SpanEditing.swift:193-206` vs `TimelineViewModel.swift:125-144` | reviewer evidence |
| B12 | **M4A with PCM: the backends disagree.** Apple refuses it; `FFmpegBackend::validate` accepts it, so the router can send it to FFmpeg, whose ipod muxer may fail late. | `AppleWriter.mm:516-567` vs `FFmpegBackend.mm:107-134` | unverified |

## Cross-cutting themes, ranked

### 1. The same rule lives in several places, and the copies drift
- **Transition and fade limits:** at least six places: `checkTransitionSpan`, `pruneInvalidTransitions`, `Clip::fitSpans`, `setClipFade`,
  `transitionSideLimits`, `fadeLimit`, plus a trial-and-error loop in `SetSequenceFormat` and a frozen copy in the
  v4→v5 migration (core #3). The "review L9" fixes were already one instance of the copies disagreeing.
- **Span kind and parameter classification:** which track a kind belongs to is open-coded three times; whether a
  parameter adds or multiplies, in six places, inverted in four planners (core #2).
- **Validation predicates:** written twice inside one function (`checkVideoParams`); the speed message appears three
  times; `kMinSpeed`/`kMaxSpeed` are never used (core #11).
- **Layer to picture to decode target:** four times across playback, export and the leftover `ProgramFrameProvider`,
  with the priority formula `10000 - k*10 + i` copied verbatim. It inverts at 10 or more layers (render #2).
- **Decoder `seek`/`next` state machines:** written once per backend, and already drifting. Stills: Apple reads the
  alpha tag, FFmpeg hard-codes it. Audio end of stream: the two stop under different conditions (media #1).
- **The rest:**
  - Thumbnail and waveform services are parallel copies of one skeleton (media #13).
  - Three "last frame" algorithms (media #9).
  - `nativePixelFormat`, `fitDimensions`, `checkReadableFile` and the container/codec rules are copied across the
    backends (media #11).
  - Swift has two parameter tables, two range editors and two formatters (app #5), per-kind titles and icons in
    several places (app #6), and engine rules re-derived in Swift (fade room, lane limits, drop reasons; app #7).

**Recommendation:** one owner per rule:

- a `TransitionRules::edgeRoom` that every caller uses;
- a shared `PresentationOrderDecoder` core and `StillVideoDecoder`;
- one `LayerPictures` module for picture keys and decode targets;
- facade queries (`fadeLimit`, `spanLimits`, `placementBox`, drop reasons) so Swift stops re-deriving engine rules.

### 2. No descriptor tables: every new kind or parameter is a scavenger hunt
- **Today, one new span kind or parameter means editing:**
  - about 15 sites in the C++ engine;
  - a public C struct (`VESpanValues`) plus about 6 switch sites in the facade;
  - about 10 kind switches and 29 `kind ==` checks across 8 Swift files.
- **Forgetting one fails silently:**
  - `parseSpan` drops an unknown kind on load;
  - a wrong-track refusal;
  - a plan that inverts the wrong way.
- **`EffectSpan` is two types in one struct** (core #1). Transitions and effects share the struct with different
  time bases and dummy fields, and every span routine forks on `isTransition()`. `SpanTracks` holds six named
  scalar tracks, which do not fit wheels, curves or LUTs.
- **Shader uniforms are packed into spare float lanes:** enums travel as floats; `reserved` is fully used
  (render #5).

**Recommendation:** before colour grading:

- descriptor tables for `SpanKind` and `SpanParameter` (name, track kind, neutral value, range, additive or
  multiplicative) with `compose`/`decompose` helpers;
- parameters indexed by enum instead of named fields;
- split `EffectSpan` into effect and transition types;
- a per-kind metadata extension in Swift (title, icon, colour, parameters);
- span values in the facade keyed by `VESpanParameter`;
- named uniform sub-structs, with optional grading features behind function constants.

### 3. Large objects that still do several jobs
- **`PlaybackController`** (render #1) does all of these:
  - the transport state machine and pre-roll;
  - decode targeting;
  - audio mix planning;
  - the audio device's lifetime and power handling;
  - the render-thread frame source;
  - observers, preview solo and HUD stats.

  It also contains pasted idioms: "stop the mixer" four times, the "faded" test three times, the "move the display"
  epilogue seven times, `Playing || Prerolling` eight times. `stepFrames` issues a wasted decode request.
- **`ProjectStore`** (app #2): 33 `@Published` properties, observed whole by 18 views and menus.
  - `refreshModel` fires `objectWillChange` about 12 times per edit.
  - The workarounds this forces: `Equatable` canvases with a hand-kept field list, mirror properties, `objectWillChange`
    forwarded by hand in five places.
- **`EditOps`** (core #13): 3,580 lines holding about 30 commands, the planners, queries, a 630-line conform
  algorithm (core #7) and prose helpers. The `EditPlans`/`TransitionFitting` split is arbitrary.
- **`VETypes.mm`** (render #9): a grab bag of snapshot classes, enum bridges, model evaluation, waveform maths and
  pass-through forwarders.
- **`DecodePool::step()`** (media #14): a 275-line state machine held in ten flags.

**Recommendation:**

- Split `PlaybackController` along its existing seams: `ProgramFrameSource`, `AudioOutputLifecycle`, the shared
  decode planner. Add private helpers for the pasted idioms.
- Move the app to `@Observable` (macOS 14 allows it) and split `ProjectStore` by concern: snapshot, selection,
  edit commands, Ken Burns session, presentation state, timeline state.
- Split `EditOps` by concern: clip edits, span edits, transitions, tracks and links, sequence format with conform.

### 4. One-sequence and file-only assumptions (blocks nested sequences)
- **Edit layer:** `SequencePatch`/`SequenceCommand` cover exactly one existing sequence. Project-level commands
  (import, remove asset, composite, `FreshIds`, even `MoveClips`) live in the Obj-C++ facade. An edit that shortens
  a sequence used as an asset would not revalidate its parents (core #4).
- **Media and audio sources:** the mixer holds concrete `ClipAudioSource*`, which opens a file decoder and starts a
  thread per source; pool streams are built from file URLs (media #8).
- **Frame cache key:** it omits the track and the decode options. This is latent today, but a proxy decode or a
  higher-precision grading decode would cross-serve frames (media #7).
- **Compositor:** it keeps per-frame state in members and cannot re-enter, so it cannot render a nested graph as a
  layer inside an outer frame (render #4).
- **UI state:** the snapshot is a single sequence; viewport, collapse, targets and selection are global; lane
  collapse is persisted under "V1"/"A2" strings (app #12).
- **Sequence settings:** validation is split. A loaded file can hold a 1000 fps or odd-sized sequence that Sequence
  Settings would refuse and the exporter cannot encode (core #6).

**Recommendation:** before nesting:

- a project-level patch, with dependents revalidated;
- the composite and asset commands moved into `Engine/Edit`;
- an `IAudioSampleSource` and a non-file video frame source;
- a cache key that includes track and format;
- a re-entrant `encodeGraph`;
- per-sequence view state in the app;
- one `SequenceFormat` member with one validity rule.

### 5. The colour pipeline is not ready for linear-light grading
- **Different render paths:** monitors blend straight into an 8- or 10-bit framebuffer-only drawable; export blends
  into an `RGBA16Float` intermediate. Scopes cannot read the drawable, and the two paths blend at different
  precision (render #3).
- **Clamping at decode:** `sampleYCbCr` clamps (`saturate`), discarding above-white values before any grade.
- **8-bit decode output:** alpha, RGB and still sources come out at 8 bits (12-bit ProRes 4444 included); stills
  are flattened to 8-bit sRGB (P3 HEIC is gamut-clipped; FFmpeg ignores ICC profiles) (media #2).
- **Unused colour tags:** transfer and primaries are attached carefully but never read downstream.

**Recommendation:**

- composite into a pooled float intermediate on monitors too, followed by an output stage;
- decide and write down where grading sits relative to the gamma-space blend, and move the clamp after it;
- add a high-precision decode format for alpha, high-depth and still sources;
- decide which colour tags the compositor honours.

### 6. Commands depend on the selection and gestures are string-keyed (blocks the MCP server)
- **Store commands read UI state implicitly:** `selection`, `focusArea`, the anchor, the playhead. Views and models
  also call the engine directly (about 45 sites), and some skip the gesture guard. The preamble ("Finish the
  current drag first.") is copied 20 times (app #3).
- **Coalescing groups:** keyed by ad hoc strings across 6 files, with three slightly different "can edit" gates
  (app #4).
- **Facade monitor APIs:** the two monitors have different shapes; export and memory-pressure events bypass the
  observer protocol (render #8).
- **Notices:** five reporting channels with no policy (app #10).
- **Menus, keys and context menus** each declare commands separately, with different enabling rules (app #13).
- **Concurrency:** strict concurrency is `minimal`, with 28 `MainActor.assumeIsolated` (app #11).

**Recommendation:**

- an `EditCommands` service with explicit arguments that returns a typed outcome, with selection-based wrappers for
  menus and keys;
- one `EditSession` owner (drag, slider, nudge, batch) with a single `canEdit`;
- one transport shape and one event channel in the facade;
- an `EditorCommand` registry that menus, keys, context menus and MCP's `tools/list` all read;
- complete concurrency checking for the App target.

### 7. Test infrastructure
- **Leaks:** see B8.
- **Copied facade scaffolding:**
  - `spinUntil` in 9 files with two poll intervals;
  - `mediaURL` in 8;
  - `makeEngine` in 7;
  - five textually different `shownIndex` variants;
  - 28 open-coded deadline loops and 6 named waiters.
- **Timing and real time:**
  - Absolute wall-clock thresholds (1.5 ms per frame, 5 ms caller budget) run in the default scheme in Debug with
    coverage on.
  - The playback controller reads `steady_clock` at 13 sites, so its tests run in real time with fixed sleeps.
  - About 19 "nothing happened" assertions follow fixed waits.
- **The slowest test** (66.6 s) reads `~/Movies/Framewright Demo` and runs only on the author's machine. Two random
  real-time soak tests take 128 s of a 600 s run.
- **Display-link coverage:** the three display-link tests skip in every recorded run ("no awake display"), so
  nothing exercises the render loop.
- **Coverage gaps:** `FFRemux.mm` (test-only code shipped in the product) 0 %; swscale colour mapping 0-43 %.
- **Doctest:** its 326 cases run only inside the full XCTest bundle.
- **No test plans:** TSan's class list lives in prose; there is no Timing or Soak configuration.
- **AppTests host:** they run inside the fully launched app (live store, real preferences, global key monitor).

**Recommendation:**

- teardown hygiene, plus a facade "wait until idle" method;
- a `VEFacadeTestCase` base class and one shared `waitUntil`;
- an injectable steady clock in `PlaybackConfig`;
- `.xctestplan` files: Default, Timing (no coverage), TSan, Stress/Soak;
- a command-line doctest target;
- a minimal app mode and a separate bundle id when hosting tests.

### 8. Docs
- **`integration-notes.md`** is a 1,849-line chronological log. The current rules (lines 7-72) sit above about
  1,780 lines of history, some of it explicitly superseded.
- **`open-findings.md`** promises "only what is still open" but carries about 245 lines of done items.
- **Dangling links:** `docs/plans/README.md` and `integration-notes.md:1379` link the deleted
  `2026-09-29-post-lanes-review.md`.
- **No testing guide.** The harnesses, the doctest filter, the TSan recipe and the media cache are described only in
  review logs.

**Recommendation:**

- `docs/architecture-rules.md`, edited in place;
- `docs/testing.md`;
- round logs moved to `docs/reviews/rounds/`;
- `open-findings.md` kept to open items;
- the release steps in the README.

## Further findings by area (not covered above)

**Engine core**
- Migrations use the live writer and model helpers, so the next schema change silently alters how a v4 file loads.
  Freeze each step and add golden JSON per version (#8).
- Forward compatibility is inconsistent. An unknown transition is preserved, but unknown span kinds, parameters and
  fields are dropped and lost on save, so an older build would strip colour grades. Preserve them opaquely, or
  refuse to overwrite (#9).
- Five result shapes and four note channels; messages mix developer and user text. Use one `Outcome<T>` with a code,
  a user message, a diagnostic and notes (#10).
- Lookups by id are linear scans; the per-edit pipeline has quadratic steps. Build one per-apply index (#14).
- `normalizeSequence` silently repairs broken links after every edit. Edit and load use different repair sets (#15).
- Bool/options overload pairs, UI strings passed into commands, unused parameters (#16).
- Rounding `+`/`-` used where `checked*` is the stated rule. `ExactTime` lacks `times`, `dividedBy` and
  `onTimescale`, so Int128 code is hand-written (#17).
- Copy-pasted helpers (`exactTimeOn` ×2, mirror-image trims, four decimal formatters) and misleading comments and
  sentinels (#12, #19).

**Media**
- The backend seam is Apple-shaped: the router knows "apple" by name, and container tokens are strings from two
  sniffers. `VEExport.mm:509` bypasses the router (#3).
- Every subsystem probes on its own, with different policies; probes are expensive. Add one `RoutingCache` (#5).
- `IVideoDecoder::open(path, track)` re-derives everything the prober knew. Pass the backend's own `TrackInfo` (#6).
- The export audio path polls every 1 ms under the mixer mutex (#16).
- Manual CF/VT lifetimes where `CFRef` exists; per-call transfer sessions (#15).
- `FFRemux` compiled into the product; dead switch arms; inconsistent `MediaInfo::duration`; rotation normalisation
  ×5 (#17).

**Render, Playback, Facade**
- `ProgramFrameProvider` is a misnamed leftover built on a stale premise. The source monitor switches between it and
  a controller behind a flag used 18 times. Give the source monitor one controller (#6).
- `PlaybackController.h` doubles as a utility module (`mediaPathForURL`, `pictureTimeFor`), so export, audio and the
  facade include the whole controller. `MediaAsset::url` is "URL or path" and is normalised inconsistently (#7).
- A paused frame crosses five threads before it is drawn; the item 9 race came from this choreography. A direct wake
  path would fix it (#10).
- Every preview view owns a whole compositor (queue, texture cache, pipelines, scratch pool). Share a per-device
  `RenderContext` (#11).
- Dead code: `SeekMode::NearestKeyframeFast`, `isRenderOnce`, `rgbToYCbCr8Rows`; stale comments; contradictory docs
  on `makeEncodeSettings` (#12).
- `countAssetUses` repeats `assetUseCounts` and runs O(assets × clips); 16384 is a literal in two places (#13).
- The whole `Project` is deep-copied on every edit, and again by export. Use a `shared_ptr<const Project>` (#14).

**App**
- `didSet` observers carry business logic. Selecting a span pauses playback, writes UserDefaults and changes the
  engine's solo preview. Use explicit `select(...)` commands (#9).
- State is duplicated between store, views and engine: Ken Burns mirrors, three copies of "is exporting", collapse
  state split over two keys (#8).
- Diagnostics and test hooks sit in production state; `assetsByID` is settable for tests (#14).
- Stale comments; a progress throttle that repeats the engine's cap; models filed under `Views/`; bookmark
  resolve-with-fallback copied three times (#15).

**Build**
- The release script has no clean-tree check, prints `--target main` whatever was built, never asserts the hardened
  runtime, and does not check the FFmpeg build stamp (#14).
- Stale `VidEdit.entitlements`. `.swiftformat` targets 5.9 while the project says Swift 5.0. `docs/demo/` is ignored
  but 4 of its files are tracked (#17).
- Tests are filed by review id ("E1", "P1") in three regression files instead of by feature (#15).

## What is good

- Exact time and span maths, and a validate-then-commit undo model that cannot corrupt a project.
- A plain-value model with typed ids.
- Precise backend contracts with one conformance suite run against both backends.
- A careful realtime audio path (no locks or allocation on the render thread).
- Measured, not guessed, hardware routing.
- A Metal slot ring with an abandon path and fault injection.
- A robust export job (validation first, an atomic working file, clear errors).
- The facade's four classes are compiler-enforced to know nothing of the engine.
- In the app, interaction logic lives in pure, testable types (gesture state machine, timeline geometry, Ken Burns
  maths). One undo step per action holds everywhere. There are no force unwraps.
- Tests:
  - self-generating, versioned media;
  - purpose-built harnesses (`PlaybackHarness` with a virtual clock, scripted audio output, burn-in frame indices);
  - honest skips;
  - mutation testing of review fixes;
  - opt-in hour-long stress tests.
- Build: warnings are errors with no suppressions, and `build-ffmpeg.sh` is pinned and verified.
- Comments explain *why*, with measurements and review references.

## Recommended order

1. **Now (cheap, independent):**
   - fix bugs B1-B6, check B9 and B10;
   - test hygiene (B8): teardown, defaults suites, a facade "wait until idle";
   - move the `~/Movies` test and the soak tests out of the default run;
   - fix the dangling doc links.
2. **Before colour grading:**
   - descriptor tables for span kinds and parameters, and splitting `EffectSpan` (theme 2);
   - `TransitionRules` consolidation (theme 1);
   - the float intermediate on monitors, clamp placement and high-precision decode (theme 5);
   - named shader uniforms;
   - preserving unknown span content on save.
3. **Before nested sequences:**
   - the project-level patch and moving the project commands into `Engine/Edit` (theme 4);
   - the id policy (B7);
   - non-file audio and video sources;
   - the cache key;
   - a re-entrant compositor and one `LayerPictures` module;
   - per-sequence view state in the app.
4. **Before the MCP server:**
   - `EditCommands`/`EditSession` with typed outcomes (theme 6);
   - one transport shape and one event channel in the facade;
   - a command registry;
   - `@Observable` and the `ProjectStore` split;
   - complete concurrency checking.
5. **Ongoing:**
   - split `PlaybackController` and `EditOps`;
   - the shared decoder core and job-service skeleton;
   - test plans, the facade test base class, an injectable steady clock;
   - the docs restructure.
