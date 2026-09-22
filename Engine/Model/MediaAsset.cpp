#include "MediaAsset.h"

namespace ve {

const char *nameOf(AssetKind kind) {
    switch (kind) {
    case AssetKind::Video:
        return "video";
    case AssetKind::Audio:
        return "audio";
    case AssetKind::Still:
        return "still";
    case AssetKind::AudioVideo:
        return "av";
    }
    return "unknown";
}

bool operator==(const MediaAsset &a, const MediaAsset &b) {
    return a.id == b.id && a.name == b.name && a.url == b.url && a.kind == b.kind &&
           identical(a.duration, b.duration) && a.width == b.width && a.height == b.height &&
           identical(a.frameDuration, b.frameDuration) && a.isVFR == b.isVFR &&
           a.audioSampleRate == b.audioSampleRate && a.audioChannels == b.audioChannels &&
           a.backendHint == b.backendHint && a.hardwareDecode == b.hardwareDecode;
}

} // namespace ve
