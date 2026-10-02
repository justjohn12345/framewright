#include "Histogram.h"

#include <algorithm>
#include <cstring>
#include <string>
#include <utility>

// The framework's bundle (the compositor loads its library the same way).
@interface VEHistogramBundleAnchor : NSObject
@end
@implementation VEHistogramBundleAnchor
@end

namespace ve::render {

using media::MediaErrorCode;

namespace {

media::MediaError histogramError(const std::string &what, NSError *error = nil) {
    std::string text = "Histogram: " + what;
    if (error != nil) {
        text += ": ";
        text += error.localizedDescription.UTF8String ?: "";
    }
    return media::makeError(MediaErrorCode::Internal, text);
}

} // namespace

struct Histogram::Impl {
    id<MTLDevice> device = nil;
    id<MTLComputePipelineState> accumulate = nil;
    id<MTLComputePipelineState> finish = nil;
    id<MTLFunction> displayVertex = nil;
    id<MTLFunction> displayFragment = nil;
    std::vector<std::pair<MTLPixelFormat, id<MTLRenderPipelineState>>> displayPipelines;
    id<MTLBuffer> counts = nil;
    // Bound as the clipping counters when the caller gives none (written, never read).
    id<MTLBuffer> discardedStats = nil;
    VEHistogramUniforms uniforms{};
    bool accumulated = false;
    std::uint64_t samples = 0;
    PixelRect frame;

    id<MTLRenderPipelineState> displayPipeline(MTLPixelFormat format) {
        for (const auto &entry : displayPipelines) {
            if (entry.first == format) {
                return entry.second;
            }
        }
        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.label = @"Framewright histogram";
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

media::Result<std::unique_ptr<Histogram>> Histogram::create(id<MTLDevice> device) {
    if (device == nil) {
        return histogramError("no Metal device");
    }
    auto impl = std::make_unique<Impl>();
    impl->device = device;
    NSError *error = nil;
    id<MTLLibrary> library =
        [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:VEHistogramBundleAnchor.class] error:&error];
    if (library == nil) {
        return histogramError("cannot load the engine Metal library", error);
    }
    id<MTLFunction> accumulate = [library newFunctionWithName:@"ve_histogram_accumulate"];
    id<MTLFunction> finish = [library newFunctionWithName:@"ve_histogram_finish"];
    impl->displayVertex = [library newFunctionWithName:@"ve_output_vertex"];
    impl->displayFragment = [library newFunctionWithName:@"ve_histogram_fragment"];
    if (accumulate == nil || finish == nil || impl->displayVertex == nil || impl->displayFragment == nil) {
        return histogramError("shader functions missing from default.metallib");
    }
    impl->accumulate = [device newComputePipelineStateWithFunction:accumulate error:&error];
    if (impl->accumulate == nil) {
        return histogramError("accumulate pipeline", error);
    }
    constexpr NSUInteger kGroupThreads = kVEHistogramGroupSide * kVEHistogramGroupSide;
    if (impl->accumulate.maxTotalThreadsPerThreadgroup < kGroupThreads) {
        return histogramError("the accumulate kernel cannot run " + std::to_string(kGroupThreads) +
                              " threads per threadgroup on this device");
    }
    impl->finish = [device newComputePipelineStateWithFunction:finish error:&error];
    if (impl->finish == nil || impl->finish.maxTotalThreadsPerThreadgroup < kVEHistogramBins) {
        return histogramError("finish pipeline", error);
    }
    const NSUInteger length = NSUInteger(kVEHistogramCountsLength) * sizeof(std::uint32_t);
    impl->counts = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
    impl->discardedStats = [device newBufferWithLength:ScopeStatsRing::kSlotStride options:MTLResourceStorageModePrivate];
    if (impl->counts == nil || impl->discardedStats == nil) {
        return histogramError("cannot allocate the counts");
    }
    impl->counts.label = @"Framewright histogram counts";
    impl->discardedStats.label = @"Framewright histogram discarded clipping counters";
    std::memset(impl->counts.contents, 0, length);
    return std::unique_ptr<Histogram>(new Histogram(std::move(impl)));
}

Histogram::Histogram(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}

Histogram::~Histogram() = default;

bool Histogram::encodeAccumulate(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> working, const PixelRect &frame,
                                 const ScopeStatsSlot *stats) {
    Impl &im = *impl_;
    if (commandBuffer == nil || working == nil || working.device != im.device) {
        return false;
    }
    const PixelRect r = clipToTexture(frame, std::int32_t(working.width), std::int32_t(working.height));
    if (r.isEmpty()) {
        return false;
    }
    VEHistogramUniforms &u = im.uniforms;
    u.frame = simd_make_float4(float(r.x), float(r.y), float(r.width), float(r.height));
    im.samples = std::uint64_t(r.width) * std::uint64_t(r.height);
    im.frame = r;

    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    blit.label = @"Framewright histogram clear";
    [blit fillBuffer:im.counts range:NSMakeRange(0, im.counts.length) value:0];
    [blit endEncoding];

    id<MTLComputeCommandEncoder> compute = [commandBuffer computeCommandEncoder];
    compute.label = @"Framewright histogram";
    [compute setComputePipelineState:im.accumulate];
    [compute setTexture:working atIndex:VETextureIndexWorking];
    [compute setBuffer:im.counts offset:0 atIndex:VEBufferIndexScopeCounts];
    [compute setBytes:&u length:sizeof u atIndex:VEBufferIndexScopeUniforms];
    if (stats != nullptr && stats->buffer != nil) {
        [compute setBuffer:stats->buffer offset:stats->offset atIndex:VEBufferIndexScopeStats];
    } else {
        [compute setBuffer:im.discardedStats offset:0 atIndex:VEBufferIndexScopeStats];
    }
    const NSUInteger tile = kVEHistogramTileSide;
    [compute dispatchThreadgroups:MTLSizeMake((NSUInteger(r.width) + tile - 1) / tile,
                                              (NSUInteger(r.height) + tile - 1) / tile, 1)
            threadsPerThreadgroup:MTLSizeMake(kVEHistogramGroupSide, kVEHistogramGroupSide, 1)];
    // The finish kernel reads what every group added: a serial compute encoder (the default) runs its
    // dispatches one after the other, each seeing the previous one's writes.
    [compute setComputePipelineState:im.finish];
    [compute dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(kVEHistogramBins, 1, 1)];
    [compute endEncoding];
    im.accumulated = true;
    return true;
}

bool Histogram::encodeDisplay(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> target, HistogramStyle style) {
    Impl &im = *impl_;
    if (commandBuffer == nil || target == nil || !im.accumulated || target.device != im.device) {
        return false;
    }
    id<MTLRenderPipelineState> pipeline = im.displayPipeline(target.pixelFormat);
    if (pipeline == nil) {
        return false;
    }
    VEHistogramUniforms u = im.uniforms;
    u.target = simd_make_float4(float(target.width), float(target.height), 0.0f, 0.0f);
    u.style = static_cast<VEUInt>(style);
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare; // every pixel is written
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (encoder == nil) {
        return false;
    }
    encoder.label = @"Framewright histogram display";
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentBuffer:im.counts offset:0 atIndex:VEBufferIndexScopeCounts];
    [encoder setFragmentBytes:&u length:sizeof u atIndex:VEBufferIndexScopeUniforms];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    return true;
}

id<MTLDevice> Histogram::device() const {
    return impl_->device;
}

std::array<std::uint32_t, Histogram::kBins> Histogram::counts(HistogramChannel channel) const {
    std::array<std::uint32_t, kBins> out{};
    const auto *values = static_cast<const std::uint32_t *>(impl_->counts.contents);
    const auto row = static_cast<std::size_t>(channel);
    if (row < kVEHistogramChannels) {
        std::memcpy(out.data(), values + row * kBins, sizeof(std::uint32_t) * kBins);
    }
    return out;
}

std::array<std::uint32_t, 4> Histogram::maxima() const {
    std::array<std::uint32_t, 4> out{};
    const auto *values = static_cast<const std::uint32_t *>(impl_->counts.contents);
    std::memcpy(out.data(), values + kVEHistogramMaximaOffset, sizeof(std::uint32_t) * 4);
    return out;
}

std::uint64_t Histogram::samples() const {
    return impl_->samples;
}

PixelRect Histogram::countedFrame() const {
    return impl_->frame;
}

} // namespace ve::render
