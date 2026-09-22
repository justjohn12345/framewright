// Engine Metal shaders. Compiled into VidEditEngine.framework/Resources/default.metallib;
// load with [device newDefaultLibraryWithBundle:[NSBundle bundleForClass:VEEngine.class] error:].

#include <metal_stdlib>
using namespace metal;

struct VEPassthroughVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Full-screen triangle generated from the vertex id; draw with 3 vertices and no vertex buffer.
vertex VEPassthroughVertexOut ve_passthrough_vertex(uint vertexID [[vertex_id]]) {
    const float2 uv = float2((vertexID << 1) & 2, vertexID & 2);
    VEPassthroughVertexOut out;
    out.position = float4(uv * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.texCoord = uv;
    return out;
}

// Samples the bound texture unchanged.
fragment float4 ve_passthrough_fragment(VEPassthroughVertexOut in [[stage_in]],
                                        texture2d<float> source [[texture(0)]]) {
    constexpr sampler linearSampler(address::clamp_to_edge, filter::linear);
    return source.sample(linearSampler, in.texCoord);
}
