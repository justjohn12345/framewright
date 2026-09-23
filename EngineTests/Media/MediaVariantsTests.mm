// Source variants beyond the conformance clips, through both backends: long GOPs, a leading
// empty edit, MPEG-TS with a timestamp offset, AV1 (VideoToolbox hardware and dav1d), 44.1 kHz,
// mono and 5.1 audio, Opus/Vorbis/FLAC/ADTS, ProRes 4444 alpha, oversized stills, decoder
// interrupts, and cross-backend equivalence on the same files.

#import <XCTest/XCTest.h>

#include "../../Engine/Media/Apple/AppleBackend.h"
#include "../../Engine/Media/BackendRouter.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Media/HardwareCaps.h"
#include "../../Engine/Model/TimeUtil.h"
#include "BurnIn.h"
#include "FFmpegTestMedia.h"
#include "TestMedia.h"

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <cmath>
#include <numeric>
#include <thread>

using namespace ve;
using namespace ve::media;
using namespace ve::test;

namespace {

double sec(CMTime t) {
    return CMTimeGetSeconds(t);
}

std::vector<std::shared_ptr<IMediaBackend>> bothBackends() {
    return {apple::makeAppleBackend(), ffmpeg::makeFFmpegBackend()};
}

/// The whole track at `options`.
std::vector<float> readAll(IAudioDecoder &decoder) {
    std::vector<float> all;
    std::vector<float> chunk(static_cast<size_t>(4096 * decoder.channels()));
    while (true) {
        auto n = decoder.read(chunk.data(), 4096);
        if (!n.ok() || n.value() == 0) {
            break;
        }
        all.insert(all.end(), chunk.begin(), chunk.begin() + n.value() * decoder.channels());
    }
    return all;
}

/// Lag (in frames, |lag| <= maxLag) at which channel 0 of `b` best matches channel 0 of `a`
/// over [from, from + length), and the normalised correlation there.
std::pair<int, double> bestLag(const std::vector<float> &a, int channelsA, const std::vector<float> &b, int channelsB,
                               int64_t from, int64_t length, int maxLag) {
    int best = 0;
    double bestCorr = -2;
    for (int lag = -maxLag; lag <= maxLag; ++lag) {
        double ab = 0, aa = 0, bb = 0;
        for (int64_t i = from; i < from + length; ++i) {
            const int64_t j = i + lag;
            if (j < 0 || (j + 1) * channelsB > static_cast<int64_t>(b.size()) ||
                (i + 1) * channelsA > static_cast<int64_t>(a.size())) {
                continue;
            }
            const double x = a[static_cast<size_t>(i * channelsA)];
            const double y = b[static_cast<size_t>(j * channelsB)];
            ab += x * y;
            aa += x * x;
            bb += y * y;
        }
        const double corr = aa > 0 && bb > 0 ? ab / std::sqrt(aa * bb) : 0;
        if (corr > bestCorr) {
            bestCorr = corr;
            best = lag;
        }
    }
    return {best, bestCorr};
}

/// Where findBeepOnset() finds the beep of the ideal generated signal at `rate`.
double referenceOnset(double toneHz, double rate, double beepStart) {
    const auto frames = static_cast<int64_t>((beepStart + 0.2) * rate);
    const std::vector<float> ideal = makeToneWithBeep(toneHz, rate, 1, frames, beepStart);
    return findBeepOnset(ideal.data(), frames, 1, rate, static_cast<int64_t>((beepStart - 0.5) * rate)).value_or(-1);
}

} // namespace

@interface MediaVariantsTests : XCTestCase
@end

@implementation MediaVariantsTests

- (void)setUp {
    self.continueAfterFailure = YES;
}

- (std::string)generated:(const std::string &)file {
    std::string error;
    const std::string path = testMediaPath(file, error);
    XCTAssertFalse(path.empty(), @"%s", error.c_str());
    return path;
}

/// A derived file; "" (the caller skips) when it needs the missing ffmpeg tool.
- (std::string)derived:(const std::string &)file {
    std::string error;
    const std::string path = derivedMediaPath(file, error);
    if (path.empty() && !(derivedNeedsTool(file) && ffmpegToolPath().empty())) {
        XCTFail(@"%s", error.c_str());
    }
    return path;
}

- (std::unique_ptr<IVideoDecoder>)open:(IMediaBackend &)backend path:(const std::string &)path {
    auto decoder = backend.makeVideoDecoder();
    Status s = decoder->open(path, -1, DecodeOptions{});
    XCTAssertTrue(s.ok(), @"%s via %s: %s", path.c_str(), backend.name().c_str(),
                  s.ok() ? "" : s.error().description().c_str());
    return s.ok() ? std::move(decoder) : nullptr;
}

/// seek(t) then next() must give burn-in `index` at pts `pts`.
- (void)expectSeek:(IVideoDecoder &)decoder to:(CMTime)t index:(int)index pts:(CMTime)pts label:(NSString *)label {
    XCTAssertTrue(decoder.seek(t).ok(), @"%@", label);
    auto r = decoder.next();
    XCTAssertTrue(r.ok() && r.value(), @"%@: seek(%.4f): %s", label, sec(t),
                  r.ok() ? "end of stream" : r.error().description().c_str());
    if (!r.ok() || !r.value()) {
        return;
    }
    XCTAssertEqual(readBurnIn(r.value()->image.get()), std::optional<int>(index), @"%@: seek(%.4f)", label, sec(t));
    XCTAssertEqualWithAccuracy(sec(r.value()->pts), sec(pts), 1e-6, @"%@: seek(%.4f)", label, sec(t));
}

// MARK: - Video geometry

/// GOPs of 5 s: seeks deep into a GOP, onto the last frame of one, the first of the next, and
/// backwards across them, on both backends.
- (void)testLongGOPSeeksLandOnTheRightFrame {
    const std::string path = [self generated:"gop5s_h264_1080p30.mp4"];
    if (path.empty()) {
        return;
    }
    const CMTime fd = CMTimeMake(1, 30);
    for (const auto &backend : bothBackends()) {
        auto decoder = [self open:*backend path:path];
        if (!decoder) {
            continue;
        }
        for (int frame : {149, 150, 151, 299, 75, 148, 0, 290, 152}) {
            [self expectSeek:*decoder
                          to:CMTimeAdd(CMTimeMultiply(fd, frame), CMTimeMake(1, 120))
                       index:frame
                         pts:CMTimeMultiply(fd, frame)
                       label:@(backend->name().c_str())];
        }
    }
}

/// A leading empty edit: the first frame is presented at 0.5 s. Earlier times select it (the
/// seek contract's "first frame after t"), later times the frame containing them.
- (void)testLeadingEmptyEdit {
    const std::string path = [self generated:"leading_gap_h264.mov"];
    if (path.empty()) {
        return;
    }
    const CMTime first = CMTimeMake(1, 2);
    const CMTime fd = CMTimeMake(1, 30);
    for (const auto &backend : bothBackends()) {
        NSString *label = @(backend->name().c_str());
        auto info = backend->makeProber()->probe(path);
        XCTAssertTrue(info.ok(), @"%@", label);
        if (info.ok()) {
            const TrackInfo *v = info->firstTrack(TrackKind::Video);
            XCTAssertEqualWithAccuracy(sec(v->startTime + v->duration), 2.5, 1e-3, @"%@: track end", label);
        }
        auto decoder = [self open:*backend path:path];
        if (!decoder) {
            continue;
        }
        auto r = decoder->next();
        XCTAssertTrue(r.ok() && r.value());
        if (r.ok() && r.value()) {
            XCTAssertEqual(readBurnIn(r.value()->image.get()), std::optional<int>(0), @"%@", label);
            XCTAssertEqual(CMTimeCompare(r.value()->pts, first), 0, @"%@: first pts %.4f", label, sec(r.value()->pts));
        }
        [self expectSeek:*decoder to:CMTimeMake(1, 5) index:0 pts:first label:label];
        [self expectSeek:*decoder to:CMTimeMake(1, 1) index:15 pts:first + CMTimeMultiply(fd, 15) label:label];
        [self expectSeek:*decoder to:kCMTimeZero index:0 pts:first label:label];
        [self expectSeek:*decoder
                      to:first + CMTimeMultiply(fd, 59)
                   index:59
                     pts:first + CMTimeMultiply(fd, 59)
                   label:label];
    }
}

/// MPEG-TS starts wherever the muxer's clock was (here 10 s plus the muxer's own delay):
/// timestamps and seeks are in that timeline.
- (void)testMpegTsWithANonZeroStart {
    const std::string path = [self derived:"h264_offset.ts"];
    if (path.empty()) {
        XCTSkip(@"h264_offset.ts needs ThirdParty/ffmpeg/tools/bin/ffmpeg");
    }
    auto backend = ffmpeg::makeFFmpegBackend();
    auto info = backend->makeProber()->probe(path);
    XCTAssertTrue(info.ok());
    if (!info.ok()) {
        return;
    }
    XCTAssertEqual(info->container, "mpegts");
    const TrackInfo *v = info->firstTrack(TrackKind::Video);
    const CMTime start = v->startTime;
    NSLog(@"h264_offset.ts: video starts at %.6f s", sec(start));
    XCTAssertGreaterThanOrEqual(sec(start), 10.0);
    XCTAssertEqualWithAccuracy(sec(v->duration), 10.0, 0.05);
    auto decoder = [self open:*backend path:path];
    if (!decoder) {
        return;
    }
    auto r = decoder->next();
    XCTAssertTrue(r.ok() && r.value());
    if (r.ok() && r.value()) {
        XCTAssertEqual(readBurnIn(r.value()->image.get()), std::optional<int>(0));
        XCTAssertEqual(CMTimeCompare(r.value()->pts, start), 0);
    }
    const CMTime fd = CMTimeMake(1, 30);
    for (int frame : {60, 299, 12, 150}) {
        [self expectSeek:*decoder
                      to:start + CMTimeMultiply(fd, frame) + CMTimeMake(1, 100)
                   index:frame
                     pts:start + CMTimeMultiply(fd, frame)
                   label:@"ts"];
    }
    // The router and the asset use the same timeline.
    auto router = std::make_shared<BackendRouter>();
    XCTAssertTrue(router->registerBackend(apple::makeAppleBackend()).ok());
    XCTAssertTrue(router->registerBackend(backend).ok());
    auto routed = router->probe(path);
    XCTAssertTrue(routed.ok() && routed->backendFor(TrackKind::Video) == "ffmpeg");
}

/// A Matroska file that states no duration anywhere (never finalised) is still imported: the
/// prober measures each stream's duration from its packets instead of refusing the file, and
/// the decoders play it to its end.
- (void)testUnfinalisedMatroskaWithoutDurations {
    const std::string path = [self derived:"live_no_duration.mkv"];
    if (path.empty()) {
        XCTSkip(@"live_no_duration.mkv needs ThirdParty/ffmpeg/tools/bin/ffmpeg");
    }
    auto backend = ffmpeg::makeFFmpegBackend();
    auto info = backend->makeProber()->probe(path);
    XCTAssertTrue(info.ok(), @"%s", info.ok() ? "" : info.error().description().c_str());
    if (!info.ok()) {
        return;
    }
    XCTAssertEqual(info->tracks.size(), size_t(2));
    const TrackInfo *v = info->firstTrack(TrackKind::Video);
    const TrackInfo *a = info->firstTrack(TrackKind::Audio);
    XCTAssertTrue(v && a);
    if (!v || !a) {
        return;
    }
    // The live muxer shifted every timestamp by the AAC priming (the audio started at -44 ms),
    // so the video starts at 44 ms; the durations are measured from the packets.
    XCTAssertEqualWithAccuracy(sec(v->duration), 10.0, 0.002, @"measured from the packets");
    XCTAssertEqualWithAccuracy(sec(a->startTime + a->duration), sec(v->startTime + v->duration), 0.06);
    auto decoder = [self open:*backend path:path];
    if (!decoder) {
        return;
    }
    const CMTime fd = CMTimeMake(1, 30);
    const CMTime last = v->startTime + CMTimeMultiply(fd, 299);
    [self expectSeek:*decoder to:last + CMTimeMake(1, 100) index:299 pts:last label:@"live mkv"];
    auto end = decoder->next();
    XCTAssertTrue(end.ok() && !end.value(), @"ends where the data ends");
}

/// A 600 s jump in the audio timestamps (a discontinuity or damage) reads as 600 s of silence
/// without buffering it: memory stays flat, the audio after the jump is where its timestamps
/// say, and seeking into or past the gap works.
- (void)testHugeAudioGapIsSilenceWithoutBuffering {
    const std::string path = [self derived:"audio_gap.mkv"];
    if (path.empty()) {
        XCTSkip(@"audio_gap.mkv needs ThirdParty/ffmpeg/tools/bin/ffmpeg");
    }
    auto decoder = ffmpeg::makeFFmpegBackend()->makeAudioDecoder();
    XCTAssertTrue(decoder->open(path, -1, AudioOptions{}).ok());
    std::vector<float> chunk(48000 * 2);
    const uint64_t before = physicalFootprint();
    double quietMax = 0;
    double toneAfter = 0;
    int64_t frames = 0;
    while (true) {
        auto n = decoder->read(chunk.data(), 48000);
        XCTAssertTrue(n.ok());
        if (!n.ok() || n.value() == 0) {
            break;
        }
        for (int i = 0; i < n.value(); ++i) {
            const int64_t index = frames + i;
            const double v = std::fabs(chunk[static_cast<size_t>(i) * 2]);
            if (index > 4 * 48000 && index < 602 * 48000) {
                quietMax = std::max(quietMax, v);
            } else if (index > 604 * 48000 && index < 605 * 48000) {
                toneAfter = std::max(toneAfter, v);
            }
        }
        frames += n.value();
    }
    const double growthMB = (static_cast<double>(physicalFootprint()) - static_cast<double>(before)) / 1048576.0;
    NSLog(@"audio gap: %lld frames read (%.1f s), footprint %+.1f MB", frames, frames / 48000.0, growthMB);
    XCTAssertEqualWithAccuracy(static_cast<double>(frames) / 48000, 606.0, 0.05);
    XCTAssertEqual(quietMax, 0.0, @"the gap is silence");
    XCTAssertGreaterThan(toneAfter, 0.09, @"the audio after the gap is there");
    XCTAssertLessThan(growthMB, 40.0, @"600 s of silence (230 MB of float samples) was not buffered");
    // Seek into the gap and past it.
    XCTAssertTrue(decoder->seek(CMTimeMake(300, 1)).ok());
    auto n = decoder->read(chunk.data(), 4800);
    XCTAssertTrue(n.ok() && n.value() == 4800);
    XCTAssertEqual(*std::max_element(chunk.begin(), chunk.begin() + 9600), 0.0f);
    XCTAssertTrue(decoder->seek(CMTimeMake(6041, 10)).ok());
    n = decoder->read(chunk.data(), 4800);
    XCTAssertTrue(n.ok() && n.value() == 4800);
    XCTAssertGreaterThan(estimateFrequency(chunk.data(), 0, 4800, 2, 48000), 700.0, @"the 770 Hz tone after the gap");
}

// MARK: - AV1

/// AV1: in MP4 through the Apple backend (VideoToolbox; hardware on M3 and later), and in MP4,
/// WebM and VFR WebM through FFmpeg's libdav1d. The router sends WebM to FFmpeg and MP4 to
/// Apple when VideoToolbox decodes AV1 in hardware.
- (void)testAV1DecodesThroughVideoToolboxAndDav1d {
    const std::string mp4 = [self derived:"av1_640.mp4"];
    const std::string webm = [self derived:"av1_640.webm"];
    if (mp4.empty() || webm.empty()) {
        XCTSkip(@"the AV1 clips need ThirdParty/ffmpeg/tools/bin/ffmpeg built with SVT-AV1 (Scripts/build-ffmpeg.sh)");
    }
    const CMTime fd = CMTimeMake(1, 30);
    auto check = [&](IMediaBackend &backend, const std::string &path) {
        NSString *label = [NSString stringWithFormat:@"%s %s", backend.name().c_str(), path.c_str()];
        auto info = backend.makeProber()->probe(path);
        XCTAssertTrue(info.ok(), @"%@", label);
        if (info.ok()) {
            XCTAssertEqual(info->firstTrack(TrackKind::Video)->codec.fourCC, fourcc::AV1, @"%@", label);
        }
        auto decoder = [self open:backend path:path];
        if (!decoder) {
            return;
        }
        for (int i = 0; i < 10; ++i) {
            auto r = decoder->next();
            XCTAssertTrue(r.ok() && r.value(), @"%@ frame %d", label, i);
            if (!r.ok() || !r.value()) {
                return;
            }
            XCTAssertEqual(readBurnIn(r.value()->image.get()), std::optional<int>(i), @"%@", label);
        }
        for (int frame : {95, 31, 119, 60}) {
            [self expectSeek:*decoder to:CMTimeMultiply(fd, frame) index:frame pts:CMTimeMultiply(fd, frame) label:label];
        }
    };
    auto ff = ffmpeg::makeFFmpegBackend();
    check(*ff, mp4);
    check(*ff, webm);
    const bool vtAV1 = HardwareCaps::get().av1.hardwareDecode;
    NSLog(@"VideoToolbox AV1 hardware decode on this machine: %d", vtAV1);
    auto appleBackend = apple::makeAppleBackend();
    if (vtAV1) {
        check(*appleBackend, mp4);
    }
    auto router = std::make_shared<BackendRouter>();
    XCTAssertTrue(router->registerBackend(appleBackend).ok());
    XCTAssertTrue(router->registerBackend(ff).ok());
    auto routedWebm = router->probe(webm);
    XCTAssertTrue(routedWebm.ok() && routedWebm->backendFor(TrackKind::Video) == "ffmpeg");
    auto routedMp4 = router->probe(mp4);
    XCTAssertTrue(routedMp4.ok());
    if (routedMp4.ok()) {
        XCTAssertEqual(routedMp4->backendFor(TrackKind::Video), vtAV1 ? "apple" : "ffmpeg", @"%s",
                       routedMp4->reason.c_str());
        XCTAssertEqual(routedMp4->firstRoute(TrackKind::Video)->hardwareDecode, vtAV1);
    }
}

// MARK: - Audio sources

/// 44.1 kHz, mono and 5.1 sources on both backends: native-rate decode is exact (beep onset on
/// the ideal signal's sample, exact length for PCM), seeks at 44.1 kHz match sequential decode,
/// and conversion to 48 kHz stereo keeps the beep within a few samples.
- (void)testAudioSourceVariants {
    struct Case {
        const char *file;
        double rate;
        int channels;
        double toneHz;
        double seconds;
        bool pcm;
    };
    const Case cases[] = {
        {"audio_44k.m4a", 44100, 2, 880, 6, false},
        {"audio_44k.wav", 44100, 2, 990, 6, true},
        {"audio_mono.m4a", 48000, 1, 660, 4, false},
        {"audio_51.m4a", 48000, 6, 520, 4, false},
    };
    for (const auto &backend : bothBackends()) {
        for (const Case &c : cases) {
            const std::string path = [self generated:c.file];
            if (path.empty()) {
                continue;
            }
            NSString *label = [NSString stringWithFormat:@"%s %s", backend->name().c_str(), c.file];
            auto info = backend->makeProber()->probe(path);
            XCTAssertTrue(info.ok(), @"%@", label);
            if (info.ok()) {
                const TrackInfo *a = info->firstTrack(TrackKind::Audio);
                XCTAssertEqual(a->sampleRate, c.rate, @"%@", label);
                XCTAssertEqual(a->channels, c.channels, @"%@", label);
            }
            // Native rate and channel count.
            AudioOptions native;
            native.sampleRate = c.rate;
            native.channels = c.channels;
            auto decoder = backend->makeAudioDecoder();
            XCTAssertTrue(decoder->open(path, -1, native).ok(), @"%@", label);
            const std::vector<float> all = readAll(*decoder);
            const auto frames = static_cast<int64_t>(all.size() / static_cast<size_t>(c.channels));
            const auto expected = static_cast<int64_t>(std::llround(c.seconds * c.rate));
            XCTAssertLessThanOrEqual(std::llabs(frames - expected), c.pcm ? 0 : 1024, @"%@: %lld frames", label, frames);
            auto onset = findBeepOnset(all.data(), frames, c.channels, c.rate, static_cast<int64_t>(1.5 * c.rate));
            XCTAssertTrue(onset.has_value(), @"%@", label);
            if (onset) {
                XCTAssertEqualWithAccuracy(*onset, referenceOnset(c.toneHz, c.rate, kMediaBeepStart),
                                           (c.pcm ? 0.5 : 4.0) / c.rate, @"%@: beep at %.6f", label, *onset);
            }
            XCTAssertEqualWithAccuracy(estimateFrequency(all.data(), static_cast<int64_t>(0.5 * c.rate),
                                                         static_cast<int64_t>(1.5 * c.rate), c.channels, c.rate),
                                       c.toneHz, c.toneHz * 0.01, @"%@", label);
            // Every channel carries the tone, except 5.1's LFE: the AAC encoder band-limits the
            // LFE channel (the 520 Hz tone is above it). Output order is L R C LFE Ls Rs on both
            // backends, so the quiet channel must be index 3 for both.
            for (int ch = 0; ch < c.channels; ++ch) {
                double energy = 0;
                for (int64_t i = static_cast<int64_t>(0.5 * c.rate); i < static_cast<int64_t>(1.0 * c.rate); ++i) {
                    energy += std::fabs(all[static_cast<size_t>(i * c.channels + ch)]);
                }
                const bool lfe = c.channels == 6 && ch == 3;
                if (lfe) {
                    XCTAssertLessThan(energy, 0.003 * 0.5 * c.rate, @"%@: channel 3 is the LFE", label);
                } else {
                    XCTAssertGreaterThan(energy, 0.03 * 0.5 * c.rate, @"%@: channel %d is silent", label, ch);
                }
            }
            // Seeks at the native rate match sequential decode.
            std::vector<float> chunk(static_cast<size_t>(4410 * c.channels));
            for (double t : {3.3, 0.25, 1.95, 5.0 * c.seconds / 6.0, 0.013}) {
                const CMTime at = CMTimeMakeWithSeconds(t, 1000000000);
                XCTAssertTrue(decoder->seek(at).ok(), @"%@", label);
                // floor(t * rate) of the exact time passed (not of the double).
                const auto pos =
                    CMTimeConvertScale(at, static_cast<int32_t>(c.rate), kCMTimeRoundingMethod_RoundTowardNegativeInfinity)
                        .value;
                XCTAssertEqual(decoder->position(), pos, @"%@", label);
                auto n = decoder->read(chunk.data(), 4410);
                XCTAssertTrue(n.ok(), @"%@", label);
                if (!n.ok()) {
                    continue;
                }
                double maxDiff = 0;
                for (int64_t i = 0; i < n.value() * c.channels && (pos * c.channels + i) < static_cast<int64_t>(all.size());
                     ++i) {
                    maxDiff = std::max(maxDiff, static_cast<double>(std::fabs(chunk[static_cast<size_t>(i)] -
                                                                              all[static_cast<size_t>(pos * c.channels + i)])));
                }
                XCTAssertLessThan(maxDiff, c.pcm ? 1e-6 : 2e-3, @"%@: seek %.3f differs from sequential by %g", label,
                                  t, maxDiff);
            }
            // Converted to 48 kHz stereo.
            auto converted = backend->makeAudioDecoder();
            XCTAssertTrue(converted->open(path, -1, AudioOptions{}).ok(), @"%@", label);
            const std::vector<float> stereo = readAll(*converted);
            const auto stereoFrames = static_cast<int64_t>(stereo.size() / 2);
            auto onset48 = findBeepOnset(stereo.data(), stereoFrames, 2, 48000, 72000);
            XCTAssertTrue(onset48.has_value(), @"%@ at 48 kHz stereo", label);
            if (onset48) {
                XCTAssertEqualWithAccuracy(*onset48, referenceOnset(c.toneHz, 48000, kMediaBeepStart), 6.0 / 48000,
                                           @"%@: beep at %.6f at 48 kHz stereo", label, *onset48);
            }
        }
    }
}

/// Opus and Vorbis in Matroska/WebM: sequential decode is exact, and a seek lands within the
/// decoder's stated seekTolerance() (half a millisecond tick), as Interfaces.h documents.
- (void)testOpusAndVorbisSeekWithinTheStatedTolerance {
    for (const char *file : {"opus.webm", "vorbis.mkv"}) {
        const std::string path = [self derived:file];
        if (path.empty()) {
            XCTSkip(@"%s needs ThirdParty/ffmpeg/tools/bin/ffmpeg", file);
        }
        auto backend = ffmpeg::makeFFmpegBackend();
        auto sequential = backend->makeAudioDecoder();
        XCTAssertTrue(sequential->open(path, -1, AudioOptions{}).ok(), @"%s", file);
        const std::vector<float> all = readAll(*sequential);
        const auto total = static_cast<int64_t>(all.size() / 2);
        auto onset = findBeepOnset(all.data(), total, 2, 48000, 72000);
        XCTAssertTrue(onset.has_value(), @"%s", file);
        if (onset) {
            // Lossy codecs with their own delay handling: the beep is where the source had it.
            XCTAssertEqualWithAccuracy(*onset, referenceOnset(770, 48000, kMediaBeepStart), 0.25e-3, @"%s: beep %.6f",
                                       file, *onset);
        }
        auto decoder = backend->makeAudioDecoder();
        XCTAssertTrue(decoder->open(path, -1, AudioOptions{}).ok());
        const double tolerance = sec(decoder->seekTolerance());
        NSLog(@"%s: seekTolerance %.6f s (%.1f samples)", file, tolerance, tolerance * 48000);
        XCTAssertGreaterThan(tolerance, 0.0, @"%s: variable-frame-size codec in a millisecond container", file);
        XCTAssertLessThanOrEqual(tolerance, 1.1e-3, @"%s", file);
        // The tone is periodic (a correlation search could lock onto the wrong period); the
        // beep's attack is not: seek to just before it from several distances and compare where
        // the attack lands with where sequential decoding put it.
        const double sequentialOnset = onset.value_or(-1);
        std::vector<float> chunk(24000 * 2);
        int worst = 0;
        for (double t : {1.9, 1.95, 1.97, 1.99, 1.999}) {
            // Reposition far away first so every seek below is a real demuxer seek.
            XCTAssertTrue(decoder->seek(CMTimeMake(8, 1)).ok());
            const CMTime at = CMTimeMakeWithSeconds(t, 1000000000);
            XCTAssertTrue(decoder->seek(at).ok());
            const int64_t pos = CMTimeConvertScale(at, 48000, kCMTimeRoundingMethod_RoundTowardNegativeInfinity).value;
            auto n = decoder->read(chunk.data(), 24000);
            XCTAssertTrue(n.ok() && n.value() == 24000, @"%s seek %.3f", file, t);
            auto after = findBeepOnset(chunk.data(), 24000, 2, 48000);
            XCTAssertTrue(after.has_value(), @"%s seek %.3f", file, t);
            if (!after) {
                continue;
            }
            const double landed = *after + static_cast<double>(pos) / 48000.0;
            const int offset = static_cast<int>(std::lround((landed - sequentialOnset) * 48000));
            worst = std::max(worst, std::abs(offset));
            XCTAssertLessThanOrEqual(std::abs(offset), static_cast<int>(std::ceil(tolerance * 48000)),
                                     @"%s seek %.3f: %d samples off", file, t, offset);
        }
        NSLog(@"%s: worst seek offset %d samples", file, worst);
    }
    // AAC in Matroska stays sample-exact (fixed frame size, snapped to the codec frame grid).
    std::string error;
    const std::string mkvDir = mkvTestMediaDirectory(error);
    XCTAssertFalse(mkvDir.empty(), @"%s", error.c_str());
    if (!mkvDir.empty()) {
        auto decoder = ffmpeg::makeFFmpegBackend()->makeAudioDecoder();
        XCTAssertTrue(decoder->open(mkvDir + "/h264_1080p30.mkv", -1, AudioOptions{}).ok());
        XCTAssertEqual(CMTimeCompare(decoder->seekTolerance(), kCMTimeZero), 0);
    }
}

/// FLAC in MP4 ('fLaC' sample entry) is the same codec to both probers (canonical 'flac'),
/// the router keeps it on AVFoundation, and both backends decode it bit-exactly (it is the
/// 16-bit PCM of audio_only.wav). Raw ADTS AAC is recognised as "aac", not MP3.
- (void)testFlacInMP4AndADTS {
    const std::string flac = [self derived:"flac.mp4"];
    const std::string adts = [self derived:"aac_adts.aac"];
    const std::string wav = [self generated:"audio_only.wav"];
    if (flac.empty() || adts.empty()) {
        XCTSkip(@"flac.mp4 / aac_adts.aac need ThirdParty/ffmpeg/tools/bin/ffmpeg");
    }
    auto reference = apple::makeAppleBackend()->makeAudioDecoder();
    XCTAssertTrue(reference->open(wav, -1, AudioOptions{}).ok());
    const std::vector<float> pcm = readAll(*reference);
    for (const auto &backend : bothBackends()) {
        auto info = backend->makeProber()->probe(flac);
        XCTAssertTrue(info.ok(), @"%s", backend->name().c_str());
        if (info.ok()) {
            XCTAssertEqual(info->firstTrack(TrackKind::Audio)->codec.fourCC, fourcc::FLAC, @"%s",
                           backend->name().c_str());
            XCTAssertTrue(backend->canHandle(info.value()), @"%s", backend->name().c_str());
        }
        auto decoder = backend->makeAudioDecoder();
        XCTAssertTrue(decoder->open(flac, -1, AudioOptions{}).ok(), @"%s", backend->name().c_str());
        const std::vector<float> decoded = readAll(*decoder);
        XCTAssertEqual(decoded.size(), pcm.size(), @"%s", backend->name().c_str());
        double maxDiff = 0;
        for (size_t i = 0; i < std::min(decoded.size(), pcm.size()); ++i) {
            maxDiff = std::max(maxDiff, static_cast<double>(std::fabs(decoded[i] - pcm[i])));
        }
        XCTAssertLessThan(maxDiff, 1e-6, @"%s: FLAC decodes to the source PCM", backend->name().c_str());

        auto aac = backend->makeProber()->probe(adts);
        XCTAssertTrue(aac.ok(), @"%s ADTS", backend->name().c_str());
        if (aac.ok()) {
            XCTAssertEqual(aac->container, "aac", @"%s", backend->name().c_str());
            XCTAssertEqual(canonicalCodec(aac->firstTrack(TrackKind::Audio)->codec.fourCC), fourcc::AAC);
        }
        auto adtsDecoder = backend->makeAudioDecoder();
        XCTAssertTrue(adtsDecoder->open(adts, -1, AudioOptions{}).ok(), @"%s ADTS", backend->name().c_str());
        const std::vector<float> adtsPcm = readAll(*adtsDecoder);
        XCTAssertGreaterThan(adtsPcm.size(), size_t(48000 * 2 * 9), @"%s ADTS", backend->name().c_str());
    }
    auto router = std::make_shared<BackendRouter>();
    XCTAssertTrue(router->registerBackend(apple::makeAppleBackend()).ok());
    XCTAssertTrue(router->registerBackend(ffmpeg::makeFFmpegBackend()).ok());
    auto routed = router->probe(flac);
    XCTAssertTrue(routed.ok() && routed->backendFor(TrackKind::Audio) == "apple",
                  @"FLAC in MP4 is accepted by AVFoundation (canonical four-cc)");
}

// MARK: - Alpha contract and stills

/// ProRes 4444 with alpha decodes to BGRA with STRAIGHT alpha on both backends, tagged
/// kCVImageBufferAlphaChannelMode_StraightAlpha and VideoFrame::alphaIsPremultiplied = false;
/// stills are premultiplied and tagged so.
- (void)testAlphaContractIsExplicit {
    const std::string prores = [self generated:"prores4444_alpha.mov"];
    const std::string png = [self generated:"still.png"];
    if (prores.empty() || png.empty()) {
        return;
    }
    for (const auto &backend : bothBackends()) {
        NSString *label = @(backend->name().c_str());
        auto decoder = [self open:*backend path:prores];
        if (!decoder) {
            continue;
        }
        XCTAssertEqual(decoder->outputPixelFormat(), (OSType)kCVPixelFormatType_32BGRA, @"%@", label);
        auto r = decoder->next();
        XCTAssertTrue(r.ok() && r.value(), @"%@", label);
        if (!r.ok() || !r.value()) {
            continue;
        }
        const VideoFrame &f = *r.value();
        XCTAssertFalse(f.alphaIsPremultiplied, @"%@", label);
        XCTAssertFalse(alphaIsPremultiplied(f.image.get(), true), @"%@: the buffer is tagged straight", label);
        CVPixelBufferRef pb = f.image.get();
        PixelBufferLock lock(pb, true);
        const auto *base = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddress(pb));
        const size_t stride = CVPixelBufferGetBytesPerRow(pb);
        const size_t y = CVPixelBufferGetHeight(pb) * 3 / 4; // Below the burn-in row.
        const uint8_t *left = base + y * stride + (CVPixelBufferGetWidth(pb) / 4) * 4;
        const uint8_t *right = base + y * stride + (CVPixelBufferGetWidth(pb) * 3 / 4) * 4;
        // Frame 0's background is palette 0: R 180, G 60, B 60. Straight alpha keeps it.
        NSLog(@"%@ ProRes 4444: left BGRA %d %d %d %d, right %d %d %d %d", label, left[0], left[1], left[2], left[3],
              right[0], right[1], right[2], right[3]);
        XCTAssertLessThanOrEqual(std::abs(left[3] - 128), 2, @"%@: alpha", label);
        XCTAssertLessThanOrEqual(std::abs(left[2] - 180), 6, @"%@: red is not premultiplied", label);
        XCTAssertLessThanOrEqual(std::abs(left[1] - 60), 6, @"%@", label);
        XCTAssertEqual(right[3], 255, @"%@: opaque half", label);
        XCTAssertLessThanOrEqual(std::abs(right[2] - 180), 6, @"%@", label);

        auto still = [self open:*backend path:png];
        if (still) {
            auto s = still->next();
            XCTAssertTrue(s.ok() && s.value());
            if (s.ok() && s.value()) {
                XCTAssertTrue(s.value()->alphaIsPremultiplied, @"%@ still", label);
                XCTAssertTrue(alphaIsPremultiplied(s.value()->image.get(), false), @"%@ still is tagged", label);
            }
        }
    }
}

/// A 20000 x 1250 panorama decoded at full size (maxDimension 0) is scaled to the Metal texture
/// limit instead of failing (or allocating a buffer the compositor cannot sample).
- (void)testHugePanoramaStillIsClampedToTheTextureLimit {
    const std::string path = scratchDirectory() + "/panorama.png";
    {
        constexpr int w = 20000, h = 1250;
        CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(nullptr, w, h, 8, 0, space,
                                                 static_cast<uint32_t>(kCGImageAlphaNoneSkipLast));
        XCTAssertTrue(ctx != nullptr);
        CGContextSetRGBFillColor(ctx, 0.2, 0.4, 0.8, 1);
        CGContextFillRect(ctx, CGRectMake(0, 0, w, h));
        CGContextSetRGBFillColor(ctx, 0.9, 0.1, 0.1, 1);
        CGContextFillRect(ctx, CGRectMake(0, 0, w / 2, h));
        CGImageRef image = CGBitmapContextCreateImage(ctx);
        CFURLRef url = (__bridge CFURLRef)[NSURL fileURLWithPath:@(path.c_str())];
        CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, nullptr);
        CGImageDestinationAddImage(dest, image, nullptr);
        XCTAssertTrue(CGImageDestinationFinalize(dest));
        CFRelease(dest);
        CGImageRelease(image);
        CGContextRelease(ctx);
        CGColorSpaceRelease(space);
    }
    for (const auto &backend : bothBackends()) {
        NSString *label = @(backend->name().c_str());
        auto info = backend->makeProber()->probe(path);
        XCTAssertTrue(info.ok(), @"%@", label);
        if (info.ok()) {
            XCTAssertEqual(info->firstTrack(TrackKind::Still)->width, 20000, @"%@: the prober reports the real size", label);
        }
        auto decoder = [self open:*backend path:path];
        if (!decoder) {
            continue;
        }
        auto r = decoder->next();
        XCTAssertTrue(r.ok() && r.value(), @"%@", label);
        if (!r.ok() || !r.value()) {
            continue;
        }
        const size_t w = r.value()->image.width();
        const size_t h = r.value()->image.height();
        NSLog(@"%@: 20000x1250 panorama decoded at %zux%zu", label, w, h);
        XCTAssertLessThanOrEqual(w, size_t(kMaxImageDimension), @"%@", label);
        XCTAssertGreaterThanOrEqual(w, size_t(kMaxImageDimension - 2), @"%@: scaled to the limit, not further", label);
        XCTAssertEqualWithAccuracy(static_cast<double>(w) / static_cast<double>(h), 16.0, 0.02, @"%@: aspect", label);
    }
}

// MARK: - Interrupts

/// Both backends poll DecodeOptions::interrupt: a far seek's preroll is abandoned with
/// Cancelled, and after clearing it the decoder resumes and delivers the requested frame.
- (void)testDecodersHonourTheInterruptAndResume {
    const std::string path = [self generated:"gop5s_h264_1080p30.mp4"];
    if (path.empty()) {
        return;
    }
    for (const auto &backend : bothBackends()) {
        NSString *label = @(backend->name().c_str());
        auto interrupt = std::make_shared<DecodeInterrupt>();
        DecodeOptions options;
        options.interrupt = interrupt;
        auto decoder = backend->makeVideoDecoder();
        XCTAssertTrue(decoder->open(path, -1, options).ok(), @"%@", label);
        XCTAssertTrue(decoder->seek(CMTimeMake(149, 30)).ok(), @"%@", label); // Last frame of the first GOP.
        interrupt->request();
        auto cancelled = decoder->next();
        XCTAssertFalse(cancelled.ok(), @"%@", label);
        if (!cancelled.ok()) {
            XCTAssertEqual(cancelled.error().code, MediaErrorCode::Cancelled, @"%@", label);
        }
        interrupt->clear();
        auto resumed = decoder->next();
        XCTAssertTrue(resumed.ok() && resumed.value(), @"%@", label);
        if (resumed.ok() && resumed.value()) {
            XCTAssertEqual(readBurnIn(resumed.value()->image.get()), std::optional<int>(149), @"%@: resumed", label);
        }
        // Interrupted from another thread while the preroll runs.
        XCTAssertTrue(decoder->seek(CMTimeMake(298, 30)).ok(), @"%@", label);
        std::thread interrupter([&] { interrupt->request(); });
        auto maybe = decoder->next();
        interrupter.join();
        if (!maybe.ok()) {
            XCTAssertEqual(maybe.error().code, MediaErrorCode::Cancelled, @"%@", label);
        }
        interrupt->clear();
        [self expectSeek:*decoder to:CMTimeMake(10, 30) index:10 pts:CMTimeMake(10, 30) label:label];
    }
}

// MARK: - Cross-backend equivalence

/// The same file through both backends gives identical timestamps, durations and pictures
/// (burn-ins), and identical audio: bit-exact for PCM, zero lag and matching samples for AAC.
- (void)testBackendsAgreeOnTheSameFiles {
    auto apple = apple::makeAppleBackend();
    auto ff = ffmpeg::makeFFmpegBackend();
    for (const char *file : {"h264_1080p30.mp4", "hevc_720p2997.mov", "prores_540p25.mov", "vfr_h264.mp4"}) {
        const std::string path = [self generated:file];
        if (path.empty()) {
            continue;
        }
        auto a = [self open:*apple path:path];
        auto f = [self open:*ff path:path];
        if (!a || !f) {
            continue;
        }
        for (int round = 0; round < 2; ++round) {
            if (round == 1) {
                XCTAssertTrue(a->seek(CMTimeMake(47, 10)).ok() && f->seek(CMTimeMake(47, 10)).ok());
            }
            for (int i = 0; i < 40; ++i) {
                auto fa = a->next();
                auto ffr = f->next();
                if (!fa.ok() || !fa.value() || !ffr.ok() || !ffr.value()) {
                    XCTAssertEqual(fa.ok() && fa.value().has_value(), ffr.ok() && ffr.value().has_value(),
                                   @"%s: both end together", file);
                    break;
                }
                XCTAssertEqual(CMTimeCompare(fa.value()->pts, ffr.value()->pts), 0, @"%s frame %d pts %.6f vs %.6f",
                               file, i, sec(fa.value()->pts), sec(ffr.value()->pts));
                XCTAssertEqual(CMTimeCompare(fa.value()->duration, ffr.value()->duration), 0,
                               @"%s frame %d duration %.6f vs %.6f", file, i, sec(fa.value()->duration),
                               sec(ffr.value()->duration));
                XCTAssertEqual(readBurnIn(fa.value()->image.get()), readBurnIn(ffr.value()->image.get()), @"%s frame %d",
                               file, i);
            }
        }
    }
    for (const char *file : {"audio_only.wav", "prores_540p25.mov", "audio_44k.wav", "audio_only.m4a", "h264_1080p30.mp4",
                             "audio_44k.m4a"}) {
        const std::string path = [self generated:file];
        if (path.empty()) {
            continue;
        }
        auto da = apple->makeAudioDecoder();
        auto df = ff->makeAudioDecoder();
        XCTAssertTrue(da->open(path, -1, AudioOptions{}).ok() && df->open(path, -1, AudioOptions{}).ok(), @"%s", file);
        const std::vector<float> sa = readAll(*da);
        const std::vector<float> sf = readAll(*df);
        const bool pcm = std::string(file).find(".wav") != std::string::npos || std::string(file) == "prores_540p25.mov";
        const bool resampled = std::string(file).find("44k") != std::string::npos;
        if (pcm && !resampled) {
            XCTAssertEqual(sa.size(), sf.size(), @"%s", file);
            double maxDiff = 0;
            for (size_t i = 0; i < std::min(sa.size(), sf.size()); ++i) {
                maxDiff = std::max(maxDiff, static_cast<double>(std::fabs(sa[i] - sf[i])));
            }
            XCTAssertLessThan(maxDiff, 1e-6, @"%s: PCM is bit-exact across backends", file);
        }
        auto [lag, corr] = bestLag(sa, 2, sf, 2, 96000, 48000, 32);
        NSLog(@"%s: cross-backend audio lag %d samples, correlation %.6f", file, lag, corr);
        XCTAssertEqual(lag, 0, @"%s: the backends place the audio identically", file);
        XCTAssertGreaterThan(corr, pcm && !resampled ? 0.999999 : 0.999, @"%s", file);
    }
}

@end
