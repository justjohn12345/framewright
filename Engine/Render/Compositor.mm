#include "Compositor.h"

#include "../Media/ColorTags.h"
#include "ColorMath.h"
#include "ShaderTypes.h"

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

static_assert(sizeof(VESourceUniforms) == 128, "VESourceUniforms layout must match Shaders.metal");
static_assert(sizeof(VEDrawUniforms) == 64 + 2 * 128, "VEDrawUniforms layout must match Shaders.metal");
static_assert(sizeof(VEConvertUniforms) == 64, "VEConvertUniforms layout must match Shaders.metal");

PixelRect fitRect(double sourceWidth, double sourceHeight, std::int32_t destWidth, std::int32_t destHeight) {
    if (!(sourceWidth > 0) || !(sourceHeight > 0) || destWidth <= 0 || destHeight <= 0) {
        return {};
    }
    const double scale = std::min(destWidth / sourceWidth, destHeight / sourceHeight);
    PixelRect r;
    r.width = std::clamp(static_cast<std::int32_t>(std::lround(sourceWidth * scale)), 1, destWidth);
    r.height = std::clamp(static_cast<std::int32_t>(std::lround(sourceHeight * scale)), 1, destHeight);
    r.x = (destWidth - r.width) / 2;
    r.y = (destHeight - r.height) / 2;
    return r;
}

namespace {

constexpr std::size_t kUniformAlignment = 256; // constant-buffer offset alignment (macOS)
constexpr std::size_t kInitialDrawCapacity = 64;
constexpr MTLPixelFormat kIntermediateFormat = MTLPixelFormatRGBA16Float;

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

    std::uint64_t packed() const {
        return (static_cast<std::uint64_t>(format) << 3) | (aIsYCbCr ? 1u : 0u) | (hasPartner ? 2u : 0u) |
               (hasPartner && bIsYCbCr ? 4u : 0u);
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

// Geometry, in order: the decoded (storage-orientation) picture is rotated by the container
// rotation, the rotated picture is fitted into the sequence frame, then the clip transform
// (scale about the centre, rotation, offset) is applied. The returned rows map a sequence
// position to storage uv.
Placement placeSource(const VideoParams &params, std::int32_t sourceRotationDegrees, double storageWidth,
                      double storageHeight, double frameWidth, double frameHeight) {
    Placement p{};
    const int quarterTurns = quarterTurnsClockwise(sourceRotationDegrees);
    const bool swapped = (quarterTurns & 1) != 0;
    const double sourceWidth = swapped ? storageHeight : storageWidth; // displayed orientation
    const double sourceHeight = swapped ? storageWidth : storageHeight;
    const double fit = std::min(frameWidth / sourceWidth, frameHeight / sourceHeight);
    const double sx = sourceWidth * fit * params.scale;
    const double sy = sourceHeight * fit * params.scale;
    if (!(sx > 1e-6) || !(sy > 1e-6) || !std::isfinite(sx) || !std::isfinite(sy)) {
        return p;
    }
    const double theta = params.rotationDegrees * M_PI / 180.0;
    const double c = std::cos(theta);
    const double s = std::sin(theta);
    const double cx = frameWidth / 2.0 + params.x;
    const double cy = frameHeight / 2.0 + params.y;
    // Displayed uv' of a sequence position. Forward: p = centre + R (uv' - 0.5) * size,
    // R = [c -s; s c] (clockwise with +y down). Inverse: uv' = 0.5 + R^T (p - centre) / size.
    const simd_float4 ux = simd_make_float4(float(c / sx), float(s / sx), float(0.5 - (c * cx + s * cy) / sx), 0.0f);
    const simd_float4 uy = simd_make_float4(float(-s / sy), float(c / sy), float(0.5 - (-s * cx + c * cy) / sy), 0.0f);
    // Storage uv from displayed uv' (the storage picture turned clockwise by quarterTurns):
    //   90: u = v', v = 1 - u'   180: u = 1 - u', v = 1 - v'   270: u = 1 - v', v = u'
    const simd_float4 one = simd_make_float4(0.0f, 0.0f, 1.0f, 0.0f);
    switch (quarterTurns) {
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
    p.scale = fit * params.scale;
    // Bounding box of the rotated rectangle.
    const double hx = std::fabs(c) * sx / 2.0 + std::fabs(s) * sy / 2.0;
    const double hy = std::fabs(s) * sx / 2.0 + std::fabs(c) * sy / 2.0;
    p.x0 = std::max(0.0, std::floor(cx - hx) - 1.0);
    p.y0 = std::max(0.0, std::floor(cy - hy) - 1.0);
    p.x1 = std::min(frameWidth, std::ceil(cx + hx) + 1.0);
    p.y1 = std::min(frameHeight, std::ceil(cy + hy) + 1.0);
    p.visible = p.x1 > p.x0 && p.y1 > p.y0;
    return p;
}

void fillSource(VESourceUniforms &u, const VideoLayer &layer, const TextureSet &textures, const Placement &placement,
                double weight) {
    u.colorMatrix = textures.colorMatrix();
    u.uvFromFrameX = placement.uvFromFrameX;
    u.uvFromFrameY = placement.uvFromFrameY;
    u.chromaTransform = textures.chromaTransform();
    const bool straight =
        textures.sourceClass() == SourceClass::RGBA && !textures.alphaIsPremultiplied(layer.isStill);
    u.params = simd_make_float4(float(std::clamp(weight, 0.0, 1.0)), straight ? 1.0f : 0.0f, 0.0f, 0.0f);
}

struct DrawItem {
    VEDrawUniforms uniforms;
    id<MTLRenderPipelineState> pipeline;
    std::size_t layerA;
    std::size_t layerB; // == layerA when drawn alone
};

std::string nsErrorText(NSError *error) {
    return error ? std::string(error.localizedDescription.UTF8String ?: "") : std::string("unknown error");
}

bool isSupportedTargetFormat(OSType f) {
    return f == kCVPixelFormatType_32BGRA || f == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           f == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
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

    // Drops the per-frame references to source pictures (they live on in a slot if submitted).
    void dropScratchReferences() {
        for (TextureSet &t : resolved) {
            t.reset();
        }
    }

    bool consumeFault(Fault fault) {
        Fault expected = fault;
        return injectedFault.load(std::memory_order_relaxed) == fault &&
               injectedFault.compare_exchange_strong(expected, Fault::None);
    }

    id<MTLTexture> intermediate = nil;

    // Per-frame scratch, reused (capacity kept) across frames.
    std::vector<TextureSet> resolved;
    std::vector<char> drawn;
    std::vector<DrawItem> items;
    std::vector<SkippedLayer> skipped;

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
        [constants setConstantValue:&a type:MTLDataTypeBool atIndex:VEFunctionConstantSourceAIsYCbCr];
        [constants setConstantValue:&partner type:MTLDataTypeBool atIndex:VEFunctionConstantHasPartner];
        [constants setConstantValue:&b type:MTLDataTypeBool atIndex:VEFunctionConstantSourceBIsYCbCr];
        NSError *error = nil;
        id<MTLFunction> fragment = [library newFunctionWithName:@"ve_layer_fragment" constantValues:constants error:&error];
        if (fragment == nil) {
            return makeError(MediaErrorCode::Internal, "Compositor: cannot specialise ve_layer_fragment: " + nsErrorText(error));
        }
        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.label = @"VidEdit layer";
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
        intermediate.label = @"VidEdit composite";
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
        slot.uniforms.label = @"VidEdit uniforms";
        slot.drawCapacity = capacity;
        return media::okStatus();
    }

    // Builds `items` for the graph; fills `skipped` and `resolved`.
    Status buildItems(const RenderGraph &graph, TextureLookup lookup, MTLPixelFormat format, std::size_t &drawnLayers) {
        const std::size_t n = graph.layers.size();
        items.clear();
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
                double weight = layer.opacity;
                if (layer.transition) {
                    weight *= layer.transition->weight();
                }
                const TextureSet &t = resolved[i];
                const Placement pl = placeSource(layer.transform, layer.sourceRotationDegrees, double(t.width()),
                                                 double(t.height()), frameW, frameH);
                drawn[i] = 1;
                ++drawnLayers;
                if (!pl.visible || weight <= 0.0) {
                    continue;
                }
                fillSource(item.uniforms.a, layer, t, pl, weight);
                item.uniforms.quadRect = simd_make_float4(float(pl.x0), float(pl.y0), float(pl.x1), float(pl.y1));
                item.layerA = item.layerB = i;
                auto state = pipeline({t.sourceClass() == SourceClass::YCbCrBiPlanar, false, false, format});
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
                const Placement pa = placeSource(outLayer.transform, outLayer.sourceRotationDegrees,
                                                 double(ta.width()), double(ta.height()), frameW, frameH);
                const Placement pb = placeSource(inLayer.transform, inLayer.sourceRotationDegrees, double(tb.width()),
                                                 double(tb.height()), frameW, frameH);
                drawn[i] = drawn[partner] = 1;
                drawnLayers += 2;
                if (!pa.visible && !pb.visible) {
                    continue;
                }
                fillSource(item.uniforms.a, outLayer, ta, pa, pa.visible ? outLayer.opacity : 0.0);
                fillSource(item.uniforms.b, inLayer, tb, pb, pb.visible ? inLayer.opacity : 0.0);
                double x0 = pa.visible ? pa.x0 : pb.x0, y0 = pa.visible ? pa.y0 : pb.y0;
                double x1 = pa.visible ? pa.x1 : pb.x1, y1 = pa.visible ? pa.y1 : pb.y1;
                if (pa.visible && pb.visible) {
                    x0 = std::min(pa.x0, pb.x0);
                    y0 = std::min(pa.y0, pb.y0);
                    x1 = std::max(pa.x1, pb.x1);
                    y1 = std::max(pa.y1, pb.y1);
                }
                item.uniforms.quadRect = simd_make_float4(float(x0), float(y0), float(x1), float(y1));
                item.uniforms.mix =
                    simd_make_float4(float(std::clamp(inLayer.transition->mix, 0.0, 1.0)), 0.0f, 0.0f, 0.0f);
                item.layerA = out;
                item.layerB = in;
                auto state = pipeline({ta.sourceClass() == SourceClass::YCbCrBiPlanar, true,
                                       tb.sourceClass() == SourceClass::YCbCrBiPlanar, format});
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

Result<std::unique_ptr<Compositor>> Compositor::create(id<MTLDevice> device) {
    if (device == nil) {
        return makeError(MediaErrorCode::InvalidArgument, "Compositor: no Metal device");
    }
    auto impl = std::make_unique<Impl>();
    impl->device = device;
    impl->queue = [device newCommandQueue];
    if (impl->queue == nil) {
        return makeError(MediaErrorCode::Internal, "Compositor: cannot create a command queue");
    }
    impl->queue.label = @"VidEdit compositor";
    NSError *error = nil;
    impl->library = [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:VECompositorBundleAnchor.class]
                                                  error:&error];
    if (impl->library == nil) {
        return makeError(MediaErrorCode::Internal, "Compositor: cannot load the engine Metal library: " + nsErrorText(error));
    }
    impl->vertexFunction = [impl->library newFunctionWithName:@"ve_layer_vertex"];
    id<MTLFunction> bgra = [impl->library newFunctionWithName:@"ve_convert_to_bgra"];
    id<MTLFunction> yuv = [impl->library newFunctionWithName:@"ve_convert_to_420"];
    if (impl->vertexFunction == nil || bgra == nil || yuv == nil) {
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
    auto cache = TextureCache::create(device);
    if (!cache.ok()) {
        return std::move(cache).error();
    }
    impl->textureCache = std::move(cache).value();

    impl->pipelines.reserve(32);
    for (MTLPixelFormat format : {MTLPixelFormatBGRA8Unorm, kIntermediateFormat}) {
        for (int bits = 0; bits < 8; ++bits) {
            PipelineKey key{(bits & 1) != 0, (bits & 2) != 0, (bits & 4) != 0, format};
            if (!key.hasPartner && key.bIsYCbCr) {
                continue;
            }
            auto state = impl->pipeline(key);
            if (!state.ok()) {
                return std::move(state).error();
            }
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
    impl->freeSlots = dispatch_semaphore_create(static_cast<long>(kFramesInFlight));
    return std::unique_ptr<Compositor>(new Compositor(std::move(impl)));
}

Result<Submission> Compositor::render(const RenderGraph &graph, TextureLookup lookup, const RenderTarget &target,
                                      RenderCompletion completion, RenderOptions options) {
    Impl &im = *impl_;
    if (!graph.layers.empty() && (graph.width <= 0 || graph.height <= 0)) {
        return makeError(MediaErrorCode::InvalidArgument, "Compositor: render graph has layers but no frame size");
    }

    // Resolve the colour attachment and the sequence viewport inside it.
    id<MTLTexture> colorTexture = nil;
    PixelRect viewport;
    const PixelBuffer *targetBuffer = nullptr;
    if (const auto *tt = std::get_if<TextureTarget>(&target)) {
        colorTexture = tt->texture;
        if (colorTexture == nil) {
            return makeError(MediaErrorCode::InvalidArgument, "Compositor: texture target has no texture");
        }
        if ((colorTexture.usage & MTLTextureUsageRenderTarget) == 0) {
            return makeError(MediaErrorCode::InvalidArgument, "Compositor: target texture lacks RenderTarget usage");
        }
        viewport = tt->viewport;
        if (viewport.isEmpty()) {
            viewport = fitRect(graph.width, graph.height, static_cast<std::int32_t>(colorTexture.width),
                               static_cast<std::int32_t>(colorTexture.height));
        }
    } else {
        targetBuffer = &std::get<PixelBufferTarget>(target).buffer;
        if (!*targetBuffer) {
            return makeError(MediaErrorCode::InvalidArgument, "Compositor: pixel buffer target is empty");
        }
        if (!isSupportedTargetFormat(targetBuffer->pixelFormat())) {
            return makeError(MediaErrorCode::UnsupportedFormat, "Compositor: unsupported target pixel format '" +
                                                                    fourCCString(targetBuffer->pixelFormat()) +
                                                                    "' (use BGRA, 420v or 420f)");
        }
        VE_MEDIA_TRY(im.ensureIntermediate(targetBuffer->width(), targetBuffer->height()));
        colorTexture = im.intermediate;
        viewport = fitRect(graph.width, graph.height, static_cast<std::int32_t>(targetBuffer->width()),
                           static_cast<std::int32_t>(targetBuffer->height()));
    }

    std::size_t drawnLayers = 0;
    VE_MEDIA_TRY(im.buildItems(graph, lookup, colorTexture.pixelFormat, drawnLayers));

    // Target planes for pixel-buffer output (mapped before taking a slot so errors need no cleanup).
    TextureSet outputPlanes;
    if (targetBuffer != nullptr) {
        auto planes = im.textureCache.textures(*targetBuffer, TextureAccess::ReadWrite);
        if (!planes.ok()) {
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
    commandBuffer.label = @"VidEdit frame";

    slot.retained.clear();
    auto *uniformBytes = static_cast<std::uint8_t *>(slot.uniforms.contents);
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
    encoder.label = @"VidEdit layers";
    if (!im.items.empty() && !viewport.isEmpty()) {
        [encoder setViewport:(MTLViewport){double(viewport.x), double(viewport.y), double(viewport.width),
                                           double(viewport.height), 0.0, 1.0}];
        [encoder setScissorRect:(MTLScissorRect){NSUInteger(viewport.x), NSUInteger(viewport.y),
                                                 NSUInteger(viewport.width), NSUInteger(viewport.height)}];
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
            const TextureSet &a = im.resolved[item.layerA];
            [encoder setFragmentTexture:a.plane(0) atIndex:VETextureIndexA0];
            [encoder setFragmentTexture:a.plane(1) atIndex:VETextureIndexA1];
            slot.retained.push_back(a);
            if (item.layerB != item.layerA) {
                const TextureSet &b = im.resolved[item.layerB];
                [encoder setFragmentTexture:b.plane(0) atIndex:VETextureIndexB0];
                [encoder setFragmentTexture:b.plane(1) atIndex:VETextureIndexB1];
                slot.retained.push_back(b);
            }
            [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        }
    }
    [encoder endEncoding];

    if (targetBuffer != nullptr) {
        const OSType format = targetBuffer->pixelFormat();
        const std::size_t w = targetBuffer->width();
        const std::size_t h = targetBuffer->height();
        VEConvertUniforms convert{};
        convert.size = simd_make_uint4(static_cast<unsigned>(w), static_cast<unsigned>(h), 0, 0);
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
            tags.fullRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
            const RGBToYCbCrRows rows = rgbToYCbCr8Rows(media::YCbCrMatrix::BT709, tags.fullRange);
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
        compute.label = @"VidEdit output conversion";
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

    if (const auto *tt = std::get_if<TextureTarget>(&target); tt != nullptr && tt->drawable != nil) {
        [commandBuffer presentDrawable:tt->drawable];
    }

    // Fill the slot's result (the slot is ours until the completion handler gives it back).
    slot.result.frameNumber = ++im.frameCounter;
    slot.result.status = media::okStatus();
    slot.result.skippedLayers.assign(im.skipped.begin(), im.skipped.end());
    slot.result.drawnLayers = drawnLayers;
    slot.result.gpuSeconds = 0;
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
        if (done.completion) {
            done.completion(done.result);
        }
        done.completion = nullptr;
        done.retained.clear();
        implPtr->returnSlot(slotIndex);
    }];
    [commandBuffer commit];
    // The slot now holds what the GPU needs; drop the scratch references.
    im.dropScratchReferences();
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
