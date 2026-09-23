#include "Clip.h"

namespace ve {

bool isValidSpeed(Ratio speed) {
    return speed.isReduced() && speed.num > 0 && speed.den <= kMaxSpeedDenominator && !(speed < Ratio{1, 100}) &&
           !(Ratio{100, 1} < speed);
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

} // namespace ve
