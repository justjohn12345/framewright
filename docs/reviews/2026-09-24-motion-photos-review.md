# Keyframed Motion, Ken Burns and Photos drops review (2026-09-24)

Reviewer: Claude (lead) with four read-only Opus reviewers (engine model/edit/JSON, facade/export/media, app
Motion UI, Photos drops). Scope: commits 4c118ef..5c47628 (26 commits, 61 files, +11214/−132): keyframed Motion
(model, edit ops, schema v4, scheduler, facade, inspector, Ken Burns helper with range/existing-move/custom
range/band/draggable markers, Control-K), Photos.app file-promise drops and Import from Photos. The lead
verified every HIGH and MEDIUM finding below by reading the cited code; items a reviewer could not confirm at
runtime are marked "unverified". Tree state: full Framewright scheme green (443 EngineTests incl. 190 doctest
cases, 165 AppTests), zero warnings, app launches.

## Summary
Three HIGH findings. (1) Adding a keyframe (the diamond, Control-K, a value typed on an animated parameter)
inserts a plain linear keyframe and so reshapes the segment it lands in: a hold becomes a ramp and an eased move
is re-timed, contradicting the documented "the picture does not change". (2) Live Photo pairing runs across
every file of a batch by file stem, and a remembered choice then deletes one of two unrelated files with no
question; the remembered choice cannot be changed in the app. (3) The Ken Burns helper's preview pictures go
through the shared thumbnail cache: 3.7 MB each, no byte budget (600 entries FIFO, about 2 GB after a long
scrub), every landing redraws the timeline and the bin, and the loader never shows the picture that just
landed, so the preview freezes during a continuous scrub. The rest are MEDIUM correctness items at the seams
(a nudge writing into a keyframe the frame does not display, a keyframe on the next precise tick showing a
frame late after a hold, late Photos placement overwriting later edits, quit/New/Open ignoring media still
arriving, the media-folder bookmark surviving Save As) and a long tail of LOWs. The core is sound: exact-time
evaluation, the curve split, undo snapshots, the marker-drag command, the view-observation rules and the
file-deletion boundaries are all correct.

## Ranked findings

1. HIGH: adding a keyframe changes frames other than the one keyed. `EditOps.cpp:1080-1087` (AddKeyframe),
   `:1140` (SetMotionValue's add path) and `:1505-1513` (the Control-K toggle) insert a Linear keyframe holding
   the value evaluated at that time; the segment's shape is lost. Scenario (fixture `Animated`,
   KeyframeEditTests.cpp:27, Control-K on frame 50 = source 80): scale was Hold 1 over [60,100) and now shows
   1.5 at source 90; x was EaseInOut 0→300 over [60,150) and now shows 165.2 instead of 205.7 at source 115.
   Fix: insert through `splitTrack(track, static, t)` and merge left+right (the boundary once): a hold stays a
   hold, an eased segment becomes two exact Bezier parts; apply an explicit value/interpolation after the split.
   Tests: picture preservation on every frame for Add/Toggle/SetMotionValue-add inside Hold and eased segments
   (today only the keyed frame is checked, and AddKeyframe's test inserts into a Linear segment only).

2. HIGH: Live Photo pairing across unrelated items, and the remembered choice is permanent.
   `IncomingMedia.swift:283-305` pairs any still and movie sharing a stem (case-insensitive) across the whole
   batch; `:595-612` applies a remembered `livePhotoImport` choice without asking and deletes the other file.
   Scenario: drag IMG_0001.HEIC (an old phone) and an unrelated IMG_0001.MOV (a new phone; camera names wrap
   at 9999) in one drop with "Remember my choice" set: one of them is deleted from the Media folder and never
   imported, silently. Same through PHPicker (each pick is its own item). `livePhotoImport` is referenced
   nowhere else in App/. Fix: pair only files one promise delivered together (one receiver's files, or a .pvt
   bundle); never apply a remembered choice to a cross-item pair; add a Settings control (Ask / Video / Still)
   and name it in the alert text. Test the false-positive pair and the settings round trip.

3. HIGH: the Ken Burns preview pictures flood the shared thumbnail cache, redraw everything, and freeze while
   scrubbing. `KenBurns.swift:892-943` (`KenBurnsPictureLoader`, `maxDimension` 1280) stores through
   `ThumbnailCache` (`MediaCaches.swift:44,141-148`: capacity 600 entries, FIFO, no byte accounting). Each
   distinct playhead frame is a new key (~3.7 MB); a 30 s scrub back and forth fills ~2 GB, evicts the timeline
   strips and bin tiles (which refetch and bump again), and the pictures stay after the helper closes. Every
   landing bumps `thumbnails.version`, which `TimelineView`, `MediaBinView` and every `AssetTileView` observe
   (`TimelineView.swift:63,208`, `MediaBinView.swift:13,216`): one full timeline + bin redraw per landing; a
   separate version counter would not help because `objectWillChange` fires for any published change. And
   `update()` (`KenBurns.swift:919-943`) looks only for `wantedSeconds` when a fetch lands, never assigns the
   landed `pendingSeconds` picture, so during a continuous scrub `image` stays on the first `anyImage` fallback
   until the playhead stops (the test at KeyframedMotionTests:412 passes only through that fallback). Fix: give
   the loader its own small cache (4-8 images, calling `engine.thumbnail` directly, observed by the overlay
   alone; drop the `cachedImage`/`isFetching` additions on ThumbnailCache if unused); show the landed picture
   before starting the next fetch; re-drive the loader on a failed fetch (`MediaCaches.swift:133-137` records
   failures without `bump()`). Tests: three landings during a scrub, a failed fetch, and a redraw test with the
   overlay hosted that counts timeline/bin redraws while pictures land (the band test hosts the timeline alone).

4. MEDIUM: a value edit on an animated parameter can write into a keyframe the frame does not display.
   `VEEngine.mm:1945-1946` (setMotionValue's animated branch; also `VEClipInfo keyframeForParameter:atTime:`)
   takes the keyframe the frame "owns" via `keyframeIndexForFrame`, which may sit anywhere in the frame's
   source span, e.g. on the out point after a split, or inside a frame of a 1.5x clip; the frame's picture is
   evaluated at the frame's start (`Scheduler::motionAt`), and the inspector shows and nudges that evaluated
   value (`InspectorModel.swift:283-290`). Scenario: x linear 0→−150 over 40 frames, split at 20: the left piece
   has an out-point keyframe at −75 while its last frame shows −71.25; a +1 nudge sets the keyframe to −70.25
   and the frame shows about −66.7. Fix: when the owned keyframe's time is not `keyframeTimeForFrame(frame)`,
   plan like `planMotionAtFrame` for that parameter (a keyframe on the frame's start carrying the new value and
   inheriting the interpolation, the frame's other keyframes giving way) as one SetMotionTracks. Test: a split
   out-point keyframe and a 1.5x clip.

5. MEDIUM: a keyframe on the next precise tick shows one frame late after a hold. `Clip.cpp:266-280`
   (`keyframeTimeForFrame`) falls back to the next kPreciseTimescale tick T = S + up to 1.4 ns when the exact
   source time S has no CMTime form; `Scheduler.mm:44-46` evaluates the frame at S < T, so with a Hold segment
   before it the frame shows the previous value and the new value appears on the next frame. Reachable
   (KeyframeTests.cpp:255-274 builds such a clip: NTSC, speed 999/1000, sourceIn 44101/44100; it checks where the
   keyframe lands, not what the frame shows). Affects AddKeyframe, SetMotionValue, toggle, planMotionAtFrame,
   planMotionMove, planMotionKeyframeGroupMove. Fix: evaluate at the same representative time (in `motionAt`
   use the tick time when S has no CMTime form), or snap within-frame keyframes to S during evaluation. Test
   the rendered value of that frame with a Hold predecessor.

6. MEDIUM: a late Photos placement overwrites what the user edited since the drop, and failures are silent.
   `ProjectStore.swift:1108-1123` (`place`) drops with `overwrite: !placement.insert` (overwrite is the default)
   at the drop-time placement whenever the batch settles; a track deleted meanwhile or a refused `dropAsset`
   ends with `break` and no message; an open nudge burst is not treated as a gesture. Scenario: an iCloud item
   takes three minutes; the user edits at 10 s; on arrival the clip overwrites those edits as a new undo step
   with no note. Fix: record `changeCount` at the drop; if it changed or the target range is no longer empty,
   insert instead or leave the media in the bin with a message; report a missing track or a refused drop.

7. MEDIUM: quit, close window, New and Open do not ask about media still arriving.
   `DocumentController.swift:118-160` checks `isDirty` and the export only. Scenario: a saved project (bookmark
   already saved, not dirty), five iCloud photos dropped, two arrived (`.received`, waiting for the batch),
   Cmd-Q: nothing is imported and the two files stay orphaned in Media; New/Open `discardAll()` the same way.
   Fix: ask when `store.incoming.isReceiving` in the three confirm paths ("Media from Photos is still arriving:
   Stop / Keep Waiting"). Test through DocumentController.

8. MEDIUM: the media-folder bookmark follows the project to a new location. `VEEngine.mm:917-919` writes
   whatever bookmark is held; `IncomingMedia.swift:397-405` stores one even for the implicit "Media next to the
   project" folder; `ProjectStore.save(to:)` resets nothing. Save As to /B: later drops still land in /A/Media
   and P2 references A's folder permanently; a Finder-duplicated project folder imports into the original's
   Media (bookmarks resolve by file identity). The header (VEEngine.h:234-238) specifies only New/Open. Fix:
   persist a bookmark only for a folder the user chose; recompute the implicit folder from `projectURL`; on a
   save to a different directory drop a bookmark resolving to the old `<dir>/Media`. Document and test Save As.

9. MEDIUM: the real Photos drag path (`PasteboardFilePromise`, `IncomingMedia.swift:200-237`) is fragile and
   untested. `expected = max(1, receiver.fileTypes.count)` (unverified against AppKit for Live Photos and error
   cases): fewer reader calls leave the item receiving forever and never delete what arrived; more calls
   complete early and orphan the rest; cancel after a partial delivery leaves the partial files until every
   call arrives. `displayName` is the type's description ("HEIF Image") on every row, so per-row Cancel buttons
   are indistinguishable. Fix: settle each reader call on its own, delete what arrived at once on cancel and
   keep a set of paths to delete on late calls; use the promise metadata or file names for the row. Tests: the
   count, a reader error, cancel after partial delivery, deallocation while pending.

10. MEDIUM: the folder panel and the accepted promise types put the user's own files at risk of clutter and
    orphans. `IncomingMedia.swift:375-395`: in the real sandbox "Media next to the project" fails for a project
    opened through a panel, so the folder panel appears in most sessions, opens on the project's folder with
    "Keep Media Here", and one click makes the project folder the Photos folder; `createDirectory` also adopts
    a user's own existing "Media" folder without asking. `:199-202` takes every `NSFilePromiseReceiver` without a
    `fileTypes` filter, so a Mail PDF or Numbers file dropped on the bin is received into Media, fails in
    `importMedia`, and stays there; the same for any received file the engine refuses. Fix: after the panel,
    create and use a "Media" subfolder inside the chosen folder; adopt an existing folder only with a marker the
    app wrote; receive pasteboard promises into a private staging subfolder and `adopt` from there; filter
    receivers by `fileTypes` conforming to image/audiovisual/livePhotoBundle; delete received files whose
    import failed. Unverified: whether Photos makes names unique or overwrites on collision in the destination.

11. MEDIUM: typed Start/End/Duration text is overwritten by unrelated model changes. `KenBurns.swift:654-657`
    (`rangeChanged()` rewrites all three texts) runs from `update(clip:)` (`:632-650`), which `refreshModel`
    calls on every model change (save, an import landing, `setMediaFolderBookmark`, undo/redo, any push), and
    from `setPlayhead` in From playhead (e.g. during playback). Typed, uncommitted text silently reverts.
    `commitFields()` (`:506-508`) also overwrites `endText`/`durationText` between commits. Fix: keep the last
    committed string per field, rewrite a field only when its committed string changed, never rewrite a field
    whose text differs from its old committed value. Test: typed text survives a save and a model change.

12. MEDIUM: the start rectangle cannot be grabbed when the rectangles overlap. `KenBurnsOverlay.swift:43-45,
    141-160`: the end rectangle is drawn last with a hit-testable fill and its corners on top; for a placed but
    unanimated clip `defaultRect` (`KenBurns.swift:676-685`) gives identical rectangles, so the start's body,
    corners, label and the arrow are all covered; with the default push in the start is reachable only on its
    outer margin. Fix: hit-test a border band per rectangle, or pick the rectangle whose edge/corner is nearest.

13. MEDIUM (test validity): the animated export parity test's movement check proves nothing.
    `ExportParityTests.mm:619` (`smallestStep > 40`) is satisfied by the test clip's background cycling
    (`palette[index % 8]`, sampled 4-5 source frames apart) with animation off. The layer-transform asserts and
    the export-vs-monitor block comparison do hold (scale reaches 2.2 by frames 19-39). Fix: compare against an
    unanimated render of the same graph, or use a still/single-colour source for the movement check; assert the
    V2 still's Hold keyframes at the layer level.

14. MEDIUM-LOW: `uniqueURL` race between concurrent item-provider handlers (`IncomingMedia.swift:49-80,
    134-158`): two picks suggesting "IMG_0001" adopt on separate background threads, both pick IMG_0001.mov,
    the second's move and copy both fail, the item reports "could not be received". No data loss. Fix:
    serialise `adopt`, or retry with the next number on `NSFileWriteFileExistsError`.

15. MEDIUM-LOW: Control-K auto-repeat flips all five keyframes on and off. `KeyboardController.swift:57-62`:
    `.toggleMotionKeyframes` is not in `ignoresRepeat`; each repeat adds then removes them as its own undo step.
    Fix: add it to `ignoresRepeat`; test.

16. MEDIUM-LOW: Ken Burns overlay drag state. `KenBurnsOverlay.swift:24,153-173`: one shared `dragOrigin`
    `@State` for both rectangles and all corners, cleared only in `onEnded`; a cancelled DragGesture leaves a
    stale origin and the next drag jumps. Fix: `@GestureState` per rectangle/corner. Also a zero-movement click
    marks the rectangle edited (`minimumDistance: 0`, `KenBurns.swift:797-810`) so it stops following range
    changes: mark edited only on a non-zero translation.

17. MEDIUM-LOW: a duration typed in From playhead with the playhead off the clip is stored as 0 frames
    (`KenBurns.swift:601-618`: `remainingFrames` 0, `requestedFrames = 0`, note "Limited to the 00:00:00:00
    left"); when the playhead returns the span is one frame and Apply sends a zero duration. Fix: refuse via
    `rangeProblem` when `rangeOffset == nil` and store nothing.

18. LOW-MEDIUM: turning a neighbour toggle off resets a rectangle the user moved. `KenBurns.swift:640-641`:
    `continuesFromPrevious = false` runs the `didSet` that clears `editedStart`, so trimming the previous clip
    by a frame discards the user's start rectangle. Fix: a private setter that skips the reset.

19. LOW: `TimingCurve::isValid` (`Keyframes.cpp:122`) accepts x1 > x2 and `splitCurve` (`:170-177`) then clamps
    renormalised control points silently: a loaded Bezier (0.9, 0, 0.1, 1) split at 70% errs by 0.159 of the
    segment's change (48 px on a 300 px move). Engine-made curves are unaffected. Fix: require x1 ≤ x2 (ulp
    tolerance) in `isValid`. Related: splitting through an overshooting custom curve (y > 1 on opacity/scale)
    fails validation with InvariantViolation (`:321` does not clamp the boundary value; the evaluator does):
    clamp it or return a proper error.

20. LOW: `isThroughEdit` (`EditOps.cpp:1808-1818`) reports adjacent stills with identical whole-clip keyframes as
    a through edit (still keyframes are clip-relative, so the move restarts at the cut); only the AddTransition
    note is wrong. Fix: for stills also require `!isAnimated()`.

21. LOW: refusal codes and undocumented paths. Keyframes on an audio clip through SetVideoParams/SetClipsParams/
    placements fail only in `validateSequence` (InvariantViolation, not TrackKindMismatch) and those paths
    accept new keyframes outside the used source range that AddKeyframe/SetMotionTracks refuse
    (`EditOps.cpp:783-795`, `buildClip`). `keyframeTimeRefusal` returns VEEditErrorNotRepresentable, absent from
    VEEngine.h's Motion list (`:417-430`), with an "at the playhead" message even for moveKeyframe's destination.
    `motionParameterFrom` (`VETypes.mm:254`) maps an out-of-range VEMotionParameter to X silently: return
    optional and refuse. Single-parameter `moveKeyframe` (`VEEngine.mm:1985-2015`) finds the keyframe in the
    live model and so fails on step 2 of a ReplacePrevious group (unused by the app; document "not for drags"
    or plan inside the command). `splitClipAt` refuses an animated clip whose cut has no CMTime form
    (`EditPrimitives.cpp`, `notRepresentable`) where `keyframeTimeForFrame` would fall back to the next tick;
    needs a pathological speed ratio; align the two or document.

22. LOW: JSON. Unknown keys under `"keyframes"` are dropped silently on load (`ProjectJSON.cpp:396-410`; an
    unknown interpolation warns): warn. A non-Bezier keyframe with a non-default `curve` compares unequal after
    a save/reload (the serializer writes `curve` only for Bezier; validation does not require the default):
    normalise or validate. The v4 golden test writes the golden file itself when missing.

23. LOW: media folder and sandbox. A trashed Media folder's bookmark resolves into ~/.Trash and imports land
    there (`IncomingMedia.swift:369-374,408-420`; `stale` ignored; access kept started when the writability check
    fails): reject Trash URLs, rewrite stale bookmarks, stop access on the nil path. After New/Open,
    `mediaFolder.reset()` stops the security scope before late pasteboard files arrive, so their deletion fails
    silently (`ProjectStore.swift:1165-1166`): keep the old access until outstanding promises settle.
    `pasteboardPromises()` returns every promise item including ones that also carry public.file-url, and the
    file/promise partition relies on `NSItemProvider` identity across two `itemProviders(for:)` calls
    (`:635-638,655`; unverified for SwiftUI's DropInfo): partition once from the drag pasteboard's items by type.

24. LOW: PHPicker and Live Photo bundles. `PhotosPicker.swift:30-61`: `picker` stays non-nil if the sheet goes
    away without the delegate (the menu item then does nothing, and it is not disabled while shown); the folder
    panel runs modally inside the delegate callback while the sheet dismisses; `suggestedName` is used
    unsanitised in `adopt` (a "/" or ".." breaks the target path; the sandbox limits the reach). The .pvt package
    is moved into Media and the chosen part imported from inside it (hidden in Finder); the other part is
    deleted but the package stays; Cancel leaves an empty .pvt (`IncomingMedia.swift:269-279,595-612`). A second
    batch settling during the Live Photo alert (`runModal` from a main-queue block) nests a second alert, and
    the alert can appear mid-drag: queue questions, defer while `isGestureActive`. The batch is retained by the
    completion closure (`:512-514`, harmless): capture the id.

25. LOW: UI details. The Clip menu's Add/Remove Motion Keyframes title reads the playhead without observing it
    and is enabled off the clip (`FramewrightApp.swift:137-139`). `statusMessage` is assigned on every
    mouse-move of a marker drag even when unchanged (`TimelineGestureController.swift:474`), re-running every
    store observer. The inspector switches between `AnimatedParameterRows` and a plain `ForEach` when a clip
    gains its first keyframe (`InspectorView.swift:224-231`), losing field focus and typed text. `hasUncommittedText`
    compares raw text while the commit trims, so "00:00:02:00 " never lets Return press Apply, and equivalent
    text ("2s") switches Whole clip/Existing move to Custom. Pressing "Ken Burns…" while open replaces the model
    silently; `durationDisplay` is captured at open; Shift-adding a second clip keeps the helper open while the
    inspector hides its controls; `playheadIsOverMotionTarget` is dead code; the marker zone takes the head-trim
    zone in the bottom 11 pt; no accessibility identifiers on corner handles, Smoothing, Cancel.

26. LOW: build/test plumbing. `project.yml:228-246` redeclares Apple-owned UTIs (all four are already declared
    by the system; runtime effect unverified), and the PhotosDropTests `isDeclared`/`!isDynamic` assertions pass
    without the plist entries. `$FRAMEWRIGHT_TEST_MEDIA_DIR` bypasses the script hash, so a stale override lacks
    `slowmo_hevc_portrait.mov`; old hash directories are never pruned; the C++ `slowmoFrameTime` table is kept
    in sync with the script by comment only.

## Done properly (do not redo)
- Evaluation: upper_bound segment choice, exact hold before the first and after the last keyframe, Int128
  fraction with a safe fallback; `splitTrack` in every branch; `splitCurve` for engine-made curves (de Casteljau
  with correct renormalisation); split of stills shifting the right piece; `setTimelineStartKeepingEnd` atomic;
  speed changes leaving source-time keyframes alone; undo/redo by whole-track snapshots; validation of
  NaN/inf/range/order/curve and video-track-only; JSON doubles bit-exact, v3→v4 a true no-op.
- `MoveKeyframeGroup` plans inside `perform` (correct under ReplacePrevious), keeps strict order, refuses crowded
  frames; the marker drag's group key, `cancelActiveGesture`, Escape/abandon/Busy handling, clamping, and
  click-still-seeks; markers from the engine's `frameTime` (correct through speed, hidden ones excluded).
- Facade: `VE_ASSERT_MAIN` on every new entry point; one push per call; honest no-ops; static setters keep
  keyframes; edge-time refusals; `motion(at:)` equals `Scheduler::motionAt`; hidden keyframes filtered by every
  consumer; the error enum appended at the end; the bookmark reset on New/Open, dirty-not-undo, saved beside
  `assetBookmarks`.
- App views: `KeyframeControls` draws from an Equatable state; `ParameterRow`/`AnimatedParameterRows`/
  `KenBurnsOverlay`/`KenBurnsBandView`/`KenBurnsOverlayHost` observe what they draw; no bare class-reference
  view remains. Helper lifetime (selection, clip removal, New/Open, Apply/Cancel) and band forwarding are
  correct; detection never overwrites a Custom range or moved rectangles; every new command has the
  `isGestureActive` guard; Control-K goes through the key monitor that skips `NSText`.
- Photos: Finder URLs never reach a delete path; deletions are limited to files the app received; `adopt` never
  overwrites; `discardAll()` before `mediaFolder.reset()`; security-scope start/stop ordered; item-provider
  promises take the file inside the handler, hop to main, honour "never after cancel", clear KVO; a declined
  folder panel imports nothing; receiving starts on the next main-queue turn; PHPicker configured with
  `.current`, unlimited selection, images/videos/Live Photos, gesture guard; the slow-mo VFR test checks real
  frame identity at 1/240 s boundaries.

## Test gaps
1. Picture preservation on every frame for Add/Toggle/SetMotionValue-add inside Hold and eased segments
   (finding 1); the tick-fallback frame's rendered value after a Hold (5); a value edit on a split out-point
   keyframe and on a 1.5x clip (4).
2. Nested splits (a Bezier piece split again; non-frame-aligned and near-0/1 fractions), a split of an animated
   clip at speed ≠ 1, an overwrite inside an animated clip, ripple/MoveClip onto an animated clip, a still split
   on a keyframe, still head trims forward/back and past all keyframes then re-extended, undo of each checked by
   picture. Curve edge cases (x1 > x2, y overshoot). SchedulerTests and the splitCurve test compare against the
   implementation's own evaluator; only KeyframeTests.cpp:99 has an independent reference.
3. Facade: stills (keyframes, head trim, Ken Burns on a still); an Accumulate burst of setMotionValue; a marker
   drag returning to its origin; a crowded frame through `keyframeGroup`; toggle/Ken Burns/match/removeAnimation
   with another group open; NotRepresentable and an out-of-range parameter; bookmark: Open without the key after
   one with it, Save As, malformed base64; duration rounding at .5 frames; whole-clip Ken Burns on a two-frame
   clip; a real movement check in the parity test (13).
4. App: the loader across three landings and a failed fetch; redraw counts with the overlay hosted (the band test
   can `XCTSkip` silently and polls); typed field text surviving a save/model change and `commitFields()` with
   two fields typed; a neighbour disappearing after an edited rectangle; a zero-movement click; overlapping
   rectangles; From playhead off the clip with a typed duration; marker drag `abandon()`/outside-window, a
   crowded frame at app level, an out-point keyframe after a split, the zone near trim edges; held Control-K;
   the Clip menu title after the playhead moves. `testKeyframeControlStateFollowsEveryEdit` checks the state
   struct, not a rendered view; `testControlKIsAddMotionKeyframe` checks the mapping, not the monitor.
5. Photos: `PasteboardFilePromise` has no tests at all (count, reader error, cancel after partial delivery,
   deallocation while pending); item-provider error; cancel between adopt and the main hop; `FakePromiseProvider`
   completes twice (real providers do not); `ScriptedPromise.cancel()` drops its completion so "never after
   cancel" holds by construction; the real-sandbox "cannot create Media" panel path; stale/Trash/failed
   bookmarks; Save As; Live Photo Cancel and the false-positive pair; same-name collisions; placement with a
   deleted track, an edited sequence, a gesture on arrival, a drop off the tracks; DocumentController with
   `incoming.isReceiving`; a non-media promise; the vacuous plist test.

## Deviations
Premiere semantics outside the keyframes (hold first/last) and the stopwatch behaviour for typed values
(documented); Existing-move detection takes the whole span when several moves exist (documented); dragging a
marker no longer moves the clip (documented); Start/End/Duration always editable (documented); Photos assets
appear in the bin only when the whole batch settles (documented, and the root of finding 2's cross-item pairing).
All acceptable except where the findings above say otherwise.
