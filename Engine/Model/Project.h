// The root of the document model: assets, sequences and the id generator.
//
// Model objects are plain values addressed by id; nothing holds pointers into the model across
// edits. Pointers returned by the find* helpers are valid until the next mutation.

#pragma once

#include "CubeLut.h"
#include "Ids.h"
#include "MediaAsset.h"
#include "Sequence.h"

#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace ve {

struct Project {
    std::string name;
    std::vector<MediaAsset> assets;
    std::vector<Sequence> sequences;
    SequenceId activeSequenceId; // invalid only when there are no sequences
    IdGenerator ids;
    // "Sharpen scaled-down sources" (the Sequence Settings sheet, shown in the export sheet): a
    // picture the compositor draws smaller than 3/4 of its size (Lanczos pre-scaled) gets an unsharp
    // mask after the pre-scale (Compositor.h), in every render of the project: the program monitor,
    // its solo preview, the output display, the source monitor and the export.
    bool sharpenScaledDownSources = true;
    // The colour LUTs the clips' grades use (ClipGrade::inputLut, ::lookLut), by content id (cubeContentId):
    // a copy of each imported .cube table, so the project needs no file to show them. Shared and immutable,
    // so copies of the project (a frame's model, an undo snapshot) cost nothing. Entries no clip uses stay
    // until the project is saved (only used ones are written).
    std::map<std::string, std::shared_ptr<const CubeLut>> luts;

    const MediaAsset *findAsset(AssetId assetId) const;
    MediaAsset *findAsset(AssetId assetId);
    // The project's generator asset of `kind` (the first, MediaAsset.h; a title clip refers to the Title asset),
    // or nullptr when no clip of the kind was made yet.
    const MediaAsset *findGeneratorAsset(GeneratorKind kind) const;
    const Sequence *findSequence(SequenceId sequenceId) const;
    Sequence *findSequence(SequenceId sequenceId);
    const Sequence *activeSequence() const;
    Sequence *activeSequence();

    // Adds an asset under a newly generated id and returns that id. Its times are passed through
    // canonicalProbedTime.
    AssetId addAsset(MediaAsset asset);

    // The LUT of content id `id`, or nullptr.
    const CubeLut *findLut(const std::string &id) const;
    // Adds `lut` (which must be valid: cubeProblem) under its content id unless that id is there (the same
    // table, maybe from another file: the first copy's names are kept). Returns the id.
    std::string addLut(CubeLut lut);

    // Adds an empty sequence with `videoTrackCount` video tracks named V1, V2, ... and
    // `audioTrackCount` audio tracks named A1, A2, .... It becomes active if none was.
    SequenceId addSequence(std::string sequenceName, CMTime frameDuration, std::int32_t width, std::int32_t height,
                           std::size_t videoTrackCount = 1, std::size_t audioTrackCount = 1);
};

// Bit-for-bit equality of every field, including the id generator state (LUTs by their contents).
bool operator==(const Project &a, const Project &b);

// How many clips of every sequence use each asset, in the order of `project.assets` (zero for an
// unused asset).
std::vector<std::pair<AssetId, std::size_t>> assetUseCounts(const Project &project);

} // namespace ve
