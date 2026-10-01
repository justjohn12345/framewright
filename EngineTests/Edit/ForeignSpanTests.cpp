// What a newer version of Framewright wrote into spans (EffectSpan.h, ForeignSpanContent; review core
// #9) under this version's edits: a span of an unknown kind is never edited, stays while its clip's
// edits leave it whole and goes (reported as dropped) when they would cut it; a known span's unknown
// parameter tracks go when its length changes; unknown keys stay.

#include "EditTestSupport.h"

#include "../../Engine/Serialize/ProjectJSON.h"

using namespace vetest;
using nlohmann::json;

namespace {

// V1: a 90-frame clip from source frame 30 (timeline frame f shows source frame 30 + f), with a
// "colour" span of a newer version on lane 2 over source frames 50-70 (timeline 20-40) and a Motion
// span on lane 1 over source frames 40-80 (timeline 10-50) carrying an unknown "blur" track and an
// unknown key.
struct ForeignFixture : Fixture {
    ClipId v;
    SpanId colour, motion;
    ForeignFixture() {
        v = addClip(v1, av30, 0, 90, 30);
        colour = addSpan(v, SpanKind::Unknown, 2, f30(50), f30(70));
        EffectSpan &c = *sequence().findSpan(colour);
        c.foreign.kindName = "colour";
        c.foreign.fields = R"({"tracks":{"exposure":[{"time":{"timescale":30,"value":0},"value":0.5}]}})";
        SpanTracks move;
        move.x = {key(kCMTimeZero, 0), key(f30(40), 100)};
        motion = addSpan(v, SpanKind::Motion, 1, f30(40), f30(80), move);
        EffectSpan &m = *sequence().findSpan(motion);
        m.foreign.fields = R"({"label":"push in"})";
        m.foreign.tracks = R"({"blur":[{"time":{"timescale":30,"value":40},"value":2.0}]})";
        m.foreign.tracksLength = f30(40);
        requireValid();
    }

    const Clip &clip() const {
        return *sequence().findClip(v);
    }
};

const EffectSpan *unknownSpanOf(const Clip &clip) {
    for (const EffectSpan &span : clip.spans) {
        if (span.isUnknownKind()) {
            return &span;
        }
    }
    return nullptr;
}

bool contains(const std::vector<SpanId> &ids, SpanId id) {
    return std::find(ids.begin(), ids.end(), id) != ids.end();
}

} // namespace

TEST_CASE("Foreign spans: no span edit changes a span of an unknown kind") {
    ForeignFixture fx;
    const auto newer = [](const EditResult &r) {
        CHECK(r.message.find("\"colour\" span from a newer version of Framewright") != std::string::npos);
    };
    SetSpanRange range(fx.seq, fx.colour, f30(20), f30(30));
    newer(applyRefused(fx.project, range, EditError::InvalidArgument));
    SetSpanValues values(fx.seq, fx.colour, {SpanValueChange{SpanParameter::Opacity, 0.5, 0.5}});
    newer(applyRefused(fx.project, values, EditError::InvalidArgument));
    SetSpanInterpolation easing(fx.seq, fx.colour, KeyframeInterpolation::EaseIn);
    newer(applyRefused(fx.project, easing, EditError::InvalidArgument));
    MoveSpanLane lane(fx.seq, fx.colour, 3);
    newer(applyRefused(fx.project, lane, EditError::InvalidArgument));
    RemoveSpans remove(fx.seq, {fx.colour});
    newer(applyRefused(fx.project, remove, EditError::InvalidArgument));
    std::vector<SpanValueChange> changes;
    CHECK(planMatchSpanEdge(fx.sequence(), fx.colour, ClipEdge::Head, changes).error == EditError::InvalidArgument);
    CHECK(changes.empty());
    AddSpan unknown(fx.seq, fx.v, SpanKind::Unknown, 3, f30(0), f30(10));
    applyRefused(fx.project, unknown, EditError::InvalidArgument);

    // It holds its lane: a span added over it is refused, saying what is there.
    AddSpan over(fx.seq, fx.v, SpanKind::Opacity, 2, f30(25), f30(35));
    const EditResult refusal = applyRefused(fx.project, over, EditError::Overlap);
    CHECK(refusal.message.find("(a span from a newer version of Framewright)") != std::string::npos);
    REQUIRE(refusal.freeRange.has_value());
    // Beside it the lane is free.
    AddSpan beside(fx.seq, fx.v, SpanKind::Opacity, 2, f30(40), f30(60));
    applyReversible(fx.project, beside);
}

TEST_CASE("Foreign spans: clip edits keep a span of an unknown kind whole or drop it") {
    ForeignFixture fx;
    const EffectSpan original = *fx.span(fx.colour);
    SUBCASE("a trim that leaves it inside the clip keeps it unchanged") {
        TrimClipTail tail(fx.seq, fx.v, f30(45));
        applyReversible(fx.project, tail);
        TrimClipHead head(fx.seq, fx.v, f30(15));
        const EditResult r = applyReversible(fx.project, head);
        CHECK_FALSE(contains(r.droppedSpanIds, fx.colour));
        REQUIRE(fx.span(fx.colour) != nullptr);
        CHECK(*fx.span(fx.colour) == original);
    }
    SUBCASE("a trim that would cut it drops it, reported") {
        TrimClipTail tail(fx.seq, fx.v, f30(30));
        const EditResult r = applyReversible(fx.project, tail);
        CHECK(contains(r.droppedSpanIds, fx.colour));
        CHECK(unknownSpanOf(fx.clip()) == nullptr);
    }
    SUBCASE("a head trim past its start drops it") {
        TrimClipHead head(fx.seq, fx.v, f30(25));
        const EditResult r = applyReversible(fx.project, head);
        CHECK(contains(r.droppedSpanIds, fx.colour));
        CHECK(unknownSpanOf(fx.clip()) == nullptr);
    }
    SUBCASE("a split through it drops it from both parts") {
        SplitClip split(fx.seq, fx.v, f30(30));
        applyReversible(fx.project, split);
        for (const Clip &part : fx.sequence().findTrack(fx.v1)->clips) {
            CHECK(unknownSpanOf(part) == nullptr);
        }
    }
    SUBCASE("a split beside it leaves it on its part, content and range unchanged") {
        SplitClip split(fx.seq, fx.v, f30(5));
        applyReversible(fx.project, split);
        const std::vector<Clip> &parts = fx.sequence().findTrack(fx.v1)->clips;
        REQUIRE(parts.size() == 2);
        CHECK(unknownSpanOf(parts[0]) == nullptr);
        const EffectSpan *kept = unknownSpanOf(parts[1]);
        REQUIRE(kept != nullptr);
        CHECK(kept->foreign == original.foreign);
        CHECK(identical(kept->start, original.start));
        CHECK(identical(kept->end, original.end));
        CHECK(kept->lane == original.lane);
    }
}

TEST_CASE("Foreign spans: a known span's unknown tracks go when its length changes; its unknown keys stay") {
    ForeignFixture fx;
    const ForeignSpanContent original = fx.span(fx.motion)->foreign;
    SUBCASE("moved without a change of length: kept and saved") {
        SetSpanRange move(fx.seq, fx.motion, f30(12), f30(52));
        applyReversible(fx.project, move);
        CHECK(fx.span(fx.motion)->foreign == original);
        const json saved = projectToJson(fx.project)["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][0];
        REQUIRE(saved["kind"] == "motion");
        CHECK(saved["tracks"].contains("blur"));
        CHECK(saved["label"] == "push in");
    }
    SUBCASE("trimmed: the tracks go (they cannot stretch with the known ones), the keys stay") {
        SetSpanRange trim(fx.seq, fx.motion, f30(10), f30(40));
        applyReversible(fx.project, trim);
        const ForeignSpanContent &now = fx.span(fx.motion)->foreign;
        CHECK(now.tracks.empty());
        CHECK_FALSE(CMTIME_IS_NUMERIC(now.tracksLength));
        CHECK(now.fields == original.fields);
        const json saved = projectToJson(fx.project)["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][0];
        CHECK_FALSE(saved["tracks"].contains("blur"));
        CHECK(saved["label"] == "push in");
    }
    SUBCASE("cut: neither part keeps the tracks") {
        const auto parts = splitSpan(*fx.span(fx.motion), f30(60));
        REQUIRE(parts.has_value());
        CHECK(parts->left.foreign.tracks.empty());
        CHECK(parts->right.foreign.tracks.empty());
        CHECK(parts->left.foreign.fields == original.fields);
        CHECK(parts->right.foreign.fields == original.fields);
    }
    SUBCASE("a length changed by any other route: the writer leaves the tracks out") {
        EffectSpan &span = *fx.sequence().findSpan(fx.motion);
        span.end = f30(70);
        span.tracks.x.back().time = f30(30);
        const json saved = projectToJson(fx.project)["sequences"][0]["videoTracks"][0]["clips"][0]["spans"][0];
        CHECK_FALSE(saved["tracks"].contains("blur"));
    }
}
