#include "Vectorscope.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <string>
#include <utility>

// The framework's bundle (the compositor loads its library the same way).
@interface VEVectorscopeBundleAnchor : NSObject
@end
@implementation VEVectorscopeBundleAnchor
@end

namespace ve::render {

using media::MediaErrorCode;

namespace {

media::MediaError vectorscopeError(const std::string &what, NSError *error = nil) {
    std::string text = "Vectorscope: " + what;
    if (error != nil) {
        text += ": ";
        text += error.localizedDescription.UTF8String ?: "";
    }
    return media::makeError(MediaErrorCode::Internal, text);
}

} // namespace

struct Vectorscope::Impl {
    id<MTLDevice> device = nil;
    id<MTLComputePipelineState> accumulate = nil;
    id<MTLFunction> displayVertex = nil;
    id<MTLFunction> displayFragment = nil;
    std::vector<std::pair<MTLPixelFormat, id<MTLRenderPipelineState>>> displayPipelines;
    id<MTLBuffer> counts = nil;
    id<MTLBuffer> discardedStats = nil;
    VEVectorscopeUniforms uniforms{};
    bool accumulated = false;
    std::uint64_t samples = 0;

    id<MTLRenderPipelineState> displayPipeline(MTLPixelFormat format) {
        for (const auto &entry : displayPipelines) {
            if (entry.first == format) {
                return entry.second;
            }
        }
        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.label = @"Framewright vectorscope";
        desc.vertexFunction = displayVertex;
        desc.fragmentFunction = displayFragment;
        desc.colorAttachments[0].pixelFormat = format;
        NSError *error = nil;
        id<MTLRenderPipelineState> state = [device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (state != nil) {
            displayPipelines.emplace_back(format, state);
        }
        return state;
    }
};

std::array<double, 2> Vectorscope::chromaOf(const std::array<double, 3> &rgb) {
    const double y = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
    return {(rgb[2] - y) / 1.8556, (rgb[0] - y) / 1.5748};
}

std::array<std::uint32_t, 2> Vectorscope::binOf(double cb, double cr) {
    const double last = double(kBins - 1);
    return {std::uint32_t(std::clamp(std::nearbyint((cb + 0.5) * last), 0.0, last)),
            std::uint32_t(std::clamp(std::nearbyint((cr + 0.5) * last), 0.0, last))};
}

std::array<std::array<double, 2>, 6> Vectorscope::barTargets() {
    const std::array<std::array<double, 3>, 6> bars = {{{0.75, 0, 0}, {0.75, 0, 0.75}, {0, 0, 0.75},
                                                        {0, 0.75, 0.75}, {0, 0.75, 0}, {0.75, 0.75, 0}}};
    std::array<std::array<double, 2>, 6> targets{};
    for (std::size_t i = 0; i < bars.size(); ++i) {
        targets[i] = chromaOf(bars[i]);
    }
    return targets;
}

std::uint32_t Vectorscope::sampleRowsFor(const PixelRect &frame, std::int32_t width, std::int32_t height) {
    const PixelRect r = clipToTexture(frame, width, height);
    return r.isEmpty() ? 0u : std::min<std::uint32_t>(kMaxSampleRows, std::uint32_t(r.height));
}

media::Result<std::unique_ptr<Vectorscope>> Vectorscope::create(id<MTLDevice> device) {
    if (device == nil) {
        return vectorscopeError("no Metal device");
    }
    auto impl = std::make_unique<Impl>();
    impl->device = device;
    NSError *error = nil;
    id<MTLLibrary> library =
        [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:VEVectorscopeBundleAnchor.class] error:&error];
    if (library == nil) {
        return vectorscopeError("cannot load the engine Metal library", error);
    }
    id<MTLFunction> accumulate = [library newFunctionWithName:@"ve_vectorscope_accumulate"];
    impl->displayVertex = [library newFunctionWithName:@"ve_output_vertex"];
    impl->displayFragment = [library newFunctionWithName:@"ve_vectorscope_fragment"];
    if (accumulate == nil || impl->displayVertex == nil || impl->displayFragment == nil) {
        return vectorscopeError("shader functions missing from default.metallib");
    }
    impl->accumulate = [device newComputePipelineStateWithFunction:accumulate error:&error];
    if (impl->accumulate == nil) {
        return vectorscopeError("accumulate pipeline", error);
    }
    const NSUInteger length = NSUInteger(kBins) * kBins * sizeof(std::uint32_t);
    impl->counts = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
    impl->discardedStats = [device newBufferWithLength:ScopeStatsRing::kSlotStride options:MTLResourceStorageModePrivate];
    if (impl->counts == nil || impl->discardedStats == nil) {
        return vectorscopeError("cannot allocate the counts");
    }
    impl->counts.label = @"Framewright vectorscope counts";
    impl->discardedStats.label = @"Framewright vectorscope discarded clipping counters";
    std::memset(impl->counts.contents, 0, length);
    VEVectorscopeUniforms &u = impl->uniforms;
    const auto targets = barTargets();
    for (std::size_t i = 0; i < 3; ++i) {
        u.targets[i] = simd_make_float4(float(targets[2 * i][0]), float(targets[2 * i][1]), float(targets[2 * i + 1][0]),
                                        float(targets[2 * i + 1][1]));
    }
    const double skin = kSkinToneDegrees * M_PI / 180.0;
    u.skinLine = simd_make_float4(float(std::cos(skin)), float(std::sin(skin)), 0.0f, 0.0f);
    return std::unique_ptr<Vectorscope>(new Vectorscope(std::move(impl)));
}

Vectorscope::Vectorscope(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}

Vectorscope::~Vectorscope() = default;

bool Vectorscope::encodeAccumulate(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> working, const PixelRect &frame,
                                   const ScopeStatsSlot *stats) {
    Impl &im = *impl_;
    if (commandBuffer == nil || working == nil || working.device != im.device) {
        return false;
    }
    const PixelRect r = clipToTexture(frame, std::int32_t(working.width), std::int32_t(working.height));
    if (r.isEmpty()) {
        return false;
    }
    const std::uint32_t rows = std::min<std::uint32_t>(kMaxSampleRows, std::uint32_t(r.height));
    VEVectorscopeUniforms &u = im.uniforms;
    u.frame = simd_make_float4(float(r.x), float(r.y), float(r.width), float(r.height));
    u.sampleRows = rows;
    im.samples = std::uint64_t(r.width) * rows;
    // A bin holding 1/2000 of the samples is about two-thirds bright.
    u.gain = float(2000.0 / double(std::max<std::uint64_t>(1, im.samples)));

    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    blit.label = @"Framewright vectorscope clear";
    [blit fillBuffer:im.counts range:NSMakeRange(0, im.counts.length) value:0];
    [blit endEncoding];

    id<MTLComputeCommandEncoder> compute = [commandBuffer computeCommandEncoder];
    compute.label = @"Framewright vectorscope";
    [compute setComputePipelineState:im.accumulate];
    [compute setTexture:working atIndex:VETextureIndexWorking];
    [compute setBuffer:im.counts offset:0 atIndex:VEBufferIndexScopeCounts];
    [compute setBytes:&u length:sizeof u atIndex:VEBufferIndexScopeUniforms];
    if (stats != nullptr && stats->buffer != nil) {
        [compute setBuffer:stats->buffer offset:stats->offset atIndex:VEBufferIndexScopeStats];
    } else {
        [compute setBuffer:im.discardedStats offset:0 atIndex:VEBufferIndexScopeStats];
    }
    const NSUInteger tw = im.accumulate.threadExecutionWidth;
    const NSUInteger th = std::max<NSUInteger>(1, std::min<NSUInteger>(8, im.accumulate.maxTotalThreadsPerThreadgroup / tw));
    [compute dispatchThreads:MTLSizeMake(NSUInteger(r.width), rows, 1) threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
    [compute endEncoding];
    im.accumulated = true;
    return true;
}

bool Vectorscope::encodeDisplay(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> target) {
    Impl &im = *impl_;
    if (commandBuffer == nil || target == nil || !im.accumulated || target.device != im.device) {
        return false;
    }
    id<MTLRenderPipelineState> pipeline = im.displayPipeline(target.pixelFormat);
    if (pipeline == nil) {
        return false;
    }
    VEVectorscopeUniforms u = im.uniforms;
    u.target = simd_make_float4(float(target.width), float(target.height), 0.0f, 0.0f);
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare; // every pixel is written
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (encoder == nil) {
        return false;
    }
    encoder.label = @"Framewright vectorscope display";
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentBuffer:im.counts offset:0 atIndex:VEBufferIndexScopeCounts];
    [encoder setFragmentBytes:&u length:sizeof u atIndex:VEBufferIndexScopeUniforms];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    return true;
}

id<MTLDevice> Vectorscope::device() const {
    return impl_->device;
}

std::vector<std::uint32_t> Vectorscope::countsSnapshot() const {
    const auto *values = static_cast<const std::uint32_t *>(impl_->counts.contents);
    return std::vector<std::uint32_t>(values, values + std::size_t(kBins) * kBins);
}

std::uint64_t Vectorscope::samples() const {
    return impl_->samples;
}

} // namespace ve::render
