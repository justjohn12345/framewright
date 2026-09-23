// Test helpers shared by every media test (and by later phases' render/export tests):
// the frame-index burn-in drawn by Scripts/make_test_media.swift, and the test tone + beep.
//
// Burn-in layout (keep in sync with Scripts/make_test_media.swift):
//   cell = width / 18; square i (0..15) covers x in [round((i+1)cell), round((i+2)cell)),
//   y in [round(0.5 cell), round(1.5 cell)); white = bit (15 - i) of the index set (MSB first).
//   Everything else is kBurnInPalette[index % 8].
#pragma once

#include <CoreVideo/CoreVideo.h>

#include <cstdint>
#include <optional>
#include <vector>

namespace ve::test {

struct RGB {
    uint8_t r, g, b;
};
inline constexpr RGB kBurnInPalette[8] = {
    {180, 60, 60}, {60, 150, 60}, {60, 60, 200}, {170, 150, 40},
    {40, 150, 160}, {150, 60, 160}, {110, 110, 110}, {200, 110, 50},
};

/// Reads the frame index from a decoded frame. Handles 32BGRA and the biplanar YCbCr formats
/// (8-bit 420v/420f/422v/..., 10-bit x420/xf20/x422/xf22/x444/xf44), at any scale. Returns
/// nullopt unless every square is clearly black or white and the background matches the
/// palette entry for the decoded index.
std::optional<int> readBurnIn(CVPixelBufferRef buffer);

/// Draws the burn-in for `index` into a 32BGRA buffer.
bool drawBurnIn(CVPixelBufferRef bgraBuffer, int index);

// Audio: toneAmplitude * sin(2 pi f t) on every channel plus the beep
// beepAmplitude * sin(2 pi 1000 (t - beepStart)) for beepStart <= t < beepStart + 0.1 s.
inline constexpr float kToneAmplitude = 0.1f;
inline constexpr float kBeepAmplitude = 0.7f;
inline constexpr double kBeepFrequency = 1000.0;
inline constexpr double kBeepDuration = 0.1;
inline constexpr double kMediaBeepStart = 2.0; ///< Beep position in the generated files.

/// Interleaved test signal, sample-exact like the generator's.
std::vector<float> makeToneWithBeep(double toneHz, double rate, int channels, int64_t frames, double beepStart);

/// Onset of the beep in seconds from the start of `interleaved` (channel 0): the first sample
/// whose magnitude exceeds 0.3. With the signal above that sample follows the true onset by a
/// fixed detection latency: the beep alone crosses 0.3 when sin(2 pi 1000 t) > 0.3 / 0.7, i.e.
/// 3.39 samples in at 48 kHz, so the first sample above it is sample 4; the tone (amplitude
/// 0.1) moves the crossing by at most one sample either way. So at 48 kHz the result is the
/// true onset + kBeepDetectorLatencyFrames48k samples, within +-1 sample (at another rate or
/// speed the latency scales with the beep's period in samples). Samples before
/// `searchFromFrame` are ignored. nullopt if there is no beep.
std::optional<double> findBeepOnset(const float *interleaved, int64_t frames, int channels, double rate,
                                    int64_t searchFromFrame = 0);

/// findBeepOnset's detection latency at 48 kHz (see above), in samples.
inline constexpr int kBeepDetectorLatencyFrames48k = 4;

/// Frequency of channel 0 over [fromFrame, toFrame) from rising zero crossings.
double estimateFrequency(const float *interleaved, int64_t fromFrame, int64_t toFrame, int channels, double rate);

} // namespace ve::test
