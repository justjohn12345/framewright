// Keyframed Motion edit ops (AddKeyframe, SetMotionValue, RemoveKeyframe, MoveKeyframe,
// SetKeyframeInterpolation, SetMotionTracks) and how the other edits keep keyframes on their
// pictures: head and tail trims, speed changes, splits (video and stills), overwrites. Every
// picture comparison goes through Scheduler::motionAt, the evaluation playback and export use.

#include "EditTestSupport.h"

#include "../../Engine/Edit/UndoStack.h"
#include "../../Engine/Render/Scheduler.h"

#include <map>
#include <memory>

using namespace vetest;

namespace {

Keyframe key(CMTime time, double value, KeyframeInterpolation interpolation = KeyframeInterpolation::Linear) {
    Keyframe k;
    k.time = time;
    k.value = value;
    k.interpolation = interpolation;
    return k;
}

// A 90-frame clip of av30 on V1 at timeline frame 30 from source frame 60 (2 s), animated: x
// eases in and out from 0 to 300 over source frames [60, 150), scale holds 1 then 2 from source
// frame 100, rotation is linear from 0 to 90, opacity is static.
struct Animated {
    Fixture fx;
    ClipId clip;
    ClipId partner;

    Animated() {
        std::tie(clip, partner) = fx.addLinkedPair(30, 90, 60);
        Clip &c = *fx.sequence().findClip(clip);
        c.video.keyframes.x = {key(f30(60), 0, KeyframeInterpolation::EaseInOut), key(f30(150), 300)};
        c.video.keyframes.scale = {key(f30(60), 1, KeyframeInterpolation::Hold), key(f30(100), 2)};
        c.video.keyframes.rotation = {key(f30(60), 0), key(f30(149), 90)};
        c.video.opacity = 0.8;
        fx.requireValid();
    }
};

// The Motion every picture of `asset` source frames [from, to) shows, keyed by source frame:
// what the sequence shows wherever those pictures play (whichever clip plays them).
std::map<std::int64_t, VideoParams> motionByPicture(const Fixture &fx, TrackId track, std::int64_t fromTimeline,
                                                    std::int64_t toTimeline) {
    std::map<std::int64_t, VideoParams> result;
    for (std::int64_t frame = fromTimeline; frame < toTimeline; ++frame) {
        const Clip *clip = fx.sequence().findTrack(track)->clipAt(f30(frame));
        if (clip == nullptr) {
            continue;
        }
        const CMTime source = clip->sourceTimeAt(f30(frame));
        const std::int64_t index = frameIndexAt(source, CMTimeMake(1, 60), SnapMode::Round); // half frames
        result[index] = Scheduler::motionAt(*clip, f30(frame));
    }
    return result;
}

void checkSameMotion(const VideoParams &a, const VideoParams &b) {
    CHECK(a.x == doctest::Approx(b.x).epsilon(1e-9));
    CHECK(a.y == doctest::Approx(b.y).epsilon(1e-9));
    CHECK(a.scale == doctest::Approx(b.scale).epsilon(1e-9));
    CHECK(a.rotationDegrees == doctest::Approx(b.rotationDegrees).epsilon(1e-9));
    CHECK(a.opacity == doctest::Approx(b.opacity).epsilon(1e-9));
}

} // namespace

TEST_CASE("AddKeyframe keeps the picture and refuses what it cannot add") {
    Animated a;
    Fixture &fx = a.fx;
    // Rotation at source frame 90 (timeline 60) is about 30 degrees; a keyframe there keeps it.
    AddKeyframe add(fx.seq, a.clip, MotionParameter::Rotation, f30(90));
    CHECK(add.name() == "Add Keyframe");
    const VideoParams before = Scheduler::motionAt(fx.clip(a.clip), f30(60));
    applyReversible(fx.project, add);
    const KeyframeTrack &rotation = fx.clip(a.clip).video.keyframes.rotation;
    REQUIRE(rotation.size() == 3);
    CHECK(rotation[1].time == f30(90));
    CHECK(rotation[1].interpolation == KeyframeInterpolation::Linear);
    checkSameMotion(Scheduler::motionAt(fx.clip(a.clip), f30(60)), before);

    SUBCASE("a static parameter's first keyframe takes its static value") {
        AddKeyframe first(fx.seq, a.clip, MotionParameter::Opacity, f30(70));
        applyReversible(fx.project, first);
        CHECK(fx.clip(a.clip).video.keyframes.opacity == KeyframeTrack{key(f30(70), 0.8)});
    }
    SUBCASE("with a value and an interpolation") {
        AddKeyframe given(fx.seq, a.clip, MotionParameter::Y, f30(70), -40.0, KeyframeInterpolation::EaseOut);
        applyReversible(fx.project, given);
        CHECK(fx.clip(a.clip).video.keyframes.y == KeyframeTrack{key(f30(70), -40, KeyframeInterpolation::EaseOut)});
    }
    SUBCASE("refusals") {
        AddKeyframe again(fx.seq, a.clip, MotionParameter::Rotation, f30(90));
        applyRefused(fx.project, again, EditError::AlreadyExists);
        AddKeyframe outside(fx.seq, a.clip, MotionParameter::X, f30(59));
        applyRefused(fx.project, outside, EditError::InvalidTime);
        AddKeyframe pastOut(fx.seq, a.clip, MotionParameter::X, f30(151));
        applyRefused(fx.project, pastOut, EditError::InvalidTime);
        AddKeyframe audio(fx.seq, a.partner, MotionParameter::X, f30(70));
        applyRefused(fx.project, audio, EditError::TrackKindMismatch);
        AddKeyframe badValue(fx.seq, a.clip, MotionParameter::Opacity, f30(70), 2.0);
        applyRefused(fx.project, badValue, EditError::InvalidArgument);
        AddKeyframe custom(fx.seq, a.clip, MotionParameter::X, f30(70), 1.0, KeyframeInterpolation::Bezier);
        applyRefused(fx.project, custom, EditError::InvalidArgument);
        CMTime rounded = f30(70);
        rounded.flags |= kCMTimeFlags_HasBeenRounded;
        AddKeyframe inexact(fx.seq, a.clip, MotionParameter::X, rounded);
        applyRefused(fx.project, inexact, EditError::InvalidTime);
        lockTrack(fx, fx.v1);
        AddKeyframe locked(fx.seq, a.clip, MotionParameter::X, f30(70));
        applyRefused(fx.project, locked, EditError::TrackLocked);
    }
}

TEST_CASE("SetMotionValue sets the static value, changes a keyframe or adds one") {
    Animated a;
    Fixture &fx = a.fx;
    SUBCASE("static") {
        SetMotionValue set(fx.seq, a.clip, MotionParameter::Opacity, std::nullopt, 0.25);
        applyReversible(fx.project, set);
        CHECK(set.name() == "Change Video Settings");
        CHECK(fx.clip(a.clip).video.opacity == 0.25);
        CHECK(Scheduler::motionAt(fx.clip(a.clip), f30(50)).opacity == 0.25);
    }
    SUBCASE("the keyframe at the time") {
        SetMotionValue set(fx.seq, a.clip, MotionParameter::X, f30(150), 600.0);
        applyReversible(fx.project, set);
        CHECK(set.name() == "Change Keyframe");
        CHECK(fx.clip(a.clip).video.keyframes.x.back().value == 600);
        CHECK(fx.clip(a.clip).video.keyframes.x.size() == 2);
    }
    SUBCASE("a new keyframe, with the interpolation asked for") {
        SetMotionValue set(fx.seq, a.clip, MotionParameter::X, f30(100), 10.0, KeyframeInterpolation::Hold);
        applyReversible(fx.project, set);
        CHECK(set.name() == "Add Keyframe");
        const KeyframeTrack &x = fx.clip(a.clip).video.keyframes.x;
        REQUIRE(x.size() == 3);
        CHECK(x[1] == key(f30(100), 10, KeyframeInterpolation::Hold));
    }
    SUBCASE("refusals") {
        SetMotionValue negative(fx.seq, a.clip, MotionParameter::Scale, f30(100), -1.0);
        applyRefused(fx.project, negative, EditError::InvalidArgument);
        SetMotionValue outside(fx.seq, a.clip, MotionParameter::X, f30(10), 1.0);
        applyRefused(fx.project, outside, EditError::InvalidTime);
    }
}

TEST_CASE("RemoveKeyframe, MoveKeyframe and SetKeyframeInterpolation") {
    Animated a;
    Fixture &fx = a.fx;
    SUBCASE("removing the last keyframe leaves its value static: the picture does not change") {
        RemoveKeyframe first(fx.seq, a.clip, MotionParameter::Scale, f30(60));
        applyReversible(fx.project, first);
        RemoveKeyframe last(fx.seq, a.clip, MotionParameter::Scale, f30(100));
        applyReversible(fx.project, last);
        CHECK(fx.clip(a.clip).video.keyframes.scale.empty());
        CHECK(fx.clip(a.clip).video.scale == 2);
        RemoveKeyframe missing(fx.seq, a.clip, MotionParameter::Scale, f30(100));
        applyRefused(fx.project, missing, EditError::KeyframeNotFound);
    }
    SUBCASE("moving keeps value and interpolation") {
        MoveKeyframe move(fx.seq, a.clip, MotionParameter::X, f30(60), f30(75));
        applyReversible(fx.project, move);
        CHECK(fx.clip(a.clip).video.keyframes.x.front() == key(f30(75), 0, KeyframeInterpolation::EaseInOut));
    }
    SUBCASE("a move onto another keyframe or outside the clip is refused") {
        MoveKeyframe onto(fx.seq, a.clip, MotionParameter::X, f30(60), f30(150));
        applyRefused(fx.project, onto, EditError::AlreadyExists);
        MoveKeyframe outside(fx.seq, a.clip, MotionParameter::X, f30(60), f30(151));
        applyRefused(fx.project, outside, EditError::InvalidTime);
        MoveKeyframe missing(fx.seq, a.clip, MotionParameter::X, f30(61), f30(70));
        applyRefused(fx.project, missing, EditError::KeyframeNotFound);
    }
    SUBCASE("interpolation") {
        SetKeyframeInterpolation hold(fx.seq, a.clip, MotionParameter::X, f30(60), KeyframeInterpolation::Hold);
        applyReversible(fx.project, hold);
        CHECK(Scheduler::motionAt(fx.clip(a.clip), f30(100)).x == 0);
        SetKeyframeInterpolation custom(fx.seq, a.clip, MotionParameter::X, f30(60), KeyframeInterpolation::Bezier);
        applyRefused(fx.project, custom, EditError::InvalidArgument);
        SetKeyframeInterpolation missing(fx.seq, a.clip, MotionParameter::X, f30(61), KeyframeInterpolation::Linear);
        applyRefused(fx.project, missing, EditError::KeyframeNotFound);
    }
}

TEST_CASE("SetMotionTracks replaces whole tracks as one edit (Ken Burns, animation off)") {
    Animated a;
    Fixture &fx = a.fx;
    MotionTrackChange x{MotionParameter::X, {key(f30(60), -100, KeyframeInterpolation::EaseInOut), key(f30(149), 100)},
                        -100};
    MotionTrackChange scale{MotionParameter::Scale, {key(f30(60), 1.2, KeyframeInterpolation::EaseInOut), key(f30(149), 1.6)},
                            1.2};
    MotionTrackChange off{MotionParameter::Rotation, {}, 30};
    SetMotionTracks set(fx.seq, a.clip, {x, scale, off}, "Ken Burns");
    CHECK(set.name() == "Ken Burns");
    applyReversible(fx.project, set);
    const Clip &clip = fx.clip(a.clip);
    CHECK(clip.video.keyframes.x == x.keyframes);
    CHECK(clip.video.keyframes.scale == scale.keyframes);
    CHECK(clip.video.keyframes.rotation.empty());
    CHECK(clip.video.rotationDegrees == 30);
    CHECK(Scheduler::motionAt(clip, f30(30)).x == -100);
    CHECK(Scheduler::motionAt(clip, f30(119)).scale == doctest::Approx(1.6));

    SetMotionTracks twice(fx.seq, a.clip, {off, off});
    applyRefused(fx.project, twice, EditError::InvalidArgument);
    SetMotionTracks unsorted(fx.seq, a.clip, {MotionTrackChange{MotionParameter::X, {key(f30(90), 0), key(f30(80), 1)}, 0}});
    applyRefused(fx.project, unsorted, EditError::InvalidArgument);
    SetMotionTracks outside(fx.seq, a.clip, {MotionTrackChange{MotionParameter::X, {key(f30(10), 0)}, 0}});
    applyRefused(fx.project, outside, EditError::InvalidTime);
}

TEST_CASE("Keyframes stay on their pictures through trims and speed changes") {
    Animated a;
    Fixture &fx = a.fx;
    const auto before = motionByPicture(fx, fx.v1, 0, 400);
    REQUIRE(before.size() == 90);
    const MotionKeyframes keyframes = fx.clip(a.clip).video.keyframes;

    SUBCASE("head trim in, then back out") {
        TrimClipHead trim(fx.seq, a.clip, f30(45));
        applyReversible(fx.project, trim);
        CHECK(fx.clip(a.clip).video.keyframes == keyframes); // the cut-off keyframe stays, hidden
        auto after = motionByPicture(fx, fx.v1, 0, 400);
        CHECK(after.size() == 75);
        for (const auto &[picture, motion] : after) {
            REQUIRE(before.count(picture));
            checkSameMotion(motion, before.at(picture));
        }
        TrimClipHead back(fx.seq, a.clip, f30(30));
        applyReversible(fx.project, back);
        after = motionByPicture(fx, fx.v1, 0, 400);
        REQUIRE(after.size() == before.size());
        for (const auto &[picture, motion] : after) {
            checkSameMotion(motion, before.at(picture));
        }
    }
    SUBCASE("tail trim") {
        TrimClipTail trim(fx.seq, a.clip, f30(80));
        applyReversible(fx.project, trim);
        CHECK(fx.clip(a.clip).video.keyframes == keyframes);
        for (const auto &[picture, motion] : motionByPicture(fx, fx.v1, 0, 400)) {
            checkSameMotion(motion, before.at(picture));
        }
    }
    SUBCASE("half speed: the keyframes move with their pictures") {
        SetClipSpeed slow(fx.seq, a.clip, Ratio{1, 2}, SpeedOptions{true, true, RippleScope::AllUnlockedTracks});
        applyReversible(fx.project, slow);
        const Clip &clip = fx.clip(a.clip);
        CHECK(clip.video.keyframes == keyframes);
        CHECK(clip.timelineDuration == f30(180));
        // The x keyframe on source frame 150 (the old out point) now plays 180 frames after the start.
        CHECK(clip.timelineTimeAt(f30(150)) == f30(210));
        const auto after = motionByPicture(fx, fx.v1, 0, 400);
        CHECK(after.size() == 180); // every picture twice, plus the half frames between them
        for (const auto &[picture, motion] : after) {
            if (before.count(picture)) {
                checkSameMotion(motion, before.at(picture));
            }
        }
    }
}

TEST_CASE("A split gives each piece its keyframes and changes no picture") {
    Animated a;
    Fixture &fx = a.fx;
    std::vector<VideoParams> before;
    for (std::int64_t frame = 30; frame < 120; ++frame) {
        before.push_back(Scheduler::motionAt(fx.clip(a.clip), f30(frame)));
    }
    for (const std::int64_t at : {31, 50, 70, 100, 119}) {
        CAPTURE(at);
        Fixture copy = fx;
        SplitClip split(copy.seq, a.clip, f30(at));
        applyReversible(copy.project, split);
        const ClipId right = split.createdClipIds().front();
        const Clip &left = copy.clip(a.clip);
        const Clip &rightClip = copy.clip(right);
        for (std::int64_t frame = 30; frame < 120; ++frame) {
            const Clip &piece = frame < at ? left : rightClip;
            checkSameMotion(Scheduler::motionAt(piece, f30(frame)), before[std::size_t(frame - 30)]);
        }
        // Every keyframe is on its piece's side of the cut (source frame at + 30).
        for (const MotionParameter p : kMotionParameters) {
            for (const Keyframe &k : left.video.keyframes.track(p)) {
                CHECK(k.time <= rightClip.sourceIn);
            }
            for (const Keyframe &k : rightClip.video.keyframes.track(p)) {
                CHECK(k.time >= rightClip.sourceIn);
            }
        }
        // The linked audio piece has no Motion.
        CHECK_FALSE(copy.clip(split.createdClipIds().back()).video.isAnimated());
    }
    SUBCASE("a split through an eased segment: the pieces carry the curve's parts") {
        SplitClip split(fx.seq, a.clip, f30(70));
        applyReversible(fx.project, split);
        const Clip &right = fx.clip(split.createdClipIds().front());
        REQUIRE(right.video.keyframes.x.size() == 2);
        CHECK(right.video.keyframes.x.front().time == f30(100));
        CHECK(right.video.keyframes.x.front().interpolation == KeyframeInterpolation::Bezier);
        CHECK(fx.clip(a.clip).video.keyframes.x.back().time == f30(100));
        // Scale holds 1 until source frame 100 and becomes 2 there: the right piece starts on it.
        CHECK(right.video.keyframes.scale.front().time == f30(100));
    }
}

TEST_CASE("A still's keyframes stay at their timeline positions through splits and head trims") {
    Fixture fx;
    const ClipId still = fx.addClip(fx.v1, fx.still, 30, 150);
    Clip &clip = *fx.sequence().findClip(still);
    clip.video.keyframes.scale = {key(f30(0), 1, KeyframeInterpolation::EaseInOut), key(f30(149), 1.5)};
    clip.video.keyframes.x = {key(f30(0), -50), key(f30(149), 50)};
    fx.requireValid();
    std::vector<VideoParams> before;
    for (std::int64_t frame = 30; frame < 180; ++frame) {
        before.push_back(Scheduler::motionAt(fx.clip(still), f30(frame)));
    }
    SUBCASE("split") {
        SplitClip split(fx.seq, still, f30(90));
        applyReversible(fx.project, split);
        const Clip &right = fx.clip(split.createdClipIds().front());
        CHECK(right.video.keyframes.scale.front().time == f30(0)); // the cut, at the piece's start
        for (std::int64_t frame = 30; frame < 180; ++frame) {
            const Clip &piece = frame < 90 ? fx.clip(still) : right;
            checkSameMotion(Scheduler::motionAt(piece, f30(frame)), before[std::size_t(frame - 30)]);
        }
    }
    SUBCASE("head trim") {
        TrimClipHead trim(fx.seq, still, f30(60));
        applyReversible(fx.project, trim);
        for (std::int64_t frame = 60; frame < 180; ++frame) {
            checkSameMotion(Scheduler::motionAt(fx.clip(still), f30(frame)), before[std::size_t(frame - 30)]);
        }
    }
    SUBCASE("an overwrite over its head") {
        OverwriteClip overwrite(fx.seq, f30(0), {place(fx.v1, fx.video60, 0, 45)});
        applyReversible(fx.project, overwrite);
        for (std::int64_t frame = 45; frame < 180; ++frame) {
            checkSameMotion(Scheduler::motionAt(fx.clip(still), f30(frame)), before[std::size_t(frame - 30)]);
        }
    }
}

TEST_CASE("Keyframe edits undo, redo and merge in an Accumulate group") {
    Animated a;
    Fixture &fx = a.fx;
    const Project start = fx.project;
    UndoStack stack;
    REQUIRE(stack.push(fx.project, std::make_unique<AddKeyframe>(fx.seq, a.clip, MotionParameter::Y, f30(90))).ok());
    CHECK(stack.undoName() == "Add Keyframe");
    // A burst of nudges of that keyframe's value is one undo step.
    const SetMotionValue probe(fx.seq, a.clip, MotionParameter::Y, f30(90), 0.0);
    stack.beginCoalescing(probe.coalescingKey(), CoalesceMode::Accumulate);
    for (int i = 1; i <= 5; ++i) {
        REQUIRE(stack
                    .push(fx.project, std::make_unique<SetMotionValue>(fx.seq, a.clip, MotionParameter::Y, f30(90),
                                                                       double(i * 10)))
                    .ok());
    }
    stack.endCoalescing();
    CHECK(fx.clip(a.clip).video.keyframes.y.front().value == 50);
    CHECK(stack.undoName() == "Change Keyframe");
    REQUIRE(stack.undo(fx.project));
    CHECK(fx.clip(a.clip).video.keyframes.y.front().value == 0);
    REQUIRE(stack.undo(fx.project));
    CHECK(fx.project == start);
    REQUIRE(stack.redo(fx.project));
    REQUIRE(stack.redo(fx.project));
    CHECK(fx.clip(a.clip).video.keyframes.y.front().value == 50);
}

TEST_CASE("isThroughEdit: a split of an animated clip is not a through edit (the pieces differ)") {
    Animated a;
    Fixture &fx = a.fx;
    SplitClip split(fx.seq, a.clip, f30(70));
    applyReversible(fx.project, split);
    CHECK_FALSE(isThroughEdit(fx.sequence(), a.clip, split.createdClipIds().front()));
    // Without keyframes a plain split is one.
    Fixture plain;
    const ClipId clip = plain.addClip(plain.v1, plain.av30, 0, 60);
    SplitClip plainSplit(plain.seq, clip, f30(30));
    applyReversible(plain.project, plainSplit);
    CHECK(isThroughEdit(plain.sequence(), clip, plainSplit.createdClipIds().front()));
}

// ----- Ken Burns moves over part of a clip, matching a neighbour's framing -----

namespace {

MotionMoveRequest moveRequest(std::int64_t firstFrame, std::int64_t lastFrame, MotionFraming start, MotionFraming end,
                              KeyframeInterpolation interpolation = KeyframeInterpolation::EaseInOut) {
    MotionMoveRequest request;
    request.firstFrame = f30(firstFrame);
    request.lastFrame = f30(lastFrame);
    request.start = start;
    request.end = end;
    request.interpolation = interpolation;
    return request;
}

void checkFraming(const VideoParams &shown, MotionFraming framing) {
    CHECK(shown.x == doctest::Approx(framing.x).epsilon(1e-12));
    CHECK(shown.y == doctest::Approx(framing.y).epsilon(1e-12));
    CHECK(shown.scale == doctest::Approx(framing.scale).epsilon(1e-12));
}

// Plans `request` on `clipId` (which must succeed) and applies it with SetMotionTracks.
MotionMovePlan applyMove(Fixture &fx, ClipId clipId, const MotionMoveRequest &request) {
    MotionMovePlan plan;
    const EditResult planned = planMotionMove(fx.clip(clipId), f30(1), request, plan);
    REQUIRE_MESSAGE(planned.ok(), doctest::String(planned.message.c_str()));
    REQUIRE(plan.changes.size() == 3);
    SetMotionTracks set(fx.seq, clipId, plan.changes, "Ken Burns");
    applyReversible(fx.project, set);
    return plan;
}

std::vector<CMTime> timesOf(const KeyframeTrack &track) {
    std::vector<CMTime> times;
    for (const Keyframe &keyframe : track) {
        times.push_back(keyframe.time);
    }
    return times;
}

} // namespace

TEST_CASE("planMotionMove: a move over part of a clip, then a second one later, keeps the first") {
    Fixture fx;
    // A 30 s clip (900 frames) from source frame 0 at timeline 0, unanimated.
    const ClipId clip = fx.addClip(fx.v1, fx.av30, 0, 900);
    fx.requireValid();
    const MotionFraming whole{0, 0, 1};
    const MotionFraming pushed{-100, 50, 1.5};

    // The first 5 s: keyframes on frames 0 and 149, the end framing held to the clip's end.
    const MotionMovePlan first = applyMove(fx, clip, moveRequest(0, 149, whole, pushed));
    CHECK(first.before.parameters.empty());
    CHECK(first.after.parameters.empty());
    CHECK_FALSE(isNumeric(first.before.keyframeTime));
    for (MotionParameter parameter : {MotionParameter::X, MotionParameter::Y, MotionParameter::Scale}) {
        const KeyframeTrack &track = fx.clip(clip).video.keyframes.track(parameter);
        CHECK(timesOf(track) == std::vector<CMTime>{f30(0), f30(149)});
        CHECK(track[0].interpolation == KeyframeInterpolation::EaseInOut);
        CHECK(track[1].interpolation == KeyframeInterpolation::Linear);
    }
    CHECK(fx.clip(clip).video.keyframes.rotation.empty());
    CHECK(fx.clip(clip).video.x == 0); // the static value is the start framing
    checkFraming(Scheduler::motionAt(fx.clip(clip), f30(0)), whole);
    for (std::int64_t frame : {149, 150, 400, 899}) {
        CAPTURE(frame);
        checkFraming(Scheduler::motionAt(fx.clip(clip), f30(frame)), pushed);
    }

    // A second move from 20 s, starting on the framing held there: the first move's keyframes stay
    // (before the range) and the framing holds between the two moves.
    const MotionFraming closer{200, -40, 2.5};
    const MotionMovePlan second = applyMove(fx, clip, moveRequest(600, 749, pushed, closer));
    CHECK(second.before.parameters.empty()); // the kept keyframes on frame 149 have the start framing
    CHECK(second.after.parameters.empty());
    CHECK(timesOf(fx.clip(clip).video.keyframes.x) == std::vector<CMTime>{f30(0), f30(149), f30(600), f30(749)});
    for (std::int64_t frame : {149, 300, 600}) {
        CAPTURE(frame);
        checkFraming(Scheduler::motionAt(fx.clip(clip), f30(frame)), pushed);
    }
    for (std::int64_t frame : {749, 800, 899}) {
        CAPTURE(frame);
        checkFraming(Scheduler::motionAt(fx.clip(clip), f30(frame)), closer);
    }

    // A move between them from another framing: the kept keyframes on either side lead into and
    // out of it, which the plan reports (the earliest before, the latest after).
    const MotionFraming other{0, 50, 1.5}; // only X differs from the framing on frame 149
    MotionMovePlan between;
    REQUIRE(planMotionMove(fx.clip(clip), f30(1), moveRequest(300, 449, other, closer), between).ok());
    CHECK(between.before.parameters == std::vector<MotionParameter>{MotionParameter::X});
    CHECK(between.before.keyframeTime == f30(149));
    // After it the keyframes on frame 600 have the framing `pushed`, not `closer`.
    CHECK(between.after.parameters ==
          std::vector<MotionParameter>{MotionParameter::X, MotionParameter::Y, MotionParameter::Scale});
    CHECK(between.after.keyframeTime == f30(600));

    // A move over [100, 700] replaces the keyframes on frames 149 and 600 and keeps 0 and 749.
    applyMove(fx, clip, moveRequest(100, 700, other, pushed));
    CHECK(timesOf(fx.clip(clip).video.keyframes.scale) == std::vector<CMTime>{f30(0), f30(100), f30(700), f30(749)});

    // The whole clip replaces everything, as the helper always did.
    applyMove(fx, clip, moveRequest(0, 899, whole, pushed));
    CHECK(timesOf(fx.clip(clip).video.keyframes.y) == std::vector<CMTime>{f30(0), f30(899)});
}

TEST_CASE("planMotionMove: keyframes a trim hid are kept unless the move reaches that end of the clip") {
    Animated a;
    Fixture &fx = a.fx;
    // The clip plays source [60, 150) at timeline [30, 120). X gets hidden keyframes at source 30
    // (before the in point) and 200 (after the out point).
    Clip &c = *fx.sequence().findClip(a.clip);
    c.video.keyframes.x = {key(f30(30), -50), key(f30(60), 0, KeyframeInterpolation::EaseInOut), key(f30(150), 300),
                           key(f30(200), 400)};
    fx.requireValid();
    const MotionFraming start{0, 0, 1};
    const MotionFraming end{10, 10, 1.2};

    SUBCASE("a move inside the clip keeps both hidden keyframes (SetMotionTracks accepts them)") {
        const MotionMovePlan plan = applyMove(fx, a.clip, moveRequest(40, 59, start, end));
        // Source 60 (frame 30) and 150 (the out point, the last frame) are outside the move.
        CHECK(timesOf(fx.clip(a.clip).video.keyframes.x) ==
              std::vector<CMTime>{f30(30), f30(60), f30(70), f30(89), f30(150), f30(200)});
        // Before the move the kept keyframes on frame 30 have its start framing (x 0, scale 1): it
        // holds. After it X's keyframe on the out point (300) and Scale's on frame 70 (2) lead on.
        CHECK(plan.before.parameters.empty());
        CHECK(plan.after.parameters == std::vector<MotionParameter>{MotionParameter::X, MotionParameter::Scale});
        CHECK(plan.after.keyframeTime == f30(150));
    }
    SUBCASE("a move from the clip's first frame replaces the hidden keyframe before it") {
        applyMove(fx, a.clip, moveRequest(30, 59, start, end));
        CHECK(timesOf(fx.clip(a.clip).video.keyframes.x) == std::vector<CMTime>{f30(60), f30(89), f30(150), f30(200)});
    }
    SUBCASE("a move to the clip's last frame replaces the out point's and the hidden one after it") {
        applyMove(fx, a.clip, moveRequest(100, 119, start, end));
        CHECK(timesOf(fx.clip(a.clip).video.keyframes.x) == std::vector<CMTime>{f30(30), f30(60), f30(130), f30(149)});
    }
    SUBCASE("the whole clip replaces every keyframe") {
        applyMove(fx, a.clip, moveRequest(30, 119, start, end));
        CHECK(timesOf(fx.clip(a.clip).video.keyframes.x) == std::vector<CMTime>{f30(60), f30(149)});
        CHECK(timesOf(fx.clip(a.clip).video.keyframes.scale) == std::vector<CMTime>{f30(60), f30(149)});
    }
    // A new keyframe outside the clip is still refused.
    SetMotionTracks outside(fx.seq, a.clip, {MotionTrackChange{MotionParameter::X, {key(f30(31), -50)}, 0}});
    applyRefused(fx.project, outside, EditError::InvalidTime);
}

TEST_CASE("planMotionMove refuses frames outside the clip, fewer than two frames and bad values") {
    Animated a;
    const Clip &clip = a.fx.clip(a.clip); // timeline [30, 120)
    MotionMovePlan plan;
    const MotionFraming framing{0, 0, 1};
    CHECK(planMotionMove(clip, f30(1), moveRequest(29, 60, framing, framing), plan).error == EditError::InvalidTime);
    CHECK(planMotionMove(clip, f30(1), moveRequest(30, 120, framing, framing), plan).error == EditError::InvalidTime);
    CHECK(planMotionMove(clip, f30(1), moveRequest(60, 60, framing, framing), plan).error == EditError::InvalidTime);
    CHECK(planMotionMove(clip, f30(1), moveRequest(61, 60, framing, framing), plan).error == EditError::InvalidTime);
    MotionMoveRequest offGrid = moveRequest(40, 60, framing, framing);
    offGrid.firstFrame = CMTimeMake(81, 60);
    CHECK(planMotionMove(clip, f30(1), offGrid, plan).error == EditError::InvalidTime);
    CHECK(planMotionMove(clip, f30(1), moveRequest(40, 60, framing, framing, KeyframeInterpolation::Bezier), plan).error ==
          EditError::InvalidArgument);
    CHECK(planMotionMove(clip, f30(1), moveRequest(40, 60, framing, MotionFraming{0, 0, -1}), plan).error ==
          EditError::InvalidArgument);
    CHECK(planMotionMove(clip, f30(1), moveRequest(30, 31, framing, framing), plan).ok()); // two frames
    CHECK(plan.changes.size() == 3);
}

TEST_CASE("planMotionAtFrame: animated parameters get a keyframe on the frame, static ones a static value") {
    Animated a;
    Fixture &fx = a.fx;
    // x: keyframes on source 60 (frame 30) and 150 (the out point: the last frame); y static;
    // scale: 60 and 100; rotation: 60 and 149 (the last frame); opacity static 0.8.
    const VideoParams values(10, 20, 1.5, 45, 0.5);
    std::vector<MotionTrackChange> changes;

    SUBCASE("the first frame") {
        REQUIRE(planMotionAtFrame(fx.clip(a.clip), f30(1), f30(30), values, changes).ok());
        REQUIRE(changes.size() == 5);
        SetMotionTracks set(fx.seq, a.clip, changes, "Match Previous Clip");
        applyReversible(fx.project, set);
        const Clip &clip = fx.clip(a.clip);
        CHECK(timesOf(clip.video.keyframes.x) == std::vector<CMTime>{f30(60), f30(150)});
        CHECK(clip.video.keyframes.x[0].value == 10);
        CHECK(clip.video.keyframes.x[0].interpolation == KeyframeInterpolation::EaseInOut); // kept
        CHECK(clip.video.keyframes.scale[0].interpolation == KeyframeInterpolation::Hold);
        CHECK(clip.video.keyframes.y.empty());
        CHECK(clip.video.y == 20);
        CHECK(clip.video.keyframes.opacity.empty());
        CHECK(clip.video.opacity == 0.5);
        const VideoParams shown = Scheduler::motionAt(clip, f30(30));
        CHECK(shown == values);
        CHECK(clip.video.keyframes.x[1].value == 300); // the rest of the animation is kept
    }
    SUBCASE("the last frame: the out point's keyframe moves to the frame's start, scale gets a new one") {
        fx.sequence().findClip(a.clip)->video.keyframes.x[1].interpolation = KeyframeInterpolation::EaseIn;
        REQUIRE(planMotionAtFrame(fx.clip(a.clip), f30(1), f30(119), values, changes).ok());
        SetMotionTracks set(fx.seq, a.clip, changes, "Match Next Clip");
        applyReversible(fx.project, set);
        const Clip &clip = fx.clip(a.clip);
        CHECK(timesOf(clip.video.keyframes.x) == std::vector<CMTime>{f30(60), f30(149)});
        CHECK(clip.video.keyframes.x[1].value == 10);
        CHECK(clip.video.keyframes.x[1].interpolation == KeyframeInterpolation::EaseIn);
        CHECK(timesOf(clip.video.keyframes.scale) == std::vector<CMTime>{f30(60), f30(100), f30(149)});
        CHECK(clip.video.keyframes.scale[2].interpolation == KeyframeInterpolation::Linear);
        CHECK(timesOf(clip.video.keyframes.rotation) == std::vector<CMTime>{f30(60), f30(149)});
        checkSameMotion(Scheduler::motionAt(clip, f30(119)), values);
    }
    CHECK(planMotionAtFrame(fx.clip(a.clip), f30(1), f30(120), values, changes).error == EditError::InvalidTime);
    CHECK(planMotionAtFrame(fx.clip(a.clip), f30(1), f30(30), VideoParams(0, 0, 1, 0, 2), changes).error ==
          EditError::InvalidArgument);
}

TEST_CASE("adjacentClip finds the touching clip on the same track") {
    Fixture fx;
    const ClipId first = fx.addClip(fx.v1, fx.av30, 0, 60);
    const ClipId second = fx.addClip(fx.v1, fx.av30, 60, 60, 100);
    const ClipId apart = fx.addClip(fx.v1, fx.av30, 130, 30);
    const ClipId above = fx.addClip(fx.v2, fx.av30, 120, 10);
    fx.requireValid();
    CHECK(adjacentClip(fx.sequence(), second, ClipEdge::Head)->id == first);
    CHECK(adjacentClip(fx.sequence(), first, ClipEdge::Tail)->id == second);
    CHECK(adjacentClip(fx.sequence(), first, ClipEdge::Head) == nullptr);
    CHECK(adjacentClip(fx.sequence(), second, ClipEdge::Tail) == nullptr); // a 10-frame gap
    CHECK(adjacentClip(fx.sequence(), apart, ClipEdge::Head) == nullptr);  // V2's clip is on another track
    CHECK(adjacentClip(fx.sequence(), above, ClipEdge::Tail) == nullptr);
    CHECK(adjacentClip(fx.sequence(), ClipId(9999), ClipEdge::Head) == nullptr);
    CHECK(motionValuesMatch(MotionParameter::X, 100, 100 + 1e-5));
    CHECK_FALSE(motionValuesMatch(MotionParameter::X, 100, 100.01));
    CHECK(motionValuesMatch(MotionParameter::Scale, 1, 1 + 5e-7));
}
