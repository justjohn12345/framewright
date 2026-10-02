#include "Clip.h"

#include "TransitionRules.h"

#include "Track.h"

#include <algorithm>
#include <cmath>

namespace ve {

namespace {

// The clip value a span parameter composes onto (its static value; Clip.h, "Composition"): the
// picture's placement and opacity, or the sound's gain.
template <typename Video, typename Audio>
auto &composedValue(Video &video, Audio &audio, SpanParameter parameter) {
    switch (parameter) {
    case SpanParameter::X:
        return video.x;
    case SpanParameter::Y:
        return video.y;
    case SpanParameter::Scale:
        return video.scale;
    case SpanParameter::Rotation:
        return video.rotationDegrees;
    case SpanParameter::Opacity:
        return video.opacity;
    case SpanParameter::Gain:
        return audio.gainDb;
    }
    return video.x;
}

// Applies what `span` contributes at `time` on top of `video` and `audio` (composeMotion,
// composeGainDb): each of its parameters composed (composeSpanValue: offsets add, factors multiply).
void composeSpanOnto(VideoParams &video, AudioParams &audio, const EffectSpan &span, const ExactTime &time) {
    for (const SpanParameter parameter : infoOf(span.kind).parameters) {
        double &value = composedValue(video, audio, parameter);
        value = composeSpanValue(parameter, value, spanContributionAt(span, parameter, time));
    }
}

// Whether `span`'s kind changes the picture (its spans go on video tracks) or the sound (audio).
bool changesTrackOfKind(const EffectSpan &span, TrackKind kind) {
    return infoOf(span.kind).trackKind == kind;
}

// Calls `apply` for every effect span of `spans` that `include` accepts, lane 1, 2, 3 and within a
// lane in the vector's (start) order: the order the composition applies them in.
template <typename Include, typename Apply>
void forEachInCompositionOrder(const std::vector<EffectSpan> &spans, Include include, Apply apply) {
    for (int lane = kFirstEffectLane; lane <= kLastLane; ++lane) {
        for (const EffectSpan &span : spans) {
            if (span.lane == lane && include(span)) {
                apply(span);
            }
        }
    }
}

bool isFinite(const VideoParams &values) {
    return std::isfinite(values.x) && std::isfinite(values.y) && std::isfinite(values.scale) &&
           std::isfinite(values.rotationDegrees) && std::isfinite(values.opacity);
}

} // namespace

bool isValidSpeed(Ratio speed) {
    return speed.isReduced() && speed.num > 0 && speed.den <= kMaxSpeedDenominator && !(speed < Ratio{1, 100}) &&
           !(Ratio{100, 1} < speed);
}

const char *nameOf(MotionParameter parameter) {
    switch (parameter) {
    case MotionParameter::X:
        return "x";
    case MotionParameter::Y:
        return "y";
    case MotionParameter::Scale:
        return "scale";
    case MotionParameter::Rotation:
        return "rotation";
    case MotionParameter::Opacity:
        return "opacity";
    }
    return "x";
}

const char *displayNameOf(MotionParameter parameter) {
    return displayNameOf(spanParameterOf(parameter));
}

SpanParameter spanParameterOf(MotionParameter parameter) {
    switch (parameter) {
    case MotionParameter::X:
        return SpanParameter::X;
    case MotionParameter::Y:
        return SpanParameter::Y;
    case MotionParameter::Scale:
        return SpanParameter::Scale;
    case MotionParameter::Rotation:
        return SpanParameter::Rotation;
    case MotionParameter::Opacity:
        return SpanParameter::Opacity;
    }
    return SpanParameter::X;
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

bool operator==(const Clip &a, const Clip &b) {
    return a.id == b.id && a.assetId == b.assetId && a.trackId == b.trackId &&
           identical(a.timelineStart, b.timelineStart) && identical(a.timelineDuration, b.timelineDuration) &&
           identical(a.sourceIn, b.sourceIn) && a.speed == b.speed && a.isStill == b.isStill &&
           a.reversed == b.reversed &&
           a.linkedClipId == b.linkedClipId && a.video == b.video && a.audio == b.audio && a.grade == b.grade &&
           a.transitions == b.transitions && a.spans == b.spans;
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

std::optional<ExactTime> mediaTimeOfFrame(const Clip &clip, CMTime frameStart, CMTime frameDuration, CMTime mediaEnd) {
    if (!clip.reversed || clip.isStill) {
        return clip.exactSourceTimeAt(frameStart);
    }
    // u(frameStart + frameDuration) = u(frameStart) + frameDuration * speed, in exact arithmetic.
    const auto start = clip.exactSourceTimeAt(frameStart);
    const auto length = ExactTime::from(frameDuration);
    const auto step = length ? length->times(clip.speedRatio()) : std::nullopt;
    const auto clipTime = start && step ? start->plus(*step) : std::nullopt;
    const auto mirror = ExactTime::from(mediaEnd);
    return mirror && clipTime ? mirror->minus(*clipTime) : std::nullopt;
}

std::optional<std::pair<ExactTime, ExactTime>> mediaRangeOf(const Clip &clip, CMTime mediaEnd) {
    const auto in = ExactTime::from(clip.isStill ? kCMTimeZero : clip.sourceIn);
    const auto out = clip.exactSourceOut();
    if (!in || !out) {
        return std::nullopt;
    }
    if (!clip.reversed || clip.isStill) {
        return std::make_pair(*in, *out);
    }
    const auto mirror = ExactTime::from(mediaEnd);
    const auto first = mirror ? mirror->minus(*out) : std::nullopt;
    const auto last = mirror ? mirror->minus(*in) : std::nullopt;
    if (!first || !last) {
        return std::nullopt;
    }
    return std::make_pair(*first, *last);
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

std::optional<std::pair<CMTime, CMTime>> Clip::spanBounds() const {
    if (isStill) {
        return std::make_pair(kCMTimeZero, timelineDuration);
    }
    const auto out = exactSourceOut();
    if (!out) {
        return std::nullopt;
    }
    if (const auto exact = out->toTime()) {
        return std::make_pair(sourceIn, *exact);
    }
    // No CMTime form: the tick before the out point (no frame of the clip starts after it).
    const CMTime tick = CMTimeMake(1, kPreciseTimescale);
    const auto index = out->frameIndex(tick, SnapMode::Floor);
    const auto bound = index ? checkedTimeForFrame(*index, tick) : std::nullopt;
    if (!bound) {
        return std::nullopt;
    }
    return std::make_pair(sourceIn, *bound);
}

RetimeResult Clip::setTimelineStartKeepingEnd(CMTime newStart) {
    const auto delta = checkedSubtract(newStart, timelineStart);
    if (!delta) {
        return RetimeResult::NotRepresentable;
    }
    const auto duration = checkedSubtract(timelineDuration, *delta);
    if (!duration) {
        return RetimeResult::NotRepresentable;
    }
    Clip moved = *this;
    if (isStill) {
        // A still's source time is measured from its start: its effect spans move back by the
        // change so they keep their timeline positions.
        const auto back = checkedNegate(*delta);
        if (!back) {
            return RetimeResult::NotRepresentable;
        }
        for (EffectSpan &span : moved.spans) {
            const auto start = checkedAdd(span.start, *back);
            const auto end = checkedAdd(span.end, *back);
            if (!start || !end || !isExactModelTime(*start) || !isExactModelTime(*end)) {
                return RetimeResult::NotRepresentable;
            }
            span.start = *start;
            span.end = *end;
        }
    } else {
        const auto scaled = checkedScale(*delta, speed);
        const auto in = scaled ? checkedAdd(sourceIn, *scaled) : std::nullopt;
        if (!in || !isExactModelTime(*in)) {
            return RetimeResult::NotRepresentable;
        }
        moved.sourceIn = *in;
    }
    moved.timelineStart = newStart;
    moved.timelineDuration = *duration;
    if (const RetimeResult fitted = moved.fitSpans(ClipEdge::Head); fitted != RetimeResult::Ok) {
        return fitted;
    }
    *this = std::move(moved);
    return RetimeResult::Ok;
}

RetimeResult Clip::setTimelineEnd(CMTime newEnd) {
    const auto duration = checkedSubtract(newEnd, timelineStart);
    if (!duration) {
        return RetimeResult::NotRepresentable;
    }
    Clip moved = *this;
    moved.timelineDuration = *duration;
    if (isStill) {
        moved.sourceIn = kCMTimeZero;
    }
    if (const RetimeResult fitted = moved.fitSpans(ClipEdge::Tail); fitted != RetimeResult::Ok) {
        return fitted;
    }
    *this = std::move(moved);
    return RetimeResult::Ok;
}

RetimeResult Clip::fitSpans(ClipEdge editedEdge) {
    const auto bounds = spanBounds();
    if (!bounds) {
        return RetimeResult::NotRepresentable;
    }
    // Effect spans wholly before the in bound hold their end values over every frame left: those
    // values move into the static values, composed in the composition's order.
    VideoParams heldVideo = video;
    AudioParams heldAudio = audio;
    const auto in = ExactTime::from(bounds->first);
    if (!in) {
        return RetimeResult::NotRepresentable;
    }
    bool held = false;
    forEachInCompositionOrder(
        spans, [&](const EffectSpan &span) { return !(bounds->first < span.end); },
        [&](const EffectSpan &span) {
            held = true;
            composeSpanOnto(heldVideo, heldAudio, span, *in);
        });
    if (held && (!isFinite(heldVideo) || !std::isfinite(heldAudio.gainDb))) {
        return RetimeResult::HeldValuesOverflow;
    }

    std::vector<EffectSpan> fitted;
    fitted.reserve(spans.size());
    for (const EffectSpan &span : spans) {
        SpanCutProblem problem = SpanCutProblem::None;
        if (auto clipped = clipSpan(span, bounds->first, bounds->second, &problem)) {
            fitted.push_back(std::move(*clipped));
        } else if (problem == SpanCutProblem::CurveOvershoot) {
            return RetimeResult::SpanCurveOvershoot;
        } else if (problem == SpanCutProblem::NotRepresentable) {
            return RetimeResult::NotRepresentable;
        }
        // Otherwise nothing of the span is left inside the clip: it goes.
    }

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
        // The fade that gives way keeps the room the other leaves (TransitionRules.h).
        const bool headGivesWay = head != nullptr && (!tailIsFade || editedEdge == ClipEdge::Head);
        if (headGivesWay) {
            const auto rest = TransitionRules::fadeRoomBeside(length, tailInside);
            if (!rest) {
                return RetimeResult::NotRepresentable;
            }
            headLength = *rest;
        } else if (tailIsFade) {
            const auto rest = TransitionRules::fadeRoomBeside(length, headLength);
            if (!rest) {
                return RetimeResult::NotRepresentable;
            }
            tailInside = *rest;
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
    spans = std::move(fitted);
    video = heldVideo;
    audio.gainDb = heldAudio.gainDb;
    return RetimeResult::Ok;
}

void Clip::sortSpans() {
    std::stable_sort(transitions.begin(), transitions.end(), [](const TransitionSpan &a, const TransitionSpan &b) {
        return a.edge == ClipEdge::Head && b.edge == ClipEdge::Tail;
    });
    std::stable_sort(spans.begin(), spans.end(), [](const EffectSpan &a, const EffectSpan &b) {
        return a.lane != b.lane ? a.lane < b.lane : a.start < b.start;
    });
}

const EffectSpan *Clip::findSpan(SpanId spanId) const {
    for (const EffectSpan &span : spans) {
        if (span.id == spanId) {
            return &span;
        }
    }
    return nullptr;
}

const TransitionSpan *Clip::findTransition(SpanId spanId) const {
    for (const TransitionSpan &span : transitions) {
        if (span.id == spanId) {
            return &span;
        }
    }
    return nullptr;
}

TransitionSpan *Clip::findTransition(SpanId spanId) {
    return const_cast<TransitionSpan *>(static_cast<const Clip *>(this)->findTransition(spanId));
}

EffectSpan *Clip::findSpan(SpanId spanId) {
    return const_cast<EffectSpan *>(static_cast<const Clip *>(this)->findSpan(spanId));
}

const TransitionSpan *Clip::transitionAt(ClipEdge edge) const {
    for (const TransitionSpan &span : transitions) {
        if (span.edge == edge) {
            return &span;
        }
    }
    return nullptr;
}

TransitionSpan *Clip::transitionAt(ClipEdge edge) {
    return const_cast<TransitionSpan *>(static_cast<const Clip *>(this)->transitionAt(edge));
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

namespace {

// The first kPreciseTimescale tick at or after `source` (which has no CMTime form): inside the
// frame's span (the nearest tick could fall just before it, on the previous frame).
std::optional<CMTime> tickAtOrAfter(const ExactTime &source) {
    const CMTime tick = CMTimeMake(1, kPreciseTimescale);
    const auto index = source.frameIndex(tick, SnapMode::Ceil);
    return index ? checkedTimeForFrame(*index, tick) : std::nullopt;
}

} // namespace

std::optional<ExactTime> motionTimeAt(const Clip &clip, CMTime t) {
    const auto source = clip.exactSourceTimeAt(t);
    if (!source || source->toTime()) {
        return source;
    }
    const auto tick = tickAtOrAfter(*source);
    return tick ? ExactTime::from(*tick) : std::nullopt;
}

std::optional<CMTime> spanTimeAt(const Clip &clip, CMTime t) {
    const auto source = clip.exactSourceTimeAt(t);
    const auto bounds = clip.spanBounds();
    if (!source || !bounds) {
        return std::nullopt;
    }
    std::optional<CMTime> time = source->toTime();
    if (!time) {
        time = tickAtOrAfter(*source);
    }
    if (!time) {
        return std::nullopt;
    }
    return clampTime(*time, bounds->first, bounds->second);
}

std::optional<ExactTime> spanEvaluationTime(const Clip &clip, CMTime t) {
    const auto time = motionTimeAt(clip, t);
    const auto bounds = clip.spanBounds();
    const auto in = bounds ? ExactTime::from(bounds->first) : std::nullopt;
    const auto out = bounds ? ExactTime::from(bounds->second) : std::nullopt;
    if (!time || !in || !out) {
        return std::nullopt;
    }
    if (time->compare(*in) < 0) {
        return in;
    }
    if (time->compare(*out) > 0) {
        return out;
    }
    return time;
}

double clipValueOf(const VideoParams &video, const AudioParams &audio, SpanParameter parameter) {
    return composedValue(video, audio, parameter);
}

VideoParams composeMotion(const Clip &clip, const ExactTime &time, std::optional<SpanId> except) {
    VideoParams values = clip.video;
    AudioParams unused = clip.audio;
    forEachInCompositionOrder(
        clip.spans,
        [&](const EffectSpan &span) {
            return changesTrackOfKind(span, TrackKind::Video) && !(except && span.id == *except) &&
                   spanActsAt(span, time);
        },
        [&](const EffectSpan &span) { composeSpanOnto(values, unused, span, time); });
    return values;
}

double composeGainDb(const Clip &clip, const ExactTime &time, std::optional<SpanId> except) {
    VideoParams unused = clip.video;
    AudioParams values = clip.audio;
    forEachInCompositionOrder(
        clip.spans,
        [&](const EffectSpan &span) {
            return changesTrackOfKind(span, TrackKind::Audio) && !(except && span.id == *except) &&
                   spanActsAt(span, time);
        },
        [&](const EffectSpan &span) { composeSpanOnto(unused, values, span, time); });
    return values.gainDb;
}

VideoParams motionValuesAt(const Clip &clip, CMTime t) {
    if (!clip.hasEffectSpans()) {
        return clip.video;
    }
    const auto time = spanEvaluationTime(clip, t);
    return time ? composeMotion(clip, *time) : clip.video;
}

double gainDbAt(const Clip &clip, CMTime t) {
    if (!clip.hasEffectSpans()) {
        return clip.audio.gainDb;
    }
    const auto time = spanEvaluationTime(clip, t);
    return time ? composeGainDb(clip, *time) : clip.audio.gainDb;
}

std::optional<ExactTime> spanEdgeFrameTime(const Clip &clip, const EffectSpan &span, CMTime frameDuration, bool atEnd) {
    if (!atEnd) {
        return ExactTime::from(span.start);
    }
    const auto end = clip.exactTimelineTimeAt(span.end);
    if (!end) {
        return std::nullopt;
    }
    const std::int64_t endFrame = frameIndexAt(end->toTimeRounded(), frameDuration, SnapMode::Ceil);
    const auto last = checkedTimeForFrame(endFrame - 1, frameDuration);
    if (!last) {
        return std::nullopt;
    }
    return spanEvaluationTime(clip, maxTime(*last, clip.timelineStart));
}

std::optional<VideoParams> spanEdgeMotion(const Clip &clip, const EffectSpan &span, CMTime frameDuration, bool atEnd) {
    if (span.kind != SpanKind::Motion) {
        return std::nullopt;
    }
    const auto time = spanEdgeFrameTime(clip, span, frameDuration, atEnd);
    if (!time) {
        return std::nullopt;
    }
    VideoParams values = composeMotion(clip, *time, span.id);
    AudioParams unused = clip.audio;
    for (const SpanParameter parameter : infoOf(span.kind).parameters) {
        double &value = composedValue(values, unused, parameter);
        value = composeSpanValue(parameter, value, spanEdgeValue(span, parameter, atEnd));
    }
    return values;
}

} // namespace ve
