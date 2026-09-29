// One hour at 29.97 fps, exported and decoded again: the README's claim of "exact rational time math
// (29.97 fps and 44.1 kHz audio do not accumulate rounding)" checked end to end over 107,892 frames
// (01:00:00;00 in drop-frame timecode). Opt-in (StressSupport.h): the StressTests scheme.
//
// The sequence (640x360, 1001/30000 s frames, a 44.1 kHz sequence) is built from the stress media of
// Scripts/make_test_media.swift --stress:
// - V1/A1 [0, 101): the sync marker from its flash frame on (source frames 100...200), so the flash
//   is sequence frame 0 and its beep (44.1 kHz PCM, starting on the flash frame's first sample)
//   starts on sequence sample 0;
// - V1/A1 [101, 107791): 19 filler clips (linked video and audio) alternating between a 44.1 kHz
//   AAC H.264 source and a 48 kHz AAC HEVC source at speeds 1, 2, 1/2, 3/2, 2/3 and 1001/1000, with
//   a 30-frame cross dissolve (and the linked audio crossfade) on every fourth cut;
// - V1/A1 [107791, 107892): the sync marker from its start, so its flash is the last frame, 107,891;
// - A2 [300, 107000): a bed of the fillers' audio at -12 dB with a fade in and a fade out, clear of
//   both markers so the beep windows hold only the markers.
//
// Each test exports it with the H.264 preset's settings (VEExportSettings, through the facade's own
// mapping makeEncodeSettings) and decodes the whole file with the phase-2 decoders:
// - video: exactly 107,892 frames, frame i presented at exactly i * 1001/30000 s; the only white
//   frames are 0 and 107,891; every frame outside a dissolve shows the burn-in of the source frame
//   the scheduler assigns it (and for speed-1 clips, the frame independently computed from the clip's
//   in point), so no frame over the hour is dropped, duplicated or taken from a neighbour; the track
//   duration is exactly 107,892 frames;
// - audio: the sample count, and the beeps: each onset is measured to a fraction of a sample (the
//   0.3 threshold crossing interpolated, less the crossing's fixed delay after a clean onset) in the
//   first second and the last seconds of the file, and the drift is the difference between the end
//   marker's (beep - flash) offset and the start marker's. The detector's delay and any constant
//   codec delay cancel in the difference; what remains is the time model's error over the hour.
// Wall-clock time, the export's footprint (sampled at each progress delivery, as ExportJobTests does)
// and the drift are logged ("HOUR EXPORT ...").

#import <XCTest/XCTest.h>

#include "../../Engine/Export/ExportJob.h"
#include "../../Engine/Facade/VEExport+Internal.h"
#include "../../Engine/Media/AssetImport.h"
#include "../../Engine/Media/FFmpeg/FFmpegBackend.h"
#include "../../Engine/Model/Validation.h"
#include "../../Engine/Render/Scheduler.h"
#include "../Media/BurnIn.h"
#include "../Media/TestMedia.h"
#include "StressSupport.h"

#include <sys/stat.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <iterator>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

using namespace ve;
namespace ex = ve::exporting;

namespace {

constexpr int64_t kTotalFrames = 107892;                          // 01:00:00;00 at 29.97 fps
constexpr int64_t kMarkerFrames = 101;                            // the flash frame and 100 black ones
constexpr int64_t kMarkerFlashFrame = 100;                        // in sync_marker_2997.mov
constexpr int64_t kEndMarkerStart = kTotalFrames - kMarkerFrames; // 107,791
constexpr int64_t kDissolveFrames = 30;
constexpr int64_t kBedStart = 300;
constexpr int64_t kBedEnd = 107000;

/// `n` sequence frames of 1001/30000 s.
CMTime frames(int64_t n) {
    return CMTimeMake(n * 1001, 30000);
}

double nowSeconds() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

double megabytes(double bytes) {
    return bytes / (1024.0 * 1024.0);
}

/// What the export must show at a sequence frame.
enum : int32_t {
    kExpectBlack = -1, ///< a marker frame other than its flash
    kExpectFlash = -2, ///< the marker's white frame
    kExpectBlend = -3, ///< inside a dissolve: two pictures mixed (only "not white" is checked)
};

struct HourProject {
    Project project;
    SequenceId sequenceId;
    TrackId v1, a1, a2;
    AssetId marker, filler44, filler48;
    std::map<AssetId, media::RoutedMediaInfo> routing;
    int fillerClips = 0;
    int bedClips = 0;
    int dissolves = 0;
    std::string error;

    Sequence &sequence() { return *project.findSequence(sequenceId); }
};

AssetId importFile(HourProject &h, media::BackendRouter &router, const std::string &file) {
    std::string mediaError;
    const std::string path = test::stressMediaPath(file, mediaError);
    if (path.empty()) {
        h.error = "stress media: " + mediaError;
        return AssetId{};
    }
    auto routed = router.probe(path);
    if (!routed.ok()) {
        h.error = file + ": " + routed.error().description();
        return AssetId{};
    }
    const AssetId id = h.project.ids.make<AssetId>();
    auto asset = media::makeMediaAsset(*routed, id);
    if (!asset.ok()) {
        h.error = file + ": " + asset.error().description();
        return AssetId{};
    }
    h.project.assets.push_back(*asset);
    h.routing[id] = *routed;
    return id;
}

ClipId addClip(HourProject &h, TrackId track, AssetId asset, int64_t start, int64_t length, CMTime sourceIn,
               Ratio speed = Ratio{1, 1}) {
    Clip clip;
    clip.id = h.project.ids.make<ClipId>();
    clip.assetId = asset;
    clip.trackId = track;
    clip.timelineStart = frames(start);
    clip.timelineDuration = frames(length);
    clip.sourceIn = sourceIn;
    clip.speed = speed;
    Track &t = *h.sequence().findTrack(track);
    t.clips.push_back(clip);
    t.sortClips();
    return clip.id;
}

void link(HourProject &h, ClipId a, ClipId b) {
    h.sequence().findClip(a)->linkedClipId = b;
    h.sequence().findClip(b)->linkedClipId = a;
}

/// A lane-0 span of `clip`: a centred cross dissolve (Tail, [-half, +half]) or a fade.
void addTransitionSpan(HourProject &h, ClipId clip, ClipEdge edge, CMTime start, CMTime end) {
    EffectSpan span;
    span.id = h.project.ids.make<SpanId>();
    span.lane = kTransitionLane;
    span.kind = SpanKind::Transition;
    span.edge = edge;
    span.start = start;
    span.end = end;
    Clip &c = *h.sequence().findClip(clip);
    c.spans.push_back(span);
    c.sortSpans();
}

/// The hour described at the top of the file.
bool buildHour(HourProject &h, media::BackendRouter &router) {
    h.sequenceId = h.project.addSequence("One hour", CMTimeMake(1001, 30000), 640, 360, 1, 2);
    h.sequence().audioSampleRate = 44100;
    h.v1 = h.sequence().videoTracks[0].id;
    h.a1 = h.sequence().audioTracks[0].id;
    h.a2 = h.sequence().audioTracks[1].id;
    h.marker = importFile(h, router, "sync_marker_2997.mov");
    h.filler44 = importFile(h, router, "filler_h264_44k.mp4");
    h.filler48 = importFile(h, router, "filler_hevc_48k.mov");
    if (!h.error.empty()) {
        return false;
    }

    // The markers.
    const ClipId startV = addClip(h, h.v1, h.marker, 0, kMarkerFrames, frames(kMarkerFlashFrame));
    const ClipId startA = addClip(h, h.a1, h.marker, 0, kMarkerFrames, frames(kMarkerFlashFrame));
    link(h, startV, startA);
    const ClipId endV = addClip(h, h.v1, h.marker, kEndMarkerStart, kMarkerFrames, kCMTimeZero);
    const ClipId endA = addClip(h, h.a1, h.marker, kEndMarkerStart, kMarkerFrames, kCMTimeZero);
    link(h, endV, endA);

    // The fillers: the pattern repeats until the end marker; the last piece takes what is left.
    struct Piece {
        bool from44k;
        Ratio speed;
        int64_t length;        // sequence frames
        int64_t sourceInFrame; // source frames
    };
    const std::vector<Piece> pattern = {
        {true, {1, 1}, 5000, 100},    {false, {2, 1}, 2400, 60},       {true, {1, 2}, 8000, 3000},
        {false, {3, 2}, 3000, 300},   {true, {2, 3}, 9000, 1500},      {false, {1001, 1000}, 5000, 150},
        {true, {1, 1}, 8500, 200},
    };
    std::vector<std::pair<ClipId, ClipId>> fillers; // (video, audio)
    int64_t at = kMarkerFrames;
    for (size_t i = 0; at < kEndMarkerStart; ++i) {
        Piece piece = pattern[i % pattern.size()];
        if (kEndMarkerStart - at - piece.length < 1500) {
            piece.length = kEndMarkerStart - at;
        }
        const AssetId asset = piece.from44k ? h.filler44 : h.filler48;
        const ClipId v = addClip(h, h.v1, asset, at, piece.length, frames(piece.sourceInFrame), piece.speed);
        const ClipId a = addClip(h, h.a1, asset, at, piece.length, frames(piece.sourceInFrame), piece.speed);
        link(h, v, a);
        fillers.emplace_back(v, a);
        at += piece.length;
    }
    h.fillerClips = static_cast<int>(fillers.size());
    // A centred 30-frame dissolve (and crossfade) on every fourth cut between fillers.
    for (size_t i = 0; i + 1 < fillers.size(); i += 4) {
        for (ClipId clip : {fillers[i].first, fillers[i].second}) {
            addTransitionSpan(h, clip, ClipEdge::Tail, frames(-kDissolveFrames / 2),
                              frames(kDissolveFrames - kDissolveFrames / 2));
        }
        ++h.dissolves;
    }

    // The bed on A2: the fillers' audio at -12 dB, faded in and out.
    std::vector<ClipId> bed;
    at = kBedStart;
    for (size_t i = 0; at < kBedEnd; ++i) {
        const bool from48k = i % 2 == 0;
        const int64_t length = std::min<int64_t>(from48k ? 5300 : 8900, kBedEnd - at);
        const ClipId clip = addClip(h, h.a2, from48k ? h.filler48 : h.filler44, at, length, kCMTimeZero);
        h.sequence().findClip(clip)->audio.gainDb = -12.0;
        bed.push_back(clip);
        at += length;
    }
    h.bedClips = static_cast<int>(bed.size());
    addTransitionSpan(h, bed.front(), ClipEdge::Head, kCMTimeZero, frames(60));
    addTransitionSpan(h, bed.back(), ClipEdge::Tail, frames(-60), kCMTimeZero);

    if (const auto problem = validateProject(h.project)) {
        h.error = "invalid project: " + *problem;
        return false;
    }
    if (CMTimeCompare(h.sequence().duration(), frames(kTotalFrames)) != 0) {
        h.error = "the sequence is not 107,892 frames long";
        return false;
    }
    return true;
}

/// Frame index of an exact source time on a 1001/30000 grid, or -1 when it is not on the grid.
int64_t ntscFrameIndex(CMTime t) {
    const __int128 scaled = static_cast<__int128>(t.value) * 30000;
    const __int128 unit = static_cast<__int128>(t.timescale) * 1001;
    if (t.timescale <= 0 || scaled % unit != 0) {
        return -1;
    }
    return static_cast<int64_t>(scaled / unit);
}

/// What every sequence frame must show, from the scheduler (the program monitor's and the export's
/// own frame mapping); speed-1 filler frames are also checked against the clip's in point directly.
/// `independentChecks` counts those; a disagreement goes to `problem`.
std::vector<int32_t> expectedFrames(const HourProject &h, int64_t &independentChecks, std::string &problem) {
    const Sequence &sequence = *h.project.findSequence(h.sequenceId);
    std::vector<int32_t> expected(static_cast<size_t>(kTotalFrames), kExpectBlend);
    for (int64_t f = 0; f < kTotalFrames; ++f) {
        const RenderGraph graph = Scheduler::renderGraphAt(sequence, h.project, frames(f));
        if (graph.layers.size() != 1 || graph.layers[0].transition.has_value()) {
            if (graph.layers.size() != 2 && problem.empty()) {
                problem = "frame " + std::to_string(f) + " has " + std::to_string(graph.layers.size()) + " layers";
            }
            continue;
        }
        const VideoLayer &layer = graph.layers[0];
        const int64_t source = ntscFrameIndex(layer.sourceTime);
        if (source < 0) {
            if (problem.empty()) {
                problem = "frame " + std::to_string(f) + ": source time off the 29.97 grid";
            }
            continue;
        }
        if (layer.assetId == h.marker) {
            expected[size_t(f)] = source == kMarkerFlashFrame ? kExpectFlash : kExpectBlack;
            continue;
        }
        expected[size_t(f)] = static_cast<int32_t>(source);
        const Clip *clip = sequence.findClip(layer.clipId);
        if (clip != nullptr && clip->speed.num == 1 && clip->speed.den == 1) {
            const int64_t start = ntscFrameIndex(clip->timelineStart);
            const int64_t in = ntscFrameIndex(clip->sourceIn);
            ++independentChecks;
            if (in + (f - start) != source && problem.empty()) {
                problem = "frame " + std::to_string(f) + ": the scheduler shows source frame " +
                          std::to_string(source) + ", the clip's in point gives " + std::to_string(in + (f - start));
            }
        }
    }
    return expected;
}

/// Mean 8-bit luma of the frame (every 4th pixel of every 4th row), in full-range code values.
double meanLuma(CVPixelBufferRef buffer) {
    CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const auto *luma = static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(buffer, 0));
    const size_t stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0);
    const size_t width = CVPixelBufferGetWidthOfPlane(buffer, 0);
    const size_t height = CVPixelBufferGetHeightOfPlane(buffer, 0);
    const OSType format = CVPixelBufferGetPixelFormatType(buffer);
    double sum = 0;
    size_t n = 0;
    for (size_t y = 0; y < height; y += 4) {
        for (size_t x = 0; x < width; x += 4) {
            sum += luma[y * stride + x];
            ++n;
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    const double mean = n ? sum / double(n) : 0;
    return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? (mean - 16.0) * 255.0 / 219.0 : mean;
}

/// The beep's onset in `window` (interleaved stereo, channel 0), in samples from the window's start
/// plus `firstFrame`, to a fraction of a sample. The beep is 0.7 sin(w (n - onset)) from its onset
/// (w = 2 pi 1000 Hz / rate), so each of the first two samples above 0.3 in magnitude (on the first
/// rising quarter wave: about 4 and 5 samples in) gives the onset as n - asin(x[n] / 0.7) / w; their
/// mean is the estimate. Exact for the clean signal; codec noise of 1e-3 moves it by about 0.01 sample.
std::optional<double> beepOnset(const std::vector<float> &window, int64_t firstFrame, double rate) {
    constexpr double kThreshold = 0.3;
    const double w = 2.0 * M_PI * test::kBeepFrequency / rate;
    const size_t count = window.size() / 2;
    for (size_t n = 0; n + 1 < count; ++n) {
        if (std::fabs(window[n * 2]) > kThreshold) {
            double sum = 0;
            for (size_t k = n; k <= n + 1; ++k) {
                const double ratio = std::clamp(std::fabs(double(window[k * 2])) / test::kBeepAmplitude, 0.0, 1.0);
                sum += double(k) - std::asin(ratio) / w;
            }
            return double(firstFrame) + sum / 2.0;
        }
    }
    return std::nullopt;
}

/// Where the audio of a speed-1 clip lands relative to its exact place, in output samples: the mixer
/// renders sequence sample n from the clip's decoded sample n + round(a), a = (sourceIn - timeline
/// start) * rate (ClipAudioSource: "at speed 1 the source position is rounded to a whole sample and
/// samples are copied bit-exactly"), so the clip's audio is a - round(a) samples late (at most half a
/// sample, whatever the position: a rounding, not an accumulation). Computed as the engine does.
double speedOnePlacementSamples(CMTime sourceIn, CMTime timelineStart, double rate) {
    const double a = CMTimeGetSeconds(CMTimeSubtract(sourceIn, timelineStart)) * rate;
    return a - double(std::llround(a));
}

struct Measured {
    double exportSeconds = 0;
    double exportFps = 0;
    double verifySeconds = 0;
    double firstWarmMB = 0, peakMB = 0, lastMB = 0, slopeKBPerFrame = 0;
    size_t footprintSamples = 0;
    double driftSamples = NAN;
};

} // namespace

@interface HourExportStressTests : XCTestCase
@end

@implementation HourExportStressTests {
    std::string _dir;
}

- (void)setUp {
    _dir = ve::test::scratchDirectory();
}

- (void)tearDown {
    // The movies are large (the PCM ones about 1 GB): never left behind.
    std::error_code ec;
    std::filesystem::remove_all(_dir, ec);
}

/// Builds the hour, exports it with `settings` (audio at `audioRate` when it differs from the preset's
/// 48 kHz) and checks the file (see the top of the file).
- (void)exportHourWithSettings:(VEExportSettings *)settings
                     audioRate:(double)audioRate
                          name:(NSString *)name
                          file:(NSString *)file {
    VE_REQUIRE_STRESS_TESTS();
    XCTAssertNil(settings.validationMessage, @"%@", settings.validationMessage);

    auto router = media::BackendRouter::makeDefault();
    (void)router->registerBackend(media::ffmpeg::makeFFmpegBackend());
    auto cache = std::make_shared<media::FrameCache>();
    HourProject h;
    const double buildStart = nowSeconds();
    if (!buildHour(h, *router)) {
        XCTFail(@"%@: %s", name, h.error.c_str());
        return;
    }
    NSLog(@"HOUR EXPORT %@: the hour: %d filler clips (+2 markers) with %d dissolves on V1/A1, %d bed clips on A2; "
          @"built in %.2f s",
          name, h.fillerClips, h.dissolves, h.bedClips, nowSeconds() - buildStart);

    // The request: the facade's own mapping of the preset settings, at the sequence's size.
    ex::ExportRequest request;
    request.project = std::make_shared<const Project>(h.project);
    request.sequenceId = h.sequenceId;
    int bitDepth = 8;
    const CGSize size = [settings outputSizeForSequenceWidth:640 height:360];
    const Sequence *hourSequence = h.project.findSequence(h.sequenceId);
    XCTAssertTrue(hourSequence != nullptr);
    if (hourSequence == nullptr) {
        return;
    }
    request.encode = ve::facade::makeEncodeSettings(settings, size, hourSequence->audioSampleRate, bitDepth);
    request.videoBitDepth = bitDepth;
    XCTAssertTrue(request.encode.audio.has_value());
    if (!request.encode.audio) {
        return;
    }
    request.encode.audio->sampleRate = audioRate;
    request.outputPath = _dir + "/" + file.UTF8String;
    ex::ExportServices services;
    services.router = router;
    services.cache = cache;
    services.epoch = cache->epoch();
    services.routing = h.routing;

    // Export, sampling the footprint at every progress delivery (ExportJobTests' method).
    struct Sample {
        int64_t framesDone;
        uint64_t bytes;
    };
    auto samples = std::make_shared<std::vector<Sample>>();
    auto result = std::make_shared<std::optional<media::Result<ex::ExportSummary>>>();
    auto mutex = std::make_shared<std::mutex>();
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_queue_t queue =
        dispatch_queue_create("com.justjohn12345.framewright.tests.hour-export", DISPATCH_QUEUE_SERIAL);
    const double exportStart = nowSeconds();
    auto started = ex::ExportJob::start(
        request, services, ex::ExportOptions{}, queue,
        [samples, mutex](const ex::ExportProgress &p) {
            std::lock_guard<std::mutex> lock(*mutex);
            samples->push_back({p.framesDone, test::physicalFootprint()});
        },
        [result, mutex, done](media::Result<ex::ExportSummary> r) {
            std::lock_guard<std::mutex> lock(*mutex);
            *result = std::move(r);
            dispatch_semaphore_signal(done);
        });
    if (!started.ok()) {
        XCTFail(@"%@: the export was refused: %s", name, started.error().description().c_str());
        return;
    }
    started.value().reset(); // the job keeps itself alive
    // A generous limit: the hour exports in a few minutes on the reference machine.
    const bool finished =
        dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, int64_t(3600) * NSEC_PER_SEC)) == 0;
    XCTAssertTrue(finished, @"%@: the export did not finish within an hour", name);
    std::lock_guard<std::mutex> lock(*mutex);
    if (!finished || !result->has_value() || !(*result)->ok()) {
        XCTFail(@"%@: %s", name,
                result->has_value() ? (*result)->error().description().c_str() : "no completion");
        return;
    }
    const ex::ExportSummary summary = (*result)->value();
    Measured m;
    m.exportSeconds = nowSeconds() - exportStart;
    m.exportFps = summary.averageFps;
    const CMTime hour = frames(kTotalFrames);
    const int64_t expectedAudioFrames = std::llround(CMTimeGetSeconds(hour) * audioRate);
    NSLog(@"HOUR EXPORT %@: %lld frames in %.1f s (%.1f fps), %.1f MB, %s (%s), writer %s", name, summary.frames,
          summary.wallSeconds, summary.averageFps, megabytes(double(summary.bytes)), summary.videoEncoder.c_str(),
          summary.hardwareEncoder ? "hardware" : "software", summary.writerBackend.c_str());
    XCTAssertEqual(summary.frames, kTotalFrames);
    XCTAssertEqual(CMTimeCompare(summary.duration, hour), 0, @"summary duration %.6f s",
                   CMTimeGetSeconds(summary.duration));
    XCTAssertEqual(summary.audioFrames, expectedAudioFrames);
    XCTAssertTrue(summary.hardwareEncoder, @"the H.264 preset encodes 640x360 in hardware on this machine");

    // Footprint: after the pools are warm (150 frames), the peak and the trend against frames done.
    std::vector<Sample> warm;
    std::copy_if(samples->begin(), samples->end(), std::back_inserter(warm),
                 [](const Sample &s) { return s.framesDone >= 150; });
    m.footprintSamples = warm.size();
    XCTAssertGreaterThan(warm.size(), size_t(100), @"%@: enough footprint samples", name);
    if (warm.size() >= 2) {
        double mx = 0, my = 0, peak = 0;
        for (const Sample &s : warm) {
            mx += double(s.framesDone);
            my += double(s.bytes);
            peak = std::max(peak, double(s.bytes));
        }
        mx /= double(warm.size());
        my /= double(warm.size());
        double sxy = 0, sxx = 0;
        for (const Sample &s : warm) {
            sxy += (double(s.framesDone) - mx) * (double(s.bytes) - my);
            sxx += (double(s.framesDone) - mx) * (double(s.framesDone) - mx);
        }
        m.slopeKBPerFrame = sxx > 0 ? sxy / sxx / 1024.0 : 0;
        m.firstWarmMB = megabytes(double(warm.front().bytes));
        m.peakMB = megabytes(peak);
        m.lastMB = megabytes(double(warm.back().bytes));
        NSLog(@"HOUR EXPORT %@: footprint over %zu samples: first warm %.1f MB, peak %.1f MB (+%.1f MB), last %.1f MB, "
              @"trend %+.3f KB per frame",
              name, warm.size(), m.firstWarmMB, m.peakMB, m.peakMB - m.firstWarmMB, m.lastMB, m.slopeKBPerFrame);
        // Flat over the hour: a leak of 1 KB per frame would add 105 MB, of 64 bytes 6.6 MB. The bounds
        // leave room for the writer's and the decoders' own buffers settling (measured: see the log).
        XCTAssertLessThan(m.slopeKBPerFrame, 0.25, @"%@: the footprint grows with the frames exported", name);
        XCTAssertLessThan(m.peakMB - m.firstWarmMB, 96.0, @"%@: the footprint grew during the export", name);
    }

    // The file: container durations.
    const double verifyStart = nowSeconds();
    auto routed = router->probe(request.outputPath);
    XCTAssertTrue(routed.ok(), @"%@: %s", name, routed.ok() ? "" : routed.error().description().c_str());
    if (!routed.ok()) {
        return;
    }
    const media::TrackInfo *video = routed->info.firstTrack(media::TrackKind::Video);
    const media::TrackInfo *audio = routed->info.firstTrack(media::TrackKind::Audio);
    XCTAssertTrue(video != nullptr && audio != nullptr);
    if (video == nullptr || audio == nullptr) {
        return;
    }
    NSLog(@"HOUR EXPORT %@: container %s, duration %.6f s; video %.6f s (value %lld / %d), frame %lld/%d; audio "
          @"%.0f Hz, %.6f s",
          name, routed->info.container.c_str(), CMTimeGetSeconds(routed->info.duration),
          CMTimeGetSeconds(video->duration),
          video->duration.value, video->duration.timescale, video->frameDuration.value, video->frameDuration.timescale,
          audio->sampleRate, CMTimeGetSeconds(audio->duration));
    // The container stores the track's duration in its own timescale (MP4 through AVAssetWriter: the
    // movie timescale, 48000 here, in which 107,892 * 1001/30000 s is 172,799,827.2 ticks): exact to
    // one tick. The frame count and every frame's time are checked exactly below.
    const double videoError = std::fabs(CMTimeGetSeconds(video->duration) - CMTimeGetSeconds(hour));
    XCTAssertLessThanOrEqual(videoError, 1.0 / double(video->duration.timescale) + 1e-9,
                             @"%@: video track %.9f s, %.3f ticks of 1/%d s from the hour", name,
                             CMTimeGetSeconds(video->duration), videoError * video->duration.timescale,
                             video->duration.timescale);
    XCTAssertEqual(CMTimeCompare(video->frameDuration, CMTimeMake(1001, 30000)), 0, @"%@: frame duration %lld/%d", name,
                   video->frameDuration.value, video->frameDuration.timescale);
    XCTAssertEqual(audio->sampleRate, audioRate);
    XCTAssertEqualWithAccuracy(CMTimeGetSeconds(audio->duration), CMTimeGetSeconds(hour), 1.0 / audioRate + 1e-9,
                               @"%@: audio track", name);

    // Every frame of the file against what the sequence shows there.
    int64_t independentChecks = 0;
    std::string expectedProblem;
    const std::vector<int32_t> expected = expectedFrames(h, independentChecks, expectedProblem);
    XCTAssertTrue(expectedProblem.empty(), @"%@: %s", name, expectedProblem.c_str());
    auto decoder = router->makeVideoDecoder(*routed, -1, media::DecodeOptions{});
    XCTAssertTrue(decoder.ok());
    if (!decoder.ok()) {
        return;
    }
    XCTAssertTrue(decoder->decoder->seek(kCMTimeZero).ok());
    int64_t count = 0;
    int64_t timeErrors = 0, pictureErrors = 0, burnInChecked = 0;
    std::vector<int64_t> flashes;
    std::vector<std::string> firstErrors;
    auto note = [&](const std::string &what) {
        if (firstErrors.size() < 8) {
            firstErrors.push_back(what);
        }
    };
    for (;;) {
        auto next = decoder->decoder->next();
        if (!next.ok()) {
            XCTFail(@"%@: decode failed after %lld frames: %s", name, count, next.error().description().c_str());
            break;
        }
        if (!next.value()) {
            break;
        }
        const media::VideoFrame &frame = *next.value();
        const int64_t f = count++;
        if (CMTimeCompare(frame.pts, frames(f)) != 0) {
            ++timeErrors;
            note("frame " + std::to_string(f) + " presented at " + std::to_string(CMTimeGetSeconds(frame.pts)) + " s");
        }
        const double luma = meanLuma(frame.image.get());
        const bool white = luma > 180.0;
        if (white) {
            flashes.push_back(f);
        }
        if (f >= kTotalFrames) {
            continue;
        }
        const int32_t want = expected[size_t(f)];
        if (want == kExpectFlash || want == kExpectBlack || want == kExpectBlend) {
            const bool ok = want == kExpectFlash ? white : (want == kExpectBlack ? luma < 30.0 : !white);
            if (!ok) {
                ++pictureErrors;
                note("frame " + std::to_string(f) + ": mean luma " + std::to_string(luma) + " (expected " +
                     (want == kExpectFlash ? "the flash" : want == kExpectBlack ? "black" : "a dissolve") + ")");
            }
            continue;
        }
        ++burnInChecked;
        const int shown = test::readBurnIn(frame.image.get()).value_or(-1);
        if (shown != want) {
            ++pictureErrors;
            note("frame " + std::to_string(f) + ": burn-in " + std::to_string(shown) + ", expected " +
                 std::to_string(want));
        }
    }
    const double videoVerifySeconds = nowSeconds() - verifyStart;
    std::string flashList;
    for (size_t i = 0; i < flashes.size() && i < 6; ++i) {
        flashList += (i ? ", " : "") + std::to_string(flashes[i]);
    }
    NSLog(@"HOUR EXPORT %@: decoded %lld frames in %.1f s: %lld burn-ins checked (%lld speed-1 frames also against "
          @"the clip's in point), %lld timestamp errors, %lld picture errors, white frames: %s",
          name, count, videoVerifySeconds, burnInChecked, independentChecks, timeErrors, pictureErrors,
          flashList.empty() ? "none" : flashList.c_str());
    for (const std::string &error : firstErrors) {
        NSLog(@"HOUR EXPORT %@:   %s", name, error.c_str());
    }
    XCTAssertEqual(count, kTotalFrames, @"%@: frames in the file", name);
    XCTAssertEqual(timeErrors, int64_t{0}, @"%@: frames not at i * 1001/30000 s", name);
    XCTAssertEqual(pictureErrors, int64_t{0}, @"%@: frames showing the wrong picture", name);
    XCTAssertGreaterThan(burnInChecked, int64_t(100000), @"%@: burn-ins checked", name);
    XCTAssertEqual(flashes.size(), size_t(2), @"%@: white frames", name);
    if (flashes.size() == 2) {
        XCTAssertEqual(flashes[0], int64_t{0}, @"%@: the first flash", name);
        XCTAssertEqual(flashes[1], kTotalFrames - 1, @"%@: the last flash", name);
    }

    // Audio: the whole file decoded (counting its samples), keeping the first second and the last
    // four seconds for the beeps.
    auto audioDecoder = router->makeAudioDecoder(*routed, -1, media::AudioOptions{audioRate, 2});
    XCTAssertTrue(audioDecoder.ok());
    if (!audioDecoder.ok()) {
        return;
    }
    XCTAssertTrue(audioDecoder->decoder->seek(kCMTimeZero).ok());
    const int64_t head = int64_t(audioRate);
    const int64_t tailFrom = expectedAudioFrames - 4 * int64_t(audioRate);
    std::vector<float> first, last;
    std::vector<float> chunk(8192 * 2);
    int64_t decoded = 0;
    for (;;) {
        auto n = audioDecoder->decoder->read(chunk.data(), 8192);
        if (!n.ok()) {
            XCTFail(@"%@: audio decode failed at sample %lld: %s", name, decoded, n.error().description().c_str());
            break;
        }
        if (n.value() <= 0) {
            break;
        }
        for (int i = 0; i < n.value(); ++i) {
            const int64_t s = decoded + i;
            if (s < head) {
                first.insert(first.end(), {chunk[size_t(i) * 2], chunk[size_t(i) * 2 + 1]});
            } else if (s >= tailFrom) {
                last.insert(last.end(), {chunk[size_t(i) * 2], chunk[size_t(i) * 2 + 1]});
            }
        }
        decoded += n.value();
    }
    m.verifySeconds = nowSeconds() - verifyStart;
    XCTAssertEqual(decoded, expectedAudioFrames, @"%@: audio samples in the file", name);
    const auto startOnset = beepOnset(first, 0, audioRate);
    const auto endOnset = beepOnset(last, tailFrom, audioRate);
    XCTAssertTrue(startOnset.has_value() && endOnset.has_value(), @"%@: both beeps found", name);
    if (!startOnset || !endOnset) {
        return;
    }
    // Where the flashes are, in samples: frame 0 at 0, frame 107,891 at 107,891 * 1001/30000 s.
    const double endFlash = double(kTotalFrames - 1) * 1001.0 / 30000.0 * audioRate;
    const double startOffset = *startOnset;
    const double endOffset = *endOnset - endFlash;
    m.driftSamples = endOffset - startOffset;
    const double frameSamples = 1001.0 / 30000.0 * audioRate;
    // What the audio path's speed-1 sample placement predicts (see speedOnePlacementSamples): the
    // start marker's audio is placed exactly (its offset is 100 frames * rate, whole at 44.1 and 48
    // kHz), the end marker's up to half a sample late.
    const double predicted = speedOnePlacementSamples(frames(0), frames(kEndMarkerStart), audioRate) -
                             speedOnePlacementSamples(frames(kMarkerFlashFrame), frames(0), audioRate);
    NSLog(@"HOUR EXPORT %@: beeps at sample %.3f (flash 0: offset %+.3f samples) and %.3f (flash at %.3f: offset %+.3f "
          @"samples); drift over the hour %+.3f samples = %+.2f us (whole-sample placement predicts %+.3f; limit "
          @"1 ms = %.0f samples)",
          name, *startOnset, startOffset, *endOnset, endFlash, endOffset, m.driftSamples,
          m.driftSamples / audioRate * 1e6, predicted, audioRate / 1000.0);
    XCTAssertLessThan(std::fabs(startOffset), frameSamples, @"%@: the first beep within a frame of its flash", name);
    XCTAssertLessThan(std::fabs(endOffset), frameSamples, @"%@: the last beep within a frame of its flash", name);
    XCTAssertLessThan(std::fabs(m.driftSamples) / audioRate, 0.001, @"%@: drift %.3f samples", name, m.driftSamples);
    // Tighter: nothing accumulates over the hour. The drift is the end marker's whole-sample placement
    // (at most half a sample) and the estimator's error (0.1 sample leaves room for AAC's noise).
    XCTAssertLessThanOrEqual(std::fabs(m.driftSamples - predicted), 0.1,
                             @"%@: drift %.3f samples, the sample placement predicts %.3f", name, m.driftSamples,
                             predicted);
    XCTAssertLessThanOrEqual(std::fabs(m.driftSamples), 0.6, @"%@: drift %.3f samples (at most half a sample)", name,
                             m.driftSamples);

    NSLog(@"HOUR EXPORT %@ SUMMARY: export %.1f s wall (%.1f fps), verification %.1f s; footprint first warm %.1f MB, "
          @"peak %.1f MB, trend %+.3f KB/frame over %zu samples; drift %+.3f samples (%+.2f us)",
          name, m.exportSeconds, m.exportFps, m.verifySeconds, m.firstWarmMB, m.peakMB, m.slopeKBPerFrame,
          m.footprintSamples, m.driftSamples, m.driftSamples / audioRate * 1e6);
}

/// The H.264 preset as the export sheet offers it: MP4, AAC 256 kb/s, 48 kHz stereo.
- (void)testOneHourAt2997ExportsWithTheH264PresetFrameAndSampleExact {
    [self exportHourWithSettings:[VEExportSettings defaultSettingsForPreset:VEExportPresetH264]
                       audioRate:48000
                            name:@"H.264 MP4 AAC 48 kHz"
                            file:@"hour_h264_aac.mp4"];
}

/// The H.264 preset with PCM audio (QuickTime): the lossless audio path, 48 kHz as every preset writes.
- (void)testOneHourAt2997ExportsWithPCMAudioFrameAndSampleExact {
    VEExportSettings *preset = [VEExportSettings defaultSettingsForPreset:VEExportPresetH264];
    VEExportSettings *settings = [[VEExportSettings alloc] initWithPreset:VEExportPresetH264
                                                                container:VEExportContainerMOV
                                                               resolution:VEExportResolutionSequence
                                                              customWidth:preset.customWidth
                                                              rateControl:preset.rateControl
                                                                  quality:preset.quality
                                                             videoBitRate:preset.videoBitRate
                                                               audioCodec:VEExportAudioCodecPCM
                                                             audioBitRate:preset.audioBitRate];
    [self exportHourWithSettings:settings audioRate:48000 name:@"H.264 MOV PCM 48 kHz" file:@"hour_h264_pcm48.mov"];
}

/// The same PCM export at the sequence's own 44.1 kHz (an engine request: the presets write 48 kHz), so
/// the markers' 44.1 kHz audio reaches the file without a rate conversion.
- (void)testOneHourAt2997ExportsAt441kHzFrameAndSampleExact {
    VEExportSettings *preset = [VEExportSettings defaultSettingsForPreset:VEExportPresetH264];
    VEExportSettings *settings = [[VEExportSettings alloc] initWithPreset:VEExportPresetH264
                                                                container:VEExportContainerMOV
                                                               resolution:VEExportResolutionSequence
                                                              customWidth:preset.customWidth
                                                              rateControl:preset.rateControl
                                                                  quality:preset.quality
                                                             videoBitRate:preset.videoBitRate
                                                               audioCodec:VEExportAudioCodecPCM
                                                             audioBitRate:preset.audioBitRate];
    [self exportHourWithSettings:settings audioRate:44100 name:@"H.264 MOV PCM 44.1 kHz" file:@"hour_h264_pcm44.mov"];
}

@end
