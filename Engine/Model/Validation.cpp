#include "Validation.h"

#include <cmath>
#include <cstdint>
#include <unordered_map>
#include <unordered_set>

namespace ve {

namespace {

std::string clipName(ClipId id) {
    return "clip " + std::to_string(id.value());
}

struct ClipInfo {
    TrackId trackId;
    std::optional<ClipId> linkedClipId;
};

// Problem with a time that may be non-numeric: an invalid time must be the canonical
// kCMTimeInvalid (it is saved as null), a numeric one must be an exact model time.
std::optional<std::string> optionalTimeProblem(CMTime t, const std::string &what) {
    if (CMTIME_IS_INVALID(t)) {
        if (!identical(t, kCMTimeInvalid)) {
            return what + " is an invalid time with non-zero fields";
        }
        return std::nullopt;
    }
    if (!isNumeric(t)) {
        return t.epoch != 0 ? std::optional<std::string>(what + " has epoch " + std::to_string(t.epoch))
                            : std::nullopt;
    }
    return modelTimeProblem(t, what);
}

std::optional<std::string> validateClip(const Clip &clip, const Track &track, const Sequence &sequence,
                                        const Project &project, const std::unordered_map<ClipId, ClipInfo> &clips) {
    const std::string where = clipName(clip.id);
    const MediaAsset *asset = project.findAsset(clip.assetId);
    if (!asset) {
        return where + ": unknown asset " + std::to_string(clip.assetId.value());
    }
    if (!assetFitsTrack(*asset, track.kind)) {
        return where + ": " + nameOf(asset->kind) + " asset on a " + nameOf(track.kind) + " track";
    }
    const bool shouldBeStill = asset->isStill();
    if (clip.isStill != shouldBeStill) {
        return where +
               (shouldBeStill ? ": still asset but clip is not marked still" : ": marked still but asset is not");
    }
    for (const auto &[time, what] : {std::pair{clip.timelineStart, "start"}, std::pair{clip.timelineDuration, "duration"},
                                     std::pair{clip.sourceIn, "sourceIn"}}) {
        if (auto problem = modelTimeProblem(time, what)) {
            return where + ": " + *problem;
        }
    }
    if (!isPositive(clip.timelineDuration)) {
        return where + ": duration " + describe(clip.timelineDuration) + " is not positive";
    }
    if (clip.isStill) {
        if (!(clip.speed == Ratio{1, 1})) {
            return where + ": still clips must have speed 1";
        }
        if (clip.sourceIn != kCMTimeZero) {
            return where + ": still clips must have sourceIn 0";
        }
    } else {
        if (!isValidSpeed(clip.speed)) {
            return where + ": speed " + std::to_string(clip.speed.num) + "/" + std::to_string(clip.speed.den) +
                   " is not a reduced ratio within [1/100, 100] with a denominator of at most " +
                   std::to_string(kMaxSpeedDenominator);
        }
        if (clip.sourceIn < kCMTimeZero) {
            return where + ": sourceIn " + describe(clip.sourceIn) + " before the start of the media";
        }
        const auto sourceOut = clip.exactSourceOut();
        if (!sourceOut) {
            return where + ": its source out point overflows exact arithmetic";
        }
        const CMTime mediaEnd = mediaEndFor(*asset, track.kind);
        if (!isNumeric(mediaEnd) || sourceOut->compare(mediaEnd) > 0) {
            return where + ": source out point " + describe(sourceOut->toTimeRounded()) + " past the end of the " +
                   (track.kind == TrackKind::Video ? "media's video (" : "media (") + describe(mediaEnd) + ")";
        }
    }
    if (!isOnFrameGrid(clip.timelineStart, sequence.frameDuration)) {
        return where + ": start " + describe(clip.timelineStart) + " is not on the sequence frame grid";
    }
    if (!isOnFrameGrid(clip.timelineDuration, sequence.frameDuration)) {
        return where + ": duration " + describe(clip.timelineDuration) + " is not a whole number of frames";
    }
    if (auto problem = videoParamsProblem(clip.video)) {
        return where + ": " + *problem;
    }
    if (track.kind != TrackKind::Video && clip.video.isAnimated()) {
        return where + ": only clips on video tracks have Motion keyframes";
    }
    const AudioParams &a = clip.audio;
    if (!std::isfinite(a.gainDb)) {
        return where + ": non-finite gain";
    }
    for (const auto &[fade, what] : {std::pair{a.fadeInDuration, "fade-in"}, std::pair{a.fadeOutDuration, "fade-out"}}) {
        if (auto problem = modelTimeProblem(fade, what)) {
            return where + ": " + *problem;
        }
        if (fade < kCMTimeZero) {
            return where + ": " + what + " " + describe(fade) + " is negative";
        }
        if (fade > clip.timelineDuration) {
            return where + ": " + what + " " + describe(fade) + " is longer than the clip (" +
                   describe(clip.timelineDuration) + ")";
        }
    }
    const auto fadeIn = ExactTime::from(a.fadeInDuration);
    const auto fadeOut = ExactTime::from(a.fadeOutDuration);
    const auto fades = fadeIn && fadeOut ? fadeIn->plus(*fadeOut) : std::nullopt;
    if (!fades || fades->compare(clip.timelineDuration) > 0) {
        return where + ": fade-in " + describe(a.fadeInDuration) + " and fade-out " + describe(a.fadeOutDuration) +
               " overlap (together longer than the clip, " + describe(clip.timelineDuration) + ")";
    }
    if (clip.linkedClipId) {
        const ClipId partnerId = *clip.linkedClipId;
        if (partnerId == clip.id) {
            return where + ": linked to itself";
        }
        const auto partner = clips.find(partnerId);
        if (partner == clips.end()) {
            return where + ": linked to missing " + clipName(partnerId);
        }
        if (partner->second.linkedClipId != clip.id) {
            return where + ": link to " + clipName(partnerId) + " is not reciprocated";
        }
        if (partner->second.trackId == clip.trackId) {
            return where + ": linked to " + clipName(partnerId) + " on the same track";
        }
    }
    return std::nullopt;
}

} // namespace

std::optional<std::string> modelTimeProblem(CMTime t, const std::string &what) {
    if (!isNumeric(t) || t.timescale <= 0) {
        return what + " " + describe(t) + " is not a numeric time";
    }
    if (isRounded(t)) {
        return what + " " + describe(t) + " has been rounded";
    }
    if (t.epoch != 0) {
        return what + " " + describe(t) + " has epoch " + std::to_string(t.epoch);
    }
    return std::nullopt;
}

std::optional<std::string> videoParamsProblem(const VideoParams &v) {
    if (!std::isfinite(v.x) || !std::isfinite(v.y) || !std::isfinite(v.scale) || !std::isfinite(v.rotationDegrees) ||
        !std::isfinite(v.opacity)) {
        return std::string("non-finite video parameter");
    }
    if (v.scale < 0.0 || v.opacity < 0.0 || v.opacity > 1.0) {
        return std::string("video scale must be >= 0 and opacity within [0, 1]");
    }
    for (const MotionParameter parameter : kMotionParameters) {
        if (auto problem = keyframeTrackProblem(v.keyframes.track(parameter), parameter)) {
            return problem;
        }
    }
    return std::nullopt;
}

std::optional<std::string> validateAsset(const MediaAsset &asset) {
    const std::string what = "asset " + std::to_string(asset.id.value());
    if (asset.url.empty()) {
        return what + ": empty URL";
    }
    if (auto problem = optionalTimeProblem(asset.duration, "duration")) {
        return what + ": " + *problem;
    }
    if (auto problem = optionalTimeProblem(asset.frameDuration, "frame duration")) {
        return what + ": " + *problem;
    }
    if (asset.isStill()) {
        if (isNumeric(asset.duration)) {
            return what + ": a still has no duration, found " + describe(asset.duration);
        }
    } else if (!isPositive(asset.duration)) {
        return what + ": duration " + describe(asset.duration) + " is not positive";
    }
    if (auto problem = optionalTimeProblem(asset.videoDuration, "video duration")) {
        return what + ": " + *problem;
    }
    if (isNumeric(asset.videoDuration)) {
        if (!asset.hasVideo() || asset.isStill()) {
            return what + ": only video has a video duration, found " + describe(asset.videoDuration);
        }
        if (!isPositive(asset.videoDuration) || asset.videoDuration > asset.duration) {
            return what + ": video duration " + describe(asset.videoDuration) + " is not within (0, " +
                   describe(asset.duration) + "]";
        }
    }
    if (asset.hasVideo()) {
        if (asset.width <= 0 || asset.height <= 0) {
            return what + ": frame size " + std::to_string(asset.width) + "x" + std::to_string(asset.height) +
                   " is not positive";
        }
        if (!isValidRotation(asset.rotationDegrees)) {
            return what + ": rotation " + std::to_string(asset.rotationDegrees) + " is not 0, 90, 180 or 270";
        }
    }
    if (asset.hasVideo() && !asset.isStill()) {
        const bool missingAllowed = asset.isVFR && CMTIME_IS_INVALID(asset.frameDuration);
        if (!missingAllowed && !isPositive(asset.frameDuration)) {
            return what + ": frame duration " + describe(asset.frameDuration) + " is not positive";
        }
    }
    if (asset.hasAudio() && (asset.audioSampleRate <= 0 || asset.audioChannels <= 0)) {
        return what + ": audio needs a positive sample rate and channel count (" +
               std::to_string(asset.audioSampleRate) + " Hz, " + std::to_string(asset.audioChannels) + " channels)";
    }
    return std::nullopt;
}

bool assetFitsTrack(const MediaAsset &asset, TrackKind kind) {
    return kind == TrackKind::Video ? asset.hasVideo() : asset.hasAudio();
}

CMTime mediaEndFor(const MediaAsset &asset, TrackKind kind) {
    return kind == TrackKind::Video ? asset.videoEnd() : asset.duration;
}

std::optional<TransitionIssue> checkTransition(const Sequence &sequence, const Project &project,
                                               const Transition &transition) {
    using K = TransitionIssueKind;
    const std::string where = "transition " + std::to_string(transition.id.value());
    if (!transition.id) {
        return TransitionIssue{K::Structure, where + ": invalid id"};
    }
    const Track *track = sequence.findTrack(transition.trackId);
    if (!track) {
        return TransitionIssue{K::Structure, where + ": unknown track " + std::to_string(transition.trackId.value())};
    }
    if (transition.fromClipId == transition.toClipId) {
        return TransitionIssue{K::Structure, where + ": joins a clip to itself"};
    }
    const Clip *from = track->find(transition.fromClipId);
    const Clip *to = track->find(transition.toClipId);
    if (!from || !to) {
        return TransitionIssue{K::Structure,
                               where + ": its clips are not both on track " + std::to_string(track->id.value())};
    }
    if (from->timelineEnd() != to->timelineStart) {
        return TransitionIssue{K::NotAdjacent,
                               where + ": " + clipName(from->id) + " and " + clipName(to->id) + " are not adjacent"};
    }
    if (!isExactModelTime(transition.duration) || !isPositive(transition.duration) ||
        !isOnFrameGrid(transition.duration, sequence.frameDuration)) {
        return TransitionIssue{K::BadDuration, where + ": duration " + describe(transition.duration) +
                                                   " is not a positive whole number of frames"};
    }
    const auto range = sequence.transitionRange(transition);
    if (!range) {
        return TransitionIssue{K::Structure, where + ": cannot compute its range"};
    }
    if (range->start < from->timelineStart || range->end > to->timelineEnd()) {
        return TransitionIssue{K::TooLong, where + ": longer than the clips it joins"};
    }
    if (!from->isStill) {
        const MediaAsset *asset = project.findAsset(from->assetId);
        const auto sourceEnd = from->exactSourceTimeAt(range->end);
        const CMTime mediaEnd = asset ? mediaEndFor(*asset, track->kind) : kCMTimeInvalid;
        if (!asset || !isNumeric(mediaEnd) || !sourceEnd || sourceEnd->compare(mediaEnd) > 0) {
            return TransitionIssue{K::InsufficientHandles,
                                   where + ": " + clipName(from->id) + " lacks media after its out point for the transition",
                                   from->id};
        }
    }
    if (!to->isStill) {
        const auto sourceStart = to->exactSourceTimeAt(range->start);
        if (!sourceStart || sourceStart->compare(kCMTimeZero) < 0) {
            return TransitionIssue{K::InsufficientHandles,
                                   where + ": " + clipName(to->id) + " lacks media before its in point for the transition",
                                   to->id};
        }
    }
    return std::nullopt;
}

std::optional<std::string> validateSequence(const Sequence &sequence, const Project &project) {
    const std::string where = "sequence " + std::to_string(sequence.id.value());
    if (!sequence.id) {
        return where + ": invalid id";
    }
    if (auto problem = modelTimeProblem(sequence.frameDuration, "frame duration")) {
        return where + ": " + *problem;
    }
    if (!isPositive(sequence.frameDuration)) {
        return where + ": frame duration " + describe(sequence.frameDuration) + " is not positive";
    }
    if (sequence.width <= 0 || sequence.height <= 0) {
        return where + ": frame size must be positive";
    }
    if (sequence.audioSampleRate <= 0) {
        return where + ": audio sample rate must be positive";
    }
    std::unordered_map<ClipId, ClipInfo> clipInfo;
    for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
        for (const Track &track : sequence.tracks(kind)) {
            for (const Clip &clip : track.clips) {
                clipInfo.emplace(clip.id, ClipInfo{track.id, clip.linkedClipId});
            }
        }
    }
    std::unordered_set<TrackId> trackIds;
    std::unordered_set<ClipId> clipIds;
    for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
        for (const Track &track : sequence.tracks(kind)) {
            if (track.kind != kind) {
                return where + ": track " + std::to_string(track.id.value()) + " is in the wrong track list";
            }
            if (!trackIds.insert(track.id).second) {
                return where + ": duplicate track id " + std::to_string(track.id.value());
            }
            if (auto problem = track.checkInvariants()) {
                return where + ": " + *problem;
            }
            for (const Clip &clip : track.clips) {
                if (!clipIds.insert(clip.id).second) {
                    return where + ": duplicate clip id " + std::to_string(clip.id.value());
                }
                if (auto problem = validateClip(clip, track, sequence, project, clipInfo)) {
                    return where + ": " + *problem;
                }
            }
        }
    }

    std::unordered_set<TransitionId> transitionIds;
    std::unordered_map<ClipId, TimeRange> outgoingRanges; // clip -> range of the transition at its end
    std::unordered_map<ClipId, TimeRange> incomingRanges; // clip -> range of the transition at its start
    for (const Transition &transition : sequence.transitions) {
        if (!transitionIds.insert(transition.id).second) {
            return where + ": duplicate transition id " + std::to_string(transition.id.value());
        }
        if (auto issue = checkTransition(sequence, project, transition)) {
            return where + ": " + issue->message;
        }
        const TimeRange range = *sequence.transitionRange(transition);
        if (!outgoingRanges.emplace(transition.fromClipId, range).second ||
            !incomingRanges.emplace(transition.toClipId, range).second) {
            return where + ": more than one transition on the cut at " + describe(range.start);
        }
    }
    for (const auto &[clipId, tailRange] : outgoingRanges) {
        const auto head = incomingRanges.find(clipId);
        if (head != incomingRanges.end() && head->second.end > tailRange.start) {
            return where + ": transitions overlap on " + clipName(clipId);
        }
    }
    return std::nullopt;
}

std::optional<std::string> validateProject(const Project &project) {
    std::unordered_set<std::uint64_t> usedIds;
    std::uint64_t maxId = 0;
    auto claim = [&](std::uint64_t value, const std::string &what) -> std::optional<std::string> {
        if (value == 0) {
            return what + " has an invalid id";
        }
        if (!usedIds.insert(value).second) {
            return "id " + std::to_string(value) + " is used more than once (" + what + ")";
        }
        maxId = value > maxId ? value : maxId;
        return std::nullopt;
    };

    for (const MediaAsset &asset : project.assets) {
        if (auto problem = claim(asset.id.value(), "asset " + std::to_string(asset.id.value()))) {
            return problem;
        }
        if (auto problem = validateAsset(asset)) {
            return problem;
        }
    }
    for (const Sequence &sequence : project.sequences) {
        if (auto problem = claim(sequence.id.value(), "sequence " + std::to_string(sequence.id.value()))) {
            return problem;
        }
        for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
            for (const Track &track : sequence.tracks(kind)) {
                if (auto problem = claim(track.id.value(), "track " + std::to_string(track.id.value()))) {
                    return problem;
                }
                for (const Clip &clip : track.clips) {
                    if (auto problem = claim(clip.id.value(), "clip " + std::to_string(clip.id.value()))) {
                        return problem;
                    }
                }
            }
        }
        for (const Transition &transition : sequence.transitions) {
            if (auto problem = claim(transition.id.value(), "transition " + std::to_string(transition.id.value()))) {
                return problem;
            }
        }
        if (auto problem = validateSequence(sequence, project)) {
            return problem;
        }
    }
    if (project.ids.nextValue() <= maxId) {
        return "id generator (next " + std::to_string(project.ids.nextValue()) + ") is not ahead of id " +
               std::to_string(maxId);
    }
    if (project.sequences.empty() ? project.activeSequenceId.isValid()
                                  : project.findSequence(project.activeSequenceId) == nullptr) {
        return "active sequence " + std::to_string(project.activeSequenceId.value()) + " does not exist";
    }
    return std::nullopt;
}

} // namespace ve
