// TransitionRules (Engine/Model/TransitionRules.h), the one owner of the room a transition has at an
// edge of its clip (review 1.8):
//   - its callers give what they gave before it: fadeLimit, transitionSideLimits, checkTransitionSpan,
//     pruneInvalidTransitions, setClipFade, Clip::fitSpans' fades and the frame-rate conform's fade
//     fitting are compared with copies of their code before the change (namespace ref below) over
//     thousands of random tracks: valid and invalid transitions, fades of sample lengths, stills, speeds,
//     handles near the media's ends;
//   - the disagreements between the copies that the change keeps (documented in open-findings,
//     "Colour grading prerequisites round 2", item 5), each shown by a test;
//   - edgeRoom's parts, limits, limiting clips and reasons on hand-made cuts.

#include "../../Engine/Edit/TransitionFitting.h"
#include "../../Engine/Model/TransitionRules.h"
#include "../Edit/EditTestSupport.h"

#include <random>

using namespace vetest;

namespace ref {

using namespace ve;

// ----- The rules as they were written before TransitionRules (copied from 520e7c0) -----

std::string idString(std::uint64_t value) {
    return std::to_string(value);
}

EditResult requireExact(CMTime t, const char *what) {
    if (!isExactModelTime(t)) {
        return EditResult::failure(EditError::InvalidTime, std::string(what) + " " + describe(t) +
                                                               " is not an exact time (numeric, unrounded, epoch 0)");
    }
    return EditResult::success();
}

std::string quotedMediaName(const Project &project, const Clip &clip) {
    const MediaAsset *asset = project.findAsset(clip.assetId);
    const std::string name = asset && !asset->name.empty() ? asset->name : "clip " + idString(clip.id.value());
    return "“" + name + "”";
}

std::int64_t wholeFrames(const std::optional<ExactTime> &length, CMTime frameDuration) {
    if (!length) {
        return std::numeric_limits<std::int64_t>::max() / 4;
    }
    if (length->numerator() <= 0) {
        return 0;
    }
    return length->frameIndex(frameDuration, SnapMode::Floor).value_or(0);
}

CMTime incomingInside(const Track &track, const Clip &clip) {
    const Clip *previous = touchingClip(track, clip, ClipEdge::Head);
    if (previous == nullptr) {
        return kCMTimeZero;
    }
    const TransitionSpan *tail = previous->transitionAt(ClipEdge::Tail);
    return tail != nullptr && kCMTimeZero < tail->end ? tail->end : kCMTimeZero;
}

void setTransitionFrames(TransitionSpan &span, std::int64_t before, std::int64_t after, CMTime frameDuration) {
    if (span.edge == ClipEdge::Head) {
        span.start = kCMTimeZero;
        span.end = timeForFrame(after, frameDuration);
    } else {
        span.start = negateTime(timeForFrame(before, frameDuration));
        span.end = timeForFrame(after, frameDuration);
    }
}

TransitionLimit refFadeLimit(const Clip &clip, const Track &track, ClipEdge edge, CMTime frameDuration) {
    // A fade in is limited by the clip's tail transition, a fade out by its fade in and the dissolve coming
    // into the clip: never by the span at its own edge (the fade being resized, if any).
    const Clip &owner = clip;
    CMTime taken = kCMTimeZero;
    CMTime incoming = kCMTimeZero;
    if (edge == ClipEdge::Head) {
        if (const TransitionSpan *tail = owner.transitionAt(ClipEdge::Tail)) {
            taken = -tail->start;
        }
    } else {
        taken = clipFadeLength(owner, ClipEdge::Head);
        incoming = incomingInside(track, owner);
    }
    const CMTime room = owner.timelineDuration - taken - incoming;
    TransitionLimit limit;
    if (kCMTimeZero < incoming) {
        limit.reason = track.kind == TrackKind::Audio ? "It would meet the crossfade coming into the clip."
                                                      : "It would meet the cross dissolve coming into the clip.";
        limit.limitError = EditError::Overlap;
    } else {
        limit.reason = taken == kCMTimeZero ? "A fade cannot be longer than its clip."
                                            : "It would overlap the transition at the clip's other end.";
        limit.limitError = taken == kCMTimeZero ? EditError::InvalidArgument : EditError::Overlap;
    }
    limit.maximumFrames = std::max<std::int64_t>(0, frameIndexAt(room, frameDuration, SnapMode::Floor));
    limit.maximum = limit.maximumFrames > 0 ? timeForFrame(limit.maximumFrames, frameDuration) : kCMTimeZero;
    return limit;
}

std::optional<TransitionSideLimits> refSideLimits(const Project &project, const Sequence &sequenceRef,
                                                         ClipId ownerId, SpanId existing, EditResult &why) {
    const Sequence *sequence = &sequenceRef;
    if (!isPositive(sequence->frameDuration)) {
        why = EditResult::failure(EditError::SequenceNotFound, "The sequence no longer exists.");
        return std::nullopt;
    }
    const Track *track = sequence->trackOfClip(ownerId);
    const Clip *owner = track ? track->find(ownerId) : nullptr;
    if (!owner) {
        why = EditResult::failure(EditError::ClipNotFound, "The clips no longer exist.");
        return std::nullopt;
    }
    const Clip *next = touchingClip(*track, *owner, ClipEdge::Tail);
    if (!next) {
        why = EditResult::failure(EditError::NotAdjacent, "The clips do not meet at a cut on one track.");
        return std::nullopt;
    }
    if (track->locked) {
        why = EditResult::failure(EditError::TrackLocked, "Track “" + track->name + "” is locked.");
        return std::nullopt;
    }
    const TransitionSpan *tail = owner->transitionAt(ClipEdge::Tail);
    if (tail && tail->id != existing) {
        why = EditResult::failure(EditError::AlreadyExists, "This cut already has a transition.");
        return std::nullopt;
    }
    if (existing && !tail) {
        why = EditResult::failure(EditError::TransitionNotFound, "The transition no longer exists.");
        return std::nullopt;
    }
    const CMTime fd = sequence->frameDuration;
    TransitionSideLimits limits;

    // Before the cut: the owner's frames not taken by its fade in or by a dissolve into it, and the
    // next clip's media before its in point.
    CMTime taken = kCMTimeZero;
    EditError roomError = EditError::InvalidArgument;
    std::string roomReason = "A transition cannot be longer than the clips it joins.";
    if (const TransitionSpan *head = owner->transitionAt(ClipEdge::Head)) {
        taken = head->end;
        roomError = EditError::Overlap;
        roomReason = "It would overlap the fade at the clip's start.";
    } else if (const Clip *previous = touchingClip(*track, *owner, ClipEdge::Head)) {
        if (const TransitionSpan *incoming = previous->transitionAt(ClipEdge::Tail); incoming && kCMTimeZero < incoming->end) {
            taken = incoming->end;
            roomError = EditError::Overlap;
            roomReason = "It would overlap the neighbouring transition.";
        }
    }
    const auto ownerLength = ExactTime::from(owner->timelineDuration);
    const auto takenExact = ExactTime::from(taken);
    const std::int64_t roomBefore =
        wholeFrames(ownerLength && takenExact ? ownerLength->minus(*takenExact) : std::nullopt, fd);
    std::int64_t mediaBefore = wholeFrames(std::nullopt, fd);
    if (!next->isStill) {
        const auto in = ExactTime::from(next->sourceIn);
        mediaBefore = wholeFrames(in ? in->dividedBy(next->speedRatio()) : std::nullopt, fd);
    }
    limits.maxBeforeFrames = std::min(roomBefore, mediaBefore);
    if (roomBefore <= mediaBefore) {
        limits.beforeError = roomError;
        limits.beforeReason = roomReason;
    } else {
        limits.beforeError = EditError::InsufficientHandles;
        limits.beforeReason = quotedMediaName(project, *next) + " has no more media before its in point.";
        limits.beforeLimitingClip = next->id;
    }

    // After the cut: the next clip's frames not taken by its own tail transition, and the owner's
    // media after its out point.
    CMTime nextTaken = kCMTimeZero;
    EditError nextError = EditError::InvalidArgument;
    std::string nextReason = "A transition cannot be longer than the clips it joins.";
    if (const TransitionSpan *nextTail = next->transitionAt(ClipEdge::Tail)) {
        nextTaken = -nextTail->start;
        nextError = EditError::Overlap;
        nextReason = "It would overlap the neighbouring transition.";
    }
    const auto nextLength = ExactTime::from(next->timelineDuration);
    const auto nextTakenExact = ExactTime::from(nextTaken);
    const std::int64_t roomAfter =
        wholeFrames(nextLength && nextTakenExact ? nextLength->minus(*nextTakenExact) : std::nullopt, fd);
    std::int64_t mediaAfter = wholeFrames(std::nullopt, fd);
    if (!owner->isStill) {
        const MediaAsset *asset = project.findAsset(owner->assetId);
        const auto out = owner->exactSourceOut();
        const auto end = asset ? ExactTime::from(mediaEndFor(*asset, track->kind)) : std::nullopt;
        const auto rest = out && end ? end->minus(*out) : std::nullopt;
        mediaAfter = wholeFrames(rest ? rest->dividedBy(owner->speedRatio()) : std::optional<ExactTime>(ExactTime{}), fd);
    }
    limits.maxAfterFrames = std::min(roomAfter, mediaAfter);
    if (roomAfter <= mediaAfter) {
        limits.afterError = nextError;
        limits.afterReason = nextReason;
    } else {
        limits.afterError = EditError::InsufficientHandles;
        limits.afterReason = quotedMediaName(project, *owner) + " has no more media after its out point.";
        limits.afterLimitingClip = owner->id;
    }
    why = EditResult::success();
    return limits;
}

std::optional<TransitionIssue> refCheck(const Project &project, const Track &track, const Clip &owner,
                                                   const TransitionSpan &span, CMTime frameDuration) {
    using K = TransitionIssueKind;
    const std::string where = "transition " + std::to_string(span.id.value());
    if (track.kind == TrackKind::Audio && span.kind != TransitionKind::CrossDissolve) {
        return TransitionIssue{K::Structure, where + ": an audio transition is a crossfade or a fade, not a " +
                                                 displayNameOf(span.kind)};
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
    const TransitionSpan *other = owner.transitionAt(span.edge == ClipEdge::Head ? ClipEdge::Tail : ClipEdge::Head);
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
    if (const TransitionSpan *partnerTail = partner->transitionAt(ClipEdge::Tail)) {
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

void refPrune(Sequence &sequence, const Project &project, std::vector<std::string> *notes) {
    const std::string where = "sequence " + std::to_string(sequence.id.value());
    for (std::vector<Track> *list : {&sequence.videoTracks, &sequence.audioTracks}) {
        for (Track &track : *list) {
            for (std::size_t i = track.clips.size(); i-- > 0;) {
                Clip &clip = track.clips[i];
                for (const ClipEdge edge : {ClipEdge::Tail, ClipEdge::Head}) {
                    const TransitionSpan *span = clip.transitionAt(edge);
                    if (span == nullptr) {
                        continue;
                    }
                    auto issue = refCheck(project, track, clip, *span, sequence.frameDuration);
                    if (issue && issue->kind == TransitionIssueKind::Overlap && edge == ClipEdge::Tail &&
                        kCMTimeZero < span->end && i + 1 < track.clips.size() &&
                        track.clips[i + 1].timelineStart == clip.timelineEnd()) {
                        // The next clip's fade out meets this dissolve: shorten it, if that is all.
                        Clip &next = track.clips[i + 1];
                        TransitionSpan *fade = next.transitionAt(ClipEdge::Tail);
                        const auto room = checkedSubtract(next.timelineDuration, span->end);
                        if (fade != nullptr && fade->end == kCMTimeZero && room) {
                            const Clip before = next;
                            const SpanId fadeId = fade->id;
                            const auto start = checkedNegate(maxTime(*room, kCMTimeZero));
                            const bool kept = start && kCMTimeZero < *room;
                            if (kept) {
                                fade->start = *start;
                            } else {
                                std::erase_if(next.transitions, [fadeId](const TransitionSpan &s) { return s.id == fadeId; });
                            }
                            issue = refCheck(project, track, clip, *span, sequence.frameDuration);
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
                        std::erase_if(clip.transitions, [id](const TransitionSpan &s) { return s.id == id; });
                    }
                }
            }
        }
    }
}

EditResult refSetClipFade(Clip &clip, const Track &track, ClipEdge edge, CMTime length, IdGenerator &ids) {
    const char *which = edge == ClipEdge::Head ? "fade in" : "fade out";
    if (EditResult r = requireExact(length, which); !r) {
        return r;
    }
    if (length < kCMTimeZero || clip.timelineDuration < length) {
        return EditResult::failure(EditError::InvalidTime, std::string("a ") + which + " of " + describe(length) +
                                                               " does not fit clip " + idString(clip.id.value()) +
                                                               " (" + describe(clip.timelineDuration) + ")");
    }
    TransitionSpan *span = clip.transitionAt(edge);
    if (edge == ClipEdge::Tail && span != nullptr && kCMTimeZero < span->end) {
        if (length == kCMTimeZero) {
            return EditResult::success(); // a cross dissolve is not a fade
        }
        return EditResult::failure(EditError::InvalidArgument, "clip " + idString(clip.id.value()) +
                                                                   " ends in a crossfade, which replaces a fade out "
                                                                   "there");
    }
    if (length == kCMTimeZero) {
        if (span != nullptr) {
            const SpanId id = span->id;
            std::erase_if(clip.transitions, [id](const TransitionSpan &s) { return s.id == id; });
        }
        return EditResult::success();
    }
    if (edge == ClipEdge::Head && span == nullptr && touchingClip(track, clip, ClipEdge::Head) != nullptr) {
        return EditResult::failure(EditError::InvalidArgument,
                                   "another clip touches the start of clip " + idString(clip.id.value()) +
                                       ", so the cut belongs to that clip: use a crossfade there instead of a fade in");
    }
    if (edge == ClipEdge::Tail) {
        // A cross dissolve coming into the clip keeps its part inside it: the fade out has the rest.
        const CMTime incoming = incomingInside(track, clip);
        const auto room = checkedSubtract(clip.timelineDuration, incoming);
        if (kCMTimeZero < incoming && (!room || *room < length)) {
            // Overlap, as the facade's fade limit reports the same condition (review L9).
            return EditResult::failure(
                EditError::Overlap,
                "a fade out of " + describe(length) + " would meet the " +
                    (track.kind == TrackKind::Audio ? "crossfade" : "cross dissolve") + " coming into clip " +
                    idString(clip.id.value()) + ": it has room for " + describe(room ? maxTime(*room, kCMTimeZero)
                                                                                     : kCMTimeZero));
        }
    }
    const CMTime other = edge == ClipEdge::Head ? [&] {
        const TransitionSpan *tail = clip.transitionAt(ClipEdge::Tail);
        return tail != nullptr ? -tail->start : kCMTimeZero;
    }()
                                                : clipFadeLength(clip, ClipEdge::Head);
    const auto total = ExactTime::from(length) && ExactTime::from(other)
                           ? ExactTime::from(length)->plus(*ExactTime::from(other))
                           : std::nullopt;
    if (!total || total->compare(clip.timelineDuration) > 0) {
        return EditResult::failure(EditError::Overlap, "the fade in and fade out overlap: together they are "
                                                       "longer than the clip (" +
                                                           describe(clip.timelineDuration) + ")");
    }
    const auto start = checkedNegate(length);
    if (!start) {
        return notRepresentable(clip.id, clip.timelineStart);
    }
    if (span == nullptr) {
        TransitionSpan fade;
        fade.id = ids.make<SpanId>();
        fade.edge = edge;
        clip.transitions.push_back(fade);
        span = &clip.transitions.back();
    }
    if (edge == ClipEdge::Head) {
        span->start = kCMTimeZero;
        span->end = length;
    } else {
        span->start = *start;
        span->end = kCMTimeZero;
    }
    clip.sortSpans();
    return EditResult::success();
}

// The lane-0 part of Clip::fitSpans before the rules had one owner (the clip's effect spans aside: the
// clips this test retimes have none).
RetimeResult refFitFades(Clip &clip, ClipEdge editedEdge) {
    const CMTime timelineDuration = clip.timelineDuration;
    std::vector<TransitionSpan> &transitions = clip.transitions;
    // Lane-0 fades fit the clip: a head fade and the inside part of the tail span together at
    // most its length. Fades give way to a cross dissolve (which is never shortened here); between
    // two fades the one at the edited edge gives way first.
    std::vector<TransitionSpan> fittedTransitions = transitions;
    TransitionSpan *head = nullptr;
    TransitionSpan *tail = nullptr;
    for (TransitionSpan &span : fittedTransitions) {
        (span.edge == ClipEdge::Head ? head : tail) = &span;
    }
    const CMTime length = maxTime(timelineDuration, kCMTimeZero);
    const bool tailIsFade = tail != nullptr && tail->end == kCMTimeZero;
    CMTime headLength = head != nullptr ? minTime(head->end, length) : kCMTimeZero;
    CMTime tailInside = kCMTimeZero;
    if (tail != nullptr) {
        const auto inside = checkedNegate(tail->start);
        if (!inside) {
            return RetimeResult::NotRepresentable;
        }
        tailInside = tailIsFade ? minTime(*inside, length) : *inside;
    }
    const auto together = ExactTime::from(headLength) && ExactTime::from(tailInside)
                              ? ExactTime::from(headLength)->plus(*ExactTime::from(tailInside))
                              : std::nullopt;
    if (!together) {
        return RetimeResult::NotRepresentable;
    }
    if (together->compare(length) > 0) {
        const bool headGivesWay = head != nullptr && (!tailIsFade || editedEdge == ClipEdge::Head);
        if (headGivesWay) {
            const auto rest = checkedSubtract(length, tailInside);
            if (!rest) {
                return RetimeResult::NotRepresentable;
            }
            headLength = maxTime(*rest, kCMTimeZero);
        } else if (tailIsFade) {
            const auto rest = checkedSubtract(length, headLength);
            if (!rest) {
                return RetimeResult::NotRepresentable;
            }
            tailInside = maxTime(*rest, kCMTimeZero);
        }
    }
    if (head != nullptr) {
        head->end = headLength;
    }
    if (tailIsFade) {
        const auto start = checkedNegate(tailInside);
        if (!start) {
            return RetimeResult::NotRepresentable;
        }
        tail->start = *start;
    }
    std::erase_if(fittedTransitions, [](const TransitionSpan &span) {
        return !(span.start < span.end); // a fade shortened to nothing
    });
    transitions = std::move(fittedTransitions);
    return RetimeResult::Ok;
}

// The frame-rate conform's fade fitting (SetSequenceFormat): shorter by a frame while the fade is too
// long for its clip or meets its other transition, as checkTransitionSpan reports it. The frames kept.
std::int64_t refConformFadeFrames(const Project &project, Track &track, Clip &clip, ClipEdge edge,
                                  std::int64_t wanted, CMTime newFd) {
    TransitionSpan &span = *clip.transitionAt(edge);
    std::int64_t frames = wanted;
    setTransitionFrames(span, edge == ClipEdge::Tail ? frames : 0, edge == ClipEdge::Head ? frames : 0, newFd);
    auto issue = refCheck(project, track, clip, span, newFd);
    auto lengthIssue = [&issue] {
        return issue && (issue->kind == TransitionIssueKind::TooLong || issue->kind == TransitionIssueKind::Overlap);
    };
    while (frames > 0 && lengthIssue()) {
        --frames;
        if (frames > 0) {
            setTransitionFrames(span, edge == ClipEdge::Tail ? frames : 0, edge == ClipEdge::Head ? frames : 0, newFd);
            issue = refCheck(project, track, clip, span, newFd);
        }
    }
    return frames;
}

} // namespace ref

namespace {

// A random track (V1 or A1, `seed`) of up to four clips, mostly touching, with random transitions valid or
// not: fades of whole frames or of samples, cross dissolves of random shares, wipes (also on audio, which
// is invalid), stills, speeds, reversed clips and in points near both ends of the media.
struct RandomTrack : Fixture {
    TrackId trackId;
    std::vector<ClipId> clips;

    explicit RandomTrack(std::uint32_t seed) {
        std::mt19937 rng(seed);
        auto pick = [&](std::uint32_t n) { return static_cast<std::int64_t>(rng() % n); };
        const bool video = pick(2) == 0;
        trackId = video ? v1 : a1;
        std::int64_t start = pick(10);
        const int count = 1 + static_cast<int>(pick(4));
        for (int i = 0; i < count; ++i) {
            const std::int64_t duration = 1 + pick(40);
            AssetId asset = av30;
            if (video && pick(6) == 0) {
                asset = still;
            } else if (!video && pick(6) == 0) {
                asset = audioOnly;
            }
            // In points: at the start of the media, a little in, or near its end (av30: 1800 frames).
            const std::int64_t in = pick(3) == 0 ? pick(4) : pick(3) == 0 ? 1750 + pick(40) : 100 + pick(500);
            const double speed = pick(5) == 0 ? 2.0 : pick(5) == 0 ? 0.5 : 1.0;
            const ClipId id = addClip(trackId, asset, start, duration, in, speed);
            Clip &clip = *sequence().findClip(id);
            if (!clip.isStill && pick(8) == 0) {
                clip.reversed = true;
            }
            clips.push_back(id);
            start += duration + (pick(10) < 7 ? 0 : 1 + pick(5));
        }
        std::uint64_t nextSpan = 5000;
        for (std::size_t i = 0; i < clips.size(); ++i) {
            Clip &clip = *sequence().findClip(clips[i]);
            const bool touched = i + 1 < clips.size() && sequence().findClip(clips[i + 1])->timelineStart == clip.timelineEnd();
            auto fadeLength = [&] {
                return !video && pick(5) == 0 ? CMTimeMake(1 + pick(48000), 48000) : f30(1 + pick(35));
            };
            if (pick(10) < 3) {
                TransitionSpan head;
                head.id = SpanId{nextSpan++};
                head.edge = ClipEdge::Head;
                head.end = fadeLength();
                clip.transitions.push_back(head);
            }
            if (pick(10) < 6) {
                TransitionSpan tail;
                tail.id = SpanId{nextSpan++};
                tail.edge = ClipEdge::Tail;
                if (touched && pick(3) != 0) {
                    tail.start = -f30(pick(22));
                    tail.end = f30(1 + pick(22));
                } else {
                    tail.start = -fadeLength();
                    tail.end = kCMTimeZero;
                }
                if (pick(6) == 0) {
                    tail.kind = TransitionKind::WipeLeft;
                }
                clip.transitions.push_back(tail);
            }
            clip.sortSpans();
        }
        project.ids.reserveThrough(nextSpan + 1);
    }

    const Track &theTrack() const {
        return *sequence().findTrack(trackId);
    }
};

constexpr std::uint32_t kTracks = 3000;

bool sameLimit(const TransitionLimit &a, const TransitionLimit &b) {
    return a.maximumFrames == b.maximumFrames && identical(a.maximum, b.maximum) && a.limitError == b.limitError &&
           a.reason == b.reason && a.limitingClip == b.limitingClip;
}

// A clip with a fade in and a dissolve coming into it: invalid (the cut belongs to the other clip), the one
// state where the dissolve's room before its cut now counts both (it counted the fade in alone).
bool fadeInOnTouchedClip(const Track &track, const Clip &clip) {
    return clip.transitionAt(ClipEdge::Head) != nullptr && TransitionRules::incomingPartInside(track, clip) > kCMTimeZero;
}

} // namespace

TEST_CASE("TransitionRules: fadeLimit gives what it gave") {
    for (std::uint32_t seed = 1; seed <= kTracks; ++seed) {
        CAPTURE(seed);
        const RandomTrack fx(seed);
        for (const ClipId id : fx.clips) {
            for (const ClipEdge edge : {ClipEdge::Head, ClipEdge::Tail}) {
                const TransitionLimit now = fadeLimit(fx.clip(id), fx.theTrack(), edge, f30(1));
                const TransitionLimit before = ref::refFadeLimit(fx.clip(id), fx.theTrack(), edge, f30(1));
                REQUIRE_MESSAGE(sameLimit(now, before), doctest::String((now.reason + " / " + before.reason).c_str()));
            }
        }
    }
}

TEST_CASE("TransitionRules: transitionSideLimits gives what it gave") {
    std::size_t compared = 0;
    for (std::uint32_t seed = 1; seed <= kTracks; ++seed) {
        CAPTURE(seed);
        const RandomTrack fx(seed);
        for (const ClipId id : fx.clips) {
            const TransitionSpan *tail = fx.clip(id).transitionAt(ClipEdge::Tail);
            for (const SpanId existing : {tail != nullptr ? tail->id : SpanId{}, SpanId{}}) {
                EditResult whyNow = EditResult::success();
                EditResult whyBefore = EditResult::success();
                const auto now = transitionSideLimits(fx.project, fx.sequence(), id, existing, whyNow);
                const auto before = ref::refSideLimits(fx.project, fx.sequence(), id, existing, whyBefore);
                REQUIRE(now.has_value() == before.has_value());
                CHECK(whyNow.error == whyBefore.error);
                CHECK(whyNow.message == whyBefore.message);
                if (!now) {
                    continue;
                }
                ++compared;
                CHECK(now->maxAfterFrames == before->maxAfterFrames);
                CHECK(now->afterError == before->afterError);
                CHECK(now->afterReason == before->afterReason);
                CHECK(now->afterLimitingClip == before->afterLimitingClip);
                if (fadeInOnTouchedClip(fx.theTrack(), fx.clip(id))) {
                    // Invalid: the fade in goes (Touching, or an earlier problem) wherever the sequence is checked.
                    CHECK(touchingClip(fx.theTrack(), fx.clip(id), ClipEdge::Head) != nullptr);
                    CHECK(checkTransitionSpan(fx.project, fx.theTrack(), fx.clip(id),
                                              *fx.clip(id).transitionAt(ClipEdge::Head), f30(1))
                              .has_value());
                    CHECK(now->maxBeforeFrames <= before->maxBeforeFrames);
                    continue;
                }
                CHECK(now->maxBeforeFrames == before->maxBeforeFrames);
                CHECK(now->beforeError == before->beforeError);
                CHECK(now->beforeReason == before->beforeReason);
                CHECK(now->beforeLimitingClip == before->beforeLimitingClip);
            }
        }
    }
    CHECK(compared > 1000);
}

TEST_CASE("TransitionRules: checkTransitionSpan reports what it reported") {
    std::size_t issues = 0;
    std::size_t valid = 0;
    for (std::uint32_t seed = 1; seed <= kTracks; ++seed) {
        CAPTURE(seed);
        const RandomTrack fx(seed);
        for (const ClipId id : fx.clips) {
            for (const TransitionSpan &span : fx.clip(id).transitions) {
                const auto now = checkTransitionSpan(fx.project, fx.theTrack(), fx.clip(id), span, f30(1));
                const auto before = ref::refCheck(fx.project, fx.theTrack(), fx.clip(id), span, f30(1));
                REQUIRE(now.has_value() == before.has_value());
                if (now) {
                    ++issues;
                    CHECK(now->kind == before->kind);
                    CHECK(now->message == before->message);
                    CHECK(now->clip == before->clip);
                } else {
                    ++valid;
                }
            }
        }
    }
    MESSAGE("transitions checked: " << issues << " with an issue, " << valid << " valid");
    CHECK(issues > 1000);
    CHECK(valid > 1000);
}

TEST_CASE("TransitionRules: pruneInvalidTransitions removes and shortens what it did") {
    for (std::uint32_t seed = 1; seed <= kTracks; ++seed) {
        CAPTURE(seed);
        const RandomTrack fx(seed);
        Sequence now = fx.sequence();
        Sequence before = fx.sequence();
        std::vector<std::string> notesNow;
        std::vector<std::string> notesBefore;
        pruneInvalidTransitions(now, fx.project, &notesNow);
        ref::refPrune(before, fx.project, &notesBefore);
        CHECK(now == before);
        CHECK(notesNow == notesBefore);

    }
}

TEST_CASE("TransitionRules: setClipFade accepts, refuses and fits as it did") {
    for (std::uint32_t seed = 1; seed <= kTracks; ++seed) {
        CAPTURE(seed);
        const RandomTrack fx(seed);
        std::mt19937 rng(seed * 7919u);
        for (const ClipId id : fx.clips) {
            for (const ClipEdge edge : {ClipEdge::Head, ClipEdge::Tail}) {
                const std::int64_t frames = static_cast<std::int64_t>(rng() % 45);
                CMTime length = rng() % 6 == 0 ? CMTimeMake(static_cast<std::int64_t>(rng() % 96000), 48000) : f30(frames);
                if (rng() % 20 == 0) {
                    length.flags |= kCMTimeFlags_HasBeenRounded;
                }
                Fixture copyNow = fx;
                Fixture copyBefore = fx;
                IdGenerator idsNow = fx.project.ids;
                IdGenerator idsBefore = fx.project.ids;
                const EditResult now = setClipFade(*copyNow.sequence().findClip(id), copyNow.track(fx.trackId), edge,
                                                   length, idsNow);
                const EditResult before = ref::refSetClipFade(*copyBefore.sequence().findClip(id),
                                                              copyBefore.track(fx.trackId), edge, length, idsBefore);
                CHECK(now.error == before.error);
                CHECK(now.message == before.message);
                CHECK(copyNow.clip(id) == copyBefore.clip(id));
                CHECK(idsNow.nextValue() == idsBefore.nextValue());
            }
        }
    }
}

TEST_CASE("TransitionRules: a trim fits a clip's own fades as it did (Clip::fitSpans)") {
    for (std::uint32_t seed = 1; seed <= kTracks; ++seed) {
        CAPTURE(seed);
        const RandomTrack fx(seed);
        std::mt19937 rng(seed * 104729u);
        for (const ClipId id : fx.clips) {
            const Clip &clip = fx.clip(id);
            const std::int64_t frames = frameIndexAt(clip.timelineDuration, f30(1), SnapMode::Round);
            // The end: anywhere from a frame after the start to 20 frames past the end.
            const CMTime end = clip.timelineStart + f30(1 + static_cast<std::int64_t>(rng() % (frames + 20)));
            Clip now = clip;
            const RetimeResult endNow = now.setTimelineEnd(end);
            Clip before = clip;
            RetimeResult endBefore = RetimeResult::Ok;
            if (const auto duration = checkedSubtract(end, before.timelineStart)) {
                before.timelineDuration = *duration;
                if (before.isStill) {
                    before.sourceIn = kCMTimeZero;
                }
                endBefore = ref::refFitFades(before, ClipEdge::Tail);
            } else {
                endBefore = RetimeResult::NotRepresentable;
            }
            REQUIRE(endNow == endBefore);
            if (endNow == RetimeResult::Ok) {
                CHECK(now.transitions == before.transitions);
            }
            // The start: up to 20 frames before it (where the media allows) to a frame before the end.
            const std::int64_t back = static_cast<std::int64_t>(rng() % 21);
            const CMTime startAt = clip.timelineStart - f30(back) + f30(static_cast<std::int64_t>(rng() % (frames + back)));
            Clip moved = clip;
            const RetimeResult startNow = moved.setTimelineStartKeepingEnd(startAt);
            Clip movedBefore = clip;
            RetimeResult startBefore = RetimeResult::Ok;
            const auto delta = checkedSubtract(startAt, movedBefore.timelineStart);
            const auto duration = delta ? checkedSubtract(movedBefore.timelineDuration, *delta) : std::nullopt;
            const auto scaled = delta && !movedBefore.isStill ? checkedScale(*delta, movedBefore.speed) : delta;
            const auto in = scaled && !movedBefore.isStill ? checkedAdd(movedBefore.sourceIn, *scaled) : std::optional<CMTime>(movedBefore.sourceIn);
            if (!duration || !in || !isExactModelTime(*in)) {
                startBefore = RetimeResult::NotRepresentable;
            } else {
                movedBefore.sourceIn = *in;
                movedBefore.timelineStart = startAt;
                movedBefore.timelineDuration = *duration;
                startBefore = ref::refFitFades(movedBefore, ClipEdge::Head);
            }
            REQUIRE(startNow == startBefore);
            if (startNow == RetimeResult::Ok) {
                CHECK(moved.transitions == movedBefore.transitions);
            }
        }
    }
}

TEST_CASE("TransitionRules: the frame-rate conform keeps the fades it kept") {
    const CMTime rates[] = {CMTimeMake(1, 25), CMTimeMake(1001, 30000), CMTimeMake(1, 24), CMTimeMake(1, 60)};
    for (std::uint32_t seed = 1; seed <= kTracks; ++seed) {
        CAPTURE(seed);
        const RandomTrack fx(seed);
        std::mt19937 rng(seed * 1299709u);
        for (const ClipId id : fx.clips) {
            for (const ClipEdge edge : {ClipEdge::Head, ClipEdge::Tail}) {
                const TransitionSpan *span = fx.clip(id).transitionAt(edge);
                if (span == nullptr || (edge == ClipEdge::Tail && kCMTimeZero < span->end)) {
                    continue; // fades only (the conform fits dissolves with transitionSideLimits)
                }
                const CMTime fd = rates[rng() % 4];
                const std::int64_t wanted = 1 + static_cast<std::int64_t>(rng() % 40);
                Fixture before = fx;
                Track &beforeTrack = before.track(fx.trackId);
                Clip &beforeClip = *before.sequence().findClip(id);
                std::int64_t kept = ref::refConformFadeFrames(before.project, beforeTrack, beforeClip, edge, wanted, fd);
                if (kept > 0 && ref::refCheck(before.project, beforeTrack, beforeClip, *beforeClip.transitionAt(edge), fd)) {
                    kept = 0; // not a valid fade at any length (another clip touches a fade in's start...)
                }
                Fixture now = fx;
                Track &nowTrack = now.track(fx.trackId);
                Clip &nowClip = *now.sequence().findClip(id);
                TransitionSpan &nowSpan = *nowClip.transitionAt(edge);
                std::int64_t frames = std::min(wanted, TransitionRules::conformFadeFrames(nowClip, edge, fd));
                if (frames > 0) {
                    ref::setTransitionFrames(nowSpan, edge == ClipEdge::Tail ? frames : 0, edge == ClipEdge::Head ? frames : 0, fd);
                    if (checkTransitionSpan(now.project, nowTrack, nowClip, nowSpan, fd)) {
                        frames = 0;
                    }
                }
                CHECK(frames == kept);
            }
        }
    }
}

namespace {

CMTime f25(std::int64_t frames) {
    return CMTimeMake(frames, 25);
}

SequenceFormat at25fps(const Sequence &sequence) {
    SequenceFormat format = sequence.format();
    format.frameDuration = CMTimeMake(1, 25);
    return format;
}

// V1: A [0, 30) with a fade in of `fadeIn` frames and a cross dissolve of `before` + `after` frames into
// B [30, 90) (B 300 frames into its media, so the dissolve has its handles).
struct FadeInBesideDissolve : Fixture {
    ClipId a, b;
    SpanId fadeIn, dissolve;
    FadeInBesideDissolve(std::int64_t fadeFrames, std::int64_t before, std::int64_t after) {
        a = addClip(v1, av30, 0, 30, 30);
        b = addClip(v1, av30, 30, 60, 300);
        fadeIn = addFade(a, ClipEdge::Head, f30(fadeFrames));
        dissolve = addTailTransition(a, before, after);
        requireValid();
    }
};

// V1: A [0, 30) with a cross dissolve of `before` + `after` frames into B [30, 60), which fades out over
// `fadeOut` frames; both clips have their handles.
struct DissolveIntoFadeOut : Fixture {
    ClipId a, b;
    SpanId dissolve, fadeOut;
    DissolveIntoFadeOut(std::int64_t before, std::int64_t after, std::int64_t fadeFrames) {
        a = addClip(v1, av30, 0, 30, 30);
        b = addClip(v1, av30, 30, 30, 300);
        dissolve = addTailTransition(a, before, after);
        fadeOut = addFade(b, ClipEdge::Tail, f30(fadeFrames));
    }
};

} // namespace

// D1 (open-findings, round 2, item 5; the user's decision of 2026-10-02): when a clip's fade in and its tail
// dissolve no longer fit it, the fade gives way and the dissolve keeps its length, after a trim
// (Clip::fitSpans) and in the frame-rate conform alike.
TEST_CASE("TransitionRules: D1, a fade in beside a tail dissolve: a trim and the conform both shorten the fade") {
    SUBCASE("a trim of the clip's start") {
        FadeInBesideDissolve fx(10, 10, 10);
        Clip trimmed = fx.clip(fx.a);
        REQUIRE(trimmed.setTimelineStartKeepingEnd(f30(15)) == RetimeResult::Ok); // 15 frames left
        CHECK(clipFadeLength(trimmed, ClipEdge::Head) == f30(5));                 // the fade gave way
        CHECK(trimmed.transitionAt(ClipEdge::Tail)->start == -f30(10));            // the dissolve kept its share
    }
    SUBCASE("the frame-rate conform") {
        // 15 + 15 of A's 30 frames at 30 fps; transitions keep their frame counts, A is 25 frames at 25 fps.
        FadeInBesideDissolve fx(15, 15, 15);
        SetSequenceFormat command(fx.seq, at25fps(fx.sequence()));
        applyReversible(fx.project, command);
        const Clip &a = fx.clip(fx.a);
        REQUIRE(a.timelineDuration == f25(25));
        CHECK(clipFadeLength(a, ClipEdge::Head) == f25(10));      // the fade gave way: 25 - 15
        CHECK(a.transitionAt(ClipEdge::Tail)->start == -f25(15)); // the dissolve kept its 15 + 15 frames
        CHECK(a.transitionAt(ClipEdge::Tail)->end == f25(15));
        CHECK(command.report().transitionsShortened == std::vector<SpanId>{fx.fadeIn});
        fx.requireValid();
    }
}

// D2 (the same decision): when a cross dissolve into a clip and the clip's fade out no longer fit it, the
// fade out gives way, in pruning (every edit, loading) and in the frame-rate conform alike.
TEST_CASE("TransitionRules: D2, a dissolve into a clip that fades out: pruning and the conform both shorten the fade") {
    SUBCASE("pruning") {
        DissolveIntoFadeOut fx(10, 15, 20); // 15 + 20 of B's 30 frames
        std::vector<std::string> notes;
        pruneInvalidTransitions(fx.sequence(), fx.project, &notes);
        CHECK(clipFadeLength(fx.clip(fx.b), ClipEdge::Tail) == f30(15)); // the fade gave way
        CHECK(fx.clip(fx.a).transitionAt(ClipEdge::Tail)->end == f30(15));
        REQUIRE(notes.size() == 1);
        CHECK(notes[0].find("the fade out (transition " + std::to_string(fx.fadeOut.value()) + ") was shortened") !=
              std::string::npos);
        fx.requireValid();
    }
    SUBCASE("the frame-rate conform") {
        DissolveIntoFadeOut fx(15, 15, 15); // 15 + 15 of B's 30 frames at 30 fps; B is 25 frames at 25 fps
        fx.requireValid();
        SetSequenceFormat command(fx.seq, at25fps(fx.sequence()));
        applyReversible(fx.project, command);
        const Clip &b = fx.clip(fx.b);
        REQUIRE(b.timelineDuration == f25(25));
        CHECK(clipFadeLength(b, ClipEdge::Tail) == f25(10));              // the fade gave way: 25 - 15
        CHECK(fx.clip(fx.a).transitionAt(ClipEdge::Tail)->end == f25(15)); // the dissolve kept its 15 + 15 frames
        CHECK(fx.clip(fx.a).transitionAt(ClipEdge::Tail)->start == -f25(15));
        CHECK(command.report().transitionsShortened == std::vector<SpanId>{fx.fadeOut});
        fx.requireValid();
    }
}

// The one rule per role in the conform: a fade in beside its clip's tail dissolve, a fade out beside a
// dissolve coming into its clip; on picture and on sound; shortened or removed, with the sentence saying
// why, and undone exactly.
TEST_CASE("TransitionRules: the frame-rate conform fits each fade in what the dissolves leave") {
    auto sentenceFor = [](const std::vector<std::string> &sentences, const std::string &start) {
        for (const std::string &s : sentences) {
            if (s.rfind(start, 0) == 0) {
                return s;
            }
        }
        return std::string();
    };
    SUBCASE("a fade in gives way to its clip's tail dissolve") {
        FadeInBesideDissolve fx(15, 15, 15);
        SetSequenceFormat command(fx.seq, at25fps(fx.sequence()));
        applyReversible(fx.project, command); // applies, checks the undo, applies again
        CHECK(sentenceFor(command.report().sentences, "The fade in at the start of") ==
              "The fade in at the start of “av30.mov” is shortened from 15 frames to 10 frames: it gives way to the "
              "cross dissolve at the clip's end.");
    }
    SUBCASE("a fade in the dissolve leaves no frame for is removed") {
        FadeInBesideDissolve fx(5, 25, 5); // the dissolve takes 25 of A's 30 frames; A becomes 25 frames
        SetSequenceFormat command(fx.seq, at25fps(fx.sequence()));
        applyReversible(fx.project, command);
        const Clip &a = fx.clip(fx.a);
        CHECK(a.transitionAt(ClipEdge::Head) == nullptr);
        CHECK(a.transitionAt(ClipEdge::Tail)->start == -f25(25));
        CHECK(a.transitionAt(ClipEdge::Tail)->end == f25(5));
        CHECK(command.report().transitionsRemoved == std::vector<SpanId>{fx.fadeIn});
        CHECK(command.report().transitionsShortened.empty());
        CHECK(sentenceFor(command.report().sentences, "The fade in at the start of") ==
              "The fade in at the start of “av30.mov” is removed: not one frame of it fits at 25 fps (it gives way to "
              "the cross dissolve at the clip's end).");
        fx.requireValid();
    }
    SUBCASE("a fade out on sound gives way to a crossfade coming into its clip") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.a1, fx.av30, 0, 30, 30);
        const ClipId b = fx.addClip(fx.a1, fx.av30, 30, 30, 300);
        const SpanId crossfade = fx.addTailTransition(a, 15, 20);
        const SpanId fadeOut = fx.addFade(b, ClipEdge::Tail, f30(10));
        fx.requireValid();
        SetSequenceFormat command(fx.seq, at25fps(fx.sequence()));
        applyReversible(fx.project, command);
        CHECK(fx.clip(a).transitionAt(ClipEdge::Tail)->id == crossfade);
        CHECK(fx.clip(a).transitionAt(ClipEdge::Tail)->end == f25(20)); // the crossfade kept its frames
        CHECK(clipFadeLength(fx.clip(b), ClipEdge::Tail) == f25(5));    // B is 25 frames: 25 - 20
        CHECK(command.report().transitionsShortened == std::vector<SpanId>{fadeOut});
        CHECK(sentenceFor(command.report().sentences, "The fade out at the end of") ==
              "The fade out at the end of “av30.mov” is shortened from 10 frames to 5 frames: it gives way to the "
              "crossfade coming into the clip.");
        fx.requireValid();
    }
    SUBCASE("a fade out the dissolve leaves no frame for is removed; the fade in still comes first") {
        // C, apart from the cut, keeps the rule between a clip's two fades: its fade out gives way to its fade in.
        DissolveIntoFadeOut fx(5, 25, 5); // the dissolve takes 25 of B's frames; B becomes 25 frames
        const ClipId c = fx.addClip(fx.v1, fx.av30, 100, 30, 30);
        fx.addFade(c, ClipEdge::Head, f30(20));
        const SpanId cOut = fx.addFade(c, ClipEdge::Tail, f30(10));
        fx.requireValid();
        SetSequenceFormat command(fx.seq, at25fps(fx.sequence()));
        applyReversible(fx.project, command);
        CHECK(fx.clip(fx.b).transitionAt(ClipEdge::Tail) == nullptr);
        CHECK(fx.clip(fx.a).transitionAt(ClipEdge::Tail)->end == f25(25));
        CHECK(clipFadeLength(fx.clip(c), ClipEdge::Head) == f25(20));
        CHECK(clipFadeLength(fx.clip(c), ClipEdge::Tail) == f25(5)); // C is 25 frames: 25 - 20
        CHECK(command.report().transitionsRemoved == std::vector<SpanId>{fx.fadeOut});
        CHECK(command.report().transitionsShortened == std::vector<SpanId>{cOut});
        CHECK(sentenceFor(command.report().sentences, "The fade out at the end of “av30.mov” is removed") ==
              "The fade out at the end of “av30.mov” is removed: not one frame of it fits at 25 fps (it gives way to "
              "the cross dissolve coming into the clip).");
        fx.requireValid();
    }
}

// A fade shorter than half a frame of the new rate keeps one frame, at the edge it is on.
TEST_CASE("TransitionRules: the frame-rate conform keeps a sub-frame fade as one frame at its own edge") {
    for (const ClipEdge edge : {ClipEdge::Head, ClipEdge::Tail}) {
        CAPTURE(edge == ClipEdge::Head);
        Fixture fx;
        const ClipId a = fx.addClip(fx.a1, fx.av30, 0, 30, 30);
        const SpanId fade = fx.addFade(a, edge, CMTimeMake(100, 48000)); // 100 samples
        fx.requireValid();
        SetSequenceFormat command(fx.seq, at25fps(fx.sequence()));
        applyReversible(fx.project, command);
        const TransitionSpan *span = fx.clip(a).transitionAt(edge);
        REQUIRE(span != nullptr);
        CHECK(span->id == fade);
        CHECK(clipFadeLength(fx.clip(a), edge) == f25(1));
        CHECK(span->start == (edge == ClipEdge::Head ? kCMTimeZero : -f25(1)));
        CHECK(span->end == (edge == ClipEdge::Head ? f25(1) : kCMTimeZero));
        fx.requireValid();
    }
}

TEST_CASE("TransitionRules: edgeRoom's parts, limits, limiting clips and reasons") {
    SUBCASE("a fade in beside a fade out") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
        fx.addFade(a, ClipEdge::Tail, f30(20));
        const EdgeRoom room =
            TransitionRules::edgeRoom(fx.project, fx.track(fx.v1), fx.clip(a), ClipEdge::Head, TransitionShape::Fade, f30(1));
        CHECK(room.inside.length == f30(60));
        CHECK(room.inside.otherEdge == f30(20));
        CHECK(room.inside.incoming == kCMTimeZero);
        CHECK_FALSE(room.inside.media.has_value());
        CHECK(room.inside.frames == 40);
        CHECK(room.inside.limit == RoomLimit::OtherEdge);
        CHECK(room.inside.limitingClip == a);
        CHECK(room.inside.reason == "It would overlap the transition at the clip's other end.");
        CHECK_FALSE(room.beyond.has_value());
    }
    SUBCASE("a fade out of a clip a crossfade comes into") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.a1, fx.av30, 0, 30, 30);
        const ClipId b = fx.addClip(fx.a1, fx.av30, 30, 30, 300);
        fx.addTailTransition(a, 5, 7);
        const SideRoom side = TransitionRules::fadeRoom(fx.track(fx.a1), fx.clip(b), ClipEdge::Tail, f30(1));
        CHECK(side.incoming == f30(7));
        CHECK(side.frames == 23);
        CHECK(side.limit == RoomLimit::IncomingDissolve);
        CHECK(side.limitingClip == a); // the clip whose dissolve it would meet
        CHECK(side.reason == "It would meet the crossfade coming into the clip.");
    }
    SUBCASE("a dissolve: both sides, the media winning on one") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 30);
        const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 12); // 12 frames of media before its in point
        fx.addTailTransition(b, 4, 0);                             // B fades out over 4 frames
        const EdgeRoom room = TransitionRules::edgeRoom(fx.project, fx.track(fx.v1), fx.clip(a), ClipEdge::Tail,
                                                        TransitionShape::CrossDissolve, f30(1));
        CHECK(room.inside.frames == 12);
        CHECK(room.inside.limit == RoomLimit::Media);
        CHECK(room.inside.limitingClip == b);
        CHECK(room.inside.reason == "“av30.mov” has no more media before its in point.");
        REQUIRE(room.inside.media.has_value());
        CHECK(room.inside.media->compare(f30(12)) == 0);
        REQUIRE(room.beyond.has_value());
        CHECK(room.beyond->length == f30(60));
        CHECK(room.beyond->otherEdge == f30(4));
        CHECK(room.beyond->frames == 56);
        CHECK(room.beyond->limit == RoomLimit::OtherEdge);
        CHECK(room.beyond->limitingClip == b);
        CHECK(room.beyond->reason == "It would overlap the neighbouring transition.");
    }
    SUBCASE("a still needs no media; a clip without an asset has none") {
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.still, 0, 30);
        const ClipId b = fx.addClip(fx.v1, fx.still, 30, 30);
        const EdgeRoom room = TransitionRules::edgeRoom(fx.project, fx.track(fx.v1), fx.clip(a), ClipEdge::Tail,
                                                        TransitionShape::CrossDissolve, f30(1));
        CHECK_FALSE(room.inside.media.has_value());
        CHECK_FALSE(room.beyond->media.has_value());
        CHECK(room.inside.frames == 30);
        CHECK(room.beyond->frames == 30);
        CHECK(room.inside.limit == RoomLimit::ClipLength);
        CHECK(room.inside.limitingClip == a);
        CHECK(room.beyond->limitingClip == b);
        CHECK(room.inside.reason == "A transition cannot be longer than the clips it joins.");
    }
    SUBCASE("helpers") {
        CHECK(TransitionRules::wholeFrames(std::nullopt, f30(1)) == std::numeric_limits<std::int64_t>::max() / 4);
        CHECK(TransitionRules::wholeFrames(ExactTime::from(-f30(3)), f30(1)) == 0);
        CHECK(TransitionRules::wholeFrames(ExactTime::from(CMTimeMake(59, 60)), f30(1)) == 29);
        CHECK(TransitionRules::fadeRoomBeside(f30(10), f30(4)) == f30(6));
        CHECK(TransitionRules::fadeRoomBeside(f30(10), f30(14)) == kCMTimeZero);
        Fixture fx;
        const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 30, 30);
        fx.addFade(a, ClipEdge::Head, f30(8));
        CHECK(TransitionRules::conformFadeFrames(fx.clip(a), ClipEdge::Head, f30(1)) == 30); // the clip alone
        CHECK(TransitionRules::conformFadeFrames(fx.clip(a), ClipEdge::Tail, f30(1)) == 22); // less the fade in
        CHECK(TransitionRules::partInside(fx.clip(a), ClipEdge::Head) == f30(8));
        CHECK(TransitionRules::partInside(fx.clip(a), ClipEdge::Tail) == kCMTimeZero);
    }
}
