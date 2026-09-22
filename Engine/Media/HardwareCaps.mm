#include "HardwareCaps.h"

#include "CFRef.h"
#include "MediaTypes.h"

#include <VideoToolbox/VideoToolbox.h>

#include <mutex>
#include <sstream>

namespace ve::media {

const char *toString(HWCodec codec) {
    switch (codec) {
    case HWCodec::H264:
        return "h264";
    case HWCodec::HEVC:
        return "hevc";
    case HWCodec::ProRes:
        return "prores";
    case HWCodec::AV1:
        return "av1";
    case HWCodec::VP9:
        return "vp9";
    }
    return "unknown";
}

namespace {

std::string cfString(CFTypeRef value) {
    if (value == nullptr || CFGetTypeID(value) != CFStringGetTypeID()) {
        return {};
    }
    CFStringRef s = static_cast<CFStringRef>(value);
    if (const char *fast = CFStringGetCStringPtr(s, kCFStringEncodingUTF8)) {
        return fast;
    }
    const CFIndex max = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), kCFStringEncodingUTF8) + 1;
    std::string out(static_cast<size_t>(max), '\0');
    if (!CFStringGetCString(s, out.data(), max, kCFStringEncodingUTF8)) {
        return {};
    }
    out.resize(strlen(out.c_str()));
    return out;
}

void probeEncoders(HardwareCaps &caps) {
    CFArrayRef rawList = nullptr;
    if (VTCopyVideoEncoderList(nullptr, &rawList) != noErr || rawList == nullptr) {
        return;
    }
    CFRef<CFArrayRef> list = CFRef<CFArrayRef>::adopt(rawList);
    const CFIndex count = CFArrayGetCount(list.get());
    for (CFIndex i = 0; i < count; ++i) {
        CFTypeRef item = CFArrayGetValueAtIndex(list.get(), i);
        if (item == nullptr || CFGetTypeID(item) != CFDictionaryGetTypeID()) {
            continue;
        }
        CFDictionaryRef entry = static_cast<CFDictionaryRef>(item);
        CFTypeRef typeValue = CFDictionaryGetValue(entry, kVTVideoEncoderList_CodecType);
        uint32_t codecType = 0;
        if (typeValue == nullptr || CFGetTypeID(typeValue) != CFNumberGetTypeID() ||
            !CFNumberGetValue(static_cast<CFNumberRef>(typeValue), kCFNumberSInt32Type, &codecType)) {
            continue;
        }
        // Absent key means software.
        CFTypeRef hwValue = CFDictionaryGetValue(entry, kVTVideoEncoderList_IsHardwareAccelerated);
        const bool hardware = hwValue != nullptr && CFGetTypeID(hwValue) == CFBooleanGetTypeID() &&
                              CFBooleanGetValue(static_cast<CFBooleanRef>(hwValue));
        CodecCapabilities *target = nullptr;
        const uint32_t canonical = canonicalCodec(codecType);
        if (canonical == fourcc::H264) {
            target = &caps.h264;
        } else if (canonical == fourcc::HEVC) {
            target = &caps.hevc;
        } else if (codecType == fourcc::ProRes422) {
            target = &caps.prores;
        } else if (codecType == fourcc::AV1) {
            target = &caps.av1;
        } else if (codecType == fourcc::VP9) {
            target = &caps.vp9;
        }
        if (target == nullptr) {
            continue;
        }
        if (hardware) {
            target->hardwareEncode = true;
            target->hardwareEncoderIDs.push_back(cfString(CFDictionaryGetValue(entry, kVTVideoEncoderList_EncoderID)));
        } else {
            target->softwareEncode = true;
        }
    }
}

} // namespace

HardwareCaps HardwareCaps::probe() {
    HardwareCaps caps;
    caps.h264.codec = HWCodec::H264;
    caps.h264.codecType = fourcc::H264;
    caps.hevc.codec = HWCodec::HEVC;
    caps.hevc.codecType = fourcc::HEVC;
    caps.prores.codec = HWCodec::ProRes;
    caps.prores.codecType = fourcc::ProRes422;
    caps.av1.codec = HWCodec::AV1;
    caps.av1.codecType = fourcc::AV1;
    caps.vp9.codec = HWCodec::VP9;
    caps.vp9.codecType = fourcc::VP9;

    // AV1 and VP9 decoders are "supplemental": VT only knows about them after registration.
    // Registering is idempotent and harmless when the hardware lacks the decoder.
    VTRegisterSupplementalVideoDecoderIfAvailable(fourcc::AV1);
    VTRegisterSupplementalVideoDecoderIfAvailable(fourcc::VP9);

    for (CodecCapabilities *c : {&caps.h264, &caps.hevc, &caps.prores, &caps.av1, &caps.vp9}) {
        c->hardwareDecode = VTIsHardwareDecodeSupported(c->codecType);
    }
    probeEncoders(caps);
    return caps;
}

const HardwareCaps &HardwareCaps::get() {
    static std::once_flag once;
    static HardwareCaps *caps = nullptr; // Intentionally leaked: immutable process-wide singleton.
    std::call_once(once, [] { caps = new HardwareCaps(probe()); });
    return *caps;
}

const CodecCapabilities &HardwareCaps::forCodec(HWCodec codec) const {
    switch (codec) {
    case HWCodec::H264:
        return h264;
    case HWCodec::HEVC:
        return hevc;
    case HWCodec::ProRes:
        return prores;
    case HWCodec::AV1:
        return av1;
    case HWCodec::VP9:
        return vp9;
    }
    return h264;
}

const CodecCapabilities *HardwareCaps::forCodecType(uint32_t codecType) const {
    const uint32_t c = canonicalCodec(codecType);
    if (c == fourcc::H264) {
        return &h264;
    }
    if (c == fourcc::HEVC) {
        return &hevc;
    }
    if (isProRes(c)) {
        return &prores;
    }
    if (c == fourcc::AV1) {
        return &av1;
    }
    if (c == fourcc::VP9) {
        return &vp9;
    }
    return nullptr;
}

bool HardwareCaps::hardwareDecode(uint32_t codecType) const {
    const CodecCapabilities *c = forCodecType(codecType);
    return c != nullptr && c->hardwareDecode;
}

bool HardwareCaps::hardwareEncode(uint32_t codecType) const {
    const CodecCapabilities *c = forCodecType(codecType);
    return c != nullptr && c->hardwareEncode;
}

std::string HardwareCaps::description() const {
    std::ostringstream s;
    for (const CodecCapabilities *c : {&h264, &hevc, &prores, &av1, &vp9}) {
        s << toString(c->codec) << " (" << fourCCToString(c->codecType) << "): decode "
          << (c->hardwareDecode ? "HW" : "SW") << ", encode "
          << (c->hardwareEncode ? "HW" : (c->softwareEncode ? "SW" : "none"));
        if (!c->hardwareEncoderIDs.empty()) {
            s << " [";
            for (size_t i = 0; i < c->hardwareEncoderIDs.size(); ++i) {
                s << (i ? ", " : "") << c->hardwareEncoderIDs[i];
            }
            s << "]";
        }
        s << "\n";
    }
    return s.str();
}

} // namespace ve::media
