#include "Sequence.h"

#include "MediaAsset.h"

#include <algorithm>
#include <array>
#include <climits>
#include <cmath>
#include <cstdio>

namespace ve {

const std::vector<CMTime> &standardFrameDurations() {
    static const std::vector<CMTime> durations{CMTimeMake(1001, 24000), CMTimeMake(1, 24),    CMTimeMake(1, 25),
                                               CMTimeMake(1001, 30000), CMTimeMake(1, 30),    CMTimeMake(1, 50),
                                               CMTimeMake(1001, 60000), CMTimeMake(1, 60)};
    return durations;
}

namespace {

double ratePerSecond(CMTime frameDuration) {
    return static_cast<double>(frameDuration.timescale) / static_cast<double>(frameDuration.value);
}

// Whether `rate` is within `tolerance` (relative) of a whole multiple (>= 1) of `base`.
bool isWholeMultiple(double rate, double base, double tolerance) {
    const double multiple = std::round(rate / base);
    return multiple >= 1 && std::fabs(rate - multiple * base) <= tolerance * rate;
}

} // namespace

std::optional<CMTime> standardFrameDurationFor(double framesPerSecond) {
    if (!std::isfinite(framesPerSecond) || !(framesPerSecond > 0)) {
        return std::nullopt;
    }
    const std::vector<CMTime> &standard = standardFrameDurations();
    const double fastest = ratePerSecond(standard.back());
    if (framesPerSecond > fastest * 1.001) {
        // High frame rate: the standard rate it is a whole multiple of, the faster first.
        for (const CMTime base : {CMTimeMake(1, 60), CMTimeMake(1001, 60000), CMTimeMake(1, 50)}) {
            if (isWholeMultiple(framesPerSecond, ratePerSecond(base), 0.0005)) {
                return base;
            }
        }
        return CMTimeMake(1, 60);
    }
    const double slowest = ratePerSecond(standard.front());
    if (framesPerSecond < slowest * 0.995) {
        // A slow rate: the slowest standard rate showing each of its frames a whole number of times.
        for (const CMTime candidate : standard) {
            if (isWholeMultiple(ratePerSecond(candidate), framesPerSecond, 0.0005)) {
                return candidate;
            }
        }
        return CMTimeMake(1, 30);
    }
    CMTime best = standard.front();
    double bestDistance = INFINITY;
    for (const CMTime candidate : standard) {
        const double distance = std::fabs(std::log(framesPerSecond / ratePerSecond(candidate)));
        if (distance < bestDistance) {
            bestDistance = distance;
            best = candidate;
        }
    }
    return best;
}

std::string frameRateName(CMTime frameDuration) {
    if (!isPositive(frameDuration)) {
        return "?";
    }
    static constexpr std::array<const char *, 8> names{"23.976", "24", "25", "29.97", "30", "50", "59.94", "60"};
    const std::vector<CMTime> &standard = standardFrameDurations();
    for (std::size_t i = 0; i < standard.size(); ++i) {
        if (frameDuration == standard[i]) {
            return names[i];
        }
    }
    char buffer[32];
    std::snprintf(buffer, sizeof buffer, "%.3f", ratePerSecond(frameDuration));
    std::string text = buffer;
    while (!text.empty() && text.back() == '0') {
        text.pop_back();
    }
    if (!text.empty() && text.back() == '.') {
        text.pop_back();
    }
    return text;
}

SequenceFormat requestedSequenceFormat(std::int64_t width, std::int64_t height, CMTime frameDuration,
                                       std::int64_t audioSampleRate) {
    auto side = [](std::int64_t value) {
        return static_cast<std::int32_t>(std::clamp<std::int64_t>(value, 0, INT32_MAX));
    };
    SequenceFormat format;
    format.width = side(width);
    format.height = side(height);
    format.frameDuration = frameDuration;
    format.audioSampleRate = side(audioSampleRate);
    format.configured = true;
    return format;
}

std::optional<std::string> sequenceFormatProblem(const SequenceFormat &format) {
    const CMTime fd = format.frameDuration;
    if (!isExactModelTime(fd) || !isPositive(fd) || CMTimeCompare(fd, CMTimeMake(1, 240)) < 0 ||
        CMTimeCompare(fd, CMTimeMake(1, 1)) > 0) {
        return std::string("The frame rate must be between 1 and 240 frames per second.");
    }
    if (format.width < kMinSequenceSide || format.height < kMinSequenceSide || format.width > kMaxSequenceSide ||
        format.height > kMaxSequenceSide) {
        return "The frame size must be between " + std::to_string(kMinSequenceSide) + " and " +
               std::to_string(kMaxSequenceSide) + " pixels on each side.";
    }
    if (format.width % 2 != 0 || format.height % 2 != 0) {
        return std::string("The frame width and height must be even numbers (video encoders need them).");
    }
    if (format.audioSampleRate < kMinSequenceSampleRate || format.audioSampleRate > kMaxSequenceSampleRate) {
        return std::string("The audio sample rate must be between 8 and 192 kHz.");
    }
    return std::nullopt;
}

std::optional<SequenceFormat> formatAdoptedFrom(const MediaAsset &asset, const SequenceFormat &current) {
    if (!asset.hasVideo() || asset.isStill() || asset.width <= 0 || asset.height <= 0) {
        return std::nullopt;
    }
    SequenceFormat format = current;
    if (isPositive(asset.frameDuration)) {
        if (const auto standard = standardFrameDurationFor(ratePerSecond(asset.frameDuration))) {
            format.frameDuration = *standard;
        }
    }
    format.width = asset.width + (asset.width & 1);
    format.height = asset.height + (asset.height & 1);
    format.configured = true;
    if (sequenceFormatProblem(format)) {
        format.width = current.width;
        format.height = current.height;
    }
    return format;
}

bool operator==(const Sequence &a, const Sequence &b) {
    return a.id == b.id && a.name == b.name && identical(a.frameDuration, b.frameDuration) && a.width == b.width &&
           a.height == b.height && a.audioSampleRate == b.audioSampleRate && a.configured == b.configured &&
           a.videoTracks == b.videoTracks && a.audioTracks == b.audioTracks;
}

SequenceFormat Sequence::format() const {
    return SequenceFormat{frameDuration, width, height, audioSampleRate, configured};
}

void Sequence::setFormat(const SequenceFormat &format) {
    frameDuration = format.frameDuration;
    width = format.width;
    height = format.height;
    audioSampleRate = format.audioSampleRate;
    configured = format.configured;
}

bool Sequence::isEmpty() const {
    for (const std::vector<Track> *list : {&videoTracks, &audioTracks}) {
        for (const Track &track : *list) {
            if (!track.clips.empty()) {
                return false;
            }
        }
    }
    return true;
}

CMTime Sequence::duration() const {
    CMTime result = kCMTimeZero;
    for (const Track &track : videoTracks) {
        result = maxTime(result, track.end());
    }
    for (const Track &track : audioTracks) {
        result = maxTime(result, track.end());
    }
    return result;
}

const Track *Sequence::findTrack(TrackId trackId) const {
    for (const Track &track : videoTracks) {
        if (track.id == trackId) {
            return &track;
        }
    }
    for (const Track &track : audioTracks) {
        if (track.id == trackId) {
            return &track;
        }
    }
    return nullptr;
}

Track *Sequence::findTrack(TrackId trackId) {
    return const_cast<Track *>(static_cast<const Sequence *>(this)->findTrack(trackId));
}

std::optional<ClipLocation> Sequence::locateClip(ClipId clipId) const {
    for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
        const std::vector<Track> &list = tracks(kind);
        for (std::size_t t = 0; t < list.size(); ++t) {
            if (const auto index = list[t].indexOf(clipId)) {
                return ClipLocation{kind, t, *index};
            }
        }
    }
    return std::nullopt;
}

const Clip *Sequence::findClip(ClipId clipId) const {
    const auto location = locateClip(clipId);
    if (!location) {
        return nullptr;
    }
    return &tracks(location->trackKind)[location->trackIndex].clips[location->clipIndex];
}

Clip *Sequence::findClip(ClipId clipId) {
    return const_cast<Clip *>(static_cast<const Sequence *>(this)->findClip(clipId));
}

const Track *Sequence::trackOfClip(ClipId clipId) const {
    const auto location = locateClip(clipId);
    if (!location) {
        return nullptr;
    }
    return &tracks(location->trackKind)[location->trackIndex];
}

Track *Sequence::trackOfClip(ClipId clipId) {
    return const_cast<Track *>(static_cast<const Sequence *>(this)->trackOfClip(clipId));
}

const EffectSpan *Sequence::findSpan(SpanId spanId, const Clip **owner, const Track **track) const {
    for (const std::vector<Track> *list : {&videoTracks, &audioTracks}) {
        for (const Track &t : *list) {
            for (const Clip &clip : t.clips) {
                if (const EffectSpan *span = clip.findSpan(spanId)) {
                    if (owner != nullptr) {
                        *owner = &clip;
                    }
                    if (track != nullptr) {
                        *track = &t;
                    }
                    return span;
                }
            }
        }
    }
    return nullptr;
}

EffectSpan *Sequence::findSpan(SpanId spanId, Clip **owner, Track **track) {
    const Clip *constOwner = nullptr;
    const Track *constTrack = nullptr;
    const EffectSpan *span = static_cast<const Sequence *>(this)->findSpan(spanId, &constOwner, &constTrack);
    if (owner != nullptr) {
        *owner = const_cast<Clip *>(constOwner);
    }
    if (track != nullptr) {
        *track = const_cast<Track *>(constTrack);
    }
    return const_cast<EffectSpan *>(span);
}

const Clip *touchingClip(const Track &track, const Clip &clip, ClipEdge edge) {
    const auto index = track.indexOf(clip.id);
    if (!index) {
        return nullptr;
    }
    if (edge == ClipEdge::Head) {
        if (*index == 0) {
            return nullptr;
        }
        const Clip &previous = track.clips[*index - 1];
        return previous.timelineEnd() == clip.timelineStart ? &previous : nullptr;
    }
    if (*index + 1 >= track.clips.size()) {
        return nullptr;
    }
    const Clip &next = track.clips[*index + 1];
    return next.timelineStart == clip.timelineEnd() ? &next : nullptr;
}

CMTime incomingTransitionInside(const Track &track, const Clip &clip) {
    const Clip *previous = touchingClip(track, clip, ClipEdge::Head);
    if (previous == nullptr) {
        return kCMTimeZero;
    }
    const EffectSpan *tail = previous->transitionAt(ClipEdge::Tail);
    return tail != nullptr && kCMTimeZero < tail->end ? tail->end : kCMTimeZero;
}

std::optional<TransitionPlacement> placeTransition(const Track &track, const Clip &owner, const EffectSpan &span) {
    if (!span.isTransition()) {
        return std::nullopt;
    }
    TransitionPlacement placement;
    placement.track = &track;
    placement.owner = &owner;
    placement.span = &span;
    if (span.edge == ClipEdge::Head) {
        placement.role = TransitionRole::FadeIn;
        placement.cut = owner.timelineStart;
    } else {
        placement.cut = owner.timelineEnd();
        placement.role = kCMTimeZero < span.end ? TransitionRole::CrossDissolve : TransitionRole::FadeOut;
        if (placement.role == TransitionRole::CrossDissolve) {
            placement.partner = touchingClip(track, owner, ClipEdge::Tail);
        }
    }
    const auto start = checkedAdd(placement.cut, span.start);
    const auto end = checkedAdd(placement.cut, span.end);
    if (!start || !end) {
        return std::nullopt;
    }
    placement.range = TimeRange{*start, *end};
    return placement;
}

std::optional<TransitionPlacement> transitionAt(const Track &track, CMTime t) {
    const auto index = track.clipIndexAt(t);
    if (!index) {
        return std::nullopt;
    }
    const Clip &clip = track.clips[*index];
    auto covering = [&](const Clip &owner, ClipEdge edge) -> std::optional<TransitionPlacement> {
        const EffectSpan *span = owner.transitionAt(edge);
        if (span == nullptr) {
            return std::nullopt;
        }
        auto placement = placeTransition(track, owner, *span);
        if (placement && placement->range.contains(t)) {
            return placement;
        }
        return std::nullopt;
    };
    if (auto own = covering(clip, ClipEdge::Tail)) {
        return own;
    }
    if (auto head = covering(clip, ClipEdge::Head)) {
        return head;
    }
    if (const Clip *previous = touchingClip(track, clip, ClipEdge::Head)) {
        if (auto incoming = covering(*previous, ClipEdge::Tail)) {
            return incoming;
        }
    }
    return std::nullopt;
}

} // namespace ve
