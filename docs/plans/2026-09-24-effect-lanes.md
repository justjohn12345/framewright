# Effect lanes and spans (plan, 2026-09-24, agreed)

## Goal
Every track gets effect lanes beneath it. An effect is a span: a visible time range on a lane, attached to a
clip, with start and end values for what it changes. Selecting a range on an empty lane creates a span; for a
video track that opens the Ken Burns editor over that range. The inspector shows the span's range and its start
and end values. Spans on one lane never overlap; spans on different lanes may, and their effects compose. A
transition is a span across a cut, so its share of each side (70/30) is set by dragging its edges. This replaces
the per-parameter keyframe diamonds and the Ken Burns range controls as the user-facing model; the engine's
keyframe machinery (exact evaluation, curve split, group move) is reused inside spans.

## Model (schema v5)
- `EffectSpan { id, clipId, lane: int, kind, range, tracks, interpolation }`.
  - `kind`: `motion` (position/scale/rotation), `opacity` (video fade), `gain` (audio level/fade), `transition`
    (see below). One kind per span; a span holds the keyframe tracks of its kind's parameters only.
  - `range`: clip-relative, in the clip's source-time base as keyframes are today (so trims keep a span on its
    pictures, speed changes move it with them, a still's spans are clip-relative). Clamped to the clip.
  - `tracks`: `MotionKeyframes`-style tracks whose times are relative to the span's start; initially exactly a
    start and an end keyframe per parameter (the inspector edits "start value / end value"); more keyframes are
    allowed by the model for later (a drag-out midpoint) but not exposed in this phase.
  - `interpolation`: the segment's easing (hold/linear/ease in/out/in-out), as the Ken Burns smoothing today.
  - Invariants: spans of one clip on one lane never overlap; lane ≥ 0; a span lies inside its clip's source
    range (a trim that cuts through a span clips its range, the values at the new edge evaluated, like the
    keyframe split today; extending the clip does not restore it).
- Composition (fixed, documented, tested; hold after, decided 2026-09-24, round 1b): an effect span contributes
  nothing before its start, animates over its range and holds its end value from its end until the clip ends (also
  in a tail transition handle); there is no toggle and no model field. For a frame, start from the clip's static
  `VideoParams`, then apply every span that has started, at its value at min(frame time, its end), in lane order
  and within a lane in start order: position adds, rotation adds, scale multiplies, opacity multiplies (gain adds
  dB). A later span on the same lane therefore applies on top of the value the earlier one holds (chained spans are
  cumulative: one starting neutral continues without a jump), and two motion spans on different lanes combine (a
  zoom-out with a pan); two on one lane cannot overlap. A 5 s move from 5 s on a 30 s clip shows the clip's framing
  for 0-5 s, the move over 5-10 s and the end framing for 10-30 s. A span a trim or split leaves wholly before a
  clip's start hands its held value to that clip's static values, so no remaining frame changes.
- Lanes: every video and audio track has at most 4 lanes. Lane 0 is reserved for transitions; lanes 1-3 hold
  effect spans (motion, opacity, gain). A span's lane is part of the model; the app refuses a fifth.
- Transitions are lane-0 spans attached to a clip (kind `transition`; video: cross dissolve, fade from/to black;
  audio: crossfade, fade in/out). A transition span at a clip's tail covers a range from inside the clip past its
  end: the part after the end overlays whatever comes next (the touching next clip: a dissolve/crossfade whose
  share of each side is the range's split at the cut; nothing touching: a fade out to black/silence). A span at a
  clip's head is allowed only when nothing touches the clip's start: a fade in from black/silence. The share on
  each side is limited by the two clips' handle media (`transitionLimit` today; the fade-to-black side has no
  limit but the clip's own length). One transition per cut, owned by the outgoing (left) clip; the incoming clip
  never owns a span across that cut. Linked A/V pairs keep linked transitions (same range relative to the cut);
  the existing centred transitions migrate to a centred lane-0 span on the outgoing clip.
- Clip keyframe tracks (v4) migrate: per clip, the x/y/scale/rotation tracks become one `motion` span from the
  earliest to the latest keyframe (lane 0) and opacity becomes an `opacity` span (lane 1 if it overlaps); the
  values before/after hold as today. Audio `fadeIn`/`fadeOut` migrate to lane-0 fade in/out transition spans
  (they are fades to silence); `gainDb` stays the clip's static level and `gain` spans (lanes 1-3) ramp it.
  v4 files load unchanged in meaning; the golden v4 file is kept as a migration test.

## Engine
- `Scheduler::motionAt` evaluates spans (composition above) into the layer transform and opacity; the dissolve
  and the fades use the lane-0 span's range (mix fraction at the frame centre as today; black/silence as the
  missing side). The audio mixer's fade envelope and crossfade law read the same spans. Export and playback
  share it (parity tests: two effect lanes on video; an audio crossfade with a 70/30 split; a fade from black).
- Edit ops (single SequenceCommands, coalescing-friendly): `AddSpan` (range, kind, lane, default values from the
  clip's framing at the range's edges), `SetSpanRange` (trim an edge / move within the clip; refused on overlap
  with a reason and the nearest free range), `SetSpanValues` (start/end per parameter), `SetSpanInterpolation`,
  `MoveSpanLane` (lanes 1-3 only), `RemoveSpan`, `SetTransitionRange` (asymmetric; fits to the handles, notes a
  shortening; a range that no longer crosses the cut becomes a fade to black/silence and says so).
  Split: a span cut by a split is divided exactly (the existing split math); each half keeps its lane. Ripple,
  move, overwrite: spans follow their clip; a clearRange through a span trims it.
- Facade: `VEEffectSpan` info (range as timeline times too), the calls above, `spans(forClip:)`, `lanes(forTrack:)`
  (the number of lanes to draw = max used lane + 1, at least 1), `addMotionSpan(clip:range:)` returning the span
  for the Ken Burns editor, `applyKenBurns(span:start:end:interpolation:)` replacing the ranged call.
- Remove: `AddKeyframe`/`RemoveKeyframe`/`MoveKeyframeGroup`/toggle/match as public API (their internals move
  under spans; `Match Previous/Next` becomes "match the neighbour span's edge value", kept in the inspector).

## Timeline UI
- Under each track, its lanes: lane rows (about 14 pt); lane 0 is drawn when the track has a transition (or on
  hover/drag of a transition), effect lanes 1-3 are drawn for the used ones plus one empty lane for creating
  (never more than 3); collapsible per track (a disclosure in the track header); the fitted timeline height and
  the empty-track collapse account for lanes; the model cache is keyed by spans and lane counts (redraw budget
  tests extended). Audio tracks get the same lanes (lane 0 crossfades/fades, lanes 1-3 gain spans).
- A span is a rounded bar with its kind's icon and a label (Motion, Fade, Cross Dissolve); selected with a click
  (inspector shows it), body drag moves it within its clip, edge drags trim it, Delete removes it, all through
  coalescing groups with Escape. Snapping to the playhead, cut points and other spans' edges (the timeline's
  snapping helper).
- Range selection on an empty lane (drag) creates a span: a video lane gets a `motion` span and opens the Ken
  Burns editor over that range (its bar shows the range; Apply writes the values, Cancel removes an untouched
  new span); Option-drag creates an `opacity` span (or choose the kind from the Effects tab and drag it onto a
  lane); an audio lane creates a `gain` span. The band the helper draws today becomes the span itself.
- Transition spans live on lane 0, straddling the cut from the outgoing clip; their edges are draggable
  independently (asymmetric); dragging the whole span slides the split; a span dragged to a clip's tail with no
  neighbour is a fade to black, at a first clip's head a fade from black. The Effects tab's transitions drop onto
  lane 0 (or onto the cut as today, which places them on lane 0). The transition handles drawn on the clips
  today are removed in favour of the span.
- Context menu on a span: Set Interpolation, Move to Lane, Remove. Selecting a motion span opens the Ken Burns
  editor (see below), so there is no separate Edit command.

## Inspector
- A span section replaces the keyframe controls: kind, range (Start/End/Duration fields, editable, clamped to the
  clip and free space), interpolation, and per parameter a Start and an End value (Position X/Y, Scale, Rotation
  for motion; Opacity for fades; Gain in dB for audio), plus "Ken Burns…" for motion spans and Match
  Previous/Next. A transition span shows its kind, duration, and the share on each side (e.g. 70% / 30%), editable.
- The Video section keeps the clip's static values (what a span composes onto). The diamonds, previous/next and
  the interpolation menu per parameter go, and Control-K becomes "Add Motion Span at Playhead" (a default 5 s
  span, or to the clip's end if shorter).

## Ken Burns editor
- Opens on selection: clicking a motion span in a lane (or selecting it any other way, e.g. after creating it by
  range-drag) shows the Ken Burns editor over the program monitor for that span; selecting another span switches
  it; deselecting, selecting a clip, or Escape closes it. Opacity and gain spans show a small on-monitor readout
  (start → end value) rather than rectangles; the inspector is their editor.
- Live, not modal: every rectangle drag or corner drag writes `SetSpanValues` as it moves inside a coalescing
  group (one undo step per drag, like the timeline drags); the range fields edit the span directly. There is no
  Apply or Cancel: Undo (Cmd-Z) reverts the last drag, Escape mid-drag cancels that drag. The bar keeps
  Smoothing, Swap and the neighbour toggles. The existing-move detection, Move menu and duration logic are
  removed. The preview follows the playhead as now (own loader; while a span is selected the playhead is clamped
  to the span's range for the preview picture). Neighbour toggles read the adjacent clip's edge values.

## Decisions (2026-09-24)
- At most 4 lanes per track (video and audio). Lane 0 is reserved for clip-to-clip transitions and the
  black/silence fades; lanes 1-3 for effect spans.
- Transitions attach to the outgoing clip and hang off its tail over whatever comes next; a head span is only a
  fade in from black/silence when nothing precedes the clip.
- Audio gets the same lanes and spans; audio crossfades and fades are lane-0 spans; the existing fade in/out
  migrate there.
- The per-parameter keyframe diamonds, previous/next navigation and per-parameter interpolation menus are
  removed outright; spans are the only user-facing model.
- Selecting a motion span opens the Ken Burns editor, and the editor is live (drags edit the span with undo per
  drag; no Apply/Cancel).

## Out of scope for this phase
Multi-keyframe spans in the UI, audio automation curves beyond a gain span, per-span effects beyond
motion/opacity/gain/transition, stacking several transitions on one cut, more than 4 lanes.

## Rounds
1. Engine: model v5 + migration, composition, scheduler, edit ops, facade; tests (migration of v4 goldens,
   parity with two lanes, split/trim/ripple through spans, transition alignment limits, undo).
   1b. Engine follow-up: the hold-after rule above (composition, the audio level, the Ken Burns edges, matching,
   trims and splits past a span), the Ken Burns caption; the migration renders unchanged.
2. App: lanes in the timeline (drawing, creation by range, move/trim, transition spans, snapping, collapse,
   redraw budget), inspector span section, Ken Burns bound to spans, Control-K, Effects tab drag to lane;
   removal of the diamonds/range controls/marker drags; tests.
3. Review round (adversarial, per the reviews convention), then a fix round.
Each round is one Opus 5.5 high implementer; the lead verifies (full scheme, reads) between rounds.
