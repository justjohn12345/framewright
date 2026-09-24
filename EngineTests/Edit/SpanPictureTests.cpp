// Spans stay on their pictures through clip edits: a split divides them exactly, moves and ripples
// carry them along, overwrite and trims cut them, a speed change moves them with the source frames
// and a still keeps its spans at its timeline offsets. Every frame is compared with an independent
// reference of the move (SpanReference.h) evaluated at the source time the frame shows, so an edit
// that shifted, stretched or re-evaluated a span by a frame would show.

#include "../Model/SpanReference.h"
#include "EditTestSupport.h"

using namespace vetest;

namespace {

using KI = KeyframeInterpolation;

// The fixture's move, by source second (the clip's static values composed in):
//   lane 1 Motion [1.5 s, 3.5 s): x -100 -> 200 and scale 1 -> 1.8, easing in and out;
//   lane 2 Opacity [1 s, 2.5 s): 1 -> 0.3, linear.
// Statics: x 12, scale 1.25, opacity 0.9.
VideoParams referenceMove(double s) {
    VideoParams v{12, 0, 1.25, 0, 0.9};
    v.x += referenceSpanValue(1.5, 3.5, -100, 200, KI::EaseInOut, s).value_or(0);
    v.scale *= referenceSpanValue(1.5, 3.5, 1, 1.8, KI::EaseInOut, s).value_or(1);
    v.opacity *= referenceSpanValue(1, 2.5, 1, 0.3, KI::Linear, s).value_or(1);
    return v;
}

bool close(double a, double b) {
    return std::fabs(a - b) <= 1e-9 * std::max(1.0, std::fabs(b));
}

// V1: the moving clip, 90 frames from source frame 30 (1 s), at timeline frame `start`; linked to
// its audio on A1.
struct Moving : Fixture {
    ClipId v, a;
    SpanId motion, opacity;

    explicit Moving(std::int64_t start = 0) {
        std::tie(v, a) = addLinkedPair(start, 90, 30);
        sequence().findClip(v)->video = VideoParams{12, 0, 1.25, 0, 0.9};
        SpanTracks move;
        move.x = rampTrack(-100, 200, CMTimeMake(2, 1), KI::EaseInOut);
        move.scale = rampTrack(1, 1.8, CMTimeMake(2, 1), KI::EaseInOut);
        motion = addSpan(v, SpanKind::Motion, 1, CMTimeMake(3, 2), CMTimeMake(7, 2), move);
        SpanTracks fade;
        fade.opacity = rampTrack(1, 0.3, CMTimeMake(3, 2));
        opacity = addSpan(v, SpanKind::Opacity, 2, CMTimeMake(1, 1), CMTimeMake(5, 2), fade);
        requireValid();
    }

    // Checks every frame of the moving clip's pieces on V1 (the clips with its static values)
    // against the reference at the source time the frame shows; returns the number of frames
    // checked.
    int checkPictures() const {
        int checked = 0;
        for (const Clip &clip : sequence().videoTracks[0].clips) {
            if (!(clip.video == VideoParams{12, 0, 1.25, 0, 0.9})) {
                continue; // a clip an edit placed
            }
            const auto [first, last] = framesOf(clip);
            for (std::int64_t f = first; f < last; ++f) {
                const auto source = clip.exactSourceTimeAt(f30(f));
                REQUIRE(source.has_value());
                const VideoParams want = referenceMove(source->toDouble());
                const VideoParams shown = motionValuesAt(clip, f30(f));
                INFO("clip " << clip.id.value() << " frame " << f);
                CHECK(close(shown.x, want.x));
                CHECK(close(shown.scale, want.scale));
                CHECK(close(shown.opacity, want.opacity));
                ++checked;
            }
        }
        return checked;
    }
};

} // namespace

TEST_CASE("Span pictures: the fixture matches its reference before any edit") {
    Moving fx;
    CHECK(fx.checkPictures() == 90);
}

TEST_CASE("Span pictures: a split divides the spans exactly") {
    for (const std::int64_t at : {10, 20, 44, 45, 46, 75, 89}) {
        CAPTURE(at);
        Moving fx;
        SplitClip split(fx.seq, fx.v, f30(at));
        const EditResult r = applyReversible(fx.project, split);
        CHECK(r.droppedSpanIds.empty());
        CHECK(fx.checkPictures() == 90);
        const ClipId right = split.createdClipIds()[0];
        // A span wholly on one side keeps its id there; one the cut divides keeps it on the left
        // and its right part gets a new one.
        for (const EffectSpan &span : fx.clip(right).spans) {
            CHECK(fx.clip(fx.v).findSpan(span.id) == nullptr);
        }
        // Motion covers timeline frames [15, 75), Opacity [0, 45).
        CHECK((fx.clip(fx.v).findSpan(fx.motion) != nullptr) == (at > 15));
        CHECK((fx.clip(right).findSpan(fx.motion) != nullptr) == (at <= 15));
        CHECK(fx.clip(fx.v).findSpan(fx.opacity) != nullptr);
        CHECK(fx.clip(right).spans.size() == (at < 45 ? 2u : at < 75 ? 1u : 0u));
    }
}

TEST_CASE("Span pictures: moves and ripples carry the spans along") {
    Moving fx;
    SUBCASE("MoveClip") {
        MoveClip move(fx.seq, fx.v, fx.v1, f30(37));
        applyReversible(fx.project, move);
        CHECK(fx.clip(fx.v).timelineStart == f30(37));
        CHECK(fx.checkPictures() == 90);
    }
    SUBCASE("an insert before it ripples it") {
        InsertClip insert(fx.seq, f30(0), {place(fx.v1, fx.av30, 900, 920)});
        applyReversible(fx.project, insert);
        CHECK(fx.clip(fx.v).timelineStart == f30(20));
        CHECK(fx.checkPictures() == 90);
    }
    SUBCASE("a ripple delete before it") {
        Moving later(30);
        const ClipId first = later.addClip(later.v1, later.av30, 0, 30, 1200);
        later.requireValid();
        RippleDelete ripple(later.seq, {first});
        applyReversible(later.project, ripple);
        CHECK(later.clip(later.v).timelineStart == f30(0));
        CHECK(later.checkPictures() == 90);
    }
}

TEST_CASE("Span pictures: overwrite and trims cut the spans at the new edges, exactly") {
    Moving fx;
    SUBCASE("an overwrite through the middle leaves two pieces") {
        OverwriteClip overwrite(fx.seq, f30(30), {place(fx.v1, fx.av30, 900, 930)});
        const EditResult r = applyReversible(fx.project, overwrite);
        CHECK(r.droppedSpanIds.empty());
        CHECK(fx.checkPictures() == 60); // the pieces before and after the overwritten 30 frames
    }
    SUBCASE("an overwrite over the Opacity span's frames removes that part and reports a span it removed") {
        OverwriteClip overwrite(fx.seq, f30(0), {place(fx.v1, fx.av30, 900, 945)});
        const EditResult r = applyReversible(fx.project, overwrite);
        // Opacity [1 s, 2.5 s) is source frames [30, 75): the 45 frames overwritten cover it.
        CHECK(r.droppedSpanIds == std::vector<SpanId>{fx.opacity});
        CHECK(fx.checkPictures() == 45);
    }
    SUBCASE("head and tail trims") {
        TrimClipHead head(fx.seq, fx.v, f30(20));
        applyReversible(fx.project, head);
        TrimClipTail tail(fx.seq, fx.v, f30(70));
        applyReversible(fx.project, tail);
        CHECK(fx.checkPictures() == 50);
        // Extending again does not bring back what was cut: the span ends where the trim left it.
        TrimClipTail back(fx.seq, fx.v, f30(90));
        applyReversible(fx.project, back);
        const EffectSpan *motion = fx.clip(fx.v).findSpan(fx.motion);
        REQUIRE(motion != nullptr);
        CHECK(motion->end == f30(100)); // source frame 30 + 70
        CHECK(motionValuesAt(fx.clip(fx.v), f30(80)).x == 12);
    }
}

TEST_CASE("Span pictures: a speed change moves the spans with their source frames") {
    Moving fx;
    SetClipSpeed faster(fx.seq, fx.v, Ratio{3, 2});
    applyReversible(fx.project, faster);
    CHECK(fx.clip(fx.v).timelineDuration == f30(60));
    CHECK(fx.checkPictures() == 60);
    SetClipSpeed slower(fx.seq, fx.v, Ratio{1, 2});
    applyReversible(fx.project, slower);
    CHECK(fx.clip(fx.v).timelineDuration == f30(180));
    CHECK(fx.checkPictures() == 180);
}

TEST_CASE("Span pictures: at 29.97 fps with an in point off the grid, span edges fall on frames") {
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
    AddSpan add(fx.seq, clip.id, SpanKind::Motion, 1, CMTimeMake(1001 * 7, 30000), CMTimeMake(1001 * 60, 30000));
    applyReversible(fx.project, add);
    const SpanId id = add.createdSpanId();
    SetSpanValues values(fx.seq, id, {SpanValueChange{SpanParameter::X, 0.0, 530.0}});
    applyReversible(fx.project, values);
    const Clip &c = fx.clip(clip.id);
    // Frames 7..59 are in the span, 6 and 60 are not; frame 7 shows the start value exactly.
    CHECK(motionValuesAt(c, CMTimeMake(1001 * 6, 30000)).x == 0);
    CHECK(motionValuesAt(c, CMTimeMake(1001 * 7, 30000)).x == 0);
    CHECK(motionValuesAt(c, CMTimeMake(1001 * 8, 30000)).x > 0);
    CHECK(motionValuesAt(c, CMTimeMake(1001 * 59, 30000)).x > 500);
    CHECK(motionValuesAt(c, CMTimeMake(1001 * 60, 30000)).x == 0);
    // A split between keeps every frame (at frame 40, whose exact source time has a CMTime form, as
    // a split needs for the right piece's in point).
    std::vector<double> before;
    for (int f = 0; f < 100; ++f) {
        before.push_back(motionValuesAt(c, CMTimeMake(1001 * f, 30000)).x);
    }
    SplitClip split(fx.seq, clip.id, CMTimeMake(1001 * 40, 30000));
    applyReversible(fx.project, split);
    const Clip &left = fx.clip(clip.id);
    const Clip &right = fx.clip(split.createdClipIds()[0]);
    for (int f = 0; f < 100; ++f) {
        const Clip &piece = f < 40 ? left : right;
        CHECK(close(motionValuesAt(piece, CMTimeMake(1001 * f, 30000)).x, before[static_cast<std::size_t>(f)]));
    }
}

TEST_CASE("Span pictures: a still's spans keep their timeline places through a head trim and a move") {
    Fixture fx;
    const ClipId still = fx.addClip(fx.v1, fx.still, 30, 90);
    SpanTracks grow;
    grow.scale = rampTrack(0.5, 1, f30(40));
    const SpanId id = fx.addSpan(still, SpanKind::Motion, 1, f30(20), f30(60), grow);
    fx.requireValid();
    auto reference = [](std::int64_t timelineFrame, std::int64_t clipStart) {
        // The span covers timeline frames [clipStart + 20, clipStart + 60).
        const double into = static_cast<double>(timelineFrame - clipStart);
        return referenceSpanValue(20, 60, 0.5, 1, KI::Linear, into).value_or(1);
    };
    for (std::int64_t f = 30; f < 120; ++f) {
        CHECK(close(motionValuesAt(fx.clip(still), f30(f)).scale, reference(f, 30)));
    }
    TrimClipHead trim(fx.seq, still, f30(60)); // cuts the span's first 10 frames
    applyReversible(fx.project, trim);
    CHECK(fx.clip(still).findSpan(id)->start == f30(0));
    for (std::int64_t f = 60; f < 120; ++f) {
        CHECK(close(motionValuesAt(fx.clip(still), f30(f)).scale, reference(f, 30)));
    }
    MoveClip move(fx.seq, still, fx.v1, f30(100));
    applyReversible(fx.project, move);
    for (std::int64_t f = 100; f < 160; ++f) {
        CHECK(close(motionValuesAt(fx.clip(still), f30(f)).scale, reference(f, 70)));
    }
}
