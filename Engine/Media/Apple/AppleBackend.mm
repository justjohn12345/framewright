#include "AppleBackend.h"

#include "../HardwareCaps.h"
#include "AppleAudioDecoder.h"
#include "AppleProber.h"
#include "AppleVideoDecoder.h"
#include "AppleWriter.h"

#include <algorithm>
#include <string_view>

namespace ve::media::apple {

AppleBackend::AppleBackend() : AppleBackend(Options{}) {}

AppleBackend::AppleBackend(Options options) : options_(options) {}

std::string AppleBackend::name() const {
    return "apple";
}

std::unique_ptr<IMediaProber> AppleBackend::makeProber() {
    return std::make_unique<AppleProber>(options_.loadTimeoutSeconds);
}

std::unique_ptr<IVideoDecoder> AppleBackend::makeVideoDecoder() {
    return std::make_unique<AppleVideoDecoder>(options_.loadTimeoutSeconds);
}

std::unique_ptr<IAudioDecoder> AppleBackend::makeAudioDecoder() {
    return std::make_unique<AppleAudioDecoder>(options_.loadTimeoutSeconds);
}

std::unique_ptr<IMediaWriter> AppleBackend::makeWriter() {
    return std::make_unique<AppleWriter>();
}

namespace {

bool contains(std::initializer_list<std::string_view> list, std::string_view value) {
    return std::find(list.begin(), list.end(), value) != list.end();
}

bool videoCodecSupported(uint32_t code) {
    const uint32_t c = canonicalCodec(code);
    if (c == fourcc::H264 || c == fourcc::HEVC || isProRes(c) || c == fourcc::JPEG || c == fourcc::make("mp4v") ||
        c == fourcc::make("mp2v") || c == fourcc::make("dvh1")) {
        return true;
    }
    if (c == fourcc::AV1 || c == fourcc::VP9) {
        return HardwareCaps::get().hardwareDecode(c);
    }
    return false;
}

bool audioCodecSupported(uint32_t code) {
    const uint32_t c = canonicalCodec(code);
    return c == fourcc::AAC || c == fourcc::LinearPCM || c == fourcc::make("aach") || c == fourcc::make("aacp") ||
           c == fourcc::make("alac") || c == fourcc::make(".mp3") || c == fourcc::make("ac-3") ||
           c == fourcc::make("ec-3") || c == fourcc::Opus || c == fourcc::FLAC || c == fourcc::make("ulaw") ||
           c == fourcc::make("alaw");
}

} // namespace

bool AppleBackend::canHandle(const MediaInfo &info) const {
    const bool stillContainer = contains({"png", "jpeg", "heic", "tiff", "gif", "avif"}, info.container);
    const bool avContainer = contains({"mov", "mp4", "m4a", "m4v", "wav", "aiff", "caf", "mp3", "aac"}, info.container);
    if (!stillContainer && !avContainer) {
        return false;
    }
    if (info.tracks.empty()) {
        return false;
    }
    // Our own prober's verdict is evidence (AVFoundation + a VideoToolbox session were asked);
    // another backend's TrackInfo::decodable says nothing about us.
    const bool ownProbe = info.backend == "apple";
    for (const TrackInfo &t : info.tracks) {
        if (ownProbe && !t.decodable) {
            return false;
        }
        switch (t.kind) {
        case TrackKind::Still:
            if (!stillContainer) {
                return false;
            }
            break;
        case TrackKind::Video:
            if (!avContainer || !videoCodecSupported(t.codec.fourCC)) {
                return false;
            }
            break;
        case TrackKind::Audio:
            if (!avContainer || !audioCodecSupported(t.codec.fourCC)) {
                return false;
            }
            break;
        }
    }
    return true;
}

bool AppleBackend::canWrite(const EncodeSettings &settings) const {
    return AppleWriter::validate(settings).ok();
}

std::shared_ptr<IMediaBackend> makeAppleBackend() {
    return std::make_shared<AppleBackend>();
}

} // namespace ve::media::apple
