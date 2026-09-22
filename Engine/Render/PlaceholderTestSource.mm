#include "PlaceholderTestSource.h"

#include "../Media/ColorTags.h"
#include "../Media/PixelBuffer.h"

#include <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <vector>

namespace ve::render {

using media::makeError;
using media::MediaErrorCode;
using media::PixelBuffer;
using media::Result;
using media::Status;

namespace {

constexpr std::int32_t kWidth = 1920;
constexpr std::int32_t kHeight = 1080;

struct Color {
    std::uint8_t r, g, b;
};

// Same layout as the test-media burn-in (EngineTests/Media/BurnIn.h): a palette background and
// 16 black/white squares encoding `index`, MSB first.
Status drawPattern(CVPixelBufferRef buffer, int index, Color background) {
    media::PixelBufferLock lock(buffer, false);
    if (!lock.locked()) {
        return makeError(MediaErrorCode::Internal, "placeholder: cannot lock pixel buffer");
    }
    auto *base = static_cast<std::uint8_t *>(CVPixelBufferGetBaseAddress(buffer));
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    const double cell = static_cast<double>(width) / 18.0;
    std::vector<std::uint8_t> row(width * 4);
    for (size_t x = 0; x < width; ++x) {
        row[x * 4 + 0] = background.b;
        row[x * 4 + 1] = background.g;
        row[x * 4 + 2] = background.r;
        row[x * 4 + 3] = 255;
    }
    std::vector<std::uint8_t> squares = row;
    for (int i = 0; i < 16; ++i) {
        const auto x0 = static_cast<size_t>(std::lround((i + 1) * cell));
        const auto x1 = std::min(width, static_cast<size_t>(std::lround((i + 2) * cell)));
        const std::uint8_t v = ((index >> (15 - i)) & 1) ? 255 : 0;
        for (size_t x = x0; x < x1; ++x) {
            squares[x * 4 + 0] = squares[x * 4 + 1] = squares[x * 4 + 2] = v;
        }
    }
    const auto y0 = static_cast<size_t>(std::lround(0.5 * cell));
    const auto y1 = static_cast<size_t>(std::lround(1.5 * cell));
    for (size_t y = 0; y < height; ++y) {
        std::memcpy(base + y * stride, (y >= y0 && y < y1) ? squares.data() : row.data(), width * 4);
    }
    return media::okStatus();
}

Result<PixelBuffer> makeBGRA(int index, Color background) {
    auto pool = media::PixelBufferPool::create(kCVPixelFormatType_32BGRA, kWidth, kHeight);
    if (!pool.ok()) {
        return std::move(pool).error();
    }
    auto buffer = pool->makeBuffer();
    if (!buffer.ok()) {
        return std::move(buffer).error();
    }
    VE_MEDIA_TRY(drawPattern(buffer->get(), index, background));
    media::attachColorInfo(buffer->get(), media::ColorInfo::bt709());
    return std::move(buffer).value();
}

Result<PixelBuffer> convertTo420v(const PixelBuffer &bgra) {
    auto pool = media::PixelBufferPool::create(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kWidth, kHeight);
    if (!pool.ok()) {
        return std::move(pool).error();
    }
    auto out = pool->makeBuffer();
    if (!out.ok()) {
        return std::move(out).error();
    }
    media::attachColorInfo(out->get(), media::ColorInfo::bt709());
    media::CFRef<VTPixelTransferSessionRef> session;
    OSStatus rc = VTPixelTransferSessionCreate(kCFAllocatorDefault, session.outPtr());
    if (rc != noErr) {
        return makeError(MediaErrorCode::Internal, "placeholder: VTPixelTransferSessionCreate failed", "OSStatus", rc);
    }
    VTSessionSetProperty(session.get(), kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                         kCVImageBufferYCbCrMatrix_ITU_R_709_2);
    rc = VTPixelTransferSessionTransferImage(session.get(), bgra.get(), out->get());
    VTPixelTransferSessionInvalidate(session.get());
    if (rc != noErr) {
        return makeError(MediaErrorCode::Internal, "placeholder: BGRA to 420v transfer failed", "OSStatus", rc);
    }
    return std::move(out).value();
}

struct PlaceholderState {
    PixelBuffer bottom; // '420v'
    PixelBuffer top;    // BGRA
    TextureSet bottomTextures;
    TextureSet topTextures;
    CFTimeInterval startTime = 0;
};

} // namespace

Result<PreviewFrameSource> makePlaceholderTestSource() {
    auto state = std::make_shared<PlaceholderState>();
    auto bottomRGB = makeBGRA(1, {60, 150, 60});
    if (!bottomRGB.ok()) {
        return std::move(bottomRGB).error();
    }
    auto bottom = convertTo420v(bottomRGB.value());
    if (!bottom.ok()) {
        return std::move(bottom).error();
    }
    auto top = makeBGRA(2, {60, 60, 200});
    if (!top.ok()) {
        return std::move(top).error();
    }
    state->bottom = std::move(bottom).value();
    state->top = std::move(top).value();
    state->startTime = CACurrentMediaTime();

    return PreviewFrameSource([state](const PreviewFrameRequest &request, PreviewFrame &frame) {
        if (!state->bottomTextures && request.textureCache != nullptr) {
            auto b = request.textureCache->textures(state->bottom);
            auto t = request.textureCache->textures(state->top);
            if (!b.ok() || !t.ok()) {
                return false;
            }
            state->bottomTextures = std::move(b).value();
            state->topTextures = std::move(t).value();
        }
        const double seconds = std::max(0.0, request.targetTimestamp - state->startTime);
        RenderGraph &g = frame.graph;
        g.time = CMTimeMakeWithSeconds(seconds, 600);
        g.width = kWidth;
        g.height = kHeight;
        g.layers.resize(2);
        g.layers[0] = VideoLayer{};
        g.layers[0].clipId = ClipId{1};
        g.layers[0].assetId = AssetId{1};
        g.layers[0].opacity = 0.5;
        g.layers[1] = VideoLayer{};
        g.layers[1].clipId = ClipId{2};
        g.layers[1].assetId = AssetId{2};
        g.layers[1].isStill = true;
        g.layers[1].opacity = 0.5;
        g.layers[1].transform.scale = 0.6;
        g.layers[1].transform.x = 120;
        g.layers[1].transform.y = 60;
        g.layers[1].transform.rotationDegrees = std::fmod(seconds * 15.0, 360.0);
        frame.textures.resize(2);
        frame.textures[0] = state->bottomTextures;
        frame.textures[1] = state->topTextures;
        return true;
    });
}

} // namespace ve::render
