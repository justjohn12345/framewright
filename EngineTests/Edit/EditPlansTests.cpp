// EditPlans.h: what the facade's clip edits work out before building their commands (moved out of
// VEEngine.mm; the facade tests cover the edits end to end through VEEngine).

#include "../../Engine/Edit/EditPlans.h"

#include "EditTestSupport.h"

using namespace vetest;

TEST_CASE("placementsForAsset places the video and the sound on their tracks with the chosen range") {
    Fixture fx;
    const MediaAsset &av30 = *fx.project.findAsset(fx.av30);
    auto placements = placementsForAsset(av30, fx.v1, fx.a1, f30(30), f30(90));
    REQUIRE(placements.size() == 2);
    CHECK(placements[0].trackId == fx.v1);
    CHECK(placements[1].trackId == fx.a1);
    for (const ClipPlacement &p : placements) {
        CHECK(p.assetId == fx.av30);
        CHECK(p.sourceIn == f30(30));
        CHECK(p.sourceOut == f30(90));
    }
    // Invalid ends keep placementForAsset's whole media.
    placements = placementsForAsset(av30, fx.v1, TrackId{}, kCMTimeInvalid, kCMTimeInvalid);
    REQUIRE(placements.size() == 1);
    const ClipPlacement whole = placementForAsset(av30, fx.v1);
    CHECK(placements[0].trackId == fx.v1);
    CHECK(placements[0].sourceIn == whole.sourceIn);
    CHECK(placements[0].sourceOut == whole.sourceOut);
    placements = placementsForAsset(av30, TrackId{}, fx.a1, kCMTimeInvalid, f30(45));
    REQUIRE(placements.size() == 1);
    CHECK(placements[0].trackId == fx.a1);
    CHECK(placements[0].sourceIn == whole.sourceIn);
    CHECK(placements[0].sourceOut == f30(45));
    // A part the asset does not have is skipped.
    placements = placementsForAsset(*fx.project.findAsset(fx.audioOnly), fx.v1, fx.a1, kCMTimeInvalid, kCMTimeInvalid);
    REQUIRE(placements.size() == 1);
    CHECK(placements[0].trackId == fx.a1);
    CHECK(placementsForAsset(av30, TrackId{}, TrackId{}, kCMTimeInvalid, kCMTimeInvalid).empty());
}

TEST_CASE("placementsForAsset gives a still the length of the chosen range") {
    Fixture fx;
    const MediaAsset &still = *fx.project.findAsset(fx.still);
    auto placements = placementsForAsset(still, fx.v1, fx.a1, f30(30), f30(120));
    REQUIRE(placements.size() == 1); // a still has no sound
    CHECK(placements[0].sourceIn == kCMTimeZero);
    CHECK(placements[0].sourceOut == f30(90));
    const ClipPlacement standard = placementForAsset(still, fx.v1);
    for (const auto &[in, out] : {std::pair{f30(30), f30(30)}, std::pair{f30(30), f30(10)},
                                  std::pair{kCMTimeInvalid, f30(10)}, std::pair{f30(0), kCMTimeInvalid}}) {
        placements = placementsForAsset(still, fx.v1, TrackId{}, in, out);
        REQUIRE(placements.size() == 1);
        CHECK(placements[0].sourceIn == standard.sourceIn);
        CHECK(placements[0].sourceOut == standard.sourceOut);
    }
}

TEST_CASE("splitTargets: clips the time falls strictly inside, one per linked pair") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 60);
    const ClipId other = fx.addClip(fx.v2, fx.av30, 20, 60);
    CHECK(splitTargets(fx.sequence(), {v, a, other}, f30(30), false) == std::vector<ClipId>{v, other});
    CHECK(splitTargets(fx.sequence(), {a, v, a}, f30(30), false) == std::vector<ClipId>{a});
    CHECK(splitTargets(fx.sequence(), {v, other}, f30(0), false) == std::vector<ClipId>{});  // v's start
    CHECK(splitTargets(fx.sequence(), {v, other}, f30(60), false) == std::vector<ClipId>{other}); // v's end
    CHECK(splitTargets(fx.sequence(), {ClipId(9999), other}, f30(30), false) == std::vector<ClipId>{other});
    lockTrack(fx, fx.v2);
    CHECK(splitTargets(fx.sequence(), {v, other}, f30(30), true) == std::vector<ClipId>{v});
    CHECK(splitTargets(fx.sequence(), {v, other}, f30(30), false) == std::vector<ClipId>{v, other});
}

TEST_CASE("linkedEditTargets lists each clip once, without partners of clips listed before") {
    Fixture fx;
    const auto [v, a] = fx.addLinkedPair(0, 60);
    const ClipId other = fx.addClip(fx.v2, fx.av30, 0, 60);
    const ClipId still = fx.addClip(fx.v2, fx.still, 100, 30);
    std::vector<ClipId> targets;
    REQUIRE(linkedEditTargets(fx.sequence(), {v, other, a, v}, "no stills", targets).ok());
    CHECK(targets == std::vector<ClipId>{v, other});
    REQUIRE(linkedEditTargets(fx.sequence(), {a, v}, "no stills", targets).ok());
    CHECK(targets == std::vector<ClipId>{a});
    REQUIRE(linkedEditTargets(fx.sequence(), {}, "no stills", targets).ok());
    CHECK(targets.empty());

    EditResult refused = linkedEditTargets(fx.sequence(), {v, still}, "A still has no speed.", targets);
    CHECK(refused.error == EditError::InvalidArgument);
    CHECK(refused.message == "A still has no speed.");
    // A missing clip is refused even after its partner was listed.
    refused = linkedEditTargets(fx.sequence(), {v, ClipId(9999)}, "no stills", targets);
    CHECK(refused.error == EditError::ClipNotFound);
    CHECK(refused.message == "A selected clip no longer exists.");
}

TEST_CASE("planMatchMotion matches a clip's static Motion to its neighbour at the cut") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60);
    Clip &second = *fx.sequence().findClip(b);
    second.video.x = 100;
    second.video.scale = 2;
    second.video.opacity = 0.5;

    std::optional<VideoParams> values;
    REQUIRE(planMatchMotion(fx.sequence(), a, ClipEdge::Tail, values).ok());
    REQUIRE(values);
    CHECK(values->x == 100);
    CHECK(values->scale == 2);
    CHECK(values->opacity == 0.5);
    CHECK(values->y == 0);

    REQUIRE(planMatchMotion(fx.sequence(), b, ClipEdge::Head, values).ok());
    REQUIRE(values);
    CHECK(values->x == 0);
    CHECK(values->scale == 1);
    CHECK(values->opacity == 1);

    // Already matching: nothing to change.
    fx.sequence().findClip(a)->video = second.video;
    REQUIRE(planMatchMotion(fx.sequence(), a, ClipEdge::Tail, values).ok());
    CHECK_FALSE(values);
}

TEST_CASE("planMatchMotion takes the clip's spans into account") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60);
    fx.addClip(fx.v1, fx.av30, 60, 60);
    SpanTracks zoom;
    zoom.scale = {key(kCMTimeZero, 2), key(f30(60), 2)}; // A is shown at twice its static scale
    fx.addSpan(a, SpanKind::Motion, 1, kCMTimeZero, f30(60), zoom);
    std::optional<VideoParams> values;
    REQUIRE(planMatchMotion(fx.sequence(), a, ClipEdge::Tail, values).ok());
    REQUIRE(values);
    CHECK(values->scale == doctest::Approx(0.5)); // x 2 by the span = the neighbour's 1

    SpanTracks hide;
    hide.opacity = {key(kCMTimeZero, 0), key(f30(60), 0)};
    fx.addSpan(a, SpanKind::Opacity, 2, kCMTimeZero, f30(60), hide);
    const EditResult refused = planMatchMotion(fx.sequence(), a, ClipEdge::Tail, values);
    CHECK(refused.error == EditError::InvalidArgument);
    CHECK(refused.message == "The clip's spans make its scale or opacity 0 there, so no static value can match.");
}

TEST_CASE("planMatchMotion refuses what it cannot match") {
    Fixture fx;
    const ClipId a = fx.addClip(fx.v1, fx.av30, 0, 60);
    const ClipId b = fx.addClip(fx.v1, fx.av30, 60, 60);
    const ClipId sound = fx.addClip(fx.a1, fx.audioOnly, 0, 60);
    const ClipId apart = fx.addClip(fx.v2, fx.av30, 200, 30);
    std::optional<VideoParams> values;
    EditResult r = planMatchMotion(fx.sequence(), ClipId(9999), ClipEdge::Head, values);
    CHECK(r.error == EditError::ClipNotFound);
    CHECK(r.message == "The clip no longer exists.");
    r = planMatchMotion(fx.sequence(), sound, ClipEdge::Head, values);
    CHECK(r.error == EditError::TrackKindMismatch);
    CHECK(r.message == "Audio clips have no Motion.");
    r = planMatchMotion(fx.sequence(), a, ClipEdge::Head, values);
    CHECK(r.error == EditError::NotAdjacent);
    CHECK(r.message == "No clip ends where this clip starts on its track.");
    r = planMatchMotion(fx.sequence(), apart, ClipEdge::Tail, values);
    CHECK(r.error == EditError::NotAdjacent);
    CHECK(r.message == "No clip starts where this clip ends on its track.");

    // A neighbour more opaque than the clip's spans let it be.
    SpanTracks dim;
    dim.opacity = {key(kCMTimeZero, 0.5), key(f30(60), 0.5)};
    fx.addSpan(b, SpanKind::Opacity, 1, kCMTimeZero, f30(60), dim);
    r = planMatchMotion(fx.sequence(), b, ClipEdge::Head, values);
    CHECK(r.error == EditError::InvalidArgument);
    CHECK(r.message == "The clip's spans lower its opacity there, so no static opacity can reach the neighbour's.");
    CHECK_FALSE(values);
}
