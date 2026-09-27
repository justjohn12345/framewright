// Reversed clips (Clip.h, "Reverse"): the mirror rule by frame index (frame k of a reversed clip
// shows exactly what frame n - 1 - k showed forward, at any speed, on an NTSC grid and on a VFR
// source), SetClipReversed (undo, the linked partner, refusals, spans keeping their frames, a
// dissolve whose handles are gone), and the edits that must keep a reversed clip's pictures: split,
// head and tail trims, a speed change, a Motion span across a trim.

#include "../../Engine/Edit/EditOps.h"
#include "../../Engine/Render/Scheduler.h"
#include "EditTestSupport.h"

#include <map>

using namespace vetest;

namespace {

// The picture every frame of `clip` shows, by timeline frame (the sequence's frame duration).
std::vector<CMTime> picturesOf(const Fixture &fx, ClipId clipId) {
    const Sequence &sequence = fx.sequence();
    const Clip &clip = fx.clip(clipId);
    const CMTime fd = sequence.frameDuration;
    std::vector<CMTime> pictures;
    const std::int64_t first = frameIndexAt(clip.timelineStart, fd, SnapMode::Round);
    const std::int64_t last = frameIndexAt(clip.timelineEnd(), fd, SnapMode::Round);
    for (std::int64_t f = first; f < last; ++f) {
        const RenderGraph graph = Scheduler::renderGraphAt(sequence, fx.project, timeForFrame(f, fd));
        CMTime shown = kCMTimeInvalid;
        for (const VideoLayer &layer : graph.layers) {
            if (layer.clipId == clipId) {
                shown = layer.sourceTime;
                CHECK(layer.reversed == clip.reversed);
            }
        }
        REQUIRE_MESSAGE(isNumeric(shown), doctest::String(("frame " + std::to_string(f) + " has no layer").c_str()));
        pictures.push_back(shown);
    }
    return pictures;
}

// Whether two clips are the same clip with the same times as numbers (a time may come back on
// another timescale after two edits that move it: 1410/30 and 47/1 are the same clip time).
bool sameNumerically(const Clip &a, const Clip &b) {
    if (a.id != b.id || a.assetId != b.assetId || a.trackId != b.trackId || a.timelineStart != b.timelineStart ||
        a.timelineDuration != b.timelineDuration || a.sourceIn != b.sourceIn || !(a.speed == b.speed) ||
        a.isStill != b.isStill || a.reversed != b.reversed || a.linkedClipId != b.linkedClipId ||
        !(a.video == b.video) || !(a.audio == b.audio) || a.spans.size() != b.spans.size()) {
        return false;
    }
    for (std::size_t i = 0; i < a.spans.size(); ++i) {
        EffectSpan x = a.spans[i];
        const EffectSpan &y = b.spans[i];
        if (x.start != y.start || x.end != y.end) {
            return false;
        }
        x.start = y.start;
        x.end = y.end;
        if (!(x == y)) {
            return false;
        }
    }
    return true;
}

// Reverses `clipId`, checks frame k shows forward frame n - 1 - k exactly, reverses it back and
// checks the clip is the original (its times the same numbers, on the timescales they had when the
// original's times were whole ticks of them).
void checkMirror(Fixture &fx, ClipId clipId, const char *label) {
    CAPTURE(label);
    const Clip original = fx.clip(clipId);
    const std::vector<CMTime> forward = picturesOf(fx, clipId);
    REQUIRE(forward.size() > 1);
    SetClipReversed reverse(fx.seq, clipId, true);
    applyReversible(fx.project, reverse);
    const Clip &reversed = fx.clip(clipId);
    CHECK(reversed.reversed);
    CHECK(identical(reversed.timelineStart, original.timelineStart));
    CHECK(identical(reversed.timelineDuration, original.timelineDuration));
    CHECK(reversed.speed == original.speed);
    const std::vector<CMTime> backward = picturesOf(fx, clipId);
    REQUIRE(backward.size() == forward.size());
    const std::size_t n = forward.size();
    int mismatches = 0;
    for (std::size_t k = 0; k < n; ++k) {
        if (!identical(backward[k], forward[n - 1 - k])) {
            if (++mismatches <= 3) {
                FAIL_CHECK("frame " << k << " of " << n << " shows " << describe(backward[k]) << ", forward frame "
                                    << (n - 1 - k) << " showed " << describe(forward[n - 1 - k]));
            }
        }
    }
    CHECK(mismatches == 0);
    SetClipReversed back(fx.seq, clipId, false);
    applyReversible(fx.project, back);
    CHECK(sameNumerically(fx.clip(clipId), original));
    const std::vector<CMTime> again = picturesOf(fx, clipId);
    REQUIRE(again.size() == forward.size());
    for (std::size_t k = 0; k < n; ++k) {
        CHECK(identical(again[k], forward[k]));
    }
}

// A 30 fps sequence clip of av30 with a Motion span, linked to its audio.
struct ReversedPair : Fixture {
    ClipId v, a;
    ReversedPair() {
        std::tie(v, a) = addLinkedPair(30, 90, 300); // timeline [30, 120), source frames [300, 390)
        requireValid();
    }
};

} // namespace

TEST_CASE("Reverse: frame k of a reversed clip shows exactly what forward frame n - 1 - k showed") {
    SUBCASE("30 fps media on a 30 fps sequence") {
        Fixture fx;
        const ClipId clip = fx.addClip(fx.v1, fx.av30, 10, 60, 30);
        fx.requireValid();
        checkMirror(fx, clip, "speed 1");
    }
    SUBCASE("fast and slow speeds") {
        for (const double speed : {2.0, 1.0 / 3.0, 0.75}) {
            Fixture fx;
            const ClipId clip = fx.addClip(fx.v1, fx.av30, 0, 45, 90, speed);
            fx.requireValid();
            checkMirror(fx, clip, speed == 2.0 ? "speed 2" : speed < 0.5 ? "speed 1/3" : "speed 3/4");
        }
    }
    SUBCASE("23.976 media at 999/1000 on a 29.97 sequence, in point off the grid (the span tests' NTSC case)") {
        Fixture fx;
        fx.sequence().frameDuration = CMTimeMake(1001, 30000);
        Clip clip;
        clip.id = fx.project.ids.make<ClipId>();
        clip.assetId = fx.av24;
        clip.trackId = fx.v1;
        clip.timelineStart = kCMTimeZero;
        clip.timelineDuration = CMTimeMake(1001 * 100, 30000);
        clip.sourceIn = CMTimeMake(44101, 44100);
        clip.speed = Ratio{999, 1000};
        fx.track(fx.v1).clips.push_back(clip);
        fx.requireValid();
        checkMirror(fx, clip.id, "NTSC");
    }
    SUBCASE("a VFR source at half speed (not snapped to a frame grid)") {
        Fixture fx;
        fx.project.findAsset(fx.video60)->isVFR = true;
        const ClipId clip = fx.addClip(fx.v1, fx.video60, 0, 30, 7, 0.5);
        fx.requireValid();
        checkMirror(fx, clip, "VFR");
    }
    SUBCASE("a clip ending on the video's last frame") {
        Fixture fx;
        const ClipId clip = fx.addClip(fx.v1, fx.av30, 0, 30, 1770);
        fx.requireValid();
        checkMirror(fx, clip, "the media's end");
    }
}

TEST_CASE("Reverse: SetClipReversed is undoable, takes the linked clip along and refuses what it cannot reverse") {
    ReversedPair fx;
    SetClipReversed reverse(fx.seq, fx.v, true);
    const EditResult r = applyReversible(fx.project, reverse);
    CHECK(r.droppedTransitionIds.empty());
    CHECK(reverse.name() == "Reverse Clip");
    CHECK(fx.clip(fx.v).reversed);
    CHECK(fx.clip(fx.a).reversed);
    // av30 is 60 s: the clips show media [10 s, 13 s), so their clip times are [47 s, 50 s), on the
    // in point's timescale (30).
    CHECK(identical(fx.clip(fx.v).sourceIn, CMTimeMake(47 * 30, 30)));
    CHECK(identical(fx.clip(fx.a).sourceIn, CMTimeMake(47 * 30, 30)));
    const auto range = mediaRangeOf(fx.clip(fx.v), fx.project.findAsset(fx.av30)->videoEnd());
    REQUIRE(range.has_value());
    CHECK(range->first.compare(f30(300)) == 0);
    CHECK(range->second.compare(f30(390)) == 0);

    SUBCASE("asking for the state it has changes nothing") {
        const Project before = fx.project;
        SetClipReversed again(fx.seq, fx.v, true);
        CHECK(again.apply(fx.project).ok());
        CHECK(fx.project == before);
    }
    SUBCASE("without the linked clip") {
        SetClipReversed forward(fx.seq, fx.v, false, false);
        applyReversible(fx.project, forward);
        CHECK(forward.name() == "Play Clip Forward");
        CHECK_FALSE(fx.clip(fx.v).reversed);
        CHECK(fx.clip(fx.a).reversed);
    }
    SUBCASE("a still") {
        const ClipId still = fx.addClip(fx.v2, fx.still, 0, 30);
        SetClipReversed edit(fx.seq, still, true);
        applyRefused(fx.project, edit, EditError::InvalidArgument);
        fx.sequence().findClip(still)->reversed = true;
        const auto problem = validateProject(fx.project);
        REQUIRE(problem.has_value());
        CHECK(problem->find("a still cannot be reversed") != std::string::npos);
    }
    SUBCASE("a locked track") {
        lockTrack(fx, fx.a1);
        SetClipReversed edit(fx.seq, fx.v, false);
        applyRefused(fx.project, edit, EditError::TrackLocked);
    }
    SUBCASE("an unknown clip") {
        SetClipReversed edit(fx.seq, ClipId{9999}, true);
        applyRefused(fx.project, edit, EditError::ClipNotFound);
    }
}

TEST_CASE("Reverse: effect spans keep their timeline frames; a dissolve without media on the new side goes") {
    Fixture fx;
    // A: source [0, 60) frames; B touching it; a 10-frame dissolve needs A's media after frame 60 (there)
    // and, once A is reversed, media before its range's start (frame 0: none).
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 0);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    const SpanId dissolve = fx.addTransition(fx.v1, a, b, 10);
    SpanTracks move;
    move.x = {key(kCMTimeZero, 0), key(f30(20), 100)};
    const SpanId motion = fx.addSpan(a, SpanKind::Motion, 1, f30(10), f30(30), move);
    fx.requireValid();
    const auto frameOf = [&](const EffectSpan &span) {
        const auto range = spanTimelineRange(fx.clip(a), span, fx.track(fx.v1));
        REQUIRE(range.has_value());
        return std::make_pair(range->start, range->end);
    };
    const auto before = frameOf(*fx.span(motion));
    std::vector<VideoParams> motionBefore;
    for (std::int64_t f = 0; f < 55; ++f) {
        motionBefore.push_back(motionValuesAt(fx.clip(a), f30(f)));
    }
    SetClipReversed reverse(fx.seq, a, true);
    const EditResult r = applyReversible(fx.project, reverse);
    CHECK(r.droppedTransitionIds == std::vector<SpanId>{dissolve});
    CHECK(fx.span(dissolve) == nullptr);
    const auto after = frameOf(*fx.span(motion));
    CHECK(identical(after.first, before.first));
    CHECK(identical(after.second, before.second));
    for (std::int64_t f = 0; f < 55; ++f) {
        CHECK(motionValuesAt(fx.clip(a), f30(f)) == motionBefore[static_cast<std::size_t>(f)]);
    }
    reverse.revert(fx.project);
    CHECK(fx.span(dissolve) != nullptr);

    // B reversed keeps it: its media before the cut's handle (frame 295) becomes media after its
    // range's end (frame 365).
    SetClipReversed reverseB(fx.seq, b, true);
    CHECK(applyReversible(fx.project, reverseB).droppedTransitionIds.empty());
    CHECK(fx.span(dissolve) != nullptr);
}

TEST_CASE("Reverse: split, trims and speed changes keep a reversed clip's pictures") {
    ReversedPair fx;
    SetClipReversed reverse(fx.seq, fx.v, true);
    applyReversible(fx.project, reverse);
    const std::vector<CMTime> pictures = picturesOf(fx, fx.v); // timeline frames 30 ... 119
    REQUIRE(pictures.size() == 90);
    auto shownAt = [&](std::int64_t frame) {
        const RenderGraph graph = Scheduler::renderGraphAt(fx.sequence(), fx.project, f30(frame));
        REQUIRE(graph.layers.size() == 1);
        return graph.layers[0].sourceTime;
    };
    CHECK(pictures.front() == f30(389)); // the latest media first
    CHECK(pictures.back() == f30(300));

    SUBCASE("a split: both pieces reversed, each showing what it showed") {
        SplitClip split(fx.seq, fx.v, f30(70));
        applyReversible(fx.project, split);
        const ClipId right = split.createdClipIds()[0];
        CHECK(fx.clip(fx.v).reversed);
        CHECK(fx.clip(right).reversed);
        for (std::int64_t f = 30; f < 120; ++f) {
            CHECK(identical(shownAt(f), pictures[static_cast<std::size_t>(f - 30)]));
        }
    }
    SUBCASE("a head trim removes the end of the media range, what the first frames showed") {
        TrimClipHead trim(fx.seq, fx.v, f30(40));
        applyReversible(fx.project, trim);
        for (std::int64_t f = 40; f < 120; ++f) {
            CHECK(identical(shownAt(f), pictures[static_cast<std::size_t>(f - 30)]));
        }
        const auto range = mediaRangeOf(fx.clip(fx.v), fx.project.findAsset(fx.av30)->videoEnd());
        CHECK(range->first.compare(f30(300)) == 0);
        CHECK(range->second.compare(f30(380)) == 0);
    }
    SUBCASE("a tail trim removes the start of the media range") {
        TrimClipTail trim(fx.seq, fx.v, f30(100));
        applyReversible(fx.project, trim);
        for (std::int64_t f = 30; f < 100; ++f) {
            CHECK(identical(shownAt(f), pictures[static_cast<std::size_t>(f - 30)]));
        }
        const auto range = mediaRangeOf(fx.clip(fx.v), fx.project.findAsset(fx.av30)->videoEnd());
        CHECK(range->first.compare(f30(320)) == 0);
    }
    SUBCASE("a speed change keeps where the clip starts in its media and runs backwards at the new speed") {
        SetClipSpeed faster(fx.seq, fx.v, Ratio{2, 1});
        applyReversible(fx.project, faster);
        CHECK(fx.clip(fx.v).reversed);
        CHECK(fx.clip(fx.v).timelineDuration == f30(45));
        // Frame k reads the mirror of its end: media 390 - 2 (k + 1) frames.
        CHECK(shownAt(30) == f30(388));
        CHECK(shownAt(31) == f30(386));
        CHECK(shownAt(74) == f30(300));
    }
    SUBCASE("a move keeps it") {
        MoveClip move(fx.seq, fx.v, fx.v1, f30(200));
        applyReversible(fx.project, move);
        CHECK(fx.clip(fx.v).reversed);
        for (std::int64_t f = 200; f < 290; ++f) {
            CHECK(identical(shownAt(f), pictures[static_cast<std::size_t>(f - 200)]));
        }
    }
}

TEST_CASE("Reverse: a Motion span on a reversed clip stays on its pictures across a trim") {
    ReversedPair fx;
    SetClipReversed reverse(fx.seq, fx.v, true);
    applyReversible(fx.project, reverse);
    const Clip &clip = fx.clip(fx.v);
    // A span over timeline frames [60, 90) of the reversed clip, x from 0 to 300.
    AddSpan add(fx.seq, fx.v, SpanKind::Motion, 1, f30(60), f30(90));
    applyReversible(fx.project, add);
    SetSpanValues values(fx.seq, add.createdSpanId(), {SpanValueChange{SpanParameter::X, 0.0, 300.0}});
    applyReversible(fx.project, values);
    std::map<std::int64_t, std::pair<CMTime, double>> before; // frame -> (picture, x)
    for (std::int64_t f = 50; f < 100; ++f) {
        const RenderGraph graph = Scheduler::renderGraphAt(fx.sequence(), fx.project, f30(f));
        before[f] = {graph.layers[0].sourceTime, graph.layers[0].transform.x};
    }
    (void)clip;
    for (const bool head : {true, false}) {
        CAPTURE(head);
        Project saved = fx.project;
        if (head) {
            TrimClipHead trim(fx.seq, fx.v, f30(70)); // cuts into the span
            applyReversible(fx.project, trim);
        } else {
            TrimClipTail trim(fx.seq, fx.v, f30(80));
            applyReversible(fx.project, trim);
        }
        const Clip &trimmed = fx.clip(fx.v);
        for (std::int64_t f = 50; f < 100; ++f) {
            if (f < frameIndexAt(trimmed.timelineStart, f30(1), SnapMode::Round) ||
                f >= frameIndexAt(trimmed.timelineEnd(), f30(1), SnapMode::Round)) {
                continue;
            }
            const RenderGraph graph = Scheduler::renderGraphAt(fx.sequence(), fx.project, f30(f));
            REQUIRE(graph.layers.size() == 1);
            CHECK(identical(graph.layers[0].sourceTime, before[f].first));
            CHECK(graph.layers[0].transform.x == doctest::Approx(before[f].second).epsilon(1e-12));
        }
        fx.project = saved;
    }
}

TEST_CASE("Reverse: the audio graph marks a reversed clip's segments with the media's end") {
    ReversedPair fx;
    SetClipReversed reverse(fx.seq, fx.v, true);
    applyReversible(fx.project, reverse);
    const AudioGraph graph = Scheduler::audioGraphFor(fx.sequence(), fx.project, TimeRange{f30(0), f30(150)});
    REQUIRE_FALSE(graph.segments.empty());
    for (const AudioSegment &segment : graph.segments) {
        CHECK(segment.clipId == fx.a);
        CHECK(segment.reversed);
        CHECK(identical(segment.mediaEnd, fx.project.findAsset(fx.av30)->duration));
        CHECK(identical(segment.sourceRange.start, fx.clip(fx.a).sourceTimeAt(segment.timelineRange.start)));
    }
}
