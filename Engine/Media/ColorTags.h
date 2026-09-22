// Conversions between ColorInfo and the CoreVideo attachment strings
// (kCVImageBufferColorPrimaries_*, ...), shared by both backends: FFmpeg frames wrapped in
// CVPixelBuffers get tagged the same way as VideoToolbox output.
#pragma once

#include "MediaTypes.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>

namespace ve::media {

ColorPrimaries colorPrimariesFromCV(CFStringRef value);
TransferFunction transferFunctionFromCV(CFStringRef value);
YCbCrMatrix yCbCrMatrixFromCV(CFStringRef value);
/// Returns nullptr for Unknown. The strings are CoreVideo constants (not owned).
CFStringRef cvString(ColorPrimaries value);
CFStringRef cvString(TransferFunction value);
CFStringRef cvString(YCbCrMatrix value);

/// Reads colour tags from CoreVideo-style extension/attachment dictionary values (a
/// CMFormatDescription's extensions or a CVBuffer's attachments). fullRange is not set here.
ColorInfo colorInfoFromAttachments(CFDictionaryRef attachments);

/// Sets primaries/transfer/matrix attachments (propagated) on `buffer`; Unknown values are
/// left untouched.
void attachColorInfo(CVBufferRef buffer, const ColorInfo &color);

/// True for the full-range YCbCr pixel formats ('420f', 'xf20', 'xf22', 'xf44', ...).
bool isFullRangeYCbCr(OSType pixelFormat);
bool isYCbCrBiPlanar(OSType pixelFormat);

} // namespace ve::media
