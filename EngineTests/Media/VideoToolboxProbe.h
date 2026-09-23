// Independent answers from VideoToolbox itself, for tests that check the media layer's hardware
// reporting against the platform rather than against HardwareCaps (which the code under test
// also uses, so comparing with it would be circular).
#pragma once

#include <CoreMedia/CoreMedia.h>

#include <optional>
#include <string>

namespace ve::test {

/// Loads the first video track of an ISO-BMFF/QuickTime file with AVFoundation, creates a
/// VTDecompressionSession for its format description with hardware enabled and returns
/// kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder. nullopt if the file has no
/// video track or VideoToolbox refuses the format.
std::optional<bool> videoToolboxDecodesInHardware(const std::string &path);

/// Whether VideoToolbox can create a compression session for `codec` at width x height with the
/// hardware encoder REQUIRED.
bool videoToolboxEncodesInHardware(CMVideoCodecType codec, int width, int height);

} // namespace ve::test
