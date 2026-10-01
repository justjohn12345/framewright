// Sequence settings, measured by rendering: after SetSequenceFormat changes a sequence's frame size, every
// picture covers the same part of the monitor as before (a picture in picture placed by static values and
// moved by a Motion span, a 4:3 still, a rotated picture), in the same shape (2x) and in another shape
// (the old frame fitted inside the new one). The pictures are drawn by the compositor from the Scheduler's
// graphs, as the monitors and the export draw them.

#import <XCTest/XCTest.h>

#include "../../Engine/Edit/EditOps.h"
#include "../../Engine/Model/Validation.h"
#include "../../Engine/Render/Compositor.h"
#include "../../Engine/Render/Scheduler.h"
#include "CompositorTestSupport.h"

#include <cmath>
#include <map>
#include <memory>
#include <vector>

using namespace ve;
using namespace ve::render;
using namespace ve::rtest;

namespace {

/// Where one colour lies in a rendered texture: the bounding box of the pixels at least half that
/// colour, and the coverage-weighted centroid and area (a pixel counts by the colour's fraction).
struct Footprint {
    double minX = 1e9, minY = 1e9, maxX = -1, maxY = -1;
    double centroidX = 0, centroidY = 0, area = 0;
};

enum class Channel { Red, Green, Blue };

Footprint footprintOf(id<MTLTexture> texture, Channel channel) {
    const size_t w = texture.width, h = texture.height;
    std::vector<uint8_t> pixels(w * h * 4);
    [texture getBytes:pixels.data() bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    Footprint f;
    double sumX = 0, sumY = 0;
    for (size_t y = 0; y < h; ++y) {
        for (size_t x = 0; x < w; ++x) {
            const uint8_t *p = &pixels[(y * w + x) * 4]; // BGRA
            const int value = channel == Channel::Red ? p[2] : channel == Channel::Green ? p[1] : p[0];
            const double weight = value / 255.0;
            if (weight <= 0) {
                continue;
            }
            f.area += weight;
            sumX += weight * (double(x) + 0.5);
            sumY += weight * (double(y) + 0.5);
            if (value >= 128) {
                f.minX = std::min(f.minX, double(x));
                f.minY = std::min(f.minY, double(y));
                f.maxX = std::max(f.maxX, double(x));
                f.maxY = std::max(f.maxY, double(y));
            }
        }
    }
    if (f.area > 0) {
        f.centroidX = sumX / f.area;
        f.centroidY = sumY / f.area;
    }
    return f;
}

/// A footprint in `from`'s target pixels mapped by x' = ox + s x, y' = oy + s y.
Footprint mapped(const Footprint &f, double s, double ox, double oy) {
    Footprint m = f;
    m.minX = ox + s * f.minX;
    m.maxX = ox + s * f.maxX;
    m.minY = oy + s * f.minY;
    m.maxY = oy + s * f.maxY;
    m.centroidX = ox + s * f.centroidX;
    m.centroidY = oy + s * f.centroidY;
    m.area = f.area * s * s;
    return m;
}

} // namespace

@interface SequenceFormatRenderTests : XCTestCase
@end

@implementation SequenceFormatRenderTests {
    std::unique_ptr<Compositor> _compositor;
}

- (void)setUp {
    auto created = Compositor::create(device());
    XCTAssertTrue(created.ok());
    if (created.ok()) {
        _compositor = std::move(created).value();
    }
}

/// Three pictures, each one colour so its footprint can be measured alone: red, a 16:9 picture in picture
/// at half size, offset, moved by a Motion span; green, a 4:3 still at 0.6 on V2; blue, a 16:9 picture
/// turned 90 degrees at 0.3, in a corner, on V3.
- (void)testPicturesKeepTheirPlaceWhenTheFrameSizeChanges {
    if (!_compositor) {
        return;
    }
    Project project;
    auto addStill = [&](const char *name, int32_t width, int32_t height) {
        MediaAsset asset;
        asset.name = name;
        asset.url = std::string("file:///media/") + name;
        asset.kind = AssetKind::Still;
        asset.width = width;
        asset.height = height;
        return project.addAsset(asset);
    };
    const AssetId red = addStill("red.png", 640, 360);
    const AssetId green = addStill("green.png", 480, 360);
    const AssetId blue = addStill("blue.png", 640, 360);
    const SequenceId sequenceId = project.addSequence("Main", CMTimeMake(1, 30), 1920, 1080, 3, 0);
    Sequence &sequence = *project.findSequence(sequenceId);
    auto addClip = [&](size_t track, AssetId asset, VideoParams params) {
        Clip clip;
        clip.id = project.ids.make<ClipId>();
        clip.assetId = asset;
        clip.trackId = sequence.videoTracks[track].id;
        clip.isStill = true;
        clip.timelineStart = kCMTimeZero;
        clip.timelineDuration = CMTimeMake(60, 30);
        clip.video = params;
        sequence.videoTracks[track].clips.push_back(clip);
        return clip.id;
    };
    const ClipId redClip = addClip(0, red, VideoParams{-300, 150, 0.5, 0, 1});
    addClip(1, green, VideoParams{250, -120, 0.6, 0, 1});
    addClip(2, blue, VideoParams{700, 380, 0.3, 90, 1});
    // The red clip moves 400 px right and 100 px up over its first second, then holds.
    EffectSpan move;
    move.id = project.ids.make<SpanId>();
    move.lane = 1;
    move.kind = SpanKind::Motion;
    move.start = kCMTimeZero;
    move.end = CMTimeMake(1, 1);
    Keyframe k0, k1;
    k0.time = kCMTimeZero;
    k1.time = CMTimeMake(1, 1);
    k0.value = 0;
    k1.value = 400;
    move.tracks[SpanParameter::X] = {k0, k1};
    k1.value = -100;
    move.tracks[SpanParameter::Y] = {k0, k1};
    sequence.findClip(redClip)->spans.push_back(move);
    XCTAssertFalse(validateProject(project).has_value(), @"%s", validateProject(project).value_or("").c_str());

    // The pictures: solid colours (premultiplied, opaque).
    std::map<AssetId, TextureSet> textures;
    for (const auto &[asset, color] : {std::pair{red, RGBA8{255, 0, 0, 255}}, std::pair{green, RGBA8{0, 255, 0, 255}},
                                       std::pair{blue, RGBA8{0, 0, 255, 255}}}) {
        const MediaAsset &info = *project.findAsset(asset);
        media::PixelBuffer buffer = makeBuffer(kCVPixelFormatType_32BGRA, size_t(info.width), size_t(info.height));
        fillBGRA(buffer, color);
        textures[asset] = texturesFor(*_compositor, buffer);
    }
    auto render = [&](const Project &p, CMTime t, size_t width, size_t height) {
        const Sequence &s = *p.findSequence(sequenceId);
        const RenderGraph graph = Scheduler::renderGraphAt(s, p, t);
        id<MTLTexture> target = makeTargetTexture(width, height);
        auto lookup = [&](const VideoLayer &layer, std::size_t, TextureSet &out) {
            out = textures[layer.assetId];
            return bool(out);
        };
        auto result = _compositor->renderAndWait(graph, lookup, TextureTarget{target, {}, nil});
        XCTAssertTrue(result.ok() && result->status.ok() && result->skippedLayers.empty());
        return target;
    };
    auto expectSame = [](const Footprint &expected, const Footprint &actual, const char *what) {
        NSLog(@"%s: box %.1f,%.1f-%.1f,%.1f vs %.1f,%.1f-%.1f,%.1f; centroid %.2f,%.2f vs %.2f,%.2f; area %.0f vs %.0f",
              what, expected.minX, expected.minY, expected.maxX, expected.maxY, actual.minX, actual.minY, actual.maxX,
              actual.maxY, expected.centroidX, expected.centroidY, actual.centroidX, actual.centroidY, expected.area,
              actual.area);
        XCTAssertGreaterThan(actual.area, 100.0, @"%s is on screen", what);
        XCTAssertEqualWithAccuracy(actual.minX, expected.minX, 1.01, @"%s", what);
        XCTAssertEqualWithAccuracy(actual.maxX, expected.maxX, 1.01, @"%s", what);
        XCTAssertEqualWithAccuracy(actual.minY, expected.minY, 1.01, @"%s", what);
        XCTAssertEqualWithAccuracy(actual.maxY, expected.maxY, 1.01, @"%s", what);
        XCTAssertEqualWithAccuracy(actual.centroidX, expected.centroidX, 0.5, @"%s", what);
        XCTAssertEqualWithAccuracy(actual.centroidY, expected.centroidY, 0.5, @"%s", what);
        XCTAssertEqualWithAccuracy(actual.area, expected.area, expected.area * 0.01, @"%s", what);
    };

    // Before: the 16:9 frame in a 960x540 monitor (half size), at 0.5 s (the move half way) and 1.5 s.
    const CMTime times[] = {CMTimeMake(15, 30), CMTimeMake(45, 30)};
    std::vector<std::vector<Footprint>> before;
    for (const CMTime t : times) {
        id<MTLTexture> shown = render(project, t, 960, 540);
        before.push_back({footprintOf(shown, Channel::Red), footprintOf(shown, Channel::Green),
                          footprintOf(shown, Channel::Blue)});
    }
    const char *names[] = {"red picture in picture", "green 4:3 still", "blue turned picture"};

    // 3840x2160: the same monitor shows the same thing.
    {
        Project doubled = project;
        SetSequenceFormat command(sequenceId, SequenceFormat{CMTimeMake(1, 30), 3840, 2160, 48000, true});
        XCTAssertTrue(command.apply(doubled).ok());
        for (size_t i = 0; i < 2; ++i) {
            id<MTLTexture> shown = render(doubled, times[i], 960, 540);
            const Footprint after[] = {footprintOf(shown, Channel::Red), footprintOf(shown, Channel::Green),
                                       footprintOf(shown, Channel::Blue)};
            for (size_t c = 0; c < 3; ++c) {
                expectSame(before[i][c], after[c], names[c]);
            }
        }
    }
    // 1080x1080 in a 540x540 monitor: the old frame fitted inside the square (540 x 303.75 at y 118.125),
    // each picture where it was in that fitted frame (the parts of the blue picture outside the old frame
    // are clipped in both, so it is left out of this comparison).
    {
        Project square = project;
        SetSequenceFormat command(sequenceId, SequenceFormat{CMTimeMake(1, 30), 1080, 1080, 48000, true});
        XCTAssertTrue(command.apply(square).ok());
        const double s = 540.0 / 960.0;
        const double oy = (540.0 - 540.0 * 9.0 / 16.0) / 2.0;
        for (size_t i = 0; i < 2; ++i) {
            id<MTLTexture> shown = render(square, times[i], 540, 540);
            expectSame(mapped(before[i][0], s, 0, oy), footprintOf(shown, Channel::Red), names[0]);
            expectSame(mapped(before[i][1], s, 0, oy), footprintOf(shown, Channel::Green), names[1]);
        }
    }
}

@end
