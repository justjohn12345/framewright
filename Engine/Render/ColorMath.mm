#include "ColorMath.h"

namespace ve::render {

LumaCoefficients lumaCoefficients(media::YCbCrMatrix matrix) {
    switch (matrix) {
    case media::YCbCrMatrix::BT601:
        return {0.299, 0.114};
    case media::YCbCrMatrix::BT2020:
        return {0.2627, 0.0593};
    case media::YCbCrMatrix::SMPTE240M:
        return {0.212, 0.087};
    case media::YCbCrMatrix::BT709:
    case media::YCbCrMatrix::Unknown:
        break;
    }
    return {0.2126, 0.0722};
}

simd_float4x4 yCbCrToRGBMatrix(const YCbCrEncoding &e) {
    const double maxCode = e.bitDepth >= 10 ? 1023.0 : 255.0;
    const double step = e.bitDepth >= 10 ? 4.0 : 1.0; // 2^(n-8)
    // sample -> integer code
    const double toCode = e.msbPacked16 ? 65535.0 / 64.0 : maxCode;

    // Y' = yScale * sample + yOffset, C' = cScale * sample + cOffset
    double yScale, yOffset, cScale, cOffset;
    if (e.fullRange) {
        yScale = toCode / maxCode;
        yOffset = 0.0;
        cScale = toCode / maxCode;
        cOffset = -(128.0 * step) / maxCode;
    } else {
        yScale = toCode / (219.0 * step);
        yOffset = -16.0 / 219.0;
        cScale = toCode / (224.0 * step);
        cOffset = -128.0 / 224.0;
    }

    const LumaCoefficients k = lumaCoefficients(e.matrix);
    const double kg = k.kg();
    // R' = Y' + rCr Cr';  G' = Y' + gCb Cb' + gCr Cr';  B' = Y' + bCb Cb'
    const double rCr = 2.0 * (1.0 - k.kr);
    const double bCb = 2.0 * (1.0 - k.kb);
    const double gCb = -bCb * k.kb / kg;
    const double gCr = -rCr * k.kr / kg;

    // Columns: coefficient of Ysample, Cbsample, Crsample, and the constant term.
    const simd_float4 colY = simd_make_float4(float(yScale), float(yScale), float(yScale), 0.0f);
    const simd_float4 colCb = simd_make_float4(0.0f, float(gCb * cScale), float(bCb * cScale), 0.0f);
    const simd_float4 colCr = simd_make_float4(float(rCr * cScale), float(gCr * cScale), 0.0f, 0.0f);
    const double r0 = yOffset + rCr * cOffset;
    const double g0 = yOffset + (gCb + gCr) * cOffset;
    const double b0 = yOffset + bCb * cOffset;
    const simd_float4 colConst = simd_make_float4(float(r0), float(g0), float(b0), 1.0f);
    return simd_matrix(colY, colCb, colCr, colConst);
}

RGBToYCbCrRows rgbToYCbCr8Rows(media::YCbCrMatrix matrix, bool fullRange) {
    const LumaCoefficients k = lumaCoefficients(matrix);
    const double kg = k.kg();
    const double ySpan = fullRange ? 255.0 : 219.0;
    const double yBase = fullRange ? 0.0 : 16.0;
    const double cSpan = fullRange ? 255.0 : 224.0;
    const double cb = 1.0 / (2.0 * (1.0 - k.kb));
    const double cr = 1.0 / (2.0 * (1.0 - k.kr));
    const double ys = ySpan / 255.0;
    const double cs = cSpan / 255.0;
    RGBToYCbCrRows rows;
    rows.y = simd_make_float4(float(ys * k.kr), float(ys * kg), float(ys * k.kb), float(yBase / 255.0));
    rows.cb = simd_make_float4(float(-cs * cb * k.kr), float(-cs * cb * kg), float(cs * cb * (1.0 - k.kb)),
                               float(128.0 / 255.0));
    rows.cr = simd_make_float4(float(cs * cr * (1.0 - k.kr)), float(-cs * cr * kg), float(-cs * cr * k.kb),
                               float(128.0 / 255.0));
    return rows;
}

} // namespace ve::render
