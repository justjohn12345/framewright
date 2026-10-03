#include "Project.h"

#include <algorithm>
#include <map>
#include <utility>

namespace ve {

bool operator==(const Project &a, const Project &b) {
    return a.name == b.name && a.assets == b.assets && a.sequences == b.sequences &&
           a.activeSequenceId == b.activeSequenceId && a.ids == b.ids &&
           a.sharpenScaledDownSources == b.sharpenScaledDownSources &&
           std::equal(a.luts.begin(), a.luts.end(), b.luts.begin(), b.luts.end(), [](const auto &x, const auto &y) {
               return x.first == y.first && (x.second == y.second || (x.second && y.second && *x.second == *y.second));
           });
}

const CubeLut *Project::findLut(const std::string &id) const {
    const auto it = luts.find(id);
    return it == luts.end() ? nullptr : it->second.get();
}

std::string Project::addLut(CubeLut lut) {
    std::string id = cubeContentId(lut);
    if (luts.find(id) == luts.end()) {
        luts.emplace(id, std::make_shared<const CubeLut>(std::move(lut)));
    }
    return id;
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

const MediaAsset *Project::findGeneratorAsset(GeneratorKind kind) const {
    if (kind == GeneratorKind::None) {
        return nullptr;
    }
    for (const MediaAsset &asset : assets) {
        if (asset.generator == kind) {
            return &asset;
        }
    }
    return nullptr;
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
    asset.duration = canonicalProbedTime(asset.duration);
    asset.frameDuration = canonicalProbedTime(asset.frameDuration);
    asset.videoDuration = canonicalProbedTime(asset.videoDuration);
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

std::vector<std::pair<AssetId, std::size_t>> assetUseCounts(const Project &project) {
    std::map<AssetId, std::size_t> counts;
    for (const Sequence &sequence : project.sequences) {
        for (const auto *tracks : {&sequence.videoTracks, &sequence.audioTracks}) {
            for (const Track &track : *tracks) {
                for (const Clip &clip : track.clips) {
                    ++counts[clip.assetId];
                }
            }
        }
    }
    std::vector<std::pair<AssetId, std::size_t>> uses;
    uses.reserve(project.assets.size());
    for (const MediaAsset &asset : project.assets) {
        auto it = counts.find(asset.id);
        uses.emplace_back(asset.id, it == counts.end() ? 0 : it->second);
    }
    return uses;
}

} // namespace ve
