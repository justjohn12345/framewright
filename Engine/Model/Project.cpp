#include "Project.h"

#include <utility>

namespace ve {

bool operator==(const Project &a, const Project &b) {
    return a.name == b.name && a.assets == b.assets && a.sequences == b.sequences &&
           a.activeSequenceId == b.activeSequenceId && a.ids == b.ids;
}

const MediaAsset *Project::findAsset(AssetId assetId) const {
    for (const MediaAsset &asset : assets) {
        if (asset.id == assetId) {
            return &asset;
        }
    }
    return nullptr;
}

MediaAsset *Project::findAsset(AssetId assetId) {
    return const_cast<MediaAsset *>(static_cast<const Project *>(this)->findAsset(assetId));
}

const Sequence *Project::findSequence(SequenceId sequenceId) const {
    for (const Sequence &sequence : sequences) {
        if (sequence.id == sequenceId) {
            return &sequence;
        }
    }
    return nullptr;
}

Sequence *Project::findSequence(SequenceId sequenceId) {
    return const_cast<Sequence *>(static_cast<const Project *>(this)->findSequence(sequenceId));
}

const Sequence *Project::activeSequence() const {
    return findSequence(activeSequenceId);
}

Sequence *Project::activeSequence() {
    return findSequence(activeSequenceId);
}

AssetId Project::addAsset(MediaAsset asset) {
    asset.id = ids.make<AssetId>();
    const AssetId assetId = asset.id;
    assets.push_back(std::move(asset));
    return assetId;
}

SequenceId Project::addSequence(std::string sequenceName, CMTime frameDuration, std::int32_t width, std::int32_t height,
                                std::size_t videoTrackCount, std::size_t audioTrackCount) {
    Sequence sequence;
    sequence.id = ids.make<SequenceId>();
    sequence.name = std::move(sequenceName);
    sequence.frameDuration = frameDuration;
    sequence.width = width;
    sequence.height = height;
    for (std::size_t i = 0; i < videoTrackCount; ++i) {
        Track track;
        track.id = ids.make<TrackId>();
        track.kind = TrackKind::Video;
        track.name = "V" + std::to_string(i + 1);
        sequence.videoTracks.push_back(std::move(track));
    }
    for (std::size_t i = 0; i < audioTrackCount; ++i) {
        Track track;
        track.id = ids.make<TrackId>();
        track.kind = TrackKind::Audio;
        track.name = "A" + std::to_string(i + 1);
        sequence.audioTracks.push_back(std::move(track));
    }
    const SequenceId sequenceId = sequence.id;
    sequences.push_back(std::move(sequence));
    if (!findSequence(activeSequenceId)) {
        activeSequenceId = sequenceId;
    }
    return sequenceId;
}

} // namespace ve
