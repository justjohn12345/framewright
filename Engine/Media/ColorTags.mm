#include "ColorTags.h"

namespace ve::media {

namespace {
bool eq(CFStringRef a, CFStringRef b) {
    return a != nullptr && b != nullptr && CFStringCompare(a, b, 0) == kCFCompareEqualTo;
}
CFStringRef stringValue(CFDictionaryRef dict, CFStringRef key) {
    if (dict == nullptr) {
        return nullptr;
    }
    CFTypeRef v = CFDictionaryGetValue(dict, key);
    return (v != nullptr && CFGetTypeID(v) == CFStringGetTypeID()) ? static_cast<CFStringRef>(v) : nullptr;
}
} // namespace

ColorPrimaries colorPrimariesFromCV(CFStringRef v) {
    if (eq(v, kCVImageBufferColorPrimaries_ITU_R_709_2)) {
        return ColorPrimaries::BT709;
    }
    if (eq(v, kCVImageBufferColorPrimaries_SMPTE_C)) {
        return ColorPrimaries::BT601_525;
    }
    if (eq(v, kCVImageBufferColorPrimaries_EBU_3213)) {
        return ColorPrimaries::BT601_625;
    }
    if (eq(v, kCVImageBufferColorPrimaries_ITU_R_2020)) {
        return ColorPrimaries::BT2020;
    }
    if (eq(v, kCVImageBufferColorPrimaries_P3_D65)) {
        return ColorPrimaries::P3_D65;
    }
    if (eq(v, kCVImageBufferColorPrimaries_DCI_P3)) {
        return ColorPrimaries::DCI_P3;
    }
    return ColorPrimaries::Unknown;
}

TransferFunction transferFunctionFromCV(CFStringRef v) {
    if (eq(v, kCVImageBufferTransferFunction_ITU_R_709_2) || eq(v, kCVImageBufferTransferFunction_ITU_R_2020)) {
        return TransferFunction::BT709; // BT.2020 SDR uses the BT.709 curve.
    }
    if (eq(v, kCVImageBufferTransferFunction_sRGB)) {
        return TransferFunction::SRGB;
    }
    if (eq(v, kCVImageBufferTransferFunction_Linear)) {
        return TransferFunction::Linear;
    }
    if (eq(v, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)) {
        return TransferFunction::PQ;
    }
    if (eq(v, kCVImageBufferTransferFunction_ITU_R_2100_HLG)) {
        return TransferFunction::HLG;
    }
    if (eq(v, kCVImageBufferTransferFunction_SMPTE_240M_1995)) {
        return TransferFunction::SMPTE240M;
    }
    return TransferFunction::Unknown;
}

YCbCrMatrix yCbCrMatrixFromCV(CFStringRef v) {
    if (eq(v, kCVImageBufferYCbCrMatrix_ITU_R_709_2)) {
        return YCbCrMatrix::BT709;
    }
    if (eq(v, kCVImageBufferYCbCrMatrix_ITU_R_601_4)) {
        return YCbCrMatrix::BT601;
    }
    if (eq(v, kCVImageBufferYCbCrMatrix_ITU_R_2020)) {
        return YCbCrMatrix::BT2020;
    }
    if (eq(v, kCVImageBufferYCbCrMatrix_SMPTE_240M_1995)) {
        return YCbCrMatrix::SMPTE240M;
    }
    return YCbCrMatrix::Unknown;
}

CFStringRef cvString(ColorPrimaries v) {
    switch (v) {
    case ColorPrimaries::BT709:
        return kCVImageBufferColorPrimaries_ITU_R_709_2;
    case ColorPrimaries::BT601_525:
        return kCVImageBufferColorPrimaries_SMPTE_C;
    case ColorPrimaries::BT601_625:
        return kCVImageBufferColorPrimaries_EBU_3213;
    case ColorPrimaries::BT2020:
        return kCVImageBufferColorPrimaries_ITU_R_2020;
    case ColorPrimaries::P3_D65:
        return kCVImageBufferColorPrimaries_P3_D65;
    case ColorPrimaries::DCI_P3:
        return kCVImageBufferColorPrimaries_DCI_P3;
    case ColorPrimaries::Unknown:
        break;
    }
    return nullptr;
}

CFStringRef cvString(TransferFunction v) {
    switch (v) {
    case TransferFunction::BT709:
        return kCVImageBufferTransferFunction_ITU_R_709_2;
    case TransferFunction::SRGB:
        return kCVImageBufferTransferFunction_sRGB;
    case TransferFunction::Linear:
        return kCVImageBufferTransferFunction_Linear;
    case TransferFunction::PQ:
        return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ;
    case TransferFunction::HLG:
        return kCVImageBufferTransferFunction_ITU_R_2100_HLG;
    case TransferFunction::SMPTE240M:
        return kCVImageBufferTransferFunction_SMPTE_240M_1995;
    case TransferFunction::Unknown:
        break;
    }
    return nullptr;
}

CFStringRef cvString(YCbCrMatrix v) {
    switch (v) {
    case YCbCrMatrix::BT709:
        return kCVImageBufferYCbCrMatrix_ITU_R_709_2;
    case YCbCrMatrix::BT601:
        return kCVImageBufferYCbCrMatrix_ITU_R_601_4;
    case YCbCrMatrix::BT2020:
        return kCVImageBufferYCbCrMatrix_ITU_R_2020;
    case YCbCrMatrix::SMPTE240M:
        return kCVImageBufferYCbCrMatrix_SMPTE_240M_1995;
    case YCbCrMatrix::Unknown:
        break;
    }
    return nullptr;
}

ColorInfo colorInfoFromAttachments(CFDictionaryRef dict) {
    ColorInfo c;
    c.primaries = colorPrimariesFromCV(stringValue(dict, kCVImageBufferColorPrimariesKey));
    c.transfer = transferFunctionFromCV(stringValue(dict, kCVImageBufferTransferFunctionKey));
    c.matrix = yCbCrMatrixFromCV(stringValue(dict, kCVImageBufferYCbCrMatrixKey));
    return c;
}

void attachColorInfo(CVBufferRef buffer, const ColorInfo &color) {
    if (buffer == nullptr) {
        return;
    }
    if (CFStringRef s = cvString(color.primaries)) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, s, kCVAttachmentMode_ShouldPropagate);
    }
    if (CFStringRef s = cvString(color.transfer)) {
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, s, kCVAttachmentMode_ShouldPropagate);
    }
    if (CFStringRef s = cvString(color.matrix)) {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, s, kCVAttachmentMode_ShouldPropagate);
    }
}

bool isFullRangeYCbCr(OSType f) {
    switch (f) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_420YpCbCr8PlanarFullRange:
        return true;
    default:
        return false;
    }
}

bool isYCbCrBiPlanar(OSType f) {
    switch (f) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
        return true;
    default:
        return false;
    }
}

} // namespace ve::media
