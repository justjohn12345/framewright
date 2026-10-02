#include "TransitionRules.h"

#include "Validation.h"

#include <algorithm>
#include <limits>

namespace ve {

namespace {

std::string quotedMediaName(const Project &project, const Clip &clip) {
    const MediaAsset *asset = project.findAsset(clip.assetId);
    const std::string name = asset && !asset->name.empty() ? asset->name : "clip " + std::to_string(clip.id.value());
    return "“" + name + "”";
}

// length - taken... as an exact time; nullopt on overflow.
std::optional<ExactTime> lengthLeft(CMTime length, std::initializer_list<CMTime> taken) {
    std::optional<ExactTime> left = ExactTime::from(length);
    for (const CMTime t : taken) {
        const auto part = ExactTime::from(t);
        left = left && part ? left->minus(*part) : std::nullopt;
    }
    return left;
}

// Fills `side`'s room, frames, limit and reason: the length less what is taken, at most the media
// (which wins only when it allows fewer whole frames than the length does).
void settle(SideRoom &side, std::optional<ExactTime> left, RoomLimit lengthLimit, ClipId lengthClip,
            std::string lengthReason, ClipId mediaClip, std::string mediaReason, CMTime frameDuration) {
    const std::int64_t lengthFrames = TransitionRules::wholeFrames(left, frameDuration);
    side.limit = lengthLimit;
    side.limitingClip = lengthClip;
    side.reason = std::move(lengthReason);
    side.room = left;
    side.frames = lengthFrames;
    if (side.media) {
        const std::int64_t mediaFrames = TransitionRules::wholeFrames(side.media, frameDuration);
        if (mediaFrames < lengthFrames) {
            side.limit = RoomLimit::Media;
            side.limitingClip = mediaClip;
            side.reason = std::move(mediaReason);
            side.frames = mediaFrames;
        }
        if (!left || side.media->compare(*left) < 0) {
            side.room = side.media;
        }
    }
}

} // namespace

namespace TransitionRules {

std::int64_t wholeFrames(const std::optional<ExactTime> &length, CMTime frameDuration) {
    if (!length) {
        return std::numeric_limits<std::int64_t>::max() / 4;
    }
    if (length->numerator() <= 0) {
        return 0;
    }
    return length->frameIndex(frameDuration, SnapMode::Floor).value_or(0);
}

CMTime partInside(const Clip &owner, ClipEdge edge) {
    const TransitionSpan *span = owner.transitionAt(edge);
    if (span == nullptr) {
        return kCMTimeZero;
    }
    return edge == ClipEdge::Head ? span->end : negateTime(span->start);
}

CMTime incomingPartInside(const Track &track, const Clip &clip) {
    const Clip *previous = touchingClip(track, clip, ClipEdge::Head);
    if (previous == nullptr) {
        return kCMTimeZero;
    }
    const TransitionSpan *tail = previous->transitionAt(ClipEdge::Tail);
    return tail != nullptr && kCMTimeZero < tail->end ? tail->end : kCMTimeZero;
}

SideRoom fadeRoom(const Track &track, const Clip &owner, ClipEdge edge, CMTime frameDuration) {
    SideRoom inside;
    inside.length = owner.timelineDuration;
    inside.otherEdge = partInside(owner, edge == ClipEdge::Head ? ClipEdge::Tail : ClipEdge::Head);
    const Clip *previous = edge == ClipEdge::Tail ? touchingClip(track, owner, ClipEdge::Head) : nullptr;
    if (edge == ClipEdge::Tail) {
        inside.incoming = incomingPartInside(track, owner);
    }
    const auto left = lengthLeft(inside.length, {inside.otherEdge, inside.incoming});
    // The clip's length less the other edge's span and, at the tail, a dissolve coming in.
    if (kCMTimeZero < inside.incoming) {
        settle(inside, left, RoomLimit::IncomingDissolve, previous != nullptr ? previous->id : ClipId{},
               track.kind == TrackKind::Audio ? "It would meet the crossfade coming into the clip."
                                              : "It would meet the cross dissolve coming into the clip.",
               {}, {}, frameDuration);
    } else if (inside.otherEdge != kCMTimeZero) {
        settle(inside, left, RoomLimit::OtherEdge, owner.id, "It would overlap the transition at the clip's other end.",
               {}, {}, frameDuration);
    } else {
        settle(inside, left, RoomLimit::ClipLength, owner.id, "A fade cannot be longer than its clip.", {}, {},
               frameDuration);
    }
    return inside;
}

std::optional<CMTime> fadeRoomBeside(CMTime length, CMTime taken) {
    const auto rest = checkedSubtract(length, taken);
    return rest ? std::optional<CMTime>(maxTime(*rest, kCMTimeZero)) : std::nullopt;
}

std::int64_t conformFadeFrames(const Clip &owner, ClipEdge edge, CMTime frameDuration) {
    const CMTime taken = edge == ClipEdge::Tail ? partInside(owner, ClipEdge::Head) : kCMTimeZero;
    return wholeFrames(lengthLeft(owner.timelineDuration, {taken}), frameDuration);
}

EdgeRoom edgeRoom(const Project &project, const Track &track, const Clip &owner, ClipEdge edge,
                  TransitionShape shape, CMTime frameDuration) {
    EdgeRoom room;
    if (shape == TransitionShape::Fade) {
        room.inside = fadeRoom(track, owner, edge, frameDuration);
        return room;
    }
    SideRoom &inside = room.inside;
    inside.length = owner.timelineDuration;
    const ClipEdge other = edge == ClipEdge::Head ? ClipEdge::Tail : ClipEdge::Head;
    const TransitionSpan *otherSpan = owner.transitionAt(other);
    inside.otherEdge = partInside(owner, other);
    const Clip *previous = edge == ClipEdge::Tail ? touchingClip(track, owner, ClipEdge::Head) : nullptr;
    if (edge == ClipEdge::Tail) {
        inside.incoming = incomingPartInside(track, owner);
    }
    const ClipId incomingOwner = previous != nullptr ? previous->id : ClipId{};
    const auto left = lengthLeft(inside.length, {inside.otherEdge, inside.incoming});

    // A cross dissolve out of the owner: its share before the cut needs the next clip's media before its
    // in point, its share after the cut lies in the next clip and needs the owner's media after its out.
    const Clip *next = touchingClip(track, owner, ClipEdge::Tail);
    if (next != nullptr && !next->isStill) {
        // nullopt on overflow: then media does not limit it.
        const auto in = ExactTime::from(next->sourceIn);
        inside.media = in ? in->dividedBy(next->speedRatio()) : std::nullopt;
    }
    const std::string mediaBefore =
        next != nullptr ? quotedMediaName(project, *next) + " has no more media before its in point." : std::string();
    const ClipId nextId = next != nullptr ? next->id : ClipId{};
    if (otherSpan != nullptr && other == ClipEdge::Head) {
        settle(inside, left, RoomLimit::OtherEdge, owner.id, "It would overlap the fade at the clip's start.", nextId,
               mediaBefore, frameDuration);
    } else if (kCMTimeZero < inside.incoming) {
        settle(inside, left, RoomLimit::IncomingDissolve, incomingOwner,
               "It would overlap the neighbouring transition.", nextId, mediaBefore, frameDuration);
    } else {
        settle(inside, left, RoomLimit::ClipLength, owner.id, "A transition cannot be longer than the clips it joins.",
               nextId, mediaBefore, frameDuration);
    }
    if (next == nullptr || edge != ClipEdge::Tail) {
        return room;
    }

    SideRoom beyond;
    beyond.length = next->timelineDuration;
    const TransitionSpan *nextTail = next->transitionAt(ClipEdge::Tail);
    beyond.otherEdge = partInside(*next, ClipEdge::Tail);
    if (!owner.isStill) {
        // The owner's media after its out point; none without a usable asset (or on overflow).
        const MediaAsset *asset = project.findAsset(owner.assetId);
        const auto out = owner.exactSourceOut();
        const auto end = asset ? ExactTime::from(mediaEndFor(*asset, track.kind)) : std::nullopt;
        const auto rest = out && end ? end->minus(*out) : std::nullopt;
        const auto media = rest ? rest->dividedBy(owner.speedRatio()) : std::nullopt;
        beyond.media = media ? *media : ExactTime{};
    }
    const auto beyondLeft = lengthLeft(beyond.length, {beyond.otherEdge});
    const std::string mediaAfter = quotedMediaName(project, owner) + " has no more media after its out point.";
    if (nextTail != nullptr) {
        settle(beyond, beyondLeft, RoomLimit::OtherEdge, next->id, "It would overlap the neighbouring transition.",
               owner.id, mediaAfter, frameDuration);
    } else {
        settle(beyond, beyondLeft, RoomLimit::ClipLength, next->id,
               "A transition cannot be longer than the clips it joins.", owner.id, mediaAfter, frameDuration);
    }
    room.beyond = std::move(beyond);
    return room;
}

} // namespace TransitionRules

} // namespace ve
