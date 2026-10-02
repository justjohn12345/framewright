#include "LumaWaveform.h"

#include "ShaderTypes.h"

#include <algorithm>
#include <cstring>
#include <string>
#include <utility>

// The framework's bundle (the compositor loads its library the same way).
@interface VELumaWaveformBundleAnchor : NSObject
@end
@implementation VELumaWaveformBundleAnchor
@end

namespace ve::render {

using media::MediaErrorCode;

namespace {

media::MediaError waveformError(const std::string &what, NSError *error = nil) {
    std::string text = "LumaWaveform: " + what;
    if (error != nil) {
        text += ": ";
        text += error.localizedDescription.UTF8String ?: "";
    }
    return media::makeError(MediaErrorCode::Internal, text);
}

// The part of `r` inside a width x height texture.
PixelRect clippedTo(const PixelRect &r, std::int32_t width, std::int32_t height) {
    const std::int64_t x0 = std::max<std::int64_t>(0, r.x);
    const std::int64_t y0 = std::max<std::int64_t>(0, r.y);
    const std::int64_t x1 = std::min<std::int64_t>(width, std::int64_t(r.x) + r.width);
    const std::int64_t y1 = std::min<std::int64_t>(height, std::int64_t(r.y) + r.height);
    if (x1 <= x0 || y1 <= y0) {
        return PixelRect{};
    }
    return PixelRect{std::int32_t(x0), std::int32_t(y0), std::int32_t(x1 - x0), std::int32_t(y1 - y0)};
}

} // namespace

struct LumaWaveform::Impl {
    id<MTLDevice> device = nil;
    WaveformSettings settings;
    id<MTLComputePipelineState> accumulate = nil;
    id<MTLFunction> displayVertex = nil;
    id<MTLFunction> displayFragment = nil;
    std::vector<std::pair<MTLPixelFormat, id<MTLRenderPipelineState>>> displayPipelines;
    id<MTLBuffer> counts = nil;
    VEWaveformUniforms uniforms{};
    bool accumulated = false;
    std::uint64_t samplesPerColumn = 0;

    id<MTLRenderPipelineState> displayPipeline(MTLPixelFormat format) {
        for (const auto &entry : displayPipelines) {
            if (entry.first == format) {
                return entry.second;
            }
        }
        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.label = @"Framewright waveform";
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

media::Result<std::unique_ptr<LumaWaveform>> LumaWaveform::create(id<MTLDevice> device, WaveformSettings settings) {
    if (device == nil) {
        return waveformError("no Metal device");
    }
    constexpr std::uint32_t kMaxSetting = 4096;
    if (settings.columns == 0 || settings.levels < 2 || settings.maxSampleRows == 0 || settings.columns > kMaxSetting ||
        settings.levels > kMaxSetting || settings.maxSampleRows > kMaxSetting) {
        return media::makeError(MediaErrorCode::InvalidArgument,
                                "LumaWaveform: columns, levels (at least 2) and rows must be 1 to 4096");
    }
    auto impl = std::make_unique<Impl>();
    impl->device = device;
    impl->settings = settings;
    NSError *error = nil;
    id<MTLLibrary> library =
        [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:VELumaWaveformBundleAnchor.class] error:&error];
    if (library == nil) {
        return waveformError("cannot load the engine Metal library", error);
    }
    id<MTLFunction> accumulate = [library newFunctionWithName:@"ve_waveform_accumulate"];
    impl->displayVertex = [library newFunctionWithName:@"ve_output_vertex"];
    impl->displayFragment = [library newFunctionWithName:@"ve_waveform_fragment"];
    if (accumulate == nil || impl->displayVertex == nil || impl->displayFragment == nil) {
        return waveformError("shader functions missing from default.metallib");
    }
    impl->accumulate = [device newComputePipelineStateWithFunction:accumulate error:&error];
    if (impl->accumulate == nil) {
        return waveformError("accumulate pipeline", error);
    }
    const NSUInteger length = NSUInteger(settings.columns) * settings.levels * sizeof(std::uint32_t);
    impl->counts = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
    if (impl->counts == nil) {
        return waveformError("cannot allocate the counts");
    }
    impl->counts.label = @"Framewright waveform counts";
    std::memset(impl->counts.contents, 0, length);
    return std::unique_ptr<LumaWaveform>(new LumaWaveform(std::move(impl)));
}

LumaWaveform::LumaWaveform(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}

LumaWaveform::~LumaWaveform() = default;

bool LumaWaveform::encodeAccumulate(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> working, const PixelRect &frame) {
    Impl &im = *impl_;
    if (commandBuffer == nil || working == nil || working.device != im.device) {
        return false;
    }
    const PixelRect r = clippedTo(frame, std::int32_t(working.width), std::int32_t(working.height));
    if (r.isEmpty()) {
        return false;
    }
    const std::uint32_t rows = std::min<std::uint32_t>(im.settings.maxSampleRows, std::uint32_t(r.height));
    VEWaveformUniforms &u = im.uniforms;
    u.frame = simd_make_float4(float(r.x), float(r.y), float(r.width), float(r.height));
    u.columns = im.settings.columns;
    u.levels = im.settings.levels;
    u.sampleRows = rows;
    // Pixels per column: the frame's width over the columns, times the rows (the average; columns of a
    // width that does not divide evenly differ by at most one pixel column).
    im.samplesPerColumn = std::max<std::uint64_t>(1, std::uint64_t(r.width) * rows / im.settings.columns);
    u.gain = float(48.0 / double(im.samplesPerColumn));

    id<MTLBlitCommandEncoder> blit = [commandBuffer blitCommandEncoder];
    blit.label = @"Framewright waveform clear";
    [blit fillBuffer:im.counts range:NSMakeRange(0, im.counts.length) value:0];
    [blit endEncoding];

    id<MTLComputeCommandEncoder> compute = [commandBuffer computeCommandEncoder];
    compute.label = @"Framewright waveform";
    [compute setComputePipelineState:im.accumulate];
    [compute setTexture:working atIndex:VETextureIndexWorking];
    [compute setBuffer:im.counts offset:0 atIndex:VEBufferIndexWaveformCounts];
    [compute setBytes:&u length:sizeof u atIndex:VEBufferIndexWaveform];
    const NSUInteger tw = im.accumulate.threadExecutionWidth;
    const NSUInteger th = std::max<NSUInteger>(1, std::min<NSUInteger>(8, im.accumulate.maxTotalThreadsPerThreadgroup / tw));
    [compute dispatchThreads:MTLSizeMake(NSUInteger(r.width), rows, 1) threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
    [compute endEncoding];
    im.accumulated = true;
    return true;
}

bool LumaWaveform::encodeDisplay(id<MTLCommandBuffer> commandBuffer, id<MTLTexture> target) {
    Impl &im = *impl_;
    if (commandBuffer == nil || target == nil || !im.accumulated || target.device != im.device) {
        return false;
    }
    id<MTLRenderPipelineState> pipeline = im.displayPipeline(target.pixelFormat);
    if (pipeline == nil) {
        return false;
    }
    VEWaveformUniforms u = im.uniforms;
    u.target = simd_make_float4(float(target.width), float(target.height), 0.0f, 0.0f);
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare; // every pixel is written
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:pass];
    if (encoder == nil) {
        return false;
    }
    encoder.label = @"Framewright waveform display";
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentBuffer:im.counts offset:0 atIndex:VEBufferIndexWaveformCounts];
    [encoder setFragmentBytes:&u length:sizeof u atIndex:VEBufferIndexWaveform];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    return true;
}

id<MTLDevice> LumaWaveform::device() const {
    return impl_->device;
}

const WaveformSettings &LumaWaveform::settings() const {
    return impl_->settings;
}

std::vector<std::uint32_t> LumaWaveform::countsSnapshot() const {
    const auto *values = static_cast<const std::uint32_t *>(impl_->counts.contents);
    return std::vector<std::uint32_t>(values, values + impl_->counts.length / sizeof(std::uint32_t));
}

std::uint64_t LumaWaveform::samplesPerColumn() const {
    return impl_->samplesPerColumn;
}

std::uint32_t LumaWaveform::sampleRows() const {
    return impl_->uniforms.sampleRows;
}

} // namespace ve::render
