#include "Validation.h"

#include <cmath>
#include <cstdint>
#include <string>
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
    if (!std::isfinite(clip.audio.gainDb)) {
        return where + ": non-finite gain";
    }
    int heads = 0;
    int tails = 0;
    for (const EffectSpan &span : clip.spans) {
        if (span.isTransition() || span.lane == kTransitionLane) {
            if (!span.isTransition() || span.lane != kTransitionLane) {
                return where + ": span " + std::to_string(span.id.value()) +
                       (span.isTransition() ? ": a transition lies on lane 0 only, found lane " + std::to_string(span.lane)
                                            : std::string(": lane 0 holds transitions only"));
            }
            if (!span.id) {
                return where + ": a transition span has an invalid id";
            }
            if (++(span.edge == ClipEdge::Head ? heads : tails) > 1) {
                return where + ": more than one transition at its " + nameOf(span.edge);
            }
            continue;
        }
        if (auto problem = effectSpanProblem(span, clip, track.kind)) {
            return where + ": " + *problem;
        }
    }
    // Spans of one lane never overlap (effect spans are sorted by start within a lane).
    for (std::size_t i = 0; i < clip.spans.size(); ++i) {
        const EffectSpan &a = clip.spans[i];
        if (a.isTransition()) {
            continue;
        }
        for (std::size_t j = i + 1; j < clip.spans.size(); ++j) {
            const EffectSpan &b = clip.spans[j];
            if (b.isTransition() || b.lane != a.lane) {
                continue;
            }
            if (a.start < b.end && b.start < a.end) {
                return where + ": spans " + std::to_string(a.id.value()) + " and " + std::to_string(b.id.value()) +
                       " overlap on lane " + std::to_string(a.lane);
            }
        }
    }
    for (std::size_t i = 1; i < clip.spans.size(); ++i) {
        const EffectSpan &a = clip.spans[i - 1];
        const EffectSpan &b = clip.spans[i];
        const bool ordered = a.lane < b.lane ||
                             (a.lane == b.lane && (a.isTransition() ? a.edge == ClipEdge::Head && b.edge == ClipEdge::Tail
                                                                    : a.start < b.start));
        if (!ordered) {
            return where + ": spans are not in lane and time order";
        }
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
    return std::nullopt;
}

std::optional<std::string> effectSpanProblem(const EffectSpan &span, const Clip &clip, TrackKind kind) {
    const std::string where = "span " + std::to_string(span.id.value());
    if (!span.id) {
        return where + ": invalid id";
    }
    if (span.isTransition() || span.lane < kFirstEffectLane || span.lane > kLastLane) {
        return where + ": lane " + std::to_string(span.lane) + " is not an effect lane (1 to " +
               std::to_string(kLastLane) + ")";
    }
    const bool videoKind = span.kind == SpanKind::Motion || span.kind == SpanKind::Opacity;
    if (videoKind != (kind == TrackKind::Video)) {
        return where + ": a " + nameOf(span.kind) + " span on " + nameOf(kind) + " track";
    }
    if (span.edge != ClipEdge::Tail || span.transition != TransitionKind::CrossDissolve) {
        return where + ": an effect span has no transition edge or kind";
    }
    for (const auto &[time, what] : {std::pair{span.start, "start"}, std::pair{span.end, "end"}}) {
        if (auto problem = modelTimeProblem(time, what)) {
            return where + ": " + *problem;
        }
    }
    if (!(span.start < span.end)) {
        return where + ": its range " + describe(span.start) + " - " + describe(span.end) + " is empty";
    }
    const auto bounds = clip.spanBounds();
    if (!bounds) {
        return where + ": its clip's source range overflows exact arithmetic";
    }
    if (span.start < bounds->first || bounds->second < span.end) {
        return where + ": " + describe(span.start) + " - " + describe(span.end) + " is outside its clip's source range (" +
               describe(bounds->first) + " - " + describe(bounds->second) + ")";
    }
    return spanTracksProblem(span);
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

std::optional<TransitionIssue> checkTransitionSpan(const Project &project, const Track &track, const Clip &owner,
                                                   const EffectSpan &span, CMTime frameDuration) {
    using K = TransitionIssueKind;
    const std::string where = "transition " + std::to_string(span.id.value());
    if (!span.isTransition() || span.lane != kTransitionLane || !span.tracks.empty()) {
        return TransitionIssue{K::Structure, where + ": not a lane-0 transition span without keyframes"};
    }
    for (const auto &[time, what] : {std::pair{span.start, "start"}, std::pair{span.end, "end"}}) {
        if (auto problem = modelTimeProblem(time, what)) {
            return TransitionIssue{K::BadDuration, where + ": " + *problem};
        }
    }
    if (!(span.start < span.end)) {
        return TransitionIssue{K::BadDuration, where + ": its range " + describe(span.start) + " - " +
                                                   describe(span.end) + " is empty"};
    }
    const CMTime length = owner.timelineDuration;
    const auto placement = placeTransition(track, owner, span);
    if (!placement) {
        return TransitionIssue{K::Structure, where + ": cannot compute its range"};
    }
    const EffectSpan *other = owner.transitionAt(span.edge == ClipEdge::Head ? ClipEdge::Tail : ClipEdge::Head);
    if (span.edge == ClipEdge::Head) {
        if (span.start != kCMTimeZero) {
            return TransitionIssue{K::Structure, where + ": a fade in starts at its clip's start"};
        }
        if (length < span.end) {
            return TransitionIssue{K::TooLong, where + ": longer than its clip"};
        }
        if (touchingClip(track, owner, ClipEdge::Head) != nullptr) {
            return TransitionIssue{K::Touching, where + ": another clip touches the start of clip " +
                                                    std::to_string(owner.id.value()) +
                                                    ", so the cut belongs to that clip (a fade in needs nothing "
                                                    "before it)"};
        }
        return std::nullopt;
    }
    if (kCMTimeZero < span.start || span.end < kCMTimeZero) {
        return TransitionIssue{K::Structure, where + ": a tail transition starts at or before its clip's end and "
                                                 "ends at or after it"};
    }
    const auto inside = checkedNegate(span.start);
    if (!inside || length < *inside) {
        return TransitionIssue{K::TooLong, where + ": longer than its clip"};
    }
    if (other != nullptr) {
        const auto room = checkedSubtract(length, *inside);
        if (!room || *room < other->end) {
            return TransitionIssue{K::Overlap, where + ": meets the fade in at the start of clip " +
                                                   std::to_string(owner.id.value())};
        }
    }
    if (placement->role == TransitionRole::FadeOut) {
        return std::nullopt;
    }
    // A cross dissolve into the clip touching the owner's end.
    const Clip *partner = placement->partner;
    if (partner == nullptr) {
        return TransitionIssue{K::NotAdjacent, where + ": runs past the end of clip " + std::to_string(owner.id.value()) +
                                                   " but no clip touches that end"};
    }
    if (!isOnFrameGrid(span.start, frameDuration) || !isOnFrameGrid(span.end, frameDuration)) {
        return TransitionIssue{K::BadDuration, where + ": a cross dissolve covers whole sequence frames on each side "
                                                   "of its cut (" + describe(span.start) + " - " +
                                                   describe(span.end) + ")"};
    }
    if (partner->timelineDuration < span.end) {
        return TransitionIssue{K::TooLong, where + ": longer than clip " + std::to_string(partner->id.value())};
    }
    if (const EffectSpan *partnerTail = partner->transitionAt(ClipEdge::Tail)) {
        const auto partnerRoom = checkedAdd(partner->timelineDuration, partnerTail->start);
        if (!partnerRoom || *partnerRoom < span.end) {
            return TransitionIssue{K::Overlap, where + ": meets the transition at the end of clip " +
                                                   std::to_string(partner->id.value())};
        }
    }
    if (!owner.isStill) {
        const MediaAsset *asset = project.findAsset(owner.assetId);
        const auto sourceEnd = owner.exactSourceTimeAt(placement->range.end);
        const CMTime mediaEnd = asset ? mediaEndFor(*asset, track.kind) : kCMTimeInvalid;
        if (!asset || !isNumeric(mediaEnd) || !sourceEnd || sourceEnd->compare(mediaEnd) > 0) {
            return TransitionIssue{K::InsufficientHandles,
                                   where + ": clip " + std::to_string(owner.id.value()) +
                                       " lacks media after its out point for the transition",
                                   owner.id};
        }
    }
    if (!partner->isStill) {
        const auto sourceStart = partner->exactSourceTimeAt(placement->range.start);
        if (!sourceStart || sourceStart->compare(kCMTimeZero) < 0) {
            return TransitionIssue{K::InsufficientHandles,
                                   where + ": clip " + std::to_string(partner->id.value()) +
                                       " lacks media before its in point for the transition",
                                   partner->id};
        }
    }
    return std::nullopt;
}

void pruneInvalidTransitions(Sequence &sequence, const Project &project, std::vector<std::string> *notes) {
    const std::string where = "sequence " + std::to_string(sequence.id.value());
    for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (Track &track : *list) {
            for (std::size_t i = track.clips.size(); i-- > 0;) {
                Clip &clip = track.clips[i];
                for (const ClipEdge edge : {ClipEdge::Tail, ClipEdge::Head}) {
                    const EffectSpan *span = clip.transitionAt(edge);
                    if (span == nullptr) {
                        continue;
                    }
                    auto issue = checkTransitionSpan(project, track, clip, *span, sequence.frameDuration);
                    if (issue && issue->kind == TransitionIssueKind::Overlap && edge == ClipEdge::Tail &&
                        kCMTimeZero < span->end && i + 1 < track.clips.size() &&
                        track.clips[i + 1].timelineStart == clip.timelineEnd()) {
                        // The next clip's fade out meets this dissolve: shorten it, if that is all.
                        Clip &next = track.clips[i + 1];
                        EffectSpan *fade = next.transitionAt(ClipEdge::Tail);
                        const auto room = checkedSubtract(next.timelineDuration, span->end);
                        if (fade != nullptr && fade->end == kCMTimeZero && room) {
                            const Clip before = next;
                            const SpanId fadeId = fade->id;
                            const auto start = checkedNegate(maxTime(*room, kCMTimeZero));
                            const bool kept = start && kCMTimeZero < *room;
                            if (kept) {
                                fade->start = *start;
                            } else {
                                std::erase_if(next.spans, [fadeId](const EffectSpan &s) { return s.id == fadeId; });
                            }
                            issue = checkTransitionSpan(project, track, clip, *span, sequence.frameDuration);
                            if (issue) {
                                next = before; // the dissolve goes anyway: the fade out stays as it was
                            } else if (notes != nullptr) {
                                notes->push_back(where + ": clip " + std::to_string(next.id.value()) + ": the fade out (transition " +
                                                 std::to_string(fadeId.value()) + ") was " +
                                                 (kept ? "shortened to " + describe(*room) : std::string("removed")) +
                                                 ": the cross dissolve " + std::to_string(span->id.value()) +
                                                 " into the clip needs " + describe(span->end));
                            }
                        }
                    }
                    if (issue) {
                        const SpanId id = span->id;
                        if (notes != nullptr) {
                            notes->push_back(where + ": clip " + std::to_string(clip.id.value()) + ": transition " +
                                             std::to_string(id.value()) + " was removed: " + issue->message);
                        }
                        std::erase_if(clip.spans, [id](const EffectSpan &s) { return s.id == id; });
                    }
                }
            }
        }
    }
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

    std::unordered_set<SpanId> spanIds;
    for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
        for (const Track &track : sequence.tracks(kind)) {
            for (const Clip &clip : track.clips) {
                for (const EffectSpan &span : clip.spans) {
                    if (!spanIds.insert(span.id).second) {
                        return where + ": duplicate span id " + std::to_string(span.id.value());
                    }
                    if (!span.isTransition()) {
                        continue;
                    }
                    if (auto issue = checkTransitionSpan(project, track, clip, span, sequence.frameDuration)) {
                        return where + ": " + issue->message;
                    }
                }
            }
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
                    for (const EffectSpan &span : clip.spans) {
                        if (auto problem = claim(span.id.value(), "span " + std::to_string(span.id.value()))) {
                            return problem;
                        }
                    }
                }
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
