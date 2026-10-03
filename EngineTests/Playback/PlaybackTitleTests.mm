// Titles in the program monitor (titles design, sections 3 and 12; slice 1, item 7): the playback controller asks the
// decode pool for a title's picture at the raster scale its clip and the monitors need, and the frame source looks it
// up by the same key. Typing (a new content) renders a new picture while the previous one stays on screen; moving the
// box renders nothing; a larger view renders titles larger; a zoom renders the picture at the scale it reaches; and
// real-time playback with a title over video is not disturbed.

#import <XCTest/XCTest.h>

#include "../../Engine/Media/TitleRenderer.h"
#include "../../Engine/Render/Compositor.h"
#include "PlaybackTestSupport.h"

#include <chrono>
#include <thread>

using namespace ve;
using namespace ve::test;
using ve::playback::PlaybackState;
using SteadyClock = std::chrono::steady_clock;

namespace {

/// Adds the Title generator asset to `h`'s project (once) and a title clip of `content` on `track` over 30 fps
/// frames [start, start + frames).
ClipId addTitle(PlaybackHarness &h, TrackId track, const TitleContent &content, int64_t start, int64_t frames) {
    AssetId titles;
    for (const MediaAsset &asset : h.project.assets) {
        if (asset.generator == GeneratorKind::Title) {
            titles = asset.id;
        }
    }
    if (!titles) {
        titles = h.project.addAsset(makeGeneratorAsset(GeneratorKind::Title));
    }
    const ClipId id = h.addClip(track, titles, start, frames, kCMTimeZero);
    Clip &clip = *h.sequence().findClip(id);
    clip.isStill = true;
    clip.generated = GeneratedContent::makeTitle(content);
    return id;
}

void setTitle(PlaybackHarness &h, ClipId clip, const TitleContent &content) {
    h.sequence().findClip(clip)->generated = GeneratedContent::makeTitle(content);
}

TitleContent sampleTitle(const char *text) {
    TitleContent content;
    content.text = text;
    content.size = 0.1;
    content.y = 0.7;
    return content;
}

/// The cache key the controller uses for `clip`'s title at raster scale `k` on the harness's sequence.
media::FrameKey titleKey(PlaybackHarness &h, ClipId clip, double k) {
    const Clip &c = *h.sequence().findClip(clip);
    return media::FrameKey{c.assetId, h.pool->decodeFormat(),
                           media::generatedKeyFor(*c.generated, h.sequence().width, h.sequence().height, k,
                                                  media::titleFontGeneration())};
}

const playback::PresentedLayer *presentedLayer(const PlaybackHarness::Sample &sample, ClipId clip) {
    for (const playback::PresentedLayer &layer : sample.presented.layers) {
        if (layer.clip == clip) {
            return &layer;
        }
    }
    return nullptr;
}

} // namespace

@interface PlaybackTitleTests : XCTestCase
@end

@implementation PlaybackTitleTests

- (void)testATitleOverVideoIsPresentedWithItsPicture {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    const AssetId movie = h.importAsset("h264_1080p30.mp4");
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    h.addClip(h.v1, movie, 0, 60, kCMTimeZero);
    const ClipId title = addTitle(h, h.v2, sampleTitle("Over Video"), 10, 40);
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();
    h.controller->seek(frames30(20));
    const PlaybackHarness::Sample sample = h.presentExact();
    XCTAssertEqual(sample.presented.layers.size(), 2u);
    const playback::PresentedLayer *shown = presentedLayer(sample, title);
    XCTAssertTrue(shown != nullptr && shown->exact, @"the title has its picture");
    XCTAssertEqual(h.frame().graph.layers.back().clipId, title, @"over the video");
    const render::TextureSet &texture = h.frame().textures.back();
    XCTAssertTrue(texture.canvas().has_value(), @"the picture carries its canvas geometry");
    XCTAssertTrue(h.cache->contains(titleKey(h, title, 1.0), kCMTimeZero), @"rendered at the sequence's resolution");
    XCTAssertFalse(h.cache->contains(media::FrameKey{h.sequence().findClip(title)->assetId, h.pool->decodeFormat()},
                                     kCMTimeZero),
                   @"never under the generator asset's own key");
    // Composited, the title shows over the picture below (the frame differs from the video alone).
    auto created = render::Compositor::create(h.device(), {MTLPixelFormatBGRA8Unorm});
    XCTAssertTrue(created.ok());
    if (!created.ok()) {
        return;
    }
    auto drawn = [&](bool withTitle) {
        RenderGraph graph = h.frame().graph;
        std::vector<render::TextureSet> textures = h.frame().textures;
        if (!withTitle) {
            graph.layers.pop_back();
            textures.pop_back();
        }
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                        width:480
                                                                                       height:270
                                                                                    mipmapped:NO];
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
        id<MTLTexture> target = [h.device() newTextureWithDescriptor:desc];
        auto lookup = [&](const VideoLayer &, std::size_t index, render::TextureSet &out) {
            out = textures[index];
            return static_cast<bool>(out);
        };
        auto result = created.value()->renderAndWait(graph, lookup, render::TextureTarget{target, {}, nil});
        XCTAssertTrue(result.ok() && result->skippedLayers.empty());
        std::vector<uint8_t> bytes(480 * 270 * 4);
        [target getBytes:bytes.data() bytesPerRow:480 * 4 fromRegion:MTLRegionMake2D(0, 0, 480, 270) mipmapLevel:0];
        return bytes;
    };
    const std::vector<uint8_t> with = drawn(true), without = drawn(false);
    size_t changed = 0;
    for (size_t i = 0; i < with.size(); i += 4) {
        changed += std::abs(int(with[i + 1]) - int(without[i + 1])) > 40 ? 1 : 0;
    }
    XCTAssertGreaterThan(changed, size_t(500), @"the title's pixels are drawn over the video");
}

- (void)testTypingRendersANewPictureAndMovingTheBoxDoesNot {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    const AssetId movie = h.importAsset("h264_1080p30.mp4");
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    h.addClip(h.v1, movie, 0, 60, kCMTimeZero);
    TitleContent content = sampleTitle("Typ");
    const ClipId title = addTitle(h, h.v2, content, 0, 60);
    h.load();
    h.controller->seek(frames30(15));
    h.presentExact();
    XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)));
    std::this_thread::sleep_for(std::chrono::milliseconds(300)); // the stopped lookahead settles
    XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)));

    // Typing: each keystroke is new content, a new picture. Until it lands the monitor keeps the previous complete
    // picture (a present either changes nothing or shows the title with its picture), never a frame without it.
    double worstMs = 0;
    // The pictures rendered for the title: by the pool's title stream and by the paused display's scrub requests.
    const AssetId titleAsset = h.sequence().findClip(title)->assetId;
    auto renders = [&]() {
        const media::DecodePool::Stats stats = h.pool->stats();
        uint64_t count = stats.scrubServiced;
        for (const auto &stream : stats.streams) {
            count += stream.asset == titleAsset ? stream.framesDecoded : 0;
        }
        return count;
    };
    for (const char *typed : {"Typi", "Typin", "Typing"}) {
        content.text = typed;
        setTitle(h, title, content);
        const uint64_t insertionsBefore = h.cache->stats().insertions;
        const uint64_t rendersBefore = renders();
        const auto keystroke = SteadyClock::now();
        h.publishEdit();
        bool landed = false;
        while (SteadyClock::now() - keystroke < std::chrono::seconds(5)) {
            const PlaybackHarness::Sample s = h.present();
            if (s.changed) {
                const playback::PresentedLayer *shown = presentedLayer(s, title);
                XCTAssertTrue(shown != nullptr && shown->exact, @"\"%s\": a frame without the title's picture", typed);
                if (h.cache->contains(titleKey(h, title, 1.0), kCMTimeZero)) {
                    landed = true;
                    break;
                }
            }
            std::this_thread::sleep_for(std::chrono::microseconds(500));
        }
        const double ms = std::chrono::duration<double, std::milli>(SteadyClock::now() - keystroke).count();
        worstMs = std::max(worstMs, ms);
        XCTAssertTrue(landed, @"\"%s\" was presented", typed);
        // Once: the paused display's render is the decode pool's too (review fix round, finding 11).
        XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)));
        XCTAssertEqual(h.cache->stats().insertions, insertionsBefore + 1, @"\"%s\" rendered once", typed);
        XCTAssertEqual(renders(), rendersBefore + 1, @"\"%s\": one render, not one for the display and one for the "
                                                     @"pool's stream", typed);
        NSLog(@"TITLE keystroke to picture (paused, \"%s\"): %.1f ms", typed, ms);
    }
    NSLog(@"TITLE keystroke to picture, worst of 3: %.1f ms", worstMs);

    // Moving the box: the same picture at another place, nothing rendered.
    XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)));
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)));
    const media::FrameKey before = titleKey(h, title, 1.0);
    const uint64_t insertionsBefore = h.cache->stats().insertions;
    content.x = 0.3;
    content.y = 0.2;
    setTitle(h, title, content);
    h.publishEdit();
    const PlaybackHarness::Sample moved = h.presentExact();
    XCTAssertTrue(presentedLayer(moved, title) != nullptr && presentedLayer(moved, title)->exact);
    XCTAssertTrue(titleKey(h, title, 1.0) == before, @"the position is not part of the picture");
    XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertEqual(h.cache->stats().insertions, insertionsBefore, @"a drag renders nothing");
    XCTAssertEqualWithAccuracy(h.frame().graph.layers.back().canvasAnchorX, 0.3 * h.sequence().width, 1e-9);

    // A burst of keystrokes renders the last text (the scrub path keeps the newest request per lane).
    for (int i = 0; i < 10; ++i) {
        content.text = "Burst " + std::to_string(i);
        setTitle(h, title, content);
        h.publishEdit();
    }
    const PlaybackHarness::Sample last = h.presentExact();
    XCTAssertTrue(presentedLayer(last, title) != nullptr && presentedLayer(last, title)->exact);
    XCTAssertEqual(h.frame().graph.layers.back().generated->title().text, "Burst 9");
    XCTAssertTrue(h.cache->contains(titleKey(h, title, 1.0), kCMTimeZero));
}

- (void)testALargerViewRendersTitlesLarger {
    XCTAssertEqual(playback::monitorOutputScale(0.4), 1.0);
    XCTAssertEqual(playback::monitorOutputScale(1.0), 1.0);
    XCTAssertEqual(playback::monitorOutputScale(1.2), 1.0, @"a slightly larger view keeps the sequence's picture");
    XCTAssertEqual(playback::monitorOutputScale(1.3), 2.0);
    XCTAssertEqual(playback::monitorOutputScale(2.0), 2.0);
    XCTAssertEqual(playback::monitorOutputScale(3.1), 4.0);
    XCTAssertEqual(playback::monitorOutputScale(12.0), 4.0);
    XCTAssertEqual(playback::monitorOutputScale(std::nan("")), 1.0);

    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    const ClipId title = addTitle(h, h.v1, sampleTitle("Large View"), 0, 30);
    h.load();
    h.controller->seek(frames30(5));
    h.presentExact();
    const size_t smallWidth = h.frame().textures.front().width();
    h.controller->setGeneratedOutputScale(2.0);
    XCTAssertEqual(h.controller->generatedOutputScale(), 2.0);
    const PlaybackHarness::Sample large = h.presentExact();
    XCTAssertTrue(presentedLayer(large, title) != nullptr && presentedLayer(large, title)->exact);
    XCTAssertTrue(h.cache->contains(titleKey(h, title, 2.0), kCMTimeZero));
    XCTAssertEqual(h.frame().textures.front().width(), smallWidth * 2);
    h.controller->setGeneratedOutputScale(0.25);
    XCTAssertEqual(h.controller->generatedOutputScale(), 1.0, @"never below the sequence's resolution");
}

- (void)testAZoomedTitleIsRenderedAtTheScaleItReaches {
    PlaybackHarness h(PlaybackHarness::Mode::Manual, 1.0);
    const ClipId title = addTitle(h, h.v1, sampleTitle("Zoom"), 0, 60);
    SpanTracks zoom;
    Keyframe from;
    from.value = 1.0;
    Keyframe to;
    to.time = frames30(30);
    to.value = 2.5;
    zoom.track(SpanParameter::Scale) = {from, to};
    h.addSpan(title, SpanKind::Motion, 1, kCMTimeZero, frames30(30), zoom);
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();
    h.controller->seek(frames30(2)); // early in the zoom: the picture is already the one for its end
    const PlaybackHarness::Sample sample = h.presentExact();
    XCTAssertTrue(presentedLayer(sample, title) != nullptr && presentedLayer(sample, title)->exact);
    XCTAssertTrue(h.cache->contains(titleKey(h, title, 2.5), kCMTimeZero));
    XCTAssertFalse(h.cache->contains(titleKey(h, title, 1.0), kCMTimeZero));
    // One picture serves the whole zoom: later frames render nothing new.
    XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)));
    const uint64_t insertions = h.cache->stats().insertions;
    for (int64_t frame : {10, 20, 29, 45}) {
        h.controller->seek(frames30(frame));
        const PlaybackHarness::Sample later = h.presentExact();
        XCTAssertTrue(presentedLayer(later, title) != nullptr && presentedLayer(later, title)->exact);
    }
    XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)));
    XCTAssertEqual(h.cache->stats().insertions, insertions);
}

- (void)testRealTimePlaybackWithATitleOverVideoDropsNothing {
    PlaybackHarness h(PlaybackHarness::Mode::Realtime, 3.0);
    const AssetId movie = h.importAsset("h264_1080p30.mp4");
    XCTAssertTrue(h.ok(), @"%s", h.error().c_str());
    if (!h.ok()) {
        return;
    }
    h.addClip(h.v1, movie, 0, 150, kCMTimeZero);
    TitleContent lower = titlePreset(GeneratedPreset::LowerThird);
    lower.text = "Jane Doe\nDirector";
    const ClipId first = addTitle(h, h.v2, lower, 15, 45);
    TitleContent card = sampleTitle("A Second Title Arrives");
    card.shadowBlur = 0.02;
    const ClipId second = addTitle(h, h.v2, card, 75, 45);
    XCTAssertFalse(h.problem().has_value(), @"%s", h.problem().value_or("").c_str());
    h.load();
    XCTAssertTrue(PlaybackHarness::waitUntil([&] { return h.output->isRunning(); }), @"the output warms up");
    h.controller->seek(kCMTimeZero);
    h.presentExact();
    XCTAssertTrue(h.pool->waitUntilIdle(std::chrono::seconds(10)));
    std::this_thread::sleep_for(std::chrono::milliseconds(300));
    const uint64_t lateBefore = h.controller->stats().lateFrames;
    const uint64_t droppedBefore = h.controller->stats().droppedFrames;
    XCTAssertGreaterThanOrEqual(h.playAndWait(), 0.0);
    int samples = 0, titleSamples = 0, titleExact = 0;
    const auto start = SteadyClock::now();
    auto next = start;
    while (SteadyClock::now() - start < std::chrono::milliseconds(4200)) {
        next += std::chrono::microseconds(16667);
        std::this_thread::sleep_until(next);
        const PlaybackHarness::Sample s = h.present();
        if (!s.changed || !s.presented.clockDriven) {
            continue;
        }
        ++samples;
        for (const ClipId title : {first, second}) {
            if (const playback::PresentedLayer *shown = presentedLayer(s, title)) {
                ++titleSamples;
                titleExact += shown->exact ? 1 : 0;
            }
        }
    }
    const playback::PlaybackStats stats = h.controller->stats();
    h.controller->pause();
    NSLog(@"TITLE real-time playback over video: %d frames presented, %d with a title (%d exact), %llu late, %llu "
          @"dropped, %llu audio underruns",
          samples, titleSamples, titleExact, stats.lateFrames - lateBefore, stats.droppedFrames - droppedBefore,
          stats.audioUnderruns);
    XCTAssertGreaterThan(samples, 100);
    XCTAssertGreaterThan(titleSamples, 60, @"both titles were on screen");
    XCTAssertEqual(titleExact, titleSamples, @"every title frame had its picture (rendered ahead by the lookahead)");
    XCTAssertEqual(stats.lateFrames - lateBefore, 0u);
    XCTAssertEqual(stats.droppedFrames - droppedBefore, 0u);
    XCTAssertEqual(stats.audioUnderruns, 0u);
}

@end
