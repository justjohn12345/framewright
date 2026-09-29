# Reverse, speed in the inspector, wipe and iris transitions (plan, 2026-09-27)

**Done (2026-09-27).** All three items are implemented; the notes, the tests and the deviations (the fixed mirror of
reverse, the unknown-kind warning, the glyphs' direction, the speed row's existing parts) are in
`docs/reviews/integration-notes.md`, sections "Wipe and iris transitions", "Speed in the inspector" and "Reverse".

## Goal
Three user requests: reverse a clip; a quicker way to set playback speed; more transitions (wipe left, right,
up, down; a circle expanding from the centre). Speed itself exists (Clip > Speed/Duration…, Cmd+R; the engine
accepts 1 % to 10000 % as an exact ratio), so that item is an inspector control over the existing op. The order
of work is transitions, then the speed control, then reverse (the largest; it touches the model, the scheduler,
audio, thumbnails, export and the JSON schema).

## 1. Transitions: wipes and iris

### Model
- `TransitionKind` gains `WipeLeft`, `WipeRight`, `WipeUp`, `WipeDown`, `Iris` (circle expanding from the
  centre). `nameOf` gives `wipeLeft`, `wipeRight`, `wipeUp`, `wipeDown`, `iris`; the JSON parser accepts them and
  refuses unknown names with the existing error path. No schema bump for this (a v5 file that never used them
  is unchanged; reverse below bumps the schema anyway, so the kinds land in v6's documentation).
- The kind is a property of the span, editable: `SetTransitionKind(spanId, kind)` as an undoable command, the
  linked audio crossfade unaffected (audio keeps the constant-power crossfade or the fade). Roles are unchanged:
  a wipe across a cut is a `CrossDissolve` role with a wipe kind; at a free edge it is a `FadeIn`/`FadeOut` role
  with a wipe kind (a wipe from or to black).
- Direction naming: `WipeLeft` means the incoming picture enters from the right edge and its edge travels left
  (the reveal line moves left), as Premiere's "Wipe" with direction "west" does. Document it in `Transition.h`
  with one sentence per kind and keep it consistent in the Effects tab's tile descriptions.

### Rendering
- `LayerTransition` carries the kind (it already has the field) and `mix` (linear progress at the frame's
  centre, unchanged). The compositor passes the kind and progress to the pair draw and to the single-layer
  fade draw through `VEDrawUniforms` (use `reserved`: x = kind as float, y = feather in sequence pixels).
- The fragment shader computes a per-pixel reveal `m(p, progress)` in sequence pixels (origin top-left):
  - cross dissolve: `m = progress` (today's path, bit-identical: keep the branch that does exactly `mix(A, B,
    progress)` when the kind is the dissolve so the existing pixel tests hold);
  - wipe left: `m = smoothstep(edge - f, edge + f, W - p.x)` with `edge = progress * (W + 2f)` shifted so that
    progress 0 shows none of B and progress 1 shows all of B including the feather; wipe right, up and down by
    symmetry (x mirrored, y for up/down);
  - iris: `m = smoothstep(r - f, r + f, ... )` with the circle radius `r = progress * R` where `R` is half the
    frame's diagonal, so progress 1 covers the corners; B inside the circle.
  - Feather `f` = 2 sequence pixels (a constant in `RenderGraph.h`, documented); at progress 0 and 1 the
    result must be exactly A and exactly B (test).
- Pair draw: `mix(colorA, colorB, m)` per pixel. Single-layer fade draw (a wipe to or from black): the layer's
  premultiplied colour times `m` (fade in) or `(1 - m)` (fade out), replacing the uniform `weight()` for
  these kinds; the dissolve fade keeps the uniform weight.
- Export goes through the same compositor and needs no change beyond the uniforms; `ExportParityTests` gains
  one wipe and the iris (export pixels equal the monitor's).

### Tests (engine)
- A CPU reference of `m(p, progress)` in the test (the same formulas in C++), compared per pixel against the
  compositor for each kind at progress 0, 0.25, 0.5, 0.75, 1 on two flat-colour sources (tolerance 1/255 away
  from the feather band, exact at 0 and 1); the dissolve path unchanged against its existing goldens.
- A wipe at a free edge (fade role) against black; the audio crossfade unchanged under every kind (the mixer
  never sees the kind: assert the audio graph is identical for a dissolve and a wipe on the same cut).
- JSON round trip of every kind; an unknown kind refused with its name in the message; `SetTransitionKind`
  undo/redo and its refusal for a non-transition span.

### App
- Effects tab: a tile per kind under Transitions (Cross Dissolve, Wipe Left, Wipe Right, Wipe Up, Wipe Down,
  Iris), each draggable onto a cut or a free edge exactly as Cross Dissolve is today (`TransitionTransfer`
  carries the kind) and addable with "+" at the nearest cut. Constant Power stays as the audio tile.
- Inspector, transition section: a "Kind" popup listing the video kinds (hidden for an audio crossfade);
  changing it is one undo step. The timeline's transition span shows a small glyph per kind (▷ ◁ △ ▽ ◯) next
  to the name; `TimelineViewModel` exposes the kind.
- Tests: the drop of each kind through `TimelineDropDelegate`; the popup change through `InspectorModel`;
  the timeline glyph per kind.

## 2. Speed in the inspector
- Inspector, Clip section, a "Speed" row: a percentage field (the same parser as the sheet: "50", "50 %",
  "1/2", "2x" accepted; see `SpeedDurationModel`), a presets menu (25 %, 50 %, 100 %, 200 %, 400 %, 800 %), and
  the "Reverse" checkbox from item 3. Commit applies the sheet's op with the store's ripple preference
  (`SpeedRipple`), one undo step; the row's help text says where the full sheet is (Cmd+R) for the duration
  and ripple choices. Limits are the engine's: 1 % to 10000 %; a value outside is refused with the range in
  the status line. Stills have no speed: the row is hidden for them.
- Tests: `InspectorModel` speed commit (percent and ratio), refusal outside the range, presets, hidden for a
  still; the linked audio clip follows (as the sheet does).

## 3. Reverse

### Model (schema v6)
- `Clip.reversed: bool` (default false; stills never reversed: validation refuses it). JSON key `reversed`
  written only when true. `kProjectSchemaVersion` becomes 6 with a migration that changes nothing but the
  version (a test opens a v5 file and asserts every clip is forward).
- **Reverse is applied only where media is read.** Everything else in the model keeps the forward mapping:
  `sourceTimeAt(t) = sourceIn + (t - timelineStart) * speed` remains the clip's "clip time" `u`, spans keep
  their source-time ranges, trims, splits, speed changes, `fitSpans`, thumbnails' cache keys and the
  invariants are untouched. The media read for clip time `u` on a reversed clip is the **mirror**: the source
  frame a forward clip would show at clip time `sourceIn + sourceOut - u` (frame-exact: timeline frame k of an
  n-frame clip shows the source frame that forward frame n-1-k shows; define it by frame index through the
  existing frame-grid mapping so VFR and NTSC cases stay exact, and document the rule in `Clip.h`).
  Consequence, documented: trimming the head of a reversed clip removes source frames from the *end* of the
  file, which is what the user sees.
- Edit ops: `SetClipReversed(clipId, bool)` (undoable; a linked audio clip follows, as speed does); a reversed
  clip survives split (both pieces reversed, each showing the pictures it showed), speed change, move, trim,
  copy. Validation: `reversed` only on media clips.

### Engine
- Scheduler: `makeLayer` and the audio graph resolve the mirror for reversed clips. The video layer's source
  time is the mirrored frame's time; the `DecodePool` target for a reversed clip during forward playback is a
  backward window (the pool already decodes backward windows for reverse play: a target's direction becomes
  `clip.reversed XOR playback reversed`). Reverse playback of a reversed clip is forward decoding.
- Audio: `ClipAudioSource` for a reversed clip reads the block that ends at the mirrored time and delivers it
  sample-reversed; the resampler (speed) sits after the mirror so pitch follows speed as today; crossfades and
  gain spans are unchanged. Reverse *playback* stays silent as today (unchanged rule); a reversed clip in
  forward playback has sound (reversed).
- Thumbnails: the timeline strip of a reversed clip shows the mirrored order (the thumbnail request maps clip
  time through the mirror before the cache lookup; cache keys stay by source time).
- Export: through the scheduler; nothing extra. Parity test: exporting a reversed clip equals the monitor's
  pictures and the audio equals the playback mixer's, and equals the forward export played backwards (frame k
  of reversed == frame n-1-k of forward, exact; audio the sample-reversed forward audio within 1e-6).

### App
- Clip menu: "Reverse Clip" (toggle, checkmark when the selection is reversed; Option-Cmd-R), the clip context
  menu, the "Reverse" checkbox in the inspector's Speed row and in the Speed/Duration sheet. The timeline
  clip shows a "◀" badge before its name when reversed; the inspector's Source In/Out rows show the source range
  with "(reversed)" after them. The source monitor is unaffected (it shows the asset, not the clip).
- Tests: `InspectorModel`/menu toggles and undo; the timeline badge; split/trim of a reversed clip keeping
  its pictures (engine); a Motion span on a reversed clip stays on its pictures across a trim (engine).

## Order, commits, verification
Transitions (engine, then app), the speed row, then reverse (model and JSON, scheduler and audio, thumbnails,
export parity, app). Path-scoped commits per step; a failing-then-passing test per behaviour; the full scheme
green with zero project warnings at each step's end; ThreadSanitizer over the EngineTests once at the end
(the decode pool's direction change is the risk). Docs: an integration-notes section per item, README's
"What it does today" updated for the transitions, speed row and reverse, and this plan marked done.
