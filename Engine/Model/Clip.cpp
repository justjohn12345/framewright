#include "Clip.h"

namespace ve {

bool isValidSpeed(Ratio speed) {
    return speed.isReduced() && speed.num > 0 && speed.den <= kMaxSpeedDenominator && !(speed < Ratio{1, 100}) &&
           !(Ratio{100, 1} < speed);
}

double VideoParams::staticValue(MotionParameter parameter) const {
    switch (parameter) {
    case MotionParameter::X:
        return x;
    case MotionParameter::Y:
        return y;
    case MotionParameter::Scale:
        return scale;
    case MotionParameter::Rotation:
        return rotationDegrees;
    case MotionParameter::Opacity:
        return opacity;
    }
    return x;
}

void VideoParams::setStaticValue(MotionParameter parameter, double value) {
    switch (parameter) {
    case MotionParameter::X:
        x = value;
        break;
    case MotionParameter::Y:
        y = value;
        break;
    case MotionParameter::Scale:
        scale = value;
        break;
    case MotionParameter::Rotation:
        rotationDegrees = value;
        break;
    case MotionParameter::Opacity:
        opacity = value;
        break;
    }
}

double VideoParams::valueAt(MotionParameter parameter, const ExactTime &time) const {
    const KeyframeTrack &track = keyframes.track(parameter);
    if (track.empty()) {
        return staticValue(parameter);
    }
    return clampMotionValue(parameter, evaluateTrack(track, staticValue(parameter), time));
}

VideoParams VideoParams::valuesAt(const ExactTime &time) const {
    VideoParams values = staticValues();
    if (!keyframes.empty()) {
        for (const MotionParameter parameter : kMotionParameters) {
            values.setStaticValue(parameter, valueAt(parameter, time));
        }
    }
    return values;
}

VideoParams VideoParams::staticValues() const {
    VideoParams values;
    values.x = x;
    values.y = y;
    values.scale = scale;
    values.rotationDegrees = rotationDegrees;
    values.opacity = opacity;
    return values;
}

bool operator==(const AudioParams &a, const AudioParams &b) {
    return a.gainDb == b.gainDb && identical(a.fadeInDuration, b.fadeInDuration) &&
           identical(a.fadeOutDuration, b.fadeOutDuration);
}

bool operator==(const Clip &a, const Clip &b) {
    return a.id == b.id && a.assetId == b.assetId && a.trackId == b.trackId &&
           identical(a.timelineStart, b.timelineStart) && identical(a.timelineDuration, b.timelineDuration) &&
           identical(a.sourceIn, b.sourceIn) && a.speed == b.speed && a.isStill == b.isStill &&
           a.linkedClipId == b.linkedClipId && a.video == b.video && a.audio == b.audio;
}

std::optional<ExactTime> Clip::exactSourceTimeAt(CMTime t) const {
    const auto at = ExactTime::from(t);
    const auto start = ExactTime::from(timelineStart);
    const auto in = ExactTime::from(isStill ? kCMTimeZero : sourceIn);
    if (!at || !start || !in) {
        return std::nullopt;
    }
    const auto offset = at->minus(*start);
    const auto scaled = offset ? offset->times(speedRatio()) : std::nullopt;
    return scaled ? in->plus(*scaled) : std::nullopt;
}

std::optional<ExactTime> Clip::exactSourceOut() const {
    const auto in = ExactTime::from(isStill ? kCMTimeZero : sourceIn);
    const auto length = ExactTime::from(timelineDuration);
    if (!in || !length) {
        return std::nullopt;
    }
    const auto scaled = length->times(speedRatio());
    return scaled ? in->plus(*scaled) : std::nullopt;
}

std::optional<ExactTime> Clip::exactTimelineTimeAt(CMTime s) const {
    const auto source = ExactTime::from(s);
    const auto start = ExactTime::from(timelineStart);
    const auto in = ExactTime::from(isStill ? kCMTimeZero : sourceIn);
    if (!source || !start || !in) {
        return std::nullopt;
    }
    const auto offset = source->minus(*in);
    const auto scaled = offset ? offset->dividedBy(speedRatio()) : std::nullopt;
    return scaled ? start->plus(*scaled) : std::nullopt;
}

CMTime Clip::sourceTimeAt(CMTime t) const {
    const auto exact = exactSourceTimeAt(t);
    return exact ? exact->toTimeRounded() : kCMTimeInvalid;
}

CMTime Clip::sourceOut() const {
    const auto exact = exactSourceOut();
    return exact ? exact->toTimeRounded() : kCMTimeInvalid;
}

CMTime Clip::sourceDuration() const {
    return scaleTime(timelineDuration, speedRatio());
}

CMTime Clip::timelineTimeAt(CMTime s) const {
    const auto exact = exactTimelineTimeAt(s);
    return exact ? exact->toTimeRounded() : kCMTimeInvalid;
}

bool Clip::setTimelineStartKeepingEnd(CMTime newStart) {
    const auto delta = checkedSubtract(newStart, timelineStart);
    if (!delta) {
        return false;
    }
    const auto duration = checkedSubtract(timelineDuration, *delta);
    if (!duration) {
        return false;
    }
    CMTime in = kCMTimeZero;
    std::optional<MotionKeyframes> shifted;
    if (isStill && !video.keyframes.empty()) {
        const auto back = checkedNegate(*delta);
        if (!back) {
            return false;
        }
        shifted = video.keyframes;
        for (const MotionParameter parameter : kMotionParameters) {
            if (!shiftTrack(shifted->track(parameter), *back)) {
                return false;
            }
        }
    }
    if (!isStill) {
        const auto scaled = checkedScale(*delta, speed);
        const auto moved = scaled ? checkedAdd(sourceIn, *scaled) : std::nullopt;
        if (!moved) {
            return false;
        }
        in = *moved;
    }
    timelineStart = newStart;
    timelineDuration = *duration;
    sourceIn = in;
    if (shifted) {
        video.keyframes = std::move(*shifted);
    }
    fitFades(ClipEdge::Head);
    return true;
}

bool Clip::setTimelineEnd(CMTime newEnd) {
    const auto duration = checkedSubtract(newEnd, timelineStart);
    if (!duration) {
        return false;
    }
    timelineDuration = *duration;
    if (isStill) {
        sourceIn = kCMTimeZero;
    }
    fitFades(ClipEdge::Tail);
    return true;
}

void Clip::fitFades(ClipEdge editedEdge) {
    CMTime &fadeIn = audio.fadeInDuration;
    CMTime &fadeOut = audio.fadeOutDuration;
    const CMTime length = maxTime(timelineDuration, kCMTimeZero);
    if (fadeIn > length) {
        fadeIn = length;
    }
    if (fadeOut > length) {
        fadeOut = length;
    }
    const auto in = ExactTime::from(fadeIn);
    const auto out = ExactTime::from(fadeOut);
    const auto total = in && out ? in->plus(*out) : std::nullopt;
    if (!total || total->compare(length) <= 0) {
        return;
    }
    // Overlapping fades: the fade at the edited edge gives way. When the remainder has no exact
    // CMTime form (only with pathological timescales) that fade is removed instead.
    CMTime &yielding = editedEdge == ClipEdge::Head ? fadeIn : fadeOut;
    const CMTime &kept = editedEdge == ClipEdge::Head ? fadeOut : fadeIn;
    yielding = checkedSubtract(length, kept).value_or(kCMTimeZero);
}

std::optional<CMTime> frameShowingSourceTime(const Clip &clip, CMTime sourceTime, CMTime frameDuration) {
    if (!isPositive(frameDuration) || !isNumeric(sourceTime)) {
        return std::nullopt;
    }
    const auto at = clip.exactTimelineTimeAt(sourceTime);
    const auto start = ExactTime::from(clip.timelineStart);
    const auto end = ExactTime::from(clip.timelineEnd());
    if (!at || !start || !end || at->compare(*start) < 0 || at->compare(*end) > 0) {
        return std::nullopt;
    }
    if (at->compare(*end) == 0) {
        // On the out point: the clip's last frame.
        const auto last = checkedSubtract(clip.timelineEnd(), frameDuration);
        return last && *last >= clip.timelineStart ? last : std::nullopt;
    }
    const auto index = at->frameIndex(frameDuration, SnapMode::Floor);
    const auto frame = index ? checkedTimeForFrame(*index, frameDuration) : std::nullopt;
    if (!frame || *frame < clip.timelineStart || *frame >= clip.timelineEnd()) {
        return std::nullopt;
    }
    return frame;
}

std::optional<std::size_t> keyframeIndexForFrame(const Clip &clip, MotionParameter parameter, CMTime frameStart,
                                                 CMTime frameDuration) {
    const KeyframeTrack &track = clip.video.keyframes.track(parameter);
    if (track.empty() || !isPositive(frameDuration) || !isNumeric(frameStart) || frameStart < clip.timelineStart ||
        frameStart >= clip.timelineEnd()) {
        return std::nullopt;
    }
    const auto frameEnd = checkedAdd(frameStart, frameDuration);
    const auto from = clip.exactSourceTimeAt(frameStart);
    const auto to = frameEnd ? clip.exactSourceTimeAt(*frameEnd) : std::nullopt;
    if (!from || !to) {
        return std::nullopt;
    }
    if (const auto index = firstKeyframeIn(track, *from, *to)) {
        return index;
    }
    if (*frameEnd >= clip.timelineEnd()) {
        // The last frame also owns a keyframe on the out point.
        for (std::size_t i = 0; i < track.size(); ++i) {
            if (to->compare(track[i].time) == 0) {
                return i;
            }
        }
    }
    return std::nullopt;
}

std::optional<CMTime> keyframeTimeForFrame(const Clip &clip, CMTime frameStart) {
    const auto source = clip.exactSourceTimeAt(frameStart);
    if (!source) {
        return std::nullopt;
    }
    if (const auto exact = source->toTime()) {
        return exact;
    }
    // The first kPreciseTimescale tick at or after the exact time: inside the frame's span (the
    // nearest tick could fall just before it, on the previous frame).
    const CMTime tick = CMTimeMake(1, kPreciseTimescale);
    const auto index = source->frameIndex(tick, SnapMode::Ceil);
    return index ? checkedTimeForFrame(*index, tick) : std::nullopt;
}

} // namespace ve
