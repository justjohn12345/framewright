// VideoToolbox hardware capability probe. Runs once, on first use, and is cached for the
// lifetime of the process.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace ve::media {

enum class HWCodec { H264, HEVC, ProRes, AV1, VP9 };
const char *toString(HWCodec codec);

struct CodecCapabilities {
    HWCodec codec = HWCodec::H264;
    uint32_t codecType = 0;         ///< CoreMedia codec type probed ('avc1', 'hvc1', 'apcn', 'av01', 'vp09').
    bool hardwareDecode = false;    ///< VTIsHardwareDecodeSupported.
    bool hardwareEncode = false;    ///< A hardware-accelerated encoder is listed by VTCopyVideoEncoderList.
    bool softwareEncode = false;    ///< A software encoder is listed.
    std::vector<std::string> hardwareEncoderIDs; ///< kVTVideoEncoderList_EncoderID of the hardware encoders.
};

/// Plain snapshot of the machine's VideoToolbox capabilities.
///
/// Thread-safety: get() is thread-safe (the probe runs exactly once under std::call_once) and
/// the returned object is immutable.
struct HardwareCaps {
    CodecCapabilities h264;
    CodecCapabilities hevc;
    CodecCapabilities prores; ///< Probed with ProRes 422 ('apcn'); applies to every ProRes flavour.
    CodecCapabilities av1;    ///< Probed after VTRegisterSupplementalVideoDecoderIfAvailable('av01').
    CodecCapabilities vp9;    ///< Probed after VTRegisterSupplementalVideoDecoderIfAvailable('vp09').

    /// The cached probe result.
    static const HardwareCaps &get();
    /// Runs the probe now (uncached). Registers the AV1/VP9 supplemental decoders.
    static HardwareCaps probe();

    /// Capabilities for a CoreMedia codec type (aliases such as 'hev1' and every ProRes
    /// four-cc are mapped), or nullptr for codecs outside the probed set.
    const CodecCapabilities *forCodecType(uint32_t codecType) const;
    const CodecCapabilities &forCodec(HWCodec codec) const;
    bool hardwareDecode(uint32_t codecType) const;
    bool hardwareEncode(uint32_t codecType) const;

    /// Human-readable multi-line table, e.g. "h264    decode HW  encode HW (...)".
    std::string description() const;
};

} // namespace ve::media
