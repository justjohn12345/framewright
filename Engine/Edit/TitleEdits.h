// Edits of titles and colour mattes (GeneratedContent.h; docs/plans/2026-10-02-titles-design.md, sections 9 and 10)
// and the questions the inspector asks about a selection.
//
// - SetGeneratedContent sets title parameters (or a matte's colour) on one or several clips as one undo step. It
//   sets only the parameters its change gives and keeps the others, so moving one control over a multi-selection
//   sets that parameter on every title and keeps what differs between them (the grade's rule). In a coalescing
//   group (a slider drag, a box drag, a typing run: ReplacePrevious) each step replaces the last, so every step
//   says "set the text to 'Hello' on this clip", relative to the state before the gesture.
// - summarizeTitles tells, per parameter, the value the titles of a selection agree on, or that they differ
//   ("Mixed"), and the same for the mattes' colour.
// - AddGeneratedClip is the placement rule of a new title or matte (section 9): at the playhead, on the lowest
//   video track above the target video track that is free for the clip's whole length (unlocked, shown, with
//   nothing in that time); if none is, on a new video track added on top, in the same edit. Nothing is overwritten or
//   rippled.
//
// A clip of a generator asset is placed by naming its content: ClipPlacement::generated (EditOps.h), whose asset is
// the project's generator asset of the content's kind (Project::findGeneratorAsset), which must exist when the edit
// runs (the facade adds it in the same undo step when it does not).
//
// Plain C++ (CoreMedia's CMTime only): unit-testable without Core Text or media.

#pragma once

#include "Command.h"

#include <array>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

namespace ve {

// What SetGeneratedContent sets on each clip: title parameters (nullopt: the clip keeps its own) and a matte's
// colour.
struct TitleChange {
    std::array<std::optional<TitleValue>, kTitleParameterCount> values{};
    std::optional<SRGBColour> matteColour;

    // One title parameter.
    static TitleChange of(TitleParameter parameter, TitleValue value);
    // The style of `content` (every parameter isStyleParameter says is style: Copy Style and Paste Style).
    static TitleChange style(const TitleContent &content);
    // A matte's colour.
    static TitleChange matte(SRGBColour colour);

    std::optional<TitleValue> &operator[](TitleParameter parameter) {
        return values[static_cast<std::size_t>(parameter)];
    }
    const std::optional<TitleValue> &operator[](TitleParameter parameter) const {
        return values[static_cast<std::size_t>(parameter)];
    }
    // The number of title parameters given.
    std::size_t count() const;
    bool isEmpty() const {
        return count() == 0 && !matteColour;
    }
    // `content` with the title parameters applied.
    TitleContent appliedTo(TitleContent content) const;
};

// Sets title parameters or a matte's colour on clips (see the header), the same change on every clip, or (the
// per-clip form) each clip's own change: the facade's edits that keep a title's text where it is when its point text,
// anchor or alignment changes give each title its own position. Refused as a whole, changing nothing,
// when the list or the change is empty, a clip is missing, listed twice or on a locked track, a title parameter is
// given for a clip that is not a title or a matte colour for one that is not a matte (InvalidArgument), or a value
// is not valid (titleValueProblem: its type, its range, a text that is too long). A change that leaves every clip
// as it was records no undo step. What a newer version wrote in a clip's content (GeneratedContent::foreign) is
// kept.
class SetGeneratedContent final : public SequenceCommand {
  public:
    // `name` is the Undo menu's name; empty: "Edit Title Text" for the text, "Change <parameter>" for one
    // parameter ("Change Font", "Change Shadow Opacity"), "Change Matte Colour", else "Change Title".
    SetGeneratedContent(SequenceId sequenceId, std::vector<ClipId> clipIds, TitleChange change, std::string name = {});
    SetGeneratedContent(SequenceId sequenceId, std::vector<std::pair<ClipId, TitleChange>> changes, std::string name = {});
    std::string name() const override;

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    std::vector<std::pair<ClipId, TitleChange>> changes_;
    std::string name_;
};

// What a selection's titles and mattes have.
struct TitleSummary {
    // The title clips and the matte clips of the selection, in the order given (each once).
    std::vector<ClipId> titles;
    std::vector<ClipId> mattes;
    // Per parameter: the value every one of `titles` has (nullopt when they differ or there are none), and whether
    // they differ.
    std::array<std::optional<TitleValue>, kTitleParameterCount> values{};
    std::array<bool, kTitleParameterCount> mixed{};
    // The colour every one of `mattes` has (nullopt when they differ or there are none), and whether they differ.
    std::optional<SRGBColour> matteColour;
    bool matteColourMixed = false;

    const std::optional<TitleValue> &valueOf(TitleParameter parameter) const {
        return values[static_cast<std::size_t>(parameter)];
    }
    bool isMixed(TitleParameter parameter) const {
        return mixed[static_cast<std::size_t>(parameter)];
    }
};

// The summary of the generated clips of `clipIds` in `sequence`; ids that name no clip, and clips of media, are
// left out.
TitleSummary summarizeTitles(const Sequence &sequence, const std::vector<ClipId> &clipIds);

// Adds a clip showing `content` at `at` (snapped to the frame grid) for `length` (whole frames, at least one) by
// the placement rule (see the header): on the lowest video track above `aboveTrack` (a video track of the sequence;
// an invalid id: from the bottom track up) that is unlocked, shown (not hidden, Track::muted) and free over the clip's range, else on a new video
// track added on top ("V<n>"). Refused: InvalidTime for a time before zero or not numeric, InvalidArgument for no
// content or invalid content, TrackKindMismatch when `aboveTrack` is not a video track, AssetNotFound when the
// project has no generator asset of the content's kind.
//
// Several contents (a preset of more than one layer, presetLayers: a title card's matte and title) are stacked from
// the bottom up: the first by the rule above `aboveTrack`, each next one by the rule above the track the one before
// it went on.
class AddGeneratedClip final : public SequenceCommand {
  public:
    AddGeneratedClip(SequenceId sequenceId, CMTime at, TrackId aboveTrack, std::shared_ptr<const GeneratedContent> content,
                     CMTime length = defaultStillDuration(), std::string name = {});
    AddGeneratedClip(SequenceId sequenceId, CMTime at, TrackId aboveTrack,
                     std::vector<std::shared_ptr<const GeneratedContent>> contents, CMTime length = defaultStillDuration(),
                     std::string name = {});
    // "Add Title" (or the name given).
    std::string name() const override;
    // Valid after the first successful apply (and through undo and redo): the top clip (the last content's).
    ClipId createdClipId() const {
        return createdClips_.empty() ? ClipId{} : createdClips_.back();
    }
    // Every clip it added, from the bottom up.
    const std::vector<ClipId> &createdClipIds() const {
        return createdClips_;
    }
    // The track the top clip went on; whether the edit added a track.
    TrackId placedTrackId() const {
        return placedTrack_;
    }
    bool addedTrack() const {
        return addedTrack_;
    }

  protected:
    EditResult perform(const Project &project, Sequence &sequence, IdGenerator &ids) override;

  private:
    CMTime at_;
    TrackId aboveTrack_;
    std::vector<std::shared_ptr<const GeneratedContent>> contents_;
    CMTime length_;
    std::string name_;
    std::vector<ClipId> createdClips_;
    TrackId placedTrack_;
    bool addedTrack_ = false;
};

} // namespace ve
