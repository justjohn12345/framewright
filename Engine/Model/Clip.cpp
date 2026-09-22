#include "Clip.h"

namespace ve {

bool operator==(const AudioParams &a, const AudioParams &b) {
    return a.gainDb == b.gainDb && identical(a.fadeInDuration, b.fadeInDuration) &&
           identical(a.fadeOutDuration, b.fadeOutDuration);
}

bool operator==(const Clip &a, const Clip &b) {
    return a.id == b.id && a.assetId == b.assetId && a.trackId == b.trackId &&
           identical(a.timelineStart, b.timelineStart) && identical(a.sourceIn, b.sourceIn) &&
           identical(a.sourceOut, b.sourceOut) && a.speed == b.speed && a.isStill == b.isStill &&
           a.linkedClipId == b.linkedClipId && a.video == b.video && a.audio == b.audio;
}

Ratio Clip::speedRatio() const {
    if (isStill) {
        return Ratio{1, 1};
    }
    return approximateRatio(speed, kMaxSpeedDenominator);
}

CMTime Clip::duration() const {
    return scaleTime(sourceDuration(), speedRatio().inverse());
}

CMTime Clip::sourceTimeAt(CMTime t) const {
    return sourceIn + scaleTime(t - timelineStart, speedRatio());
}

CMTime Clip::timelineTimeAt(CMTime s) const {
    return timelineStart + scaleTime(s - sourceIn, speedRatio().inverse());
}

void Clip::setTimelineStartKeepingEnd(CMTime newStart) {
    if (isStill) {
        const CMTime end = timelineEnd();
        timelineStart = newStart;
        sourceIn = kCMTimeZero;
        sourceOut = end - newStart;
        return;
    }
    sourceIn = sourceTimeAt(newStart);
    timelineStart = newStart;
}

void Clip::setTimelineEnd(CMTime newEnd) {
    if (isStill) {
        sourceIn = kCMTimeZero;
        sourceOut = newEnd - timelineStart;
        return;
    }
    sourceOut = sourceTimeAt(newEnd);
}

} // namespace ve
