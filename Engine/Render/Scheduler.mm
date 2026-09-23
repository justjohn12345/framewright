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
    layer.transform = clip.video;
    layer.opacity = clip.video.opacity;
    return layer;
}

double dbToLinear(double db) {
    return std::pow(10.0, db / 20.0);
}

} // namespace

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
        if (const Transition *transition = sequence.transitionAt(track.id, t)) {
            const Clip *from = track.find(transition->fromClipId);
            const Clip *to = track.find(transition->toClipId);
            const MediaAsset *fromAsset = from ? project.findAsset(from->assetId) : nullptr;
            const MediaAsset *toAsset = to ? project.findAsset(to->assetId) : nullptr;
            if (fromAsset && toAsset) {
                // Frame k of an n-frame transition shows the mix at its centre, (k + 1/2) / n: the
                // value the audio crossfade's linear progress has at the middle of the frame.
                const TimeRange range = *sequence.transitionRange(*transition);
                const std::int64_t k = frameIndexAt(t - range.start, sequence.frameDuration, SnapMode::Floor);
                const std::int64_t n = frameIndexAt(range.duration(), sequence.frameDuration, SnapMode::Round);
                const double mix = n > 0 ? (static_cast<double>(k) + 0.5) / static_cast<double>(n) : 0.5;
                const std::size_t outgoingIndex = graph.layers.size();
                VideoLayer outgoing = makeLayer(*from, *fromAsset, t);
                VideoLayer incoming = makeLayer(*to, *toAsset, t);
                outgoing.transition =
                    LayerTransition{transition->id, transition->kind, mix, false, to->id, outgoingIndex + 1};
                incoming.transition =
                    LayerTransition{transition->id, transition->kind, mix, true, from->id, outgoingIndex};
                graph.layers.push_back(std::move(outgoing));
                graph.layers.push_back(std::move(incoming));
                continue;
            }
        }
        if (const Clip *clip = track.clipAt(t)) {
            if (const MediaAsset *asset = project.findAsset(clip->assetId)) {
                graph.layers.push_back(makeLayer(*clip, *asset, t));
            }
        }
    }
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
        // tail. Past the range end, only a clip whose head transition starts inside it counts.
        const std::size_t firstStarting = track.firstClipStartingAtOrAfter(range.start);
        for (std::size_t index = firstStarting >= 2 ? firstStarting - 2 : 0; index < track.clips.size(); ++index) {
            const Clip &clip = track.clips[index];
            const Transition *head = sequence.transitionTo(clip.id);
            const std::optional<TimeRange> headRange = head ? sequence.transitionRange(*head) : std::nullopt;
            if (clip.timelineStart >= range.end && (!headRange || headRange->start >= range.end)) {
                break;
            }
            const MediaAsset *asset = project.findAsset(clip.assetId);
            if (!asset) {
                continue;
            }
            const TimeRange clipRange = clip.timelineRange();
            const Transition *tail = sequence.transitionFrom(clip.id);
            const std::optional<TimeRange> tailRange = tail ? sequence.transitionRange(*tail) : std::nullopt;

            // The clip sounds over its own range plus the transition handles around it.
            TimeRange span = clipRange;
            if (headRange) {
                span.start = minTime(span.start, headRange->start);
            }
            if (tailRange) {
                span.end = maxTime(span.end, tailRange->end);
            }
            const auto active = intersection(span, range);
            if (!active) {
                continue;
            }

            // A crossfade replaces the clip's own fade on that edge.
            const CMTime fadeIn = headRange ? kCMTimeZero : clip.audio.fadeInDuration;
            const CMTime fadeOut = tailRange ? kCMTimeZero : clip.audio.fadeOutDuration;
            auto fadeAt = [&](CMTime t) {
                const CMTime c = clampTime(t, clipRange.start, clipRange.end);
                double g = 1.0;
                if (isPositive(fadeIn)) {
                    g *= std::min(1.0, toSeconds(c - clipRange.start) / toSeconds(fadeIn));
                }
                if (isPositive(fadeOut)) {
                    g *= std::min(1.0, toSeconds(clipRange.end - c) / toSeconds(fadeOut));
                }
                return g;
            };

            std::vector<CMTime> cuts{active->start, active->end};
            auto addCut = [&](CMTime t) {
                if (active->start < t && t < active->end) {
                    cuts.push_back(t);
                }
            };
            addCut(clipRange.start);
            addCut(clipRange.end);
            if (isPositive(fadeIn)) {
                addCut(clipRange.start + fadeIn);
            }
            if (isPositive(fadeOut)) {
                addCut(clipRange.end - fadeOut);
            }
            for (const auto &transitionRange : {headRange, tailRange}) {
                if (transitionRange) {
                    addCut(transitionRange->start);
                    addCut(transitionRange->end);
                }
            }
            std::sort(cuts.begin(), cuts.end(), [](CMTime a, CMTime b) { return a < b; });
            cuts.erase(std::unique(cuts.begin(), cuts.end(), [](CMTime a, CMTime b) { return a == b; }), cuts.end());

            const double gain = dbToLinear(clip.audio.gainDb);
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
                segment.gain = gain;
                segment.fade = GainRamp{fadeAt(piece.start), fadeAt(piece.end)};
                if (headRange && headRange->contains(piece)) {
                    segment.crossfade =
                        GainRamp{fractionThrough(*headRange, piece.start), fractionThrough(*headRange, piece.end)};
                    segment.transitionId = head->id;
                    segment.crossfadePartner = head->fromClipId;
                } else if (tailRange && tailRange->contains(piece)) {
                    segment.crossfade = GainRamp{1.0 - fractionThrough(*tailRange, piece.start),
                                                 1.0 - fractionThrough(*tailRange, piece.end)};
                    segment.transitionId = tail->id;
                    segment.crossfadePartner = tail->toClipId;
                }
                graph.segments.push_back(segment);
            }
        }
    }
    return graph;
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
