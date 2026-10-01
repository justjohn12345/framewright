#include "ContainerRules.h"

namespace ve::media {

Status checkContainerHoldsVideo(ContainerFormat container, VideoCodec codec) {
    if (container == ContainerFormat::WAV || container == ContainerFormat::M4A) {
        return makeError(MediaErrorCode::InvalidArgument, "container cannot hold video");
    }
    if (container == ContainerFormat::MP4 && codec == VideoCodec::ProRes422) {
        return makeError(MediaErrorCode::UnsupportedCodec, "ProRes requires a QuickTime (.mov) container");
    }
    if (codec == VideoCodec::AV1 && container != ContainerFormat::MP4 && container != ContainerFormat::MKV) {
        return makeError(MediaErrorCode::UnsupportedCodec, "AV1 is written to MP4 or Matroska (.mkv) only");
    }
    return okStatus();
}

Status checkContainerHoldsAudio(ContainerFormat container, AudioCodec codec) {
    if (container == ContainerFormat::WAV && codec != AudioCodec::LinearPCM) {
        return makeError(MediaErrorCode::UnsupportedCodec, "WAV holds linear PCM only");
    }
    if ((container == ContainerFormat::MP4 || container == ContainerFormat::M4A) && codec == AudioCodec::LinearPCM) {
        return makeError(MediaErrorCode::UnsupportedCodec, "linear PCM requires .mov, .wav or .mkv");
    }
    return okStatus();
}

Status checkContainerHolds(const EncodeSettings &s) {
    if (s.video) {
        VE_MEDIA_TRY(checkContainerHoldsVideo(s.container, s.video->codec));
    }
    if (s.audio) {
        VE_MEDIA_TRY(checkContainerHoldsAudio(s.container, s.audio->codec));
    }
    return okStatus();
}

std::optional<VideoCodec> videoCodecForFourCC(uint32_t fourCC) {
    const uint32_t c = canonicalCodec(fourCC);
    if (c == fourcc::H264) {
        return VideoCodec::H264;
    }
    if (c == fourcc::HEVC) {
        return VideoCodec::HEVC;
    }
    if (isProRes(c)) {
        return VideoCodec::ProRes422;
    }
    if (c == fourcc::AV1) {
        return VideoCodec::AV1;
    }
    return std::nullopt;
}

std::optional<AudioCodec> audioCodecForFourCC(uint32_t fourCC) {
    const uint32_t c = canonicalCodec(fourCC);
    if (c == fourcc::AAC) {
        return AudioCodec::AAC;
    }
    if (c == fourcc::LinearPCM) {
        return AudioCodec::LinearPCM;
    }
    return std::nullopt;
}

} // namespace ve::media
