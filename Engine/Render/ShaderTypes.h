// Uniform layouts and binding indices shared by Shaders.metal and the Obj-C++ compositor.
//
// Members are 16-byte float4s (or float4x4s) or groups of 4-byte scalars (float, VEInt, VEUInt) that
// fill whole 16-byte rows, so the C (simd) and Metal layouts agree without relying on packing rules;
// the static_asserts at the end check the sizes and offsets on both sides.

#pragma once

#ifdef __METAL_VERSION__
#include <metal_stdlib>
typedef metal::float4 VEFloat4;
typedef metal::float4x4 VEFloat4x4;
typedef int VEInt;
typedef uint VEUInt;
#define VE_OFFSET_OF(type, member) __builtin_offsetof(type, member)
#else
#include <simd/simd.h>
#include <stddef.h>
#include <stdint.h>
typedef simd_float4 VEFloat4;
typedef simd_float4x4 VEFloat4x4;
typedef int32_t VEInt;
typedef uint32_t VEUInt;
#define VE_OFFSET_OF(type, member) offsetof(type, member)
#endif

// Buffer binding indices. Each index belongs to one pipeline's functions, and an encoder binds only
// its own pipeline's: the render pipeline (VEBufferIndexDraw) and the two compute kernels' uniforms
// share the number 0 without meeting.
enum VEBufferIndex {
    VEBufferIndexDraw = 0,    // VEDrawUniforms (vertex and fragment)
    VEBufferIndexConvert = 0, // VEConvertUniforms (compute)
    VEBufferIndexUnsharp = 0, // VEUnsharpUniforms (compute)
    // The luma waveform (LumaWaveform.h): its counts and uniforms, in its accumulate kernel and its
    // display pass alike.
    VEBufferIndexWaveformCounts = 0,
    VEBufferIndexWaveform = 1, // VEWaveformUniforms
    // The other scopes (Histogram.h): their counts and uniforms, as the waveform's.
    VEBufferIndexScopeCounts = 0,
    VEBufferIndexScopeUniforms = 1,
    // Every scope's accumulate kernel: the clipping counters of the frame (ScopeStats.h; two atomic uints,
    // the samples with a channel at or above white, and at or below black).
    VEBufferIndexScopeStats = 2,
    // The monitor output pass with the clipping overlay: the frame's rectangle in the target (float4: x0, y0,
    // x1, y1 in pixels); the letterbox bars outside it are never tinted.
    VEBufferIndexOutputFrame = 0,
};

// Texture binding indices, per pipeline as the buffer indices are.
enum VETextureIndex {
    VETextureIndexA0 = 0, // source A: luma (YCbCr) or the RGBA texture
    VETextureIndexA1 = 1, // source A: interleaved CbCr (YCbCr only)
    VETextureIndexB0 = 2, // partner source B (dissolve), same layout as A
    VETextureIndexB1 = 3,
    // An extended grade's tables (VEGradeTableRow), per source.
    VETextureIndexAGradeTables = 4,
    VETextureIndexBGradeTables = 5,
    // An extended grade's 3D LUTs (RGBA32Float texture3d; a 1x1x1 stand-in when none), per source.
    VETextureIndexAInputCube = 6,
    VETextureIndexALookCube = 7,
    VETextureIndexBInputCube = 8,
    VETextureIndexBLookCube = 9,
    // Compute conversion.
    VETextureIndexComposite = 0, // RGBA16Float intermediate (read)
    VETextureIndexOut0 = 1,      // BGRA, or luma of a biplanar target (write)
    VETextureIndexOut1 = 2,      // CbCr of a biplanar target (write)
    // Unsharp mask of a pre-scaled plane.
    VETextureIndexUnsharpSource = 0,      // the Lanczos output (read)
    VETextureIndexUnsharpDestination = 1, // the sharpened plane (write)
    // Output pass of a texture target (a monitor), and the luma waveform's accumulate kernel: the
    // RGBA16Float working texture (read).
    VETextureIndexWorking = 0,
};

// Function constants that specialise the fragment function (one pipeline per combination).
enum VEFunctionConstant {
    VEFunctionConstantSourceAIsYCbCr = 0,
    VEFunctionConstantHasPartner = 1,
    VEFunctionConstantSourceBIsYCbCr = 2,
    // The source has a grade (VEGradeUniforms; ColorGrade.h): graded after its conversion, unclamped until
    // the end of the grade. Without it a source is drawn exactly as before grading existed.
    VEFunctionConstantSourceAHasGrade = 3,
    VEFunctionConstantSourceBHasGrade = 4,
    // The monitor output pass (ve_output_fragment) tints clipped pixels (kVEScopeClipTolerance): a monitor's
    // clipping overlay. Absent or false: the output pass is a plain copy.
    VEFunctionConstantClippingOverlay = 5,
    // The source's grade uses a slice 2 stage (VEGradeUniforms::stages: the wheels, ...): the grade runs
    // veGradeExtended, each stage skipped by its bit when unused. Without it a graded source runs the slice 1
    // grade exactly as before. Only with the matching ...HasGrade.
    VEFunctionConstantSourceAHasExtendedGrade = 6,
    VEFunctionConstantSourceBHasExtendedGrade = 7,
};

// The slice 2 stages of a grade (VEGradeUniforms::stages), each run only when its bit is set.
enum VEGradeStage {
    VEGradeStageWheels = 1, // lift / gamma / gain (ColorGrade.h, veApplyWheels)
    VEGradeStageCurves = 2, // the tone curves (veApplyCurves; VEGradeUniforms::curveMask says which)
    VEGradeStageInputLut = 4, // the input LUT, before the grade (veApplyLut)
    VEGradeStageLookLut = 8,  // the look LUT, after the curves, mixed by lookStrength
    VEGradeStageHueCurves = 16, // the hue curves (veApplyHueCurves; VEGradeUniforms::hueCurveMask says which)
};

// VEGradeUniforms::lutFlags: which LUT is 3D (a texture3d of its own, read with tetrahedral interpolation);
// a 1D LUT is three rows of the grade's tables.
enum VEGradeLutFlag {
    VEGradeLutInputIs3D = 1,
    VEGradeLutLookIs3D = 2,
};

// The grade's tables (veTableLookup): one R32Float texture per graded source, kVEGradeTableWidth samples per
// row over [0, 1], a row per curve and per channel of a 1D LUT (VEGradeTableRow; a LUT's rows over its
// domain). Built on the CPU from the clip's curves and 1D LUTs (gradeTableData).
#define kVEGradeTableWidth 1024u
enum VEGradeTableRow {
    VEGradeTableRowLuma = 0,
    VEGradeTableRowRed = 1,
    VEGradeTableRowGreen = 2,
    VEGradeTableRowBlue = 3,
    VEGradeTableRowInputLut = 4, // red, green, blue of a 1D input LUT: rows 4, 5, 6
    VEGradeTableRowLookLut = 7,  // of a 1D look: rows 7, 8, 9
    // The hue curves (periodic rows: sample i at hue i / kVEGradeTableWidth).
    VEGradeTableRowHueSaturation = 10,
    VEGradeTableRowHueHue = 11,
    VEGradeTableRowHueLuma = 12,
    VEGradeTableRowCount = 13,
};

// How close to white (1) or black (0) a channel of the working picture counts as clipped, for the scopes'
// clipping counters and the monitor's clipping overlay: 2^-12, a quarter of a 10-bit code. The working
// texture is half float, whose largest value below 1 is 1 - 2^-11, so a channel counts as clipped white
// exactly when it is stored as 1 or more; a channel within 2^-12 of 0 (the YCbCr matrix's float residue at
// video black, stored as the smallest half subnormals) counts as black, while 10-bit code 1 (2^-10) does not.
#define kVEScopeClipTolerance 2.44140625e-04f

// The transfer curve a graded source is linearised by (VEGradeUniforms::transfer; ColorGrade.h).
enum VEGradeTransfer {
    VEGradeTransferBT1886 = 0, // pure 2.4 power: BT.709, BT.601, SMPTE 240M and untagged video
    VEGradeTransferSRGB = 1,   // the sRGB curve: sRGB-tagged sources and stills
    VEGradeTransferLinear = 2, // identity
};

// A source's colour grade (ColorGrade.h, gradeUniformsFor). Read only when the source's grade function
// constant is set.
struct VEGradeUniforms {
    // xyz: the linear-light channel gains, 2^exposure times the luminance-normalised white-balance gains;
    // w unused (0).
    VEFloat4 gain;
    float saturation;
    float contrast;
    // The contrast curve's linear segment below epsilon: f(epsilon) / epsilon.
    float contrastSlope;
    // The VEGradeTransfer.
    VEInt transfer;
    // Slice 2, read only with the source's extended-grade function constant. The wheels (VEGradeStageWheels),
    // per channel in xyz (w unused, 0): the lift offset, the gain, the gamma's exponent 1 / gamma, and that
    // power's linear segment below epsilon, epsilon^(1 / gamma) / epsilon.
    VEFloat4 lift;
    VEFloat4 wheelGain;
    VEFloat4 inverseGamma;
    VEFloat4 gammaSlope;
    // The VEGradeStage bits of the stages to run.
    VEUInt stages;
    // VEGradeStageCurves: the curves in use, bit 1 << VEGradeTableRow (the others are the identity).
    VEUInt curveMask;
    // The VEGradeLutFlag bits, and the look's strength (0 to 1: how much of its change is kept).
    VEUInt lutFlags;
    float lookStrength;
    // Each LUT's domain: a value v is looked up at (v - domainMin) * domainScale, limited to [0, 1] (xyz; w 0).
    VEFloat4 inputDomainMin;
    VEFloat4 inputDomainScale;
    VEFloat4 lookDomainMin;
    VEFloat4 lookDomainScale;
    // The sizes of 3D LUTs (entries per side; 0 for a 1D LUT or none).
    VEUInt inputCubeSize;
    VEUInt lookCubeSize;
    // VEGradeStageHueCurves: the hue curves in use, bit 1 << GradeHueCurve (saturation, hue, luma).
    VEUInt hueCurveMask;
    VEUInt unused0;
};

// The shape of a transition draw (VETransitionUniforms::shape), TransitionKind's values
// (Compositor.mm static_asserts them): None is the cross dissolve, the uniform mix.
enum VETransitionShape {
    VETransitionShapeNone = 0,
    VETransitionShapeWipeLeft = 1,
    VETransitionShapeWipeRight = 2,
    VETransitionShapeWipeUp = 3,
    VETransitionShapeWipeDown = 4,
    VETransitionShapeIris = 5,
};

// How one source picture is sampled, graded and placed.
struct VESourceUniforms {
    // Maps the sampled (Y, Cb, Cr, 1) plane values (texture unorm, i.e. before range expansion)
    // to gamma-encoded R'G'B'. Folds bit depth, video/full range and the YCbCr matrix.
    // Unused for RGBA sources.
    VEFloat4x4 colorMatrix;
    // Inverse placement: source uv = (dot(uvFromFrameX.xyz, (px, py, 1)), dot(uvFromFrameY.xyz, ...))
    // where (px, py) is a position in sequence pixels (origin top left, +y down).
    VEFloat4 uvFromFrameX;
    VEFloat4 uvFromFrameY;
    // Chroma plane uv = uv * chromaTransform.xy + chromaTransform.zw (chroma siting and odd
    // sizes; see TextureCache.h). Unused for RGBA sources.
    VEFloat4 chromaTransform;
    // The layer weight: its opacity, times the transition weight when drawn without its partner.
    float weight;
    // 1 when an RGBA source has straight (non-premultiplied) alpha, else 0.
    VEUInt straightAlpha;
    VEUInt unused0;
    VEUInt unused1;
    // The part of each plane's texture the picture fills, in that texture's uv: xy for plane 0 (luma or RGBA),
    // zw for plane 1 (chroma). (1, 1) for a source plane; a pre-scaled plane lies in the top-left w x h of a
    // pooled texture at least that large, and is sampled clamped half a texel inside that region's right and
    // bottom edges (as clamp_to_edge clamps a whole texture).
    VEFloat4 planeExtent;
    // The source's colour grade, applied after the conversion to R'G'B' and before the coverage, the weight
    // and the blend (docs/reviews/2026-10-01-grading-pipeline-decision.md, section 1); all zero and unread
    // for an ungraded source.
    struct VEGradeUniforms grade;
};

// The transition of one draw (RenderGraph.h, LayerTransition; transitionReveal). All zero but `mix` for
// a cross dissolve, and all zero for a layer without a transition, whose draws are unchanged.
struct VETransitionUniforms {
    // The transition's linear progress at the frame's centre (LayerTransition::mix): the dissolve mix
    // toward source B of a pair draw.
    float mix;
    // A shaped transition's exposure interval [progressStart, progressEnd] (LayerTransition::progressStart /
    // progressEnd; mirrored to [1 - p1, 1 - p0] for a closing iris), over which its edge is averaged
    // (transitionReveal); zero for a dissolve.
    float progressStart;
    float progressEnd;
    // The soft edge's half width f in sequence pixels (LayerTransition::softness, by default
    // kTransitionFeather); zero for a dissolve.
    float feather;
    // The VETransitionShape.
    VEInt shape;
    // A single-layer draw of a shaped transition: 1 when it is the incoming picture (drawn where the
    // reveal m is, times m; also a closing iris), 0 for the outgoing one (times 1 - m). Unused for pair
    // draws, which show mix(A, B, m) per pixel.
    VEUInt incoming;
    VEUInt unused0;
    VEUInt unused1;
};

// One draw: an axis-aligned quad in sequence pixels covering the layer (or the pair).
struct VEDrawUniforms {
    VEFloat4 quadRect;  // x0, y0, x1, y1 in sequence pixels
    VEFloat4 frameSize; // sequence width, height, 1/width, 1/height
    struct VETransitionUniforms transition;
    struct VESourceUniforms a;
    struct VESourceUniforms b;
};

// The unsharp mask of a pre-scaled plane (Compositor.h "Sharpening").
struct VEUnsharpUniforms {
    float amount;
    // The mask fades in over |c - blur| in [threshold, 2 * threshold].
    float threshold;
    // A luma plane's nominal range in unorm (16/255 and 235/255 for 8-bit video range...): the
    // sharpened luma is kept within [min(rangeLow, c), max(rangeHigh, c)]. Unused for RGBA.
    float rangeLow;
    float rangeHigh;
    // The pre-scaled plane's size in texels (the top-left region of its pooled textures it fills; the
    // kernel runs over it and reads its neighbours clamped to it).
    VEUInt width;
    VEUInt height;
    // 1 for a luma plane (sharpen .r within the range above), 0 for premultiplied RGBA (sharpen .rgb
    // within [0, alpha], keep alpha).
    VEUInt isLuma;
    VEUInt unused0;
};

// RGB -> output conversion for the export compute pass.
struct VEConvertUniforms {
    // Rows mapping (R', G', B', 1) to the unorm plane values Y, Cb, Cr (biplanar targets only).
    VEFloat4 yRow;
    VEFloat4 cbRow;
    VEFloat4 crRow;
    // The output luma size in pixels.
    VEUInt width;
    VEUInt height;
    // 1: the target stores 10-bit codes in the high bits of 16-bit words ('x420'), 0: 8-bit planes.
    VEUInt tenBitCodes;
    VEUInt unused0;
};

// The luma waveform of a frame (LumaWaveform.h): its accumulate kernel counts, per column of the frame and
// luma level, the samples of the working texture there; its display pass draws the counts.
struct VEWaveformUniforms {
    // The frame in the working texture: x, y, width, height in texels.
    VEFloat4 frame;
    // The display target's width and height in pixels; zw unused (0).
    VEFloat4 target;
    // The waveform's columns (across the frame's width) and luma levels (0 black ... levels - 1 white).
    VEUInt columns;
    VEUInt levels;
    // Rows of the frame sampled (evenly spaced; the kernel's grid is frame width x sampleRows).
    VEUInt sampleRows;
    // Display: the trace's brightness per count (1 - exp(-count * gain)).
    float gain;
};

// A histogram of a frame (Histogram.h): its accumulate kernel counts the samples of the working texture per
// channel (R, G, B, luma) and level; its finish kernel finds the tallest bars; its display pass draws them.
//
// The counts buffer: kVEHistogramChannels rows of kVEHistogramBins uints (row 0 red, 1 green, 2 blue, 3 luma;
// bin b holds the samples whose value rounds to b / (bins - 1)), then the finish kernel's four uints: the
// tallest red, green or blue bar and the tallest luma bar between the end bins, then the same over every bin.
#define kVEHistogramBins 256u
#define kVEHistogramChannels 4u
#define kVEHistogramMaximaOffset (kVEHistogramBins * kVEHistogramChannels)
#define kVEHistogramCountsLength (kVEHistogramMaximaOffset + 4u)
// A threadgroup of the accumulate kernel is kVEHistogramGroupSide^2 threads; each counts a
// kVEHistogramTileSide-pixel square tile's pixels in threadgroup memory, then adds them to the counts.
#define kVEHistogramGroupSide 16u
#define kVEHistogramTileSide 64u
struct VEHistogramUniforms {
    // The frame in the working texture: x, y, width, height in texels.
    VEFloat4 frame;
    // The display target's width and height in pixels; zw unused (0).
    VEFloat4 target;
    // The VEHistogramStyle of the display (0 RGB and luma overlaid, 1 luma, 2 RGB parade).
    VEUInt style;
    VEUInt unused0;
    VEUInt unused1;
    VEUInt unused2;
};

// A vectorscope of a frame (Vectorscope.h): its accumulate kernel counts the samples of the working texture by
// their BT.709 chroma (Cb across, Cr up, each -0.5 to 0.5) in a kVEVectorscopeBins x kVEVectorscopeBins grid
// (row r, column c: Cr from the bottom, Cb from the left); its display pass draws the counts in a square
// centred in the target, over the graticule.
#define kVEVectorscopeBins 256u
struct VEVectorscopeUniforms {
    // The frame in the working texture: x, y, width, height in texels.
    VEFloat4 frame;
    // The display target's width and height in pixels; zw unused (0).
    VEFloat4 target;
    // The 75 % colour bars' chroma (Cb, Cr), the graticule's targets: red and magenta, blue and cyan, green and
    // yellow (xy, zw of each).
    VEFloat4 targets[3];
    // The skin tone line's direction (cos, sin of its angle from the Cb axis); zw unused (0).
    VEFloat4 skinLine;
    // Rows of the frame sampled (evenly spaced; the kernel's grid is frame width x sampleRows).
    VEUInt sampleRows;
    // Display: the trace's brightness per count (1 - exp(-count * gain)).
    float gain;
    VEUInt unused0;
    VEUInt unused1;
};

// The same layout on both sides: sizes, and the offset of every member that follows a scalar group or
// starts one.
static_assert(sizeof(struct VEGradeUniforms) == 192, "VEGradeUniforms layout");
static_assert(VE_OFFSET_OF(struct VEGradeUniforms, lookStrength) == 108, "VEGradeUniforms layout");
static_assert(VE_OFFSET_OF(struct VEGradeUniforms, inputDomainMin) == 112, "VEGradeUniforms layout");
static_assert(VE_OFFSET_OF(struct VEGradeUniforms, inputCubeSize) == 176, "VEGradeUniforms layout");
static_assert(VE_OFFSET_OF(struct VEGradeUniforms, saturation) == 16, "VEGradeUniforms layout");
static_assert(VE_OFFSET_OF(struct VEGradeUniforms, transfer) == 28, "VEGradeUniforms layout");
static_assert(VE_OFFSET_OF(struct VEGradeUniforms, lift) == 32, "VEGradeUniforms layout");
static_assert(VE_OFFSET_OF(struct VEGradeUniforms, gammaSlope) == 80, "VEGradeUniforms layout");
static_assert(VE_OFFSET_OF(struct VEGradeUniforms, stages) == 96, "VEGradeUniforms layout");
static_assert(sizeof(struct VESourceUniforms) == 336, "VESourceUniforms layout");
static_assert(VE_OFFSET_OF(struct VESourceUniforms, weight) == 112, "VESourceUniforms layout");
static_assert(VE_OFFSET_OF(struct VESourceUniforms, straightAlpha) == 116, "VESourceUniforms layout");
static_assert(VE_OFFSET_OF(struct VESourceUniforms, planeExtent) == 128, "VESourceUniforms layout");
static_assert(VE_OFFSET_OF(struct VESourceUniforms, grade) == 144, "VESourceUniforms layout");
static_assert(sizeof(struct VETransitionUniforms) == 32, "VETransitionUniforms layout");
static_assert(VE_OFFSET_OF(struct VETransitionUniforms, shape) == 16, "VETransitionUniforms layout");
static_assert(VE_OFFSET_OF(struct VETransitionUniforms, incoming) == 20, "VETransitionUniforms layout");
static_assert(sizeof(struct VEDrawUniforms) == 64 + 2 * 336, "VEDrawUniforms layout");
static_assert(VE_OFFSET_OF(struct VEDrawUniforms, transition) == 32, "VEDrawUniforms layout");
static_assert(VE_OFFSET_OF(struct VEDrawUniforms, a) == 64, "VEDrawUniforms layout");
static_assert(VE_OFFSET_OF(struct VEDrawUniforms, b) == 64 + 336, "VEDrawUniforms layout");
static_assert(sizeof(struct VEUnsharpUniforms) == 32, "VEUnsharpUniforms layout");
static_assert(VE_OFFSET_OF(struct VEUnsharpUniforms, width) == 16, "VEUnsharpUniforms layout");
static_assert(VE_OFFSET_OF(struct VEUnsharpUniforms, isLuma) == 24, "VEUnsharpUniforms layout");
static_assert(sizeof(struct VEConvertUniforms) == 64, "VEConvertUniforms layout");
static_assert(VE_OFFSET_OF(struct VEConvertUniforms, width) == 48, "VEConvertUniforms layout");
static_assert(VE_OFFSET_OF(struct VEConvertUniforms, tenBitCodes) == 56, "VEConvertUniforms layout");
static_assert(sizeof(struct VEWaveformUniforms) == 48, "VEWaveformUniforms layout");
static_assert(VE_OFFSET_OF(struct VEWaveformUniforms, columns) == 32, "VEWaveformUniforms layout");
static_assert(VE_OFFSET_OF(struct VEWaveformUniforms, gain) == 44, "VEWaveformUniforms layout");
static_assert(sizeof(struct VEHistogramUniforms) == 48, "VEHistogramUniforms layout");
static_assert(sizeof(struct VEVectorscopeUniforms) == 112, "VEVectorscopeUniforms layout");
static_assert(VE_OFFSET_OF(struct VEVectorscopeUniforms, targets) == 32, "VEVectorscopeUniforms layout");
static_assert(VE_OFFSET_OF(struct VEVectorscopeUniforms, sampleRows) == 96, "VEVectorscopeUniforms layout");
static_assert(VE_OFFSET_OF(struct VEHistogramUniforms, style) == 32, "VEHistogramUniforms layout");
