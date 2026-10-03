# Titles, text overlays and colour mattes: design and slices (2026-10-02)

Status: **proposed, not approved.** Nothing here is implemented. The owner asked for titles and text overlays
next (feature gap item 1, `2026-10-01-premiere-lite-feature-gap.md`). This note answers the design questions
the lead raised, in the shape of the approved grading decision (`docs/reviews/2026-10-01-grading-pipeline-decision.md`):
per question the options, a recommendation, what the major editors do, and what it means for the code. It ends
with the decisions for the owner and a slice plan. File and line references are to main at f6ad9f4; sizes and
timings marked "estimate" are from reading the code, not measured.

The feature gap note put titles in round 4 beside nested sequences, because both need "a clip whose pictures
are not a file". Doing titles first means designing that piece now (review 2.2, video half) in a form the
nested-sequence round can reuse; section 2 does that and says what it leaves for that round.

## Summary of the recommendation
- **A title belongs to its clip** (Premiere's graphics clips, Final Cut's titles, Resolve's Text+), not to the
  media bin. Every title clip refers to one hidden per-project generator asset of its kind ("Title", "Colour
  Matte"), so the engine's rule "a clip has an asset" holds unchanged, and keeps its own text and style. Title
  edits are clip edits, undone like grade edits.
- **Not a PNG file.** The text is rendered in memory by Core Text into a still-like picture, keyed by its
  content and the scale it is drawn at, by the decode pool's threads, never on the render or main thread.
- **Sharp at any size it is drawn:** the picture is rendered at the largest scale the clip reaches in that
  output (its Motion zoom, an export larger than the sequence), never below the sequence's resolution, and is
  never sharpened.
- **A frame-sized transparent canvas:** the clip's Motion, opacity, fades, transitions and spans apply to a
  title exactly as to a photo; the text block's own position and wrap width are title properties, dragged on
  the program monitor.
- **No grade on titles and mattes** in slice 1; text colour is exact (white text exports as video white).
- **Schema 10**, a frozen 9 -> 10 step and version 10 goldens; no existing golden changes.
- **Slice 1** delivers styled titles and lower thirds over video, colour mattes, the on-monitor box, and
  identical export. Typing on the monitor, safe areas and style copy come in slice 2; rich text, shapes and
  templates in slice 3; animated text in slice 4.

## What a title touches today
- **Pictures are keyed by asset.** A layer names its `assetId` (RenderGraph.h:110-149). Playback and export look
  up the picture in the frame cache by `FrameKey{asset, decode format}` (FrameCache.h:93-105;
  PlaybackController.mm:382; ExportJob.mm ~336), filled by the decode pool, whose streams open a decoder through
  the backend router from the asset's path (DecodePool.h:110-120, BackendRouter.h). Nothing in that chain can
  produce a picture without a file.
- **A still is the nearest thing to a title.** A still asset has no duration (MediaAsset.h:16, 28-30), its clips
  have speed 1, sourceIn 0 and cannot be reversed (Validation.cpp:50-73), and its one frame has pts 0 and an
  infinite duration, so the cache's slot 0 answers every time (FrameCache.h:17-18; Interfaces.h:57-62).
  Stills are drawn by CoreGraphics into an IOSurface-backed buffer, premultiplied and sRGB-tagged
  (StillDrawing.mm:19-33, 49-90).
- **The compositor fits every picture into the frame** by its aspect ratio, then applies Motion about its centre
  (Compositor.h:32-43; `placeSource`, Compositor.mm:131-205). A picture within 2 px of the frame size is drawn at
  exactly 1:1 (Compositor.mm:145-157). Outside a picture's rectangle the shader's edge coverage is 0, so the
  area is transparent (`edgeCoverage`, Shaders.metal:62-70).
- **Blending is gamma-encoded,** and only the grade works in linear light. Layers blend premultiplied
  (`ONE, ONE_MINUS_SOURCE_ALPHA`) on BT.709 R'G'B' values, and sRGB stills are treated as BT.709-encoded
  (Compositor.h:44-50; grading decision, section 2).
- **Minified pictures are pre-scaled and sharpened.** A picture drawn below 0.75 of its size is Lanczos
  pre-scaled, and then sharpened when "Sharpen scaled-down sources" is on (Compositor.h:58-108). The flag is
  per graph and is read per layer where the source is bound (Compositor.mm:1032, 1071-1076).
- **Paused and late pictures are held.** While paused, a frame waiting for a picture keeps the previous
  complete picture on screen. While playing, a late layer keeps its clip's previous picture
  (PlaybackController.mm:421-447; PlaybackController.h:394-418).
- **Assets are registered with the pools by path on every model change.** `registerAssetsLocked`,
  PlaybackController.mm:698-718, registers with the decode pool and the mixer. About a dozen places read
  `MediaAsset::url` as a file: the monitors' registration (VEEngine+Project.mm:137-138), thumbnails, waveforms,
  locate and bookmarks (VEMediaLibrary.mm:253-521), export (ExportJob.mm:268, 618, 644), the offline mixer
  (OfflineAudioRenderer.mm:37), the asset snapshot (VETypes.mm:952), import (AssetImport.mm:60) and validation,
  which refuses an empty URL (Validation.cpp:241).
- **Edits and ids.** Clip edits are `SequenceCommand`s in `Engine/Edit` (the grade's are in GradeEdits). Asset
  additions are facade commands (`ImportAssets`, VEFacadeCommands+Internal.h:22). Every facade edit is wrapped in
  `FreshIds` (VEEngine+Undo.mm:131), which already gives the ids review 2.4 worries about.
- **The file.** It is schema 9 (ProjectJSON.h:61). A build refuses a file of a newer schema with "newer than
  this version of Framewright supports" (ProjectJSON.cpp:976-990), and the writer always writes the current
  version. Unknown keys are kept only in spans and in a clip's grade (ProjectJSON.h:34-41; open findings, "Facade
  and model"). Migrations are frozen steps with per-version goldens (ProjectMigrations.h:1-16).
- **App.**
  - The Ken Burns editor draws boxes over the program monitor in sequence coordinates, with rotation-aware
    boxes, hit testing and one coalescing group per drag (KenBurns.swift:932-1006 geometry, 1059 viewport, 1151
    hits, 514-612 drag group; KenBurnsOverlay.swift:28-60).
  - The Effects tab lists transitions and lane effects as draggable tiles with "+" (InspectorPanel.swift:43-80;
    TransitionsPanel.swift).
  - Media from the source monitor or the bin goes at the playhead on the target tracks, overwriting, or
    inserting with Command (ProjectStore.swift:1490-1512, 1585-1595).
  - Copy Grade and Paste Grade, with "mixed" controls for several clips, are the model for reusing a style
    (ProjectStore.swift:1315-1370; GradeTools.swift).

## 1. What a title is in the model

**Recommendation: (b) clip-owned content with a shared, hidden generator asset per kind.**

The options:

- **(a) A generated asset per title in the media bin.** The asset holds the text and style; clips of it show it.
  This is how Premiere's legacy titles worked (a project item; Premiere's master/source graphics still can).
  - **Pro:** it needs the least engine change, since pictures stay keyed by asset id.
  - **Against: sharing surprises.** Every clip of the asset shares the text. Splitting a title and retyping one
    half retypes both, and a future copy and paste must decide each time whether the copy shares the asset or
    gets a new one.
  - **Against: the bin fills up.** A documentary with eighty name supers puts eighty items in the bin. The bin
    already does not scale (feature gap item 27).
  - **Against: the edits land in the wrong layer.** Editing the text edits an asset, which is a project-level
    edit (review 2.1: only the facade can do those today), not a clip edit in `Engine/Edit`.
- **(b) Clip-owned content (recommended).**
  - **The clip.** It carries its title (or matte) content and refers to the project's generator asset of that
    kind: one hidden "Title" asset and one "Colour Matte" asset, made by the first clip of the kind in the same
    undo step.
  - **The asset.** It has no file and no size. It is a still (no duration), so every rule about stills applies
    to title clips unchanged: any length, trims without media bounds, speed 1, no reverse.
  - **Edits.** Title edits are `SequenceCommand`s like the grade edits. A split gives two independent titles,
    and a future clip copy (feature gap item 2) copies the content with the clip and needs nothing special.
- **(b') Clip-owned with no asset at all.** The clip would carry `std::optional<AssetId>`. That breaks the
  invariant "a clip has an asset" in about 45 `findAsset` sites across Model, Edit, Render, Playback, Export,
  Audio and the facade (counted with grep), for no gain over (b).
- **(c) Render a PNG once and import it as a still.** Not good enough, for these reasons:
  - **Sharpness.** The PNG has one resolution. Rendered at the sequence size, it softens under a Motion zoom
    and in an export larger than the sequence (1080p from a 720p sequence, or a custom width up to 16384;
    VEExport.h:35-44, 106-111). Rendered at 3-4x to be safe, it costs 33-133 MB of frame cache per 4K title
    (estimate, 8-bit). It is then always minified in the monitors, which sharpens it with halos around the
    letters (Compositor.h:85-108).
  - **Every edit is a file.** Each keystroke writes a file, probes and imports it, and swaps the clip's asset.
    Old versions must be kept for undo. An unsaved project has no folder to write into.
  - **Two sources of truth.** The text must still be stored somewhere to be edited again, so there are two
    sources (parameters and pixels), and a moved project shows its titles as "File not found".
  - **The one advantage:** a baked PNG shows the same on a Mac without the font. Section 7 handles that case
    instead.

  The good half of the idea is kept: the text becomes a still-like picture, rendered once per content and
  scale. It just lives in memory, made by the engine.

**What the major editors do.**
- **Premiere.** The Type tool or Graphics menu makes a graphics clip that exists only in the timeline until you
  "upgrade" it to a source graphic. Colour mattes are project items (File > New > Color Matte), the older style.
- **Final Cut.** Titles and generators come from the Titles and Generators browsers (templates) and become
  connected clips with their own text. In FCPXML a title is a `<title>` that refers to a shared `<effect>`
  resource (the template) and carries its own parameters: the shape of (b).
- **Resolve.** Text, Text+ and Solid Color are dragged from the Effects library. Each timeline instance owns its
  settings.

**Consequences for the code.**
- **The asset.** `MediaAsset` gains a generator kind: `None` for files, `Title`, `ColourMatte`. A generator
  asset is `AssetKind::Still` with an empty URL and size 0x0. Validation's URL and size rules (Validation.cpp:241,
  270-273) apply to file assets only, and a clip of a generator asset needs generator content of its kind.
- **One predicate.** A helper `isFileBacked()` is the single check at the dozen URL sites listed above:
  thumbnails, waveforms, locate, bookmarks, mixer registration, export registration and the "File not found"
  row skip generator assets. Nested sequences (a sequence-typed asset, plans README item 1) are the next
  non-file asset kind and reuse the same switch.
- **The clip's content.** `Clip` gains `generated`, holding `std::shared_ptr<const TitleContent>` or the
  matte's colour. It is shared and immutable, like the project's LUTs (Project.h:34-38), so copying a frame's
  model or an undo snapshot copies no strings, and a layer can point at it without allocating on the render
  thread. `operator==` compares contents, as for LUTs.
- **What a title clip may and may not have.** Title and matte clips are allowed only on video tracks. They
  have no grade (section 5). They may have Motion, Opacity spans, fades and transitions like any clip.
- **The bin and the source monitor.** Generator assets are hidden from the media bin and the source monitor.
  The facade's asset list leaves them out, and "remove unused media" never offers them. An unused generator
  asset is not written on save, like an unused LUT.
- **Picture size.** Everything that reads a clip's picture size gets the sequence's frame size for a generated
  clip: `VEClipInfo`, and the Ken Burns boxes, which read the asset's size today. That is the size of the canvas
  the compositor fits (section 3). Because the canvas is exactly the frame size, the 1:1-versus-fitted question
  behind the open "under a pixel" overlay finding (KenBurns.swift ~932-951) does not arise for titles.
- **Ken Burns mode.** The Ken Burns editor's automatic mode (KenBurns.swift:261) picks Transform for a generated
  clip. A title alone on black, which is what Ken Burns mode would show, is not useful.
- **Ids (review 2.4).** It is not a prerequisite. Inserting a title is a facade command wrapped in `FreshIds`,
  like every edit. Clip copy and paste needs 2.4; titles do not.
- **Schema and old builds.** This is schema 10 (section 11 and the slice plan). An old build refuses any
  project saved by the new one, with or without titles, because the writer always writes the current version.
  That is what the schema 8 and 9 bumps did. Inside schema 10, unknown keys in a title's object are kept and
  written back (the grade's `foreign` rule), so a later minor addition is not stripped.

## 2. The non-file video source (review 2.2, video half)

**Recommendation: a generated picture source the decode pool opens instead of a routed decoder, adapted to
`IVideoDecoder`, with the frame cache key extended by the source's key.**

Shape (names indicative):

```
// Engine/Media/GeneratedSource.h
class GeneratedPictureSource {          // immutable; shared between threads
  public:
    virtual ~GeneratedPictureSource() = default;
    virtual GeneratedKey key() const = 0;   // content id + raster scale: the cache identity
    virtual bool isStatic() const = 0;      // one picture for all times (titles, mattes)
    virtual CMTime frameDuration() const = 0; // invalid when static
    // Blocking; called on a pool worker or the scrub thread. Polls options.interrupt.
    virtual Result<GeneratedFrame> render(CMTime t, const DecodeOptions &options) const = 0;
};
struct GeneratedFrame { VideoFrame frame; CanvasGeometry geometry; };
```

- **Adapter.** `GeneratedVideoDecoder : IVideoDecoder` wraps a source. A static source behaves exactly as the
  still decoders do: one frame with pts 0 and an infinite duration after open and after each seek
  (Interfaces.h:119-128). A non-static source returns frames on its frame grid. The pool's stepping, windows,
  interrupts, epochs, eviction focus and scrub coalescing (DecodePool.h:1-88) are reused as they are.
- **Pool.** `DecodeTarget` and `requestFrame` gain an optional `std::shared_ptr<const GeneratedPictureSource>`.
  When it is set, the pool opens the adapter instead of calling the router. A target whose source key changed
  is treated like a relink of that stream: the stream reopens, and frames of the old source are never published
  under the new key.
- **Cache.** `FrameKey` gains the `GeneratedKey`, empty for files. Purges, focus and epochs stay per asset (the
  generator asset). Generated keys are content-addressed, so an undo back to earlier text finds that picture
  if it is still cached, and two clips with identical titles share one picture.
- **Where the picture lands (`CanvasGeometry`).** This is where the picture sits on the frame-sized canvas, in
  sequence pixels, and the raster's scale (section 3). It travels with the picture, in its cache entry and the
  `TextureSet` mapped from it, and is never recomputed from the layer. So a held previous picture (paused, or a
  late layer) draws where it was made for.
- **Consumers.** Playback and export build the source for a generated layer (from the layer's content and their
  raster scale) and look the picture up as for a still. The waits, holds, skipped-layer reporting and export
  timeouts are unchanged.

What later work reuses:
- **Colour mattes** are a static source in slice 1.
- **Captions burn-in** (feature gap item 21) is one static source per cue, rendered by the same text renderer.
- **Animated titles** (slice 4) are a non-static source: a typewriter is new content per frame.
- **Nested sequences** can be a non-static source whose `render` composites the nested sequence into a pixel
  buffer on a pool worker. Whether they do, or composite inside the outer frame (review 2.3, re-entrant
  compositor), is that round's decision. The interface does not force either.
- **Adjustment layers** are not a picture source. Their picture is the composite below them. They reuse the
  clip side of this design (a generator asset, clip-owned content, the timeline and inspector) and need a
  compositor pass over the working texture, which belongs with grading, not with the pool.

**Left for the nested-sequence round on purpose:**
- the audio half of review 2.2 (`IAudioSampleSource`, the bounded shared producer pool): titles and mattes make
  no sound, so the mixer only skips generator assets;
- 2.1, project-level edits (a title edit is a clip edit; making the generator asset reuses the facade's
  existing composite and asset commands);
- 2.3, the re-entrant compositor and one layer-to-picture module: the four copies of layer-to-picture each gain
  the generated branch, which 2.3 will fold together;
- 2.7, per-sequence UI state.

**Alternatives.**
- **(b) A "generator" media backend behind the router, with a made-up URL scheme.**
  - **Pro:** zero pool change.
  - **Against:** the router probes files and would have to "probe" content, and parameters would travel in URLs
    or through a side registry.
  - **Against:** the cache would still need the content key, and every URL site would still need its branch.
- **(c) A separate generated-picture cache consulted by the texture lookup,** bypassing the pool.
  - **Pro:** simpler for static pictures.
  - **Against:** rendering would happen on the render thread or need its own thread pool, budget, eviction and
    export wait.
  - **Against:** it would not serve nested sequences or animated text later.

## 3. Rendering

### Which API and how
**Recommendation: Core Text for layout and glyphs, Core Graphics for drawing, into an IOSurface-backed
`CVPixelBuffer`, in the engine (no AppKit), on the pool's threads.**

- **Font.** `CTFontDescriptorCreateWithAttributes` with family and style (`kCTFontFamilyNameAttribute`,
  `kCTFontStyleNameAttribute`), or `CTFontCreateWithName` with the stored PostScript name. Then
  `CTFontCopyPostScriptName` on the result, to notice a substitution (section 7).
- **Layout.** An attributed string with:
  - `kCTFontAttributeName`;
  - tracking (`kCTTrackingAttributeName`, or `kCTKernAttributeName` per character; which exists on macOS 14
    to be checked when built);
  - a `CTParagraphStyle` for alignment and line height (`kCTParagraphStyleSpecifierAlignment`,
    `kCTParagraphStyleSpecifierLineHeightMultiple`).

  `CTFramesetterCreateWithAttributedString`, `CTFramesetterSuggestFrameSizeWithConstraints` for the block's
  height at the box width, then `CTFramesetterCreateFrame`, `CTFrameGetLines` and `CTFrameGetLineOrigins`.
  Core Text does the shaping, bidirectional text and per-character font fallback (Japanese typed in Helvetica
  draws in a Japanese font).
- **Glyphs as outlines.** For each `CTRun`, `CTRunGetGlyphs` and `CTRunGetPositions`, then
  `CTFontCreatePathForGlyph`. Filling and stroking those paths with Core Graphics gives the editors' outside
  outline: stroke at twice the width with round joins (`CGContextSetLineJoin(kCGLineJoinRound)`), then fill on
  top. Core Text's own stroke attribute (`kCTStrokeWidthAttributeName`) strokes centred on the outline and eats
  half of it into the letter. Colour bitmap glyphs (Apple Color Emoji) have no outline
  (`CTFontCreatePathForGlyph` returns NULL), so those runs are drawn with `CTRunDraw` and get no outline.
- **Order inside the picture:**
  1. the background box (`CGPathCreateWithRoundedRect`);
  2. the text's shadow;
  3. outline;
  4. fill.

  The shadow is drawn around a transparency layer (`CGContextBeginTransparencyLayer`), so the outline and every
  glyph cast one shadow. Without it, overlapping glyph shadows darken twice.
- **Shadow units.** `CGContextSetShadowWithColor`'s offset and blur are in the context's base space and are not
  changed by the transformation matrix (Apple, "Quartz 2D Programming Guide: Shadows"). The renderer must
  multiply them by the raster scale itself, or a 2x raster gets half the shadow.
- **Bitmap.** `CGBitmapContextCreate` over `CVPixelBufferGetBaseAddress` of a buffer from the existing
  `PixelBufferPool`, in the layout `StillDrawing.mm` already uses (`layoutOf`, StillDrawing.mm:19-33). The
  buffer is tagged sRGB and premultiplied as `drawStillImage` tags it (StillDrawing.mm:85-87). Refactor
  `layoutOf` and the context set-up into a shared helper first, as its own commit.
- **Anti-aliasing.** `CGContextSetShouldAntialias(true)` and `CGContextSetAllowsFontSmoothing(false)`: no LCD
  smoothing, which needs an opaque background. Subpixel positioning is on and subpixel quantisation off
  (`CGContextSetShouldSubpixelPositionFonts`, `CGContextSetShouldSubpixelQuantizeFonts(false)`), so glyph
  positions scale exactly between raster scales.
- **Threads.** Core Text and Core Graphics objects created and used on one worker are safe off the main thread.
  TextKit/AppKit drawing is not used in the engine.

### At what resolution
- **The canvas.** A title's picture stands for a frame-sized transparent canvas, but only the text block's
  bounding rectangle is rasterised: box, outline and shadow, plus a 2-pixel transparent margin.
  `CanvasGeometry` says where that rectangle lies on the canvas. The compositor places the canvas exactly as it
  places a frame-sized still (fitted, which for a frame-sized canvas is 1:1, then Motion about the frame's
  centre). It then maps the canvas uv to the raster's uv with an affine change of the two uv rows, on the CPU in
  `placeSource`: no shader change. The shader's edge coverage makes everything outside the rectangle
  transparent (Shaders.metal:62-70), and the margin keeps the edge ramp on transparent pixels.
- **Raster scale k** is in raster pixels per sequence pixel.

| Option | What | Cost | Quality |
|---|---|---|---|
| (a) Per frame, drawn scale bucketed | k follows each frame's drawn size (2^(1/4) steps) | re-render during every zoom and every monitor resize; a bucket change shows the held picture until the new one lands | best at every frame |
| (b) **Max scale per clip per output (recommended)** | k = the largest Motion scale the clip reaches over its length, times max(1, output pixels per sequence pixel), quantised to 1/64 | one render per content and output; none during playback or zoom | 1:1 where the clip is largest; minified elsewhere (Lanczos pre-scale below 0.75), as a 4K source in a 1080p sequence is |
| (c) Vector per frame on the GPU | glyph outlines tessellated or a distance-field atlas in the shader | a new text renderer in Metal, outline and blur on the GPU | resolution-free; differs from Core Text's anti-aliasing; worth it only with per-character animation |

**Recommendation: (b).**
- **What the output scale is.**
  - The monitors use the sequence's resolution, or more only when a view (the output display on a large
    screen) is larger than the sequence. A half-size program monitor then draws the sequence-resolution picture
    minified, with the same Lanczos pre-scale as any minified source. Window resizes never re-render, and the
    monitors and an export at the sequence size share one picture, so their parity is exact.
  - Export uses its output size: a 1080p export of a 720p sequence renders at 1.5x.
- **The largest Motion scale** is an upper bound computed in the model, `maxMotionScale(clip)`: the static
  scale times, for each lane, the largest scale factor its Motion spans reach. A bezier curve can overshoot its
  keyframes, so it is sampled. A Motion edit that raises it changes the key, and the picture is rendered again.
- **Limits.** The raster stays within 16384 px per side (the Metal 2D texture limit on Apple GPUs). Proposed:
  within 64 MB per picture, an eighth of the frame cache's 512 MB (FrameCache.h:115). Past either limit the
  text is drawn magnified and softer. Estimate: a full-frame 4K credits page zoomed 2x is about 133 MB at
  8 bits, so that is the case that hits the limit. A lower third at 4K and 2x is under 10 MB.
- **What the editors do.** Premiere puts a Vector Motion effect on graphics clips so text scaled past 100 %
  stays sharp, while plain Motion scales a rasterised picture. (b) gets the same result for the zooms Framewright
  has.

### Caching, edges and sharpening
- **Cache key.** The content id plus k. The content id is computed in the model over the canonical form of
  everything that changes the pixels:
  - the text, the font and size;
  - colours, alignment, spacing;
  - outline, shadow, background box;
  - the box width.

  It does not cover the block's position, the clip's Motion or opacity. A drag that moves the box therefore
  renders nothing. It changes the layer's canvas position, which is a CPU uniform.
- **Hash.** The id is 128 bits: FNV-1a in two lanes, in the style of `cubeContentId` (CubeLut.h:67), since the
  model stays free of Apple frameworks. A LUT has a few variants per project; a typing session makes thousands,
  and a collision would show the wrong words.
- **Edges.** Premultiplied 8-bit BGRA from Core Graphics, blended `ONE, ONE_MINUS_SOURCE_ALPHA` like any still.
  This is the format stills use without high precision. It is enough for flat colours and anti-aliased edges.
  Soft shadows over dark video may band in 8 bits; if a test shows it, the source renders 'RGhA', which the
  same helper already supports (StillDrawing.mm:21-27), at twice the memory.
- **Mattes** are rendered as a tiny 'RGhA' picture (4x4) stretched over the canvas. A colour is then exact to
  10 bits in a 10-bit export.
- **Sharpening: generated pictures are never sharpened.** It is a one-line condition where the source is bound
  (Compositor.mm:1032, 1071-1076: `graph.sharpenMinified && !layer.generated`). Their pictures are rendered at
  the drawn size and only minified during a zoom. Sharpening Core Text's anti-aliasing draws dark rings around
  light letters over video. The Lanczos pre-scale still applies below 0.75.

### Colour
The brief asked how text colour "enters the linear-light working space". It does not, and need not: blending
is gamma-encoded (grading decision, section 2), and only a grade linearises, which titles do not have
(section 5).
- **The values.** A colour is stored as sRGB components in [0, 1] (the colour picker's colour converted with
  `NSColor.usingColorSpace(.sRGB)`), drawn into an sRGB context unchanged, and composited as stills are: as
  BT.709-encoded values (Compositor.h:44-48).
- **White and black are exact.** White is 1.0 in the working texture, 1023 in the monitors' 10-bit output, and
  Y' 235, Cb 128, Cr 128 in a video-range 4:2:0 export. Black is Y' 16.
- **Mid-tones** carry the same small sRGB-versus-BT.709 curve difference every still has. That is consistent
  with photos on the same timeline, and the parity tests hold it.
- **Wide gamut.** Display P3 picks are clipped to sRGB in slice 1. Wide-gamut colours can come with the 'RGhA'
  format and the primaries decision (open findings, colour grading).

### Performance
- **Never on the render thread or the main thread.** Pictures are rendered on the pool's worker threads (at
  most 4, DecodePool.h:145) or its scrub thread.
- **Playback.** The lookahead (1 s by default, DecodePool.h:141) renders a title before it appears, and a static
  title is rendered once, so playback does no text work at all.
- **Typing while paused.**
  - Each keystroke is a new key. The scrub path keeps only the latest request per lane and interrupts the one
    in flight (DecodePool.h:222-230), so a burst of keys renders the last text, not every one.
  - The monitor keeps the previous complete picture until the new one lands (PlaybackController.mm:421-431),
    so it never flickers to "no title".
- **Export** waits for the picture as it waits for a decode.
- **Estimates to measure in slice 1:**
  - a 1080p lower third renders in under 5 ms;
  - a full-frame 4K page with a soft shadow in tens of milliseconds (Core Graphics blurs on the CPU, and its
    cost grows with area and radius);
  - the time from a keystroke to the presented picture, paused, under 50 ms.

### Parity
- **Same picture, same pixels.** Monitor and export render the same picture through the same code whenever k
  is the same: an export at the sequence size, and a monitor snapshot at the sequence size. Their pixels are
  then the existing parity tests' question, with titles as new cases (section 12).
- **One Mac only.** Two Macs with different versions of a font can draw it differently; parity is promised on
  one Mac.

## 4. Text over video
**Recommendation: no compositor change beyond section 3; confirm with tests.**
- **Over the picture below.** A title on V2 is a layer above V1's (layers are bottom to top, RenderGraph.h:160)
  with premultiplied colour, so it composites over the picture below with a transparent background.
- **Opacity.** A clip's Opacity and its Opacity spans multiply the layer's weight (Compositor.h:52-54).
- **Fades.** A lane-0 fade on an upper track fades the title over the tracks below, not over black: a single
  faded layer is drawn "over the black (or the tracks below)" (RenderGraph.h:70-76).
- **Transitions.** A cross dissolve between two titles mixes their premultiplied samples in one pass and never
  dips (Compositor.h:9-11). Wipes and the iris reveal per pixel as for any layer.
- **Motion spans** move and zoom the whole frame-sized canvas about the frame's centre, as for any clip. A
  zoom on an off-centre lower third therefore moves it outward as it grows. That is Premiere's and Final Cut's
  clip-transform behaviour; growing text in place is a text animation (slice 4).
- **Blend modes** (feature gap item 20) are not needed. Normal "over" is what titles need. Multiply or screen
  for stylised titles can come with item 20.

## 5. Does the clip grade apply to titles?
**Recommendation: no. Title and matte clips have no grade in slice 1.**
- **Engine.** Validation refuses a grade on a generated clip, as it does on an audio clip.
- **App.** Copy Grade and Paste Grade skip them, and the Colour tab says "Titles and colour mattes are not
  graded" when only they are selected.
- **Why.** A title's colours are chosen exactly, such as a brand colour or pure white. A grade pasted onto a
  selection that happens to include the titles would shift them without anyone noticing. A matte's colour is
  set directly.
- **What the editors do.** Premiere does not Lumetri-grade a graphics clip unless Lumetri is added to that
  clip. Final Cut's colour board applies to the clip it is put on.
- **Later.** If a graded title is ever wanted ("make the titles match this warm look"), it is an adjustment layer
  over picture and titles, or lifting this rule. The compositor already grades straight-alpha RGBA correctly
  (grading decision, section 1), so lifting the rule is only a validation and UI change.

## 6. Text features

**Slice 1 (one style per title):**
- the text, multiple lines (Return makes a line);
- the font: family and style;
- size;
- fill colour;
- alignment: left, centre, right;
- line spacing (a multiple, 1.0 by default);
- tracking (thousandths of an em, the unit Adobe and Final Cut use);
- outline: on/off, colour, width;
- drop shadow: on/off, colour, opacity, angle, distance, blur;
- background box: on/off, colour, opacity, padding, corner radius;
- position: the box's centre on the frame;
- box width: text wraps inside it; its height follows the text.

The block is "area text" (Premiere's paragraph text): the width wraps and the lines align inside the box.

**Units.** Positions are fractions of the frame's width and height. Sizes (font size, outline, shadow distance
and blur, padding, corner radius) are fractions of the frame's height.
- **Why.** A title then looks the same after Sequence Settings changes 1080p to 4K, as a fitted still does,
  and the 4K export of a 1080p-designed title is the same design. Resolve's Text+ (Fusion) also uses normalised
  frame coordinates.
- **The inspector** shows pixels of the current sequence ("Size 72 px" at 1080 lines) and converts.
- **A change of aspect ratio** (16:9 to 9:16) re-wraps the text at the new width, which is what such a change
  should do.

**Descriptor table.** The parameters are rows of a `TitleParameterInfo` table: name, display name, type (number,
colour, choice, toggle, text, font), unit, default and range, in the style of `GradeParameterInfo`
(ClipGrade.h:52-60). The file, the validation, the facade and, through review 1.11's direction, the Swift
inspector rows all read the same table.

Proposed defaults, to be tuned by eye in slice 1:
- the system font, Semibold;
- size 0.06 of the frame height (65 px at 1080);
- white text, centred;
- shadow on: black at 50 %, distance 0.003, blur 0.004;
- outline and box off;
- position at the centre;
- width 0.8 of the frame width.

**Later:**
- per-character and per-word styling (a lower third whose name is bold and role regular, in one title): slice 3,
  attributed text in the file;
- gradient fills: slice 3;
- shapes (rectangle, ellipse, line) as a generator kind: slice 3;
- user-saved templates and presets: slice 3;
- point text (no wrapping, grows with the text) and a vertical anchor (grow up or down from the position):
  slice 2;
- animation: rolling and crawling credits, typewriter, fade by line: slice 4.

## 7. Fonts
- **Which fonts.** The app is sandboxed (Framewright.entitlements). Fonts activated on the Mac (system fonts,
  `~/Library/Fonts`, Font Book) are served by the system's font service and should be available to a sandboxed
  app without an entitlement. This has to be confirmed on the sandboxed build in slice 1, not only in the test
  host, which is not sandboxed.
- **Listing them.** The family popup lists `CTFontManagerCopyAvailableFontFamilyNames`, and the style popup the
  members of the chosen family.
- **The system font** is stored as a token ("system" plus a weight), never by its PostScript name. Apple's UI
  font names (".SFNS...") are private and change between macOS versions.
- **Storing a font.** A title stores the PostScript name it was drawn with, plus the family and style names for
  display.
- **A missing font.** On a Mac without the font, the title is drawn in a fallback: the system font at the same
  weight where it can be matched, else regular. A substitution is noticed by comparing
  `CTFontCopyPostScriptName` of the font obtained with the stored name; `CTFontCreateWithName` substitutes
  silently.
  - **Where it is shown:**
    - a load warning names each missing font once, with how many titles use it;
    - the inspector's font row shows the stored name in italics with "Missing; shown in System";
    - the export sheet repeats the warning (a confirmation, not a refusal; Premiere also warns and substitutes).
  - **The name is kept.** It stays in the file unchanged until the user picks another font, so installing the
    font brings the title back exactly.
- **Licensing** is not Framewright's to manage. It uses fonts installed by the user, never embeds them in
  project files and bundles none. Whether a font's licence allows its use in a video is between the user and the
  font's vendor. The README can say so in one line.

## 8. Colour mattes
**Recommendation: a "Colour Matte" generator kind in slice 1.** It is a full-frame solid colour (a colour row
in the inspector, black by default), with the same clip behaviour as titles: still-like, Motion and opacity,
fades and dissolves, no grade. It costs a small model entry and a 4x4 picture (section 3).
- **What the editors do.** Premiere has New Item > Color Matte; Final Cut and Resolve have Solid Color
  generators.
- **Later.** A gradient matte (two colours, linear or radial, an angle) shares slice 3's gradient fill. A matte
  is also the natural "background" preset under a full-screen title card.

## 9. UI

**Adding a title.**
- **Menu items in the Clip menu:**
  - Add Title (⌃T) and Add Lower Third (⇧⌃T), Final Cut's shortcuts for its default title and lower third,
    and free in Framewright (only ⌃K is taken among Control keys, KeyboardController.swift:101);
  - Add Colour Matte (no shortcut).
- **The Effects tab.** It gains a "Titles and Generators" group with the three presets as tiles (Title, Lower
  Third, Colour Matte). Each tile can be dragged onto a track like media, overwriting at the drop point or
  inserting with Command (ProjectStore.swift:1505-1512), or added at the playhead with "+". The Effects browser
  (feature gap item 28) later absorbs this group.
- **Where it goes.** At the playhead, on the lowest video track above the target video track that is free for
  the title's whole length. If none is free, a new video track is added on top, in the same undo step. Nothing
  is overwritten or rippled.
  - This is the editors' convention: Final Cut connects the title above the storyline; Premiere puts a new
    graphic above the existing clips.
  - A title made with V1 targeted over V1's footage lands on V2 as an overlay without the user thinking about
    tracks.
- **Length.** The default is 5 s, `defaultStillDuration()` (Clip.h:57-60), the length a photo gets.
- **After adding.** The new clip is selected, and the inspector's text area gets the focus with the placeholder
  "Title" (or "Name" and "Role" for the lower third) selected, so typing replaces it.

**Editing text.** In slice 1, in the inspector: a multi-line text area at the top of a Text section, then
Font, Outline, Shadow and Background sections, then the usual Video (Motion) and Speed rows.

**On-monitor typing comes in slice 2.** Double-clicking the box would put a caret in the program monitor, as
Premiere's Type tool and Final Cut's viewer do. It is slice 2 because:
- the caret, selection and hit testing must follow the renderer's own Core Text layout, through the clip's
  Motion at the playhead;
- an AppKit text view laid over the monitor lays text out with TextKit, whose line breaks can differ from Core
  Text's by a word at the wrap width;
- doing it right means hit testing with `CTLineGetStringIndexForPosition` and `CTLineGetOffsetForStringIndex`
  over the renderer's lines, which is a round's worth of work on its own.

**The box on the program monitor.** It is drawn when exactly one title clip is selected, the playhead is inside
it, and no span is selected (a selected Motion span keeps opening the Ken Burns editor).
- **What is drawn:** the text block's box, through the clip's composed Motion at the playhead, plus thin
  outlines of the other titles at the playhead.
- **Dragging:**
  - the body moves the position;
  - the left or right edge, or a corner, changes the wrap width, about the box's centre;
  - each drag is one undo step, and Escape cancels it.
- **Reused machinery:**
  - `KenBurnsViewport` maps sequence and view coordinates;
  - `KenBurnsBox` gives rotation-aware geometry, since a rotated title's box turns with it;
  - `KenBurnsHit` does the hit testing;
  - the drag-group pattern (`beginDrag`, `applyDrag`, `endDrag`, `cancelDrag`, KenBurns.swift:514-612)
    coalesces through the facade.
- **A new model.** The model is new (`TitleBoxModel`): it writes the title's position and width, not a span.
  Moving the box renders nothing new (section 3), so the drag is as live as the Ken Burns boxes.
- **Under a zoom.** A drag under Motion converts the pointer's movement through the inverse of the clip's scale
  and rotation at the playhead.

**Safe-area guides (feature gap Tier 3, S): slice 2.** A View menu toggle draws the title-safe and action-safe
rectangles and centre marks over the program monitor.
- **Which rectangles.** The classic 80 % and 90 % of the frame; SMPTE ST 2046-1 defines 90 % and 93 % for HD.
  Recommended default: the SMPTE pair, with the classic pair as a preference. Premiere's Safe Margins and Final
  Cut's Show Title/Action Safe Zones draw these; their default percentages were not re-checked for this note.
- **Why not slice 1.** Slice 1 is already a full round, and for web video, where nothing is overscanned, the
  guides are composition aids, not limits. The lower-third preset sits inside title-safe by itself.

**On the timeline.**
- A title clip has its own colour (one not used by spans or transitions) and shows the first line of its text as
  its name ("Title" when empty).
- It has no thumbnails, so the thumbnail service never sees a generator asset.
- A colour matte shows its colour as a swatch at the clip's start and the name "Colour Matte".
- A missing font shows the warning badge used for missing media.

**Presets in slice 1:**
- **Title:** centred, the defaults above.
- **Lower Third:** left-aligned, positioned in the lower-left inside title-safe, two lines ("Name" and
  "Role"), a 60 % black background box with padding.
- **Colour Matte:** black.

Presets are code (a table), not files.

## 10. Undo, copy and paste, several selected
- **One step per edit.** Every control edit is one undo step. Slider drags and box drags coalesce into one step
  each (the facade's coalescing groups, VEEngine.h:20-32), as the grade's do.
- **Typing.** A typing run in the text area is one undo step. The run ends when the field loses focus, the
  selection changes or another edit is made. The text area turns off its own undo (`allowsUndo` false), so ⌘Z
  ends the run and undoes it as one step instead of mixing two undo stacks. This is the Replace coalescing mode:
  each keystroke sets the whole text.
- **Several titles selected.** Each style control shows its value where the titles agree and "Mixed" where they
  differ. Moving a control sets that parameter on all of them, as the grade controls and inspector rows do
  (GradeTools.swift). The text area is disabled with "Select one title to edit its text".
- **Title and matte together.** Only the shared rows (Video) show.
- **Copy Style and Paste Style: slice 2.** They work like Copy Grade (ProjectStore.swift:1315-1370) and carry
  everything except the text, the position and the box width: font, size, colours, alignment, spacing, outline,
  shadow, background. That is what Premiere's text styles and Final Cut's saved format attributes carry.
- **Clip copy and paste** (feature gap item 2) needs nothing title-specific: the content is the clip's.

## 11. Export and interchange
- **Export.** Nothing beyond parity. The export job builds the generated source at its output scale (section
  3) and waits for the picture as for a decode. The missing-font confirmation is the only new export UI.
- **FCPXML** (feature gap item 23). A title maps to a `<title>` that refers to a Basic Title `<effect>` resource,
  with the text and a text style. Font, size, colour, alignment and tracking have counterparts. Outline and
  shadow probably do, but the attributes must be checked against Apple's FCPXML DTD when item 23 is planned.
  The background box has none: it would be dropped with a note in the export's report. Position maps to the
  template's position parameter. A colour matte maps to Final Cut's Solid Color generator.
- **OTIO.** OTIO has no text schema. A title would be a `GeneratorReference` with a Framewright generator kind
  and its parameters as metadata, which other applications show as a gap or offline. A colour matte as a
  "SolidColor" generator reference is the convention some adapters read (to check with the adapters then).
- **EDL** cannot carry titles.
- **Both exports** must say what they drop, as item 23 already requires.

## 12. Tests
**Model and file (doctest):**
- **Generator assets and title content.** Equality, the content id (each parameter changes it; position does
  not), `maxMotionScale` against hand-computed span sets including an overshooting bezier, and the validation
  rules: no grade, video tracks only, still semantics, URL and size rules for generator assets only.
- **Schema 10:**
  - writer and parser round trip bit for bit;
  - unknown keys in a title are kept with a warning;
  - an unknown generator kind is refused with a message naming the path;
  - unused generator assets are not written.
- **The frozen 9 -> 10 step** changes only the version. A version 9 file that holds title keys anyway keeps
  them with a warning, as the 8 -> 9 step does (ProjectMigrations.cpp:1283-1316).
- **Goldens.** `golden/v10/*.migrated.json` for every older checked-in file, and a checked-in
  `golden/v10/project-v10.json` (a title with every style on, a lower third, a matte, a missing font) that the
  writer must match byte for byte. No existing golden changes.
- **The version 9 tests.** The version 9 "byte for byte" test (MigrationGoldenV9Tests.cpp:303) becomes a test of
  an older file. The other version 9 tests change only by the schema number, as 63d23c7 did for version 8.
  These changes are listed in open findings.

**Media and render:**
- **The generated source through the pool.** A test source (a numbered checkerboard) goes through the decode
  pool, the scrub path and the export wait; key changes reopen the stream and never publish a stale picture;
  epochs; interrupts. This lands as the first commit of the round, before any text.
- **Renderer:**
  - determinism: the same content renders the same bytes;
  - premultiplied tagging;
  - the outline is outside the fill (the fill's pixels are unchanged by turning the outline on);
  - the shadow scales with k (a k = 2 picture box-downsampled to k = 1 matches the k = 1 picture within a
    tolerance);
  - emoji draw without an outline;
  - an empty text gives a transparent picture.
- **Colour.** White text exports as Y' 235 / Cb 128 / Cr 128 in 420v and 940 in x420, black as 16 / 64, and an
  sRGB colour as its BT.709 encoding to within one code.
- **Sharpness:**
  - **1:1.** An export at the sequence size of a still title (no Motion) equals the renderer's picture at
    k = 1 drawn directly, within one code.
  - **Zoomed.** A clip at Motion scale 2 equals the k = 2 picture at 1:1.
  - **Larger export.** A 1080p export of a 720p sequence equals the k = 1.5 picture.
  - **Monitors.** In a half-size monitor, the edge measure of `EngineTests/Media/TextCard.h` stays within a
    stated fraction of the Lanczos reference.
  - **No sharpening** is applied to a generated layer, even with "Sharpen scaled-down sources" on.
- **Parity.** These cases are added to ExportParityTests:
  - a title over video;
  - a title with an Opacity span and a lane-0 fade;
  - a dissolve between two titles;
  - a title under a Ken Burns zoom;
  - a colour matte in a 10-bit export.
- **Fonts.** A project naming "NoSuchFont-Bold" loads, draws in the fallback, reports the missing font once,
  and saves the name unchanged. A system-font title saves the token, not a private name.
- **Performance.** The slice 1 estimates (section 3) are measured and written down, not asserted.

**App (AppTests):**
- **Placement:** above the target, a new track when none is free, one undo step.
- **Inspector:** "Mixed" values; the typing run is one undo step; text editing is disabled with several
  selected.
- **TitleBoxModel** geometry: through Motion and rotation, drag and resize, Escape cancel, one undo step per
  drag, with synthetic points as the Ken Burns tests use them.
- **Copy and Paste Grade** skip titles; the Colour tab shows its note.
- **Menus and tiles** enable and disable correctly.
- **Timeline** names and colours.

**What needs a person** (as recorded in open findings, the test host's events never reach SwiftUI gestures):
- dragging and resizing the box with the mouse;
- typing feel and undo in the real text area;
- the font popups with the user's own fonts;
- how text edges look over real footage at full screen;
- the sandboxed font list;
- a project opened on a Mac without its font, or with the font deactivated in Font Book.

## Decisions for the owner
1. Should a title be a clip of its own on a video track (an overlay, independent of the video below it), which
   keeps its own text and style, rather than an item in the media bin that clips refer to, as in Premiere and
   Final Cut? It is not attached to any video clip: over a picture on a lower track it is an overlay, on its own
   it is a title card. **Recommended: yes.** Splitting a title gives two independent titles, and the bin stays
   your media.
2. Should text stay sharp when a Motion or Ken Burns move zooms into it, or when you export larger than the
   sequence, at the cost of rendering it at the largest size it reaches? **Recommended: yes.**
3. Should titles and colour mattes be left out of colour grading, so Paste Grade over a selection never changes a
   title's colours? **Recommended: yes.** A graded look over titles can come later as an adjustment layer, like
   an adjustment layer in Photoshop above both photo and text.
4. Should a new title go at the playhead on the first free video track above the target track (a new track if
   none is free), 5 seconds long, overwriting nothing? **Recommended: yes**; this is the Final Cut and Premiere
   convention.
5. Should you type a title's text in the inspector in slice 1, with typing directly on the picture coming in
   slice 2? **Recommended: yes.** Moving and resizing the text box on the picture is in slice 1.
6. Should a title's position and sizes be stored relative to the frame, so a title looks the same after you
   change the sequence from 1080p to 4K, as a fitted photo does? **Recommended: yes.**
7. Should each title have one style in slice 1 (one font, size and colour for all its text), with a bold name and
   regular role in one lower third waiting for slice 3? **Recommended: yes.** In slice 1 a two-style lower third
   is two titles stacked.
8. When a project uses a font this Mac does not have, should the title show in the system font with a visible
   warning, and keep the font's name so it comes back once the font is installed? **Recommended: yes.**
9. Should colour mattes (a solid colour clip, like a plain backdrop) come in slice 1 from the same machinery?
   **Recommended: yes.**
10. Should the title-safe and action-safe guides (like crop guides on a camera's screen) come in slice 2 rather
   than slice 1? **Recommended: slice 2.** They matter for television; for web video they are composition aids.
11. Projects saved by the version with titles cannot be opened by 0.1.10 or earlier, even without titles, as with
   each earlier file format change. Is that acceptable? **Recommended: yes**; it is the existing rule.

## Slice plan
Each slice is sized as one implementer round, like "Colour grading slice 2". The order inside a slice is the
commit order; refactors are one extraction per commit, and the golden files never change.

### Slice 1: titles, lower thirds and colour mattes (L)
**Engine:**
1. Extract the bitmap set-up of `StillDrawing.mm` into a shared helper (no behaviour change).
2. The generated picture source, the `IVideoDecoder` adapter, `DecodeTarget` and `requestFrame` taking a
   source, and the `FrameKey` extension. Proved with a test source before any text exists.
3. **Model:**
   - generator kinds on `MediaAsset` and `isFileBacked()` at the URL sites;
   - `Clip::generated` (shared immutable `TitleContent` and the matte colour), the `TitleParameterInfo` table
     and the content id;
   - `maxMotionScale`;
   - the validation rules.
4. **Schema 10:**
   - writer and parser, unknown title keys kept;
   - the frozen 9 -> 10 step;
   - version 10 goldens and the checked-in version 10 project;
   - the version 9 tests' schema-number changes, listed in open findings.
5. **The title renderer:**
   - Core Text layout and glyph outlines;
   - outline, shadow (scaled by k) and box;
   - font resolution and substitution reporting;
   - the matte renderer.
6. **Compositor:**
   - `CanvasGeometry` placement in `placeSource` (uv rows on the CPU);
   - no sharpening for generated layers;
   - `VideoLayer` carries the content, position and the clip's maximum Motion scale (the Scheduler fills them).
7. **Consumers.** Playback and export compute k and build the source. Mixer and media library registration skip
   generator assets.
8. **Facade:**
   - add a title, lower third or matte at the playhead with the placement rule, one undo step including a new
     track and the generator asset;
   - set title parameters for clips, coalescable;
   - title content in `VEClipInfo`;
   - the missing fonts in load warnings and a query for the export sheet.

**App:**
- The Clip menu items and ⌃T / ⇧⌃T.
- The Effects tab's "Titles and Generators" tiles.
- The inspector's Text, Font, Outline, Shadow and Background sections and the matte's colour row: "Mixed" for
  several, the typing run as one step.
- The program monitor's title box (move, resize the width, through Motion).
- The timeline's look for title and matte clips.
- The Colour tab's note; Copy and Paste Grade skip titles.
- The export sheet's missing-font confirmation.

**Schema:** 9 -> 10.

**Tests:** section 12, all but slice 2's items.

**The owner hand-tests:**
- add a title over a clip with ⌃T and type it;
- style it: font, size, colour, outline, shadow, box;
- drag it into place and widen its box;
- fade it in and out, and dissolve between two titles;
- add a lower third over an interview shot;
- put a Ken Burns zoom on a title and check it stays sharp at the end;
- add a colour matte under a title card;
- export at the sequence size and at 1080p, and compare with the monitor at full screen;
- deactivate the title's font in Font Book, reopen the project, see the warning, reactivate it, see it return;
- undo and redo through all of it.

**If the round runs long,** the cut line is: the matte and the lower-third preset move to slice 2. The parity and
sharpness tests never move.

### Slice 2: editing titles on the picture (M-L)
- **Engine.** Hit testing over the renderer's lines (caret position and selection rectangles, through Motion);
  point text (no wrap) and the vertical anchor.
- **App:**
  - typing directly on the program monitor (double-click the box; Escape or a click outside ends it; one undo
    step per typing run);
  - safe-area guides and centre marks (View menu, with the guide percentages as a preference);
  - snapping the box to the frame's centre lines and the safe-area edges while dragging;
  - Copy Style and Paste Style;
  - more presets (a centred card over a matte, a top-left caption);
  - the font popup's recent fonts.
- **Schema.** None expected. Point text and the anchor may add two keys to the title object; if so it is a
  version step with goldens.
- **Tests:** caret mapping under Motion and rotation; the snapping model; style copy; the guides' rectangles.
- **The owner hand-tests:** typing on the picture, snapping, style copy across a set of lower thirds.

### Slice 3: rich text, gradients and shapes (L)
- **Engine:**
  - attributed text: runs with their own font, size, colour and tracking, laid out by the same framesetter;
  - gradient fills for text and a gradient matte;
  - a Shape generator: rectangle, rounded rectangle, ellipse, line, with fill, outline and shadow, sharing the
    renderer;
  - the matte's gradient.
- **App:**
  - selecting a word in the text area (and on the monitor) and styling it;
  - gradient editors;
  - the Shape tile;
  - user-saved title templates, stored per user, not in the project: a saved title's content under a name,
    shown in the Effects tab.
- **Schema:** 10 -> 11 (runs and gradients), with goldens.
- **Tests:** run layout against single-style layout, gradient parity, template round trip.
- **The owner hand-tests:** a two-style lower third, a gradient title, a shape behind text, a saved template.

### Slice 4: animated text (L, best planned with captions)
- **Engine:**
  - rolling and crawling credits: a tall or wide picture moved by a speed parameter, tiled past the 16384-pixel
    texture limit;
  - non-static titles for typewriter and per-line fades, using the source's per-frame mode, with
    frame-accurate parity in export.
- **App:** animation presets in the inspector (in/out, duration).
- **Schema:** animation parameters on the title.
- **Tests:** per-frame determinism, export parity across the animation, scrubbing a credits roll.
- **Relationship to captions.** Captions with burn-in (feature gap item 21) reuse the renderer and the
  non-static source; they can share this round or follow it.

## What this note could not verify
- **Fonts in the sandbox.** That user-activated fonts are available to the sandboxed app without an entitlement
  is from how macOS serves fonts. It is not tested here; slice 1 must check it on the sandboxed build.
- **Tracking API.** Which tracking attribute Core Text offers on macOS 14 (`kCTTrackingAttributeName`, or
  per-character kerning) is to be checked when built.
- **Interchange.** FCPXML's text-style attributes for outline and shadow, and how OTIO adapters treat generator
  references, are from memory and must be checked against the DTD and the adapters when item 23 is planned.
- **Safe areas.** Premiere's and Final Cut's default safe-area percentages were not re-checked.
- **Timings and memory** in section 3 are estimates. Slice 1 measures them.

## Sources
- Framewright code at f6ad9f4 as cited above; `docs/reviews/2026-10-01-grading-pipeline-decision.md`;
  `docs/reviews/2026-10-01-general-code-review.md` (2.1-2.4, 2.7, 1.11); `docs/plans/2026-10-01-premiere-lite-feature-gap.md`
  (items 1, 20, 21, 23, 27, 28 and Tier 3); `docs/reviews/open-findings.md`.
- Apple, "Quartz 2D Programming Guide: Shadows" (shadow offset and blur in base space, not affected by the
  transformation matrix).
- Apple, Final Cut Pro User Guide, keyboard shortcuts (Control-T connects the default title, Control-Shift-T the
  default lower third).
- SMPTE ST 2046-1 safe action (93 %) and safe title (90 %) areas, as summarised in NAB's TV Tech Check of 15 March
  2010 and Netflix's "Title Safe and Safe Action Best Practices".
- Adobe community discussions of Premiere's Vector Motion for graphics clips (text scaled past 100 % without
  softening).
