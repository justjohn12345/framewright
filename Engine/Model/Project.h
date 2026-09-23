// The root of the document model: assets, sequences and the id generator.
//
// Model objects are plain values addressed by id; nothing holds pointers into the model across
// edits. Pointers returned by the find* helpers are valid until the next mutation.

#pragma once

#include "Ids.h"
#include "MediaAsset.h"
#include "Sequence.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace ve {

struct Project {
    std::string name;
    std::vector<MediaAsset> assets;
    std::vector<Sequence> sequences;
    SequenceId activeSequenceId; // invalid only when there are no sequences
    IdGenerator ids;

    const MediaAsset *findAsset(AssetId assetId) const;
    MediaAsset *findAsset(AssetId assetId);
    const Sequence *findSequence(SequenceId sequenceId) const;
    Sequence *findSequence(SequenceId sequenceId);
    const Sequence *activeSequence() const;
    Sequence *activeSequence();

    // Adds an asset under a newly generated id and returns that id. Its times are passed through
    // canonicalProbedTime.
    AssetId addAsset(MediaAsset asset);

    // Adds an empty sequence with `videoTrackCount` video tracks named V1, V2, ... and
    // `audioTrackCount` audio tracks named A1, A2, .... It becomes active if none was.
    SequenceId addSequence(std::string sequenceName, CMTime frameDuration, std::int32_t width, std::int32_t height,
                           std::size_t videoTrackCount = 1, std::size_t audioTrackCount = 1);
};

// Bit-for-bit equality of every field, including the id generator state.
bool operator==(const Project &a, const Project &b);

} // namespace ve
