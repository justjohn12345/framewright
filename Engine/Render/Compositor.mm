#include "Compositor.h"

#include "../Media/ColorTags.h"
#include "../Media/MediaTypes.h"
#include "ColorGrade.h"
#include "ColorMath.h"
#include "ShaderTypes.h"

#import <MetalPerformanceShaders/MetalPerformanceShaders.h>

#include <algorithm>
#include <atomic>
#include <bit>
#include <cmath>
#include <cstring>
#include <mutex>
#include <string>
#include <utility>

// Anchor class for locating the framework bundle (and its default.metallib).
@interface VECompositorBundleAnchor : NSObject
@end
@implementation VECompositorBundleAnchor
@end

namespace ve::render {

using media::makeError;
using media::MediaErrorCode;
using media::PixelBuffer;
using media::Result;
using media::Status;

// The uniform layouts are checked on both sides of the C / Metal boundary in ShaderTypes.h.
static_assert(int(VETransitionShapeNone) == int(TransitionKind::CrossDissolve) &&
                  int(VETransitionShapeWipeLeft) == int(TransitionKind::WipeLeft) &&
                  int(VETransitionShapeWipeRight) == int(TransitionKind::WipeRight) &&
                  int(VETransitionShapeWipeUp) == int(TransitionKind::WipeUp) &&
                  int(VETransitionShapeWipeDown) == int(TransitionKind::WipeDown) &&
                  int(VETransitionShapeIris) == int(TransitionKind::Iris),
              "VETransitionShape must follow TransitionKind");

PixelRect fitRect(double sourceWidth, double sourceHeight, std::int32_t destWidth, std::int32_t destHeight) {
    if (!(sourceWidth > 0) || !(sourceHeight > 0) || destWidth <= 0 || destHeight <= 0) {
        return {};
    }
    const double scale = std::min(destWidth / sourceWidth, destHeight / sourceHeight);
    const double fittedWidth = sourceWidth * scale;
    const double fittedHeight = sourceHeight * scale;
    // Bars under a pixel on each side cannot be drawn as bars (rounded, they become a one-pixel black
    // line on one edge): such an axis fills the destination, stretching the picture by under 2 px.
    PixelRect r;
    r.width = destWidth - fittedWidth < 2.0 ? destWidth
                                            : std::clamp(static_cast<std::int32_t>(std::lround(fittedWidth)), 1, destWidth);
    r.height = destHeight - fittedHeight < 2.0
                   ? destHeight
                   : std::clamp(static_cast<std::int32_t>(std::lround(fittedHeight)), 1, destHeight);
    r.x = (destWidth - r.width) / 2;
    r.y = (destHeight - r.height) / 2;
    return r;
}

namespace {

// The part of `r` inside [0, width) x [0, height).
PixelRect clipRect(const PixelRect &r, std::int32_t width, std::int32_t height) {
    const std::int64_t x0 = std::max<std::int64_t>(r.x, 0);
    const std::int64_t y0 = std::max<std::int64_t>(r.y, 0);
    const std::int64_t x1 = std::min<std::int64_t>(std::int64_t(r.x) + r.width, width);
    const std::int64_t y1 = std::min<std::int64_t>(std::int64_t(r.y) + r.height, height);
    if (x1 <= x0 || y1 <= y0) {
        return {};
    }
    return {std::int32_t(x0), std::int32_t(y0), std::int32_t(x1 - x0), std::int32_t(y1 - y0)};
}

constexpr std::size_t kUniformAlignment = 256; // constant-buffer offset alignment (macOS)
constexpr std::size_t kInitialDrawCapacity = 64;
constexpr MTLPixelFormat kIntermediateFormat = MTLPixelFormatRGBA16Float;

// Minification (see Compositor.h): a plane drawn at fewer than kMinifyThreshold output pixels
// per texel (along either axis) is first resampled with a Lanczos filter to about its drawn
// size, then sampled bilinearly at ~1:1 as usual.
constexpr double kMinifyThreshold = 0.75;
// Pre-scaled planes are pooled by (format, size); a pooled texture unused for this many frames
// is released.
constexpr std::uint64_t kScratchIdleFrames = 120;
constexpr std::size_t kMaxScratchTextures = 24;

constexpr std::size_t alignUp(std::size_t v, std::size_t a) {
    return (v + a - 1) / a * a;
}
constexpr std::size_t kDrawStride = alignUp(sizeof(VEDrawUniforms), kUniformAlignment);
constexpr std::size_t kConvertStride = alignUp(sizeof(VEConvertUniforms), kUniformAlignment);

struct PipelineKey {
    bool aIsYCbCr = false;
    bool hasPartner = false;
    bool bIsYCbCr = false;
    MTLPixelFormat format = MTLPixelFormatInvalid;
    // The sources' grades (VEFunctionConstantSourceAHasGrade / ...BHasGrade), and whether they use a slice 2
    // stage (VEFunctionConstantSourceAHasExtendedGrade / ...B; only with the grade).
    bool aIsGraded = false;
    bool bIsGraded = false;
    bool aIsExtended = false;
    bool bIsExtended = false;

    std::uint64_t packed() const {
        return (static_cast<std::uint64_t>(format) << 7) | (aIsYCbCr ? 1u : 0u) | (hasPartner ? 2u : 0u) |
               (hasPartner && bIsYCbCr ? 4u : 0u) | (aIsGraded ? 8u : 0u) | (hasPartner && bIsGraded ? 16u : 0u) |
               (aIsGraded && aIsExtended ? 32u : 0u) | (hasPartner && bIsGraded && bIsExtended ? 64u : 0u);
    }
};

// Where a source lands in the sequence frame and how to map back to its uv.
struct Placement {
    simd_float4 uvFromFrameX;
    simd_float4 uvFromFrameY;
    double x0, y0, x1, y1; // bounding box in sequence pixels, 1 px margin for the AA edge, clipped
    double scale = 0;      // sequence pixels per source (storage) pixel
    bool visible = false;
};

// Container rotation normalised to 0, 90, 180 or 270 (clockwise); other angles are rounded to
// the nearest quarter turn (containers only store quarter turns).
int quarterTurnsClockwise(std::int32_t degrees) {
    const long turns = std::lround(static_cast<double>(degrees) / 90.0);
    return static_cast<int>(((turns % 4) + 4) % 4);
}

// Where a picture's displayed rectangle lands in the sequence frame: the fit, the centre, the size and the rotation
// (cosine and sine) of the clip transform applied to it (see placeSource).
struct Fitted {
    double sourceWidth = 0; // displayed orientation
    double sourceHeight = 0;
    double fit = 1;
    double cx = 0;
    double cy = 0;
    double sx = 0; // displayed size in sequence pixels
    double sy = 0;
    double c = 1;
    double s = 0;
    int quarterTurns = 0;
    bool ok = false;
};

Fitted fitSource(const VideoParams &params, std::int32_t sourceRotationDegrees, double storageWidth,
                 double storageHeight, double frameWidth, double frameHeight) {
    Fitted f;
    f.quarterTurns = quarterTurnsClockwise(sourceRotationDegrees);
    const bool swapped = (f.quarterTurns & 1) != 0;
    f.sourceWidth = swapped ? storageHeight : storageWidth;
    f.sourceHeight = swapped ? storageWidth : storageHeight;
    f.fit = std::min(frameWidth / f.sourceWidth, frameHeight / f.sourceHeight);
    f.cx = frameWidth / 2.0 + params.x;
    f.cy = frameHeight / 2.0 + params.y;
    // Pixel exact: a picture that covers the frame with under 2 px to spare on each axis (a frame taken
    // from it with odd sides rounded down, see formatAdoptedFrom) has its base place at exactly its own
    // size with its top-left pixel on the frame's, the spare column and row cropped, rather than scaled
    // by a fraction of a pixel (a blur). Decided from the sizes alone, never from the clip transform,
    // which applies about that base (scale about the picture's centre, rotation, offset) for every
    // value: a Ken Burns or Motion move through scale 1 stays continuous (deciding it from the
    // animated transform drew that one frame 1:1 and top-left, the next fitted and centred: a jump of
    // half a pixel and a crop change), and the identity transform is pixel exact.
    if (f.sourceWidth >= frameWidth && f.sourceHeight >= frameHeight && f.sourceWidth - frameWidth < 2.0 &&
        f.sourceHeight - frameHeight < 2.0) {
        f.fit = 1.0;
        f.cx = f.sourceWidth / 2.0 + params.x;
        f.cy = f.sourceHeight / 2.0 + params.y;
    }
    f.sx = f.sourceWidth * f.fit * params.scale;
    f.sy = f.sourceHeight * f.fit * params.scale;
    if (!(f.sx > 1e-6) || !(f.sy > 1e-6) || !std::isfinite(f.sx) || !std::isfinite(f.sy)) {
        return f;
    }
    const double theta = params.rotationDegrees * M_PI / 180.0;
    f.c = std::cos(theta);
    f.s = std::sin(theta);
    f.ok = true;
    return f;
}

// Bounding box of points `xs`, `ys` (sequence pixels) with 1 px margin for the AA edge, clipped to the frame.
void setBoundingBox(Placement &p, std::initializer_list<double> xs, std::initializer_list<double> ys, double frameWidth,
                    double frameHeight) {
    const auto [xMin, xMax] = std::minmax(xs);
    const auto [yMin, yMax] = std::minmax(ys);
    p.x0 = std::max(0.0, std::floor(xMin) - 1.0);
    p.y0 = std::max(0.0, std::floor(yMin) - 1.0);
    p.x1 = std::min(frameWidth, std::ceil(xMax) + 1.0);
    p.y1 = std::min(frameHeight, std::ceil(yMax) + 1.0);
    p.visible = p.x1 > p.x0 && p.y1 > p.y0;
}

// Geometry, in order: the decoded (storage-orientation) picture is rotated by the container
// rotation, the rotated picture is fitted into the sequence frame, then the clip transform
// (scale about the centre, rotation, offset) is applied. The returned rows map a sequence
// position to storage uv.
Placement placeSource(const VideoParams &params, std::int32_t sourceRotationDegrees, double storageWidth,
                      double storageHeight, double frameWidth, double frameHeight) {
    Placement p{};
    const Fitted f = fitSource(params, sourceRotationDegrees, storageWidth, storageHeight, frameWidth, frameHeight);
    if (!f.ok) {
        return p;
    }
    const double c = f.c, s = f.s, cx = f.cx, cy = f.cy, sx = f.sx, sy = f.sy;
    // Displayed uv' of a sequence position. Forward: p = centre + R (uv' - 0.5) * size,
    // R = [c -s; s c] (clockwise with +y down). Inverse: uv' = 0.5 + R^T (p - centre) / size.
    const simd_float4 ux = simd_make_float4(float(c / sx), float(s / sx), float(0.5 - (c * cx + s * cy) / sx), 0.0f);
    const simd_float4 uy = simd_make_float4(float(-s / sy), float(c / sy), float(0.5 - (-s * cx + c * cy) / sy), 0.0f);
    // Storage uv from displayed uv' (the storage picture turned clockwise by quarterTurns):
    //   90: u = v', v = 1 - u'   180: u = 1 - u', v = 1 - v'   270: u = 1 - v', v = u'
    const simd_float4 one = simd_make_float4(0.0f, 0.0f, 1.0f, 0.0f);
    switch (f.quarterTurns) {
    case 1:
        p.uvFromFrameX = uy;
        p.uvFromFrameY = one - ux;
        break;
    case 2:
        p.uvFromFrameX = one - ux;
        p.uvFromFrameY = one - uy;
        break;
    case 3:
        p.uvFromFrameX = one - uy;
        p.uvFromFrameY = ux;
        break;
    default:
        p.uvFromFrameX = ux;
        p.uvFromFrameY = uy;
        break;
    }
    p.scale = f.fit * params.scale;
    // Bounding box of the rotated rectangle.
    const double hx = std::fabs(c) * sx / 2.0 + std::fabs(s) * sy / 2.0;
    const double hy = std::fabs(s) * sx / 2.0 + std::fabs(c) * sy / 2.0;
    setBoundingBox(p, {cx - hx, cx + hx}, {cy - hy, cy + hy}, frameWidth, frameHeight);
    return p;
}

// A generated picture (a title or a matte; GeneratedSource.h): the frame-sized canvas it stands for is placed as a
// frame-sized still is (placeSource, no container rotation), and the picture covers the rectangle `geometry` of it,
// anchored at (anchorX, anchorY). The rows map a sequence position to the picture's uv through the canvas's (an
// affine change of the two rows, on the CPU), the scale is in sequence pixels per texel of the picture
// (`textureWidth` x `textureHeight` texels over the rectangle), and the quad covers the rectangle only. Outside it
// the shader's edge coverage is 0: the rest of the canvas is transparent.
// On the target's pixel grid: when its clip's Motion does not change (`animated` false) and the picture is drawn
// unrotated at one target pixel per texel (`targetScaleX` and `targetScaleY` are target pixels per sequence pixel)
// or smaller (a monitor smaller than the sequence), its corner is moved (by under half a target pixel) onto a whole
// target pixel, so it is not resampled at a fractional offset (a title's position is a fraction of the frame, and
// half a pixel off, bilinear sampling blurs small letters by a third). A picture whose Motion changes keeps its
// exact place on every frame, texel for pixel too, so it glides instead of moving in whole-pixel steps (and a zoom
// that ends texel for pixel does not jump on its last frames).
Placement placeCanvas(const VideoParams &params, const media::CanvasGeometry &geometry, double anchorX, double anchorY,
                      double textureWidth, double textureHeight, double frameWidth, double frameHeight,
                      double targetScaleX, double targetScaleY, bool animated) {
    Placement p{};
    if (!geometry.isValid() || !(textureWidth > 0) || !(textureHeight > 0)) {
        return p;
    }
    const Fitted f = fitSource(params, 0, geometry.canvasWidth, geometry.canvasHeight, frameWidth, frameHeight);
    if (!f.ok) {
        return p;
    }
    const double cw = geometry.canvasWidth, ch = geometry.canvasHeight;
    const double c = f.c, s = f.s, cx = f.cx, cy = f.cy, sx = f.sx, sy = f.sy;
    // The anchor is in the frame's pixels and the geometry in the canvas's: the same unless the picture was drawn
    // for another frame size (held from before a Sequence Settings change until its new picture is there).
    double rx = anchorX * cw / frameWidth + geometry.x;
    double ry = anchorY * ch / frameHeight + geometry.y;
    const double pixelsPerTexelX = targetScaleX * (sx / cw) * geometry.width / textureWidth;
    const double pixelsPerTexelY = targetScaleY * (sy / ch) * geometry.height / textureHeight;
    const bool texelForPixel = std::fabs(pixelsPerTexelX - 1.0) < 1e-6 && std::fabs(pixelsPerTexelY - 1.0) < 1e-6;
    const bool reduced = pixelsPerTexelX < 1.0 && pixelsPerTexelY < 1.0;
    if (!animated && s == 0.0 && c > 0.0 && (texelForPixel || reduced)) {
        // The corner's place in the target (the viewport's origin is a whole pixel), rounded to a whole pixel.
        const double tx = (cx + (rx / cw - 0.5) * sx) * targetScaleX;
        const double ty = (cy + (ry / ch - 0.5) * sy) * targetScaleY;
        rx += (std::round(tx) - tx) / targetScaleX * cw / sx;
        ry += (std::round(ty) - ty) / targetScaleY * ch / sy;
    }
    // Canvas uv of a sequence position (placeSource's rows, unrotated storage), then the picture's uv:
    // u = (u_canvas * cw - rx) / width, v = (v_canvas * ch - ry) / height.
    const double ax = cw / geometry.width;
    const double ay = ch / geometry.height;
    p.uvFromFrameX = simd_make_float4(float(c / sx * ax), float(s / sx * ax),
                                      float((0.5 - (c * cx + s * cy) / sx) * ax - rx / geometry.width), 0.0f);
    p.uvFromFrameY = simd_make_float4(float(-s / sy * ay), float(c / sy * ay),
                                      float((0.5 - (-s * cx + c * cy) / sy) * ay - ry / geometry.height), 0.0f);
    p.scale = f.fit * params.scale * geometry.width / textureWidth;
    // The rectangle's corners in the frame: p = centre + R ((X / cw - 0.5) sx, (Y / ch - 0.5) sy).
    const auto corner = [&](double X, double Y) {
        const double dx = (X / cw - 0.5) * sx;
        const double dy = (Y / ch - 0.5) * sy;
        return std::pair<double, double>{cx + c * dx - s * dy, cy + s * dx + c * dy};
    };
    const auto [x0, y0] = corner(rx, ry);
    const auto [x1, y1] = corner(rx + geometry.width, ry);
    const auto [x2, y2] = corner(rx, ry + geometry.height);
    const auto [x3, y3] = corner(rx + geometry.width, ry + geometry.height);
    setBoundingBox(p, {x0, x1, x2, x3}, {y0, y1, y2, y3}, frameWidth, frameHeight);
    return p;
}

// Where `layer`'s picture `textures` lands: placeCanvas for a generated picture (its TextureSet carries the canvas
// geometry), else placeSource.
Placement placeLayer(const VideoLayer &layer, const TextureSet &textures, double frameWidth, double frameHeight,
                     double targetScaleX, double targetScaleY) {
    if (const auto &canvas = textures.canvas()) {
        return placeCanvas(layer.transform, *canvas, layer.canvasAnchorX, layer.canvasAnchorY, double(textures.width()),
                           double(textures.height()), frameWidth, frameHeight, targetScaleX, targetScaleY,
                           layer.motionAnimated);
    }
    return placeSource(layer.transform, layer.sourceRotationDegrees, double(textures.width()),
                       double(textures.height()), frameWidth, frameHeight);
}

// Whether `layer`'s minified picture may be sharpened (RenderGraph::sharpenMinified): never a generated picture,
// which is rendered at the size it is drawn (sharpening its anti-aliased edges would ring around light letters).
bool maySharpen(const RenderGraph &graph, const VideoLayer &layer) {
    return graph.sharpenMinified && !layer.generated;
}

// The textures a draw samples for one source: its own planes, or pre-scaled copies.
struct SourceBinding {
    id<MTLTexture> planes[2] = {nil, nil};
    // The part of each plane's texture the picture fills (VESourceUniforms::planeExtent): x, y plane 0, z, w
    // plane 1.
    simd_float4 extent = simd_make_float4(1.0f, 1.0f, 1.0f, 1.0f);
    bool straightAlpha = false; // RGBA colour not premultiplied (the shader premultiplies per texel)
    // An extended grade's tables and 3D LUTs (VETextureIndexAGradeTables, ...InputCube, ...LookCube / B; a
    // stand-in cube where it has none; nil for other sources).
    id<MTLTexture> gradeTables = nil;
    id<MTLTexture> inputCube = nil;
    id<MTLTexture> lookCube = nil;
};

// Whether the layer's picture is graded: a grade with a value that is not neutral (ClipGrade.h). An ungraded
// layer runs the pipeline without the grade, exactly as before grading existed.
bool isGraded(const VideoLayer &layer) {
    return !isNeutralGrade(layer.grade) ||
           needsExtendedGrade(layer.gradeWheels, layer.gradeCurves, layer.gradeInputLut || layer.gradeLookLut,
                              layer.gradeHueCurves);
}

// Whether the layer's grade uses a slice 2 stage (the extended grade); a grade of the five basic values only
// runs the slice 1 grade exactly as before.
bool isExtendedGrade(const VideoLayer &layer) {
    return needsExtendedGrade(layer.gradeWheels, layer.gradeCurves, layer.gradeInputLut || layer.gradeLookLut,
                              layer.gradeHueCurves);
}

// The source uniforms of `layer`'s picture: its sampling and placement, its weight, and (when graded) its
// grade, linearised by the picture's transfer tag (gradeTransferFor; an untagged still as sRGB).
void fillSource(VESourceUniforms &u, const TextureSet &textures, const SourceBinding &binding,
                const Placement &placement, double weight, const VideoLayer &layer) {
    u.colorMatrix = textures.colorMatrix();
    u.uvFromFrameX = placement.uvFromFrameX;
    u.uvFromFrameY = placement.uvFromFrameY;
    u.chromaTransform = textures.chromaTransform();
    u.weight = float(std::clamp(weight, 0.0, 1.0));
    u.straightAlpha = binding.straightAlpha ? 1u : 0u;
    u.unused0 = 0;
    u.unused1 = 0;
    u.planeExtent = binding.extent;
    u.grade = isGraded(layer) ? gradeUniformsFor(layer.grade, layer.gradeWheels, layer.gradeCurves,
                                                 layer.gradeInputLut.get(), layer.gradeLookLut.get(),
                                                 layer.gradeLookStrength,
                                                 gradeTransferFor(textures.transfer(), layer.isStill),
                                                 layer.gradeHueCurves)
                              : VEGradeUniforms{};
}

// Whether the layer's transition is a shaped one (a wipe or the iris): drawn with the per-pixel
// reveal instead of a uniform weight (RenderGraph.h).
bool isShaped(const VideoLayer &layer) {
    return layer.transition && isShapedTransition(layer.transition->kind);
}

// Whether `transition` is an iris closing on the picture (the FadeOut role of a Radial kind, the iris):
// the picture stays inside a disc shrinking to the centre, the opening iris run backwards (RenderGraph.h).
bool isClosingIris(const LayerTransition &transition) {
    return infoOf(transition.kind).mask == TransitionMask::Radial && transition.role == TransitionRole::FadeOut;
}

// The transition uniforms of a draw of `transition` (VETransitionUniforms). The mix at the frame's centre;
// for a shape, the frame's exposure interval [progressStart, progressEnd] (the instant at the mix when the
// interval is not set), mirrored to [1 - progressEnd, 1 - progressStart] for a closing iris (the opening
// iris's interval whose reveal is the picture's share), the shape and the soft edge (its softness), and for a layer
// drawn alone whether its picture is the revealed one: shown times the reveal m where it is the incoming
// side (a fade in, or a closing iris over its mirrored interval), times 1 - m otherwise. Everything but
// the mix is zero for a dissolve, whose draws are unchanged.
VETransitionUniforms transitionUniforms(const LayerTransition &transition, bool drawnAlone) {
    VETransitionUniforms u{};
    const double mix = std::clamp(transition.mix, 0.0, 1.0);
    u.mix = float(mix);
    if (!isShapedTransition(transition.kind)) {
        return u;
    }
    double start = transition.progressStart;
    double end = transition.progressEnd;
    if (!std::isfinite(start) || !std::isfinite(end) || end < start) {
        start = end = mix;
    }
    start = std::clamp(start, 0.0, 1.0);
    end = std::clamp(end, 0.0, 1.0);
    if (isClosingIris(transition)) {
        const double mirroredStart = 1.0 - end;
        end = 1.0 - start;
        start = mirroredStart;
    }
    u.progressStart = float(start);
    u.progressEnd = float(end);
    u.feather = float(transition.softness);
    u.shape = VEInt(transition.kind);
    const bool pictureIsRevealed = transition.isIncoming || isClosingIris(transition);
    u.incoming = drawnAlone && pictureIsRevealed ? 1u : 0u;
    return u;
}

struct DrawItem {
    VEDrawUniforms uniforms;
    id<MTLRenderPipelineState> pipeline;
    std::size_t layerA;
    std::size_t layerB; // == layerA when drawn alone
    SourceBinding a;
    SourceBinding b;
};

// One pre-scale pass: optionally premultiply `source` into `premultiplied` (straight-alpha RGBA),
// then Lanczos-resample into `destination`, then optionally sharpen that into `sharpened`.
struct PrescaleJob {
    id<MTLTexture> source;
    id<MTLTexture> premultiplied; // nil unless the source has straight alpha
    id<MTLTexture> destination;
    id<MTLTexture> sharpened; // nil unless the plane is sharpened (the draw then samples it)
    // The drawn size the plane is resampled to: the top-left region of `destination` (and `sharpened`), which
    // are pooled at a size at least that large.
    std::size_t width = 0;
    std::size_t height = 0;
    VEUnsharpUniforms unsharp{};
};

// The nominal luma range of a YCbCr format's luma plane as unorm values: 16-235 (8-bit video range),
// 64-940 in the high bits of 16-bit words (10-bit video range), or the whole range (full range).
simd_float2 lumaRangeOf(OSType pixelFormat) {
    if (media::isFullRangeYCbCr(pixelFormat)) {
        return simd_make_float2(0.0f, 1.0f);
    }
    if (media::isTenBitPixelFormat(pixelFormat)) {
        return simd_make_float2(float(64.0 * 64.0 / 65535.0), float(940.0 * 64.0 / 65535.0));
    }
    return simd_make_float2(float(16.0 / 255.0), float(235.0 / 255.0));
}

// Pooled textures for pre-scaled planes.
struct ScratchTexture {
    id<MTLTexture> texture;
    MTLPixelFormat format;
    std::size_t width;
    std::size_t height;
    std::uint64_t lastUsedFrame; // render() call that last used it
};

// Rounds a pre-scaled size up so small changes (a live resize) reuse pooled textures: to a
// multiple of about 1/16 to 1/32 of the size, never more than `full`. The final bilinear pass
// then samples at >= ~94 % of 1:1, well inside the unfiltered-OK range. With `quantize` false (a
// pixel-buffer target: an export, whose size does not change from frame to frame) the size is the
// drawn size rounded up to a whole texel, so the draw samples the pre-scaled plane at 1:1 and not,
// say, 1088 rows onto 1080 (a 4K picture at 1080p), whose drifting bilinear phase softens fine text
// in bands.
std::size_t quantizeScratchSize(double exact, std::size_t full, bool quantize = true) {
    // A drawn size a hair above a whole number (floating-point error) is that number.
    const auto n = static_cast<std::size_t>(std::max(1.0, std::ceil(exact - 1e-6)));
    if (!quantize) {
        return std::min(full, n);
    }
    std::size_t step = 1;
    while (step * 32 <= n) {
        step *= 2;
    }
    return std::min(full, (n + step - 1) / step * step);
}

std::string nsErrorText(NSError *error) {
    return error ? std::string(error.localizedDescription.UTF8String ?: "") : std::string("unknown error");
}

bool isSupportedTargetFormat(OSType f) {
    return f == kCVPixelFormatType_32BGRA || f == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
           f == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
           f == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
}

} // namespace

struct Compositor::Impl {
    struct Slot {
        id<MTLBuffer> uniforms = nil;
        std::size_t drawCapacity = 0;
        std::vector<TextureSet> retained; // pictures the GPU reads (and target planes) until completion
        RenderResult result;
        RenderCompletion completion;
    };

    id<MTLDevice> device = nil;
    id<MTLCommandQueue> queue = nil;
    id<MTLLibrary> library = nil;
    id<MTLFunction> vertexFunction = nil;
    id<MTLComputePipelineState> convertBGRA = nil;
    id<MTLComputePipelineState> convert420 = nil;
    id<MTLComputePipelineState> premultiply = nil;
    id<MTLComputePipelineState> unsharp = nil;
    MPSImageLanczosScale *lanczos = nil; // nil when MPS does not support the device (no pre-scaling)
    std::vector<std::pair<std::uint64_t, id<MTLRenderPipelineState>>> pipelines;
    TextureCache textureCache;

    dispatch_semaphore_t freeSlots = nullptr;
    Slot slots[kFramesInFlight];
    // Free uniform slots: bit i set = slots[i] free. `freeSlots` counts the set bits, so a
    // successful wait on it guarantees takeFreeSlot() finds one. Slots are returned in whatever
    // order their frames complete.
    std::atomic<std::uint32_t> freeMask{(1u << kFramesInFlight) - 1u};
    std::uint64_t frameCounter = 0;
    std::atomic<Fault> injectedFault{Fault::None};
    std::mutex heldMutex;
    std::vector<std::size_t> heldSlots; // taken by holdSlotsForTesting

    // Call only after a successful wait on freeSlots.
    std::size_t takeFreeSlot() {
        std::uint32_t mask = freeMask.load(std::memory_order_acquire);
        for (;;) {
            if (mask == 0) {
                __builtin_trap(); // freeSlots and freeMask out of step: a slot was lost
            }
            const std::uint32_t lowest = mask & (~mask + 1u);
            if (freeMask.compare_exchange_weak(mask, mask & ~lowest, std::memory_order_acq_rel,
                                               std::memory_order_acquire)) {
                return static_cast<std::size_t>(std::countr_zero(lowest));
            }
        }
    }

    // Any thread: the slot's contents are no longer used by anyone.
    void returnSlot(std::size_t index) {
        freeMask.fetch_or(1u << index, std::memory_order_release);
        dispatch_semaphore_signal(freeSlots);
    }

    // Drops the per-frame references to source pictures and pre-scaled planes (they live on in
    // a slot and the command buffer if submitted).
    void dropScratchReferences() {
        for (TextureSet &t : resolved) {
            t.reset();
        }
        items.clear();
        jobs.clear();
    }

    bool consumeFault(Fault fault) {
        Fault expected = fault;
        return injectedFault.load(std::memory_order_relaxed) == fault &&
               injectedFault.compare_exchange_strong(expected, Fault::None);
    }

    id<MTLTexture> intermediate = nil;

    // Texture targets: the working texture (RGBA16Float, at least the target's size, the frame in its
    // top-left corner) and the output pass that writes the target from it, one pipeline per format.
    id<MTLFunction> outputVertexFunction = nil;
    id<MTLFunction> outputFragmentFunction = nil;
    // By pixel format and clipping overlay (the format shifted left by one, the overlay in bit 0).
    std::vector<std::pair<std::uint64_t, id<MTLRenderPipelineState>>> outputPipelines;
    id<MTLFunction> outputOverlayFragmentFunction = nil;
    id<MTLTexture> working = nil;
    std::size_t workingAllocations = 0; // working textures ever allocated (Stats)

    // Per-frame scratch, reused (capacity kept) across frames.
    std::vector<TextureSet> resolved;
    std::vector<char> drawn;
    std::vector<DrawItem> items;
    std::vector<SkippedLayer> skipped;
    std::vector<PrescaleJob> jobs;

    std::vector<ScratchTexture> scratch; // pre-scale pool
    // Pre-scaled planes at the drawn size (pixel-buffer targets) rather than pooled steps (see
    // quantizeScratchSize); set per render().
    std::size_t scratchAllocations = 0; // pre-scale textures ever allocated (Stats)
    std::uint64_t buildCounter = 0;      // render() calls, for the pool's per-frame bookkeeping

    // A pooled texture of this format and size not yet used by the frame being built.
    Result<id<MTLTexture>> acquireScratch(MTLPixelFormat format, std::size_t width, std::size_t height) {
        for (ScratchTexture &entry : scratch) {
            if (entry.format == format && entry.width == width && entry.height == height &&
                entry.lastUsedFrame != buildCounter) {
                entry.lastUsedFrame = buildCounter;
                return entry.texture;
            }
        }
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                        width:width
                                                                                       height:height
                                                                                    mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        desc.storageMode = MTLStorageModePrivate;
        id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
        if (texture == nil) {
            return makeError(MediaErrorCode::Internal, "Compositor: cannot allocate a " + std::to_string(width) + "x" +
                                                           std::to_string(height) + " pre-scale texture");
        }
        texture.label = @"Framewright pre-scaled plane";
        scratch.push_back({texture, format, width, height, buildCounter});
        ++scratchAllocations;
        return texture;
    }

    // Releases pooled textures idle for kScratchIdleFrames, and the least recently used ones
    // beyond kMaxScratchTextures. In-flight command buffers keep their own references.
    void trimScratch() {
        std::erase_if(scratch, [this](const ScratchTexture &e) { return e.lastUsedFrame + kScratchIdleFrames < buildCounter; });
        while (scratch.size() > kMaxScratchTextures) {
            auto oldest = std::min_element(scratch.begin(), scratch.end(), [](const ScratchTexture &a, const ScratchTexture &b) {
                return a.lastUsedFrame < b.lastUsedFrame;
            });
            scratch.erase(oldest);
        }
    }

    // The textures to sample for `t` drawn at `outputScale` target pixels per source pixel: planes
    // minified below kMinifyThreshold get a Lanczos pre-scale job to the drawn size (straight-alpha RGBA
    // is premultiplied first); nothing is ever resampled below what the target draws. With
    // `sharpenSetting`, the luma or RGBA plane of such a pre-scale is then sharpened by
    // sharpenAmountAt(max(outputScale, sharpenScale)), `sharpenScale` being the picture's scale in the
    // sequence (a monitor) or in the export's output: only a picture that both the target and the
    // sequence or export minify is sharpened.
    Result<SourceBinding> bindSource(const TextureSet &t, const VideoLayer &layer, double outputScale,
                                     double sharpenScale, bool sharpenSetting) {
        SourceBinding binding;
        binding.planes[0] = t.plane(0);
        binding.planes[1] = t.plane(1);
        const bool rgba = t.sourceClass() == SourceClass::RGBA;
        binding.straightAlpha = rgba && !t.alphaIsPremultiplied(layer.isStill);
        if (lanczos == nil || !(outputScale > 0) || !(outputScale < kMinifyThreshold)) {
            return binding;
        }
        const double amount = sharpenSetting && unsharp != nil
                                  ? Compositor::sharpenAmountAt(std::max(outputScale, sharpenScale))
                                  : 0.0;
        const bool sharpen = amount > 0;
        const double scale = outputScale;
        for (std::size_t p = 0; p < t.planeCount(); ++p) {
            id<MTLTexture> plane = t.plane(p);
            const double planeW = double(plane.width);
            const double planeH = double(plane.height);
            // Output pixels per texel of this plane along each axis (chroma planes are smaller).
            const double sx = scale * double(t.width()) / planeW;
            const double sy = scale * double(t.height()) / planeH;
            if (sx >= kMinifyThreshold && sy >= kMinifyThreshold) {
                continue;
            }
            // Resampled to the drawn size, rounded up to a whole texel, so it is sampled at 1:1 (a 4K picture at
            // 1080p: 1080 rows, not 1088 resampled onto 1080, which blurred fine text in bands), into the top-left
            // of a pooled texture whose size is rounded up to 1/16-1/32 steps: a changing drawn size (a Ken Burns
            // zoom, a live resize) reuses the pool instead of allocating textures every frame.
            const std::size_t w =
                sx < kMinifyThreshold ? quantizeScratchSize(planeW * sx, plane.width, false) : plane.width;
            const std::size_t h =
                sy < kMinifyThreshold ? quantizeScratchSize(planeH * sy, plane.height, false) : plane.height;
            const std::size_t pooledW = sx < kMinifyThreshold ? quantizeScratchSize(planeW * sx, plane.width) : w;
            const std::size_t pooledH = sy < kMinifyThreshold ? quantizeScratchSize(planeH * sy, plane.height) : h;
            PrescaleJob job;
            job.source = plane;
            job.width = w;
            job.height = h;
            MTLPixelFormat format = plane.pixelFormat;
            if (rgba) {
                // Pre-scaled RGBA is always premultiplied (filtering straight colour would bleed
                // the colour of transparent texels); RGBA8 keeps compute writes portable, and a deep
                // picture ('l64r', 'RGhA': DecodeOptions::highPrecision) keeps its precision, and an
                // extended-range one its values, in RGBA16Float.
                const bool deep = plane.pixelFormat == MTLPixelFormatRGBA16Unorm ||
                                  plane.pixelFormat == MTLPixelFormatRGBA16Float;
                format = deep ? MTLPixelFormatRGBA16Float : MTLPixelFormatRGBA8Unorm;
                if (binding.straightAlpha) {
                    auto premultiplied = acquireScratch(format, plane.width, plane.height);
                    if (!premultiplied.ok()) {
                        return std::move(premultiplied).error();
                    }
                    job.premultiplied = premultiplied.value();
                    binding.straightAlpha = false;
                }
            }
            auto destination = acquireScratch(format, pooledW, pooledH);
            if (!destination.ok()) {
                return std::move(destination).error();
            }
            job.destination = destination.value();
            binding.planes[p] = job.destination;
            const float extentX = float(double(w) / double(pooledW));
            const float extentY = float(double(h) / double(pooledH));
            if (p == 0) {
                binding.extent.x = extentX;
                binding.extent.y = extentY;
            } else {
                binding.extent.z = extentX;
                binding.extent.w = extentY;
            }
            // Sharpen the luma plane of YCbCr (plane 0) or the RGBA plane; never chroma.
            if (sharpen && unsharp != nil && (rgba || p == 0)) {
                auto sharpened = acquireScratch(format, pooledW, pooledH);
                if (!sharpened.ok()) {
                    return std::move(sharpened).error();
                }
                job.sharpened = sharpened.value();
                job.unsharp.amount = float(amount);
                job.unsharp.threshold = float(Compositor::kSharpenThreshold);
                const simd_float2 range = rgba ? simd_make_float2(0.0f, 1.0f) : lumaRangeOf(t.pixelFormat());
                job.unsharp.rangeLow = range.x;
                job.unsharp.rangeHigh = range.y;
                job.unsharp.width = std::uint32_t(w);
                job.unsharp.height = std::uint32_t(h);
                job.unsharp.isLuma = rgba ? 0u : 1u;
                binding.planes[p] = job.sharpened;
            }
            jobs.push_back(job);
        }
        return binding;
    }

    void encodePrescaleJobs(id<MTLCommandBuffer> commandBuffer) {
        for (const PrescaleJob &job : jobs) {
            id<MTLTexture> source = job.source;
            if (job.premultiplied != nil) {
                id<MTLComputeCommandEncoder> compute = [commandBuffer computeCommandEncoder];
                compute.label = @"Framewright premultiply";
                [compute setComputePipelineState:premultiply];
                [compute setTexture:job.source atIndex:0];
                [compute setTexture:job.premultiplied atIndex:1];
                const NSUInteger tw = premultiply.threadExecutionWidth;
                const NSUInteger th = std::max<NSUInteger>(1, premultiply.maxTotalThreadsPerThreadgroup / tw);
                [compute dispatchThreads:MTLSizeMake(job.source.width, job.source.height, 1)
                    threadsPerThreadgroup:MTLSizeMake(tw, std::min<NSUInteger>(th, 16), 1)];
                [compute endEncoding];
                source = job.premultiplied;
            }
            // Into the top-left job.width x job.height of the pooled destination (the rest of it is never read).
            const MPSScaleTransform transform{double(job.width) / double(source.width),
                                              double(job.height) / double(source.height), 0.0, 0.0};
            lanczos.scaleTransform = &transform;
            lanczos.clipRect = MTLRegionMake2D(0, 0, job.width, job.height);
            [lanczos encodeToCommandBuffer:commandBuffer sourceTexture:source destinationTexture:job.destination];
            lanczos.scaleTransform = nil;
            lanczos.clipRect = MPSRectNoClip;
            if (job.sharpened != nil) {
                id<MTLComputeCommandEncoder> compute = [commandBuffer computeCommandEncoder];
                compute.label = @"Framewright sharpen";
                [compute setComputePipelineState:unsharp];
                [compute setTexture:job.destination atIndex:VETextureIndexUnsharpSource];
                [compute setTexture:job.sharpened atIndex:VETextureIndexUnsharpDestination];
                [compute setBytes:&job.unsharp length:sizeof(job.unsharp) atIndex:VEBufferIndexUnsharp];
                const NSUInteger tw = unsharp.threadExecutionWidth;
                const NSUInteger th = std::max<NSUInteger>(1, unsharp.maxTotalThreadsPerThreadgroup / tw);
                [compute dispatchThreads:MTLSizeMake(job.width, job.height, 1)
                    threadsPerThreadgroup:MTLSizeMake(tw, std::min<NSUInteger>(th, 16), 1)];
                [compute endEncoding];
            }
        }
    }

    std::size_t sharpenedJobCount() const {
        return static_cast<std::size_t>(
            std::count_if(jobs.begin(), jobs.end(), [](const PrescaleJob &job) { return job.sharpened != nil; }));
    }

    Result<id<MTLRenderPipelineState>> pipeline(const PipelineKey &key) {
        const std::uint64_t packed = key.packed();
        for (const auto &entry : pipelines) {
            if (entry.first == packed) {
                return entry.second;
            }
        }
        MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
        bool a = key.aIsYCbCr;
        bool partner = key.hasPartner;
        bool b = key.hasPartner && key.bIsYCbCr;
        bool aGraded = key.aIsGraded;
        bool bGraded = key.hasPartner && key.bIsGraded;
        bool aExtended = aGraded && key.aIsExtended;
        bool bExtended = bGraded && key.bIsExtended;
        [constants setConstantValue:&a type:MTLDataTypeBool atIndex:VEFunctionConstantSourceAIsYCbCr];
        [constants setConstantValue:&partner type:MTLDataTypeBool atIndex:VEFunctionConstantHasPartner];
        [constants setConstantValue:&b type:MTLDataTypeBool atIndex:VEFunctionConstantSourceBIsYCbCr];
        [constants setConstantValue:&aGraded type:MTLDataTypeBool atIndex:VEFunctionConstantSourceAHasGrade];
        [constants setConstantValue:&bGraded type:MTLDataTypeBool atIndex:VEFunctionConstantSourceBHasGrade];
        [constants setConstantValue:&aExtended type:MTLDataTypeBool atIndex:VEFunctionConstantSourceAHasExtendedGrade];
        [constants setConstantValue:&bExtended type:MTLDataTypeBool atIndex:VEFunctionConstantSourceBHasExtendedGrade];
        NSError *error = nil;
        id<MTLFunction> fragment = [library newFunctionWithName:@"ve_layer_fragment" constantValues:constants error:&error];
        if (fragment == nil) {
            return makeError(MediaErrorCode::Internal, "Compositor: cannot specialise ve_layer_fragment: " + nsErrorText(error));
        }
        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.label = @"Framewright layer";
        desc.vertexFunction = vertexFunction;
        desc.fragmentFunction = fragment;
        MTLRenderPipelineColorAttachmentDescriptor *color = desc.colorAttachments[0];
        color.pixelFormat = key.format;
        color.blendingEnabled = YES;
        color.rgbBlendOperation = MTLBlendOperationAdd;
        color.alphaBlendOperation = MTLBlendOperationAdd;
        color.sourceRGBBlendFactor = MTLBlendFactorOne;
        color.sourceAlphaBlendFactor = MTLBlendFactorOne;
        color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (state == nil) {
            return makeError(MediaErrorCode::Internal, "Compositor: cannot create layer pipeline for pixel format " +
                                                           std::to_string(static_cast<unsigned long>(key.format)) +
                                                           ": " + nsErrorText(error));
        }
        pipelines.emplace_back(packed, state);
        return state;
    }

    Status ensureIntermediate(std::size_t width, std::size_t height) {
        if (intermediate != nil && intermediate.width == width && intermediate.height == height) {
            return media::okStatus();
        }
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:kIntermediateFormat
                                                                                        width:width
                                                                                       height:height
                                                                                    mipmapped:NO];
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModePrivate;
        intermediate = [device newTextureWithDescriptor:desc];
        if (intermediate == nil) {
            return makeError(MediaErrorCode::Internal, "Compositor: cannot allocate the intermediate texture");
        }
        intermediate.label = @"Framewright composite";
        return media::okStatus();
    }

    // Extended grades' tables (gradeTableData) by curves: a small least-recently-used cache, so a graded
    // clip's tables are built once, not every frame (frames on the GPU keep the textures they use: the
    // command buffers retain them). The identity tables serve extended grades without curves.
    struct GradeTableEntry {
        GradeCurves curves;
        HueCurves hueCurves;
        std::string input1D; // the 1D LUTs' content ids ("" for none or a 3D one)
        std::string look1D;
        id<MTLTexture> texture = nil;
        std::uint64_t lastUse = 0;
    };
    static constexpr std::size_t kMaxGradeTables = 32;
    std::vector<GradeTableEntry> gradeTables;
    std::uint64_t gradeTableUses = 0;
    id<MTLTexture> identityGradeTables = nil;

    // 3D LUT textures by content id (least recently used; a 65^3 LUT is 4.4 MB), and the 1x1x1 stand-in an
    // extended grade without a 3D LUT binds.
    struct CubeEntry {
        std::string lutId;
        id<MTLTexture> texture = nil;
        std::uint64_t lastUse = 0;
    };
    static constexpr std::size_t kMaxCubes = 8;
    std::vector<CubeEntry> cubes;
    id<MTLTexture> standInCube = nil;

    Result<id<MTLTexture>> makeCube(const CubeLut *lut) {
        const NSUInteger side = lut != nullptr ? lut->size : 1;
        MTLTextureDescriptor *desc = [MTLTextureDescriptor new];
        desc.textureType = MTLTextureType3D;
        desc.pixelFormat = MTLPixelFormatRGBA32Float;
        desc.width = side;
        desc.height = side;
        desc.depth = side;
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
        if (texture == nil) {
            return makeError(MediaErrorCode::Internal, "Compositor: cannot allocate a LUT's texture");
        }
        texture.label = lut != nullptr ? @"Framewright LUT" : @"Framewright LUT stand-in";
        std::vector<float> rgba(std::size_t(side) * side * side * 4, 0.0f);
        if (lut != nullptr) {
            for (std::size_t i = 0; i < std::size_t(side) * side * side; ++i) {
                rgba[i * 4] = lut->table[i * 3];
                rgba[i * 4 + 1] = lut->table[i * 3 + 1];
                rgba[i * 4 + 2] = lut->table[i * 3 + 2];
                rgba[i * 4 + 3] = 1.0f;
            }
        }
        [texture replaceRegion:MTLRegionMake3D(0, 0, 0, side, side, side)
                   mipmapLevel:0
                         slice:0
                     withBytes:rgba.data()
                   bytesPerRow:side * 4 * sizeof(float)
                 bytesPerImage:side * side * 4 * sizeof(float)];
        return texture;
    }

    // The texture of a 3D LUT (the stand-in for none or a 1D one).
    Result<id<MTLTexture>> cubeFor(const std::shared_ptr<const CubeLut> &lut, const std::string &lutId) {
        if (!lut || lut->kind != CubeKind::ThreeD) {
            if (standInCube == nil) {
                auto made = makeCube(nullptr);
                if (!made.ok()) {
                    return made;
                }
                standInCube = made.value();
            }
            return standInCube;
        }
        ++gradeTableUses;
        for (CubeEntry &entry : cubes) {
            if (entry.lutId == lutId) {
                entry.lastUse = gradeTableUses;
                return entry.texture;
            }
        }
        auto made = makeCube(lut.get());
        if (!made.ok()) {
            return made;
        }
        if (cubes.size() >= kMaxCubes) {
            cubes.erase(std::min_element(cubes.begin(), cubes.end(),
                                         [](const CubeEntry &a, const CubeEntry &b) { return a.lastUse < b.lastUse; }));
        }
        cubes.push_back(CubeEntry{lutId, made.value(), gradeTableUses});
        return made.value();
    }

    Result<id<MTLTexture>> makeGradeTables(const VideoLayer &layer) {
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                        width:kVEGradeTableWidth
                                                                                       height:VEGradeTableRowCount
                                                                                    mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
        id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
        if (texture == nil) {
            return makeError(MediaErrorCode::Internal, "Compositor: cannot allocate a grade's tables");
        }
        texture.label = @"Framewright grade tables";
        const std::vector<float> data =
            gradeTableData(layer.gradeCurves, layer.gradeInputLut.get(), layer.gradeLookLut.get(), layer.gradeHueCurves);
        [texture replaceRegion:MTLRegionMake2D(0, 0, kVEGradeTableWidth, VEGradeTableRowCount)
                   mipmapLevel:0
                     withBytes:data.data()
                   bytesPerRow:kVEGradeTableWidth * sizeof(float)];
        return texture;
    }

    // The tables of `layer`'s extended grade.
    Result<id<MTLTexture>> gradeTablesFor(const VideoLayer &layer) {
        const std::string input1D =
            layer.gradeInputLut && layer.gradeInputLut->kind == CubeKind::OneD ? layer.gradeInputLutId : std::string();
        const std::string look1D =
            layer.gradeLookLut && layer.gradeLookLut->kind == CubeKind::OneD ? layer.gradeLookLutId : std::string();
        if (isIdentityCurves(layer.gradeCurves) && isIdentityHueCurves(layer.gradeHueCurves) && input1D.empty() &&
            look1D.empty()) {
            if (identityGradeTables == nil) {
                auto made = makeGradeTables(VideoLayer{});
                if (!made.ok()) {
                    return made;
                }
                identityGradeTables = made.value();
            }
            return identityGradeTables;
        }
        ++gradeTableUses;
        for (GradeTableEntry &entry : gradeTables) {
            if (entry.curves == layer.gradeCurves && entry.hueCurves == layer.gradeHueCurves && entry.input1D == input1D &&
                entry.look1D == look1D) {
                entry.lastUse = gradeTableUses;
                return entry.texture;
            }
        }
        auto made = makeGradeTables(layer);
        if (!made.ok()) {
            return made;
        }
        if (gradeTables.size() >= kMaxGradeTables) {
            const auto oldest = std::min_element(gradeTables.begin(), gradeTables.end(),
                                                 [](const GradeTableEntry &a, const GradeTableEntry &b) {
                                                     return a.lastUse < b.lastUse;
                                                 });
            gradeTables.erase(oldest);
        }
        gradeTables.push_back(
            GradeTableEntry{layer.gradeCurves, layer.gradeHueCurves, input1D, look1D, made.value(), gradeTableUses});
        return made.value();
    }

    // The tables and 3D LUTs of `layer`'s extended grade, into `binding`.
    Status bindGradeResources(const VideoLayer &layer, SourceBinding &binding) {
        auto tables = gradeTablesFor(layer);
        if (!tables.ok()) {
            return std::move(tables).error();
        }
        auto input = cubeFor(layer.gradeInputLut, layer.gradeInputLutId);
        if (!input.ok()) {
            return std::move(input).error();
        }
        auto look = cubeFor(layer.gradeLookLut, layer.gradeLookLutId);
        if (!look.ok()) {
            return std::move(look).error();
        }
        binding.gradeTables = tables.value();
        binding.inputCube = input.value();
        binding.lookCube = look.value();
        return media::okStatus();
    }

    // The output pass's pipeline for a texture target of `format`, with or without the clipping overlay
    // (VEFunctionConstantClippingOverlay; its fragment function is specialised on first use).
    Result<id<MTLRenderPipelineState>> outputPipeline(MTLPixelFormat format, bool clippingOverlay = false) {
        const std::uint64_t key = (static_cast<std::uint64_t>(format) << 1) | (clippingOverlay ? 1u : 0u);
        for (const auto &entry : outputPipelines) {
            if (entry.first == key) {
                return entry.second;
            }
        }
        if (clippingOverlay && outputOverlayFragmentFunction == nil) {
            MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
            const bool overlay = true;
            [constants setConstantValue:&overlay type:MTLDataTypeBool atIndex:VEFunctionConstantClippingOverlay];
            NSError *functionError = nil;
            outputOverlayFragmentFunction = [library newFunctionWithName:@"ve_output_fragment"
                                                          constantValues:constants
                                                                   error:&functionError];
            if (outputOverlayFragmentFunction == nil) {
                return makeError(MediaErrorCode::Internal,
                                 "Compositor: cannot specialise the clipping overlay: " + nsErrorText(functionError));
            }
        }
        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.label = clippingOverlay ? @"Framewright output with the clipping overlay" : @"Framewright output";
        desc.vertexFunction = outputVertexFunction;
        desc.fragmentFunction = clippingOverlay ? outputOverlayFragmentFunction : outputFragmentFunction;
        desc.colorAttachments[0].pixelFormat = format;
        NSError *error = nil;
        id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (state == nil) {
            return makeError(MediaErrorCode::Internal, "Compositor: cannot create the output pipeline for pixel format " +
                                                           std::to_string(static_cast<unsigned long>(format)) + ": " +
                                                           nsErrorText(error));
        }
        outputPipelines.emplace_back(key, state);
        return state;
    }

    // A working texture for a `width` x `height` texture target. Its size is rounded up in the
    // pre-scale pool's steps (quantizeScratchSize), so a live resize of a monitor reuses it; a
    // target in another step gets a new one (the previous one lives on in frames still on the GPU).
    Status ensureWorking(std::size_t width, std::size_t height) {
        // Metal's largest 2D texture on Apple silicon (a target texture cannot be larger).
        constexpr std::size_t kMaxSide = 16384;
        const std::size_t w = quantizeScratchSize(double(width), kMaxSide);
        const std::size_t h = quantizeScratchSize(double(height), kMaxSide);
        if (working != nil && working.width == w && working.height == h) {
            return media::okStatus();
        }
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:kIntermediateFormat
                                                                                        width:w
                                                                                       height:h
                                                                                    mipmapped:NO];
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModePrivate;
        id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
        if (texture == nil) {
            return makeError(MediaErrorCode::Internal, "Compositor: cannot allocate the " + std::to_string(w) + "x" +
                                                           std::to_string(h) + " working texture");
        }
        texture.label = @"Framewright working frame";
        working = texture;
        ++workingAllocations;
        return media::okStatus();
    }

    Status ensureCapacity(Slot &slot, std::size_t draws) {
        if (slot.uniforms != nil && slot.drawCapacity >= draws) {
            return media::okStatus();
        }
        const std::size_t capacity = std::max(draws, std::max<std::size_t>(kInitialDrawCapacity, slot.drawCapacity * 2));
        slot.uniforms = [device newBufferWithLength:capacity * kDrawStride + kConvertStride
                                            options:MTLResourceStorageModeShared | MTLResourceCPUCacheModeWriteCombined];
        if (slot.uniforms == nil) {
            return makeError(MediaErrorCode::Internal, "Compositor: cannot allocate the uniform buffer");
        }
        slot.uniforms.label = @"Framewright uniforms";
        slot.drawCapacity = capacity;
        return media::okStatus();
    }

    // Builds `items` and `jobs` for the graph; fills `skipped` and `resolved`. `targetScale`:
    // target pixels per sequence pixel; `snapScaleX` and `snapScaleY` the same per axis (the viewport's; a
    // generated picture drawn texel for pixel is put on whole target pixels with them: placeCanvas).
    Status buildItems(const RenderGraph &graph, TextureLookup lookup, MTLPixelFormat format, double targetScale,
                      double sharpenTargetScale, double snapScaleX, double snapScaleY, std::size_t &drawnLayers) {
        const std::size_t n = graph.layers.size();
        ++buildCounter;
        items.clear();
        jobs.clear();
        skipped.clear();
        drawnLayers = 0;
        if (resolved.size() < n) {
            resolved.resize(n);
        }
        drawn.assign(n, 0);
        for (std::size_t i = 0; i < n; ++i) {
            resolved[i].reset();
            if (!lookup(graph.layers[i], i, resolved[i]) || !resolved[i]) {
                resolved[i].reset();
                skipped.push_back({i, graph.layers[i].clipId});
            }
        }
        const double frameW = graph.width;
        const double frameH = graph.height;
        for (std::size_t i = 0; i < n; ++i) {
            if (drawn[i] || !resolved[i]) {
                continue;
            }
            const VideoLayer &layer = graph.layers[i];
            // A dissolve pair drawn in one pass: both present and pointing at each other.
            std::size_t partner = i;
            if (layer.transition) {
                const std::size_t j = layer.transition->partnerLayerIndex;
                if (j != i && j < n && resolved[j] && !drawn[j] && graph.layers[j].transition &&
                    graph.layers[j].transition->partnerLayerIndex == i &&
                    graph.layers[j].transition->isIncoming != layer.transition->isIncoming) {
                    partner = j;
                }
            }
            DrawItem item{};
            if (partner == i) {
                // A dissolve or a fade weighs the whole layer; a shape reveals it per pixel instead.
                double weight = layer.opacity;
                if (layer.transition && !isShaped(layer)) {
                    weight *= layer.transition->weight();
                }
                const TextureSet &t = resolved[i];
                const Placement pl = placeLayer(layer, t, frameW, frameH, snapScaleX, snapScaleY);
                drawn[i] = 1;
                ++drawnLayers;
                if (!pl.visible || weight <= 0.0) {
                    continue;
                }
                auto binding = bindSource(t, layer, pl.scale * targetScale, pl.scale * sharpenTargetScale,
                                          maySharpen(graph, layer));
                if (!binding.ok()) {
                    return std::move(binding).error();
                }
                item.a = binding.value();
                fillSource(item.uniforms.a, t, item.a, pl, weight, layer);
                if (isExtendedGrade(layer)) {
                    VE_MEDIA_TRY(bindGradeResources(layer, item.a));
                }
                item.uniforms.quadRect = simd_make_float4(float(pl.x0), float(pl.y0), float(pl.x1), float(pl.y1));
                if (isShaped(layer)) {
                    item.uniforms.transition = transitionUniforms(*layer.transition, true);
                }
                item.layerA = item.layerB = i;
                auto state =
                    pipeline({t.sourceClass() == SourceClass::YCbCrBiPlanar, false, false, format, isGraded(layer), false,
                              isExtendedGrade(layer), false});
                if (!state.ok()) {
                    return std::move(state).error();
                }
                item.pipeline = state.value();
            } else {
                const bool iIsOutgoing = !layer.transition->isIncoming;
                const std::size_t out = iIsOutgoing ? i : partner;
                const std::size_t in = iIsOutgoing ? partner : i;
                const VideoLayer &outLayer = graph.layers[out];
                const VideoLayer &inLayer = graph.layers[in];
                const TextureSet &ta = resolved[out];
                const TextureSet &tb = resolved[in];
                const Placement pa = placeLayer(outLayer, ta, frameW, frameH, snapScaleX, snapScaleY);
                const Placement pb = placeLayer(inLayer, tb, frameW, frameH, snapScaleX, snapScaleY);
                drawn[i] = drawn[partner] = 1;
                drawnLayers += 2;
                if (!pa.visible && !pb.visible) {
                    continue;
                }
                auto bindingA = bindSource(ta, outLayer, pa.visible ? pa.scale * targetScale : 1.0,
                                           pa.visible ? pa.scale * sharpenTargetScale : 1.0, maySharpen(graph, outLayer));
                if (!bindingA.ok()) {
                    return std::move(bindingA).error();
                }
                auto bindingB = bindSource(tb, inLayer, pb.visible ? pb.scale * targetScale : 1.0,
                                           pb.visible ? pb.scale * sharpenTargetScale : 1.0, maySharpen(graph, inLayer));
                if (!bindingB.ok()) {
                    return std::move(bindingB).error();
                }
                item.a = bindingA.value();
                item.b = bindingB.value();
                fillSource(item.uniforms.a, ta, item.a, pa, pa.visible ? outLayer.opacity : 0.0, outLayer);
                fillSource(item.uniforms.b, tb, item.b, pb, pb.visible ? inLayer.opacity : 0.0, inLayer);
                for (const auto &[pairLayer, pairBinding] :
                     {std::pair<const VideoLayer *, SourceBinding *>{&outLayer, &item.a}, {&inLayer, &item.b}}) {
                    if (isExtendedGrade(*pairLayer)) {
                        VE_MEDIA_TRY(bindGradeResources(*pairLayer, *pairBinding));
                    }
                }
                double x0 = pa.visible ? pa.x0 : pb.x0, y0 = pa.visible ? pa.y0 : pb.y0;
                double x1 = pa.visible ? pa.x1 : pb.x1, y1 = pa.visible ? pa.y1 : pb.y1;
                if (pa.visible && pb.visible) {
                    x0 = std::min(pa.x0, pb.x0);
                    y0 = std::min(pa.y0, pb.y0);
                    x1 = std::max(pa.x1, pb.x1);
                    y1 = std::max(pa.y1, pb.y1);
                }
                item.uniforms.quadRect = simd_make_float4(float(x0), float(y0), float(x1), float(y1));
                item.uniforms.transition = transitionUniforms(*inLayer.transition, false);
                item.layerA = out;
                item.layerB = in;
                auto state = pipeline({ta.sourceClass() == SourceClass::YCbCrBiPlanar, true,
                                       tb.sourceClass() == SourceClass::YCbCrBiPlanar, format, isGraded(outLayer),
                                       isGraded(inLayer), isExtendedGrade(outLayer), isExtendedGrade(inLayer)});
                if (!state.ok()) {
                    return std::move(state).error();
                }
                item.pipeline = state.value();
            }
            item.uniforms.frameSize = simd_make_float4(float(frameW), float(frameH), float(1.0 / frameW), float(1.0 / frameH));
            items.push_back(item);
        }
        return media::okStatus();
    }
};

double Compositor::sharpenAmountAt(double scale) {
    static_assert(kSharpenRampEnd == kMinifyThreshold, "the ramp ends where minification (the pre-scale) starts");
    if (!(scale > 0) || scale >= kSharpenRampEnd) {
        return 0.0;
    }
    if (scale <= kSharpenRampStart) {
        return kSharpenAmount;
    }
    const double t = (kSharpenRampEnd - scale) / (kSharpenRampEnd - kSharpenRampStart); // 0 at the end, 1 at the start
    return kSharpenAmount * t * t * (3.0 - 2.0 * t);
}

Compositor::Compositor(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}

Compositor::~Compositor() {
    if (impl_ && impl_->freeSlots) {
        for (std::size_t i = 0; i < kFramesInFlight; ++i) {
            dispatch_semaphore_wait(impl_->freeSlots, DISPATCH_TIME_FOREVER);
        }
        for (std::size_t i = 0; i < kFramesInFlight; ++i) {
            dispatch_semaphore_signal(impl_->freeSlots);
        }
    }
}

id<MTLDevice> Compositor::device() const {
    return impl_->device;
}
id<MTLCommandQueue> Compositor::commandQueue() const {
    return impl_->queue;
}
const TextureCache &Compositor::textureCache() const {
    return impl_->textureCache;
}

Result<std::unique_ptr<Compositor>> Compositor::create(id<MTLDevice> device,
                                                       std::initializer_list<MTLPixelFormat> preparedFormats) {
    if (device == nil) {
        return makeError(MediaErrorCode::InvalidArgument, "Compositor: no Metal device");
    }
    auto impl = std::make_unique<Impl>();
    impl->device = device;
    impl->queue = [device newCommandQueue];
    if (impl->queue == nil) {
        return makeError(MediaErrorCode::Internal, "Compositor: cannot create a command queue");
    }
    impl->queue.label = @"Framewright compositor";
    NSError *error = nil;
    impl->library = [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:VECompositorBundleAnchor.class]
                                                  error:&error];
    if (impl->library == nil) {
        return makeError(MediaErrorCode::Internal, "Compositor: cannot load the engine Metal library: " + nsErrorText(error));
    }
    impl->vertexFunction = [impl->library newFunctionWithName:@"ve_layer_vertex"];
    impl->outputVertexFunction = [impl->library newFunctionWithName:@"ve_output_vertex"];
    {
        // The output fragment function has a function constant (the clipping overlay, off here; outputPipeline
        // specialises it on when a monitor asks), so it must be specialised to be used.
        MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
        const bool overlay = false;
        [constants setConstantValue:&overlay type:MTLDataTypeBool atIndex:VEFunctionConstantClippingOverlay];
        impl->outputFragmentFunction = [impl->library newFunctionWithName:@"ve_output_fragment"
                                                           constantValues:constants
                                                                    error:&error];
    }
    id<MTLFunction> bgra = [impl->library newFunctionWithName:@"ve_convert_to_bgra"];
    id<MTLFunction> yuv = [impl->library newFunctionWithName:@"ve_convert_to_420"];
    id<MTLFunction> premultiply = [impl->library newFunctionWithName:@"ve_premultiply"];
    id<MTLFunction> unsharp = [impl->library newFunctionWithName:@"ve_unsharp"];
    if (impl->vertexFunction == nil || impl->outputVertexFunction == nil || impl->outputFragmentFunction == nil ||
        bgra == nil || yuv == nil || premultiply == nil || unsharp == nil) {
        return makeError(MediaErrorCode::Internal, "Compositor: shader functions missing from default.metallib");
    }
    impl->convertBGRA = [device newComputePipelineStateWithFunction:bgra error:&error];
    if (impl->convertBGRA == nil) {
        return makeError(MediaErrorCode::Internal, "Compositor: BGRA conversion pipeline: " + nsErrorText(error));
    }
    impl->convert420 = [device newComputePipelineStateWithFunction:yuv error:&error];
    if (impl->convert420 == nil) {
        return makeError(MediaErrorCode::Internal, "Compositor: 4:2:0 conversion pipeline: " + nsErrorText(error));
    }
    impl->premultiply = [device newComputePipelineStateWithFunction:premultiply error:&error];
    if (impl->premultiply == nil) {
        return makeError(MediaErrorCode::Internal, "Compositor: premultiply pipeline: " + nsErrorText(error));
    }
    impl->unsharp = [device newComputePipelineStateWithFunction:unsharp error:&error];
    if (impl->unsharp == nil) {
        return makeError(MediaErrorCode::Internal, "Compositor: sharpening pipeline: " + nsErrorText(error));
    }
    if (MPSSupportsMTLDevice(device)) {
        impl->lanczos = [[MPSImageLanczosScale alloc] initWithDevice:device];
        impl->lanczos.label = @"Framewright minification";
        // Repeat the border texels (the default, zero, would darken the picture's edges).
        impl->lanczos.edgeMode = MPSImageEdgeModeClamp;
    }
    auto cache = TextureCache::create(device);
    if (!cache.ok()) {
        return std::move(cache).error();
    }
    impl->textureCache = std::move(cache).value();

    // Every target is composited in kIntermediateFormat; a prepared format also gets its output pass. Every
    // layer pipeline is made here (graded and not), so a first graded frame never waits for a compile.
    impl->pipelines.reserve(64);
    if (preparedFormats.size() > 0) {
        for (int bits = 0; bits < 128; ++bits) {
            PipelineKey key{(bits & 1) != 0,  (bits & 2) != 0,  (bits & 4) != 0,  kIntermediateFormat,
                            (bits & 8) != 0,  (bits & 16) != 0, (bits & 32) != 0, (bits & 64) != 0};
            if (!key.hasPartner && (key.bIsYCbCr || key.bIsGraded || key.bIsExtended)) {
                continue;
            }
            if ((key.aIsExtended && !key.aIsGraded) || (key.bIsExtended && !key.bIsGraded)) {
                continue; // the extended grade is a kind of grade
            }
            auto state = impl->pipeline(key);
            if (!state.ok()) {
                return std::move(state).error();
            }
        }
    }
    for (MTLPixelFormat format : preparedFormats) {
        auto state = impl->outputPipeline(format);
        if (!state.ok()) {
            return std::move(state).error();
        }
    }
    for (Impl::Slot &slot : impl->slots) {
        auto status = impl->ensureCapacity(slot, kInitialDrawCapacity);
        if (!status.ok()) {
            return std::move(status).error();
        }
        slot.retained.reserve(2 * kInitialDrawCapacity + 2);
        slot.result.skippedLayers.reserve(kInitialDrawCapacity);
    }
    impl->resolved.reserve(kInitialDrawCapacity);
    impl->drawn.reserve(kInitialDrawCapacity);
    impl->items.reserve(kInitialDrawCapacity);
    impl->skipped.reserve(kInitialDrawCapacity);
    impl->jobs.reserve(2 * kInitialDrawCapacity);
    impl->scratch.reserve(kMaxScratchTextures + 1);
    impl->freeSlots = dispatch_semaphore_create(static_cast<long>(kFramesInFlight));
    return std::unique_ptr<Compositor>(new Compositor(std::move(impl)));
}

Result<Submission> Compositor::render(const RenderGraph &graph, TextureLookup lookup, const RenderTarget &target,
                                      RenderCompletion completion, RenderOptions options) {
    Impl &im = *impl_;
    if (!graph.layers.empty() && (graph.width <= 0 || graph.height <= 0)) {
        return makeError(MediaErrorCode::InvalidArgument, "Compositor: render graph has layers but no frame size");
    }

    // Resolve the colour attachment (the working texture, the export intermediate, or for
    // compositeDirectlyForTesting the target itself) and the sequence viewport inside it.
    id<MTLTexture> colorTexture = nil;
    PixelRect viewport;
    std::int32_t targetWidth = 0;
    std::int32_t targetHeight = 0;
    const PixelBuffer *targetBuffer = nullptr;
    const TextureTarget *textureTarget = std::get_if<TextureTarget>(&target);
    id<MTLRenderPipelineState> outputState = nil; // texture targets through the working texture
    if (textureTarget != nullptr) {
        id<MTLTexture> targetTexture = textureTarget->texture;
        if (targetTexture == nil) {
            return makeError(MediaErrorCode::InvalidArgument, "Compositor: texture target has no texture");
        }
        if ((targetTexture.usage & MTLTextureUsageRenderTarget) == 0) {
            return makeError(MediaErrorCode::InvalidArgument, "Compositor: target texture lacks RenderTarget usage");
        }
        targetWidth = static_cast<std::int32_t>(targetTexture.width);
        targetHeight = static_cast<std::int32_t>(targetTexture.height);
        viewport = textureTarget->viewport;
        if (viewport.isEmpty()) {
            viewport = fitRect(graph.width, graph.height, targetWidth, targetHeight);
        }
        if (textureTarget->compositeDirectlyForTesting) {
            colorTexture = targetTexture;
        } else {
            auto state = im.outputPipeline(targetTexture.pixelFormat, textureTarget->clippingOverlay);
            if (!state.ok()) {
                return std::move(state).error();
            }
            outputState = state.value();
            VE_MEDIA_TRY(im.ensureWorking(targetTexture.width, targetTexture.height));
            colorTexture = im.working;
        }
    } else {
        targetBuffer = &std::get<PixelBufferTarget>(target).buffer;
        if (!*targetBuffer) {
            return makeError(MediaErrorCode::InvalidArgument, "Compositor: pixel buffer target is empty");
        }
        if (!isSupportedTargetFormat(targetBuffer->pixelFormat())) {
            return makeError(MediaErrorCode::UnsupportedFormat, "Compositor: unsupported target pixel format '" +
                                                                    fourCCString(targetBuffer->pixelFormat()) +
                                                                    "' (use BGRA, 420v, 420f, x420 or xf20)");
        }
        VE_MEDIA_TRY(im.ensureIntermediate(targetBuffer->width(), targetBuffer->height()));
        colorTexture = im.intermediate;
        targetWidth = static_cast<std::int32_t>(targetBuffer->width());
        targetHeight = static_cast<std::int32_t>(targetBuffer->height());
        viewport = fitRect(graph.width, graph.height, targetWidth, targetHeight);
    }

    // Target pixels per sequence pixel (the viewport keeps the sequence aspect up to rounding).
    const double targetScale = viewport.isEmpty() || graph.width <= 0 || graph.height <= 0
                                   ? 1.0
                                   : std::min(double(viewport.width) / graph.width, double(viewport.height) / graph.height);
    std::size_t drawnLayers = 0;
    // The scale sharpening also needs to minify (bindSource takes the larger of it and the drawn scale): the
    // output's for a pixel-buffer target (an export of the sequence), the sequence's own for a texture
    // target (a monitor). A monitor therefore sharpens what an export at the sequence's size sharpens when
    // it draws the picture minified too, never a picture that is not minified in the sequence (1080p in a
    // 1080p sequence), and never one it draws at 0.75 of its size or more (a 4K source on a 4K display).
    const double sharpenTargetScale = targetBuffer != nullptr ? targetScale : 1.0;
    const double snapScaleX = viewport.isEmpty() || graph.width <= 0 ? 1.0 : double(viewport.width) / graph.width;
    const double snapScaleY = viewport.isEmpty() || graph.height <= 0 ? 1.0 : double(viewport.height) / graph.height;
    if (Status built = im.buildItems(graph, lookup, colorTexture.pixelFormat, targetScale, sharpenTargetScale,
                                     snapScaleX, snapScaleY, drawnLayers);
        !built.ok()) {
        im.dropScratchReferences();
        return std::move(built).error();
    }

    // Target planes for pixel-buffer output (mapped before taking a slot so errors need no cleanup).
    TextureSet outputPlanes;
    if (targetBuffer != nullptr) {
        auto planes = im.textureCache.textures(*targetBuffer, TextureAccess::ReadWrite);
        if (!planes.ok()) {
            im.dropScratchReferences();
            return std::move(planes).error();
        }
        outputPlanes = std::move(planes).value();
    }

    const dispatch_time_t timeout = options.waitForFreeSlot ? DISPATCH_TIME_FOREVER : DISPATCH_TIME_NOW;
    if (dispatch_semaphore_wait(im.freeSlots, timeout) != 0) {
        im.dropScratchReferences();
        return Submission::Busy;
    }
    // From here on every failure must give the slot back (and drop what the frame referenced),
    // or a later frame would find the free-slot count and the free slots out of step.
    const std::size_t slotIndex = im.takeFreeSlot();
    Impl::Slot &slot = im.slots[slotIndex];
    auto abandon = [&im, slotIndex](media::MediaError error) -> Result<Submission> {
        Impl::Slot &s = im.slots[slotIndex];
        s.retained.clear();
        s.completion = nullptr;
        im.dropScratchReferences();
        im.returnSlot(slotIndex);
        return error;
    };
    if (im.consumeFault(Fault::UniformBuffer)) {
        return abandon(makeError(MediaErrorCode::Internal, "Compositor: cannot allocate the uniform buffer (injected)"));
    }
    if (Status st = im.ensureCapacity(slot, im.items.size()); !st.ok()) {
        return abandon(std::move(st).error());
    }

    id<MTLCommandBuffer> commandBuffer = im.consumeFault(Fault::CommandBuffer) ? nil : [im.queue commandBuffer];
    if (commandBuffer == nil) {
        return abandon(makeError(MediaErrorCode::Internal, "Compositor: cannot create a command buffer"));
    }
    commandBuffer.label = @"Framewright frame";

    slot.retained.clear();
    auto *uniformBytes = static_cast<std::uint8_t *>(slot.uniforms.contents);
    im.encodePrescaleJobs(commandBuffer);
    const std::size_t prescaledPlanes = im.jobs.size();
    const std::size_t sharpenedPlanes = im.sharpenedJobCount();
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = colorTexture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder =
        im.consumeFault(Fault::RenderEncoder) ? nil : [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (encoder == nil) {
        // Nothing was committed: the command buffer is simply dropped.
        return abandon(makeError(MediaErrorCode::Internal, "Compositor: cannot create a render command encoder"));
    }
    encoder.label = @"Framewright layers";
    // The viewport may reach outside the target (a caller's viewport); the scissor rectangle
    // must not, so it is the part of the viewport inside the target (the top-left target-sized
    // region of a larger working texture).
    const PixelRect scissor = clipRect(viewport, targetWidth, targetHeight);
    if (!im.items.empty() && !scissor.isEmpty()) {
        [encoder setViewport:(MTLViewport){double(viewport.x), double(viewport.y), double(viewport.width),
                                           double(viewport.height), 0.0, 1.0}];
        [encoder setScissorRect:(MTLScissorRect){NSUInteger(scissor.x), NSUInteger(scissor.y),
                                                 NSUInteger(scissor.width), NSUInteger(scissor.height)}];
        id<MTLRenderPipelineState> current = nil;
        for (std::size_t k = 0; k < im.items.size(); ++k) {
            const DrawItem &item = im.items[k];
            const std::size_t offset = k * kDrawStride;
            std::memcpy(uniformBytes + offset, &item.uniforms, sizeof(VEDrawUniforms));
            if (item.pipeline != current) {
                [encoder setRenderPipelineState:item.pipeline];
                current = item.pipeline;
            }
            [encoder setVertexBuffer:slot.uniforms offset:offset atIndex:VEBufferIndexDraw];
            [encoder setFragmentBuffer:slot.uniforms offset:offset atIndex:VEBufferIndexDraw];
            [encoder setFragmentTexture:item.a.planes[0] atIndex:VETextureIndexA0];
            [encoder setFragmentTexture:item.a.planes[1] atIndex:VETextureIndexA1];
            if (item.a.gradeTables != nil) {
                [encoder setFragmentTexture:item.a.gradeTables atIndex:VETextureIndexAGradeTables];
                [encoder setFragmentTexture:item.a.inputCube atIndex:VETextureIndexAInputCube];
                [encoder setFragmentTexture:item.a.lookCube atIndex:VETextureIndexALookCube];
            }
            slot.retained.push_back(im.resolved[item.layerA]);
            if (item.layerB != item.layerA) {
                [encoder setFragmentTexture:item.b.planes[0] atIndex:VETextureIndexB0];
                [encoder setFragmentTexture:item.b.planes[1] atIndex:VETextureIndexB1];
                if (item.b.gradeTables != nil) {
                    [encoder setFragmentTexture:item.b.gradeTables atIndex:VETextureIndexBGradeTables];
                    [encoder setFragmentTexture:item.b.inputCube atIndex:VETextureIndexBInputCube];
                    [encoder setFragmentTexture:item.b.lookCube atIndex:VETextureIndexBLookCube];
                }
                slot.retained.push_back(im.resolved[item.layerB]);
            }
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
    }
    [encoder endEncoding];

    if (outputState != nil) {
        // A scope (or a test) reads the frame as blended, then the output pass writes the target.
        if (textureTarget->workingFrameReader) {
            textureTarget->workingFrameReader(commandBuffer, im.working, scissor);
        }
        MTLRenderPassDescriptor *output = [MTLRenderPassDescriptor renderPassDescriptor];
        output.colorAttachments[0].texture = textureTarget->texture;
        output.colorAttachments[0].loadAction = MTLLoadActionDontCare; // every pixel is written
        output.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> outputEncoder = [commandBuffer renderCommandEncoderWithDescriptor:output];
        if (outputEncoder == nil) {
            return abandon(makeError(MediaErrorCode::Internal, "Compositor: cannot create the output render encoder"));
        }
        outputEncoder.label = @"Framewright output";
        [outputEncoder setRenderPipelineState:outputState];
        [outputEncoder setFragmentTexture:im.working atIndex:VETextureIndexWorking];
        if (textureTarget->clippingOverlay) {
            const simd_float4 frame = simd_make_float4(float(scissor.x), float(scissor.y), float(scissor.x + scissor.width),
                                                       float(scissor.y + scissor.height));
            [outputEncoder setFragmentBytes:&frame length:sizeof frame atIndex:VEBufferIndexOutputFrame];
        }
        [outputEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [outputEncoder endEncoding];
    }

    if (targetBuffer != nullptr) {
        const OSType format = targetBuffer->pixelFormat();
        const std::size_t w = targetBuffer->width();
        const std::size_t h = targetBuffer->height();
        VEConvertUniforms convert{};
        convert.width = static_cast<VEUInt>(w);
        convert.height = static_cast<VEUInt>(h);
        media::ColorInfo tags = media::ColorInfo::bt709();
        const bool biplanar = format != kCVPixelFormatType_32BGRA;
        CVBufferRef targetRef = targetBuffer->get();
        if (biplanar) {
            // ve_convert_to_420 produces left-sited chroma (the H.264/HEVC default, so players that
            // ignore the tag still place it right); say so.
            CVBufferSetAttachment(targetRef, kCVImageBufferChromaLocationTopFieldKey,
                                  chromaLocationString(ChromaSiting::Left), kCVAttachmentMode_ShouldPropagate);
            CVBufferSetAttachment(targetRef, kCVImageBufferChromaLocationBottomFieldKey,
                                  chromaLocationString(ChromaSiting::Left), kCVAttachmentMode_ShouldPropagate);
            tags.fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
                             format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
            const bool tenBit = format == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                                format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange;
            convert.tenBitCodes = tenBit ? 1u : 0u;
            const RGBToYCbCrRows rows = rgbToYCbCrRows(media::YCbCrMatrix::BT709, tags.fullRange, tenBit ? 10 : 8);
            convert.yRow = rows.y;
            convert.cbRow = rows.cb;
            convert.crRow = rows.cr;
        } else {
            // RGB output: no matrix or chroma siting (pooled buffers may carry stale ones).
            tags.matrix = media::YCbCrMatrix::Unknown;
            CVBufferRemoveAttachment(targetRef, kCVImageBufferYCbCrMatrixKey);
            CVBufferRemoveAttachment(targetRef, kCVImageBufferChromaLocationTopFieldKey);
            CVBufferRemoveAttachment(targetRef, kCVImageBufferChromaLocationBottomFieldKey);
        }
        const std::size_t offset = slot.drawCapacity * kDrawStride;
        std::memcpy(uniformBytes + offset, &convert, sizeof(convert));
        id<MTLComputeCommandEncoder> compute = [commandBuffer computeCommandEncoder];
        compute.label = @"Framewright output conversion";
        id<MTLComputePipelineState> state = biplanar ? im.convert420 : im.convertBGRA;
        [compute setComputePipelineState:state];
        [compute setBuffer:slot.uniforms offset:offset atIndex:VEBufferIndexConvert];
        [compute setTexture:im.intermediate atIndex:VETextureIndexComposite];
        [compute setTexture:outputPlanes.plane(0) atIndex:VETextureIndexOut0];
        MTLSize grid = MTLSizeMake(w, h, 1);
        if (biplanar) {
            [compute setTexture:outputPlanes.plane(1) atIndex:VETextureIndexOut1];
            grid = MTLSizeMake((w + 1) / 2, (h + 1) / 2, 1);
        }
        const NSUInteger tw = state.threadExecutionWidth;
        const NSUInteger th = std::max<NSUInteger>(1, state.maxTotalThreadsPerThreadgroup / tw);
        [compute dispatchThreads:grid threadsPerThreadgroup:MTLSizeMake(tw, std::min<NSUInteger>(th, 16), 1)];
        [compute endEncoding];
        media::attachColorInfo(targetRef, tags);
        slot.retained.push_back(std::move(outputPlanes));
    }

    if (textureTarget != nullptr && textureTarget->drawable != nil) {
        [commandBuffer presentDrawable:textureTarget->drawable];
    }

    // Fill the slot's result (the slot is ours until the completion handler gives it back).
    slot.result.frameNumber = ++im.frameCounter;
    slot.result.status = media::okStatus();
    slot.result.skippedLayers.assign(im.skipped.begin(), im.skipped.end());
    slot.result.drawnLayers = drawnLayers;
    slot.result.prescaledPlanes = prescaledPlanes;
    slot.result.sharpenedPlanes = sharpenedPlanes;
    slot.result.gpuSeconds = 0;
    slot.result.gpuStartTime = 0;
    slot.result.gpuEndTime = 0;
    slot.completion = std::move(completion);

    Impl *implPtr = impl_.get();
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> finished) {
        Impl::Slot &done = implPtr->slots[slotIndex];
        if (finished.status == MTLCommandBufferStatusError) {
            done.result.status = makeError(MediaErrorCode::Internal,
                                           "Compositor: GPU command buffer failed: " + nsErrorText(finished.error),
                                           "MTLCommandBufferError", finished.error.code);
        }
        done.result.gpuSeconds = std::max(0.0, finished.GPUEndTime - finished.GPUStartTime);
        done.result.gpuStartTime = finished.GPUStartTime;
        done.result.gpuEndTime = finished.GPUEndTime;
        if (done.completion) {
            done.completion(done.result);
        }
        done.completion = nullptr;
        done.retained.clear();
        implPtr->returnSlot(slotIndex);
    }];
    [commandBuffer commit];
    // The slot and the command buffer now hold what the GPU needs; drop the scratch references.
    im.dropScratchReferences();
    im.trimScratch();
    return Submission::Submitted;
}

std::size_t Compositor::freeSlotCount() const {
    return static_cast<std::size_t>(std::popcount(impl_->freeMask.load(std::memory_order_acquire)));
}

bool Compositor::waitForFreeSlot(double timeoutSeconds) const {
    const dispatch_time_t deadline =
        timeoutSeconds <= 0 ? DISPATCH_TIME_NOW
                            : dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(timeoutSeconds * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(impl_->freeSlots, deadline) != 0) {
        return false;
    }
    dispatch_semaphore_signal(impl_->freeSlots);
    return true;
}

void Compositor::releaseScratchMemory() {
    Impl &im = *impl_;
    im.scratch.clear();
    im.intermediate = nil;
    im.working = nil;
    im.textureCache.flush();
    im.gradeTables.clear();
    im.cubes.clear();
}

Compositor::Stats Compositor::stats() const {
    const Impl &im = *impl_;
    Stats st;
    st.freeSlots = freeSlotCount();
    st.scratchTextures = im.scratch.size();
    st.scratchAllocations = im.scratchAllocations;
    st.workingAllocations = im.workingAllocations;
    if (im.working != nil) {
        st.workingWidth = im.working.width;
        st.workingHeight = im.working.height;
        st.workingBytes = im.working.allocatedSize;
    }
    for (const ScratchTexture &e : im.scratch) {
        st.scratchBytes += e.texture.allocatedSize;
    }
    return st;
}

void Compositor::injectFaultForTesting(Fault fault) {
    impl_->injectedFault.store(fault);
}

std::size_t Compositor::holdSlotsForTesting(std::size_t count, double timeoutSeconds) {
    Impl &im = *impl_;
    std::size_t taken = 0;
    for (; taken < count; ++taken) {
        const dispatch_time_t deadline = dispatch_time(DISPATCH_TIME_NOW, static_cast<int64_t>(timeoutSeconds * NSEC_PER_SEC));
        if (dispatch_semaphore_wait(im.freeSlots, deadline) != 0) {
            break;
        }
        std::lock_guard<std::mutex> lock(im.heldMutex);
        im.heldSlots.push_back(im.takeFreeSlot());
    }
    return taken;
}

void Compositor::releaseHeldSlotsForTesting() {
    Impl &im = *impl_;
    std::lock_guard<std::mutex> lock(im.heldMutex);
    for (std::size_t index : im.heldSlots) {
        im.returnSlot(index);
    }
    im.heldSlots.clear();
}

Result<RenderResult> Compositor::renderAndWait(const RenderGraph &graph, TextureLookup lookup,
                                               const RenderTarget &target) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    RenderResult copy;
    RenderResult *out = &copy;
    auto submitted = render(
        graph, lookup, target,
        [out, done](const RenderResult &result) {
            *out = result;
            dispatch_semaphore_signal(done);
        },
        RenderOptions{true});
    if (!submitted.ok()) {
        return std::move(submitted).error();
    }
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return copy;
}

} // namespace ve::render
