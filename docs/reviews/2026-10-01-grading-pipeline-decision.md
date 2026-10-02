# Grading pipeline: placement decision (2026-10-01)

Status: **approved by the user, 2026-10-01**: sections 1-6 and 8 as recommended; section 7 amended (see the
decision at the end of section 7: the base grade is a property of the clip, not a stack effect). Nothing here
is implemented yet. It answers the
questions of theme 5 in `2026-10-01-general-code-review.md` ("decide and write down where grading sits") for
the colour grading plan (`docs/plans/README.md`, Planned item 2), and adds two related questions the lead
raised: where whole-clip effects live, and how transitions get parameters.

Today's pipeline, per layer, in `ve_layer_fragment` (Shaders.metal):

1. Sample the source: YCbCr through `sampleYCbCr`, whose colour matrix gives R'G'B' and `saturate`s it, or
   RGBA through `sampleRGBA`, premultiplied.
2. Edge coverage times weight (opacity).
3. Premultiplied blend into the target: `ONE, ONE_MINUS_SOURCE_ALPHA`, on gamma-encoded BT.709 values
   (Compositor.h, "Colour").

The targets differ:

- Monitors draw straight into the `CAMetalLayer` drawable, `BGR10A2Unorm`, `framebufferOnly`.
- Export draws into an `RGBA16Float` intermediate, then a compute pass writes the encoder's planes.

## 1. Where the per-clip grade sits

**Recommendation: in the fragment shader, per source, between steps 1 and 2.** That is after the source's
YCbCr to R'G'B' conversion and before the coverage, the weight and the blend. A dissolve pair grades A and B
separately, each with its own grade, before `mix(A, B, m)`.

- **Uniforms:** each source gets a `VEGradeUniforms` sub-struct in `VESourceUniforms`. The slot is marked in
  ShaderTypes.h by item 4 of this round.
- **Function constants:** `kSourceAHasGrade` and `kSourceBHasGrade` select it. An ungraded layer runs today's
  code, so existing projects stay bit-identical and pay nothing.
- **Straight-alpha RGBA:** the grade sees unpremultiplied colour. `sampleRGBA` returns premultiplied colour,
  so the grade divides by alpha (guarded at 0), grades, and multiplies again.

Alternatives:

- **(b) A separate full-frame pass per graded layer, into a per-layer intermediate.** It costs a texture and
  a pass for each graded layer. It is only needed for spatial operations: blur, sharpen, or a secondary with
  a soft key.
- **(c) Grade the composed frame.** That is a sequence-level look, not a clip grade. It may come later as an
  adjustment, but it does not answer the per-clip question.

## 2. Linear light or gamma-encoded

**Recommendation: grade in linear light; keep blending gamma-encoded, as today.**

The grade's steps:

1. Linearise R'G'B' with the source's transfer function (section 6), mirrored for negative values so nothing
   produces NaN.
2. Apply exposure (a gain), temperature and tint (channel gains, normalised to keep luminance), and saturation
   (a mix toward BT.709 linear luminance) in linear light.
3. Apply contrast about a pivot of linear 0.18, on the log2 of the value, which keeps it perceptual (see
   "Contrast and non-positive values" below: log2 is never taken of a value ≤ 0).
4. Re-encode with the inverse of step 1's curve.

**Contrast and non-positive values (user's requirement, 2026-10-01).** Linear values reach step 3 at or below
zero: black is 0, sub-black and out-of-gamut sources give negatives (step 1 mirrors the curve for them),
saturation can push a channel negative, and -0 and denormals occur. log2 of 0 is -inf and of a negative is NaN,
and a NaN in the fragment shader becomes a black or garbage pixel that spreads through a dissolve's mix and
the blend. The contrast step must therefore never evaluate log2 (or pow) of a value ≤ 0:

- **Formula:** the contrast curve is `f(v) = pivot · (v / pivot)^c` for `v ≥ ε` (the log2 form,
  `exp2(c · (log2 v − log2 pivot)) · pivot`, written so log2 only ever sees v ≥ ε), with ε a small positive
  threshold (for example 2^-14, about 6e-5, below the darkest 10-bit code in linear light).
- **Below ε:** a straight line through the origin that meets the curve at ε with the same value,
  `f(v) = v · f(ε) / ε`. It is continuous, monotonic and maps 0 to 0, so black stays black and there is no
  step or band at ε. Negative values continue the same line (sign kept, never mirrored through log2), so
  sub-blacks stay ordered and finite.
- **Contrast 1:** returns v unchanged on both branches, so an untouched control changes nothing, bit for bit,
  as the function constant requires.
- **NaN and infinity:** a NaN input (which should not occur) is treated as 0 before the grade. +inf is clamped
  to the float maximum before the grade, so nothing the grade outputs is NaN or inf. The same rule applies to
  every other step that uses log, pow or a division (the transfer curves' mirrored branches; temperature/tint
  luminance normalisation, whose divisor is guarded away from 0).
- **Tests:** when grading lands, a doctest of the grade function (the same function compiled for the CPU
  reference) over inputs 0, -0, ±ε, ±ε/2, denormals, negatives down to -1, 1, large values, NaN and ±inf, at
  contrast 0.5, 1 and 2. Every output must be finite; f must be monotonic and continuous across ε; contrast 1
  must be the identity. A render test must show a graded black frame stays exactly black and a graded
  sub-black ramp has no NaN pixels.

The blend stays where it is.

Effect on existing projects: **none**.

- The blend does not change, and an ungraded layer skips the grade (function constant).
- Every dissolve, opacity and wipe of every existing project looks as it does now.

Effect on export parity: **none**.

- Monitors and export run the same fragment code. The grade is per-pixel arithmetic in float, so 8-bit and
  10-bit sources grade alike (the plan's requirement); that comes from the float arithmetic, not from linear
  light.
- The parity tests keep their meaning. They should gain graded cases when grading lands.
- Section 4 removes the one precision difference that remains: the blend's target format.

Alternatives:

- **(b) Grade gamma-encoded.** It saves the transfer curves (about 0.014 ms per 1080p frame, section 5).
  But exposure and white balance behave unphotographically: highlights shift hue, and a gain is not a stop.
- **(c) Grade and blend in linear light.** It is physically right: dissolves keep brightness, and soft edges
  over light backgrounds have no dark fringe. But it changes every existing project's transitions and
  opacities. If it is wanted later, it should be a per-sequence setting ("Composite in linear light"),
  stored in the project, off for existing projects.
- **(d) A log working space (ACEScct-like).** It suits wheels and curves in slice 2. It is not needed for
  slice 1, and can be added inside the grade without moving it.

## 3. Where the `saturate` clamp in `sampleYCbCr` goes

Today it clamps R'G'B' to [0, 1] right after the matrix (Shaders.metal ~72). That throws away the above-white
and below-black values of video-range sources (Y' 236-254, out-of-gamut chroma) before anything could pull
them back.

**Recommendation: move it to the end of the grade.**

- `sampleYCbCr` stops clamping when the source is graded (function constant). The unclamped value goes
  through the grade, and the grade's output is clamped. A negative exposure or a highlight roll-off then
  recovers super-whites.
- Ungraded sources keep the clamp exactly where it is. Blending still sees [0, 1] for every layer, as today.
- Result: no existing pixel changes, and the export's final `saturate` in `ve_convert_*` stays as it is.

Alternative:

- **(b) Clamp only at the output stage.** Values above 1 would flow through the blend. That changes existing
  projects wherever an out-of-range source sits under opacity or a dissolve (half of 1.05 is 0.525, not 0.5).
  It also needs the float monitor intermediate (section 4) even without a grade.

## 4. The monitors' working format

Today monitors blend into the 10-bit `framebufferOnly` drawable. Scopes cannot read it, and it blends at a
different precision from the export's `RGBA16Float`.

**Recommendation: composite every monitor into a pooled `RGBA16Float` intermediate at drawable size, then run
an output stage that writes the drawable.**

- **The output stage:** a full-screen render pass sampling the intermediate. The drawable stays
  `framebufferOnly` and keeps its lossless compression.
- **Same as export:** monitors and export then blend into the same format. The output stage is where the
  monitors' last `saturate` happens, as `ve_convert_*` does for export.
- **Scopes:** a waveform's compute pass reads the intermediate (or a half-size copy of it) before the output
  stage.
- **Memory:** 8 bytes per pixel per view. That is 16.6 MB at 1080p and 66 MB at 2160p, for each of the
  program monitor, the source monitor, the output display and the solo preview while visible.
- **Two textures per view:** with one texture, frame N+1's composite waits for frame N's output pass (Metal
  tracks the hazard). That is correct but serialises; use two textures per view if a measurement shows it
  matters.

Alternatives:

- **(b) Keep the 10-bit drawable and make it readable** (`framebufferOnly = NO`) for scopes. It costs
  compression, and scopes would read clamped 10-bit values, not what export blends.
- **(c) An `RGBA16Float` EDR drawable.** One pass, but the window server's extended-range colour matching
  becomes part of the look, and it doubles the drawable's bandwidth. Revisit with HDR.

## 5. Measured cost of an extra full-frame pass on the monitor

Measured with a throwaway prototype (an XCTest built against this round's engine, not committed) on an Apple
M4 Pro. The figures are GPU time per frame, the median of 120 synchronous frames, with the real `Compositor`
and a 420v source. The output pass is a compute kernel from `RGBA16Float` to `BGR10A2`, in two variants:

- a copy with `saturate`;
- linearise, then a 3x3 matrix and a gain, then re-encode: what a full-frame linear-light pass would cost.

| Scene | Composite into BGR10A2 (today) | Composite into RGBA16F | Output pass, copy | Output pass, linear 3x3 |
|---|---|---|---|---|
| 1080p, 1 layer, 1080p monitor | 0.055 ms | 0.050 ms | 0.024 ms | 0.038 ms |
| 1080p, 3 layers at 50 %, 1080p | 0.150 ms | 0.138 ms | 0.024 ms | 0.038 ms |
| 4K, 1 layer, 2160p monitor | 0.199 ms | 0.181 ms | 0.087 ms | 0.140 ms |
| 4K, 3 layers at 50 %, 2160p | 0.576 ms | 0.529 ms | 0.090 ms | 0.140 ms |

A second run gave the same figures, except its first scene (GPU clocks not yet up).

**Reading:**

- Compositing into the float intermediate is not slower than into the 10-bit drawable; the blend happens in
  tile memory either way.
- The extra output pass adds **0.024 ms** at 1080p and **0.09 ms** at 2160p: under 1 % of a 60 fps frame's
  16.7 ms.
- Doing the linear-light arithmetic per pixel costs about 0.014 ms more per 1080p frame (0.05 ms at 2160p).
  Spent per layer inside the fragment shader instead (section 1), it scales with the graded area rather than
  the frame. The float intermediate on monitors is therefore affordable without reservation.

## 6. Which colour tags the compositor honours

The tags as they arrive:

- **Matrix and range:** honoured today. The kCVImageBufferYCbCrMatrixKey attachment and the pixel format set
  the colour matrix (TextureCache.h).
- **Transfer and primaries:** carried on every frame (ColorTags.h) but never read.
- **Stills:** already flattened to 8-bit sRGB at decode (review media #2), which gamut-clips P3 HEIC.

**Recommendation for slice 1:**

- **Transfer, for the grade's linearisation:** BT.709, Unknown, BT.601 and SMPTE 240M video are decoded with
  the BT.1886 display EOTF (pure 2.4 power: display-referred, which matches how the monitors and export
  already treat R'G'B'). sRGB-tagged sources and stills use the sRGB curve; Linear uses identity.
  Re-encoding uses the same curve, so an identity grade returns its input within float rounding (far below
  one 10-bit code); a grade at its neutral values can also be skipped altogether by the function constant.
- **Primaries:** P3-D65 and BT.2020 (SDR) video gets a 3x3 gamut conversion to BT.709 in linear light, in the
  same linear segment. This changes how such sources look in existing projects (correctly: today they show
  desaturated or shifted), so it should be its own decision and commit, with a parity test per primaries.
  DCI-P3 likewise.
- **PQ and HLG:** not honoured (treated as BT.709, as today). Tone mapping HDR to SDR is a separate project.
  The UI should say "shown as SDR without tone mapping" on such clips.
- **Output:** stays BT.709 (the drawable's colour space and the export tags).

Alternatives:

- **(b) Honour transfer only and leave primaries alone.** It keeps every existing look, but P3 iPhone video
  stays wrong.
- **(c) Convert everything into a wide working gamut (linear BT.2020)** and convert at output. It is right
  for a wide-gamut future, but it changes every blend's result and needs HDR output decisions first.

## 7. Where whole-clip effects live

Effect spans sit on three effect lanes per clip, and spans on one lane never overlap. That suits timed
changes (a Ken Burns move, a fade, a grade that changes over time) but not a stack of always-on effects on one
clip: a grade, a crop and a key, with more effects to come.

**Recommendation: (b), a separate ordered effect stack per clip; timed spans stay on lanes.**

- **The model:** `Clip::effects`, each an `{id, kind, enabled, parameters}`. The order is the order of
  application. It is drawn as one collapsible row under the clip and edited in the inspector.
- **A kind can be both:** Colour, for example, as a stack effect for the base grade and as timed spans for
  changes, which compose on top through the parameter table's additive or multiplicative rule.

How it interacts with the rest:

- **Splitting `EffectSpan` (review 1.9):** (b) makes a third type rather than a third meaning of the span
  struct: lane spans (timed, in source time), transitions (edge offsets), stack effects (no time range).
  Splitting first makes (b) cheap. Under (a), always-on effects would be spans that must keep filling the clip
  through every trim, split and speed change. That contradicts "spans stay on their pictures": today an
  extended trim does not restore a span.
- **Descriptor tables:** the parameter rows built in item 2 serve both. The kind table gains a placement
  column (lane, stack, or both), and later a function-constant id for the shader. Stack order, not
  composition, decides crop-then-key: those operations do not commute, while today's lanes may stay
  unordered because their operations commute.
- **Composition order with Motion:**
  1. Decode and convert.
  2. The stack in order (crop, key, grade: operations on the source picture).
  3. Timed colour spans.
  4. Motion: the placement, already applied at sampling through the inverse mapping, so crop and key happen
     in source space.
  5. Opacity.
  6. The blend.

  This is Premiere's order: fixed Motion and Opacity after the standard effects.
- **File format:** a clip gets `"effects": [{"id", "kind", "enabled", "parameters": {...}}]`. That is schema
  8, with a migration that converts nothing. Unknown effect kinds and parameters are kept from day one with
  item 1's foreign-content rule. Option (a) needs no schema change but carries the fill-the-clip burden.
  Option (c), more lanes, would make lane order semantic and would grow the timeline rows (D1 compact rows)
  for effects that have no time.

### Decision (user, 2026-10-01): the base grade is a clip property
The user chose a simpler model for grading than the effect stack recommended above. A clip has a grade, as it
has a position and a scale; there is no "colour effect" to add.

**Editing a grade:**
- Select a clip (or clips) and open the colour tools, which edit that grade.
- **One clip selected:** the panel shows and edits its grade.
- **Several clips selected:** each control shows its value where the clips agree and "mixed" where they
  differ. Moving a control sets that one parameter on all of them and leaves their other parameters alone, as
  the inspector already does for several selected clips.

**Reusing a grade:** Copy Grade, Paste Grade and Reset are how a grade is reused across clips. "Match previous
clip" can come later.

**How the major editors do it:**
- DaVinci Resolve grades the current clip only, and spreads a grade by copying it, by groups or with a
  timeline grade.
- Premiere's Lumetri panel edits one clip's Lumetri Color, spread by Paste Attributes, presets or adjustment
  layers.
- Final Cut uses clip effects and Paste Attributes.

None of them merges different grades; each grades one clip and copies.

**Consequences for the design above:**
- The grade is a fixed set of parameters on the clip (`Clip::grade`, from the parameter descriptor table).
  Composition order: decode and convert, the clip's grade, then Motion, Opacity and the blend.
- The file format gains the clip's grade fields (schema 8). Unknown grade parameters are kept under item 1's
  foreign-content rule.
- A grade that changes over time is left for later. When wanted, it is a timed Colour span on a lane that
  composes on top of the clip's grade through the parameter table's rules.
- The ordered effect stack is deferred, not rejected. It comes back when crop, keying and blur arrive, since
  those are always-on effects whose order matters. Splitting `EffectSpan` (review 1.9) still comes first and
  keeps that option cheap.

## 8. Transition parameters

Today's six transitions are fixed shapes with no parameters. The feature gap plan (item 29) wants dip to
colour, push and slide, an angled soft-edge wipe with a border, iris shapes with a centre, zoom, film and
additive dissolves, and audio fade curves.

**Recommendation: a `TransitionKindInfo` table like `SpanKindInfo`**, with these columns:

- name and display name;
- tracks: video, audio or both;
- the mask family;
- the parameters, from a `TransitionParameterInfo` table (name, type, default, range).

Parameter types are scalar, angle, point, colour and enum. A transition span then carries
`TransitionParameters`, an array indexed by the parameter enum as `SpanTracks` now is: static values first,
keyframes only if ever needed.

- **In the file:** a span's `"parameters": {...}`. Unknown ones are kept, as item 1 keeps unknown span keys
  today.
- **Kinds as presets:** Wipe Left and the rest become presets of one Wipe kind, by angle. The file names stay
  as aliases, so old files load unchanged.
- **Audio fade curves:** an enum parameter (linear, equal power, exponential) that the mixer reads where it
  computes the crossfade gain.

**A generic shader model fits most of the list.** Three parts make up each transition:

- **A reveal mask m(p)** from one family per kind, each a signed distance to an edge that already feeds
  `transitionReveal`'s soft edge and exposure averaging:
  - linear: angle, offset;
  - radial: centre, aspect;
  - polygon: the iris shapes, as signed distance functions;
  - angular: clock wipe, centre and start angle.

  A border is a band of the same distance, so it costs one `smoothstep` and a colour.
- **A transform per side** for push, slide and zoom. This needs no shader change: it composes into each
  source's inverse placement (`uvFromFrameX/Y`) on the CPU per frame.
- **A blend mode:**
  - normal `mix`;
  - dip to colour: two phases through a colour C;
  - additive;
  - film: mix in linear light, reusing section 2's transfer curves.

**How it uses item 4's named uniforms:** `VETransitionUniforms` grows named fields in whole 16-byte rows.

- mask family (int), angle, centre (float2), aspect, border width;
- border colour and dip colour (float4);
- blend mode (int).

These come with the `static_assert`ed offsets item 4 introduced. New function constants (`kHasBorder`,
`kHasDip`, `kBlendMode`) keep today's dissolve and wipes on their current code path, bit-identical and as
cheap as now.
