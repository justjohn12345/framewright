#include "BurnIn.h"

#include <algorithm>
#include <cmath>
#include <cstring>

namespace ve::test {

namespace {

enum class Layout { BGRA, Luma8, Luma16 };

bool layoutFor(OSType f, Layout &layout, bool &videoRange) {
    switch (f) {
    case kCVPixelFormatType_32BGRA:
        layout = Layout::BGRA;
        videoRange = false;
        return true;
    case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange:
        layout = Layout::Luma8;
        videoRange = true;
        return true;
    case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr8BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr8BiPlanarFullRange:
        layout = Layout::Luma8;
        videoRange = false;
        return true;
    case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange:
        layout = Layout::Luma16;
        videoRange = true;
        return true;
    case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_422YpCbCr10BiPlanarFullRange:
    case kCVPixelFormatType_444YpCbCr10BiPlanarFullRange:
        layout = Layout::Luma16;
        videoRange = false;
        return true;
    default:
        return false;
    }
}

double paletteLuma(const RGB &c) {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b;
}

struct LumaReader {
    const uint8_t *base;
    size_t stride;
    Layout layout;
    bool videoRange;

    double at(size_t x, size_t y) const {
        const uint8_t *row = base + y * stride;
        double v = 0;
        switch (layout) {
        case Layout::BGRA: {
            const uint8_t *p = row + x * 4;
            return 0.2126 * p[2] + 0.7152 * p[1] + 0.0722 * p[0];
        }
        case Layout::Luma8:
            v = row[x];
            break;
        case Layout::Luma16: {
            uint16_t s;
            std::memcpy(&s, row + x * 2, 2);
            v = s / 256.0; // 10 significant bits in the MSBs.
            break;
        }
        }
        return videoRange ? (v - 16.0) * 255.0 / 219.0 : v;
    }

    /// Mean and standard deviation over [x0,x1) x [y0,y1).
    void stats(size_t x0, size_t x1, size_t y0, size_t y1, double &mean, double &stddev) const {
        double sum = 0;
        double sum2 = 0;
        size_t n = 0;
        for (size_t y = y0; y < y1; ++y) {
            for (size_t x = x0; x < x1; ++x) {
                const double v = at(x, y);
                sum += v;
                sum2 += v * v;
                ++n;
            }
        }
        mean = n ? sum / static_cast<double>(n) : 0;
        stddev = n ? std::sqrt(std::max(0.0, sum2 / static_cast<double>(n) - mean * mean)) : 0;
    }
};

} // namespace

std::optional<int> readBurnIn(CVPixelBufferRef buffer) {
    if (buffer == nullptr) {
        return std::nullopt;
    }
    Layout layout;
    bool videoRange;
    if (!layoutFor(CVPixelBufferGetPixelFormatType(buffer), layout, videoRange)) {
        return std::nullopt;
    }
    if (CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        return std::nullopt;
    }
    const bool planar = CVPixelBufferIsPlanar(buffer);
    LumaReader reader{
        static_cast<const uint8_t *>(planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
                                            : CVPixelBufferGetBaseAddress(buffer)),
        planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer), layout,
        videoRange};
    const size_t width = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer);
    const size_t height = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer);
    std::optional<int> result;
    const double cell = static_cast<double>(width) / 18.0;
    if (reader.base != nullptr && cell >= 4 && static_cast<double>(height) > 3 * cell) {
        int index = 0;
        bool confident = true;
        const auto yA = static_cast<size_t>(std::lround(0.5 * cell + cell * 0.25));
        const auto yB = static_cast<size_t>(std::lround(1.5 * cell - cell * 0.25));
        for (int i = 0; i < 16 && confident; ++i) {
            const auto xA = static_cast<size_t>(std::lround((i + 1) * cell + cell * 0.25));
            const auto xB = static_cast<size_t>(std::lround((i + 2) * cell - cell * 0.25));
            double mean;
            double stddev;
            reader.stats(xA, xB, yA, yB, mean, stddev);
            if (stddev > 30) {
                confident = false;
            } else if (mean > 192) {
                index |= 1 << (15 - i);
            } else if (mean >= 64) {
                confident = false;
            }
        }
        if (confident) {
            // Background below the squares must match the palette entry of the decoded index.
            double mean;
            double stddev;
            const auto y0 = static_cast<size_t>(std::lround(2.25 * cell));
            const auto y1 = static_cast<size_t>(std::lround(2.75 * cell));
            reader.stats(static_cast<size_t>(cell), static_cast<size_t>(3 * cell), y0, y1, mean, stddev);
            if (stddev < 20 && std::fabs(mean - paletteLuma(kBurnInPalette[index % 8])) < 24) {
                result = index;
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    return result;
}

bool drawBurnIn(CVPixelBufferRef buffer, int index) {
    if (buffer == nullptr || CVPixelBufferGetPixelFormatType(buffer) != kCVPixelFormatType_32BGRA ||
        CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess) {
        return false;
    }
    auto *base = static_cast<uint8_t *>(CVPixelBufferGetBaseAddress(buffer));
    const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
    const size_t width = CVPixelBufferGetWidth(buffer);
    const size_t height = CVPixelBufferGetHeight(buffer);
    const RGB bg = kBurnInPalette[index % 8];
    const double cell = static_cast<double>(width) / 18.0;
    std::vector<uint8_t> bgRow(width * 4);
    for (size_t x = 0; x < width; ++x) {
        bgRow[x * 4 + 0] = bg.b;
        bgRow[x * 4 + 1] = bg.g;
        bgRow[x * 4 + 2] = bg.r;
        bgRow[x * 4 + 3] = 255;
    }
    std::vector<uint8_t> squareRow = bgRow;
    for (int i = 0; i < 16; ++i) {
        const auto x0 = static_cast<size_t>(std::lround((i + 1) * cell));
        const auto x1 = std::min(width, static_cast<size_t>(std::lround((i + 2) * cell)));
        const uint8_t v = ((index >> (15 - i)) & 1) ? 255 : 0;
        for (size_t x = x0; x < x1; ++x) {
            squareRow[x * 4 + 0] = v;
            squareRow[x * 4 + 1] = v;
            squareRow[x * 4 + 2] = v;
        }
    }
    const auto y0 = static_cast<size_t>(std::lround(0.5 * cell));
    const auto y1 = static_cast<size_t>(std::lround(1.5 * cell));
    for (size_t y = 0; y < height; ++y) {
        std::memcpy(base + y * stride, (y >= y0 && y < y1) ? squareRow.data() : bgRow.data(), width * 4);
    }
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    return true;
}

std::vector<float> makeToneWithBeep(double toneHz, double rate, int channels, int64_t frames, double beepStart) {
    std::vector<float> out(static_cast<size_t>(frames * channels));
    const auto beepFirst = static_cast<int64_t>(std::llround(beepStart * rate));
    const auto beepEnd = beepFirst + static_cast<int64_t>(std::llround(kBeepDuration * rate));
    for (int64_t n = 0; n < frames; ++n) {
        float v = kToneAmplitude * static_cast<float>(std::sin(2.0 * M_PI * toneHz * static_cast<double>(n) / rate));
        if (n >= beepFirst && n < beepEnd) {
            v += kBeepAmplitude *
                 static_cast<float>(std::sin(2.0 * M_PI * kBeepFrequency * static_cast<double>(n - beepFirst) / rate));
        }
        for (int c = 0; c < channels; ++c) {
            out[static_cast<size_t>(n * channels + c)] = v;
        }
    }
    return out;
}

std::optional<double> findBeepOnset(const float *interleaved, int64_t frames, int channels, double rate,
                                    int64_t searchFromFrame) {
    for (int64_t n = std::max<int64_t>(0, searchFromFrame); n < frames; ++n) {
        if (std::fabs(interleaved[n * channels]) > 0.3f) {
            return static_cast<double>(n) / rate;
        }
    }
    return std::nullopt;
}

double estimateFrequency(const float *interleaved, int64_t fromFrame, int64_t toFrame, int channels, double rate) {
    int64_t first = -1;
    int64_t last = -1;
    int crossings = 0;
    for (int64_t n = std::max<int64_t>(1, fromFrame); n < toFrame; ++n) {
        if (interleaved[(n - 1) * channels] < 0 && interleaved[n * channels] >= 0) {
            if (first < 0) {
                first = n;
            }
            last = n;
            ++crossings;
        }
    }
    if (crossings < 2) {
        return 0;
    }
    return (crossings - 1) * rate / static_cast<double>(last - first);
}

} // namespace ve::test
