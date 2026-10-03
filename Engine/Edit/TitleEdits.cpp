#include "TitleEdits.h"

#include "EditOps.h"
#include "EditPrimitives.h"

#include <algorithm>
#include <unordered_set>

namespace ve {

TitleChange TitleChange::of(TitleParameter parameter, TitleValue value) {
    TitleChange change;
    change[parameter] = std::move(value);
    return change;
}

TitleChange TitleChange::matte(SRGBColour colour) {
    TitleChange change;
    change.matteColour = colour;
    return change;
}

std::size_t TitleChange::count() const {
    std::size_t n = 0;
    for (const auto &value : values) {
        n += value ? 1 : 0;
    }
    return n;
}

TitleContent TitleChange::appliedTo(TitleContent content) const {
    for (const TitleParameter parameter : kTitleParameters) {
        if (const auto &value = (*this)[parameter]) {
            setValue(content, parameter, *value);
        }
    }
    return content;
}

TitleChange TitleChange::style(const TitleContent &content) {
    TitleChange change;
    for (const TitleParameter parameter : kTitleParameters) {
        if (isStyleParameter(parameter)) {
            change[parameter] = valueOf(content, parameter);
        }
    }
    return change;
}

SetGeneratedContent::SetGeneratedContent(SequenceId sequenceId, std::vector<ClipId> clipIds, TitleChange change,
                                         std::string name)
    : SetGeneratedContent(sequenceId,
                          [&] {
                              std::vector<std::pair<ClipId, TitleChange>> changes;
                              changes.reserve(clipIds.size());
                              for (const ClipId id : clipIds) {
                                  changes.emplace_back(id, change);
                              }
                              return changes;
                          }(),
                          std::move(name)) {}

SetGeneratedContent::SetGeneratedContent(SequenceId sequenceId, std::vector<std::pair<ClipId, TitleChange>> changes,
                                         std::string name)
    : SequenceCommand(sequenceId), changes_(std::move(changes)), name_(std::move(name)) {
    // The parameters set (on any clip) and the clips: a coalescing group's steps replace each other only when they
    // set the same parameters of the same clips.
    std::string key = "title";
    for (const TitleParameter parameter : kTitleParameters) {
        const bool set = std::any_of(changes_.begin(), changes_.end(),
                                     [parameter](const auto &entry) { return entry.second[parameter].has_value(); });
        key += set ? ":" + std::string(nameOf(parameter)) : "";
    }
    const bool matte = std::any_of(changes_.begin(), changes_.end(),
                                   [](const auto &entry) { return entry.second.matteColour.has_value(); });
    key += matte ? ":matteColour" : "";
    for (const auto &[id, change] : changes_) {
        key += ":" + std::to_string(id.value());
    }
    setCoalescingKey(std::move(key));
}

std::string SetGeneratedContent::name() const {
    if (!name_.empty()) {
        return name_;
    }
    // The parameters set on any clip.
    TitleChange all;
    for (const auto &[id, change] : changes_) {
        for (const TitleParameter parameter : kTitleParameters) {
            if (change[parameter] && !all[parameter]) {
                all[parameter] = change[parameter];
            }
        }
        if (change.matteColour) {
            all.matteColour = change.matteColour;
        }
    }
    if (all.count() == 0 && all.matteColour) {
        return "Change Matte Colour";
    }
    if (all.count() == 1 && !all.matteColour) {
        if (all[TitleParameter::Text]) {
            return "Edit Title Text";
        }
        for (const TitleParameter parameter : kTitleParameters) {
            if (all[parameter]) {
                return std::string("Change ") + displayNameOf(parameter);
            }
        }
    }
    return "Change Title";
}

EditResult SetGeneratedContent::perform(const Project &, Sequence &sequence, IdGenerator &) {
    if (changes_.empty()) {
        return EditResult::failure(EditError::InvalidArgument, "No titles to change.");
    }
    std::unordered_set<ClipId> seen;
    for (const auto &[id, change] : changes_) {
        if (change.isEmpty()) {
            return EditResult::failure(EditError::InvalidArgument, "No title values to set.");
        }
        for (const TitleParameter parameter : kTitleParameters) {
            if (const auto &value = change[parameter]) {
                if (auto problem = titleValueProblem(parameter, *value)) {
                    return EditResult::failure(EditError::InvalidArgument, *problem);
                }
            }
        }
        if (change.matteColour && !isValidColour(*change.matteColour)) {
            return EditResult::failure(EditError::InvalidArgument,
                                       "A matte's colour must have red, green and blue from 0 to 1.");
        }
        if (!seen.insert(id).second) {
            return EditResult::failure(EditError::InvalidArgument,
                                       "Clip " + std::to_string(id.value()) + " is listed twice.");
        }
    }
    for (const auto &[id, change] : changes_) {
        Track *track = nullptr;
        Clip *clip = nullptr;
        if (EditResult r = findEditableClip(sequence, id, track, clip); !r) {
            return r;
        }
        const std::shared_ptr<const GeneratedContent> &content = clip->generated;
        if (change.count() > 0 && (!content || !content->isTitle())) {
            return EditResult::failure(EditError::InvalidArgument,
                                       "Clip " + std::to_string(id.value()) + " is not a title.");
        }
        if (change.matteColour && (!content || !content->isMatte())) {
            return EditResult::failure(EditError::InvalidArgument,
                                       "Clip " + std::to_string(id.value()) + " is not a colour matte.");
        }
        if (content->isTitle()) {
            TitleContent changed = change.appliedTo(content->title());
            if (!(changed == content->title())) {
                clip->generated = GeneratedContent::makeTitle(std::move(changed), content->foreign());
            }
        } else if (*change.matteColour != content->matteColour()) {
            clip->generated = GeneratedContent::makeMatte(*change.matteColour, content->foreign());
        }
    }
    return EditResult::success();
}

TitleSummary summarizeTitles(const Sequence &sequence, const std::vector<ClipId> &clipIds) {
    TitleSummary summary;
    std::unordered_set<ClipId> seen;
    for (const ClipId id : clipIds) {
        const Clip *clip = sequence.findClip(id);
        if (clip == nullptr || !clip->generated || !seen.insert(id).second) {
            continue;
        }
        if (clip->generated->isTitle()) {
            const TitleContent &content = clip->generated->title();
            const bool first = summary.titles.empty();
            summary.titles.push_back(id);
            for (const TitleParameter parameter : kTitleParameters) {
                const auto i = static_cast<std::size_t>(parameter);
                const TitleValue value = valueOf(content, parameter);
                if (first) {
                    summary.values[i] = value;
                } else if (summary.values[i] && !(*summary.values[i] == value)) {
                    summary.values[i] = std::nullopt;
                    summary.mixed[i] = true;
                }
            }
        } else {
            const SRGBColour colour = clip->generated->matteColour();
            if (summary.mattes.empty()) {
                summary.matteColour = colour;
            } else if (summary.matteColour && *summary.matteColour != colour) {
                summary.matteColour = std::nullopt;
                summary.matteColourMixed = true;
            }
            summary.mattes.push_back(id);
        }
    }
    return summary;
}

AddGeneratedClip::AddGeneratedClip(SequenceId sequenceId, CMTime at, TrackId aboveTrack,
                                   std::shared_ptr<const GeneratedContent> content, CMTime length, std::string name)
    : SequenceCommand(sequenceId), at_(at), aboveTrack_(aboveTrack), content_(std::move(content)), length_(length),
      name_(std::move(name)) {}

std::string AddGeneratedClip::name() const {
    if (!name_.empty()) {
        return name_;
    }
    return content_ && content_->isMatte() ? "Add Colour Matte" : "Add Title";
}

EditResult AddGeneratedClip::perform(const Project &project, Sequence &sequence, IdGenerator &ids) {
    if (!content_) {
        return EditResult::failure(EditError::InvalidArgument, "No title to add.");
    }
    if (!CMTIME_IS_NUMERIC(at_)) {
        return EditResult::failure(EditError::InvalidTime, "The time to add the title at is not a valid time.");
    }
    const CMTime at = snapToSequence(sequence, at_);
    if (at < kCMTimeZero) {
        return EditResult::failure(EditError::InvalidTime, "A title cannot start before time zero.");
    }
    if (!isNumeric(length_) || !(length_ > kCMTimeZero)) {
        return EditResult::failure(EditError::InvalidTime, "A title needs a positive length.");
    }
    const CMTime length = maxTime(snapToSequence(sequence, length_), sequence.frameDuration);
    const TimeRange range{at, at + length};
    std::size_t first = 0;
    if (aboveTrack_) {
        const Track *target = sequence.findTrack(aboveTrack_);
        if (target == nullptr) {
            return EditResult::failure(EditError::TrackNotFound,
                                       "Track " + std::to_string(aboveTrack_.value()) + " does not exist.");
        }
        if (target->kind != TrackKind::Video) {
            return EditResult::failure(EditError::TrackKindMismatch, "A title goes above a video track.");
        }
        for (std::size_t i = 0; i < sequence.videoTracks.size(); ++i) {
            if (sequence.videoTracks[i].id == aboveTrack_) {
                first = i + 1;
            }
        }
    }
    Track *destination = nullptr;
    for (std::size_t i = first; i < sequence.videoTracks.size() && destination == nullptr; ++i) {
        Track &track = sequence.videoTracks[i];
        const bool free = std::none_of(track.clips.begin(), track.clips.end(), [&](const Clip &clip) {
            return clip.timelineRange().intersects(range);
        });
        if (!track.locked && !track.muted && free) { // a hidden video track (muted) would not show it
            destination = &track;
        }
    }
    addedTrack_ = false;
    if (destination == nullptr) {
        // No free track above the target: a new one on top, in the same edit.
        Track track;
        track.id = ids.make<TrackId>();
        track.kind = TrackKind::Video;
        track.name = "V" + std::to_string(sequence.videoTracks.size() + 1);
        sequence.videoTracks.push_back(std::move(track));
        destination = &sequence.videoTracks.back();
        addedTrack_ = true;
    }
    ClipPlacement placement;
    placement.trackId = destination->id;
    placement.generated = content_;
    placement.sourceIn = kCMTimeZero;
    placement.sourceOut = length;
    Clip clip;
    if (EditResult r = buildClipForPlacement(project, sequence, *destination, placement, clip); !r) {
        return r;
    }
    clip.id = ids.make<ClipId>();
    clip.timelineStart = at;
    createdClip_ = clip.id;
    placedTrack_ = destination->id;
    insertClipSorted(*destination, std::move(clip));
    return EditResult::success();
}

} // namespace ve
