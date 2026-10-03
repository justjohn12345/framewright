// What a program monitor frame costs the GPU at 200 % of a 4K sequence, with and without the drawable limit
// (VEPreviewView.maximumDrawableSize): the compositor drawing a 3840x2160 4:2:0 picture into a BGRA8 target the size of
// the drawable, 7680x4320 (200 % on a Retina display, unlimited) or 3840x2160 (limited to the sequence's size), as the
// view does through its working texture and output pass. GPU busy time per frame (from the command buffers' GPU
// start and end times) over 120 pipelined frames. Run in the Measurements scheme (it prints numbers and asserts
// nothing about them).

#import <XCTest/XCTest.h>

#include "CompositorTestSupport.h"

#include <algorithm>
#include <atomic>
#include <mutex>
#include <thread>
#include <vector>

using namespace ve;
using namespace ve::render;
using namespace ve::rtest;

namespace {

/// GPU busy seconds of the frames submitted (the union of their intervals) and how many completed.
struct Timeline {
    std::mutex mutex;
    std::vector<std::pair<double, double>> intervals;
    std::atomic<int> completed{0};

    void add(const RenderResult &r) {
        {
            std::lock_guard<std::mutex> lock(mutex);
            intervals.emplace_back(r.gpuStartTime, r.gpuEndTime);
        }
        completed.fetch_add(1);
    }
    double busySeconds() {
        std::lock_guard<std::mutex> lock(mutex);
        std::sort(intervals.begin(), intervals.end());
        double total = 0, start = 0, end = -1;
        for (const auto &[a, b] : intervals) {
            if (a > end) {
                total += std::max(0.0, end - start);
                start = a;
                end = b;
            } else {
                end = std::max(end, b);
            }
        }
        return total + std::max(0.0, end - start);
    }
};

} // namespace

@interface PreviewDrawableMeasurementTests : XCTestCase
@end

@implementation PreviewDrawableMeasurementTests

- (void)testAFrameAt200PercentOfA4KSequence {
    auto created = Compositor::create(device());
    XCTAssertTrue(created.ok());
    if (!created.ok()) {
        return;
    }
    std::unique_ptr<Compositor> compositor = std::move(created).value();
    const media::PixelBuffer picture = makeBurnIn420v(1, 3840, 2160);
    RenderGraph graph = makeGraph(3840, 2160);
    graph.layers.push_back(makeLayer(1));
    auto gpuMsPerFrame = [&](size_t width, size_t height) {
        std::vector<id<MTLTexture>> drawables{makeTargetTexture(width, height), makeTargetTexture(width, height),
                                              makeTargetTexture(width, height)};
        auto run = [&](int frames) {
            auto timeline = std::make_shared<Timeline>();
            for (int i = 0; i < frames; ++i) {
                @autoreleasepool {
                    const TextureSet textures = texturesFor(*compositor, picture);
                    auto lookup = [&textures](const VideoLayer &, std::size_t, TextureSet &out) {
                        out = textures;
                        return true;
                    };
                    (void)compositor->render(graph, lookup, TextureTarget{drawables[size_t(i) % drawables.size()], {}, nil},
                                             [timeline](const RenderResult &r) { timeline->add(r); });
                }
            }
            while (timeline->completed.load() < frames) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
            return timeline->busySeconds() / frames * 1000.0;
        };
        run(20); // pipelines, pools and textures
        return run(120);
    };
    const double unlimited = gpuMsPerFrame(7680, 4320);
    const double limited = gpuMsPerFrame(3840, 2160);
    NSLog(@"PREVIEW DRAWABLE MEASURE 200 %% of a 4K sequence: GPU %.2f ms per frame into 7680x4320 (unlimited), "
          @"%.2f ms per frame into 3840x2160 (limited to the sequence's size)",
          unlimited, limited);
}

@end
