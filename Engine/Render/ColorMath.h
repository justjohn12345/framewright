// YCbCr <-> R'G'B' matrices for the compositor, built on the CPU in double precision and
// uploaded as uniforms. Everything here works on gamma-encoded values (no linearisation).
//
// Conventions (ITU-R BT.601/709/2020, non-constant luminance):
//   R'G'B' in [0,1];  Y' in [0,1];  Cb', Cr' in [-0.5, 0.5]
//   Video range, n bits: Y = 16*2^(n-8) + 219*2^(n-8) Y',  C = 128*2^(n-8) + 224*2^(n-8) C'
//   Full range,  n bits: Y = (2^n - 1) Y',                   C = 2^(n-1) + (2^n - 1) C'
// Texture sampling returns unorm values: code / 255 for 8-bit planes, and for 10-bit data
// stored in the high bits of 16-bit words ('x420' etc.) (code * 64) / 65535.

#pragma once

#include "../Media/MediaTypes.h"

#include <simd/simd.h>

namespace ve::render {

struct LumaCoefficients {
    double kr;
    double kb;
    double kg() const { return 1.0 - kr - kb; }
};

/// Kr/Kb for a matrix; Unknown maps to BT.709.
LumaCoefficients lumaCoefficients(media::YCbCrMatrix matrix);

/// How the integer codes of a YCbCr plane are stored in the sampled texture.
struct YCbCrEncoding {
    media::YCbCrMatrix matrix = media::YCbCrMatrix::BT709;
    int bitDepth = 8;            ///< 8 or 10
    bool fullRange = false;      ///< full vs video range
    bool msbPacked16 = false;    ///< codes in the high bits of 16-bit words (10-bit CoreVideo formats)
};

/// Column-major matrix M with (R', G', B', _) = M * (Ysample, Cbsample, Crsample, 1).
simd_float4x4 yCbCrToRGBMatrix(const YCbCrEncoding &encoding);

/// Rows mapping (R', G', B', 1) to the unorm sample values a plane stores for Y, Cb, Cr (the
/// inverse of yCbCrToRGBMatrix).
struct RGBToYCbCrRows {
    simd_float4 y;
    simd_float4 cb;
    simd_float4 cr;
};
/// For 8-bit planes (unorm = code / 255).
RGBToYCbCrRows rgbToYCbCr8Rows(media::YCbCrMatrix matrix, bool fullRange);
/// For `bitDepth` 8 (as above) or 10: 10-bit codes stored in the high bits of 16-bit words
/// ('x420', 'xf20'), unorm = (code * 64) / 65535.
RGBToYCbCrRows rgbToYCbCrRows(media::YCbCrMatrix matrix, bool fullRange, int bitDepth);

} // namespace ve::render
