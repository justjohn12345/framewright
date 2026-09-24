// The effect span edits (EditOps.h): AddSpan, SetSpanRange, SetSpanValues, SetSpanInterpolation,
// MoveSpanLane and RemoveSpans, their refusals (an overlap names the nearest free range), undo and
// coalescing; the Ken Burns plan (spanEdgeMotion reads its framings back) and matching a
// neighbour's edge. Values are checked against the independent references of SpanReference.h.

#include "../Model/SpanReference.h"
#include "EditTestSupport.h"

#include "../../Engine/Edit/UndoStack.h"

#include <memory>

using namespace vetest;

namespace {

// V1: a 90-frame clip from source frame 30 (so timeline frame f shows source frame 30 + f); A1: a
// 90-frame audio clip.
struct SpanFixture : Fixture {
    ClipId v, a;
    SpanFixture() {
        v = addClip(v1, av30, 0, 90, 30);
        a = addClip(a1, audioOnly, 0, 90);
        requireValid();
    }

    // Adds a span through the command (checked reversible) and returns its id.
    SpanId add(ClipId clip, SpanKind kind, int lane, std::int64_t from, std::int64_t to) {
        AddSpan command(seq, clip, kind, lane, f30(from), f30(to));
        applyReversible(project, command);
        return command.createdSpanId();
    }

    void setValues(SpanId id, std::vector<SpanValueChange> changes) {
        SetSpanValues command(seq, id, std::move(changes));
        applyReversible(project, command);
    }

    const EffectSpan &get(SpanId id) const {
        const EffectSpan *found = span(id);
        REQUIRE(found != nullptr);
        return *found;
    }
};

SpanValueChange change(SpanParameter parameter, std::optional<double> start, std::optional<double> end) {
    SpanValueChange c;
    c.parameter = parameter;
    c.start = start;
    c.end = end;
    return c;
}

// Whether `track` is a straight ramp from `from` (at 0) to `to` (at `length`); times compared by
// value (a rescaled time may keep another timescale).
bool isRamp(const KeyframeTrack &track, double from, double to, CMTime length) {
    return track.size() == 2 && track[0].time == kCMTimeZero && track[1].time == length && track[0].value == from &&
           track[1].value == to && track[0].interpolation == KeyframeInterpolation::Linear;
}

bool close(double a, double b, double tolerance = 1e-9) {
    return std::fabs(a - b) <= tolerance * std::max(1.0, std::fabs(b));
}

} // namespace

TEST_CASE("AddSpan adds a neutral span over the frames, in the clip's source time; no picture changes") {
    SpanFixture fx;
    Clip &v = *fx.sequence().findClip(fx.v);
    v.video = VideoParams{20, -10, 1.25, 3, 0.9};
    std::vector<VideoParams> before;
    for (int f = 0; f < 90; ++f) {
        before.push_back(motionValuesAt(fx.clip(fx.v), f30(f)));
    }
    AddSpan add(fx.seq, fx.v, SpanKind::Motion, 1, f30(10), f30(40));
    CHECK(add.name() == "Add Motion Span");
    applyReversible(fx.project, add);
    const EffectSpan &span = fx.get(add.createdSpanId());
    CHECK(span.lane == 1);
    CHECK(span.kind == SpanKind::Motion);
    CHECK(span.start == f30(40)); // source frames: 30 + 10
    CHECK(span.end == f30(70));
    for (const SpanParameter p : parametersOf(SpanKind::Motion)) {
        const KeyframeTrack &track = span.tracks.track(p);
        REQUIRE(track.size() == 2);
        CHECK(track[0].time == kCMTimeZero);
        CHECK(track[1].time == f30(30));
        CHECK(track[0].value == neutralValue(p));
        CHECK(track[1].value == neutralValue(p));
    }
    CHECK(span.tracks.opacity.empty());
    CHECK(span.tracks.gain.empty());
    for (int f = 0; f < 90; ++f) {
        const VideoParams now = motionValuesAt(fx.clip(fx.v), f30(f));
        CHECK(now.x == before[static_cast<std::size_t>(f)].x);
        CHECK(now.scale == before[static_cast<std::size_t>(f)].scale);
        CHECK(now.opacity == before[static_cast<std::size_t>(f)].opacity);
    }
    SUBCASE("at twice the speed the span covers twice the source") {
        const ClipId fast = fx.addClip(fx.v2, fx.av30, 0, 60, 0, 2.0);
        AddSpan onFast(fx.seq, fast, SpanKind::Opacity, 3, f30(10), f30(20));
        CHECK(onFast.name() == "Add Opacity Span");
        applyReversible(fx.project, onFast);
        const EffectSpan &s = fx.get(onFast.createdSpanId());
        CHECK(s.start == f30(20));
        CHECK(s.end == f30(40));
        CHECK(isRamp(s.tracks.opacity, 1, 1, f30(20)));
    }
    SUBCASE("a Gain span on an audio clip") {
        AddSpan gain(fx.seq, fx.a, SpanKind::Gain, 2, f30(0), f30(90));
        CHECK(gain.name() == "Add Gain Span");
        applyReversible(fx.project, gain);
        CHECK(fx.get(gain.createdSpanId()).tracks.gain.size() == 2);
    }
    SUBCASE("a still's spans are measured from its start") {
        const ClipId still = fx.addClip(fx.v2, fx.still, 100, 60);
        AddSpan onStill(fx.seq, still, SpanKind::Motion, 1, f30(110), f30(130));
        applyReversible(fx.project, onStill);
        CHECK(fx.get(onStill.createdSpanId()).start == f30(10));
        CHECK(fx.get(onStill.createdSpanId()).end == f30(30));
    }
}

TEST_CASE("AddSpan refusals carry reasons; an overlap names the nearest free range") {
    SpanFixture fx;
    fx.add(fx.v, SpanKind::Motion, 1, 10, 40);
    SUBCASE("lanes 1 to 3 only, no transitions") {
        for (const int lane : {0, 4, -1}) {
            AddSpan add(fx.seq, fx.v, SpanKind::Motion, lane, f30(0), f30(5));
            const EditResult r = applyRefused(fx.project, add, EditError::InvalidArgument);
            CHECK(r.message.find("lanes 1 to 3") != std::string::npos);
        }
        AddSpan transition(fx.seq, fx.v, SpanKind::Transition, 1, f30(0), f30(5));
        applyRefused(fx.project, transition, EditError::InvalidArgument);
    }
    SUBCASE("the kind belongs to the track's kind") {
        AddSpan gainOnVideo(fx.seq, fx.v, SpanKind::Gain, 2, f30(0), f30(5));
        applyRefused(fx.project, gainOnVideo, EditError::TrackKindMismatch);
        AddSpan motionOnAudio(fx.seq, fx.a, SpanKind::Motion, 1, f30(0), f30(5));
        applyRefused(fx.project, motionOnAudio, EditError::TrackKindMismatch);
    }
    SUBCASE("at least one frame, inside the clip") {
        AddSpan empty(fx.seq, fx.v, SpanKind::Motion, 2, f30(5), f30(5));
        applyRefused(fx.project, empty, EditError::InvalidArgument);
        AddSpan outside(fx.seq, fx.v, SpanKind::Motion, 2, f30(80), f30(100));
        const EditResult r = applyRefused(fx.project, outside, EditError::InvalidTime);
        CHECK(r.message.find("is not within clip") != std::string::npos);
        AddSpan invalid(fx.seq, fx.v, SpanKind::Motion, 2, kCMTimeInvalid, f30(5));
        applyRefused(fx.project, invalid, EditError::InvalidTime);
    }
    SUBCASE("an overlap on the lane names the nearest free range") {
        // Lane 1 is free over [0, 10) and [40, 90).
        AddSpan later(fx.seq, fx.v, SpanKind::Opacity, 1, f30(30), f30(60));
        EditResult r = applyRefused(fx.project, later, EditError::Overlap);
        REQUIRE(r.freeRange.has_value());
        CHECK(r.freeRange->start == f30(40));
        CHECK(r.freeRange->end == f30(90));
        CHECK(r.message.find("nearest free range") != std::string::npos);
        AddSpan earlier(fx.seq, fx.v, SpanKind::Opacity, 1, f30(5), f30(15));
        r = applyRefused(fx.project, earlier, EditError::Overlap);
        REQUIRE(r.freeRange.has_value());
        CHECK(r.freeRange->start == f30(0));
        CHECK(r.freeRange->end == f30(10));
        // Touching is not overlapping.
        AddSpan touching(fx.seq, fx.v, SpanKind::Opacity, 1, f30(40), f30(50));
        applyReversible(fx.project, touching);
        // A full lane has no free range.
        fx.add(fx.v, SpanKind::Motion, 2, 0, 90);
        AddSpan full(fx.seq, fx.v, SpanKind::Motion, 2, f30(3), f30(4));
        r = applyRefused(fx.project, full, EditError::Overlap);
        CHECK_FALSE(r.freeRange.has_value());
        CHECK(r.message.find("no free frame") != std::string::npos);
    }
    SUBCASE("locked track, missing clip") {
        lockTrack(fx, fx.v1);
        AddSpan locked(fx.seq, fx.v, SpanKind::Motion, 2, f30(0), f30(5));
        applyRefused(fx.project, locked, EditError::TrackLocked);
        AddSpan missing(fx.seq, ClipId{999}, SpanKind::Motion, 2, f30(0), f30(5));
        applyRefused(fx.project, missing, EditError::ClipNotFound);
    }
}

TEST_CASE("SetSpanValues sets start and end values; the frames between follow the interpolation") {
    SpanFixture fx;
    const SpanId id = fx.add(fx.v, SpanKind::Motion, 1, 10, 40);
    SetSpanValues values(fx.seq, id, {change(SpanParameter::X, 0, 90), change(SpanParameter::Scale, std::nullopt, 2)});
    CHECK(values.name() == "Change Span Values");
    CHECK(values.coalescingKey() == "spanValues:" + std::to_string(id.value()));
    applyReversible(fx.project, values);
    for (int f = 10; f < 40; ++f) {
        const VideoParams shown = motionValuesAt(fx.clip(fx.v), f30(f));
        const double s = (30 + f) / 30.0;
        CHECK(close(shown.x, *referenceSpanValue(4.0 / 3, 7.0 / 3, 0, 90, KeyframeInterpolation::Linear, s)));
        CHECK(close(shown.scale, *referenceSpanValue(4.0 / 3, 7.0 / 3, 1, 2, KeyframeInterpolation::Linear, s)));
    }
    CHECK(motionValuesAt(fx.clip(fx.v), f30(40)).x == 0); // the span ends there
    SUBCASE("with an interpolation every segment moves that way (the Ken Burns step)") {
        SetSpanValues eased(fx.seq, id, {change(SpanParameter::Y, 0, -40)}, "Ken Burns",
                            KeyframeInterpolation::EaseInOut);
        CHECK(eased.name() == "Ken Burns");
        applyReversible(fx.project, eased);
        CHECK(spanInterpolation(fx.get(id)) == KeyframeInterpolation::EaseInOut);
        const double s = (30 + 25) / 30.0;
        const VideoParams shown = motionValuesAt(fx.clip(fx.v), f30(25));
        CHECK(close(shown.x, *referenceSpanValue(4.0 / 3, 7.0 / 3, 0, 90, KeyframeInterpolation::EaseInOut, s)));
        CHECK(close(shown.y, *referenceSpanValue(4.0 / 3, 7.0 / 3, 0, -40, KeyframeInterpolation::EaseInOut, s)));
    }
    SUBCASE("a keyframe between the ends keeps its place") {
        Clip &clip = *fx.sequence().findClip(fx.v);
        insertKeyframeKeepingValues(clip.findSpan(id)->tracks.x, 0, f30(10));
        clip.findSpan(id)->tracks.x[1].value = 100;
        fx.requireValid();
        fx.setValues(id, {change(SpanParameter::X, 10, 20)});
        const KeyframeTrack &x = fx.get(id).tracks.x;
        REQUIRE(x.size() == 3);
        CHECK(x[0].value == 10);
        CHECK(x[1].value == 100);
        CHECK(x[2].value == 20);
    }
    SUBCASE("refusals") {
        SetSpanValues wrongKind(fx.seq, id, {change(SpanParameter::Opacity, 0.5, 0.5)});
        CHECK(applyRefused(fx.project, wrongKind, EditError::InvalidArgument).message.find("has no Opacity") !=
              std::string::npos);
        SetSpanValues negative(fx.seq, id, {change(SpanParameter::Scale, -1, std::nullopt)});
        CHECK(applyRefused(fx.project, negative, EditError::InvalidArgument).message.find("at least 0") !=
              std::string::npos);
        SetSpanValues twice(fx.seq, id, {change(SpanParameter::X, 1, 2), change(SpanParameter::X, 3, 4)});
        applyRefused(fx.project, twice, EditError::InvalidArgument);
        SetSpanValues none(fx.seq, id, {});
        applyRefused(fx.project, none, EditError::InvalidArgument);
        SetSpanValues custom(fx.seq, id, {change(SpanParameter::X, 1, 2)}, "Change", KeyframeInterpolation::Bezier);
        applyRefused(fx.project, custom, EditError::InvalidArgument);
        SetSpanValues missing(fx.seq, SpanId{999}, {change(SpanParameter::X, 1, 2)});
        applyRefused(fx.project, missing, EditError::SpanNotFound);
        const SpanId fade = fx.addFade(fx.a, ClipEdge::Head, f30(10));
        SetSpanValues onTransition(fx.seq, fade, {change(SpanParameter::Gain, 1, 2)});
        applyRefused(fx.project, onTransition, EditError::InvalidArgument);
    }
}

TEST_CASE("SetSpanRange moves and trims a span; its values keep their places in it") {
    SpanFixture fx;
    const SpanId id = fx.add(fx.v, SpanKind::Motion, 1, 10, 40);
    fx.setValues(id, {change(SpanParameter::X, 0, 90)});
    SUBCASE("a move keeps the keyframes") {
        SetSpanRange move(fx.seq, id, f30(20), f30(50));
        CHECK(move.name() == "Change Span Range");
        CHECK(move.coalescingKey() == "spanRange:" + std::to_string(id.value()));
        applyReversible(fx.project, move);
        CHECK(fx.get(id).start == f30(50));
        CHECK(fx.get(id).end == f30(80));
        CHECK(isRamp(fx.get(id).tracks.x, 0, 90, f30(30)));
        for (int f = 20; f < 50; ++f) {
            CHECK(close(motionValuesAt(fx.clip(fx.v), f30(f)).x, 3.0 * (f - 20)));
        }
        CHECK(motionValuesAt(fx.clip(fx.v), f30(19)).x == 0);
    }
    SUBCASE("a trim stretches the values over the new range") {
        SetSpanRange trim(fx.seq, id, f30(10), f30(25));
        applyReversible(fx.project, trim);
        CHECK(isRamp(fx.get(id).tracks.x, 0, 90, f30(15)));
        for (int f = 10; f < 25; ++f) {
            CHECK(close(motionValuesAt(fx.clip(fx.v), f30(f)).x, 6.0 * (f - 10)));
        }
    }
    SUBCASE("refusals: overlap (the free range leaves the span itself out), outside the clip, a transition") {
        fx.add(fx.v, SpanKind::Opacity, 1, 60, 70);
        SetSpanRange over(fx.seq, id, f30(50), f30(65));
        const EditResult r = applyRefused(fx.project, over, EditError::Overlap);
        REQUIRE(r.freeRange.has_value());
        CHECK(r.freeRange->start == f30(0));
        CHECK(r.freeRange->end == f30(60));
        SetSpanRange outside(fx.seq, id, f30(70), f30(95));
        applyRefused(fx.project, outside, EditError::InvalidTime);
        const SpanId fade = fx.addFade(fx.v, ClipEdge::Head, f30(5));
        SetSpanRange transition(fx.seq, fade, f30(0), f30(3));
        applyRefused(fx.project, transition, EditError::InvalidArgument);
    }
    SUBCASE("an unchanged range is no edit") {
        SetSpanRange same(fx.seq, id, f30(10), f30(40));
        CHECK(same.apply(fx.project).ok());
        CHECK(same.isNoOp());
    }
}

TEST_CASE("SetSpanInterpolation, MoveSpanLane and RemoveSpans") {
    SpanFixture fx;
    const SpanId id = fx.add(fx.v, SpanKind::Motion, 1, 10, 40);
    fx.setValues(id, {change(SpanParameter::X, 0, 90)});
    SetSpanInterpolation hold(fx.seq, id, KeyframeInterpolation::Hold);
    CHECK(hold.name() == "Change Span Interpolation");
    applyReversible(fx.project, hold);
    CHECK(spanInterpolation(fx.get(id)) == KeyframeInterpolation::Hold);
    CHECK(motionValuesAt(fx.clip(fx.v), f30(39)).x == 0);
    SetSpanInterpolation custom(fx.seq, id, KeyframeInterpolation::Bezier);
    applyRefused(fx.project, custom, EditError::InvalidArgument);

    MoveSpanLane lane(fx.seq, id, 3);
    CHECK(lane.name() == "Move Span to Lane");
    applyReversible(fx.project, lane);
    CHECK(fx.get(id).lane == 3);
    CHECK(fx.clip(fx.v).spans.back().id == id);
    fx.add(fx.v, SpanKind::Opacity, 2, 0, 20);
    MoveSpanLane onto(fx.seq, id, 2);
    const EditResult r = applyRefused(fx.project, onto, EditError::Overlap);
    REQUIRE(r.freeRange.has_value());
    CHECK(r.freeRange->start == f30(20));
    CHECK(r.freeRange->end == f30(90));
    MoveSpanLane zero(fx.seq, id, 0);
    applyRefused(fx.project, zero, EditError::InvalidArgument);

    RemoveSpans remove(fx.seq, {id});
    applyReversible(fx.project, remove);
    CHECK(remove.name() == "Remove Span");
    CHECK(fx.span(id) == nullptr);
    CHECK(motionValuesAt(fx.clip(fx.v), f30(20)).x == 0);
    RemoveSpans missing(fx.seq, {SpanId{999}});
    applyRefused(fx.project, missing, EditError::SpanNotFound);
    const EditResult removed = remove.apply(fx.project);
    CHECK_FALSE(removed.ok());
}

TEST_CASE("Span edits undo as whole steps and coalesce in groups") {
    SpanFixture fx;
    UndoStack undo;
    const EditResult added = undo.push(fx.project, std::make_unique<AddSpan>(fx.seq, fx.v, SpanKind::Motion, 1, f30(0), f30(30)));
    REQUIRE(added.ok());
    const SpanId id = fx.clip(fx.v).spans.front().id;
    // A drag of the span's end: each step replaces the previous one; one undo step.
    undo.beginCoalescing("spanRange:" + std::to_string(id.value()));
    for (int end = 31; end <= 45; ++end) {
        REQUIRE(undo.push(fx.project, std::make_unique<SetSpanRange>(fx.seq, id, f30(0), f30(end))).ok());
    }
    undo.endCoalescing();
    CHECK(fx.get(id).end == f30(75));
    CHECK(undo.undoName() == "Change Span Range");
    // Nudges of the values: accumulated into one step.
    undo.beginCoalescing("spanValues:" + std::to_string(id.value()), CoalesceMode::Accumulate);
    for (int step = 1; step <= 5; ++step) {
        REQUIRE(undo.push(fx.project, std::make_unique<SetSpanValues>(
                                          fx.seq, id, std::vector<SpanValueChange>{change(SpanParameter::X, step, std::nullopt)}))
                    .ok());
    }
    undo.endCoalescing();
    CHECK(fx.get(id).tracks.x.front().value == 5);
    CHECK(undo.undoCount() == 3);
    REQUIRE(undo.undo(fx.project));
    CHECK(fx.get(id).tracks.x.front().value == 0);
    REQUIRE(undo.undo(fx.project));
    CHECK(fx.get(id).end == f30(60));
    REQUIRE(undo.undo(fx.project));
    CHECK(fx.span(id) == nullptr);
    REQUIRE(undo.redo(fx.project));
    REQUIRE(undo.redo(fx.project));
    REQUIRE(undo.redo(fx.project));
    CHECK(fx.get(id).tracks.x.front().value == 5);
    fx.requireValid();
}

TEST_CASE("planKenBurns sets the framings given the other lanes; spanEdgeMotion reads them back") {
    SpanFixture fx;
    Clip &clip = *fx.sequence().findClip(fx.v);
    clip.video = VideoParams{40, -20, 1.5, 0, 1};
    // Lane 2 zooms out 1 -> 0.8 over frames [0, 60).
    const SpanId zoom = fx.add(fx.v, SpanKind::Motion, 2, 0, 60);
    fx.setValues(zoom, {change(SpanParameter::Scale, 1, 0.8)});
    const SpanId move = fx.add(fx.v, SpanKind::Motion, 1, 30, 90);
    const MotionFraming start{-100, 50, 2};
    const MotionFraming end{200, -80, 1.25};
    std::vector<SpanValueChange> changes;
    REQUIRE(planKenBurns(fx.clip(fx.v), fx.get(move), fx.sequence().frameDuration, start, end, changes).ok());
    SetSpanValues apply(fx.seq, move, changes, "Ken Burns", KeyframeInterpolation::EaseInOut);
    applyReversible(fx.project, apply);
    const Clip &c = fx.clip(fx.v);
    const EffectSpan &span = fx.get(move);
    for (const bool atEnd : {false, true}) {
        const auto framing = spanEdgeMotion(c, span, fx.sequence().frameDuration, atEnd);
        REQUIRE(framing.has_value());
        const MotionFraming &want = atEnd ? end : start;
        CHECK(close(framing->x, want.x));
        CHECK(close(framing->y, want.y));
        CHECK(close(framing->scale, want.scale));
    }
    // The first frame shows the start framing exactly.
    const VideoParams first = motionValuesAt(c, f30(30));
    CHECK(close(first.x, start.x));
    CHECK(close(first.scale, start.scale));
    // Against the reference: the other lanes at the span's last frame (59 of the zoom's 60 frames:
    // past its end, so neutral) and first frame (source 2 s: 0.8 + 0.2 * (1 - 0.5)).
    const double zoomAtStart = *referenceSpanValue(1, 3, 1, 0.8, KeyframeInterpolation::Linear, 2.0);
    CHECK(close(span.tracks.scale.front().value, 2 / (1.5 * zoomAtStart)));
    CHECK(close(span.tracks.scale.back().value, 1.25 / 1.5));
    CHECK(close(span.tracks.x.front().value, -100 - 40));
    CHECK(close(span.tracks.x.back().value, 200 - 40));
    SUBCASE("refused for another kind and where nothing else leaves a scale") {
        const SpanId opacity = fx.add(fx.v, SpanKind::Opacity, 3, 0, 10);
        CHECK_FALSE(planKenBurns(fx.clip(fx.v), fx.get(opacity), fx.sequence().frameDuration, start, end, changes).ok());
        fx.sequence().findClip(fx.v)->video.scale = 0;
        CHECK(planKenBurns(fx.clip(fx.v), fx.get(move), fx.sequence().frameDuration, start, end, changes).error ==
              EditError::InvalidArgument);
    }
}

TEST_CASE("planMatchSpanEdge continues the neighbour at the cut through the span's value") {
    Fixture fx;
    // V1: A [0, 60) at 150 % offset right; B [60, 120) with a Motion span over its first 30 frames
    // and a static offset; A1: two touching audio clips, the second with a Gain span.
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60, 0);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60, 300);
    fx.sequence().findClip(a)->video = VideoParams{100, 0, 1.5, 10, 0.5};
    fx.sequence().findClip(b)->video = VideoParams{-20, 5, 1.2, 0, 1};
    const SpanId span = fx.addSpan(b, SpanKind::Motion, 1, f30(300), f30(330), SpanTracks{});
    fx.sequence().findClip(b)->findSpan(span)->tracks.x = rampTrack(0, 50, f30(30));
    const ClipId m = fx.addClip(fx.a1, fx.audioOnly, 0, 60, 0);
    const ClipId n = fx.addClip(fx.a1, fx.audioOnly, 60, 60, 600);
    fx.sequence().findClip(m)->audio.gainDb = -3;
    fx.sequence().findClip(n)->audio.gainDb = 2;
    const SpanId gain = fx.addSpan(n, SpanKind::Gain, 1, f30(600), f30(660), SpanTracks{});
    fx.sequence().findClip(n)->findSpan(gain)->tracks.gain = rampTrack(0, -6, f30(60));
    fx.requireValid();

    std::vector<SpanValueChange> changes;
    REQUIRE(planMatchSpanEdge(fx.sequence(), span, ClipEdge::Head, changes).ok());
    SetSpanValues match(fx.seq, span, changes);
    applyReversible(fx.project, match);
    const VideoParams aLast = motionValuesAt(fx.clip(a), f30(59));
    const VideoParams bFirst = motionValuesAt(fx.clip(b), f30(60));
    CHECK(close(bFirst.x, aLast.x));
    CHECK(close(bFirst.y, aLast.y));
    CHECK(close(bFirst.scale, aLast.scale));
    CHECK(close(bFirst.rotationDegrees, aLast.rotationDegrees));
    CHECK(fx.clip(b).findSpan(span)->tracks.x.back().value == 50); // the end value stays
    // Matched already: no changes.
    REQUIRE(planMatchSpanEdge(fx.sequence(), span, ClipEdge::Head, changes).ok());
    CHECK(changes.empty());

    REQUIRE(planMatchSpanEdge(fx.sequence(), gain, ClipEdge::Head, changes).ok());
    SetSpanValues matchGain(fx.seq, gain, changes);
    applyReversible(fx.project, matchGain);
    CHECK(close(gainDbAt(fx.clip(n), f30(60)), gainDbAt(fx.clip(m), f30(59))));

    // Refusals: no neighbour there; the span does not reach that frame; a transition.
    CHECK(planMatchSpanEdge(fx.sequence(), span, ClipEdge::Tail, changes).error == EditError::NotAdjacent);
    const SpanId inner = fx.addSpan(a, SpanKind::Opacity, 1, f30(10), f30(20), SpanTracks{});
    fx.addClip(fx.v1, fx.av30, 120, 30, 600);
    CHECK(planMatchSpanEdge(fx.sequence(), inner, ClipEdge::Tail, changes).error == EditError::InvalidArgument);
    const SpanId fade = fx.addFade(m, ClipEdge::Head, f30(5));
    CHECK(planMatchSpanEdge(fx.sequence(), fade, ClipEdge::Head, changes).error == EditError::InvalidArgument);
    CHECK(planMatchSpanEdge(fx.sequence(), SpanId{999}, ClipEdge::Head, changes).error == EditError::SpanNotFound);
}

TEST_CASE("setClipFade sets, shortens and removes lane-0 fades; clipFadeLength reads them") {
    Fixture fx;
    const ClipId c = fx.addClip(fx.a1, fx.audioOnly, 0, 100);
    Clip &clip = *fx.sequence().findClip(c);
    const Track &track = fx.track(fx.a1);
    REQUIRE(setClipFade(clip, track, ClipEdge::Head, f30(20), fx.project.ids).ok());
    REQUIRE(setClipFade(clip, track, ClipEdge::Tail, CMTimeMake(7, 48000), fx.project.ids).ok());
    CHECK(clipFadeLength(clip, ClipEdge::Head) == f30(20));
    CHECK(clipFadeLength(clip, ClipEdge::Tail) == CMTimeMake(7, 48000));
    const SpanId head = clip.transitionAt(ClipEdge::Head)->id;
    REQUIRE(setClipFade(clip, track, ClipEdge::Head, f30(30), fx.project.ids).ok());
    CHECK(clip.transitionAt(ClipEdge::Head)->id == head); // changed, not replaced
    CHECK(setClipFade(clip, track, ClipEdge::Head, f30(101), fx.project.ids).error == EditError::InvalidTime);
    CHECK(setClipFade(clip, track, ClipEdge::Tail, f30(71), fx.project.ids).error == EditError::InvalidTime);
    CHECK(setClipFade(clip, track, ClipEdge::Tail, -f30(1), fx.project.ids).error == EditError::InvalidTime);
    REQUIRE(setClipFade(clip, track, ClipEdge::Head, kCMTimeZero, fx.project.ids).ok());
    CHECK(clip.transitionAt(ClipEdge::Head) == nullptr);
    fx.requireValid();
}
