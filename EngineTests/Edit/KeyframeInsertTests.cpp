// Adding a keyframe changes no picture (motion/photos review findings 1, 4, 5 and 19): AddKeyframe,
// the Control-K toggle (planMotionKeyframeToggle) and SetMotionValue's add path insert through the
// segment's exact division (insertKeyframeKeepingValues), so a hold stays a hold and an eased or
// custom segment becomes its two exact parts. Every frame of the clip is compared with what it showed
// before the edit, and with an independent reference for the curves (Newton's method on the Bezier
// timing function, not the engine's bisection). A value set on a frame whose keyframe lies elsewhere
// in its span (a split's out point, a sped-up clip) lands on the frame's start, and a keyframe on the
// next precise tick shows on its own frame after a hold.

#include "EditTestSupport.h"

#include "../../Engine/Render/Scheduler.h"

#include <cmath>
#include <functional>
#include <map>
#include <vector>

using namespace vetest;

namespace {

Keyframe key(CMTime time, double value, KeyframeInterpolation interpolation = KeyframeInterpolation::Linear) {
    Keyframe k;
    k.time = time;
    k.value = value;
    k.interpolation = interpolation;
    return k;
}

Keyframe custom(CMTime time, double value, TimingCurve curve) {
    Keyframe k = key(time, value, KeyframeInterpolation::Bezier);
    k.curve = curve;
    return k;
}

// A custom curve that is not one of the eases (as a split leaves one).
const TimingCurve kCustomCurve{0.3, 0.1, 0.6, 0.95};

// Independent reference for a timing curve: Newton's method on x(t) (the engine bisects), then y(t).
double referenceCurve(const TimingCurve &c, double u) {
    auto bez = [](double p1, double p2, double t) {
        const double v = 1 - t;
        return 3 * v * v * t * p1 + 3 * v * t * t * p2 + t * t * t;
    };
    auto dbez = [](double p1, double p2, double t) {
        const double v = 1 - t;
        return 3 * v * v * p1 + 6 * v * t * (p2 - p1) + 3 * t * t * (1 - p2);
    };
    double t = u;
    for (int i = 0; i < 200; ++i) {
        const double d = dbez(c.x1, c.x2, t);
        if (std::fabs(d) < 1e-14) {
            break;
        }
        const double next = std::clamp(t - (bez(c.x1, c.x2, t) - u) / d, 0.0, 1.0);
        if (next == t) {
            break;
        }
        t = next;
    }
    return bez(c.y1, c.y2, t);
}

// The value of a one-segment move from `from` to `to` over source frames [60, 150) with
// `interpolation` at source frame `s` (30 fps), computed without the engine.
double referenceMove(KeyframeInterpolation interpolation, double from, double to, double s) {
    const double u = std::clamp((s - 60.0) / 90.0, 0.0, 1.0);
    if (u >= 1.0) {
        return to;
    }
    switch (interpolation) {
    case KeyframeInterpolation::Hold:
        return from;
    case KeyframeInterpolation::Linear:
        return from + (to - from) * u;
    case KeyframeInterpolation::EaseOut:
        return from + (to - from) * referenceCurve(TimingCurve{0.42, 0.0, 1.0, 1.0}, u);
    case KeyframeInterpolation::EaseIn:
        return from + (to - from) * referenceCurve(TimingCurve{0.0, 0.0, 0.58, 1.0}, u);
    case KeyframeInterpolation::EaseInOut:
        return from + (to - from) * referenceCurve(TimingCurve{0.42, 0.0, 0.58, 1.0}, u);
    case KeyframeInterpolation::Bezier:
        return from + (to - from) * referenceCurve(kCustomCurve, u);
    }
    return from;
}

// A 90-frame clip of av30 on V1 at timeline frame 30 from source frame 60 (frame f shows source
// frame f + 30), every Motion parameter animated over the whole clip with a different segment kind.
struct Moving {
    Fixture fx;
    ClipId clip;

    Moving() {
        clip = fx.addClip(fx.v1, fx.av30, 30, 90, 60);
        Clip &c = *fx.sequence().findClip(clip);
        c.video.keyframes.x = {key(f30(60), 0, KeyframeInterpolation::EaseInOut), key(f30(150), 300)};
        c.video.keyframes.y = {key(f30(60), -40, KeyframeInterpolation::EaseOut), key(f30(150), 80)};
        c.video.keyframes.scale = {key(f30(60), 1, KeyframeInterpolation::Hold), key(f30(150), 2)};
        c.video.keyframes.rotation = {key(f30(60), 0, KeyframeInterpolation::EaseIn), key(f30(150), 90)};
        c.video.keyframes.opacity = {custom(f30(60), 0.2, kCustomCurve), key(f30(150), 1)};
        fx.requireValid();
    }

    const Clip &get() const {
        return fx.clip(clip);
    }
};

// What each of the clip's frames shows, in order.
std::vector<VideoParams> everyFrame(const Clip &clip) {
    std::vector<VideoParams> frames;
    for (CMTime t = clip.timelineStart; t < clip.timelineEnd(); t = t + f30(1)) {
        frames.push_back(Scheduler::motionAt(clip, t));
    }
    return frames;
}

void checkClose(double a, double b) {
    CHECK(std::fabs(a - b) <= 1e-9 * std::max(1.0, std::max(std::fabs(a), std::fabs(b))));
}

void checkSamePictures(const std::vector<VideoParams> &after, const std::vector<VideoParams> &before) {
    REQUIRE(after.size() == before.size());
    for (std::size_t i = 0; i < after.size(); ++i) {
        CAPTURE(i);
        checkClose(after[i].x, before[i].x);
        checkClose(after[i].y, before[i].y);
        checkClose(after[i].scale, before[i].scale);
        checkClose(after[i].rotationDegrees, before[i].rotationDegrees);
        checkClose(after[i].opacity, before[i].opacity);
    }
}

// The fixture's pictures from the independent reference, frame by frame.
void checkAgainstReference(const std::vector<VideoParams> &frames) {
    for (std::size_t i = 0; i < frames.size(); ++i) {
        CAPTURE(i);
        const double s = 60.0 + static_cast<double>(i);
        checkClose(frames[i].x, referenceMove(KeyframeInterpolation::EaseInOut, 0, 300, s));
        checkClose(frames[i].y, referenceMove(KeyframeInterpolation::EaseOut, -40, 80, s));
        checkClose(frames[i].scale, referenceMove(KeyframeInterpolation::Hold, 1, 2, s));
        checkClose(frames[i].rotationDegrees, referenceMove(KeyframeInterpolation::EaseIn, 0, 90, s));
        checkClose(frames[i].opacity, std::clamp(referenceMove(KeyframeInterpolation::Bezier, 0.2, 1, s), 0.0, 1.0));
    }
}

// Timeline frames (30 fps) the tests insert on, in this order: inside the segment, then near its start
// and end (fractions 1/90 and 88/90), then into the parts the first inserts left (nested divisions).
const std::int64_t kInsertFrames[] = {77, 31, 118, 50, 64, 95};

} // namespace

TEST_CASE("Keyframe inserts: the reference agrees with the fixture before any edit") {
    Moving m;
    checkAgainstReference(everyFrame(m.get()));
}

TEST_CASE("Keyframe inserts: AddKeyframe keeps every frame inside a hold, a linear, each ease and a custom curve") {
    Moving m;
    Fixture &fx = m.fx;
    const std::vector<VideoParams> before = everyFrame(m.get());
    for (const MotionParameter parameter : kMotionParameters) {
        CAPTURE(nameOf(parameter));
        for (const std::int64_t frame : kInsertFrames) {
            CAPTURE(frame);
            AddKeyframe add(fx.seq, m.clip, parameter, f30(frame + 30));
            applyReversible(fx.project, add);
            const std::vector<VideoParams> after = everyFrame(m.get());
            checkSamePictures(after, before);
            checkAgainstReference(after);
        }
        // A source time off the frame grid (a seventh of a frame into source frame 100).
        AddKeyframe offGrid(fx.seq, m.clip, parameter, CMTimeMake(701, 210));
        applyReversible(fx.project, offGrid);
        checkSamePictures(everyFrame(m.get()), before);
    }
    // A hold stays a hold on both sides; an eased or custom segment became custom parts.
    for (const Keyframe &k : m.get().video.keyframes.scale) {
        if (!(k.time == f30(150))) {
            CHECK(k.interpolation == KeyframeInterpolation::Hold);
        }
    }
    for (const MotionParameter parameter :
         {MotionParameter::X, MotionParameter::Y, MotionParameter::Rotation, MotionParameter::Opacity}) {
        const KeyframeTrack &track = m.get().video.keyframes.track(parameter);
        REQUIRE(track.size() == 2 + std::size(kInsertFrames) + 1);
        for (std::size_t i = 0; i + 1 < track.size(); ++i) {
            CHECK(track[i].interpolation == KeyframeInterpolation::Bezier);
            CHECK(track[i].curve.isValid());
        }
    }

    // A linear segment stays linear on both sides, exact at every frame.
    const ClipId straight = fx.addClip(fx.v2, fx.av30, 30, 90, 60);
    fx.sequence().findClip(straight)->video.keyframes.x = {key(f30(60), -30), key(f30(150), 60)};
    fx.requireValid();
    for (const std::int64_t frame : kInsertFrames) {
        AddKeyframe add(fx.seq, straight, MotionParameter::X, f30(frame + 30));
        applyReversible(fx.project, add);
    }
    const Clip &line = fx.clip(straight);
    for (const Keyframe &k : line.video.keyframes.x) {
        CHECK(k.interpolation == KeyframeInterpolation::Linear);
    }
    for (std::int64_t f = 0; f < 90; ++f) {
        CAPTURE(f);
        checkClose(Scheduler::motionAt(line, f30(30 + f)).x, -30.0 + static_cast<double>(f));
    }
}

TEST_CASE("Keyframe inserts: the Control-K toggle keeps every frame (each parameter's own segment kind)") {
    Moving m;
    Fixture &fx = m.fx;
    const std::vector<VideoParams> before = everyFrame(m.get());
    for (const std::int64_t frame : kInsertFrames) {
        CAPTURE(frame);
        MotionKeyframeToggle plan;
        REQUIRE(planMotionKeyframeToggle(m.get(), f30(1), f30(frame), plan).ok());
        REQUIRE_FALSE(plan.removing);
        CHECK(plan.changes.size() == 5);
        SetMotionTracks toggle(fx.seq, m.clip, plan.changes, "Add Keyframes");
        applyReversible(fx.project, toggle);
        const std::vector<VideoParams> after = everyFrame(m.get());
        checkSamePictures(after, before);
        checkAgainstReference(after);
    }
    // Scale was a hold: every new keyframe holds too.
    for (const Keyframe &k : m.get().video.keyframes.scale) {
        CHECK((k.interpolation == KeyframeInterpolation::Hold || k.time == f30(150)));
    }
    // A frame that now has all five keyframes toggles them off.
    MotionKeyframeToggle removal;
    REQUIRE(planMotionKeyframeToggle(m.get(), f30(1), f30(77), removal).ok());
    CHECK(removal.removing);
}

TEST_CASE("Keyframe inserts: SetMotionValue's add path with the value there keeps every frame") {
    Moving m;
    Fixture &fx = m.fx;
    const std::vector<VideoParams> before = everyFrame(m.get());
    for (const MotionParameter parameter : kMotionParameters) {
        CAPTURE(nameOf(parameter));
        for (const std::int64_t frame : kInsertFrames) {
            CAPTURE(frame);
            const double value = before[static_cast<std::size_t>(frame - 30)].staticValue(parameter);
            SetMotionValue set(fx.seq, m.clip, parameter, f30(frame + 30), value);
            applyReversible(fx.project, set);
            CHECK(set.name() == "Add Keyframe");
            checkSamePictures(everyFrame(m.get()), before);
        }
    }
    checkAgainstReference(everyFrame(m.get()));
}

TEST_CASE("Keyframe inserts: explicit values and interpolations apply after the division") {
    Moving m;
    Fixture &fx = m.fx;
    const std::vector<VideoParams> before = everyFrame(m.get());
    // A new value on a hold: the frames before the keyframe still hold the old value, the new one
    // holds from the keyframe on (a hold stays a hold), the rest of the clip is unchanged.
    SetMotionValue set(fx.seq, m.clip, MotionParameter::Scale, f30(100), 1.5);
    applyReversible(fx.project, set);
    const std::vector<VideoParams> after = everyFrame(m.get());
    for (std::size_t i = 0; i < after.size(); ++i) {
        CAPTURE(i);
        checkClose(after[i].scale, i < 40 ? 1.0 : 1.5);
        checkClose(after[i].x, before[i].x);
    }
    // An interpolation asked for replaces the divided segment's.
    AddKeyframe linear(fx.seq, m.clip, MotionParameter::X, f30(120), std::nullopt, KeyframeInterpolation::Linear);
    applyReversible(fx.project, linear);
    const KeyframeTrack &x = m.get().video.keyframes.x;
    REQUIRE(x.size() == 3);
    CHECK(x[0].interpolation == KeyframeInterpolation::Bezier);
    CHECK(x[1].interpolation == KeyframeInterpolation::Linear);
    CHECK(x[1].curve == TimingCurve{});
    // Before the keyframe nothing changed.
    const std::vector<VideoParams> later = everyFrame(m.get());
    for (std::size_t i = 0; i <= 60; ++i) {
        CAPTURE(i);
        checkClose(later[i].x, before[i].x);
    }
}

TEST_CASE("Keyframe inserts: before the first keyframe, after the last, and on an empty track") {
    Fixture fx;
    const ClipId id = fx.addClip(fx.v1, fx.av30, 30, 90, 60);
    Clip &c = *fx.sequence().findClip(id);
    c.video.keyframes.x = {key(f30(80), 10, KeyframeInterpolation::EaseIn), key(f30(120), 50, KeyframeInterpolation::Hold)};
    c.video.y = 7;
    fx.requireValid();
    const std::vector<VideoParams> before = everyFrame(fx.clip(id));
    for (const auto &[parameter, time] : std::vector<std::pair<MotionParameter, CMTime>>{
             {MotionParameter::X, f30(70)}, {MotionParameter::X, f30(140)}, {MotionParameter::Y, f30(90)}}) {
        AddKeyframe add(fx.seq, id, parameter, time);
        applyReversible(fx.project, add);
        checkSamePictures(everyFrame(fx.clip(id)), before);
    }
    const KeyframeTrack &x = fx.clip(id).video.keyframes.x;
    REQUIRE(x.size() == 4);
    CHECK(x[0] == key(f30(70), 10, KeyframeInterpolation::Linear)); // holds the first value
    CHECK(x[1].interpolation == KeyframeInterpolation::EaseIn);      // untouched
    CHECK(x[3] == key(f30(140), 50, KeyframeInterpolation::Linear)); // holds the last value
    CHECK(fx.clip(id).video.keyframes.y == KeyframeTrack{key(f30(90), 7)});
}

TEST_CASE("Keyframe inserts: insertKeyframeKeepingValues returns the index and leaves an existing keyframe") {
    KeyframeTrack track{key(f30(0), 0, KeyframeInterpolation::Hold), key(f30(30), 30)};
    const KeyframeTrack original = track;
    CHECK(insertKeyframeKeepingValues(track, 0, f30(30)) == 1);
    CHECK(track == original);
    CHECK(insertKeyframeKeepingValues(track, 0, f30(10)) == 1);
    CHECK(track[1] == key(f30(10), 0, KeyframeInterpolation::Hold));
    CHECK(track.size() == 3);
    KeyframeTrack empty;
    CHECK(insertKeyframeKeepingValues(empty, 4.5, f30(3)) == 0);
    CHECK(empty == KeyframeTrack{key(f30(3), 4.5)});
}

TEST_CASE("Keyframe inserts: an overshooting custom curve refuses a keyframe with the out-of-range value") {
    Fixture fx;
    const ClipId id = fx.addClip(fx.v1, fx.av30, 0, 60, 0);
    // Opacity rises from 0.5 to 1 along a curve that overshoots 1 (only a project file makes one).
    fx.sequence().findClip(id)->video.keyframes.opacity = {custom(f30(0), 0.5, TimingCurve{0.2, 3.0, 0.8, 3.0}),
                                                           key(f30(60), 1)};
    fx.requireValid();
    AddKeyframe inside(fx.seq, id, MotionParameter::Opacity, f30(30));
    const EditResult refused = applyRefused(fx.project, inside, EditError::InvalidArgument);
    CHECK(refused.message.find("goes outside its range") != std::string::npos);
    // With a value given the keyframe is fine.
    AddKeyframe given(fx.seq, id, MotionParameter::Opacity, f30(30), 0.9);
    applyReversible(fx.project, given);
    // A split through the overshoot is refused with a reason, not an invariant violation.
    fx.sequence().findClip(id)->video.keyframes.opacity = {custom(f30(0), 0.5, TimingCurve{0.2, 3.0, 0.8, 3.0}),
                                                           key(f30(60), 1)};
    fx.requireValid();
    SplitClip split(fx.seq, id, f30(30));
    const EditResult splitRefusal = applyRefused(fx.project, split, EditError::InvalidArgument);
    CHECK(splitRefusal.message.find("cannot be split") != std::string::npos);
    // Where the curve stays within the range the split goes through.
    REQUIRE(isValidMotionValue(MotionParameter::Opacity,
                               evaluateTrack(fx.clip(id).video.keyframes.opacity, 1, *ExactTime::from(f30(2)))));
    SplitClip early(fx.seq, id, f30(2));
    applyReversible(fx.project, early);
}

TEST_CASE("Keyframe values on frames: a value set where the frame's keyframe is not on its start shows exactly") {
    SUBCASE("a split's out point") {
        // x linear 0 -> -150 over 40 frames, split at 20: the left piece's last frame (19) owns the
        // out-point keyframe (-75 at source 20) and shows -71.25.
        Fixture fx;
        const ClipId id = fx.addClip(fx.v1, fx.av30, 0, 40, 0);
        fx.sequence().findClip(id)->video.keyframes.x = {key(f30(0), 0), key(f30(40), -150)};
        fx.requireValid();
        SplitClip split(fx.seq, id, f30(20));
        applyReversible(fx.project, split);
        const Clip &left = fx.clip(id);
        REQUIRE(keyframeIndexForFrame(left, MotionParameter::X, f30(19), f30(1)) == std::optional<std::size_t>(1));
        CHECK(left.video.keyframes.x[1].time == f30(20));
        checkClose(Scheduler::motionAt(left, f30(19)).x, -71.25);

        // A +1 nudge of what the frame shows.
        MotionTrackChange change;
        REQUIRE(planMotionValueAtFrame(left, f30(1), f30(19), MotionParameter::X, -70.25, change).ok());
        SetMotionTracks set(fx.seq, id, {change}, "Change Keyframe");
        applyReversible(fx.project, set);
        const Clip &after = fx.clip(id);
        CHECK(Scheduler::motionAt(after, f30(19)).x == -70.25);
        CHECK(after.video.keyframes.x == KeyframeTrack{key(f30(0), 0), key(f30(19), -70.25)});
        // Frame 19's keyframe is on its start now; the frames before it move toward the new value.
        for (std::int64_t f = 0; f < 19; ++f) {
            CAPTURE(f);
            checkClose(Scheduler::motionAt(after, f30(f)).x, -70.25 * static_cast<double>(f) / 19.0);
        }
    }
    SUBCASE("a 1.5x clip: the keyframe inside the frame's span gives way") {
        Fixture fx;
        // 60 timeline frames at 3/2 from source 0: frame f starts at source 1.5 f (frames 30 fps).
        const ClipId id = fx.addClip(fx.v1, fx.av30, 0, 60, 0, 1.5);
        // Frame 10 spans source [15, 16.5): a keyframe at source 16 is inside it, not on its start.
        fx.sequence().findClip(id)->video.keyframes.y = {key(f30(0), 0, KeyframeInterpolation::EaseInOut),
                                                         key(f30(16), 100, KeyframeInterpolation::Hold),
                                                         key(f30(60), 200)};
        fx.requireValid();
        const Clip &clip = fx.clip(id);
        REQUIRE(keyframeIndexForFrame(clip, MotionParameter::Y, f30(10), f30(1)) == std::optional<std::size_t>(1));
        const double shown = Scheduler::motionAt(clip, f30(10)).y;
        const double before5 = Scheduler::motionAt(clip, f30(5)).y;
        CHECK(shown < 100); // the frame starts before the keyframe
        MotionTrackChange change;
        REQUIRE(planMotionValueAtFrame(clip, f30(1), f30(10), MotionParameter::Y, shown + 1, change).ok());
        SetMotionTracks set(fx.seq, id, {change}, "Change Keyframe");
        applyReversible(fx.project, set);
        const Clip &after = fx.clip(id);
        CHECK(Scheduler::motionAt(after, f30(10)).y == shown + 1);
        const KeyframeTrack &y = after.video.keyframes.y;
        REQUIRE(y.size() == 3);
        CHECK(y[1].time == CMTimeMake(15, 30));
        CHECK(y[1].interpolation == KeyframeInterpolation::Hold); // lent by the keyframe that gave way
        // The segment into the frame kept its eased shape (the custom part of the ease up to the
        // frame), scaled to the new value.
        checkClose(Scheduler::motionAt(after, f30(5)).y, before5 * (shown + 1) / shown);
        // After the frame the hold continues to the last keyframe.
        CHECK(Scheduler::motionAt(after, f30(20)).y == shown + 1);
    }
    SUBCASE("refusals") {
        Fixture fx;
        const ClipId id = fx.addClip(fx.v1, fx.av30, 0, 40, 0);
        MotionTrackChange change;
        CHECK(planMotionValueAtFrame(fx.clip(id), f30(1), f30(3), MotionParameter::X, 1, change).error ==
              EditError::InvalidArgument); // not animated
        fx.sequence().findClip(id)->video.keyframes.x = {key(f30(0), 0)};
        CHECK(planMotionValueAtFrame(fx.clip(id), f30(1), f30(40), MotionParameter::X, 1, change).error ==
              EditError::InvalidTime);
        CHECK(planMotionValueAtFrame(fx.clip(id), f30(1), f30(3), MotionParameter::Opacity, 1, change).error ==
              EditError::InvalidArgument);
    }
}

TEST_CASE("Keyframe on the next precise tick: its own frame shows it after a hold (NTSC, 999/1000)") {
    Fixture ntsc;
    ntsc.sequence().frameDuration = CMTimeMake(1001, 30000);
    const CMTime fd = ntsc.sequence().frameDuration;
    Clip slow;
    slow.id = ntsc.project.ids.make<ClipId>();
    slow.assetId = ntsc.av24;
    slow.trackId = ntsc.v1;
    slow.timelineStart = CMTimeMake(0, 30000);
    slow.timelineDuration = CMTimeMake(1001 * 100, 30000);
    slow.sourceIn = CMTimeMake(44101, 44100);
    slow.speed = Ratio{999, 1000};
    ntsc.sequence().findTrack(ntsc.v1)->clips.push_back(slow);
    // x holds 0 from the first frame; the toggle adds a keyframe on frame 7, whose exact source time
    // has no CMTime form (the keyframe goes on the next tick, up to 1.5 ns later).
    const CMTime frame7 = CMTimeMake(1001 * 7, 30000);
    REQUIRE_FALSE(slow.exactSourceTimeAt(frame7)->toTime().has_value());
    ntsc.sequence().findClip(slow.id)->video.keyframes.x = {key(slow.sourceIn, 0, KeyframeInterpolation::Hold)};
    ntsc.requireValid();

    SetMotionValue set(ntsc.seq, slow.id, MotionParameter::X, *keyframeTimeForFrame(ntsc.clip(slow.id), frame7), 100.0);
    applyReversible(ntsc.project, set);
    const Clip &clip = ntsc.clip(slow.id);
    REQUIRE(clip.video.keyframes.x.size() == 2);
    CHECK(clip.video.keyframes.x[0].interpolation == KeyframeInterpolation::Hold);
    // The frame the keyframe was set on shows its value (it used to show 0 until frame 8), and the
    // frame before still shows the hold.
    CHECK(Scheduler::motionAt(clip, frame7).x == 100.0);
    CHECK(Scheduler::motionAt(clip, CMTimeMake(1001 * 6, 30000)).x == 0.0);
    CHECK(Scheduler::motionAt(clip, CMTimeMake(1001 * 8, 30000)).x == 100.0);
    // The render graph layer the monitors and export draw carries the same value.
    CHECK(motionValuesAt(clip, frame7).x == 100.0);
    // x has its keyframe on frame 7 now: the toggle adds the other four there.
    MotionKeyframeToggle plan;
    REQUIRE(planMotionKeyframeToggle(clip, fd, frame7, plan).ok());
    CHECK_FALSE(plan.removing);
    CHECK(plan.changes.size() == 4);
}

// ----- Other edits on animated clips keep every picture (test gap 2) -----

namespace {

// What V1 shows on each timeline frame of [from, to), by timeline frame (no clip there: absent).
std::map<std::int64_t, VideoParams> timelinePictures(const Fixture &fx, std::int64_t from, std::int64_t to) {
    std::map<std::int64_t, VideoParams> pictures;
    for (std::int64_t f = from; f < to; ++f) {
        if (const Clip *clip = fx.sequence().findTrack(fx.v1)->clipAt(f30(f))) {
            pictures[f] = Scheduler::motionAt(*clip, f30(f));
        }
    }
    return pictures;
}

void checkSameAt(const std::map<std::int64_t, VideoParams> &after, const std::map<std::int64_t, VideoParams> &before,
                 std::int64_t shift = 0) {
    for (const auto &[frame, shown] : after) {
        CAPTURE(frame);
        const auto was = before.find(frame - shift);
        REQUIRE(was != before.end());
        checkClose(shown.x, was->second.x);
        checkClose(shown.y, was->second.y);
        checkClose(shown.scale, was->second.scale);
        checkClose(shown.rotationDegrees, was->second.rotationDegrees);
        checkClose(shown.opacity, was->second.opacity);
    }
}

} // namespace

TEST_CASE("Animated clips: a split at 1.5x, an overwrite inside, a move onto and a ripple keep the pictures") {
    Fixture fx;
    // 60 timeline frames at 3/2 from source frame 30: every parameter animated with its own kind.
    const ClipId id = fx.addClip(fx.v1, fx.av30, 30, 60, 30, 1.5);
    Clip &c = *fx.sequence().findClip(id);
    c.video.keyframes.x = {key(f30(30), 0, KeyframeInterpolation::EaseInOut), key(f30(120), 300)};
    c.video.keyframes.scale = {key(f30(30), 1, KeyframeInterpolation::Hold), key(f30(75), 2, KeyframeInterpolation::EaseIn),
                               key(f30(120), 0.5)};
    c.video.keyframes.opacity = {custom(f30(40), 0.3, kCustomCurve), key(f30(100), 1)};
    fx.requireValid();
    const auto before = timelinePictures(fx, 0, 200);
    REQUIRE(before.size() == 60);

    SUBCASE("a split at speed 1.5, then each piece split again (a custom part divided again)") {
        SplitClip split(fx.seq, id, f30(47));
        applyReversible(fx.project, split);
        checkSameAt(timelinePictures(fx, 0, 200), before);
        const ClipId right = split.createdClipIds().front();
        SplitClip again(fx.seq, right, f30(71));
        applyReversible(fx.project, again);
        SplitClip left(fx.seq, id, f30(33));
        applyReversible(fx.project, left);
        checkSameAt(timelinePictures(fx, 0, 200), before);
    }
    SUBCASE("an overwrite inside it leaves both remaining parts as they were") {
        ClipPlacement other = place(fx.v1, fx.av24, 0, 10);
        OverwriteClip overwrite(fx.seq, f30(50), {other}, false);
        applyReversible(fx.project, overwrite);
        auto after = timelinePictures(fx, 0, 200);
        for (std::int64_t f = 50; f < 50 + 9; ++f) {
            after.erase(f); // the other clip's frames
        }
        const ClipId inserted = overwrite.createdClipIds().front();
        for (auto it = after.begin(); it != after.end();) {
            it = fx.sequence().findTrack(fx.v1)->clipAt(f30(it->first))->id == inserted ? after.erase(it) : std::next(it);
        }
        CHECK(after.size() >= 50);
        checkSameAt(after, before);
    }
    SUBCASE("another clip moved onto it cuts it without changing what is left") {
        const ClipId mover = fx.addClip(fx.v2, fx.av24, 100, 12, 0);
        fx.requireValid();
        MoveClip move(fx.seq, mover, fx.v1, f30(60), false);
        applyReversible(fx.project, move);
        auto after = timelinePictures(fx, 0, 200);
        for (auto it = after.begin(); it != after.end();) {
            it = fx.sequence().findTrack(fx.v1)->clipAt(f30(it->first))->id == mover ? after.erase(it) : std::next(it);
        }
        CHECK(after.size() == 48);
        checkSameAt(after, before);
    }
    SUBCASE("a ripple delete before it moves its pictures with it") {
        const ClipId earlier = fx.addClip(fx.v1, fx.av24, 10, 20, 0);
        fx.requireValid();
        RippleOptions options;
        options.includeLinked = false;
        RippleDelete ripple(fx.seq, {earlier}, options);
        applyReversible(fx.project, ripple);
        CHECK(fx.clip(id).timelineStart == f30(10));
        checkSameAt(timelinePictures(fx, 0, 200), before, -20);
    }
}
