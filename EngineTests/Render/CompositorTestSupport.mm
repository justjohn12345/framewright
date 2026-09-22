#include "CompositorTestSupport.h"

#include "../../Engine/Media/ColorTags.h"
#include "../Media/BurnIn.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace ve::rtest {

using media::PixelBuffer;

id<MTLDevice> device() {
    static id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    return d;
}

PixelBuffer makeBuffer(OSType format, size_t width, size_t height) {
    auto pool = media::PixelBufferPool::create(format, width, height);
    if (!pool.ok()) {
        return {};
    }
    auto buffer = pool->makeBuffer();
    return buffer.ok() ? std::move(buffer).value() : PixelBuffer{};
}

int bitDepthOf(OSType f) {
    switch (f) {
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
        return 8;
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
        return 10;
    default:
        return 0;
    }
}

void fillYCbCr(const PixelBuffer &buffer, int y, int cb, int cr, media::YCbCrMatrix matrix) {
    CVPixelBufferRef pb = buffer.get();
    const int depth = bitDepthOf(buffer.pixelFormat());
    media::PixelBufferLock lock(pb, false);
    for (size_t plane = 0; plane < 2; ++plane) {
        auto *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pb, plane));
        const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pb, plane);
        const size_t w = CVPixelBufferGetWidthOfPlane(pb, plane);
        const size_t h = CVPixelBufferGetHeightOfPlane(pb, plane);
        for (size_t row = 0; row < h; ++row) {
            uint8_t *line = base + row * stride;
            for (size_t x = 0; x < w; ++x) {
                if (depth == 8) {
                    if (plane == 0) {
                        line[x] = static_cast<uint8_t>(y);
                    } else {
                        line[2 * x] = static_cast<uint8_t>(cb);
                        line[2 * x + 1] = static_cast<uint8_t>(cr);
                    }
                } else {
                    auto *line16 = reinterpret_cast<uint16_t *>(line);
                    if (plane == 0) {
                        line16[x] = static_cast<uint16_t>(y << 6);
                    } else {
                        line16[2 * x] = static_cast<uint16_t>(cb << 6);
                        line16[2 * x + 1] = static_cast<uint16_t>(cr << 6);
                    }
                }
            }
        }
    }
    media::ColorInfo info = media::ColorInfo::bt709();
    info.matrix = matrix;
    media::attachColorInfo(pb, info);
}

void fillBGRARect(const PixelBuffer &buffer, size_t x0, size_t y0, size_t x1, size_t y1, RGBA8 c) {
    CVPixelBufferRef pb = buffer.get();
    media::PixelBufferLock lock(pb, false);
    auto *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(pb));
    const size_t stride = CVPixelBufferGetBytesPerRow(pb);
    x1 = std::min(x1, buffer.width());
    y1 = std::min(y1, buffer.height());
    for (size_t y = y0; y < y1; ++y) {
        uint8_t *p = base + y * stride;
        for (size_t x = x0; x < x1; ++x) {
            p[4 * x + 0] = c.b;
            p[4 * x + 1] = c.g;
            p[4 * x + 2] = c.r;
            p[4 * x + 3] = c.a;
        }
    }
}

void fillBGRA(const PixelBuffer &buffer, RGBA8 color) {
    fillBGRARect(buffer, 0, 0, buffer.width(), buffer.height(), color);
}

PixelBuffer convertBGRATo420v(const PixelBuffer &bgra) {
    const size_t w = bgra.width();
    const size_t h = bgra.height();
    PixelBuffer out = makeBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, w, h);
    media::PixelBufferLock in(bgra.get(), true);
    media::PixelBufferLock lock(out.get(), false);
    const auto *src = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(bgra.get()));
    const size_t srcStride = CVPixelBufferGetBytesPerRow(bgra.get());
    auto *luma = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(out.get(), 0));
    const size_t lumaStride = CVPixelBufferGetBytesPerRowOfPlane(out.get(), 0);
    auto *chroma = static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(out.get(), 1));
    const size_t chromaStride = CVPixelBufferGetBytesPerRowOfPlane(out.get(), 1);
    const double kr = 0.2126, kb = 0.0722, kg = 1.0 - kr - kb;
    auto code = [](double v) { return static_cast<uint8_t>(std::clamp(std::lround(v), 0L, 255L)); };
    for (size_t y = 0; y < h; y += 2) {
        for (size_t x = 0; x < w; x += 2) {
            double sr = 0, sg = 0, sb = 0;
            int n = 0;
            for (size_t dy = 0; dy < 2 && y + dy < h; ++dy) {
                for (size_t dx = 0; dx < 2 && x + dx < w; ++dx) {
                    const uint8_t *p = src + (y + dy) * srcStride + (x + dx) * 4;
                    const double r = p[2] / 255.0, g = p[1] / 255.0, b = p[0] / 255.0;
                    luma[(y + dy) * lumaStride + x + dx] = code(16.0 + 219.0 * (kr * r + kg * g + kb * b));
                    sr += r;
                    sg += g;
                    sb += b;
                    ++n;
                }
            }
            sr /= n;
            sg /= n;
            sb /= n;
            const double yy = kr * sr + kg * sg + kb * sb;
            uint8_t *c = chroma + (y / 2) * chromaStride + (x / 2) * 2;
            c[0] = code(128.0 + 224.0 * (sb - yy) / (2.0 * (1.0 - kb)));
            c[1] = code(128.0 + 224.0 * (sr - yy) / (2.0 * (1.0 - kr)));
        }
    }
    media::attachColorInfo(out.get(), media::ColorInfo::bt709());
    return out;
}

PixelBuffer makeBurnIn420v(int index, size_t width, size_t height) {
    PixelBuffer bgra = makeBuffer(kCVPixelFormatType_32BGRA, width, height);
    if (!bgra || !test::drawBurnIn(bgra.get(), index)) {
        return {};
    }
    return convertBGRATo420v(bgra);
}

RGBA8 pixelAt(const PixelBuffer &bgra, size_t x, size_t y) {
    media::PixelBufferLock lock(bgra.get(), true);
    const auto *p = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(bgra.get())) +
                    y * CVPixelBufferGetBytesPerRow(bgra.get()) + x * 4;
    return {p[2], p[1], p[0], p[3]};
}

RGBA8 texturePixel(id<MTLTexture> texture, size_t x, size_t y) {
    uint8_t p[4] = {};
    [texture getBytes:p bytesPerRow:4 fromRegion:MTLRegionMake2D(x, y, 1, 1) mipmapLevel:0];
    return {p[2], p[1], p[0], p[3]};
}

id<MTLTexture> makeTargetTexture(size_t width, size_t height) {
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                    width:width
                                                                                   height:height
                                                                                mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    desc.storageMode = MTLStorageModeShared;
    return [device() newTextureWithDescriptor:desc];
}

RGBd referenceRGB(int y, int cb, int cr, int bitDepth, bool fullRange, media::YCbCrMatrix matrix) {
    double kr = 0.2126, kb = 0.0722;
    if (matrix == media::YCbCrMatrix::BT601) {
        kr = 0.299;
        kb = 0.114;
    } else if (matrix == media::YCbCrMatrix::BT2020) {
        kr = 0.2627;
        kb = 0.0593;
    }
    const double kg = 1.0 - kr - kb;
    const double s = std::ldexp(1.0, bitDepth - 8);
    const double maxCode = std::ldexp(1.0, bitDepth) - 1.0;
    double yn, cbn, crn;
    if (fullRange) {
        yn = y / maxCode;
        cbn = (cb - 128.0 * s) / maxCode;
        crn = (cr - 128.0 * s) / maxCode;
    } else {
        yn = (y - 16.0 * s) / (219.0 * s);
        cbn = (cb - 128.0 * s) / (224.0 * s);
        crn = (cr - 128.0 * s) / (224.0 * s);
    }
    const double r = yn + 2.0 * (1.0 - kr) * crn;
    const double b = yn + 2.0 * (1.0 - kb) * cbn;
    const double g = (yn - kr * r - kb * b) / kg;
    return {r * 255.0, g * 255.0, b * 255.0};
}

RenderGraph makeGraph(int32_t width, int32_t height) {
    RenderGraph g;
    g.time = CMTimeMake(0, 30);
    g.width = width;
    g.height = height;
    return g;
}

VideoLayer makeLayer(uint64_t clipId, double opacity) {
    VideoLayer l;
    l.clipId = ClipId{clipId};
    l.assetId = AssetId{clipId + 1000};
    l.trackId = TrackId{clipId + 2000};
    l.opacity = opacity;
    l.transform.opacity = opacity;
    return l;
}

media::Result<render::RenderResult> renderLayers(render::Compositor &compositor, const RenderGraph &graph,
                                                 const std::vector<render::TextureSet> &textures,
                                                 const render::RenderTarget &target) {
    auto lookup = [&textures](const VideoLayer &, std::size_t index, render::TextureSet &out) {
        if (index < textures.size() && textures[index]) {
            out = textures[index];
            return true;
        }
        return false;
    };
    return compositor.renderAndWait(graph, lookup, target);
}

render::TextureSet texturesFor(const render::Compositor &compositor, const PixelBuffer &buffer) {
    auto set = compositor.textureCache().textures(buffer);
    return set.ok() ? std::move(set).value() : render::TextureSet{};
}

bool near(RGBA8 actual, double r, double g, double b, double tolerance) {
    return std::fabs(actual.r - r) <= tolerance && std::fabs(actual.g - g) <= tolerance &&
           std::fabs(actual.b - b) <= tolerance;
}

} // namespace ve::rtest
