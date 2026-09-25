// Plain C++ (no Objective-C); an .mm file so it can later share code with Metal-side callers.

#include "Scheduler.h"

#include <algorithm>
#include <cmath>

namespace ve {

namespace {

bool anySolo(const std::vector<Track> &tracks) {
    return std::any_of(tracks.begin(), tracks.end(), [](const Track &track) { return track.solo; });
}

bool trackActive(const Track &track, bool soloActive) {
    return !track.muted && (!soloActive || track.solo);
}

VideoLayer makeLayer(const Clip &clip, const MediaAsset &asset, CMTime time) {
    VideoLayer layer;
    layer.clipId = clip.id;
    layer.assetId = clip.assetId;
    layer.trackId = clip.trackId;
    layer.isStill = clip.isStill;
    layer.sourceRotationDegrees = asset.rotationDegrees;
    layer.sourceTime = Scheduler::sourceFrameTime(clip, asset, time);
    layer.transform = Scheduler::motionAt(clip, time);
    layer.opacity = layer.transform.opacity;
    return layer;
}

// Fraction of `range` at the centre of the frame starting at `frame` (frameDuration long), clamped
// to [0, 1], computed exactly and converted to a double once: (k + 1/2) / n for frame k of a range
// of n whole frames.
double frameCentreFraction(const TimeRange &range, CMTime frame, CMTime frameDuration) {
    const auto start = ExactTime::from(range.start);
    const auto end = ExactTime::from(range.end);
    const auto at = ExactTime::from(frame);
    const auto half = ExactTime::from(frameDuration);
    const auto halfFrame = half ? half->times(Ratio{1, 2}) : std::nullopt;
    const auto centre = at && halfFrame ? at->plus(*halfFrame) : std::nullopt;
    const auto into = centre && start ? centre->minus(*start) : std::nullopt;
    const auto length = start && end ? end->minus(*start) : std::nullopt;
    if (!into || !length || length->numerator() <= 0) {
        return 0.5;
    }
    if (into->numerator() <= 0) {
        return 0.0;
    }
    if (into->compare(*length) >= 0) {
        return 1.0;
    }
    Int128 numerator = 0;
    Int128 denominator = 0;
    if (!__builtin_mul_overflow(into->numerator(), length->denominator(), &numerator) &&
        !__builtin_mul_overflow(into->denominator(), length->numerator(), &denominator) && denominator != 0) {
        return std::clamp(static_cast<double>(numerator) / static_cast<double>(denominator), 0.0, 1.0);
    }
    return std::clamp(into->toDouble() / length->toDouble(), 0.0, 1.0);
}

LayerTransition makeTransition(const TransitionPlacement &placement, double mix, bool incoming, ClipId partner,
                               std::size_t partnerIndex) {
    LayerTransition transition;
    transition.transitionId = placement.span->id;
    transition.kind = placement.span->transition;
    transition.role = placement.role;
    transition.mix = mix;
    transition.isIncoming = incoming;
    transition.partnerClipId = partner;
    transition.partnerLayerIndex = partnerIndex;
    return transition;
}

// Whether a keyframe track segment starting at `keyframe` is not linear in time (so a gain ramp
// over it is not linear in dB).
bool isEased(const Keyframe &keyframe) {
    return keyframe.interpolation != KeyframeInterpolation::Linear && keyframe.interpolation != KeyframeInterpolation::Hold;
}

} // namespace

VideoParams Scheduler::motionAt(const Clip &clip, CMTime time) {
    // The exact source time the frame shows (not snapped to the asset's frame grid), or the tick
    // after it where it has no CMTime form (motionTimeAt), held within the clip's source range
    // (spanEvaluationTime): animation moves at the sequence's frame rate, also over a slower source
    // or a still; a span holds its end value after its end, also through a tail transition handle.
    return motionValuesAt(clip, time);
}

bool Scheduler::isTrackActive(const Sequence &sequence, const Track &track) {
    return trackActive(track, anySolo(sequence.tracks(track.kind)));
}

CMTime Scheduler::sourceFrameTime(const Clip &clip, const MediaAsset &asset, CMTime time) {
    if (clip.isStill) {
        return kCMTimeZero;
    }
    const auto source = clip.exactSourceTimeAt(time);
    if (!source) {
        return clip.sourceIn; // only for a non-numeric time or 128-bit overflow
    }
    const bool inBody = clip.timelineStart <= time && time < clip.timelineEnd();
    const CMTime frame = asset.frameDuration;
    if (!asset.isVFR && isPositive(frame)) {
        // The source frame on screen at `source` is the one that starts at or before it.
        std::int64_t index = source->frameIndex(frame, SnapMode::Floor).value_or(0);
        if (inBody) {
            // Inside the clip, never a frame that starts at or after the out point (transition
            // handles, outside the body, may go past it).
            if (const auto out = clip.exactSourceOut()) {
                if (const auto firstPast = out->frameIndex(frame, SnapMode::Ceil)) {
                    index = std::min(index, *firstPast - 1);
                }
            }
        }
        // Never past the last frame of the video (which may end before the container).
        const CMTime videoEnd = asset.videoEnd();
        if (isPositive(videoEnd)) {
            const std::int64_t frames = frameIndexAt(videoEnd, frame, SnapMode::Ceil);
            index = std::min(index, frames > 0 ? frames - 1 : 0);
        }
        return timeForFrame(std::max<std::int64_t>(index, 0), frame);
    }
    // No frame grid: the mapped time itself, strictly inside the video.
    CMTime exact = source->toTimeRounded();
    const CMTime videoEnd = asset.videoEnd();
    if (isPositive(videoEnd) && exact >= videoEnd) {
        exact = videoEnd - CMTimeMake(1, videoEnd.timescale);
    }
    return maxTime(exact, kCMTimeZero);
}

RenderGraph Scheduler::renderGraphAt(const Sequence &sequence, const Project &project, CMTime time) {
    RenderGraph graph;
    graph.width = sequence.width;
    graph.height = sequence.height;
    if (!isNumeric(time)) {
        return graph;
    }
    const CMTime t = snapToFrame(time, sequence.frameDuration, SnapMode::Floor);
    graph.time = t;
    if (t < kCMTimeZero || t >= sequence.duration()) {
        return graph;
    }

    const bool soloActive = anySolo(sequence.videoTracks);
    for (const Track &track : sequence.videoTracks) {
        if (!trackActive(track, soloActive)) {
            continue;
        }
        const std::optional<TransitionPlacement> transition = transitionAt(track, t);
        if (transition && transition->role == TransitionRole::CrossDissolve && transition->partner != nullptr) {
            const Clip &from = *transition->owner;
            const Clip &to = *transition->partner;
            const MediaAsset *fromAsset = project.findAsset(from.assetId);
            const MediaAsset *toAsset = project.findAsset(to.assetId);
            if (fromAsset && toAsset) {
                // Frame k of an n-frame transition shows the mix at its centre, (k + 1/2) / n: the
                // value the audio crossfade's linear progress has at the middle of the frame.
                const double mix = frameCentreFraction(transition->range, t, sequence.frameDuration);
                const std::size_t outgoingIndex = graph.layers.size();
                VideoLayer outgoing = makeLayer(from, *fromAsset, t);
                VideoLayer incoming = makeLayer(to, *toAsset, t);
                outgoing.transition = makeTransition(*transition, mix, false, to.id, outgoingIndex + 1);
                incoming.transition = makeTransition(*transition, mix, true, from.id, outgoingIndex);
                graph.layers.push_back(std::move(outgoing));
                graph.layers.push_back(std::move(incoming));
                continue;
            }
        }
        if (const Clip *clip = track.clipAt(t)) {
            if (const MediaAsset *asset = project.findAsset(clip->assetId)) {
                VideoLayer layer = makeLayer(*clip, *asset, t);
                if (transition && transition->role != TransitionRole::CrossDissolve && transition->owner == clip) {
                    // A fade to or from black: this layer alone, weighted by the fade.
                    const double mix = frameCentreFraction(transition->range, t, sequence.frameDuration);
                    layer.transition = makeTransition(*transition, mix, transition->role == TransitionRole::FadeIn,
                                                      ClipId{}, graph.layers.size());
                }
                graph.layers.push_back(std::move(layer));
            }
        }
    }
    return graph;
}

RenderGraph Scheduler::soloGraphAt(const Sequence &sequence, const Project &project, ClipId clipId, CMTime time,
                                   bool identityMotion) {
    RenderGraph graph;
    graph.width = sequence.width;
    graph.height = sequence.height;
    if (!isNumeric(time) || !isPositive(sequence.frameDuration)) {
        return graph;
    }
    const CMTime fd = sequence.frameDuration;
    graph.time = snapToFrame(time, fd, SnapMode::Floor);
    const std::optional<ClipLocation> location = sequence.locateClip(clipId);
    if (!location || location->trackKind != TrackKind::Video) {
        return graph;
    }
    const Clip &clip = *sequence.findClip(clipId);
    const MediaAsset *asset = project.findAsset(clip.assetId);
    if (!asset || !(clip.timelineDuration > kCMTimeZero)) {
        return graph;
    }
    // The clip's frames on the sequence grid: from the first frame starting at or after its start
    // to the last frame starting before its end (clips are placed on whole frames, so these are
    // its first and last frames).
    const std::int64_t first = frameIndexAt(clip.timelineStart, fd, SnapMode::Ceil);
    const std::int64_t last = std::max(first, frameIndexAt(clip.timelineEnd(), fd, SnapMode::Ceil) - 1);
    const std::int64_t wanted = frameIndexAt(graph.time, fd, SnapMode::Floor);
    CMTime held = timeForFrame(std::clamp(wanted, first, last), fd);
    if (held < clip.timelineStart || held >= clip.timelineEnd()) {
        held = clip.timelineStart; // a clip shorter than a frame, off the grid
    }
    VideoLayer layer = makeLayer(clip, *asset, held);
    if (identityMotion) {
        layer.transform = VideoParams{};
        layer.opacity = 1.0;
    }
    graph.layers.push_back(std::move(layer));
    return graph;
}

AudioGraph Scheduler::audioGraphFor(const Sequence &sequence, const Project &project, CMTimeRange range) {
    return audioGraphFor(sequence, project, TimeRange::fromCMTimeRange(range));
}

AudioGraph Scheduler::audioGraphFor(const Sequence &sequence, const Project &project, const TimeRange &range) {
    AudioGraph graph;
    graph.range = range;
    graph.sampleRate = sequence.audioSampleRate;
    if (!isNumeric(range.start) || !isNumeric(range.end) || range.isEmpty()) {
        return graph;
    }

    const bool soloActive = anySolo(sequence.audioTracks);
    for (const Track &track : sequence.audioTracks) {
        if (!trackActive(track, soloActive)) {
            continue;
        }
        // Only clips near the range can contribute: the clip before the first one starting in the
        // range may span into it, and the one before that may reach it through a transition
        // tail. Past the range end, only a clip whose incoming dissolve starts inside it counts.
        const std::size_t firstStarting = track.firstClipStartingAtOrAfter(range.start);
        for (std::size_t index = firstStarting >= 2 ? firstStarting - 2 : 0; index < track.clips.size(); ++index) {
            const Clip &clip = track.clips[index];
            // The cross dissolve into this clip (owned by the clip touching its start).
            std::optional<TransitionPlacement> head;
            if (const Clip *previous = touchingClip(track, clip, ClipEdge::Head)) {
                if (const EffectSpan *span = previous->transitionAt(ClipEdge::Tail)) {
                    head = placeTransition(track, *previous, *span);
                    if (head && head->role != TransitionRole::CrossDissolve) {
                        head.reset();
                    }
                }
            }
            if (clip.timelineStart >= range.end && (!head || head->range.start >= range.end)) {
                break;
            }
            const MediaAsset *asset = project.findAsset(clip.assetId);
            if (!asset) {
                continue;
            }
            const TimeRange clipRange = clip.timelineRange();
            // The clip's own lane-0 spans: a cross dissolve out of it, or fades.
            std::optional<TransitionPlacement> tail;
            std::optional<TimeRange> fadeInRange;
            std::optional<TimeRange> fadeOutRange;
            for (const ClipEdge edge : {ClipEdge::Head, ClipEdge::Tail}) {
                const EffectSpan *span = clip.transitionAt(edge);
                const auto placement = span ? placeTransition(track, clip, *span) : std::nullopt;
                if (!placement) {
                    continue;
                }
                switch (placement->role) {
                case TransitionRole::CrossDissolve:
                    if (placement->partner != nullptr) {
                        tail = placement;
                    }
                    break;
                case TransitionRole::FadeOut:
                    fadeOutRange = placement->range;
                    break;
                case TransitionRole::FadeIn:
                    fadeInRange = placement->range;
                    break;
                }
            }

            // The clip sounds over its own range plus the transition handles around it.
            TimeRange span = clipRange;
            if (head) {
                span.start = minTime(span.start, head->range.start);
            }
            if (tail) {
                span.end = maxTime(span.end, tail->range.end);
            }
            const auto active = intersection(span, range);
            if (!active) {
                continue;
            }

            auto fadeAt = [&](CMTime t) {
                const CMTime c = clampTime(t, clipRange.start, clipRange.end);
                double g = 1.0;
                if (fadeInRange) {
                    g *= std::min(1.0, toSeconds(c - clipRange.start) / toSeconds(fadeInRange->duration()));
                }
                if (fadeOutRange) {
                    g *= std::min(1.0, toSeconds(clipRange.end - c) / toSeconds(fadeOutRange->duration()));
                }
                return g;
            };

            std::vector<CMTime> cuts{active->start, active->end};
            auto addCut = [&](CMTime t) {
                if (isNumeric(t) && active->start < t && t < active->end) {
                    cuts.push_back(t);
                }
            };
            addCut(clipRange.start);
            addCut(clipRange.end);
            for (const auto &fade : {fadeInRange, fadeOutRange}) {
                if (fade) {
                    addCut(fade->start);
                    addCut(fade->end);
                }
            }
            for (const auto &transition : {head, tail}) {
                if (transition) {
                    addCut(transition->range.start);
                    addCut(transition->range.end);
                }
            }
            // Gain spans: their edges and keyframes, and fine steps through eased segments (only
            // there: before a span's start it adds nothing and after its end it holds its end value,
            // both flat).
            for (const EffectSpan &gain : clip.spans) {
                if (gain.kind != SpanKind::Gain) {
                    continue;
                }
                auto timelineOf = [&](CMTime source) {
                    const auto at = clip.exactTimelineTimeAt(source);
                    return at ? at->toTimeRounded() : kCMTimeInvalid;
                };
                addCut(timelineOf(gain.start));
                addCut(timelineOf(gain.end));
                const KeyframeTrack &keys = gain.tracks.gain;
                for (std::size_t k = 0; k < keys.size(); ++k) {
                    const auto source = checkedAdd(gain.start, keys[k].time);
                    if (!source) {
                        continue;
                    }
                    const CMTime at = timelineOf(*source);
                    addCut(at);
                    if (k + 1 < keys.size() && isEased(keys[k])) {
                        const auto next = checkedAdd(gain.start, keys[k + 1].time);
                        const CMTime nextAt = next ? timelineOf(*next) : kCMTimeInvalid;
                        if (!isNumeric(at) || !isNumeric(nextAt)) {
                            continue;
                        }
                        const double seconds = toSeconds(nextAt - at);
                        const auto steps = static_cast<std::int64_t>(std::ceil(seconds / kEasedGainStep));
                        if (const auto within = stepsWithin(at, nextAt, steps, *active)) {
                            for (std::int64_t step = within->first; step <= within->second; ++step) {
                                addCut(at + scaleTime(nextAt - at, Ratio{step, steps}));
                            }
                        }
                    }
                }
            }
            std::sort(cuts.begin(), cuts.end(), [](CMTime a, CMTime b) { return a < b; });
            cuts.erase(std::unique(cuts.begin(), cuts.end(), [](CMTime a, CMTime b) { return a == b; }), cuts.end());

            const bool hasGainSpans =
                std::any_of(clip.spans.begin(), clip.spans.end(), [](const EffectSpan &s) { return s.kind == SpanKind::Gain; });
            // The level over [a, b): the static gain plus what the Gain spans acting over the piece
            // contribute (composeGainDb's order and rule: the moving value inside a span, its end
            // value held after it, a later span on the lane on top), at a and as b is approached. The
            // pieces are cut at every span edge and keyframe, so over a piece each span is either
            // one segment of its ramp or its held level, flat. Whether a span acts is decided at the
            // piece's middle: a span edge whose timeline time has no CMTime is cut at the nearest
            // tick, which may lie a hair before the span's start, and deciding at `a` left the whole
            // piece without the span (review L10); the piece then starts at the span's start value.
            auto levelOver = [&](CMTime a, CMTime b) {
                DecibelRamp level{clip.audio.gainDb, clip.audio.gainDb};
                if (!hasGainSpans) {
                    return level;
                }
                const auto from = spanEvaluationTime(clip, a);
                const auto to = spanEvaluationTime(clip, b);
                if (!from || !to) {
                    return level;
                }
                const bool instant = from->compare(*to) == 0;
                const auto middle = instant ? from : spanEvaluationTime(clip, a + scaleTime(b - a, Ratio{1, 2}));
                if (!middle) {
                    return level;
                }
                for (int lane = kFirstEffectLane; lane <= kLastLane; ++lane) {
                    for (const EffectSpan &gain : clip.spans) {
                        if (gain.lane != lane || gain.kind != SpanKind::Gain || !spanActsAt(gain, *middle)) {
                            continue;
                        }
                        const auto spanStart = ExactTime::from(gain.start);
                        const ExactTime first = spanActsAt(gain, *from) || !spanStart ? *from : *spanStart;
                        level.start += spanContributionAt(gain, SpanParameter::Gain, first);
                        level.end += instant ? spanContributionAt(gain, SpanParameter::Gain, *to)
                                             : spanContributionFromLeft(gain, SpanParameter::Gain, *to);
                    }
                }
                return level;
            };

            for (std::size_t i = 0; i + 1 < cuts.size(); ++i) {
                const TimeRange piece{cuts[i], cuts[i + 1]};
                AudioSegment segment;
                segment.clipId = clip.id;
                segment.assetId = clip.assetId;
                segment.trackId = track.id;
                segment.timelineRange = piece;
                segment.sourceRange = TimeRange{clip.sourceTimeAt(piece.start), clip.sourceTimeAt(piece.end)};
                segment.speed = clip.speedValue();
                segment.speedRatio = clip.speedRatio();
                segment.level = levelOver(piece.start, piece.end);
                segment.fade = GainRamp{fadeAt(piece.start), fadeAt(piece.end)};
                if (head && head->range.contains(piece)) {
                    segment.crossfade =
                        GainRamp{fractionThrough(head->range, piece.start), fractionThrough(head->range, piece.end)};
                    segment.transitionId = head->span->id;
                    segment.crossfadePartner = head->owner->id;
                } else if (tail && tail->range.contains(piece)) {
                    segment.crossfade = GainRamp{1.0 - fractionThrough(tail->range, piece.start),
                                                 1.0 - fractionThrough(tail->range, piece.end)};
                    segment.transitionId = tail->span->id;
                    segment.crossfadePartner = tail->partner->id;
                }
                graph.segments.push_back(segment);
            }
        }
    }
    return graph;
}

std::optional<std::pair<std::int64_t, std::int64_t>> Scheduler::stepsWithin(CMTime from, CMTime to,
                                                                                std::int64_t steps,
                                                                                const TimeRange &window) {
    if (steps < 2 || !isNumeric(from) || !isNumeric(to) || !(from < to)) {
        return std::nullopt;
    }
    // Step k lies at from + (to - from) * k / steps; the window's edges give k in doubles, widened by
    // one on each side for rounding (the caller filters exactly).
    const double length = toSeconds(to - from);
    const double lo = std::floor(toSeconds(window.start - from) / length * static_cast<double>(steps)) - 1;
    const double hi = std::ceil(toSeconds(window.end - from) / length * static_cast<double>(steps)) + 1;
    const double first = std::max(1.0, lo);
    const double last = std::min(static_cast<double>(steps - 1), hi);
    if (!(first <= last)) {
        return std::nullopt;
    }
    return std::make_pair(static_cast<std::int64_t>(first), static_cast<std::int64_t>(last));
}

std::optional<ClipId> Scheduler::clipAt(const Sequence &sequence, TrackId trackId, CMTime time) {
    const Track *track = sequence.findTrack(trackId);
    if (!track) {
        return std::nullopt;
    }
    const Clip *clip = track->clipAt(time);
    return clip ? std::optional<ClipId>(clip->id) : std::nullopt;
}

std::vector<ClipId> Scheduler::clipsAt(const Sequence &sequence, CMTime time) {
    std::vector<ClipId> result;
    for (const TrackKind kind : {TrackKind::Video, TrackKind::Audio}) {
        for (const Track &track : sequence.tracks(kind)) {
            if (const Clip *clip = track.clipAt(time)) {
                result.push_back(clip->id);
            }
        }
    }
    return result;
}

} // namespace ve
