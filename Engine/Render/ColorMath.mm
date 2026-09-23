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
    return rgbToYCbCrRows(matrix, fullRange, 8);
}

RGBToYCbCrRows rgbToYCbCrRows(media::YCbCrMatrix matrix, bool fullRange, int bitDepth) {
    const LumaCoefficients k = lumaCoefficients(matrix);
    const double kg = k.kg();
    const bool ten = bitDepth >= 10;
    const double maxCode = ten ? 1023.0 : 255.0;
    const double step = ten ? 4.0 : 1.0; // 2^(n-8)
    // Integer code -> stored unorm value.
    const double unit = ten ? 64.0 / 65535.0 : 1.0 / 255.0;
    const double ySpan = (fullRange ? maxCode : 219.0 * step) * unit;
    const double yBase = (fullRange ? 0.0 : 16.0 * step) * unit;
    const double cSpan = (fullRange ? maxCode : 224.0 * step) * unit;
    const double cBase = 128.0 * step * unit;
    const double cb = 1.0 / (2.0 * (1.0 - k.kb));
    const double cr = 1.0 / (2.0 * (1.0 - k.kr));
    RGBToYCbCrRows rows;
    rows.y = simd_make_float4(float(ySpan * k.kr), float(ySpan * kg), float(ySpan * k.kb), float(yBase));
    rows.cb = simd_make_float4(float(-cSpan * cb * k.kr), float(-cSpan * cb * kg), float(cSpan * cb * (1.0 - k.kb)),
                               float(cBase));
    rows.cr = simd_make_float4(float(cSpan * cr * (1.0 - k.kr)), float(-cSpan * cr * kg), float(-cSpan * cr * k.kb),
                               float(cBase));
    return rows;
}

} // namespace ve::render
