// The Scheduler's layers of generated clips (titles design, section 3; slice 1, item 6): a title's or matte's layer
// carries its content (the clip's own object, not a copy), the anchor of its picture (a title's position on the
// sequence's frame; the frame's corner for a matte), the largest Motion scale its clip reaches and whether its
// Motion changes; a clip of media carries none of them. Over the tracks below, under a dissolve and in the solo preview alike.

#include "../../Engine/Render/Scheduler.h"
#include "../Model/ModelFixtures.h"

using namespace vetest;

namespace {

struct Titles : Fixture {
    AssetId titles = project.addAsset(makeGeneratorAsset(GeneratorKind::Title));
    AssetId mattes = project.addAsset(makeGeneratorAsset(GeneratorKind::ColourMatte));

    ClipId addGenerated(TrackId track, AssetId asset, std::shared_ptr<const GeneratedContent> content,
                        std::int64_t start, std::int64_t frames) {
        const ClipId id = addClip(track, asset, start, frames);
        sequence().findClip(id)->generated = std::move(content);
        return id;
    }
};

const VideoLayer *layerOf(const RenderGraph &graph, ClipId clip) {
    for (const VideoLayer &layer : graph.layers) {
        if (layer.clipId == clip) {
            return &layer;
        }
    }
    return nullptr;
}

} // namespace

TEST_CASE("Scheduler: a generated clip's layer carries its content, anchor and largest Motion scale") {
    Titles fx;
    const ClipId video = fx.addClip(fx.v1, fx.av30, 0, 90);
    TitleContent content;
    content.x = 0.25;
    content.y = 0.75;
    const auto title = GeneratedContent::makeTitle(content);
    const ClipId titleClip = fx.addGenerated(fx.v2, fx.titles, title, 0, 90);
    SpanTracks zoom;
    zoom.track(SpanParameter::Scale) = {key(kCMTimeZero, 1.0), key(f30(30), 1.5)};
    fx.addSpan(titleClip, SpanKind::Motion, 1, f30(30), f30(60), zoom);
    fx.requireValid();

    const RenderGraph graph = Scheduler::renderGraphAt(fx.sequence(), fx.project, f30(10));
    REQUIRE(graph.layers.size() == 2);
    const VideoLayer *over = layerOf(graph, titleClip);
    REQUIRE(over != nullptr);
    CHECK(graph.layers.back().clipId == titleClip); // over the video below
    CHECK(over->generated == title);                 // the clip's own content, shared
    CHECK(over->canvasAnchorX == 0.25 * 1920);
    CHECK(over->canvasAnchorY == 0.75 * 1080);
    CHECK(over->maxMotionScale == 1.5); // reached later in the clip, already now
    CHECK(over->motionAnimated);        // it has a Motion span
    CHECK(over->transform.scale == 1.0);
    CHECK(over->isStill);
    CHECK(CMTimeCompare(over->sourceTime, kCMTimeZero) == 0);
    const VideoLayer *below = layerOf(graph, video);
    REQUIRE(below != nullptr);
    CHECK_FALSE(below->generated);
    CHECK(below->maxMotionScale == 1.0);

    // A matte's anchor is the frame's corner.
    const ClipId matte = fx.addGenerated(fx.v1, fx.mattes, GeneratedContent::makeMatte(kWhite), 100, 30);
    const RenderGraph matteGraph = Scheduler::renderGraphAt(fx.sequence(), fx.project, f30(110));
    const VideoLayer *matteLayer = layerOf(matteGraph, matte);
    REQUIRE(matteLayer != nullptr);
    CHECK(matteLayer->generated->isMatte());
    CHECK(matteLayer->canvasAnchorX == 0.0);
    CHECK(matteLayer->canvasAnchorY == 0.0);
    CHECK_FALSE(matteLayer->motionAnimated);

    // The solo preview's layer too.
    const RenderGraph solo = Scheduler::soloGraphAt(fx.sequence(), fx.project, titleClip, f30(10), true);
    REQUIRE(solo.layers.size() == 1);
    CHECK(solo.layers[0].generated == title);
    CHECK(solo.layers[0].canvasAnchorX == 0.25 * 1920);
    CHECK(solo.layers[0].maxMotionScale == 1.5);
}

TEST_CASE("Scheduler: a dissolve between two titles gives both layers their own content and anchor") {
    Titles fx;
    TitleContent first;
    first.text = "First";
    first.x = 0.3;
    TitleContent second;
    second.text = "Second";
    second.x = 0.7;
    const ClipId a = fx.addGenerated(fx.v2, fx.titles, GeneratedContent::makeTitle(first), 0, 60);
    const ClipId b = fx.addGenerated(fx.v2, fx.titles, GeneratedContent::makeTitle(second), 60, 60);
    fx.addTransition(fx.v2, a, b, 10);
    fx.requireValid();
    const RenderGraph graph = Scheduler::renderGraphAt(fx.sequence(), fx.project, f30(58));
    REQUIRE(graph.layers.size() == 2);
    REQUIRE(graph.layers[0].transition.has_value());
    CHECK(graph.layers[0].generated->title().text == "First");
    CHECK(graph.layers[1].generated->title().text == "Second");
    CHECK(graph.layers[0].canvasAnchorX == 0.3 * 1920);
    CHECK(graph.layers[1].canvasAnchorX == 0.7 * 1920);
}
