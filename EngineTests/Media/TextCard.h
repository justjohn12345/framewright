// Screen-like test pictures with small text (a desktop screen recording's fine strokes), a movie of
// them, and the edge measure the sharpness tests use.
#pragma once

#include "../../Engine/Media/PixelBuffer.h"

#import <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <string>
#include <vector>

namespace ve::test {

/// An 8-bit grey picture, row-major, `width` x `height`.
struct GrayImage {
    size_t width = 0;
    size_t height = 0;
    std::vector<uint8_t> pixels;

    uint8_t at(size_t x, size_t y) const { return pixels[y * width + x]; }
};

/// A "screen" of small text: lines of UI-like words and numbers in Helvetica at `pixelSize` pixels
/// (22 at 3840x2160 is macOS body text on a Retina display), black on white or, `inverted`, white on
/// black, anti-aliased like the screen (grey scale). `variant` moves a block "cursor" at the end of
/// the last line and changes one word, as a recording of someone typing would.
GrayImage renderTextCard(size_t width, size_t height, double pixelSize, bool inverted, int variant = 0);

/// Copies a grey picture into a 32BGRA buffer of the same size (opaque, R = G = B).
bool fillBGRA(CVPixelBufferRef bgra, const GrayImage &image);

/// Writes an H.264 QuickTime movie of `frames` text cards (frame i is variant i / `framesPerVariant`)
/// at `framesPerSecond`, `bitRate` bits per second (high enough that the text survives the encoder),
/// one keyframe per second. Empty on success, else what failed.
std::string writeTextCardMovie(const std::string &path, size_t width, size_t height, int frames, int framesPerSecond,
                               int64_t bitRate, double pixelSize, bool inverted, int framesPerVariant = 15);

/// The edge measure: the mean gradient magnitude of the grey levels (0...1) over the rectangle
/// [x, x + w) x [y, y + h), interior pixels only, with central differences:
/// mean of sqrt(gx^2 + gy^2), gx = (L(x+1, y) - L(x-1, y)) / 2, gy likewise. Sharper text scores
/// higher; a flat area scores 0.
double edgeMeasure(const GrayImage &image, size_t x, size_t y, size_t w, size_t h);

/// The luma (BT.709 weights of the gamma-encoded 8-bit R'G'B', rounded) of a 32BGRA buffer.
GrayImage grayOf(CVPixelBufferRef bgra);

} // namespace ve::test
