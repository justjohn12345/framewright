// Uniform layouts and binding indices shared by Shaders.metal and the Obj-C++ compositor.
//
// Every vector member is a 16-byte float4 (or a float4x4), so the C (simd) and Metal layouts
// agree without relying on packing rules; Compositor.mm static_asserts the sizes.

#pragma once

#ifdef __METAL_VERSION__
#include <metal_stdlib>
typedef metal::float4 VEFloat4;
typedef metal::float4x4 VEFloat4x4;
typedef metal::uint4 VEUInt4;
#else
#include <simd/simd.h>
typedef simd_float4 VEFloat4;
typedef simd_float4x4 VEFloat4x4;
typedef simd_uint4 VEUInt4;
#endif

// Buffer and texture binding indices.
enum VEBufferIndex {
    VEBufferIndexDraw = 0,    // VEDrawUniforms (vertex and fragment)
    VEBufferIndexConvert = 0, // VEConvertUniforms (compute)
};

enum VETextureIndex {
    VETextureIndexA0 = 0, // source A: luma (YCbCr) or the RGBA texture
    VETextureIndexA1 = 1, // source A: interleaved CbCr (YCbCr only)
    VETextureIndexB0 = 2, // partner source B (dissolve), same layout as A
    VETextureIndexB1 = 3,
    // Compute conversion.
    VETextureIndexComposite = 0, // RGBA16Float intermediate (read)
    VETextureIndexOut0 = 1,      // BGRA, or luma of a biplanar target (write)
    VETextureIndexOut1 = 2,      // CbCr of a biplanar target (write)
};

// Function constants that specialise the fragment function (one pipeline per combination).
enum VEFunctionConstant {
    VEFunctionConstantSourceAIsYCbCr = 0,
    VEFunctionConstantHasPartner = 1,
    VEFunctionConstantSourceBIsYCbCr = 2,
};

// How one source picture is sampled and placed.
struct VESourceUniforms {
    // Maps the sampled (Y, Cb, Cr, 1) plane values (texture unorm, i.e. before range expansion)
    // to gamma-encoded R'G'B'. Folds bit depth, video/full range and the YCbCr matrix.
    // Unused for RGBA sources.
    VEFloat4x4 colorMatrix;
    // Inverse placement: source uv = (dot(uvFromFrameX.xyz, (px, py, 1)), dot(uvFromFrameY.xyz, ...))
    // where (px, py) is a position in sequence pixels (origin top left, +y down).
    VEFloat4 uvFromFrameX;
    VEFloat4 uvFromFrameY;
    // x: weight (opacity; times the transition weight when drawn without its partner).
    // y, z, w: unused.
    VEFloat4 params;
};

// One draw: an axis-aligned quad in sequence pixels covering the layer (or the pair).
struct VEDrawUniforms {
    VEFloat4 quadRect;  // x0, y0, x1, y1 in sequence pixels
    VEFloat4 frameSize; // sequence width, height, 1/width, 1/height
    VEFloat4 mix;       // x: dissolve mix toward source B (pair draws only)
    VEFloat4 reserved;
    struct VESourceUniforms a;
    struct VESourceUniforms b;
};

// RGB -> output conversion for the export compute pass.
struct VEConvertUniforms {
    // Rows mapping (R', G', B', 1) to the unorm plane values Y, Cb, Cr (biplanar targets only).
    VEFloat4 yRow;
    VEFloat4 cbRow;
    VEFloat4 crRow;
    VEUInt4 size; // x, y: output luma size in pixels
};
