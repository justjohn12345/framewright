#include "TransitionFitting.h"

#include <algorithm>
#include <charconv>

namespace ve {

std::string describeFrames(std::int64_t frames, CMTime frameDuration) {
    const double seconds = static_cast<double>(frames) * CMTimeGetSeconds(frameDuration);
    // Two decimals as printf's "%.2f" writes them, independent of the C locale.
    char buffer[64];
    const auto converted = std::to_chars(buffer, buffer + sizeof buffer, seconds, std::chars_format::fixed, 2);
    const std::string secondsText(buffer, converted.ec == std::errc() ? converted.ptr : buffer);
    return std::to_string(frames) + (frames == 1 ? " frame (" : " frames (") + secondsText + " s)";
}

bool isLengthLimit(EditError error) {
    return error == EditError::InsufficientHandles || error == EditError::InvalidArgument ||
           error == EditError::Overlap;
}

std::string transitionRefusal(const TransitionLimit &limit, std::int64_t frames, CMTime frameDuration) {
    if (limit.maximumFrames == 0) {
        return isLengthLimit(limit.limitError) ? "No transition fits this cut: " + limit.reason : limit.reason;
    }
    return "A transition of " + describeFrames(frames, frameDuration) + " does not fit this cut: " + limit.reason +
           " The longest it allows is " + describeFrames(limit.maximumFrames, frameDuration) + ".";
}

EditError refusalError(const TransitionLimit &limit) {
    return limit.limitError == EditError::None ? EditError::InvalidArgument : limit.limitError;
}

TransitionKind transitionKindOnTrack(TrackKind trackKind, TransitionKind requested) {
    return trackKind == TrackKind::Video ? requested : TransitionKind::CrossDissolve;
}

const char *fadeTargetName(TrackKind trackKind) {
    return trackKind == TrackKind::Video ? "black" : "silence";
}

TransitionLimit fadeLimit(const Clip &clip, const Track &track, ClipEdge edge, CMTime frameDuration, SpanId excluded) {
    std::optional<Clip> without;
    if (excluded) {
        without = clip;
        std::erase_if(without->spans, [&](const EffectSpan &s) { return s.id == excluded; });
    }
    const Clip &owner = without ? *without : clip;
    CMTime taken = kCMTimeZero;
    CMTime incoming = kCMTimeZero;
    if (edge == ClipEdge::Head) {
        if (const EffectSpan *tail = owner.transitionAt(ClipEdge::Tail)) {
            taken = -tail->start;
        }
    } else {
        taken = clipFadeLength(owner, ClipEdge::Head);
        incoming = incomingTransitionInside(track, owner);
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

std::pair<CMTime, CMTime> resizedTransitionOffsets(const TransitionPlacement &transition, std::int64_t frames,
                                                   CMTime frameDuration) {
    const CMTime fd = frameDuration;
    if (transition.role == TransitionRole::FadeIn) {
        return {kCMTimeZero, timeForFrame(frames, fd)};
    }
    if (transition.role == TransitionRole::FadeOut) {
        return {-timeForFrame(frames, fd), kCMTimeZero};
    }
    const std::int64_t before = frameIndexAt(transition.cut - transition.range.start, fd, SnapMode::Round);
    const std::int64_t total = frameIndexAt(transition.range.duration(), fd, SnapMode::Round);
    std::int64_t newBefore = frames / 2;
    if (total > 0 && before != total / 2) {
        newBefore = static_cast<std::int64_t>((static_cast<Int128>(frames) * before) / total);
    }
    return {-timeForFrame(newBefore, fd), timeForFrame(frames - newBefore, fd)};
}

TransitionLimit transitionDurationLimit(const Project &project, const Sequence &sequence,
                                        const TransitionPlacement &transition) {
    const CMTime fd = sequence.frameDuration;
    if (transition.role != TransitionRole::CrossDissolve) {
        // The fade's own length does not count against it.
        const ClipEdge edge = transition.role == TransitionRole::FadeIn ? ClipEdge::Head : ClipEdge::Tail;
        return fadeLimit(*transition.owner, *transition.track, edge, fd, transition.span->id);
    }
    TransitionLimit limit;
    EditResult why = EditResult::success();
    const auto sides = transitionSideLimits(project, sequence, transition.owner->id, transition.span->id, why);
    if (!sides) {
        limit.limitError = why.error;
        limit.reason = why.message;
        return limit;
    }
    auto fits = [&](std::int64_t frames) {
        const auto [start, end] = resizedTransitionOffsets(transition, frames, fd);
        return frameIndexAt(-start, fd, SnapMode::Round) <= sides->maxBeforeFrames &&
               frameIndexAt(end, fd, SnapMode::Round) <= sides->maxAfterFrames;
    };
    std::int64_t lo = 0;
    std::int64_t hi = sides->maxBeforeFrames + sides->maxAfterFrames + 1;
    while (hi - lo > 1) {
        const std::int64_t mid = lo + (hi - lo) / 2;
        (fits(mid) ? lo : hi) = mid;
    }
    limit.maximumFrames = lo;
    limit.maximum = lo > 0 ? timeForFrame(lo, fd) : kCMTimeZero;
    const CMTime startOfLonger = resizedTransitionOffsets(transition, lo + 1, fd).first;
    const bool beforeOverruns = frameIndexAt(-startOfLonger, fd, SnapMode::Round) > sides->maxBeforeFrames;
    limit.limitError = beforeOverruns ? sides->beforeError : sides->afterError;
    limit.reason = beforeOverruns ? sides->beforeReason : sides->afterReason;
    limit.limitingClip = beforeOverruns ? sides->beforeLimitingClip : sides->afterLimitingClip;
    return limit;
}

TransitionRangeFit fitTransitionRange(const Project &project, const Sequence &sequence,
                                      const TransitionPlacement &transition, TimeRange range, bool linked) {
    const CMTime fd = sequence.frameDuration;
    const std::string who = linked ? "The linked transition" : "The transition";
    const Clip &owner = *transition.owner;
    TransitionRangeFit fit;
    auto refuse = [&](EditResult refusal) {
        fit.refusal = std::move(refusal);
        return fit;
    };
    if (transition.span->edge == ClipEdge::Head) {
        if (range.start != owner.timelineStart) {
            return refuse(EditResult::failure(EditError::InvalidTime, "A fade in starts at its clip's start."));
        }
        const TransitionLimit limit = fadeLimit(owner, *transition.track, ClipEdge::Head, fd, transition.span->id);
        std::int64_t length = frameIndexAt(range.duration(), fd, SnapMode::Round);
        if (length > limit.maximumFrames) {
            length = limit.maximumFrames;
        }
        if (length < 1) {
            // Refused, so nothing was shortened: no note (it used to say "shortened to 0 frames" first).
            return refuse(EditResult::failure(limit.limitError, limit.reason));
        }
        if (length < frameIndexAt(range.duration(), fd, SnapMode::Round)) {
            fit.notes.push_back(who + " was shortened to " + describeFrames(length, fd) + ": " + limit.reason);
        }
        fit.offsets = std::make_pair(kCMTimeZero, timeForFrame(length, fd));
        return fit;
    }
    const CMTime cut = owner.timelineEnd();
    if (cut < range.start) {
        return refuse(
            EditResult::failure(EditError::InvalidTime, "A transition at a clip's end starts inside the clip."));
    }
    std::int64_t before = frameIndexAt(cut - range.start, fd, SnapMode::Round);
    std::int64_t after = std::max<std::int64_t>(0, frameIndexAt(range.end - cut, fd, SnapMode::Round));
    const Clip *next = touchingClip(*transition.track, owner, ClipEdge::Tail);
    const std::string target = fadeTargetName(transition.track->kind);
    if (after > 0 && next == nullptr) {
        after = 0;
        fit.notes.push_back(who + " fades out to " + target + ": nothing follows the clip.");
    }
    if (after > 0) {
        EditResult why = EditResult::success();
        const auto sides = transitionSideLimits(project, sequence, owner.id, transition.span->id, why);
        if (!sides) {
            return refuse(why);
        }
        if (before > sides->maxBeforeFrames) {
            before = sides->maxBeforeFrames;
            fit.notes.push_back(who + " was shortened before the cut to " + describeFrames(before, fd) + ": " +
                                sides->beforeReason);
        }
        if (after > sides->maxAfterFrames) {
            after = sides->maxAfterFrames;
            fit.notes.push_back(who + " was shortened after the cut to " + describeFrames(after, fd) + ": " +
                                sides->afterReason);
        }
        if (after > 0 && transition.role != TransitionRole::CrossDissolve) {
            fit.notes.push_back(who + " now crosses the cut: a " +
                                (transition.track->kind == TrackKind::Video ? "cross dissolve" : "crossfade") +
                                " into the next clip.");
        }
    }
    if (after == 0) {
        const TransitionLimit limit = fadeLimit(owner, *transition.track, ClipEdge::Tail, fd, transition.span->id);
        if (before > limit.maximumFrames) {
            before = limit.maximumFrames;
            fit.notes.push_back(who + " was shortened to " + describeFrames(before, fd) + ": " + limit.reason);
        }
        if (transition.role == TransitionRole::CrossDissolve && before > 0 && next != nullptr) {
            fit.notes.push_back(who + " no longer reaches past the cut, so it now fades out to " + target + ".");
        }
    }
    if (before + after < 1) {
        return refuse(EditResult::failure(EditError::InvalidArgument, who + " would cover no frame."));
    }
    fit.offsets = std::make_pair(-timeForFrame(before, fd), timeForFrame(after, fd));
    return fit;
}

FadePlan planFade(const Clip &owner, const Track &ownerTrack, ClipEdge edge, std::int64_t frames,
                  CMTime frameDuration, bool fitToCut, TransitionKind requested, bool linked) {
    FadePlan plan;
    if (owner.transitionAt(edge) != nullptr) {
        plan.refusal = edge == ClipEdge::Head ? "The clip already has a transition at its start."
                                              : "The clip already has a transition at its end.";
        return plan;
    }
    if (edge == ClipEdge::Head && touchingClip(ownerTrack, owner, ClipEdge::Head) != nullptr) {
        plan.refusal = "Another clip touches the clip's start, so the cut belongs to that clip: add a transition at "
                       "its end instead.";
        return plan;
    }
    const TransitionLimit limit = fadeLimit(owner, ownerTrack, edge, frameDuration);
    std::int64_t length = frames;
    if (length > limit.maximumFrames) {
        if (!fitToCut || limit.maximumFrames == 0) {
            plan.refusal = "A fade of " + describeFrames(frames, frameDuration) + " does not fit: " + limit.reason +
                           " The longest it allows is " + describeFrames(limit.maximumFrames, frameDuration) + ".";
            return plan;
        }
        length = limit.maximumFrames;
        // The clip's own fade as the facade notes its own fitted transitions ("Shortened to ..."), the linked
        // clip's in a sentence naming it.
        plan.note = std::string(linked ? "The linked clip's fade was shortened to " : "Shortened to ") +
                    describeFrames(length, frameDuration) + ": " + limit.reason;
    }
    TransitionSpanRequest request;
    request.clipId = owner.id;
    request.edge = edge;
    request.kind = transitionKindOnTrack(ownerTrack.kind, requested);
    const CMTime fade = timeForFrame(length, frameDuration);
    request.start = edge == ClipEdge::Head ? kCMTimeZero : -fade;
    request.end = edge == ClipEdge::Head ? fade : kCMTimeZero;
    plan.request = request;
    return plan;
}

} // namespace ve
