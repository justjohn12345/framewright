# Effect lanes review (2026-09-24)

Reviewer: Claude (lead) with one read-only Opus reviewer (which split its reading into engine model/edit ops,
serialization/audio, and app), plus the user's hands-on notes with screenshots from the round 2 build. Scope:
commits 65999f5..292f060 (the plan, round 1 engine, round 1b hold-after, round 2 app; 17 commits). The lead
verified C1, H2, H3, H4 and M1 by reading the cited code; items marked "(reviewer)" rest on the reviewer's
reading, "(reproduced)" on a scratch run it made. Tree state: full scheme green (447 EngineTests incl. 222
doctest cases, 197 AppTests), zero warnings, all 447 EngineTests clean under ThreadSanitizer (lead's run).

## Summary
One CRITICAL: the Ken Burns editor assumes a full-frame clip. On a picture-in-picture clip (static scale 0.3 at the
lower right) it draws the picture full size and the rectangles many frames wide, and the first drag stores a
relative scale of about 8, destroying the picture-in-picture. Four HIGH: a valid schema-4 project can refuse to
open after migration (a fade out reaching into an incoming crossfade); Escape or Undo in the middle of a Ken
Burns drag is undone by the next mouse movement; a refused transition drop leaves its red preview pill and the
lane-0 reveal on screen for good; and dropping a Cross Dissolve near a lone clip's free edge silently becomes a
fade, so the second drop reports "already has a transition". Eight MEDIUM cover silent drops of transitions and
spans by edits, a dissolve changing partner after a ripple delete, fades deleting incoming crossfades, the scroll
wheel changing axis, the missing vertical scroll bar, mid-drag row shifts from the lane-0 reveal, the redraw
budget during Ken Burns drags, and loading that refuses instead of repairing. The user's notes 6-8 (compact
rows, a user-owned preview/timeline split, restoring the window frame) are design items with concrete plans.
The core holds: same-lane overlap refused on every path, held-value folding on every trim path, exact time bases,
transition limits and linked pairs, the audio law, migration proofs, one push per facade call, exclusive
selection, coalesced drags with Escape.

## Status after the fix round (2026-09-25)
The fix round (fef92be..02eebd3, 26 commits, one Opus implementer; verified by the lead: full scheme 448 EngineTests
incl. 234 doctest cases, 224 AppTests, zero warnings, EngineTests clean under ThreadSanitizer) closed C1 on the app
side, H1-H4, M1-M8, L1-L11, D2 and test gaps 1-6. The API changes and the by-hand checklist are in
`integration-notes.md`, "Effect lanes review fix round". The findings below are kept as written for the record;
what is still open:

- **C1, engine part (a user decision).** The editor now frames a placed clip inside its own window, but the engine
  has no crop: a zoom in on a picture in picture still enlarges it about its centre instead of cropping inside its
  box (the default push-in grows 0.3 → 0.375). A true crop needs the window quad on `VideoLayer`, the compositor
  scissor, spans composing in window space, the migration change and a static crop field (schema 6), as the C1
  text describes.
- **D1, compact rows.** Not started; the plan under "Design items" stands.
- **D3, window frame restore.** Not started; the plan under "Design items" stands.
- **Test gap 3, the render goldens.** They cannot be re-recorded (the recording tool needed the schema-4 engine);
  the opacity-only and curve-cut cases are checked against version 4's rule computed independently instead.
- **By hand, not yet done** (the test host cannot drive these): real Ken Burns drags on a 30 % lower-right, an
  offset and a turned clip (the dashed window outline and caption, the monitor following); Escape and Cmd-Z
  mid-drag then moving before release; a Cross Dissolve dragged onto a locked track, a cut without handles and a
  lone clip's end (the pill clears, lane 0 opens only under the pointer, the "Fade" preview and the "No clip
  follows" note); the wheel on a notched mouse (time; Shift or the headers for tracks) versus a trackpad (both
  axes); the vertical scroll bar appearing, dragging and disappearing with no blank space left; the divider (240 pt
  minimum for the monitors, the grip on hover, double-click fits once, lanes never resize the panes, the height
  persists); clips and the playhead exactly under the ruler at several zooms; Control-K with a locked or hidden top
  track and twice on one frame; the status wording after a real ripple delete, trim or move removes a fade or
  dissolve.

Small choices made in the round, recorded so they are not mistaken for oversights: a refused drop returns `.copy`
(the red preview says why); the H4 fallback only moves between free edges, never from a cut to a fade; `setClipFade`
refuses an over-long fade out with the room it has rather than clamping; `refreshModel` does not clamp scroll
during a gesture; M8 repairs by moving a span to the first free effect lane (composition is add and multiply, so
only the last floating-point bit can differ) and still refuses no free lane, an inexact time and a keyframe without
a value; a divider drag may pass 60 % of the window while the monitors keep 240 pt, fits are capped at 60 %; L6 only
avoids stacking on the same frame; undoing a track deletion does not restore its lane-collapse state.

## Ranked findings

### CRITICAL
C1 (user note 5). The Ken Burns editor on a scaled-down or offset clip draws huge rectangles, and the first drag
destroys the picture-in-picture. `App/State/KenBurns.swift:185-198` (`readFramings`) takes the edge's composed
motion (static values with spans applied) and `:548-559` (`rect(for:)`) turns it into a full-frame crop
(width = frame width / scale, centre = centre − offset / scale), while the picture is drawn fitted at scale 1
with no offset (`pictureBounds`). Numbers for a portrait still fitted to 810×1080 with static (x 690, y 324,
scale 0.3): the neutral start rectangle is 6400×3600 centred at (−1340, −540); the default push-in end is
5120×2880 (matches the user's screenshot). The first drag step clamps the width to `maximumWidth` (810), i.e. an
absolute scale of 1920/810 = 2.37, stored as a relative scale of 7.9: the picture-in-picture becomes a 2.37×
full-frame crop covering V1; Swap and the neighbour toggles do the same. No test has a static scale below 1.
Fix (app, Final Cut's model: a crop of the clip's own picture inside the clip's current framing): keep drawing
the whole picture; show the clip's window (static framing S applied to the frame box) as an outline and a caption
("Inside the clip's framing: 30 %, lower right"); express the edge motion M relative to S:
Φ = (R(−θs)·(xm − xs, ym − ys) / ss, sm / ss, θm − θs), rectangles from `rect(for: Φ)`; write back M' =
(xs + ss·R(θs)·Φ'.xy, ss·Φ'.scale, θs + Φ'.rotation) then `relativeFraming(M', base:)`. For an identity static
framing this is today's math, so existing tests hold; the neighbour test's 1.5/1.2 statics change meaning:
update it and add a scale-0.3 lower-right case. Remaining gap and a user decision: the engine has no crop, so a
zoom-in still enlarges the picture-in-picture about its centre instead of cropping inside its box (the default
push-in grows it 0.3 → 0.375). A true crop needs: a window quad on `VideoLayer` from `Scheduler::motionAt` that
the compositor scissors to; motion spans composing in window space (x = xs + ss·R(θs)·Σxk, s = ss·Πsk); the
migration dividing by ss for animated positions on non-neutral statics with a render test; and a static crop
field for `fitSpans` to fold into (schema 6).

### HIGH
H1 (reviewer, reproduced). A valid v4 project can fail to open. `Engine/Serialize/ProjectJSON.cpp:1004-1060`
migrates an audio clip's fade out as a tail span even when an incoming crossfade reaches into the clip (v4
allowed both and multiplied them); `Validation.cpp:356-361` then rejects the crossfade ("transition 16: meets
the transition at the end of clip 14"; reproduced with clip 14's fadeOutDuration = 57/30 in the render golden).
Fix: limit the migrated fade out to duration − ceil(n/2) of the incoming crossfade's frames with a warning, as
the fade in already is; migration test.

H2. Escape or Cmd-Z in the middle of a Ken Burns drag is undone by the next mouse movement.
`KenBurns.swift:250-262`: `cancelDrag` clears `isDragging`, the SwiftUI DragGesture keeps running, and the next
update calls `applyDrag` → `beginDrag`, which opens a new `kenBurns.drag` group and writes origin + translation;
the release commits it as an undo step. Fix: a `dragCancelled` flag honoured by `applyDrag` until the gesture
ends. Test: apply, cancel, apply, end: values unchanged, no undo step.

H3 (user note 3, the red pill). A refused transition or effect drop leaves its preview pill and the lane-0
reveal on screen for good. `TimelineRenderer.swift:337-358` draws `transitionDrop`'s message in red at the cut;
`transitionDrop` is cleared only in `transitionDragExited` and `dropTransition`
(`TimelineGestureController.swift:943, :954`). A refused target makes `handleUpdated` return `.forbidden`
(`TimelineView.swift:403-406`), so `performDrop` never runs, and `dropExited` did not run either (the
screenshot). `revealTransitionLane` also stays on: lane 0 stays shown on every video track and the fitted
timeline stays taller. `effectDrop` has the same bug. Fix: return `.copy` even when refused (the red preview
already says so) so `performDrop` always runs and clears; defensively clear a stale preview and the reveal on any
hover or press in the track area; tests through `TimelineDropInfo`.

H4 (user note 3, the fades). A Cross Dissolve dropped within 40 pt of a lone clip's free edge becomes a fade in
or fade out (`TimelineGestureController.swift:971-974`, `SpanEditing.swift:551` `addFade`); the purple bars
under the still are those fades (↗ fade in, ↘ fade out, `TimelineViewModel.swift:124-125`). The next drop near
that edge is refused with "“x” already has a transition at its end", truncated by the pill. Fix: say what the
user sees ("“x” already fades out: drag the fade's edge to lengthen it, or delete it"), fall back to the other
free edge when in reach, label the preview "Fade" in the dissolve's colour so the conversion is obvious, and on a
lone clip say "No clip follows: this adds a fade to black".

### MEDIUM
M1. The engine's drop reports are ignored by the app (`grep droppedTransitionIDs|droppedSpanIDs App` is empty).
A head fade that a move, ripple, insert, overwrite or tail extension makes touched is erased by
`normalizeSequence` before validation (`EditPrimitives.cpp:345-365`), so nothing invalid leaks but the fade
vanishes silently; so do dissolves lost to trims and speed changes, and spans folded into static values (whose
inspector values change). Fix: turn non-empty dropped lists into a status note ("Removed the fade in on “B”: “A”
now touches its start"; "The Motion span before the new start was folded into the clip's values").

M2 (reviewer). A dissolve silently changes partner after a ripple delete, insert or overwrite: v5 owns the
transition on the left clip only and `placeTransition` takes whatever now touches its end. A|B|C with an A→B
dissolve, ripple-delete B: an A→C dissolve results, unreported (v4 dropped it); the linked crossfade follows.
Fix: in `SequenceCommand::apply`, record span id → partner clip before `perform`; after `normalize` drop and
report any dissolve whose partner changed (splits keep the id).

M3 (reviewer). Setting or trimming a fade out deletes the crossfade coming into that clip: `setClipFade`
(`EditOps.cpp:1585-1651`) and `fitSpans` ignore an incoming dissolve's part inside the clip, and `normalize`
keeps the fade and drops the crossfade (B 90 frames with a 15-frame incoming crossfade; an 80-frame fade out
succeeds and the crossfade is gone). Fix: room = duration − incoming span's end in `setClipFade`,
`fadeLimitFrames` (`VEEngine.mm:2362`), `offsetsFor` (`:2729`) and the inspector limit
(`InspectorModel.swift:304-307`); `normalize` shortens the fade rather than dropping the dissolve.

M4 (user note 1). The scroll wheel changes meaning when the tracks stop fitting: `TimelineView.swift:276-291`
scrolls Y when `tallContent`, else X; adding lanes flips it. Fix: a fixed mapping (a notched wheel always scrolls
time; Shift or over the headers scrolls tracks; a trackpad scrolls both axes from its own deltas; pass
`hasPreciseScrollingDeltas` through `ScrollWheelCatcher.Scroll`).

M5 (user note 2). No vertical scroll bar, and `scrollY` is never re-clamped: `TimelineView` has only the
horizontal bar (`:293-316`); `clampScroll` runs only on wheel events (`:266-271`), so collapsing lanes, deleting a
track or growing the window leaves top rows hidden with blank space below. Fix: a vertical bar on the trailing
edge of the track area when the content is taller than the canvas (knob = canvas / content, drag sets
`store.scrollY`; the headers already follow it); clamp X and Y in `refreshModel` and on canvas size changes.

M6. Revealing lane 0 during a transition drag shifts rows under the pointer and resizes the window:
`transitionDragUpdated` reveals lane 0 on every track of the kind, then hit-tests with the new geometry, and
`ContentView` fits the timeline height to `timelineContentHeight`, whose key includes the reveal, so each track
gains 14 pt mid-drag and the target can jump tracks while the monitor shrinks. Fix: reveal only on the row under
the pointer and target by the pre-reveal geometry; D2 removes the auto-resize.

M7 (reviewer). The redraw budget regressed during Ken Burns drags: the cache key is `changeCount`
(`ProjectStore.swift:352`), so every drag step rebuilds the timeline model, redraws the canvas thumbnails and all
headers, and re-renders `SpanInspector` (about 8 `getBaseValues` calls). The deleted
`testAKenBurnsRangeChangeRedrawsOnlyItsBand` has no replacement. Fix: key the content cache on a digest of what
is drawn (clips, span ranges, lanes, flags), plus a bounded-builds test per drag step.

M8 (reviewer, reproduced). Loading refuses rather than repairs: a v5 file with unsorted spans, a touched head
fade, lane 4 or a null keyframe value fails to open; `parseClip` never calls `sortSpans`. Fix: in
`projectFromJson`, run `sortSpans` and the `normalizeSequence` transition pruning before `validateProject`, with
warnings.

### LOW
L1 (user note 4). The playhead line is 1 pt right of the ruler triangle: the track row is
headers(170) + Divider (1 pt) + trackArea while the ruler row has no divider (`TimelineView.swift:78-83`), so
clips, the playhead line, hit x, the zoom anchor and the scroll-bar row are all 1 pt right of the ruler. Fix: the
divider as an overlay on the headers, or the same 1 pt in the ruler and scroll-bar rows.
L2 (reviewer). The overlay can show stale derived text: `span` and `clip` are unpublished (`KenBurns.swift:89-90`)
while `caption`, the neighbour toggles and `pictureSeconds` read them; publish them from `update`.
L3 (reviewer). Typing 100 % "before cut" (or nudging to the limit) turns a dissolve and its linked crossfade into a
fade out (`InspectorModel.swift:706-742`); clamp each side to [0, total − 1] frames with a note.
L4 (reviewer). Span body drags and trims are limited by the clip only, so a fast drag stops short of a neighbour
span with a gap; use `spanLimits`.
L5 (reviewer). Sliding a fade out's bar can only be refused; refuse it up front as a fade in's is.
L6 (reviewer). Control-K targets a locked or hidden top track, gives a misleading message with two video clips
selected, and repeated presses stack push-ins (1.25³).
L7 (reviewer). Lane collapse keyed "V<n>" moves to another track when a track is deleted; spans on collapsed lanes
can be selected and edited invisibly (expand the lanes when one of the track's spans is selected).
L8 (reviewer). `syncKenBurns` repeats a failed open on every model change (rebuilds the loader, rewrites the status
line); remember the failed span id.
L9 (reviewer). Engine lookups per read: `selectedTransitionID` / `InspectorModel.transition` make about 10 engine
calls per inspector body; `makeEffectSpan` runs a `linkedTransition` scan per transition span during model builds.
L10 (reviewer, unverified in practice). A gain span edge rounded to a tick can leave a whole first piece without
the span (`Scheduler.mm:319-339`; decide activity at the piece midpoint); the eased-gain step loop scans the whole
span for every short plan window (`:300-311`).
L11 (reviewer). Migration changes that are only warned about (the fade-in drop and shortening) are not
render-tested; check that the app shows load warnings.

## Design items (user notes 6-8)
D1 (note 6). Compact rows as in Resolve: a "Compact Tracks" toggle (View menu, timeline corner) and per-track
compact rows when lanes are collapsed: about 22 pt video / 20 pt audio with the clip name only, a 3 pt strip at
the clip's bottom marking spans and transitions in their kind colours (click expands the lanes), a one-line
header (name, eye/mute, lock; solo and target in the context menu). Files: `TimelineViewModel` (a `Track.compact`
flag, row heights, `lanes()` empty when compact), `TimelineRenderer` (compact clip + marker strip),
`TrackHeaderView`, `WindowLayout` (persist next to `collapsedLaneTracks`), `ProjectStore` (cache key),
`TimelineGestureController` (trim zones on 20 pt rows; no span hits when collapsed), redraw and lane tests.
D2 (note 7). A user-owned split between preview and timeline: today `timelineHeight == nil` means "fit to
content", and every lane (and the lane-0 reveal) adds 14 pt up to 60 % of the window, squashing the monitor.
Make `timelineHeight` non-optional, set once on first launch from the fitted rows without lanes; double-click on
the divider is a one-shot fit that stores a value; never re-fit automatically; lanes scroll inside the timeline
(M5's bar); monitors keep at least 240 pt; a visible grip on hover; `ContentView` stops reading
`timelineContentHeight` (which also removes M6's mid-drag resize). Files: `WindowLayout.swift` (a stored nil
migrates to a value), `ContentView.swift`, `PaneDivider.swift`, `TimelineView.swift`, the layout tests.
D3 (note 8). Restore the window frame, clamped to the displays present: nothing persists the frame today (SwiftUI
`Window`, `FramewrightApp.swift:20`, no autosave). Save the frame and its screen's frame under a
`WindowLayoutModel` key on resize/move (debounced, through `WindowAccessor.CloseGuard`) and on close. Restore
once on first attach: the screen containing the saved centre, else main; width/height = min(saved, visible),
not below 1100×640 unless the display is smaller; shift inside the visible frame; `setFrame`. Re-clamp on
`didChangeScreenParametersNotification`. Set `isRestorable = false` so SwiftUI restoration does not fight it.
A pure `restoredFrame(saved:savedScreen:screens:minimum:)` unit-tested for external-monitor → laptop.

## Done properly (do not redo)
- Same-lane overlap refused on every path (AddSpan, SetSpanRange with the nearest free range excluding the span
  itself, MoveSpanLane, split, validation of order and overlap). Held-value folding on head trim, a split's right
  piece, clearRange (overwrite, MoveClip(s)) and inserts' splits; undo restores static values bit for bit.
- Source-time spans and sequence-time transition offsets never mixed; stills, speed and NTSC tick edges covered
  against the independent `SpanReference.h`. `transitionSideLimits` agrees with `checkTransitionSpan`; linked
  transitions fitted per cut with notes.
- Audio: the v4 gain law preserved (migrated fades stay linear gain; only Gain spans use the dB ramp; the mixer
  applies the same law per sample so 1/240 s sampling is a valid proxy; expectations recomputed independently);
  asymmetric dissolves, fades and the 70/30 constant-power crossfade tested frame by frame; export parity covers
  the plan's cases. Migration keeps transition ids and honours nextId; hold, eased, hidden-by-trim and still
  keyframes are render-proven.
- Facade: span calls assert the main thread and push one command; `getBaseValues` returns NO for a missing span,
  a transition or a bad frame duration; a zero base is refused in the app.
- App: clip and span selection exclusive; a removed span deselected; `resetUIState` on New/Open; span, trim and
  transition drags in Replace groups with `cancelActiveGesture` and a cancelled state; range creation on release
  in one Accumulate group, nothing under two frames; snapping to span edges only with `excludingSpans`; lane hit
  regions disjoint from trim zones; Delete of a linked transition with its partner; Escape order; drag types
  declared; the latency test skips on Bluetooth with the value logged.

## Test gaps
1. Ken Burns: a static scale below 1 or an offset (C1); cancel then further movement (H2); model builds and canvas
   draws per drag step (M7); the picture at speed ≠ 1 and on a still (the deleted speed test has no replacement).
2. Drops: a refused drop followed by no perform: pill and lane-0 reveal cleared (H3).
3. Migration: a fade out under an incoming crossfade (H1); render assertions for the warned fade-in drop and
   shortening; an opacity-only clip and a Bezier cut at a clip edge in the render goldens; the golden recording
   tool is not checked in, so the goldens cannot be re-derived.
4. Engine edits: ripple/insert/overwrite at a cut with a dissolve (M2); a fade out against an incoming crossfade
   via params, fitToCut or a tail trim (M3); a head fade dropped by insert, ripple, overwrite or tail extension
   (only MoveClip is tested); SplitClip folding with two spans on one lane; MoveClips onto a spanned clip;
   `getBaseValues` with a zero-scale base and the app's refusal path.
5. Loading: v5 files with unsorted spans, a touched head fade, equal starts on one lane; pin the policy (M8).
6. Timeline: lane-0 reveal with two video tracks (which row a fixed pointer targets); where a span drag stops next
   to another span; the 100 % share; Escape during a transition drag (the old test was removed); linked
   transitions with asymmetric shares through the gesture; Control-K with a locked top track; `scrollY` clamping
   after lanes collapse.

## Deviations
Migrated spans cover the clip's whole source range (justified: holds outside the keyframes); span values stored
relative and cumulative with absolute display (justified; C1 shows where the display model breaks); dropping a
dissolve on a free edge makes a fade (H4: keep, but make it visible); dragging a marker moves keyframes no longer
applies (markers are gone); `getBaseValues` added in an app round (justified). All acceptable except as the
findings say.
